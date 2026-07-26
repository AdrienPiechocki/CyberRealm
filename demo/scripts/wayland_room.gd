extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".

@onready var compositor: WlrCompositor = $WlrCompositor
var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune
var interact_mode_active := false

var resizing_edge := "" # "left", "right", "top", "bottom", "topleft", etc.
var is_resizing := false
var is_moving := false
var active_window_id := -1
var is_in_window := false
# Déplacement: distance (caméra -> fenêtre) figée au moment du grab, la
# fenêtre suit ensuite le viseur le long de ce rayon.
var move_depth := 0.0

var is_moving_2d := false
var move_2d_plane := Plane()
var move_2d_offset := Vector3.ZERO

# Redimensionnement: même principe de rayon à profondeur fixe, mais on
# garde aussi la base locale du quad et ses dimensions de départ pour
# convertir le déplacement du viseur (unités monde) en pixels de surface.
var resize_depth := 0.0
var resize_start_world := Vector3.ZERO
var resize_right_dir := Vector3.RIGHT
var resize_up_dir := Vector3.UP
var window_start_size := Vector2.ZERO # taille surface (px) au moment du grab
var window_start_mesh_size := Vector2.ONE # taille quad (unités monde) au moment du grab
var window_start_local_pos := Vector3.ZERO # position locale du quad au moment du grab

const BORDER_MARGIN = 5 # en pixels sur la texture, zone de bord = redimensionnement
const MIN_SURFACE_SIZE = 500 # px, garde-fou anti-fenêtre-écrasée

func _ready() -> void:
	compositor.window_mapped.connect(_on_window_mapped)
	compositor.window_unmapped.connect(_on_window_unmapped)
	compositor.window_texture_updated.connect(_on_texture_updated)
	compositor.popup_mapped.connect(_on_popup_mapped)
	compositor.popup_unmapped.connect(_on_popup_unmapped)
	compositor.popup_texture_updated.connect(_on_popup_texture_updated)
	compositor.start_headless()
	compositor.launch_app("xwayland-satellite :1")
	await get_tree().create_timer(0.2).timeout
	compositor.set_x11_display(":1")
	# Décale WAYLAND_DISPLAY pour tout ce qu'on lance nous-mêmes ensuite.
	#print("Socket Wayland: ", compositor.get_wayland_socket_name())

func spawn_test_client() -> void:
	compositor.launch_app("konsole")

func next_spawn_pos() -> Vector3:
	var camera := $Player/Camera3D
	return camera.global_position - camera.global_basis.z * 3.0

func _on_window_mapped(id: int, _title: String, _app_id: String) -> void:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.6, 1.0) # ratio ajusté au premier texture_updated
	quad.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material_override = mat

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.05)
	col.shape = shape
	body.add_child(col)
	body.set_meta("window_id", id)
	quad.add_child(body)

	add_child(quad)
	quads[id] = quad
	quad.global_position = next_spawn_pos()
	var camera := $Player/Camera3D

	quad.global_transform = Transform3D(
		camera.global_transform.basis,
		quad.global_position
	)
	
	#print("Fenêtre mappée: ", title, " (", app_id, ") id=", id)

func _on_window_unmapped(id: int) -> void:
	if focused_window_id == id:
		focused_window_id = -1
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			quad.queue_free()
		quads.erase(id)

func _on_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	(quad.material_override as StandardMaterial3D).albedo_texture = texture

	# Garde le ratio d'aspect réel de la fenêtre.
	var aspect := float(width) / float(max(height, 1))
	var h := 3.0 # hauteur du quad dans le monde 3D (mètres) - ajustez selon l'échelle de votre scène
	var mesh: QuadMesh = quad.mesh
	mesh.size = Vector2(h * aspect, h)

	var body: StaticBody3D = quad.get_child(0)
	body.set_meta("surface_size", Vector2(width, height))

	# La CollisionShape3D doit suivre la même taille que le mesh, sinon le
	# raycast teste une zone qui ne correspond plus à ce qui est affiché.
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

