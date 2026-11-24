extends Node3D
## Avatar d'un autre joueur en LAN : représentation visuelle synchronisée
## en position/rotation par le lan_manager. Pas de collision.
## Transparence progressive sous 1 m du joueur local.

@export_range(-1.0, 1.0) var pitch_scale: float = 0.4  ## Amplitude du pitch de l'avatar (1 = pitch complet de la caméra). Négatif : inverse le sens (os de tête orienté à l'envers)
@export var pitch_pivot_path: NodePath = ^""

@export var lerp_speed := 15.0  ## Vitesse de lissage (10 à 20)

@export_group("First person")
## Vue 1ère personne : le joueur voit son propre corps, tête cachée (os de tête réduit à zéro).
@export var fullbody_enabled := true
## Nom de l'os de la tête. Vide = détection automatique (premier os dont le nom contient « head »).
@export var fps_head_bone: StringName = &""
## Recul du corps par rapport à la caméra en 1ère personne (m), pour ne pas voir l'intérieur du cou/des épaules.
@export var fps_back_offset := 0.12
## Hauteur des yeux au-dessus de l'origine de l'os de la tête (m, avant échelle) : la caméra 1ère personne se place là.
@export var fps_eye_offset := 0.08

@export_group("Animations")
@export var anim_idle: StringName = &""
@export var anim_walk: StringName = &""
@export var anim_jump: StringName = &""
@export var walk_speed_threshold := 0.1
## Supprime le déplacement du « root motion » de l'animation de marche (certains exports la font avancer l'avatar
## de plusieurs mètres par boucle : il glisse puis retombe au point de départ). Le sur-place laisse le joueur
## porter le déplacement.
@export var walk_in_place := true
## Déplacement horizontal minimal (unités de l'animation) entre première et dernière clé pour qu'une piste de
## position soit considérée comme du root motion.
@export var root_motion_threshold := 0.2

## Avatar local (enfant du joueur, ex. free-cam) : jamais d'apply_transform ;
## le pose suit le parent et la vitesse est déduite du déplacement global.
var follow_parent := false
var _pitch_cam: Camera3D = null

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

# Vue 1ère personne (corps du joueur local)
const HeadHiderScript := preload("res://scripts/player/head_hider.gd")
const HEAD_MESH_WORDS := ["head", "helm", "hair", "hat", "hood", "face", "mask", "brow", "beard"]
var _fp := false
var _fp_ready := false
var _fp_supported := false
var _head_hider: SkeletonModifier3D = null
var _head_meshes: Array[MeshInstance3D] = []
var _suppressed := false

# Suivi du sol mobile (plateforme / bateau)
var _last_ground_collider: Node3D = null
var _last_ground_transform := Transform3D.IDENTITY

func _ready() -> void:
	process_physics_priority = 0

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
	# Masquage par toggle_ui (option « toggle_ui hides player names ») :
	# wayland_room pilote le groupe et le meta Engine pour les avatars créés
	# pendant que l'UI est masquée.
	_label.add_to_group("avatar_name_label")
	_label.visible = not bool(Engine.get_meta("hide_avatar_names", false))
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
		if walk_in_place and anim_walk != &"" and _anim_player.has_animation(anim_walk):
			_strip_root_motion(_anim_player.get_animation(anim_walk))

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
	_target_pitch = pitch * pitch_scale

	if not _has_received_first_transform:
		_has_received_first_transform = true
		global_position = _target_pos
		_prev_pos = _target_pos
		rotation.y = _target_yaw
		var pitch_node := _pitch_pivot if _pitch_pivot != null else self
		pitch_node.rotation.x = _target_pitch


func _process(delta: float) -> void:
	if follow_parent:
		_follow_parent_pitch(delta)
		_update_animation(delta)
		_update_transparency()
		return
	if not _has_received_first_transform:
		return

	var t := 1.0 - exp(-delta * lerp_speed)

	# Lissage des rotations (Yaw / Pitch)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)

	var pitch_node := _pitch_pivot if _pitch_pivot != null else self
	pitch_node.rotation.x = lerp_angle(pitch_node.rotation.x, _target_pitch, t)

	# Mises à jour visuelles
	_update_animation(delta)
	_update_transparency()


