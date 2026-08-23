extends Node3D
## Avatar d'un autre joueur en LAN : représentation visuelle synchronisée
## en position/rotation par le lan_manager. Pas de collision.
## Transparence progressive sous 1 m du joueur local.
##
## Personnalisation : remplacez `res://scenes/avatar.tscn` par votre
## propre scène (ou créez `res://user/avatar.tscn`). La scène doit attacher
## ce script et contenir un nœud Label3D nommé "NameLabel".

@export var pitch_treshold: float = 2.0
@export var head: Node3D

@export_group("Animations")
## Nom de la jouée quand l'avatar est immobile.
@export var anim_idle: StringName = &""
## Nom de l'animation jouée quand l'avatar se déplace au sol.
@export var anim_walk: StringName = &""
## Nom de l'animation jouée quand l'avatar est en l'air (chute / saut).
@export var anim_jump: StringName = &""
## Seuil de vitesse (m/s) en dessous duquel on est considéré immobile.
@export var walk_speed_threshold := 0.1

var peer_id := 0
var player_name := ""
var local_player: CharacterBody3D = null

var _interp_pos := Vector3.ZERO
var _interp_yaw := 0.0
var _interp_pitch := 0.0
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0

const LERP_SPEED := 20.0
const FADE_DISTANCE := 2.0

var _mesh_mats: Array[StandardMaterial3D] = []
var _label: Label3D = null
var _anim_player: AnimationPlayer = null
var _prev_pos := Vector3.ZERO
var _is_grounded := true
var _current_anim: StringName = &""
var _prewarm_ready := false
var _prewarming := false


func setup(id: int, pname: String, color: Color) -> void:
	peer_id = id
	player_name = pname
	# Invisible tant que le prewarm GPU n'est pas terminé : le viewport
	# principal ne doit jamais rendre l'avatar avant que tous les variants de
	# shaders soient compilés hors-écran (sinon TDR pendant le chargement du
	# niveau). La visibilité est restaurée par start_prewarm().
	visible = false

	if head == null:
		head = get_node(".")

	# Collecter tous les MeshInstance3D et préparer les matériaux.
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	for mi in meshes:
		if not mi.visible:
			continue
		_duplicate_material_for_fade(mi)
		# Appliquer le tint couleur uniquement si le mesh n'a AUCUN matériau.
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
			_mesh_mats.append(mat)

	# Label du nom.
	_label = _find_label(self)
	if _label == null:
		_label = Label3D.new()
		_label.name = "NameLabel"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.font_size = 48
		_label.outline_size = 6
		_label.position = Vector3(0, 1.8, 0)
		add_child(_label)
	#_make_label_no_depth_test(_label)
	_label.text = pname

	# AnimationPlayer — uniquement si au moins une animation est configurée.
	if anim_idle != &"" or anim_walk != &"" or anim_jump != &"":
		_anim_player = _find_anim_player(self)
		if _anim_player == null:
			_anim_player = AnimationPlayer.new()
			_anim_player.name = "AnimationPlayer"
			add_child(_anim_player)

	_interp_pos = position
	_target_pos = position
	_target_yaw = rotation.y
	_prev_pos = position


func _ready() -> void:
	# Le prewarm N'est PAS déclenché ici : _ready() se re-déclenche quand le
	# lan_manager re-parente l'avatar (on_level_swapped), pendant le chargement
	# du niveau — un prewarm à ce moment-là s'ajouterait à la compilation des
	# shaders du niveau et provoquerait le TDR. Le lan_manager appelle
	# start_prewarm() une fois le niveau stable.
	pass


# Déclenche le prewarm GPU une seule fois, quand le niveau est stable. Tant
# que les variants de shaders ne sont pas compilés dans le SubViewport
# hors-écran, l'avatar reste invisible. Idempotent : le 2e appel (avatar qui
# spawn après coup, ou re-parenting) ne relance pas le prewarm.
func start_prewarm() -> void:
	if _prewarm_ready:
		visible = true
		return
	if _prewarming:
		return
	_prewarming = true
	await _prewarm_gpu()
	_prewarm_ready = true
	_prewarming = false
	visible = true