func _on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	var parent_quad: MeshInstance3D = null
	var parent_px_size := Vector2(1, 1)

	if parent_popup_id != -1 and popup_quads.has(parent_popup_id) and is_instance_valid(popup_quads[parent_popup_id]):
		# Sous-menu: parenté sur le popup qui l'a ouvert, pas sur la fenêtre racine.
		parent_quad = popup_quads[parent_popup_id]
		parent_px_size = parent_quad.get_meta("surface_size", Vector2(1, 1))
	elif quads.has(parent_window_id) and is_instance_valid(quads[parent_window_id]):
		parent_quad = quads[parent_window_id]
		var parent_body: StaticBody3D = parent_quad.get_child(0)
		parent_px_size = parent_body.get_meta("surface_size", Vector2(1, 1))

	if parent_quad == null:
		return

	var parent_mesh: QuadMesh = parent_quad.mesh

	# Conversion pixels -> mètres, en réutilisant l'échelle déjà connue du
	# parent immédiat (mêmes unités que sa propre capture de texture).
	var _scale := Vector2(
		parent_mesh.size.x / max(parent_px_size.x, 1.0),
		parent_mesh.size.y / max(parent_px_size.y, 1.0)
	)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(max(width * _scale.x, 0.01), max(height * _scale.y, 0.01))
	quad.mesh = mesh
	# Mémorisé pour qu'un éventuel sous-sous-menu puisse recalculer son
	# échelle à partir de CE popup plutôt que de la fenêtre racine, et pour
	# que _on_popup_texture_updated puisse redimensionner le mesh sur la
	# même base quand le buffer réel (potentiellement plus grand que la
	# géométrie logique ci-dessus) arrive.
	quad.set_meta("surface_size", Vector2(width, height))
	quad.set_meta("px_scale", _scale)

	# (x, y) = coin haut-gauche du popup relatif au coin haut-gauche de la
	# géométrie du parent immédiat. Le quad parent est centré sur son
	# origine locale, d'où le décalage de -size/2 pour repartir du vrai
	# coin haut-gauche.
	var local_left := -parent_mesh.size.x / 2.0 + x * _scale.x
	var local_top := parent_mesh.size.y / 2.0 - y * _scale.y
	quad.position = Vector3(
		local_left + mesh.size.x / 2.0,
		local_top - mesh.size.y / 2.0,
		0.02 # léger décalage devant le parent pour éviter le z-fighting
	)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material_override = mat

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.05)
	col.shape = shape
	body.add_child(col)
	body.set_meta("popup_id", id)
	body.set_meta("surface_size", Vector2(width, height))
	quad.add_child(body)

	parent_quad.add_child(quad)
	popup_quads[id] = quad

func _on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)

func _on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not popup_quads.has(id) or not is_instance_valid(popup_quads[id]):
		return
	var quad: MeshInstance3D = popup_quads[id]
	(quad.material_override as StandardMaterial3D).albedo_texture = texture

	# popup_mapped donne la géométrie logique (xdg_surface.set_window_geometry),
	# utilisée uniquement pour le placement relatif au parent. Le buffer
	# réellement capturé ici peut être plus grand (marge d'ombre ajoutée par
	# le client, GTK/Qt notamment) - sans cette resynchronisation, le hover
	# convertissait les uv avec l'échelle de la géométrie logique au lieu de
	# celle du buffer affiché, envoyant des coordonnées fausses au client.
	var mesh: QuadMesh = quad.mesh
	var old_size := mesh.size
	var aspect := float(width) / float(max(height, 1))
	mesh.size = Vector2(old_size.y * aspect, old_size.y) if old_size.y > 0.0 else Vector2(1, 1)

	var body: StaticBody3D = quad.get_child(0)
	body.set_meta("surface_size", Vector2(width, height))
	quad.set_meta("surface_size", Vector2(width, height)) # utilisé par un éventuel sous-menu

	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