## Mode follow_parent : le pitch de la tête reprend celui de la caméra du joueur
## (le parent), comme le fait apply_transform pour un avatar distant. Le pitch
## est appliqué dès la première frame, sans lissage, pour ne pas voir la tête
## balayer l'angle à l'entrée en free-cam.
func _follow_parent_pitch(delta: float) -> void:
	if _pitch_cam == null or not is_instance_valid(_pitch_cam):
		var parent := get_parent()
		_pitch_cam = parent.get_node_or_null("Camera3D") as Camera3D if parent != null else null
		if _pitch_cam == null:
			return
		_target_pitch = _pitch_cam.rotation.x * pitch_scale
		(_pitch_pivot if _pitch_pivot != null else self).rotation.x = _target_pitch
		return
	_target_pitch = _pitch_cam.rotation.x * pitch_scale
	var pitch_node := _pitch_pivot if _pitch_pivot != null else self
	pitch_node.rotation.x = lerp_angle(pitch_node.rotation.x, _target_pitch,
		1.0 - exp(-delta * lerp_speed))

func _physics_process(delta: float) -> void:
	if follow_parent:
		_calculate_relative_velocity(_prev_pos, delta)
		_prev_pos = global_position
		return
	if not _has_received_first_transform:
		return

	# 1. Entraînement par le sol (bateau)
	_apply_ground_carry()

	# 2. On retient la position APRÈS le mouvement du bateau, 
	# mais AVANT le déplacement propre du joueur
	var pos_after_ground_carry := global_position

	# 3. Lissage de la position vers la cible réseau
	var t := 1.0 - exp(-delta * lerp_speed)
	global_position = global_position.lerp(_target_pos, t)

	# 4. Calcul de la vitesse RELATIVE (uniquement le déplacement du joueur sur le pont)
	_calculate_relative_velocity(pos_after_ground_carry, delta)

var _relative_speed_h := 0.0
var _relative_speed_v := 0.0

func _calculate_relative_velocity(pos_before_player_move: Vector3, delta: float) -> void:
	# On mesure uniquement la distance parcourue par le joueur sur le navire
	var vel := global_position - pos_before_player_move
	_relative_speed_h = Vector2(vel.x, vel.z).length() / maxf(delta, 0.001)
	_relative_speed_v = vel.y / maxf(delta, 0.001)

## Détecte le sol sous l'avatar et applique son mouvement (houle / plateformes)
func _apply_ground_carry() -> void:
	var world_space := get_world_3d().direct_space_state
	if world_space == null:
		return

	# Raycast vertical de 0.5m au-dessus des pieds à 1.5m en dessous
	var from_pos := global_position + Vector3(0, 0.5, 0)
	var to_pos := global_position + Vector3(0, -1.5, 0)

	var query := PhysicsRayQueryParameters3D.create(from_pos, to_pos)
	
	# MASQUE : On ne cible QUE la couche 1 (le decor / bateau).
	# On ignore la couche 2 (les joueurs et leurs DropTargets).
	query.collision_mask = 1

	# Exclure aussi tous les corps enfants de cet avatar (ex: DropTarget)
	var drop_target := get_node_or_null("DropTarget") as CollisionObject3D
	if drop_target != null:
		query.exclude = [drop_target.get_rid()]

	# Exclure le joueur local s'il est proche
	if is_instance_valid(local_player):
		query.exclude.append(local_player.get_rid())

	var result := world_space.intersect_ray(query)

	if result.size() > 0 and result.collider is Node3D:
		var current_ground: Node3D = result.collider
		var current_transform := current_ground.global_transform

		if current_ground == _last_ground_collider and is_instance_valid(_last_ground_collider):
			# Calcul du déplacement exact du pont cette frame
			var ground_motion := current_transform * _last_ground_transform.affine_inverse()
			
			# On applique la transformation du pont à l'avatar ET à sa cible réseau
			global_position = ground_motion * global_position
			_target_pos = ground_motion * _target_pos

		_last_ground_collider = current_ground
		_last_ground_transform = current_transform
	else:
		_last_ground_collider = null


## Fige X/Z des pistes de position qui avancent d'au moins root_motion_threshold entre la 1re et la dernière clé
## (la hauteur Y est conservée : rebond de la marche). Idempotent : la 2e fois, plus rien ne dépasse le seuil.
func _strip_root_motion(anim: Animation) -> void:
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var n := anim.track_get_key_count(t)
		if n < 2:
			continue
		var first: Vector3 = anim.track_get_key_value(t, 0)
		var last: Vector3 = anim.track_get_key_value(t, n - 1)
		if Vector2(last.x - first.x, last.z - first.z).length() < root_motion_threshold:
			continue
		for k in n:
			var v: Vector3 = anim.track_get_key_value(t, k)
			anim.track_set_key_value(t, k, Vector3(first.x, v.y, first.z))


