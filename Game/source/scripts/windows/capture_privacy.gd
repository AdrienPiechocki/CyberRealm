extends Node
## Fenêtres privées : visibles pour le joueur, noires dans le partage d'écran.
##
## Super+Ctrl+H (action `private_window`) bascule la fenêtre visée ou focalisée. Une fenêtre privée :
##  - est recouverte d'un aplat noir opaque dans l'image présentée à l'output headless, celle que copient
##    OBS et Discord quand ils partagent « l'écran » (present_manager.gd → set_capture_masks). Sont masqués :
##    le quad 3D avec son décor et ses popups, son overlay et sa barre en mode focus, ses popups en mode
##    focus, son PiP épinglé et l'aperçu du menu des fenêtres ;
##  - donne une image noire à qui la capture directement (source « fenêtre » de portal-wlr) ;
##  - porte un cadenas devant son titre (barre du jeu, barre du mode focus).
## Le choix est mémorisé par app_id (user://private_apps.json) : toutes les fenêtres de l'app sont privées,
## à chaque session. Une fenêtre sans app_id reste privée jusqu'à sa fermeture seulement.
##
## Masque approximatif par construction : ce qui passe devant la fenêtre dans la scène est noirci aussi.
## La relecture du viewport a 1-2 frames de retard sur la caméra : le masque est l'union des zones de la frame
## courante et de la précédente, élargie de MASK_MARGIN_PX, pour qu'un mouvement rapide ne découvre pas un bord.

const SAVE_PATH := "user://private_apps.json"
const MASK_MARGIN_PX := 6.0

var compositor: Object = null
var win3d: Node = null
var focus: Node = null
var pins: Node = null
var window_menu: Node = null
var save_path := SAVE_PATH

var _apps: Dictionary = {}     # app_id -> true
var _prev: Array = []          # polygones de la frame précédente (pixels du viewport)

