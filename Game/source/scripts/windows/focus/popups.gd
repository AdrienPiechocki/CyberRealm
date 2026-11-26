extends Node
## Popups des fenêtres en mode focus : overlays, placement, routage du pointeur.
##
## Module de FocusMode (nœud enfant « Popups »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

func _compute_popup_layout(parent_window_id: int, parent_popup_id: int) -> Dictionary:
	"""Scale/offset du popup dans l'espace écran du mode focus."""
	if parent_popup_id != -1 and fm.focus_popup_rects.has(parent_popup_id):
		var parent_rect: TextureRect = fm.focus_popup_rects[parent_popup_id]
		var p_content: Vector2 = parent_rect.get_meta("content_size", parent_rect.size)
		return {
			"scale": Vector2(
				parent_rect.size.x / max(p_content.x, 1.0),
				parent_rect.size.y / max(p_content.y, 1.0)),
			"offset": parent_rect.position,
		}
	elif fm.focus_mode and (parent_window_id == fm._active_id() or fm._is_stack_base(parent_window_id)):
		return fm._compute_focus_displayed_info(parent_window_id)
	return {}

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
	mat.shader = fm.popup_crop_shader
	mat.set_shader_parameter("content_size", Vector2(pw, ph))
	popup_tex_rect.material = mat

	popup_tex_rect.size = Vector2(pw, ph) * popup_scale
	popup_tex_rect.position = popup_offset + Vector2(x, y) * popup_scale
	popup_tex_rect.z_index = FocusMode.FOCUS_POPUP_Z
	popup_tex_rect.set_meta("content_size", Vector2(pw, ph))
	fm.ui.add_child(popup_tex_rect)
	fm.focus_popup_rects[popup_id] = popup_tex_rect

	# Appliquer la texture disponible dès maintenant
	if fm.windows.popup_quads.has(popup_id) and is_instance_valid(fm.windows.popup_quads[popup_id]):
		var quad: MeshInstance3D = fm.windows.popup_quads[popup_id]
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
	for popup_id in fm.focus_popup_rects:
		var popup_rect: TextureRect = fm.focus_popup_rects[popup_id]
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
	# L'overlay est recadré sur la window_geometry du popup : ajouter son
	# décalage dans la surface (marge d'ombre GTK) pour obtenir des
	# coordonnées surface correctes côté client.
	var pgeo: Dictionary = fm.compositor.get_popup_geometry(popup_id)
	px += float(pgeo.get("x", 0))
	py += float(pgeo.get("y", 0))
	if not fm.input._popup_motion_is_duplicate(popup_id, Vector2(px, py)):
		fm.compositor.forward_pointer_motion_popup(popup_id, px, py)
	# Grab bouton pour le drag-and-drop : mémoriser le popup qui reçoit un
	# appui et compter les boutons enfoncés, pour router vers lui tant que le
	# drag est actif même hors de ses bords (voir handle_focus_input).
	var press_left := fm.input._left_press_this_frame()
	var release_left := fm.input._left_release_this_frame()
	var press_right := fm.input._click_action_just_pressed("right_click")
	var release_right := fm.input._click_action_just_released("right_click")
	var press_middle := fm.input._click_action_just_pressed("middle_click")
	var release_middle := fm.input._click_action_just_released("middle_click")
	if press_left or press_right or press_middle:
		fm.popup_buttons_down += 1
		fm.popup_drag_id = popup_id
	if release_left or release_right or release_middle:
		fm.popup_buttons_down = maxi(fm.popup_buttons_down - 1, 0)
		if fm.popup_buttons_down == 0:
			fm.popup_drag_id = -1
	if press_left:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x110, true)
	if release_left:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x110, false)
	if press_right:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x111, true)
	if release_right:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x111, false)
	if press_middle:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x112, true)
	if release_middle:
		fm.compositor.forward_pointer_button_popup(popup_id, 0x112, false)

func _clear_popup_overlays() -> void:
	for popup_id in fm.focus_popup_rects:
		if is_instance_valid(fm.focus_popup_rects[popup_id]):
			fm.focus_popup_rects[popup_id].queue_free()
	fm.focus_popup_rects.clear()

# Recrée les overlays de popups de la fenêtre active : positions recalculées
# depuis le rect courant du parent (appelé après un déplacement).
func _refresh_popups() -> void:
	var active := fm._active_id()
	_clear_popup_overlays()
	for popup_id in fm.windows.popup_parent_info:
		var pinfo = fm.windows.popup_parent_info[popup_id]
		if pinfo.parent_window_id == active \
			or fm._is_stack_base(pinfo.parent_window_id) or \
			(pinfo.parent_popup_id != -1 and fm.focus_popup_rects.has(pinfo.parent_popup_id)):
			_create_popup_overlay(popup_id, pinfo.parent_window_id, pinfo.parent_popup_id,
				pinfo.x, pinfo.y, pinfo.width, pinfo.height)
