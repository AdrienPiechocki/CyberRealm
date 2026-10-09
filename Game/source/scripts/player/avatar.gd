extends Node3D
## Avatar d'un autre joueur en LAN : représentation visuelle synchronisée
## en position/rotation par le lan_manager. Pas de collision.
## Transparence progressive sous 1 m du joueur local.

@export var pitch_treshold: float = 2.0
@export var pitch_pivot_path: NodePath = ^""

@export var lerp_speed := 15.0  ## Vitesse de lissage (10 à 20)

@export_group("Animations")
@export var anim_idle: StringName = &""
@export var anim_walk: StringName = &""
@export var anim_jump: StringName = &""
@export var walk_speed_threshold := 0.1

var peer_id := 0
var player_name := ""
var local_player: CharacterBody3D = null

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0
var _has_received_first_transform := false

const FADE_DISTANCE := 2.0

var _mesh_mats: Array[StandardMaterial3D] = []
var _color_tint_mats: Array[StandardMaterial3D] = []
var _label: Label3D = null
var _anim_player: AnimationPlayer = null
var _pitch_pivot: Node3D = null
var _prev_pos := Vector3.ZERO
var _is_grounded := true
var _current_anim: StringName = &""
var _prewarm_ready := false
var _prewarming := false
var _arrived := false

# Suivi du sol mobile (plateforme / bateau)
var _last_ground_collider: Node3D = null
var _last_ground_transform := Transform3D.IDENTITY


func setup(id: int, pname: String, color: Color) -> void:
	peer_id = id
	player_name = pname
	visible = false
	_color_tint_mats.clear()

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	for mi in meshes:
		if not mi.visible:
			continue
		if mi.material_override is StandardMaterial3D \
				and mi.material_override in _color_tint_mats:
			(mi.material_override as StandardMaterial3D).albedo_color = color
			continue
		_duplicate_material_for_fade(mi)
		var has_any_mat := false
		if mi.mesh != null:
			for j in mi.mesh.get_surface_count():
				if mi.get_surface_override_material(j) != null or \
						mi.mesh.surface_get_material(j) != null:
					has_any_mat = true
					break
		if not has_any_mat and mi.material_override == null:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			mi.material_override = mat
			_color_tint_mats.append(mat)

	# Label du nom
	_label = _find_label(self)
	if _label == null:
		_label = Label3D.new()
		_label.name = "NameLabel"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.font_size = 48
		_label.outline_size = 6
		_label.position = Vector3(0, 1.8, 0)
		add_child(_label)
	_label.text = pname
	_label.no_depth_test = true
	_label.render_priority = 100
	_label.outline_render_priority = 99

	# AnimationPlayer
	if anim_idle != &"" or anim_walk != &"" or anim_jump != &"":
		_anim_player = _find_anim_player(self)
		if _anim_player == null:
			_anim_player = AnimationPlayer.new()
			_anim_player.name = "AnimationPlayer"
			add_child(_anim_player)

	# Pivot du pitch
	_pitch_pivot = null
	if not pitch_pivot_path.is_empty():
		_pitch_pivot = get_node_or_null(pitch_pivot_path) as Node3D

	_target_pos = position
	_target_yaw = rotation.y
	_prev_pos = position


func apply_transform(pos: Vector3, yaw: float, pitch: float) -> void:
	_target_pos = pos
	_target_yaw = yaw
	_target_pitch = pitch

	if not _has_received_first_transform:
		_has_received_first_transform = true
		global_position = _target_pos
		_prev_pos = _target_pos
		rotation.y = _target_yaw
		var pitch_node := _pitch_pivot if _pitch_pivot != null else self
		pitch_node.rotation.x = pitch


func _process(delta: float) -> void:
	if not _has_received_first_transform:
		return

	# 1. Détecter génériquement le sol sous l'avatar (Raycast physique)
	_apply_ground_carry()

	# 2. Lissage visuel vers la cible réseau
	var t := 1.0 - exp(-delta * lerp_speed)
	global_position = global_position.lerp(_target_pos, t)

	# 3. Lissage de la rotation du corps (Yaw)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)

	# 4. Lissage de la rotation de la tête (Pitch)
	var pitch_node := _pitch_pivot if _pitch_pivot != null else self
	pitch_node.rotation.x = lerp_angle(pitch_node.rotation.x, _target_pitch, t)

	# 5. Mises à jour des animations et de la transparence
	_update_animation(delta)
	_update_transparency()
	_prev_pos = global_position


