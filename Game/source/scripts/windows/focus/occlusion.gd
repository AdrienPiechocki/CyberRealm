extends Node
## Occlusion du monde pendant le focus : occludeur plein écran, sonde d'alpha des fenêtres
## translucides, suspension et viewport de maintien à la sortie.
##
## Module de FocusMode (nœud enfant « Occlusion »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

# ── Occlusion du monde pendant le focus ──────────────────────────────
# L'overlay 2D plein écran couvre toute la vue : la scène 3D derrière est
# dessinée pour rien. Un box occludeur fin, posé devant la caméra et
# dimensionné pour couvrir tout le frustum, fait culler par le rasterizer
# d'occlusion (use_occlusion_culling) tout ce qui se trouve derrière
# l'overlay. Un BOX plutôt qu'un quad : volume convexe, aucun piège de
# winding, occlusion valide quel que soit l'angle.

const OCCLUDER_DIST := 0.12 # m devant la caméra (> near plane par défaut 0.05)
const OCCLUDER_MARGIN := 2.0 # marge de couverture du frustum (absorbe les tolérances ci-dessous)
const OCCLUDER_THICKNESS := 0.02 # m, épaisseur du box

# Le module raycast reconstruit TOUTE la scène Embree (BVH du niveau entier,
# sur nproc-2 threads) dès qu'un occludeur change de transform. Or la caméra
# n'est jamais tout à fait immobile en focus : elle suit la tête animée de
# l'avatar (set_head_follow, respiration de l'idle). Recaler l'occludeur à
# chaque frame coûtait ~6 cœurs en continu. On ne le déplace donc que si la
# caméra s'est éloignée de la pose de référence au-delà de ces seuils ; la
# marge ci-dessus garantit que le frustum reste couvert entre-temps.
const OCCLUDER_MOVE_TOLERANCE := 0.02 # m
const OCCLUDER_TURN_TOLERANCE := 0.995 # cos de l'angle (~5.7°) entre axes de visée
var _occluder_ref_xform := Transform3D()
var _occluder_ref_valid := false

# ── Transparence du focus vs occlusion ───────────────────────────────
# Une fenêtre semi-transparente (Konsole…) laisse voir la scène 3D derrière
# l'overlay : l'occludeur doit alors être suspendu, sinon le monde cullé
# « disparaît » à travers la transparence. On échantillonne le canal alpha de
# l'image CPU de la fenêtre (copie déjà faite par la capture — pas de readback
# GPU), à cadence limitée et seulement si la version de texture a changé.
const ALPHA_CHECK_INTERVAL := 0.25 # s entre deux tentatives d'analyse
const ALPHA_PROBE_TIMEOUT := 2.0 # s avant abandon si aucune image exploitable
const ALPHA_OPAQUE_MIN := 242 # alpha >= 242/255 considéré opaque
const OCCLUDER_OFF_FRAC := 0.12 # > 12% px non opaques → occludeur suspendu

var _alpha_check_cd := 0.0
var _alpha_probe_deadline := 0.0
var _alpha_probing := false
var _occluder_suspended := false

func _ensure_world_occluder() -> void:
	if fm._world_occluder != null and is_instance_valid(fm._world_occluder):
		return
	var box := BoxOccluder3D.new()
	box.size = Vector3(1.0, 1.0, OCCLUDER_THICKNESS)
	fm._world_occluder = OccluderInstance3D.new()
	fm._world_occluder.occluder = box
	fm._world_occluder.visible = false
	fm.add_child(fm._world_occluder)
	_occluder_ref_valid = false

# Repositionne l'occludeur devant la caméra courante. Appelé chaque frame en
# focus : la caméra est normalement figée par le focus, mais rester correct
# si elle bouge ne coûte rien.
func _update_world_occluder() -> void:
	if fm._world_occluder == null or not fm._world_occluder.visible:
		return
	var cam := fm.player.get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		return
	var vp_size := get_viewport().get_visible_rect().size
	var aspect := vp_size.x / maxf(vp_size.y, 1.0)
	var half_fov := deg_to_rad(cam.fov) * 0.5
	var vh: float
	var vw: float
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		# fov horizontal : la hauteur se déduit de l'aspect.
		vw = 2.0 * OCCLUDER_DIST * tan(half_fov)
		vh = vw / maxf(aspect, 0.001)
	else:
		# KEEP_HEIGHT (défaut) : fov vertical.
		vh = 2.0 * OCCLUDER_DIST * tan(half_fov)
		vw = vh * aspect
	var box := fm._world_occluder.occluder as BoxOccluder3D
	var size := Vector3(vw * OCCLUDER_MARGIN, vh * OCCLUDER_MARGIN, OCCLUDER_THICKNESS)
	var cam_xf := cam.global_transform
	var size_changed := not box.size.is_equal_approx(size)
	if not size_changed and _occluder_ref_valid \
			and cam_xf.origin.distance_to(_occluder_ref_xform.origin) < OCCLUDER_MOVE_TOLERANCE \
			and cam_xf.basis.z.normalized().dot(_occluder_ref_xform.basis.z.normalized()) > OCCLUDER_TURN_TOLERANCE \
			and cam_xf.basis.y.normalized().dot(_occluder_ref_xform.basis.y.normalized()) > OCCLUDER_TURN_TOLERANCE:
		return
	_occluder_ref_xform = cam_xf
	_occluder_ref_valid = true
	if size_changed:
		box.size = size
	fm._world_occluder.global_transform = Transform3D(
		cam_xf.basis,
		cam_xf.origin - cam_xf.basis.z.normalized() * OCCLUDER_DIST)

