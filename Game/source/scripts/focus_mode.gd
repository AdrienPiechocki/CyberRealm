extends Node3D
## Mode focus : affiche une fenêtre en 2D plein écran (TextureRect) et route
## tout l'input clavier + souris vers elle, jusqu'à la sortie (même raccourci
## que l'entrée, ex. Super+F).
## Gère une PILE de fenêtres : une nouvelle fenêtre ouverte pendant le mode
## focus s'ajoute par-dessus la fenêtre active (auto via window_mapped, voir
## wayland_room.gd) ; la fermeture de la fenêtre active (kill) fait retomber
## le focus sur la précédente. Chaque fenêtre conserve son propre état (taille
## d'origine, position du curseur, pointer lock, popups).
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const FOCUS_Z_BASE := 2000 # au-dessus des layer surfaces et de leurs popups
const FOCUS_POPUP_Z := FOCUS_Z_BASE + 50

# Écart (m) entre les fenêtres de la pile à la sortie du mode focus : chacune
# est posée STACK_Z_OFFSET devant la précédente, vers la caméra.
const STACK_Z_OFFSET := -0.1

# Recadre la texture de capture sur la zone de contenu réelle. Le buffer
# d'allocation (VkImage / offscreen) est arrondi au palier supérieur
# (round_up_capture_size, multiple de 64) alors que le signal ne reporte
# que la taille du contenu : sans recadrage, le UV [0,1] couvre la totalité
# de la texture (zone transparente incluse) et STRETCH_SCALE écrase l'image.
# TEXTURE = le TextureRect.texture (le contrôle ne dessine que s'il est
# renseigné) ; la texture de capture est réutilisée telle quelle.
const POPUP_CROP_SHADER_CODE = """
shader_type canvas_item;
uniform vec2 content_size = vec2(0.0, 0.0);

void fragment() {
	vec2 ts = vec2(textureSize(TEXTURE, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	COLOR = texture(TEXTURE, mapped_uv);
}
"""

var popup_crop_shader: Shader

var compositor: WlrCompositor
var player: Node3D
var ui: CanvasLayer
var windows: Node3D

var focus_mode := false
# Pile des fenêtres focalisées : le DERNIER élément est la fenêtre active
# (celle qui reçoit l'input et dont l'overlay est au-dessus des autres).
var focus_stack: Array = []
# window_id (int) -> TextureRect plein écran affichant la fenêtre en overlay 2D.
var focus_rects: Dictionary = {}
# window_id (int) -> état propre à la fenêtre : original_size, mouse_captured,
# mouse_uv, surface_size, content_offset, content_size.
var focus_states: Dictionary = {}
# La seule fenêtre de la pile passée en plein écran côté compositeur (la
# première entrée en focus). Les suivantes conservent leur taille d'origine.
var focus_fullscreen_id := -1
# popup_id (int) -> TextureRect overlay en mode focus. Seuls les popups de la
# fenêtre ACTIVE sont overlayés : les fenêtres du dessous sont couvertes par
# l'overlay actif et leurs popups sont recréés à la réactivation.
var focus_popup_rects: Dictionary = {}

# Grab pointeur sur un popup (drag-and-drop) : tant qu'un bouton est enfoncé
# sur un popup, TOUS les événements (motion + boutons) partent vers CE popup,
# même si le curseur le quitte. Sans ça, un drag qui sort des bords d'un popup
# (menus/dropdowns petits) perd ses événements (relâchement inclus, qui part
# vers la fenêtre principale) → le drag-and-drop ne fonctionne pas.
var popup_drag_id: int = -1
var popup_buttons_down: int = 0

# Curseur custom de la fenêtre active dessiné en overlay 2D (TextureRect
# positionné sur le pointeur) : réplique le wl_pointer.set_cursor de
# l'application en focus pour les fenêtres X11 remontées via
# xwayland-satellite. Le curseur système est masqué (MOUSE_MODE_HIDDEN) pour
# éviter le double curseur ; sans image custom capturée on retombe sur le
# curseur système. cursor_overlay_serial = serial de la dernière image
# appliquée (-1 si aucune) ; on ne re-crée la texture que quand le client en
# pose une nouvelle (commits de la surface).
var cursor_overlay: TextureRect
var cursor_overlay_tex: ImageTexture
var cursor_overlay_serial := -1

# Curseur du propriétaire affiché par-dessus le focus DISTANT (vue seule) :
# réplique la position et l'apparence du curseur du joueur qui possède la
# fenêtre, tant qu'il la survole. État reçu de lan_manager via
# set_remote_cursor_state (position ~30/s, image quand le client la change).
var remote_cursor_overlay: TextureRect
var remote_cursor_state: Dictionary = {}
var remote_cursor_fallback_tex: ImageTexture

# Bitmap 16×16 de la flèche de secours (pointe vers le coin haut-gauche,
# hotspot (0,0)) : affichée quand l'application du propriétaire utilise le
# curseur système (aucun set_cursor custom) — le cas le plus courant.
const REMOTE_CURSOR_BITMAP := [
	"1...............",
	"11..............",
	"111.............",
	"1111............",
	"11111...........",
	"111111..........",
	"1111111.........",
	"11111111........",
	"111111111.......",
	"1111111111......",
	"11111111111.....",
	".111111111......",
	"..1111111.......",
	"...11111........",
	"....111.........",
	"................",
]

# Focus d'une fenêtre DISTANTE (streamée par un autre joueur) : affichage plein
# écran VUE SEULE. Aucun input (clavier/souris) n'est forwardé, pas de kill.
# focus_stack est vide (aucune fenêtre du compositeur local), _active_id() et
# get_focus_window_id() renvoient donc -1.
var remote_focus := false
var remote_focus_peer := -1
var remote_focus_wid := -1
var remote_focus_rect: TextureRect = null

# ── Occlusion du monde pendant le focus ──────────────────────────────
# L'overlay 2D plein écran couvre toute la vue : la scène 3D derrière est
# dessinée pour rien. Un box occludeur fin, posé devant la caméra et
# dimensionné pour couvrir tout le frustum, fait culler par le rasterizer
# d'occlusion (use_occlusion_culling) tout ce qui se trouve derrière
# l'overlay. Un BOX plutôt qu'un quad : volume convexe, aucun piège de
# winding, occlusion valide quel que soit l'angle.

const OCCLUDER_DIST := 0.12 # m devant la caméra (> near plane par défaut 0.05)
const OCCLUDER_MARGIN := 1.4 # marge de couverture du frustum
const OCCLUDER_THICKNESS := 0.02 # m, épaisseur du box

var _world_occluder: OccluderInstance3D

# ── Transparence du focus vs occlusion ───────────────────────────────
# Une fenêtre semi-transparente (Konsole…) laisse voir la scène 3D derrière
# l'overlay : l'occludeur doit alors être suspendu, sinon le monde cullé
# « disparaît » à travers la transparence. On échantillonne le canal alpha de
# l'image CPU de la fenêtre (copie déjà faite par la capture — pas de readback
# GPU), à cadence limitée et seulement si la version de texture a changé.
const ALPHA_CHECK_INTERVAL := 0.4 # s entre deux analyses
const ALPHA_OPAQUE_MIN := 242 # alpha >= 242/255 considéré opaque
const OCCLUDER_OFF_FRAC := 0.12 # > 12% px non opaques → occludeur suspendu
const OCCLUDER_ON_FRAC := 0.04 # < 4% → réactivé (hystérésis anti-clignotement)