func setup(p_compositor: Object, p_win3d: Node, p_focus: Node, p_pins: Node, p_window_menu: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	pins = p_pins
	window_menu = p_window_menu
	_load()

func is_private(wid: int) -> bool:
	return win3d != null and win3d.is_window_private(wid)

func has_private() -> bool:
	return win3d != null and not win3d.window_private.is_empty()

## Bascule la fenêtre et mémorise le choix pour son app. Renvoie le nouvel état.
func toggle(wid: int) -> bool:
	var on := not is_private(wid)
	var app := _app_id(wid)
	if app != "":
		if on:
			_apps[app] = true
		else:
			_apps.erase(app)
		_save()
		# Toutes les fenêtres ouvertes de l'app suivent.
		for other: int in win3d.window_app_ids.keys():
			if str(win3d.window_app_ids[other]) == app:
				_apply_private(other, on)
	else:
		_apply_private(wid, on)
	return on

func on_window_created(id: int, _quad: Node) -> void:
	if _apps.has(_app_id(id)):
		_apply_private(id, true)

func _apply_private(wid: int, on: bool) -> void:
	win3d.set_window_private(wid, on)
	if compositor != null and compositor.has_method("set_window_capture_private"):
		compositor.set_window_capture_private(wid, on)
	if focus != null and focus.focus_title_bars.has(wid) and focus.titlebar != null:
		focus.titlebar._sync_title_bar(wid)

func _app_id(wid: int) -> String:
	return str(win3d.window_app_ids.get(wid, "")) if win3d != null else ""

# ─── Zones à noircir ───────────────────────────────────────────────────────────────────────────────────

## Polygones (pixels de la frame `frame_size`) à noircir dans la frame présentée : zones de cette frame et
## de la précédente, élargies de MASK_MARGIN_PX.
func mask_polygons(frame_size: Vector2) -> Array:
	var cur := _current_polygons() if has_private() else []
	var all: Array = cur + _prev
	_prev = cur
	var out: Array = []
	if all.is_empty():
		return out
	var vp_size := get_viewport().get_visible_rect().size
	var k := Vector2(frame_size.x / maxf(vp_size.x, 1.0), frame_size.y / maxf(vp_size.y, 1.0))
	for poly: PackedVector2Array in all:
		for grown: PackedVector2Array in Geometry2D.offset_polygon(poly, MASK_MARGIN_PX, Geometry2D.JOIN_MITER):
			var scaled := PackedVector2Array()
			for p in grown:
				scaled.append(p * k)
			out.append(scaled)
	return out

# Zones à l'écran (pixels du viewport) des fenêtres privées dans la frame courante.
func _current_polygons() -> Array:
	var out: Array = []
	var cam := get_viewport().get_camera_3d()
	for wid: int in win3d.window_private.keys():
		# Quad 3D, décor compris (barre de titre au-dessus, bordure autour).
		var quad = win3d.quads.get(wid)
		if quad != null and is_instance_valid(quad) and quad.is_visible_in_tree() and cam != null:
			var mesh := quad.mesh as QuadMesh
			if mesh != null:
				var deco: Dictionary = win3d.snap._deco_of(quad)
				var half: Vector2 = mesh.size * 0.5
				var b: float = deco.get("border", 0.0)
				var t: float = deco.get("titlebar", 0.0)
				_add_quad(out, cam, quad.global_transform,
					Rect2(-half.x - b, -half.y - b, mesh.size.x + 2.0 * b, mesh.size.y + b + t))
		# Popups 3D (menus) : quads enfants du quad de la fenêtre, éventuellement hors de son cadre.
		for pid in win3d.popup_quads.keys():
			var pq = win3d.popup_quads[pid]
			if pq == null or not is_instance_valid(pq) or not pq.is_visible_in_tree() or cam == null:
				continue
			if _popup_root(int(pid)) != wid:
				continue
			var pm := pq.mesh as QuadMesh
			if pm != null:
				_add_quad(out, cam, pq.global_transform, Rect2(-pm.size * 0.5, pm.size))
		# Mode focus : overlay, barre de titre, popups.
		if focus != null and focus.focus_mode:
			_add_control(out, focus.focus_rects.get(wid))
			_add_control(out, focus.focus_title_bars.get(wid))
			for pid in focus.focus_popup_rects.keys():
				if _popup_root(int(pid)) == wid:
					_add_control(out, focus.focus_popup_rects[pid])
		# PiP épinglé.
		if pins != null:
			_add_control(out, pins.pinned_windows.get(wid))
		# Aperçu du menu des fenêtres.
		if window_menu != null and window_menu.is_visible_in_tree() and int(window_menu.selected_window_id) == wid:
			_add_control(out, window_menu.preview_rect)
	return out

# Fenêtre racine d'un popup (les sous-menus pointent sur leur popup parent).
func _popup_root(pid: int) -> int:
	var guard := 0
	while guard < 32:
		var info: Dictionary = win3d.popup_parent_info.get(pid, {})
		if info.is_empty():
			return -1
		var parent_popup := int(info.get("parent_popup_id", -1))
		if parent_popup == -1:
			return int(info.get("parent_window_id", -1))
		pid = parent_popup
		guard += 1
	return -1

func _add_control(out: Array, c) -> void:
	if c == null or not is_instance_valid(c) or not (c is Control) or not c.is_visible_in_tree():
		return
	var r: Rect2 = c.get_global_rect()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	out.append(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]))

# Rectangle local (plan XY) d'un nœud 3D projeté à l'écran, découpé au plan proche de la caméra.
func _add_quad(out: Array, cam: Camera3D, xform: Transform3D, local: Rect2) -> void:
	var to_cam := cam.global_transform.affine_inverse() * xform
	var pts: Array[Vector3] = [
		to_cam * Vector3(local.position.x, local.position.y, 0.0),
		to_cam * Vector3(local.end.x, local.position.y, 0.0),
		to_cam * Vector3(local.end.x, local.end.y, 0.0),
		to_cam * Vector3(local.position.x, local.end.y, 0.0),
	]
	var clipped := clip_near(pts, -cam.near * 1.01)
	if clipped.size() < 3:
		return
	var poly := PackedVector2Array()
	for p in clipped:
		poly.append(cam.unproject_position(cam.global_transform * p))
	out.append(poly)

## Sutherland-Hodgman : garde la partie du polygone (repère caméra, -Z devant) telle que z <= z_max.
static func clip_near(pts: Array[Vector3], z_max: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var n := pts.size()
	for i in n:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % n]
		var a_in := a.z <= z_max
		var b_in := b.z <= z_max
		if a_in:
			out.append(a)
		if a_in != b_in:
			var t := (z_max - a.z) / (b.z - a.z)
			out.append(a.lerp(b, t))
	return out

# ─── Persistance ───────────────────────────────────────────────────────────────────────────────────────

func _load() -> void:
	_apps.clear()
	if not FileAccess.file_exists(save_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if data is Dictionary and data.get("apps") is Array:
		for app in data["apps"]:
			if str(app) != "":
				_apps[str(app)] = true

func _save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("capture_privacy: unable to write " + save_path)
		return
	f.store_string(JSON.stringify({"version": 1, "apps": _apps.keys()}, "\t"))