# La fenêtre glisse le long de son propre plan d'orientation initial.
func _update_move_2d(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
		
	var quad: MeshInstance3D = quads[active_window_id]
	var hit = move_2d_plane.intersects_ray(ray_origin, ray_dir)
	
	if hit != null:
		var target_pos = hit + move_2d_offset
		# Déplacement fluide uniquement sur les axes X/Y locaux du plan
		quad.global_position = quad.global_position.lerp(target_pos, 15.0 * delta)

func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("launcher") and not interact_mode_active:
		spawn_test_client()

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	if Input.is_action_just_pressed("interact_mode"):
		interact_mode_active = not interact_mode_active
		$Player.interact_mode_active = not $Player.interact_mode_active

	var cam: Camera3D = $Player/Camera3D
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := cam.project_ray_origin(mouse_pos)
	var ray_dir := cam.project_ray_normal(mouse_pos)

	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if is_moving:
		if Input.is_action_just_pressed("scroll_up"):
			move_depth += 0.25
		if Input.is_action_just_pressed("scroll_down"):
			move_depth -= 0.25
		_update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab"):
			is_moving = false
			active_window_id = -1
		return
	if is_resizing:
		_update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click"):
			is_resizing = false
			resizing_edge = ""
			active_window_id = -1
		return
	if is_moving_2d:
		_update_move_2d(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("left_click"):
			is_moving_2d = false
			active_window_id = -1
		return
	
	var to := ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	var hit := space.intersect_ray(params)

	if hit.is_empty():
		is_in_window = false
		compositor.forward_pointer_leave()
		return

	var body: Node3D = hit.collider

	if body.has_meta("popup_id"):
		is_in_window = true
		_handle_popup_pointer(body, hit)
		return

	if not body.has_meta("window_id"):
		is_in_window = false
		compositor.forward_pointer_leave()
		return
	else:
		is_in_window = true
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh

	var local := quad.to_local(hit.position)
	var uv := Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)
	var wid: int = body.get_meta("window_id")
	compositor.forward_pointer_motion(wid, uv.x * win_size.x, uv.y * win_size.y)

	if Input.is_action_just_pressed("grab") and not interact_mode_active:
		active_window_id = wid
		is_moving = true
		move_depth = cam.global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab"):
		active_window_id = wid
		is_moving = false
		move_depth = 0.0
	if Input.is_action_just_pressed("left_click"):
		focused_window_id = wid
		var edge := _border_edge(uv, win_size)
		if edge != "":
			# Bord de la fenêtre -> redimensionnement.
			active_window_id = wid
			resizing_edge = edge
			is_resizing = true
			resize_depth = cam.global_position.distance_to(quad.global_position)
			resize_start_world = ray_origin + ray_dir * resize_depth
			resize_right_dir = quad.global_transform.basis.x.normalized()
			resize_up_dir = quad.global_transform.basis.y.normalized()
			window_start_size = win_size
			window_start_mesh_size = mesh.size
			window_start_local_pos = quad.position
		
		elif uv.y * win_size.y < BORDER_MARGIN * BORDER_MARGIN and not uv.x * win_size.x > win_size.x - 75 and not uv.x * win_size.x < 75:
			# Move on a 2D plane (simulation de barre de titre)
			active_window_id = wid
			is_moving_2d = true
			
			# On crée un plan infini basé sur l'orientation de la fenêtre (axe Z)
			var normal = quad.global_transform.basis.z.normalized()
			move_2d_plane = Plane(normal, quad.global_position)
			
			# Calcul de l'offset initial pour éviter que la fenêtre "saute" au centre du curseur
			var _hit = move_2d_plane.intersects_ray(ray_origin, ray_dir)
			if _hit != null:
				move_2d_offset = quad.global_position - _hit
		
		else:
			compositor.forward_pointer_button(wid, 0x110, true) # BTN_LEFT (evdev)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(wid, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(wid, 0, 50.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh

	var local := quad.to_local(hit.position)
	var uv := Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)
	var pid: int = body.get_meta("popup_id")
	compositor.forward_pointer_motion_popup(pid, uv.x * win_size.x, uv.y * win_size.y)

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button_popup(pid, 0x110, false)

