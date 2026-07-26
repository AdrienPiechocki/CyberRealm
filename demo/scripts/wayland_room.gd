extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".

@onready var compositor: WlrCompositor = $WlrCompositor
var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune
var interact_mode_active := false

var resizing_edge = "" # "left", "right", "top", "bottom", etc.
var is_resizing = false
var is_moving = false
var active_window_id = -1
var mouse_start_pos = Vector2.ZERO
var window_start_size = Vector2.ZERO
var window_start_pos3d = Vector3.ZERO

const BORDER_MARGIN = 15 # en pixels sur la texture

func _ready() -> void:
	compositor.window_mapped.connect(_on_window_mapped)
	compositor.window_unmapped.connect(_on_window_unmapped)
	compositor.window_texture_updated.connect(_on_texture_updated)
	compositor.popup_mapped.connect(_on_popup_mapped)
	compositor.popup_unmapped.connect(_on_popup_unmapped)
	compositor.popup_texture_updated.connect(_on_popup_texture_updated)
	compositor.start_headless()

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
	# échelle à partir de CE popup plutôt que de la fenêtre racine.
	quad.set_meta("surface_size", Vector2(width, height))

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

	# Pas de collision pour l'instant: cliquer un item de menu demanderait
	# de router les coordonnées à travers la hiérarchie popup -> parent,
	# pas encore géré. Le popup s'affiche mais n'est pas interactif.
	parent_quad.add_child(quad)
	popup_quads[id] = quad

func _on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)

func _on_popup_texture_updated(id: int, texture: Texture2D, _width: int, _height: int) -> void:
	if not popup_quads.has(id) or not is_instance_valid(popup_quads[id]):
		return
	var quad: MeshInstance3D = popup_quads[id]
	(quad.material_override as StandardMaterial3D).albedo_texture = texture

func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("launcher") and not interact_mode_active:
		spawn_test_client()

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	if Input.is_action_just_pressed("interact_mode"):
		interact_mode_active = not interact_mode_active
		$Player.interact_mode_active = not $Player.interact_mode_active
		
	var cam: Camera3D = $Player/Camera3D
	var mouse_pos := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mouse_pos)
	var to := from + cam.project_ray_normal(mouse_pos) * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, to)
	var hit := space.intersect_ray(params)

	if hit.is_empty() or not hit.collider.has_meta("window_id"):
		#if hit.is_empty():
			#print("PlasmaCraft debug: raycast à vide - rien touché depuis ", from, " direction ", -cam.global_transform.basis.z)
		#else:
			#print("PlasmaCraft debug: raycast a touché ", hit.collider.name, " (pas une fenêtre)")
		compositor.forward_pointer_leave()
		return

	var body: StaticBody3D = hit.collider
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

	if Input.is_action_just_pressed("left_click"):
		#print("PlasmaCraft debug: clic forwardé vers fenêtre id=", wid, " uv=", uv)
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x110, true) # BTN_LEFT (evdev)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		#print("PlasmaCraft debug: clic droit forwardé vers fenêtre id=", wid)
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(wid, 0, -50.0) 
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(wid, 0, 50.0)

func _unhandled_key_input(event: InputEvent) -> void:
	if focused_window_id == -1 or not event is InputEventKey or not interact_mode_active:
		return
	var key_event := event as InputEventKey
	#print("PlasmaCraft debug: touche reçue physical_keycode=", key_event.physical_keycode, " pressed=", key_event.pressed, " -> fenêtre id=", focused_window_id)
	compositor.forward_keyboard_key(key_event.physical_keycode, key_event.pressed)
	get_viewport().set_input_as_handled()

func _on_mouse_down_on_window(window_id, local_uv_position, texture_size):
	active_window_id = window_id
	
	# 1. Vérifier si on est sur un bord pour redimensionner
	var px = local_uv_position.x * texture_size.x
	var py = local_uv_position.y * texture_size.y
	
	var on_left = px < BORDER_MARGIN
	var on_right = px > texture_size.x - BORDER_MARGIN
	var on_top = py < BORDER_MARGIN
	var on_bottom = py > texture_size.y - BORDER_MARGIN
	
	if on_left or on_right or on_top or on_bottom:
		is_resizing = true
		# Déterminer la combinaison (ex: "bottom-right")
		resizing_edge = ""
		if on_top: resizing_edge += "top"
		elif on_bottom: resizing_edge += "bottom"
		if on_left: resizing_edge += "left"
		elif on_right: resizing_edge += "right"
		
		mouse_start_pos = get_viewport().get_mouse_position()
		window_start_size = texture_size
	else:
		# Sinon, c'est un déplacement de fenêtre (ou clic normal transmis au pointer)
		is_moving = true 
		# ... logique de déplacement 3D de ton quad ...

func _input(event):
	if event is InputEventMouseMotion:
		if is_resizing and active_window_id != -1:
			var mouse_delta = get_viewport().get_mouse_position() - mouse_start_pos
			var new_w = window_start_size.x
			var new_h = window_start_size.y
			
			# Ajuster la largeur/hauteur selon le bord attrapé
			if "right" in resizing_edge:
				new_w += mouse_delta.x
			if "bottom" in resizing_edge:
				new_h += mouse_delta.y
			if "left" in resizing_edge:
				new_w -= mouse_delta.x
				# Note: si on redimensionne par la gauche, il faut aussi bouger la position 3D du quad
			
			# Appeler la méthode C++ qu'on vient de créer
			compositor.set_window_size(active_window_id, int(new_w), int(new_h))
			
		elif is_moving:
			# Met à jour la position 3D de ton mesh en fonction du mouvement de la souris
			pass
			
	elif event is InputEventMouseButton:
		if not event.pressed:
			is_resizing = false
			is_moving = false
			active_window_id = -1