var _alpha_check_cd := 0.0
var _alpha_last_version := -1
var _occluder_suspended := false

func _ensure_world_occluder() -> void:
	if _world_occluder != null and is_instance_valid(_world_occluder):
		return
	var box := BoxOccluder3D.new()
	box.size = Vector3(1.0, 1.0, OCCLUDER_THICKNESS)
	_world_occluder = OccluderInstance3D.new()
	_world_occluder.occluder = box
	_world_occluder.visible = false
	add_child(_world_occluder)

# Repositionne l'occludeur devant la caméra courante. Appelé chaque frame en
# focus : la caméra est normalement figée par le focus, mais rester correct
# si elle bouge ne coûte rien.
func _update_world_occluder() -> void:
	if _world_occluder == null or not _world_occluder.visible:
		return
	var cam := player.get_node_or_null("Camera3D") as Camera3D
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
	var box := _world_occluder.occluder as BoxOccluder3D
	box.size = Vector3(vw * OCCLUDER_MARGIN, vh * OCCLUDER_MARGIN, OCCLUDER_THICKNESS)
	_world_occluder.global_transform = Transform3D(
		cam.global_transform.basis,
		cam.global_position - cam.global_transform.basis.z.normalized() * OCCLUDER_DIST)

func _process(delta: float) -> void:
	if focus_mode:
		_update_world_occluder()
		_update_occluder_for_alpha(delta)

# Analyse (throttlée) l'alpha du contenu de la fenêtre focus LOCALE et suspend
# l'occludeur si le contenu est significativement transparent. Le focus
# DISTANT n'est pas concerné : le stream vidéo n'a pas de canal alpha.
func _update_occluder_for_alpha(delta: float) -> void:
	if _world_occluder == null or not _world_occluder.visible:
		return
	if remote_focus or focus_fullscreen_id == -1 \
			or not windows.quads.has(focus_fullscreen_id):
		return
	_alpha_check_cd -= delta
	if _alpha_check_cd > 0.0:
		return
	var ver: int = windows.get_window_texture_version(focus_fullscreen_id)
	if ver == _alpha_last_version:
		return # contenu inchangé → décision conservée
	_alpha_check_cd = ALPHA_CHECK_INTERVAL
	_alpha_last_version = ver
	var img: Image = windows.get_window_image(focus_fullscreen_id)
	if img == null or img.is_empty():
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
	if _occluder_suspended:
		if frac < OCCLUDER_ON_FRAC:
			_occluder_suspended = false
			_world_occluder.visible = true
	elif frac > OCCLUDER_OFF_FRAC:
		_occluder_suspended = true
		_world_occluder.visible = false

func _reset_occluder_alpha_state() -> void:
	_alpha_check_cd = 0.0 # première analyse dès la frame suivante
	_alpha_last_version = -1
	_occluder_suspended = false

func setup(compositor_ref: WlrCompositor, player_ref: Node3D, ui_ref: CanvasLayer, windows_ref: Node3D) -> void:
	compositor = compositor_ref
	player = player_ref
	ui = ui_ref
	windows = windows_ref

	popup_crop_shader = Shader.new()
	popup_crop_shader.code = POPUP_CROP_SHADER_CODE

	cursor_overlay = TextureRect.new()
	cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cursor_overlay.z_index = FOCUS_POPUP_Z + 50
	cursor_overlay.visible = false
	ui.add_child(cursor_overlay)

	remote_cursor_overlay = TextureRect.new()
	remote_cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	remote_cursor_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	remote_cursor_overlay.z_index = FOCUS_POPUP_Z + 51
	remote_cursor_overlay.visible = false
	ui.add_child(remote_cursor_overlay)
	remote_cursor_fallback_tex = _make_remote_cursor_fallback()