# Bord touché (marge en pixels de texture) -> "" si le clic est dans le
# corps de la fenêtre.
func _border_edge(uv: Vector2, win_size: Vector2) -> String:
	var px := uv.x * win_size.x
	var py := uv.y * win_size.y
	var edge := ""
	if py < BORDER_MARGIN:
		edge += "top"
	elif py > win_size.y - BORDER_MARGIN:
		edge += "bottom"
	if px < BORDER_MARGIN:
		edge += "left"
	elif px > win_size.x - BORDER_MARGIN:
		edge += "right"
	return edge

# La fenêtre suit le viseur le long du rayon caméra, à profondeur figée
# (distance capturée au moment du grab) - fonctionne même si la souris ne
# se déplace jamais à l'écran (mode capturé), puisque seule l'orientation
# de la caméra entre ici en jeu.
func _update_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var cam: Camera3D = $Player/Camera3D
	var target_pos = ray_origin + ray_dir * move_depth
	# Déplacement fluide
	quad.global_position = quad.global_position.lerp(
		target_pos,
		10.0 * delta
	)
	# Rotation
	quad.global_basis = cam.global_basis

func _update_resize(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var _mesh: QuadMesh = quad.mesh

	# Delta du viseur (unités monde) projeté sur la même profondeur figée
	# qu'au moment du grab, puis exprimé dans la base locale du quad.
	var cur_world := ray_origin + ray_dir * resize_depth
	var world_delta := cur_world - resize_start_world
	var local_dx := world_delta.dot(resize_right_dir)
	var local_dy := world_delta.dot(resize_up_dir)

	# Ratio pixels de surface / unité monde, figé au grab (le mesh ne
	# change pas de taille pendant le drag, seul window_texture_updated
	# le fera une fois le client redessiné à la nouvelle taille).
	var px_per_unit_x: float = window_start_size.x / max(window_start_mesh_size.x, 0.001)
	var px_per_unit_y: float = window_start_size.y / max(window_start_mesh_size.y, 0.001)

	var new_w := window_start_size.x
	var new_h := window_start_size.y
	if "right" in resizing_edge:
		new_w = window_start_size.x + local_dx * px_per_unit_x
	elif "left" in resizing_edge:
		new_w = window_start_size.x - local_dx * px_per_unit_x
	if "top" in resizing_edge:
		new_h = window_start_size.y + local_dy * px_per_unit_y
	elif "bottom" in resizing_edge:
		new_h = window_start_size.y - local_dy * px_per_unit_y

	new_w = max(new_w, MIN_SURFACE_SIZE)
	new_h = max(new_h, MIN_SURFACE_SIZE)

	compositor.set_window_size(active_window_id, int(new_w), int(new_h))

	# Repositionne tout de suite le bord fixe pour un retour visuel fluide;
	# le ratio/la taille définitifs du quad arrivent via
	# window_texture_updated une fois que le client a recommité à la
	# nouvelle taille.
	var delta_w_world := (new_w - window_start_size.x) / px_per_unit_x
	var delta_h_world := (new_h - window_start_size.y) / px_per_unit_y
	var shift := Vector3.ZERO
	if "left" in resizing_edge:
		shift -= resize_right_dir * (delta_w_world / 2.0)
	elif "right" in resizing_edge:
		shift += resize_right_dir * (delta_w_world / 2.0)
	if "top" in resizing_edge:
		shift += resize_up_dir * (delta_h_world / 2.0)
	elif "bottom" in resizing_edge:
		shift -= resize_up_dir * (delta_h_world / 2.0)
	quad.position = window_start_local_pos + shift

func _unhandled_key_input(event: InputEvent) -> void:
	if focused_window_id == -1 or not event is InputEventKey or not interact_mode_active:
		return
	var key_event := event as InputEventKey
	compositor.forward_keyboard_key(key_event.physical_keycode, key_event.location, key_event.pressed)
	get_viewport().set_input_as_handled()