func _update_animation(_delta: float) -> void:
	if _anim_player == null:
		return

	# On utilise la vitesse relative calculée dans _physics_process
	_is_grounded = absf(_relative_speed_v) < 1.0
	
	var target: StringName = &""
	if not _is_grounded and anim_jump != &"":
		target = anim_jump
	elif _relative_speed_h > walk_speed_threshold and anim_walk != &"":
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
	visible = _prewarm_ready and _arrived and not _suppressed and not (_fp and not _fp_supported)


## Masque temporairement l'avatar (ex. free-cam, qui a son propre avatar).
func set_suppressed(on: bool) -> void:
	_suppressed = on
	_update_visible()


## Corps du joueur local : en 1ère personne (fp) la tête est cachée et le corps légèrement reculé ; en 3e
## personne tout est visible. Renvoie false si l'avatar ne permet pas de cacher la tête (alors il est masqué en 1ère
## personne plutôt que de laisser la caméra à l'intérieur de son crâne).
func set_first_person(fp: bool) -> bool:
	if not _fp_ready:
		_setup_head_hiding()
	_fp = fp
	if _head_hider != null:
		_head_hider.set("hidden", fp)
		if not fp:
			_restore_head_scale()
	for m in _head_meshes:
		if is_instance_valid(m):
			m.visible = not fp
	position.z = fps_back_offset if fp else 0.0
	_update_visible()
	return _fp_supported


## Hauteur (dans le repère du parent, ici le joueur) où placer la caméra 1ère personne pour qu'elle soit au niveau
## de la tête de CET avatar. Basée sur la pose de repos (pas l'animation : pas de balancement de la caméra).
## Renvoie NAN si l'avatar n'a pas de tête repérable.
func get_eye_height_local() -> float:
	if not _fp_ready:
		_setup_head_hiding()
	var parent := get_parent() as Node3D
	if parent == null or not is_inside_tree():
		return NAN
	var world := Vector3.ZERO
	if _head_hider != null:
		var sk := _find_skeleton(self)
		var i := sk.find_bone(String(_head_hider.get("bone_name"))) if sk != null else -1
		if i < 0:
			return NAN
		world = (sk.global_transform * sk.get_bone_global_rest(i)).origin
		world += sk.global_transform.basis.y.normalized() * fps_eye_offset * sk.global_transform.basis.get_scale().y
	elif not _head_meshes.is_empty():
		for mi in _head_meshes:
			world += mi.global_transform * mi.get_aabb().get_center()
		world /= _head_meshes.size()
	else:
		return NAN
	return parent.to_local(world).y


func _setup_head_hiding() -> void:
	_fp_ready = true
	_fp_supported = false
	if not fullbody_enabled:
		return
	var sk := _find_skeleton(self)
	if sk != null:
		var bone := _find_head_bone(sk)
		if bone >= 0:
			_head_hider = HeadHiderScript.new()
			_head_hider.name = "HeadHider"
			_head_hider.set("bone_name", sk.get_bone_name(bone))
			sk.add_child(_head_hider)
			_fp_supported = true
		return
	# Avatar sans squelette (ex. capsule + casque) : on cache les meshes rigides dont le nom évoque la tête.
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	for mi in meshes:
		var low := String(mi.name).to_lower()
		for w in HEAD_MESH_WORDS:
			if low.contains(w):
				_head_meshes.append(mi)
				break
	_fp_supported = not _head_meshes.is_empty()


func _find_head_bone(sk: Skeleton3D) -> int:
	if fps_head_bone != &"":
		return sk.find_bone(fps_head_bone)
	var best := -1
	var best_depth := 1 << 30
	for i in sk.get_bone_count():
		var low := sk.get_bone_name(i).to_lower()
		if not low.contains("head") or low.contains("headband") or low.contains("end") or low.contains("top"):
			continue
		var depth := 0
		var p := sk.get_bone_parent(i)
		while p >= 0:
			depth += 1
			p = sk.get_bone_parent(p)
		if depth < best_depth:
			best_depth = depth
			best = i
	return best


func _restore_head_scale() -> void:
	var sk := _find_skeleton(self)
	if sk == null or _head_hider == null:
		return
	var i := sk.find_bone(String(_head_hider.get("bone_name")))
	if i >= 0:
		sk.set_bone_pose_scale(i, sk.get_bone_rest(i).basis.get_scale())


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