# Analyse par SALVE l'alpha du contenu de la fenêtre focus LOCALE : une seule
# décision par focus (le contenu change rarement d'opacité en cours de
# session ; refocus pour réévaluer). Sur le chemin de capture Vulkan
# zéro-copie, l'image CPU n'existe que si quelqu'un la demande — on s'enregistre
# comme consommateur auprès du lan_manager le temps de la salve : la copie
# synchrone coûte 30-50 ms/capture en 1080p sur le thread principal, hors de
# question de la laisser tourner pendant tout le focus. Focus DISTANT exclu :
# le stream vidéo n'a pas de canal alpha.
func _update_occluder_for_alpha(delta: float) -> void:
	# Le compte à rebours avance AVANT toute sortie possible. Sinon une salve
	# qui bute sur une garde ne peut plus expirer : elle garde son consommateur
	# CPU jusqu'à la sortie du focus, et chaque capture paie alors une copie
	# synchrone de 14-30 ms sur le thread principal (cap_surface.cpp:953).
	if _alpha_probing:
		_alpha_probe_deadline -= delta
	# Toutes les reasons de ne pas pouvoir procéder tiennent en une condition,
	# pour qu'aucun retour précoce puisse manquer de relâcher la copie CPU.
	# Cible = fenêtre plein écran si le client l'a demandé, sinon la fenêtre active.
	var pid := _probe_id()
	var can_probe: bool = fm._world_occluder != null and not fm.remote_focus \
			and pid != -1 \
			and fm.windows.quads.has(pid)
	if not can_probe:
		if _alpha_probing:
			print("[focus-alpha] préconditions absentes (occl=%s remote=%s fs_id=%d quad=%s) — copie CPU relâchée" % [
				fm._world_occluder != null, fm.remote_focus, pid,
				fm.windows.quads.has(pid),
			])
			_finish_alpha_probe()
		return
	if not _alpha_probing:
		return
	# Classification déjà faite par la sonde 3D : inutile de copier l'image.
	var known: int = fm.windows.get_window_translucent(pid) \
			if fm.windows.has_method("get_window_translucent") else -1
	if known != -1:
		if known == 1:
			_occluder_suspended = true
			_hide_world_occluder()
		_apply_focus_alpha_mode()
		_finish_alpha_probe()
		return
	_alpha_check_cd -= delta
	if _alpha_check_cd > 0.0:
		return
	_alpha_check_cd = ALPHA_CHECK_INTERVAL
	var img: Image = fm.windows.get_window_image(pid)
	if img == null or img.is_empty():
		if _alpha_probe_deadline <= 0.0:
			print("[focus-alpha] no CPU image available — occluder maintained")
			_finish_alpha_probe()
		return
	img.convert(Image.FORMAT_RGBA8)
	# Grille d'échantillonnage grossière (~1300 points max) : largement assez
	# pour distinguer « fenêtre translucide » de « coins arrondis/ombre ».
	var w := img.get_width()
	var h := img.get_height()
	var step_x := maxi(w / mini(48, w), 1)
	var step_y := maxi(h / mini(27, h), 1)
	var total := 0
	var clear := 0
	for y in range(step_y / 2, h, step_y):
		for x in range(step_x / 2, w, step_x):
			total += 1
			if img.get_pixel(x, y).a * 255.0 < float(ALPHA_OPAQUE_MIN):
				clear += 1
	var frac := float(clear) / maxf(total, 1)
	print("[focus-alpha] window %d — non-opaque pixels: %d%%" % [
		pid, int(frac * 100.0)])
	if frac > OCCLUDER_OFF_FRAC:
		_occluder_suspended = true
		_hide_world_occluder()
	if fm.windows.has_method("set_window_translucent"):
		fm.windows.set_window_translucent(pid, frac > OCCLUDER_OFF_FRAC)
	_apply_focus_alpha_mode()
	_finish_alpha_probe()

# Démarre la salve : enregistre la demande de copie CPU + délai limite.
func _start_alpha_probe() -> void:
	if fm.remote_focus:
		return
	_occluder_suspended = false
	_apply_focus_alpha_mode()
	_alpha_probing = true
	_alpha_check_cd = 0.0 # première tentative dès la frame suivante
	_alpha_probe_deadline = ALPHA_PROBE_TIMEOUT
	if fm.cpu_capture_notify.is_valid():
		fm.cpu_capture_notify.call("focus", true)

