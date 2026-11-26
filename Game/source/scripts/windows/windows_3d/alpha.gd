extends Node
## Sonde d'alpha : classification opaque / translucide des fenêtres.
##
## Module de Windows3D (nœud enfant « Alpha »), créé par la façade : l'état partagé vit dans la façade
## (`w3d`), l'état propre au module vit ici.

const Windows3D := preload("res://scripts/windows/windows_3d.gd")
var w3d: Windows3D = null

# Shader UNIQUE partagé par toutes les fenêtres/popups. Le créer une seule
# fois évite à Godot de recompiler le shader à chaque ouverture de fenêtre
# (compile synchrone sur le thread principal au premier dessin → gros stall /
# chute de FPS perceptible). Le ShaderMaterial reste propre à chaque quad
# (uniformes window_texture/content_size), seule la ressource Shader est
# partagée.
# ── Sonde d'alpha des fenêtres (transparence en 3D) ───────────────────
# Même logique que la sonde du mode focus : l'alpha de l'image CPU est
# échantillonné UNE fois par fenêtre ; si trop de pixels sont non opaques, la
# fenêtre est classée translucide et son quad garde l'alpha brut (opaque_mode
# = false). Sinon l'alpha est normalisé comme avant.
const ALPHA_CHECK_INTERVAL := 0.25 # s entre deux tentatives
const ALPHA_PROBE_TIMEOUT := 2.0 # s avant abandon si aucune image exploitable
const ALPHA_OPAQUE_MIN := 242 # alpha >= 242/255 considéré opaque
const ALPHA_TRANSLUCENT_FRAC := 0.12 # > 12% px non opaques → translucide
const ALPHA_PROBE_KEY := "windows_alpha"
var _alpha_check_cd := 0.0

func _update_alpha_probes(delta: float) -> void:
	if w3d._alpha_probes.is_empty():
		return
	for wid: int in w3d._alpha_probes.keys():
		w3d._alpha_probes[wid] -= delta
	_alpha_check_cd -= delta
	if _alpha_check_cd <= 0.0:
		_alpha_check_cd = ALPHA_CHECK_INTERVAL
		for wid: int in w3d._alpha_probes.keys():
			if not w3d.quads.has(wid) or not is_instance_valid(w3d.quads[wid]):
				w3d._alpha_probes.erase(wid)
				continue
			var img: Image = w3d.get_window_image(wid)
			if img == null or img.is_empty():
				continue
			w3d._alpha_probes.erase(wid)
			w3d._alpha_decided[wid] = true
			set_window_translucent(wid, _image_is_translucent(img))
	for wid: int in w3d._alpha_probes.keys():
		if w3d._alpha_probes[wid] <= 0.0:
			w3d._alpha_probes.erase(wid)
			w3d._alpha_decided[wid] = true # abandon : reste opaque (comportement historique)
	if w3d._alpha_probes.is_empty() and w3d.cpu_capture_notify.is_valid():
		w3d.cpu_capture_notify.call(ALPHA_PROBE_KEY, false)

# Vrai si plus de ALPHA_TRANSLUCENT_FRAC des pixels échantillonnés sont non opaques.
static func _image_is_translucent(src: Image) -> bool:
	var img := src.duplicate() as Image
	img.convert(Image.FORMAT_RGBA8)
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
	return float(clear) / maxf(total, 1) > ALPHA_TRANSLUCENT_FRAC

# Classification partagée avec le mode focus : -1 inconnue, 0 opaque, 1 translucide.
func get_window_translucent(wid: int) -> int:
	if not w3d._alpha_translucent.has(wid):
		return -1
	return 1 if w3d._alpha_translucent[wid] else 0

# Enregistre la classification (sonde 3D ou sonde du focus) et l'applique au quad.
func set_window_translucent(wid: int, translucent: bool) -> void:
	w3d._alpha_decided[wid] = true
	w3d._alpha_translucent[wid] = translucent
	w3d._alpha_probes.erase(wid)
	_set_quad_opaque_mode(wid, not translucent)
	# Translucide → plus d'occludeur ; opaque → on le (re)pose.
	w3d._set_window_occluder_active(wid, not translucent)

func _set_quad_opaque_mode(wid: int, opaque: bool) -> void:
	var quad: MeshInstance3D = w3d.quads.get(wid)
	if quad == null or not is_instance_valid(quad):
		return
	var mat := quad.material_override as ShaderMaterial
	if mat != null:
		if quad.has_meta(Windows3D.WindowShaders.ACTIVE_META):
			# Le matériau est celui de la transition : on diffère.
			quad.set_meta("pending_opaque", opaque)
			quad.set_meta("window_id_of", wid)
			return
		mat.set_shader_parameter("opaque_mode", opaque)
		# Effet X-RAY actif (shader sans depth test) : effects.gd restaurera le bon
		# shader selon opaque_mode à la désactivation.
		if mat.shader != w3d._window_shader_no_depth():
			mat.shader = w3d._window_shader() if opaque else w3d._window_shader_translucent()

# Lance la sonde d'une fenêtre jamais classée (une salve par fenêtre).
func _start_alpha_probe(wid: int) -> void:
	if w3d._alpha_decided.has(wid) or w3d._alpha_probes.has(wid):
		return
	if w3d._alpha_probes.is_empty():
		_alpha_check_cd = 0.0
		if w3d.cpu_capture_notify.is_valid():
			w3d.cpu_capture_notify.call(ALPHA_PROBE_KEY, true)
	w3d._alpha_probes[wid] = ALPHA_PROBE_TIMEOUT
