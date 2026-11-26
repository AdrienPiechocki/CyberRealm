extends Node
## Focus des fenêtres distantes (LAN, lecture seule) : texture et curseur du propriétaire.
##
## Module de FocusMode (nœud enfant « Remote »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

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

# Affiche en plein écran une fenêtre d'un AUTRE joueur (vue seule) : aucun
# input forwardé, pas de kill, seul le raccourci de sortie fonctionne. La
# texture est rafraîchie par lan_manager (on_remote_texture_updated).
func enter_remote_focus(peer_id: int, wid: int, texture: Texture2D) -> void:
	if fm.focus_mode:
		return
	fm.focus_mode = true
	fm.remote_focus = true
	fm.remote_focus_peer = peer_id
	fm.remote_focus_wid = wid
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.texture = texture
	rect.z_index = FocusMode.FOCUS_Z_BASE + 1
	fm.ui.add_child(rect)
	fm.remote_focus_rect = rect
	# Idem focus local : l'overlay plein écran masque la scène 3D.
	fm.occlusion._ensure_world_occluder()
	fm._world_occluder.visible = FocusMode.FOCUS_OCCLUDES_WORLD
	fm.player.focus_mode_active = true
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

# Une frame streamée d'une fenêtre distante est arrivée : la refléter dans
# l'overlay focus distant (appelé par lan_manager).
func on_remote_texture_updated(peer_id: int, wid: int, texture: Texture2D) -> void:
	if not fm.remote_focus or not is_instance_valid(fm.remote_focus_rect):
		return
	if fm.remote_focus_peer != peer_id or fm.remote_focus_wid != wid:
		return
	fm.remote_focus_rect.texture = texture
	_update_remote_cursor()

# Nouvel état du curseur du propriétaire de la fenêtre affichée (position
# ~30/s, image/hidden quand ils changent). state == null : la fenêtre n'est
# plus partagée/visible → masquer le curseur. Appelé par lan_manager.
func set_remote_cursor_state(peer_id: int, wid: int, state) -> void:
	if state == null:
		if fm.remote_focus and fm.remote_focus_peer == peer_id and fm.remote_focus_wid == wid:
			_hide_remote_cursor()
		return
	if not fm.remote_focus or fm.remote_focus_peer != peer_id or fm.remote_focus_wid != wid:
		return
	fm.remote_cursor_state = state
	_update_remote_cursor()

# Positionne le curseur du propriétaire sur la zone affichée du focus distant :
# coordonnées du contenu (x/y) → écran via la même zone STRETCH_KEEP_ASPECT_
# CENTERED que le TextureRect, image custom si dispo sinon flèche de secours.
func _update_remote_cursor() -> void:
	if not fm.remote_focus or fm.remote_cursor_overlay == null:
		return
	if fm.remote_cursor_state.is_empty():
		_hide_remote_cursor()
		return
	if not bool(fm.remote_cursor_state.get("inside", false)) \
			or bool(fm.remote_cursor_state.get("hidden", false)) \
			or bool(fm.remote_cursor_state.get("captured", false)):
		_hide_remote_cursor()
		return
	if fm.remote_focus_rect == null or not is_instance_valid(fm.remote_focus_rect):
		_hide_remote_cursor()
		return
	var tex := fm.remote_focus_rect.texture
	if tex == null:
		_hide_remote_cursor()
		return
	var tex_size := tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		_hide_remote_cursor()
		return
	var rrect := fm.remote_focus_rect.get_global_rect()
	var aspect := tex_size.x / tex_size.y
	var rect_aspect := rrect.size.x / maxf(rrect.size.y, 0.001)
	var displayed: Vector2
	if aspect > rect_aspect:
		displayed = Vector2(rrect.size.x, rrect.size.x / aspect)
	else:
		displayed = Vector2(rrect.size.y * aspect, rrect.size.y)
	var offset := rrect.position + (rrect.size - displayed) / 2.0
	var scale := Vector2(displayed.x / tex_size.x, displayed.y / tex_size.y)
	var custom: Texture2D = fm.remote_cursor_state.get("tex")
	var img_tex: Texture2D = custom if custom != null else fm.remote_cursor_fallback_tex
	var img_size := img_tex.get_size()
	fm.remote_cursor_overlay.texture = img_tex
	var hotspot: Vector2 = fm.remote_cursor_state.get("hotspot", Vector2.ZERO)
	var px := float(fm.remote_cursor_state.get("x", 0.0))
	var py := float(fm.remote_cursor_state.get("y", 0.0))
	fm.remote_cursor_overlay.size = img_size * scale
	fm.remote_cursor_overlay.position = offset \
		+ Vector2(px / tex_size.x, py / tex_size.y) * displayed \
		- hotspot * scale
	fm.remote_cursor_overlay.visible = true

func _hide_remote_cursor() -> void:
	if fm.remote_cursor_overlay:
		fm.remote_cursor_overlay.visible = false

# Une fenêtre distante a été retirée (fermée par le joueur distant) : sortir
# du focus si c'était celle affichée.
func handle_remote_window_removed(peer_id: int, wid: int) -> void:
	if fm.remote_focus and fm.remote_focus_peer == peer_id and fm.remote_focus_wid == wid:
		fm.exit_focus()

# Un joueur distant s'est déconnecté / n'a plus de fenêtres : sortir du focus
# distant et retirer ses PiP s'il était affiché.
func handle_peer_removed(peer_id: int) -> void:
	if fm.remote_focus and fm.remote_focus_peer == peer_id:
		fm.exit_focus()