## Détecte si l'avatar est posé sur un objet 3D en mouvement et applique son déplacement.
func _apply_ground_carry() -> void:
	var world_space := get_world_3d().direct_space_state
	if world_space == null:
		return

	# Raycast de 1.5m vers le bas depuis la position actuelle
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 0.5, 0),
		global_position + Vector3(0, -1.0, 0)
	)
	var result := world_space.intersect_ray(query)

	if result.size() > 0 and result.collider is Node3D:
		var current_ground: Node3D = result.collider
		var current_transform := current_ground.global_transform

		# Si on est toujours sur le même sol qu'à la frame précédente
		if current_ground == _last_ground_collider and is_instance_valid(_last_ground_collider):
			var ground_motion := current_transform * _last_ground_transform.affine_inverse()
			# Entraîner la position actuelle ET la position cible réseau
			global_position = ground_motion * global_position
			_target_pos = ground_motion * _target_pos

		_last_ground_collider = current_ground
		_last_ground_transform = current_transform
	else:
		_last_ground_collider = null


func _update_animation(delta: float) -> void:
	if _anim_player == null:
		return
	var vel := global_position - _prev_pos
	var speed_h = Vector2(vel.x, vel.z).length() / maxf(delta, 0.001)
	var speed_v = vel.y / maxf(delta, 0.001)
	_is_grounded = absf(speed_v) < 1.0
	
	var target: StringName = &""
	if not _is_grounded and anim_jump != &"":
		target = anim_jump
	elif speed_h > walk_speed_threshold and anim_walk != &"":
		target = anim_walk
	elif anim_idle != &"":
		target = anim_idle

	if target != &"" and target != _current_anim:
		_anim_player.play(target)
		_current_anim = target


func _update_transparency() -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var dist := global_position.distance_to(local_player.global_position) - 1.0
	var alpha := clampf(dist / FADE_DISTANCE, 0.0, 1.0)
	for mat in _mesh_mats:
		if mat != null and is_instance_valid(mat):
			mat.albedo_color.a = alpha
	for mat in _color_tint_mats:
		if mat != null and is_instance_valid(mat):
			mat.albedo_color.a = alpha


func start_prewarm() -> void:
	if _prewarm_ready:
		_update_visible()
		return
	if _prewarming:
		return
	_prewarming = true
	await _prewarm_gpu()
	_prewarm_ready = true
	_prewarming = false
	_update_visible()


func set_arrived(arrived: bool) -> void:
	_arrived = arrived
	_update_visible()


func _update_visible() -> void:
	visible = _prewarm_ready and _arrived


func _prewarm_gpu() -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	if meshes.is_empty():
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.transparent_bg = true
	get_tree().root.add_child(vp)
	var cam := Camera3D.new()
	cam.current = true
	cam.look_at_from_position(Vector3(0.0, 1.0, 5.0), Vector3(0.0, 1.0, 0.0))
	vp.add_child(cam)
	var we := _find_world_environment()
	if we != null:
		var env_node := WorldEnvironment.new()
		env_node.name = "PrewarmEnvironment"
		env_node.environment = we.environment.duplicate(true)
		vp.add_child(env_node)
	var light := DirectionalLight3D.new()
	light.shadow_enabled = true
	light.look_at_from_position(Vector3(2.0, 5.0, 3.0), Vector3(0.0, 1.0, 0.0))
	vp.add_child(light)
	var skel := _find_skeleton(self)
	var skel_holder: Skeleton3D = null
	if skel != null:
		skel_holder = Skeleton3D.new()
		skel_holder.name = "PrewarmSkeleton"
		for b in skel.get_bone_count():
			skel_holder.add_bone(skel.get_bone_name(b))
			skel_holder.set_bone_rest(b, skel.get_bone_rest(b))
		vp.add_child(skel_holder)
	var i := 0
	for mi in meshes:
		if mi.mesh == null:
			continue
		var h := MeshInstance3D.new()
		h.name = "Prewarm%d" % i
		i += 1
		h.mesh = mi.mesh
		if mi.material_override != null:
			h.material_override = mi.material_override
		for s in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(s)
			if m != null:
				h.set_surface_override_material(s, m)
		h.position = Vector3((i % 5) * 0.8, 1.0, 0.0)
		vp.add_child(h)
		if skel_holder != null:
			h.skeleton = h.get_path_to(skel_holder)
	visible = false
	for _f in 3:
		await get_tree().process_frame
	if is_instance_valid(vp):
		vp.queue_free()


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_world_environment() -> WorldEnvironment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _search_world_environment(scene)


func _search_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var found := _search_world_environment(child)
		if found != null:
			return found
	return null


func _find_label(node: Node) -> Label3D:
	if node is Label3D and node.name == "NameLabel":
		return node as Label3D
	for child in node.get_children():
		var found := _find_label(child)
		if found != null:
			return found
	return null


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found != null:
			return found
	return null


func _duplicate_material_for_fade(mi: MeshInstance3D) -> void:
	if mi.mesh == null or mi.material_override != null:
		return
	for s in mi.mesh.get_surface_count():
		var mat: Material = mi.get_surface_override_material(s)
		if mat == null:
			mat = mi.mesh.surface_get_material(s)
		if mat == null or not mat is BaseMaterial3D:
			continue
		var dup: BaseMaterial3D = (mat as BaseMaterial3D).duplicate()
		if dup.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		mi.set_surface_override_material(s, dup)
		_mesh_mats.append(dup)


func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_meshes(child, result)