# Compile les shaders et uploade les meshes de l'avatar dans un SubViewport
# hors-écran, le temps de quelques frames, pendant que le GPU est encore
# disponible. Le prewarm doit reproduire les conditions de rendu du viewport
# principal (squelette de skinning, environnement sky/SSAO/SSR, lumière avec
# ombres) : sans cela le premier rendu réel (ex: la caméra se tourne vers
# l'avatar d'un coup) compile tous les variants de shaders manquants d'un coup
# et provoque un TDR (crash Vulkan) combiné aux captures Wayland.
# L'avatar reste invisible dans le viewport principal tant que le prewarm n'a
# pas fini : le viewport principal ne le rend jamais avant que tout soit prêt.
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
	# Même environnement que le viewport principal (sky, SSAO, SSR) pour
	# compiler les variants ambient/reflection au prewarm, pas au 1er rendu.
	var we := _find_world_environment()
	if we != null:
		var env_node := WorldEnvironment.new()
		env_node.name = "PrewarmEnvironment"
		env_node.environment = we.environment.duplicate(true)
		vp.add_child(env_node)
	# Lumière directionnelle avec ombres — mêmes variants shadow que le level.
	var light := DirectionalLight3D.new()
	light.shadow_enabled = true
	light.look_at_from_position(Vector3(2.0, 5.0, 3.0), Vector3(0.0, 1.0, 0.0))
	vp.add_child(light)
	# Squelette cloné : les meshes skin (FBX custom) ont besoin d'un
	# Skeleton3D pour compiler les variants de skinning. De simples holders
	# sans squelette ne compilaient pas ces variants → recompilés au 1er rendu.
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
	# Masquer l'avatar réel tant que les variants ne sont pas compilés. On
	# attend plusieurs frames (process_frame, toujours émis — pas de dépendance
	# au rendu) : le SubViewport UPDATE_ALWAYS rend à chaque frame et compile
	# les variants pendant ce délai.
	visible = false
	for _f in 3:
		await get_tree().process_frame
	if is_instance_valid(vp):
		vp.queue_free()
	# La visibilité est restaurée par start_prewarm() une fois tout prêt.


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
	# Avatar custom (FBX) : chaque surface a son propre matériau. On le duplique
	# en transparent et on l'accroche en override de surface pour pouvoir le
	# fondre à la proximité du joueur local (comme la capsule par défaut).
	# Les variantes transparentes sont compilées par le prewarm hors viewport
	# principal avant tout rendu réel : pas de TDR au 1er affichage.
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


func _make_label_no_depth_test(label: Label3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	label.material_override = mat


func apply_transform(pos: Vector3, yaw: float, pitch: float) -> void:
	_target_pos = pos
	_target_yaw = yaw
	_target_pitch = pitch


func _physics_process(delta: float) -> void:
	var k := minf(1.0, delta * LERP_SPEED)
	_interp_pos = _interp_pos.lerp(_target_pos, k)
	_interp_yaw = lerp_angle(_interp_yaw, _target_yaw, k)
	_interp_pitch = lerp_angle(_interp_pitch, _target_pitch, k)
	position = _interp_pos
	rotation.y = _interp_yaw
	head.global_rotation.x = _interp_pitch / pitch_treshold
	_update_transparency()
	_update_animation(delta)
	_prev_pos = _interp_pos


func _update_animation(_delta: float) -> void:
	if _anim_player == null:
		return
	var vel := _interp_pos - _prev_pos
	var speed_h = Vector2(vel.x, vel.z).length() / maxf(_delta, 0.001)
	var speed_v = vel.y / maxf(_delta, 0.001)
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
	var dist := global_position.distance_to(local_player.global_position) - 1
	var alpha := clampf(dist / FADE_DISTANCE, 0.0, 1.0)
	for mat in _mesh_mats:
		if mat != null and is_instance_valid(mat):
			mat.albedo_color.a = alpha


func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_meshes(child, result)