func _make_remote_cursor_fallback() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(16):
		for x in range(16):
			if REMOTE_CURSOR_BITMAP[y][x] != "1":
				continue
			for oy in range(2):
				for ox in range(2):
					# Ombre portée décalée d'un pixel en bas-droite (clampée aux
					# bords de l'image 32×32)
					var sx := x * 2 + ox + 1
					var sy := y * 2 + oy + 1
					if sx < 32 and sy < 32:
						img.set_pixel(sx, sy, Color(0, 0, 0, 0.6))
					img.set_pixel(x * 2 + ox, y * 2 + oy, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(img)

func is_active() -> bool:
	return focus_mode

# Vrai si le mode focus affiche une fenêtre distante (vue seule, aucun input).
func is_remote() -> bool:
	return remote_focus

func get_remote_peer() -> int:
	return remote_focus_peer

func get_remote_wid() -> int:
	return remote_focus_wid

func get_focus_window_id() -> int:
	return _active_id()

func _active_id() -> int:
	return focus_stack[-1] if not focus_stack.is_empty() else -1

func _state(id: int) -> Dictionary:
	if not focus_states.has(id):
		focus_states[id] = {
			"original_size": Vector2.ONE,
			"mouse_captured": false,
			"mouse_uv": Vector2(0.5, 0.5),
			"surface_size": Vector2(1, 1),
			"content_offset": Vector2.ZERO,
			"content_size": Vector2(1, 1),
		}
	return focus_states[id]

func enter_focus(id: int) -> void:
	if remote_focus:
		return
	if not windows.quads.has(id) or not is_instance_valid(windows.quads[id]):
		return
	if focus_stack.has(id):
		return
	var entering := not focus_mode
	focus_mode = true
	focus_stack.append(id)
	# L'overlay couvre la vue : activer l'occludeur plein écran pour que
	# l'occlusion culling retire la scène 3D derrière.
	_ensure_world_occluder()
	_world_occluder.visible = true
	_reset_occluder_alpha_state()

	var info: Dictionary = windows.get_quad_info(id)
	var st := _state(id)
	st["mouse_captured"] = false
	st["mouse_uv"] = Vector2(0.5, 0.5)
	st["original_size"] = info.get("surface_size", Vector2(1, 1))

	# Passer en plein écran côté compositeur : seule la première fenêtre de la
	# pile l'est ; les suivantes conservent leur taille (leur overlay 2D plein
	# écran les affiche quand même à l'écran).
	if focus_fullscreen_id == -1:
		compositor.set_window_fullscreen(id, true)
		focus_fullscreen_id = id

	# TextureRect dédié à cette fenêtre : la première (plein écran) couvre
	# tout l'écran, les suivantes sont centrées à taille naturelle (la
	# fenêtre plein écran reste visible autour). L'overlay de la fenêtre
	# active porte le z le plus haut (FOCUS_Z_BASE + position dans la pile).
	var is_fullscreen := focus_fullscreen_id == id
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_PASS
	rect.visible = true
	if is_fullscreen:
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.z_index = FOCUS_Z_BASE + focus_stack.size()
	ui.add_child(rect)
	focus_rects[id] = rect

	# Récupérer la texture courante depuis le quad 3D
	rect.texture = info.get("texture")
	st["surface_size"] = info.get("surface_size", Vector2(1, 1))
	st["content_offset"] = info.get("content_offset", Vector2.ZERO)
	st["content_size"] = info.get("content_size", st["surface_size"])
	_refresh_rect_layout(id)

	# Cacher le quad 3D, l'overlay 2D prend le relais
	# windows.set_quad_visible(id, false)

	# Bloquer le player à la première entrée en mode focus
	if entering:
		player.focus_mode_active = true

	_activate_window(id)

# Affiche en plein écran une fenêtre d'un AUTRE joueur (vue seule) : aucun
# input forwardé, pas de kill, seul le raccourci de sortie fonctionne. La
# texture est rafraîchie par lan_manager (on_remote_texture_updated).
func enter_remote_focus(peer_id: int, wid: int, texture: Texture2D) -> void:
	if focus_mode:
		return
	focus_mode = true
	remote_focus = true
	remote_focus_peer = peer_id
	remote_focus_wid = wid
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.texture = texture
	rect.z_index = FOCUS_Z_BASE + 1
	ui.add_child(rect)
	remote_focus_rect = rect
	# Idem focus local : l'overlay plein écran masque la scène 3D.
	_ensure_world_occluder()
	_world_occluder.visible = true
	player.focus_mode_active = true
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

func exit_focus() -> void:
	if not focus_mode:
		return

	# Focus distant (vue seule) : pas de fenêtre du compositeur à restaurer.
	if remote_focus:
		if remote_focus_rect != null and is_instance_valid(remote_focus_rect):
			remote_focus_rect.queue_free()
		remote_focus_rect = null
		_reset_focus_ui()
		return

	compositor.release_all_keys()

	# Restaurer la fenêtre passée en plein écran (seule la première de la pile
	# l'était) et réafficher les quads 3D de toute la pile. Les fenêtres déjà
	# fermées (kill) ne sont plus dans quads et sont ignorées.
	if focus_fullscreen_id != -1 and windows.quads.has(focus_fullscreen_id) \
		and is_instance_valid(windows.quads[focus_fullscreen_id]):
		compositor.set_window_fullscreen(focus_fullscreen_id, false)
		var st := _state(focus_fullscreen_id)
		compositor.set_window_size(focus_fullscreen_id, int(st["original_size"].x), int(st["original_size"].y))
	# Réafficher les quads 3D en les empilant l'un devant l'autre : la
	# première fenêtre garde sa position, chacune des suivantes est posée
	# STACK_Z_OFFSET devant la précédente (le long de la normale du quad,
	# vers la caméra). Les fenêtres déjà fermées (kill) ne sont plus dans
	# quads et sont ignorées.
	var stack_index := 0
	var first_quad: MeshInstance3D = null
	for id in focus_stack:
		if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
			var quad: MeshInstance3D = windows.quads[id]
			if first_quad != null:
				quad.global_basis = first_quad.global_basis
				quad.global_position = first_quad.global_position \
					- first_quad.global_basis.z.normalized() * STACK_Z_OFFSET * stack_index
			else:
				first_quad = quad
			windows.set_quad_visible(id, true)
			stack_index += 1

	_reset_focus_ui()

# Une frame streamée d'une fenêtre distante est arrivée : la refléter dans
# l'overlay focus distant (appelé par lan_manager).
func on_remote_texture_updated(peer_id: int, wid: int, texture: Texture2D) -> void:
	if not remote_focus or not is_instance_valid(remote_focus_rect):
		return
	if remote_focus_peer != peer_id or remote_focus_wid != wid:
		return
	remote_focus_rect.texture = texture
	_update_remote_cursor()

# Nouvel état du curseur du propriétaire de la fenêtre affichée (position
# ~30/s, image/hidden quand ils changent). state == null : la fenêtre n'est
# plus partagée/visible → masquer le curseur. Appelé par lan_manager.
func set_remote_cursor_state(peer_id: int, wid: int, state) -> void:
	if state == null:
		if remote_focus and remote_focus_peer == peer_id and remote_focus_wid == wid:
			_hide_remote_cursor()
		return
	if not remote_focus or remote_focus_peer != peer_id or remote_focus_wid != wid:
		return
	remote_cursor_state = state
	_update_remote_cursor()

# Positionne le curseur du propriétaire sur la zone affichée du focus distant :
# coordonnées du contenu (x/y) → écran via la même zone STRETCH_KEEP_ASPECT_
# CENTERED que le TextureRect, image custom si dispo sinon flèche de secours.
func _update_remote_cursor() -> void:
	if not remote_focus or remote_cursor_overlay == null:
		return
	if remote_cursor_state.is_empty():
		_hide_remote_cursor()
		return
	if not bool(remote_cursor_state.get("inside", false)) \
			or bool(remote_cursor_state.get("hidden", false)) \
			or bool(remote_cursor_state.get("captured", false)):
		_hide_remote_cursor()
		return
	if remote_focus_rect == null or not is_instance_valid(remote_focus_rect):
		_hide_remote_cursor()
		return
	var tex := remote_focus_rect.texture
	if tex == null:
		_hide_remote_cursor()
		return
	var tex_size := tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		_hide_remote_cursor()
		return
	var rrect := remote_focus_rect.get_global_rect()
	var aspect := tex_size.x / tex_size.y
	var rect_aspect := rrect.size.x / maxf(rrect.size.y, 0.001)
	var displayed: Vector2
	if aspect > rect_aspect:
		displayed = Vector2(rrect.size.x, rrect.size.x / aspect)
	else:
		displayed = Vector2(rrect.size.y * aspect, rrect.size.y)
	var offset := rrect.position + (rrect.size - displayed) / 2.0
	var scale := Vector2(displayed.x / tex_size.x, displayed.y / tex_size.y)
	var custom: Texture2D = remote_cursor_state.get("tex")
	var img_tex: Texture2D = custom if custom != null else remote_cursor_fallback_tex
	var img_size := img_tex.get_size()
	remote_cursor_overlay.texture = img_tex
	var hotspot: Vector2 = remote_cursor_state.get("hotspot", Vector2.ZERO)
	var px := float(remote_cursor_state.get("x", 0.0))
	var py := float(remote_cursor_state.get("y", 0.0))
	remote_cursor_overlay.size = img_size * scale
	remote_cursor_overlay.position = offset \
		+ Vector2(px / tex_size.x, py / tex_size.y) * displayed \
		- hotspot * scale
	remote_cursor_overlay.visible = true

func _hide_remote_cursor() -> void:
	if remote_cursor_overlay:
		remote_cursor_overlay.visible = false

# Une fenêtre distante a été retirée (fermée par le joueur distant) : sortir
# du focus si c'était celle affichée.
func handle_remote_window_removed(peer_id: int, wid: int) -> void:
	if remote_focus and remote_focus_peer == peer_id and remote_focus_wid == wid:
		exit_focus()

# Un joueur distant s'est déconnecté / n'a plus de fenêtres : sortir du focus
# distant et retirer ses PiP s'il était affiché.
func handle_peer_removed(peer_id: int) -> void:
	if remote_focus and remote_focus_peer == peer_id:
		exit_focus()

func on_window_unmapped(id: int) -> void:
	if not focus_mode or not focus_stack.has(id):
		return
	var was_active := id == _active_id()
	focus_stack.erase(id)
	if focus_rects.has(id):
		if is_instance_valid(focus_rects[id]):
			focus_rects[id].queue_free()
		focus_rects.erase(id)
	focus_states.erase(id)
	# Si la fenêtre plein écran quitte la pile, promouvoir la nouvelle
	# première fenêtre : le mode focus garde toujours exactement une fenêtre
	# plein écran côté compositeur.
	if focus_fullscreen_id == id and not focus_stack.is_empty():
		compositor.set_window_fullscreen(focus_stack[0], true)
		focus_fullscreen_id = focus_stack[0]
	if focus_stack.is_empty():
		# Plus aucune fenêtre dans la pile : sortir du mode focus
		compositor.release_all_keys()
		_reset_focus_ui()
	elif was_active:
		# La fenêtre active s'est fermée : retomber sur la précédente
		_activate_window(_active_id())

func on_pointer_lock_changed(window_id: int, locked: bool) -> void:
	# Un jeu a demandé le pointer lock (zwp_pointer_constraints_v1::lock_pointer)
	if not focus_mode or window_id != _active_id():
		return
	var st := _state(window_id)
	if locked:
		st["mouse_captured"] = true
		_hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		st["mouse_captured"] = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func on_window_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not focus_mode or not focus_rects.has(id):
		return
	focus_rects[id].texture = texture
	# Utiliser la taille réelle de la texture (pas width/height qui
	# sont la taille du contenu). Dans le path Vulkan, le VkImage est
	# alloué plus grand que le contenu (round_up_capture_size) — le
	# UV est calculé depuis tex.get_size(), donc la conversion
	# UV → surface doit utiliser la même base.
	var st := _state(id)
	st["surface_size"] = texture.get_size()
	var geo := compositor.get_window_geometry(id)
	st["content_offset"] = Vector2(geo["x"], geo["y"])
	st["content_size"] = Vector2(geo["width"], geo["height"])
	# Nouvelle fenêtre / resize : ajuster la taille de l'overlay des fenêtres
	# non plein écran à la nouvelle taille de surface.
	_refresh_rect_layout(id)

func _nonfullscreen_display_size(surface_size: Vector2, viewport_size: Vector2) -> Vector2:
	if surface_size.x <= 0.0 or surface_size.y <= 0.0:
		return Vector2.ZERO
	var scale := minf(
		viewport_size.x / surface_size.x,
		viewport_size.y / surface_size.y)
	scale = minf(scale, 1.0)
	return surface_size * scale

func _refresh_rect_layout(id: int) -> void:
	var rect: TextureRect = focus_rects.get(id)
	if not rect or id == focus_fullscreen_id:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var display_size := _nonfullscreen_display_size(_state(id)["surface_size"], viewport_size)
	rect.size = display_size
	rect.position = (viewport_size - display_size) / 2.0

func on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	if not focus_mode or remote_focus:
		return
	_create_popup_overlay(id, parent_window_id, parent_popup_id, x, y, width, height)

func on_popup_unmapped(id: int) -> void:
	if popup_drag_id == id:
		popup_drag_id = -1
		popup_buttons_down = 0
	if focus_popup_rects.has(id):
		if is_instance_valid(focus_popup_rects[id]):
			focus_popup_rects[id].queue_free()
		focus_popup_rects.erase(id)

func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if remote_focus or not focus_popup_rects.has(id) or not is_instance_valid(focus_popup_rects[id]):
		return
	var popup_tex_rect: TextureRect = focus_popup_rects[id]
	# texture = propriété du TextureRect : sans elle le contrôle ne dessine
	# pas ; le shader échantillonne ce TEXTURE avec le recadrage.
	popup_tex_rect.texture = texture
	var mat: ShaderMaterial = popup_tex_rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("content_size", Vector2(width, height))
	popup_tex_rect.set_meta("content_size", Vector2(width, height))
	# Recalculer la taille avec le scale du parent
	if windows.popup_parent_info.has(id):
		var info = windows.popup_parent_info[id]
		var layout := _compute_popup_layout(info.parent_window_id, info.parent_popup_id)
		if layout.is_empty():
			return
		var popup_scale: Vector2 = layout["scale"]
		var popup_offset: Vector2 = layout["offset"]
		# width/height (signal) = taille du contenu réel, à la différence de
		# info.width/height qui vient de popup_mapped (géométrie logique).
		popup_tex_rect.size = Vector2(width, height) * popup_scale
		popup_tex_rect.position = popup_offset + Vector2(info.x, info.y) * popup_scale

func _compute_popup_layout(parent_window_id: int, parent_popup_id: int) -> Dictionary:
	"""Scale/offset du popup dans l'espace écran du mode focus."""
	if parent_popup_id != -1 and focus_popup_rects.has(parent_popup_id):
		var parent_rect: TextureRect = focus_popup_rects[parent_popup_id]
		var p_content: Vector2 = parent_rect.get_meta("content_size", parent_rect.size)
		return {
			"scale": Vector2(
				parent_rect.size.x / max(p_content.x, 1.0),
				parent_rect.size.y / max(p_content.y, 1.0)),
			"offset": parent_rect.position,
		}
	elif focus_mode and parent_window_id == _active_id():
		return _compute_focus_displayed_info()
	return {}

func _compute_focus_displayed_info() -> Dictionary:
	"""Calcule l'offset, la taille et le scale de la zone affichée du TextureRect
	de la fenêtre ACTIVE."""
	var active_id := _active_id()
	if active_id == -1 or not focus_rects.has(active_id):
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var rect: TextureRect = focus_rects[active_id]
	var tex := rect.texture
	if not tex:
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var tex_size := tex.get_size()
	var tex_rect := rect.get_global_rect()
	var aspect = tex_size.x / max(tex_size.y, 1.0)
	var rect_aspect = tex_rect.size.x / max(tex_rect.size.y, 1.0)
	var displayed_size: Vector2
	if aspect > rect_aspect:
		displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
	else:
		displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
	var offset := tex_rect.position + (tex_rect.size - displayed_size) / 2.0
	var scale := Vector2(displayed_size.x / max(tex_size.x, 1), displayed_size.y / max(tex_size.y, 1))
	return {"offset": offset, "size": displayed_size, "scale": scale}

func _create_popup_overlay(popup_id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, pw: int, ph: int) -> void:
	"""Crée un TextureRect overlay pour un popup en mode focus."""
	var layout := _compute_popup_layout(parent_window_id, parent_popup_id)
	if layout.is_empty():
		return
	var popup_scale: Vector2 = layout["scale"]
	var popup_offset: Vector2 = layout["offset"]

	var popup_tex_rect := TextureRect.new()
	# EXPAND_IGNORE_SIZE permet d'imposer exactement la taille calculée
	popup_tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# STRETCH_SCALE étire la texture exactement aux bornes du Control ; le
	# shader de recadrage garantit que seul le contenu (pas la zone de
	# padding du buffer arrondi) est étiré.
	popup_tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	popup_tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Force le filtre linéaire pour éviter le flou de scaling de l'UI 2D
	popup_tex_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	var mat := ShaderMaterial.new()
	mat.shader = popup_crop_shader
	mat.set_shader_parameter("content_size", Vector2(pw, ph))
	popup_tex_rect.material = mat

	popup_tex_rect.size = Vector2(pw, ph) * popup_scale
	popup_tex_rect.position = popup_offset + Vector2(x, y) * popup_scale
	popup_tex_rect.z_index = FOCUS_POPUP_Z
	popup_tex_rect.set_meta("content_size", Vector2(pw, ph))
	ui.add_child(popup_tex_rect)
	focus_popup_rects[popup_id] = popup_tex_rect

	# Appliquer la texture disponible dès maintenant
	if windows.popup_quads.has(popup_id) and is_instance_valid(windows.popup_quads[popup_id]):
		var quad: MeshInstance3D = windows.popup_quads[popup_id]
		var qmat: ShaderMaterial = quad.material_override as ShaderMaterial
		if qmat:
			var tex: Texture2D = qmat.get_shader_parameter("window_texture")
			if tex:
				popup_tex_rect.texture = tex

# Renvoie le popup overlayé (de la fenêtre active) le plus au-dessus sous la
# position souris en mode focus, sinon un dictionnaire vide. Les popups créés
# en dernier (sous-menus) sont dessinés au-dessus des autres à z égal : on
# retient le dernier trouvé parmi ceux dont le rect contient le point.
func _popup_at(pos: Vector2) -> Dictionary:
	var top: Dictionary = {}
	for popup_id in focus_popup_rects:
		var popup_rect: TextureRect = focus_popup_rects[popup_id]
		if is_instance_valid(popup_rect) and popup_rect.get_global_rect().has_point(pos):
			top = {"id": popup_id, "rect": popup_rect}
	return top

# Route le mouvement + les clics vers la surface du popup sous le curseur.
# Les coordonnées envoyées sont relatives au CONTENU du popup (la zone
# réellement affichée par l'overlay) : le point écran dans le TextureRect est
# reconverti en pixels de surface via la taille de contenu et la taille
# d'affichage du rect — cohérent avec le rendu et avec les popups parentés en
# cascade (sous-menus), dont l'échelle d'affichage est la même partout.
func _forward_to_popup(hit: Dictionary, mouse_pos: Vector2) -> void:
	var popup_rect: TextureRect = hit.rect
	var popup_id: int = hit.id
	var content_size: Vector2 = popup_rect.get_meta("content_size", popup_rect.size)
	if content_size.x <= 0.0 or content_size.y <= 0.0:
		return
	var global_rect := popup_rect.get_global_rect()
	var px := 0.0
	var py := 0.0
	if global_rect.size.x > 0.0 and global_rect.size.y > 0.0:
		px = (mouse_pos.x - global_rect.position.x) / global_rect.size.x * content_size.x
		py = (mouse_pos.y - global_rect.position.y) / global_rect.size.y * content_size.y
	compositor.forward_pointer_motion_popup(popup_id, px, py)
	# Grab bouton pour le drag-and-drop : mémoriser le popup qui reçoit un
	# appui et compter les boutons enfoncés, pour router vers lui tant que le
	# drag est actif même hors de ses bords (voir handle_focus_input).
	var press_left := Input.is_action_just_pressed("left_click")
	var release_left := Input.is_action_just_released("left_click")
	var press_right := Input.is_action_just_pressed("right_click")
	var release_right := Input.is_action_just_released("right_click")
	var press_middle := Input.is_action_just_pressed("middle_click")
	var release_middle := Input.is_action_just_released("middle_click")
	if press_left or press_right or press_middle:
		popup_buttons_down += 1
		popup_drag_id = popup_id
	if release_left or release_right or release_middle:
		popup_buttons_down = maxi(popup_buttons_down - 1, 0)
		if popup_buttons_down == 0:
			popup_drag_id = -1
	if press_left:
		compositor.forward_pointer_button_popup(popup_id, 0x110, true)
	if release_left:
		compositor.forward_pointer_button_popup(popup_id, 0x110, false)
	if press_right:
		compositor.forward_pointer_button_popup(popup_id, 0x111, true)
	if release_right:
		compositor.forward_pointer_button_popup(popup_id, 0x111, false)
	if press_middle:
		compositor.forward_pointer_button_popup(popup_id, 0x112, true)
	if release_middle:
		compositor.forward_pointer_button_popup(popup_id, 0x112, false)


# Rend la fenêtre courante de la pile la fenêtre active : met à jour le focus
# clavier 3D, l'état de la souris et les popups overlayés (seuls ceux de la
# fenêtre active sont affichés).
func _activate_window(id: int) -> void:
	windows.focused_window_id = id
	# Donner le focus clavier du seat à la fenêtre : les touches forwardées
	# par forward_keyboard_key partent vers la surface qui détient le focus
	# clavier (pas vers un window_id). Sans ça, une nouvelle fenêtre active de
	# la pile recevrait la souris mais pas le clavier (l'enter clavier du
	# compositeur reste sur l'ancienne fenêtre).
	compositor.set_window_keyboard_focus(id)
	var st := _state(id)
	# Restaurer l'état souris de la fenêtre redevenue active. Pas de warp :
	# le curseur reste là où l'utilisateur l'a laissé quand la fenêtre active
	# change (la souris était déjà visible, seul l'état du pointeur du client
	# est restauré ci-dessous).
	_hide_cursor_overlay()
	if st["mouse_captured"]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Rafraîchir les popups overlayés
	_clear_popup_overlays()
	for popup_id in windows.popup_parent_info:
		var pinfo = windows.popup_parent_info[popup_id]
		if pinfo.parent_window_id == id or \
			(pinfo.parent_popup_id != -1 and focus_popup_rects.has(pinfo.parent_popup_id)):
			_create_popup_overlay(popup_id, pinfo.parent_window_id, pinfo.parent_popup_id,
				pinfo.x, pinfo.y, pinfo.width, pinfo.height)

func _clear_popup_overlays() -> void:
	for popup_id in focus_popup_rects:
		if is_instance_valid(focus_popup_rects[popup_id]):
			focus_popup_rects[popup_id].queue_free()
	focus_popup_rects.clear()

func _reset_focus_ui() -> void:
	# Sortie du mode focus : la scène 3D redevient visible, retirer
	# l'occludeur plein écran.
	if _world_occluder != null and is_instance_valid(_world_occluder):
		_world_occluder.visible = false
	_reset_occluder_alpha_state()
	_clear_popup_overlays()
	popup_drag_id = -1
	popup_buttons_down = 0
	for id in focus_rects:
		if is_instance_valid(focus_rects[id]):
			focus_rects[id].queue_free()
	focus_rects.clear()
	focus_states.clear()
	focus_stack.clear()
	focus_fullscreen_id = -1
	focus_mode = false
	remote_focus = false
	remote_focus_peer = -1
	remote_focus_wid = -1
	remote_focus_rect = null
	remote_cursor_state.clear()
	_hide_remote_cursor()
	# Restaurer le curseur système (l'overlay custom de la fenêtre focalisée
	# ne doit pas survivre à la sortie du mode focus).
	_hide_cursor_overlay()
	Input.set_custom_mouse_cursor(null)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.focus_mode_active = false

# Dessine en overlay 2D le curseur posé par l'application en focus
# (wl_pointer.set_cursor). Le curseur système est masqué (MOUSE_MODE_HIDDEN)
# pour éviter un double curseur ; sans image custom capturée on retombe sur
# le curseur système.
func _update_cursor_overlay(window_id: int, mouse_pos: Vector2, display_scale: Vector2) -> void:
	var cursor_info := compositor.get_window_cursor(window_id)
	if cursor_info.is_empty():
		_show_system_cursor()
		return
	# L'application a masqué son curseur OS (set_cursor NULL) et ne fournit
	# aucune image custom (ex. jeux Unity type Papers Please qui dessinent
	# leur propre curseur) : on masque l'overlay, sinon on afficherait la
	# flèche système PAR-DESSUS le curseur du jeu (double curseur).
	# L'image retenue a PRIORITÉ sur hidden : les jeux FPS (SDL) gardent leur
	# curseur capturé pendant le pointer lock sans renvoyer de surface ensuite
	# (rétention) — on continue d'afficher l'overlay dans ce cas.
	if cursor_info.get("hidden", false) and not cursor_info.has("image"):
		_hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		return
	var serial: int = cursor_info["serial"]
	if serial != cursor_overlay_serial:
		var img: Image = cursor_info["image"]
		if not img or img.is_empty():
			_show_system_cursor()
			return
		cursor_overlay_tex = ImageTexture.create_from_image(img)
		cursor_overlay.texture = cursor_overlay_tex
		cursor_overlay_serial = serial
	var hotspot := Vector2(cursor_info["hotspot_x"], cursor_info["hotspot_y"])
	var img_size := cursor_overlay_tex.get_size()
	if img_size.x <= 0.0 or img_size.y <= 0.0:
		_show_system_cursor()
		return
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	cursor_overlay.size = img_size * display_scale
	cursor_overlay.position = mouse_pos - hotspot * display_scale
	cursor_overlay.visible = true

func _show_system_cursor() -> void:
	if cursor_overlay and cursor_overlay.visible:
		cursor_overlay.visible = false
		cursor_overlay_serial = -1
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _hide_cursor_overlay() -> void:
	if cursor_overlay:
		cursor_overlay.visible = false
	cursor_overlay_serial = -1

# Routage souris/clavier du mode focus, appelé chaque frame par
# wayland_room.gd tant que le mode est actif. L'input va à la fenêtre active.
func handle_focus_input() -> void:
	if remote_focus:
		return
	var active_id := _active_id()
	if active_id == -1 or not focus_rects.has(active_id):
		return
	var st := _state(active_id)
	var rect: TextureRect = focus_rects[active_id]
	var surf_x: float
	var surf_y: float

	# Souris capturée (lock): forward UNIQUEMENT le relatif (via _input).
	# Ne PAS envoyer de wl_pointer.motion (absolu) ici : un client locké ne doit
	# recevoir que du relatif (contrat zwp_pointer_constraints_v1). L'absolu
	# par frame accumule mouse_uv, qui sature sur le clamp [0,1] : dès qu'elle
	# est saturée, chaque frame envoie un absolu avec un delta négatif (xrel =
	# P_max - last_x) que SDL3 (OpenMW) traduit en mouvement caméra → la caméra
	# "snap-back" constamment vers sa position d'origine. GLFW (Minecraft)
	# ignore l'absolu quand le pointeur est locké → insensible à ce bug.
	# Le focus pointeur est maintenu par le seat (enter persistant) et le
	# relatif est livré immédiatement par wlr_relative_pointer_manager_v1,
	# suivi d'un frame (cf. forward_pointer_relative_motion).
	if st["mouse_captured"]:
		surf_x = st["mouse_uv"].x * st["surface_size"].x + st["content_offset"].x
		surf_y = st["mouse_uv"].y * st["surface_size"].y + st["content_offset"].y
	else:
		# Souris visible: position absolue, curseur custom suit la souris
		var mouse_pos := get_viewport().get_mouse_position()

		# Utiliser la zone réelle affichée par le TextureRect pour le mapping
		# (plus précis que de recalculer avec surface_size)
		var tex := rect.texture
		var displayed_size: Vector2 = Vector2.ZERO
		if tex:
			var tex_size := tex.get_size()
			# Rect2 global du TextureRect après layout Godot
			var tex_rect := rect.get_global_rect()
			# Taille affichée respectant l'aspect ratio
			var aspect := tex_size.x / tex_size.y
			var rect_aspect := tex_rect.size.x / tex_rect.size.y
			if aspect > rect_aspect:
				displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
			else:
				displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
			var offset := tex_rect.position + (tex_rect.size - displayed_size) / 2.0

			var local_pos := mouse_pos - offset
			st["mouse_uv"] = Vector2(
				clampf(local_pos.x / displayed_size.x, 0.0, 1.0),
				clampf(local_pos.y / displayed_size.y, 0.0, 1.0)
			)
		else:
			st["mouse_uv"] = Vector2(0.5, 0.5)

		# Adopter le curseur custom posé par l'application en focus
		# (wl_pointer.set_cursor, remonté via xwayland-satellite pour les
		# fenêtres X11) : dessiné en overlay 2D sur le pointeur, sinon flèche
		# système par défaut. Uniquement dans le chemin souris visible : en
		# souris capturée (FPS) l'overlay est masqué par _hide_cursor_overlay.
		var display_scale := Vector2.ONE
		if displayed_size.x > 0.0 and st["surface_size"].x > 0.0:
			display_scale = displayed_size / st["surface_size"]
		_update_cursor_overlay(active_id, mouse_pos, display_scale)

		# Popup de la fenêtre active sous le curseur (menus, dropdowns...) :
		# router mouvement + clics vers la SURFACE du popup (forward_*_popup),
		# pas vers la fenêtre. En mode focus seuls les popups de la fenêtre
		# active sont overlayés ; sans ce routage, tout l'input partait vers la
		# fenêtre aux coordonnées du popup et le menu ne recevait ni hover ni
		# clic (inutilisable dans GIMP par exemple, alors que ça marche en 3D).
		# Pendant un drag-and-drop (bouton enfoncé sur un popup), on continue
		# de router vers LE popup qui a reçu l'appui, même quand le curseur le
		# quitte : sinon le relâchement partirait vers la fenêtre et le drag
		# serait abandonné par l'application.
		# MAIS dès qu'un drag est ACTIF au niveau wlroots (wl_data_device), le
		# grab popup n'existe plus : wlroots route tout par la surface sous le
		# curseur (wl_data_device.enter) pour mettre à jour la cible de drop.
		# Router vers le popup figerait la cible sur le popup → DnD cassé.
		var popup_hit := _popup_at(mouse_pos)
		var popup_target: Dictionary
		var drag_active := compositor.is_drag_active()
		if drag_active:
			popup_drag_id = -1
			popup_buttons_down = 0
		if not drag_active and popup_drag_id != -1 and popup_buttons_down > 0 \
				and focus_popup_rects.has(popup_drag_id):
			popup_target = {"id": popup_drag_id, "rect": focus_popup_rects[popup_drag_id]}
		else:
			popup_target = popup_hit
		if not popup_target.is_empty():
			_forward_to_popup(popup_target, mouse_pos)
			compositor.set_window_pointer(active_id, 0, 0, false)
			return

		surf_x = st["mouse_uv"].x * st["surface_size"].x + st["content_offset"].x
		surf_y = st["mouse_uv"].y * st["surface_size"].y + st["content_offset"].y
		compositor.forward_pointer_motion(active_id, surf_x, surf_y)

	compositor.set_window_pointer(active_id, surf_x, surf_y, true)

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button(active_id, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(active_id, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		compositor.forward_pointer_button(active_id, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(active_id, 0x111, false)

	# Clic molette (BTN_MIDDLE) : forwardé comme les clics gauche/droit.
	if Input.is_action_just_pressed("middle_click"):
		compositor.forward_pointer_button(active_id, 0x112, true)
	if Input.is_action_just_released("middle_click"):
		compositor.forward_pointer_button(active_id, 0x112, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(active_id, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(active_id, 0, 100.0)

# Touches mortes AZERTY (^ et ¨) : Godot compose lui-même la séquence dans sa
# couche X11 et avale l'appui de la touche morte PUIS le relâchement de la
# lettre — seul l'appui "composé" arrive (ex. ê, phys=KEY_E). Le client ne
# reçoit donc ni le dead key (→ pas d'accent) ni le relâchement (→ lettre
# "coincée", auto-repeat en boucle). On reconstruit la séquence complète côté
# client : ^ down (evdev 26), lettre down, lettre up, ^ up. Le client (keymap
# fr) compose alors l'accent et son état clavier reste sain.
# Le dead key ^ (evdev 26) est dead_circumflex sans Shift, dead_diaeresis avec
# Shift : le résultat composé dépend du Shift tenu AU moment de l'appui de ^.
# Le flag shift_pressed de l'événement composé reflète, lui, l'état de la
# touche de base (e) : il peut être false pour un ë (Shift relâché avant e).
# On pilote donc l'état Shift du client en 3 phases : (1) Shift = celui du
# dead key, (2) Shift = celui de la lettre, (3) état réel (celui de la lettre)
# maintenu à la fin — ce qui restaure aussi le relâchement avalé par l'IM.
const COMPOSED_CIRCUMFLEX := {
	0xE2: true, 0xE4: true, 0xC2: true, 0xC4: true, # â ä Â Ä
	0xEA: true, 0xEB: true, 0xCA: true, 0xCB: true, # ê ë Ê Ë
	0xEE: true, 0xEF: true, 0xCE: true, 0xCF: true, # î ï Î Ï
	0xF4: true, 0xF6: true, 0xD4: true, 0xD6: true, # ô ö Ô Ö
	0xFB: true, 0xFC: true, 0xDB: true, 0xDC: true, # û ü Û Ü
	0xFF: true, 0x9F: true,                         # ÿ Ÿ
}

# Compositions qui proviennent de dead_diaeresis (¨) : nécessitent Shift sur la
# touche morte ^. Les autres proviennent de dead_circumflex (^, sans Shift).
const COMPOSED_DIAERESIS := {
	0xE4: true, 0xC4: true, # ä Ä
	0xEB: true, 0xCB: true, # ë Ë
	0xEF: true, 0xCF: true, # ï Ï
	0xF6: true, 0xD6: true, # ö Ö
	0xFC: true, 0xDC: true, # ü Ü
	0xFF: true, 0x9F: true, # ÿ Ÿ
}

# Double-appui de la touche morte (^^ -> ^, ¨¨ -> ¨) : X11 compose l'accent
# seul. Il faut forwarder la touche morte DEUX fois pour que l'IM du client
# (qui compose déjà les lettres accentuées) produise le caractère littéral —
# un seul forward laisserait le dead key en attente côté client et l'INJURE à
# la lettre suivante. Valeur : true si le double-appui nécessite Shift
# (dead_diaeresis pour ¨), false sinon (dead_circumflex pour ^).
const COMPOSED_DEADKEY := {
	0x5E: false, # ^ (asciicircum)
	0xA8: true,  # ¨ (diaeresis)
}

# État Shift côté client (ce que le compositeur a forwardé). L'IM (XIM /
# XFilterEvent) avale le relâchement du Shift tenu pendant une touche morte :
# Godot ne l'émet jamais → on doit corriger (heal) l'état du client dès qu'un
# événement non-shifté arrive. (Les deux Shift physiques sont reportés comme
# KEY_SHIFT, seule la location diffère ; le client ne voit que le modifieur.)
var _client_shift := false

func _is_shift_key(code: int) -> bool:
	return code == KEY_SHIFT

# Aligne l'état Shift du client sur p_down (envoie DOWN/UP seulement si l'état
# diffère, pour ne pas désynchroniser xkbcommon côté client).
func _set_client_shift(down: bool) -> void:
	if _client_shift == down:
		return
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("key client_shift -> down=", down)
	compositor.forward_keyboard_key(KEY_SHIFT, 0, down)
	_client_shift = down

# À appeler avant chaque forward_keyboard_key : si le client croit encore que
# Shift est enfoncé alors que l'événement courant n'est pas shifté, c'est que
# le relâchement a été avalé par l'IM lors d'une touche morte → le rétablir
# (sinon Shift reste "coincé" côté client, majuscules/raccourcis cassés). Deux
# cas de heal :
#   - un événement NON shifté arrive (lettre, Super…) → Shift coincé relâché ;
#   - un NOUVEL appui de Shift arrive alors que le client croit déjà Shift
#     enfoncé → le Shift précédent est coincé, il faut le relâcher AVANT de
#     forwarder le nouvel appui (sinon les deux s'empilent et Shift reste
#     bloqué pour les séquences ¨ suivantes).
# Le relâchement normal de Shift (l'événement lui-même) n'est pas healé : il
# est forwardé et met à jour l'état. L'état est ensuite répercuté sur ce
# forward.
func _prepare_key_forward(key_event: InputEventKey, code: int) -> void:
	if _client_shift and code == KEY_SHIFT and key_event.pressed:
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key heal shift-up (re-appui Shift)")
		compositor.forward_keyboard_key(KEY_SHIFT, 0, false)
		_client_shift = false
	if _client_shift and not key_event.shift_pressed and code != KEY_SHIFT:
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key heal shift-up (release avalé par l'IM)")
		compositor.forward_keyboard_key(KEY_SHIFT, 0, false)
		_client_shift = false
	# Cas miroir : l'événement est shifté mais le client n'a pas Shift enfoncé.
	# Après une touche morte, l'appui de Shift suivant est avalé par l'IM (le
	# relâchement l'a déjà été via les heals ci-dessus) → Shift semble "bloqué"
	# côté client pour la lettre suivante. On re-presse Shift AVANT le forward.
	if not _client_shift and key_event.shift_pressed and code != KEY_SHIFT:
		_set_client_shift(true)
	if code == KEY_SHIFT:
		_client_shift = key_event.pressed

# Reconstruit la séquence touche morte + lettre pour un événement composé par
# Godot (touche morte avalée). Retourne true si l'événement a été géré.
func _try_reconstruct_composed_key(event: InputEventKey) -> bool:
	if not event.pressed:
		return false
	# Double-tap de la touche morte : l'accent seul a été composé (^^ -> ^,
	# ¨¨ -> ¨). On rejoue la touche morte deux fois pour que l'IM du client
	# compose le caractère littéral (aucun keycode ne produit ^/¨ directement
	# sur la keymap fr : 26 est toujours un dead key).
	if COMPOSED_DEADKEY.has(event.unicode):
		var needs_shift: bool = COMPOSED_DEADKEY[event.unicode]
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key deadkey: unicode=", event.unicode, " needs_shift=", needs_shift,
				" shift_pressed=", event.shift_pressed)
		_set_client_shift(needs_shift)
		compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
		compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
		compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
		compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
		_set_client_shift(event.shift_pressed)
		return true
	if not COMPOSED_CIRCUMFLEX.has(event.unicode):
		return false
	var phys := event.physical_keycode
	if phys == 0:
		return false
	var needs_shift := COMPOSED_DIAERESIS.has(event.unicode)
	var letter_shift := event.shift_pressed
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("key reconstruct: unicode=", event.unicode, " phys=", phys,
			" needs_shift=", needs_shift, " letter_shift=", letter_shift)
	# Phase 1 : Shift du dead key (determine dead_circumflex vs dead_diaeresis).
	_set_client_shift(needs_shift)
	# KEY_BRACKETLEFT (91) → evdev 26 (touche AZERTY '^'), cf. GODOT_TO_EVDEV.
	compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
	# Phase 2 : Shift réel de la lettre (bas-de-casse vs majuscule), qui reste
	# l'état final (il correspond à la réalité physique après la séquence).
	_set_client_shift(letter_shift)
	compositor.forward_keyboard_key(phys, 0, true)
	compositor.forward_keyboard_key(phys, 0, false)
	compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
	return true

# Gère un InputEvent en mode focus (clavier + tracking souris capturée).
# Renvoie true si l'événement a été consommé (toujours le cas en mode focus).
func handle_input_event(event: InputEvent) -> bool:
	# Focus distant (vue seule) : tout est consommé, rien n'est forwardé
	# (focus_stack est vide pour le focus distant).
	if remote_focus:
		return true
	if not focus_mode or focus_stack.is_empty():
		return false
	var active_id := _active_id()
	var st := _state(active_id)
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# Échos de répétition Godot : les consommer sans les forwarder, sinon
		# xkbcommon reçoit des DOWN non appariés → modificateur "coincé".
		if key_event.echo:
			return true
		# Raccourcis clavier gérés par le jeu lui-même (le raccourci focus
		# pour sortir, la touche de fermeture de la fenêtre) : les consommer
		# SANS les forwarder au client. Sinon la touche est tapée dans la
		# fenêtre avant que l'action (exit_focus / close_window) ne s'exécute
		# dans _process. _is_compositor_shortcut ne matche que le bind exact
		# (modifieurs compris) ET uniquement l'appui : le relâchement est
		# forwardé (dropé comme orphelin par le garde-fou du compositeur si
		# nécessaire), pour ne jamais laisser une touche enfoncée côté client.
		if _is_compositor_shortcut(key_event):
			return true
		var code = key_event.physical_keycode
		if code == 0:
			code = key_event.keycode
		# Touches mortes : Godot a composé l'accent lui-même (voir
		# _try_reconstruct_composed_key) — reconstruire la séquence pour le
		# client (incluant la gestion du Shift, cf. _set_client_shift) et ne
		# pas forwarder l'événement composé tel quel. Doit précéder le heal :
		# le flag shift_pressed d'un événement composé reflète la lettre, pas
		# la touche morte.
		if _try_reconstruct_composed_key(key_event):
			return true
		# Heal : rétablit l'état Shift du client si son relâchement a été avalé
		# par l'IM lors d'une touche morte.
		_prepare_key_forward(key_event, code)
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key focus_mode: phys=", key_event.physical_keycode,
				" code=", key_event.keycode, " unicode=", key_event.unicode,
				" loc=", key_event.location, " pressed=", key_event.pressed)
		# Chevrons AZERTY : la touche ISO (physique KEY_QUOTELEFT/96) donne '<'
		# non-shifté et '>' shifté — même touche evdev 86, le Shift est forwardé
		# à part. Remap par code physique (pas par unicode, nul au relâchement)
		# pour que l'UP parte avec le MÊME evdev que le DOWN : sinon la touche
		# reste enfoncée côté client (auto-repeat en boucle) et les appuis
		# suivants sont bloqués par le garde-fou pressed_keys.
		if key_event.unicode == 60 or key_event.unicode == 62 or code == KEY_QUOTELEFT:
			code = KEY_LESS
		compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
	elif st["mouse_captured"] and event is InputEventMouseMotion:
		# Tracker la position UV + forward le mouvement relatif au client
		var viewport_size := get_viewport().get_visible_rect().size
		var tex_size: Vector2 = st["surface_size"]
		if tex_size.x <= 0 or tex_size.y <= 0:
			tex_size = viewport_size
		var scale := minf(viewport_size.x / tex_size.x, viewport_size.y / tex_size.y)
		var displayed_size := tex_size * scale
		st["mouse_uv"].x += event.relative.x / displayed_size.x
		st["mouse_uv"].y += event.relative.y / displayed_size.y
		st["mouse_uv"].x = clampf(st["mouse_uv"].x, 0.0, 1.0)
		st["mouse_uv"].y = clampf(st["mouse_uv"].y, 0.0, 1.0)
		compositor.forward_pointer_relative_motion(
			active_id,
			event.relative.x, event.relative.y,
			event.relative.x, event.relative.y)
	return true

# True si l'événement clavier correspond à un raccourci géré par le jeu
# (et non par le client) pendant le mode focus : la touche ne doit pas
# être forwardée. Les actions sont celles vérifiées dans _process de
# wayland_room.gd (sortie de focus, fermeture de la fenêtre).
# On utilise exact_match=true : seules les touches correspondant au bind
# exact (modifieurs compris, ex. Super+F) sont consommées. F seul — et
# ses combinaisons Ctrl/Shift/Alt+F — partent donc normalement vers le
# client, même si le raccourci focus utilise le modifieur Super.
# Seul l'APPUI est consommé : le relâchement est toujours forwardé. Si on
# avalait aussi le keyup, un F dont l'appui a déjà été forwardé (tapé dans
# la fenêtre) et qui est relâché pendant que Super est encore enfoncé serait
# perdu → la touche resterait enfoncée côté client (auto-repeat en boucle).
func _is_compositor_shortcut(event: InputEventKey) -> bool:
	if not event.pressed:
		return false
	for action in ["focus_window", "kill_window"]:
		if InputMap.event_is_action(event, action, true):
			return true
	return false