# Termine la salve : libère la copie CPU quoi qu'il arrive.
func _finish_alpha_probe() -> void:
	_alpha_probing = false
	if fm.cpu_capture_notify.is_valid():
		fm.cpu_capture_notify.call("focus", false)

func _reset_occluder_alpha_state() -> void:
	_finish_alpha_probe()
	_occluder_suspended = false
	_alpha_check_cd = 0.0
	_alpha_probe_deadline = 0.0

# Mode d'affichage alpha de l'overlay plein écran : les fenêtres classées
# OPAQUES par la sonde (occludeur actif) sont forcées opaques (opaque_mode)
# — voir POPUP_CROP_SHADER_CODE ; les fenêtres réellement translucides
# (occludeur suspendu, ex. Konsole) gardent leur alpha brut.
func _focus_window_alpha_mode() -> bool:
	return not _occluder_suspended

# Fenêtre dont on sonde/règle l'alpha : la plein écran si elle existe, sinon la
# fenêtre active (toutes les fenêtres focus sont au moins maximisées).
func _probe_id() -> int:
	return fm.focus_fullscreen_id if fm.focus_fullscreen_id != -1 else fm._active_id()

func _apply_focus_alpha_mode() -> void:
	var id := _probe_id()
	if id == -1 or not fm.focus_rects.has(id):
		return
	var fmat := fm.focus_rects[id].material as ShaderMaterial
	if fmat != null:
		fmat.set_shader_parameter("opaque_mode", _focus_window_alpha_mode())

# Le buffer de profondeur de l'occlusion culling garde l'occludeur plein écran
# pendant quelques frames après son retrait : le monde resterait cullé (skybox
# seule). On coupe donc l'occlusion culling du viewport le temps que le buffer
# se reconstruise, puis on la rétablit.
const OCCLUSION_RESUME_FRAMES := 8
var _occlusion_resume_token := 0
# Viewport 3D minuscule qui partage le monde du principal (voir plus bas).
var _occlusion_keepalive: SubViewport = null

# POURQUOI le flash de fin de suspension : le moteur (module raycast) ne met à
# jour la scène des occludeurs que dans buffer_update(), appelé uniquement pour
# un viewport qui a un buffer d'occlusion. Pendant la suspension (culling
# coupé) le retrait de l'occludeur plein écran n'est donc JAMAIS pris en
# compte : à la réactivation, la première frame est culée avec l'ANCIENNE scène
# (occludeur plein écran compris) — le niveau disparaît, seul le fond reste.
# Un second viewport avec occlusion culling, sur le même monde, garde la scène
# à jour pendant toute la suspension (cull_mask 0 : il ne dessine rien).
func _start_occlusion_keepalive(main_vp: Viewport) -> void:
	if _occlusion_keepalive != null and is_instance_valid(_occlusion_keepalive):
		return
	var sv := SubViewport.new()
	sv.name = "OcclusionKeepAlive"
	sv.size = Vector2i(64, 64)
	sv.world_3d = main_vp.world_3d
	sv.use_occlusion_culling = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.audio_listener_enable_3d = false
	var cam := Camera3D.new()
	cam.cull_mask = 0
	sv.add_child(cam)
	fm.add_child(sv)
	cam.current = true
	_occlusion_keepalive = sv

func _stop_occlusion_keepalive() -> void:
	if _occlusion_keepalive != null and is_instance_valid(_occlusion_keepalive):
		_occlusion_keepalive.queue_free()
	_occlusion_keepalive = null

func _suspend_occlusion_after_focus() -> void:
	var vp := get_viewport()
	if vp == null or not fm.is_inside_tree():
		return
	_occlusion_resume_token += 1
	var token := _occlusion_resume_token
	vp.use_occlusion_culling = false
	_start_occlusion_keepalive(vp)
	for i in OCCLUSION_RESUME_FRAMES:
		await get_tree().process_frame
		if not fm.is_inside_tree():
			return
	# Une sortie de focus plus récente reprend la main sur la réactivation.
	if token == _occlusion_resume_token:
		vp.use_occlusion_culling = true
		_stop_occlusion_keepalive()

# TOUT retrait de l'occludeur plein écran passe par ici : le buffer d'occlusion
# garde sa silhouette quelques frames, y compris quand il est retiré hors de
# la sortie du focus (fenêtre fermée, sonde de translucidité). Sans la
# suspension, le niveau disparaît pendant ces frames.
func _hide_world_occluder() -> void:
	if fm._world_occluder == null or not is_instance_valid(fm._world_occluder):
		return
	if fm._world_occluder.visible:
		_suspend_occlusion_after_focus()
	fm._world_occluder.visible = false
