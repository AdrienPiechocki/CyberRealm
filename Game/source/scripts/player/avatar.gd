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
@export var fps_back_offset := 0.22
## Hauteur des yeux au-dessus de l'origine de l'os de la tête (m, avant échelle) : la caméra 1ère personne se place là.
@export var fps_eye_offset := 0.08

@export_group("Animations")
@export var anim_idle: StringName = &""
@export var anim_walk: StringName = &""
@export var anim_jump: StringName = &""
@export_subgroup("Directional locomotion")
## Marche dans les autres directions (avatar de face : « left » = déplacement vers sa gauche). Renseigner au moins
## une de ces animations active le mélange directionnel (AnimationTree créé à l'exécution) ; les directions non
## renseignées retombent sur la marche avant.
@export var anim_walk_back: StringName = &""
@export var anim_walk_left: StringName = &""
@export var anim_walk_right: StringName = &""
## Course : mêmes règles. Elle prend le relais de la marche quand le joueur dépasse sa vitesse naturelle.
@export var anim_run: StringName = &""
@export var anim_run_back: StringName = &""
@export var anim_run_left: StringName = &""
@export var anim_run_right: StringName = &""
## Vitesse naturelle (m/s) des animations sans root motion exploitable (marche / course).
@export var default_walk_speed := 2.0
@export var default_run_speed := 5.0
@export var walk_speed_threshold := 0.1
## Supprime le déplacement du « root motion » de l'animation de marche (certains exports la font avancer l'avatar
## de plusieurs mètres par boucle : il glisse puis retombe au point de départ). Le sur-place laisse le joueur
## porter le déplacement.
@export var walk_in_place := true
## Déplacement horizontal minimal (unités de l'animation) entre première et dernière clé pour qu'une piste de
## position soit considérée comme du root motion.
@export var root_motion_threshold := 0.2
## Amplitude de l'animation d'idle (1 = d'origine, 0 = pose figée sur sa première image). Certains idles
## balancent beaucoup le corps ; réduire calme l'avatar sans changer la pose de départ.
@export_range(0.0, 1.0, 0.05) var idle_motion_scale := 0.35
@export_group("Animation blending")
## Durée (s) du fondu entre idle et marche, dans les deux sens.
@export var blend_idle_walk := 0.2
## Durée (s) du fondu vers / depuis le saut.
@export var blend_jump := 0.1
## Vitesse (m/s) que l'animation de marche couvre naturellement à vitesse 1. 0 = déduite du déplacement de la piste
## racine (retiré par walk_in_place) ; si l'animation n'en a pas, pas d'adaptation de vitesse.
@export var walk_reference_speed := 0.0
## Bornes du facteur de vitesse de la marche (vitesse réelle / vitesse de référence).
@export var walk_speed_scale_min := 0.6
@export var walk_speed_scale_max := 2.5
## Mélange directionnel : durée (s) du fondu boucle de déplacement <-> saut.
@export var blend_loco_jump := 0.1

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
		var idle_anim: Animation = _anim_player.get_animation(anim_idle) \
				if anim_idle != &"" and _anim_player.has_animation(anim_idle) else null
		if idle_anim != null and idle_motion_scale < 1.0:
			_calm_animation(idle_anim, idle_motion_scale)
		_anim_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
		if walk_in_place:
			for nm in _locomotion_names():
				_strip_root_motion(_anim_player.get_animation(nm), idle_anim)
		_use_tree = _directional_requested()

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
	if _has_received_first_transform and is_inside_tree() and global_position.distance_to(pos) > TELEPORT_SNAP:
		global_position = pos     # téléportation distante (porte…) : pas de glissade sur toute la distance
		_prev_pos = pos
		_on_teleport()

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
## est inversé par rapport à l'avatar distant (sens constaté en TPS) et appliqué
## dès la première frame, sans lissage, pour ne pas voir la tête
## balayer l'angle à l'entrée en free-cam.
func _follow_parent_pitch(delta: float) -> void:
	if _pitch_cam == null or not is_instance_valid(_pitch_cam):
		var parent := get_parent()
		_pitch_cam = parent.get_node_or_null("Camera3D") as Camera3D if parent != null else null
		if _pitch_cam == null:
			return
		_target_pitch = -_pitch_cam.rotation.x * pitch_scale
		(_pitch_pivot if _pitch_pivot != null else self).rotation.x = _target_pitch
		return
	_target_pitch = -_pitch_cam.rotation.x * pitch_scale
	var pitch_node := _pitch_pivot if _pitch_pivot != null else self
	pitch_node.rotation.x = lerp_angle(pitch_node.rotation.x, _target_pitch,
		1.0 - exp(-delta * lerp_speed))

func _physics_process(delta: float) -> void:
	if follow_parent:
		if not _ref_inited:
			_prev_pos = _ref_position()
			_ref_inited = true
		_calculate_relative_velocity(_prev_pos, delta)
		_prev_pos = _ref_position()
		_update_ground_gap()
		_track_head_camera()
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
	_update_ground_gap()

var _relative_speed_h := 0.0
var _rel_vel := Vector3.ZERO     # vitesse horizontale monde (m/s)
var _relative_speed_v := 0.0

# Distance origine de l'avatar -> sol (m). Debout, l'origine est ~0,55 m au-dessus du sol (centre de la capsule du
# joueur) ; au-delà de AIR_GAP on est réellement en l'air. Sert à choisir saut / déplacement : la vitesse verticale
# mesurée ne convient pas (les marches sont montées par « step-up » instantané, les pentes donnent du vy en marchant).
const AIR_GAP := 0.68
const AIR_DEBOUNCE := 0.08      # s en l'air avant de passer à l'animation de saut (ignore les trous minuscules)
var _ground_gap := 0.0
var _air_time := 0.0

func _update_ground_gap() -> void:
	if not is_inside_tree():
		return
	var from := global_position + Vector3.UP * 0.3
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0, 1)
	var excl: Array[RID] = []
	var par := get_parent()
	if par is CollisionObject3D:
		excl.append((par as CollisionObject3D).get_rid())
	if is_instance_valid(local_player):
		excl.append(local_player.get_rid())
	q.exclude = excl
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_ground_gap = 99.0
	else:
		# Distance PERPENDICULAIRE au sol : sur une pente de 40° la distance verticale grandit de 1/cos, la
		# perpendiculaire reste celle du plat.
		_ground_gap = ((hit.position as Vector3).distance_to(from) - 0.3) * clampf((hit.normal as Vector3).y, 0.3, 1.0)


var _ref_inited := false

const TELEPORT_DIST := 2.0       # m par tick physique : au-delà, déplacement instantané (téléportation)
const TELEPORT_SNAP := 5.0       # m : un avatar distant plus loin que ça de sa cible réseau s'y place d'un coup

# Après une téléportation : plus aucune vitesse mesurée, retour à l'idle immédiat (sinon le saut de position donne
# une vitesse énorme -> animation de course à l'arrivée).
func _on_teleport() -> void:
	_rel_vel = Vector3.ZERO
	_relative_speed_h = 0.0
	_relative_speed_v = 0.0
	_speed_smooth = 0.0
	_loco_vel = Vector2.ZERO
	_walking = false
	_air_time = 0.0
	if _tree != null:
		_tree.set("parameters/loco/bs/blend_position", Vector2.ZERO)
		_tree.set("parameters/loco/ts/scale", 1.0)
		if _tree_playback != null:
			_tree_playback.start(&"loco")

# Point dont on mesure le déplacement. Avatar local : l'ORIGINE DU JOUEUR (parent), pas celle de l'avatar : en 1ère
# personne le corps est décalé derrière la caméra (fps_back_offset), donc tourner la tête sur place le fait décrire
# un arc et il « marchait » sur place (tremblement en idle).
func _ref_position() -> Vector3:
	if follow_parent and get_parent() is Node3D:
		return (get_parent() as Node3D).global_position
	return global_position


func _calculate_relative_velocity(pos_before_player_move: Vector3, delta: float) -> void:
	# On mesure uniquement la distance parcourue par le joueur sur le navire
	var vel := _ref_position() - pos_before_player_move
	if vel.length() > TELEPORT_DIST:      # porte, changement de niveau, respawn : ce n'est pas de la course
		_on_teleport()
		return
	_rel_vel = Vector3(vel.x, 0.0, vel.z) / maxf(delta, 0.001)
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
## (la hauteur Y est conservée : rebond de la marche). X/Z sont alignés sur la même piste de l'idle (`ref`) quand
## elle existe : sinon la marche, figée à sa 1re image, placerait le corps devant/derrière sa position d'idle.
## Idempotent (méta posée sur l'animation, partagée entre instances).
func _strip_root_motion(anim: Animation, ref: Animation = null) -> void:
	if anim.has_meta("cr_in_place"):
		return
	anim.set_meta("cr_in_place", true)
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
		# Déplacement de la boucle (unités locales de la piste) : sert à déduire la vitesse naturelle de la marche.
		if not anim.has_meta("cr_root_disp") or Vector2(last.x - first.x, last.z - first.z).length() \
				> (anim.get_meta("cr_root_disp") as Vector2).length():
			anim.set_meta("cr_root_disp", Vector2(last.x - first.x, last.z - first.z))
			anim.set_meta("cr_root_path", anim.track_get_path(t))
		var pin := Vector2(first.x, first.z)
		if ref != null:
			var rt := ref.find_track(anim.track_get_path(t), Animation.TYPE_POSITION_3D)
			if rt >= 0 and ref.track_get_key_count(rt) > 0:
				var rv: Vector3 = ref.track_get_key_value(rt, 0)
				pin = Vector2(rv.x, rv.z)
		for k in n:
			var v: Vector3 = anim.track_get_key_value(t, k)
			anim.track_set_key_value(t, k, Vector3(pin.x, v.y, pin.y))


## Réduit l'amplitude d'une animation autour de sa première image : positions et rotations interpolées entre la
## pose de la clé 0 et chaque clé (scale 1 = inchangé). Idempotent via une méta posée sur l'animation.
func _calm_animation(anim: Animation, amount: float) -> void:
	if anim.has_meta("cr_calmed"):
		return
	anim.set_meta("cr_calmed", true)
	for t in anim.get_track_count():
		var type := anim.track_get_type(t)
		var n := anim.track_get_key_count(t)
		if n < 2:
			continue
		if type == Animation.TYPE_POSITION_3D:
			var p0: Vector3 = anim.track_get_key_value(t, 0)
			for k in range(1, n):
				var v: Vector3 = anim.track_get_key_value(t, k)
				anim.track_set_key_value(t, k, p0.lerp(v, amount))
		elif type == Animation.TYPE_ROTATION_3D:
			var q0: Quaternion = anim.track_get_key_value(t, 0)
			for k in range(1, n):
				var q: Quaternion = anim.track_get_key_value(t, k)
				anim.track_set_key_value(t, k, q0.slerp(q, amount))


var _speed_smooth := 0.0
var _walking := false
var _walk_ref := -1.0          # vitesse de référence résolue (-1 = pas encore calculée, 0 = inconnue)

# Vitesse monde (m/s) qu'une animation de déplacement couvre à vitesse 1 : déplacement de sa piste racine / durée,
# converti avec l'échelle du nœud animé (le modèle peut être agrandi). 0 = inconnue (pas de root motion).
# À appeler quand l'avatar est dans l'arbre.
func _anim_natural_speed(anim_name: StringName) -> float:
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return 0.0
	var anim := _anim_player.get_animation(anim_name)
	if not anim.has_meta("cr_root_disp") or anim.length <= 0.0:
		return 0.0
	var disp: Vector2 = anim.get_meta("cr_root_disp")
	var path: NodePath = anim.get_meta("cr_root_path")
	var base := _anim_player.get_node_or_null(_anim_player.root_node)
	if base == null:
		return 0.0
	var node := base.get_node_or_null(NodePath(String(path).get_slice(":", 0)))
	if node == null:
		return 0.0
	var space := (node if node is Skeleton3D else node.get_parent()) as Node3D
	if space == null or not space.is_inside_tree():
		return 0.0
	return (space.global_transform.basis * Vector3(disp.x, 0.0, disp.y)).length() / anim.length


func _resolve_walk_reference() -> float:
	if walk_reference_speed > 0.0:
		return walk_reference_speed
	return _anim_natural_speed(anim_walk)


## Toutes les animations de déplacement renseignées et présentes dans l'AnimationPlayer.
func _locomotion_names() -> Array[StringName]:
	var out: Array[StringName] = []
	for nm in [anim_walk, anim_walk_back, anim_walk_left, anim_walk_right,
			anim_run, anim_run_back, anim_run_left, anim_run_right]:
		if nm != &"" and _anim_player != null and _anim_player.has_animation(nm) and not out.has(nm):
			out.append(nm)
	return out


func _directional_requested() -> bool:
	if _anim_player == null:
		return false
	for nm in [anim_walk_back, anim_walk_left, anim_walk_right, anim_run, anim_run_back, anim_run_left, anim_run_right]:
		if nm != &"" and _anim_player.has_animation(nm):
			return true
	return false


# ── Mélange directionnel (AnimationTree) ─────────────────────────────
# État « loco » : BlendSpace2D (x = vitesse latérale, y = vitesse avant, en m/s) -> TimeScale. L'idle est au centre :
# repos -> marche -> course se mélangent en continu. État « jump » : l'animation de saut, en fondu.

var _use_tree := false
var _tree: AnimationTree = null
var _tree_playback: AnimationNodeStateMachinePlayback = null
var _loco_vel := Vector2.ZERO       # vitesse locale lissée (x droite, y avant)
var _loco_top := 1.0                # plus grande vitesse naturelle de la carte (au-delà : accélération de lecture)

func _build_tree() -> void:
	var space := AnimationNodeBlendSpace2D.new()
	space.sync = true
	var fwd := anim_walk
	var walk_v := _natural_or(fwd, default_walk_speed)
	var top := walk_v
	if anim_idle != &"" and _anim_player.has_animation(anim_idle):
		_add_loco_point(space, anim_idle, Vector2.ZERO)
	var set := [
		# [nom, direction (x droite, y avant), repli sur…, vitesse par défaut]
		[anim_walk, Vector2(0, 1), anim_walk, default_walk_speed],
		[anim_walk_back, Vector2(0, -1), anim_walk, default_walk_speed],
		[anim_walk_left, Vector2(-1, 0), anim_walk, default_walk_speed],
		[anim_walk_right, Vector2(1, 0), anim_walk, default_walk_speed],
		[anim_run, Vector2(0, 1), anim_run, default_run_speed],
		[anim_run_back, Vector2(0, -1), anim_run, default_run_speed],
		[anim_run_left, Vector2(-1, 0), anim_run, default_run_speed],
		[anim_run_right, Vector2(1, 0), anim_run, default_run_speed],
	]
	var used := {}
	for e in set:
		var nm: StringName = e[0]
		if nm == &"" or not _anim_player.has_animation(nm):
			continue
		var v := _natural_or(nm, e[3])
		var pt: Vector2 = (e[1] as Vector2) * v
		if used.has(pt):
			continue
		used[pt] = true
		_add_loco_point(space, nm, pt)
		top = maxf(top, v)
	# Directions sans aucune animation : on reprend la marche avant (sinon le mélange tomberait sur l'idle en reculant).
	for dir in [Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]:
		var has_dir := false
		for pt in used:
			if (pt as Vector2).normalized().is_equal_approx(dir):
				has_dir = true
				break
		if not has_dir and anim_walk != &"" and _anim_player.has_animation(anim_walk):
			_add_loco_point(space, anim_walk, dir * walk_v)
	_loco_top = top
	space.min_space = Vector2(-top * 1.5, -top * 1.5)
	space.max_space = Vector2(top * 1.5, top * 1.5)
	space.snap = Vector2(0.01, 0.01)

	var bt := AnimationNodeBlendTree.new()
	bt.add_node(&"bs", space)
	bt.add_node(&"ts", AnimationNodeTimeScale.new())
	bt.connect_node(&"ts", 0, &"bs")
	bt.connect_node(&"output", 0, &"ts")

	var sm := AnimationNodeStateMachine.new()
	sm.add_node(&"loco", bt)
	sm.add_transition(&"Start", &"loco", AnimationNodeStateMachineTransition.new())
	if anim_jump != &"" and _anim_player.has_animation(anim_jump):
		var jn := AnimationNodeAnimation.new()
		jn.animation = anim_jump
		sm.add_node(&"jump", jn)
		for pair in [[&"loco", &"jump"], [&"jump", &"loco"]]:
			var tr := AnimationNodeStateMachineTransition.new()
			tr.xfade_time = blend_loco_jump
			sm.add_transition(pair[0], pair[1], tr)

	_tree = AnimationTree.new()
	_tree.name = "LocomotionTree"
	# Animation au tick PHYSIQUE (le projet active physics_interpolation) : mise à jour par frame, les nœuds animés
	# (racine du squelette) seraient interpolés à tort et trembleraient. Calculée AVANT que l'avatar (et la caméra qui
	# suit la tête) ne lise la pose.
	_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	_tree.process_physics_priority = -10
	_tree.tree_root = sm
	add_child(_tree)
	_tree.anim_player = _tree.get_path_to(_anim_player)
	_tree.active = true
	_tree_playback = _tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	if _tree_playback != null:
		_tree_playback.start(&"loco")


func _add_loco_point(space: AnimationNodeBlendSpace2D, anim_name: StringName, pt: Vector2) -> void:
	var n := AnimationNodeAnimation.new()
	n.animation = anim_name
	space.add_blend_point(n, pt, -1, StringName("p%d" % space.get_blend_point_count()))


func _natural_or(anim_name: StringName, fallback: float) -> float:
	var v := _anim_natural_speed(anim_name) if anim_name != &"" else 0.0
	if v <= 0.0 and anim_name == anim_walk and walk_reference_speed > 0.0:
		v = walk_reference_speed
	return v if v > 0.0 else fallback


func _update_tree(delta: float) -> void:
	if _tree == null:
		_build_tree()
		return
	# Vitesse dans le repère de l'avatar (x droite, y avant ; l'avant est -Z), lissée (réseau, escaliers).
	var lv := global_basis.orthonormalized().inverse() * _rel_vel
	var raw := Vector2(lv.x, -lv.z)
	# Zone morte douce : le bruit de mesure (arrondis de position, snapshots réseau) ne doit pas mélanger un peu de
	# marche à l'idle (tremblement à l'arrêt).
	raw *= smoothstep(0.1, 0.5, raw.length())
	_loco_vel = _loco_vel.lerp(raw, 1.0 - exp(-12.0 * delta))
	_tree.set("parameters/loco/bs/blend_position", _loco_vel)
	# Au-delà de la vitesse naturelle la plus rapide, on accélère la lecture au lieu de laisser les pieds glisser.
	var m := _loco_vel.length()
	var s := 1.0 if m <= _loco_top else clampf(m / _loco_top, 1.0, walk_speed_scale_max)
	_tree.set("parameters/loco/ts/scale", s)
	_is_grounded = _compute_grounded(delta)
	if _tree_playback != null and anim_jump != &"" and _anim_player.has_animation(anim_jump):
		var cur := _tree_playback.get_current_node()
		if not _is_grounded and cur != &"jump":
			_tree_playback.travel(&"jump")
		elif _is_grounded and cur == &"jump":
			_tree_playback.travel(&"loco")


func _compute_grounded(delta: float) -> bool:
	# Joueur local : la physique fait foi (immédiat au saut, tient jusqu'à l'atterrissage).
	var par := get_parent()
	if follow_parent and par != null and par.has_method("is_airborne"):
		return not par.is_airborne()
	if _ground_gap > AIR_GAP:
		_air_time += delta
	else:
		_air_time = 0.0
	return _air_time < AIR_DEBOUNCE


func _update_animation(delta: float) -> void:
	if _anim_player == null:
		return
	if _use_tree and is_inside_tree():
		_update_tree(delta)
		return

	# Vitesse horizontale lissée (la mesure brute est bruitée : snapshots réseau, marches d'escalier).
	_speed_smooth = lerpf(_speed_smooth, _relative_speed_h, 1.0 - exp(-12.0 * delta))
	_is_grounded = _compute_grounded(delta)

	# Hystérésis : démarre la marche au seuil, ne l'arrête qu'à la moitié (pas de va-et-vient près de 0).
	if _walking:
		_walking = _speed_smooth > walk_speed_threshold * 0.5
	else:
		_walking = _speed_smooth > walk_speed_threshold

	var target: StringName = &""
	if not _is_grounded and anim_jump != &"":
		target = anim_jump
	elif _walking and anim_walk != &"":
		target = anim_walk
	elif anim_idle != &"":
		target = anim_idle

	if target != &"" and target != _current_anim:
		var blend := blend_jump if (target == anim_jump or _current_anim == anim_jump) else blend_idle_walk
		_anim_player.play(target, blend)
		_current_anim = target

	# Marche : vitesse de lecture proportionnelle à la vitesse réelle, pour que les pieds ne glissent pas.
	var want := 1.0
	if _current_anim == anim_walk and anim_walk != &"":
		if _walk_ref < 0.0:
			_walk_ref = _resolve_walk_reference()
		if _walk_ref > 0.0:
			want = clampf(_speed_smooth / _walk_ref, walk_speed_scale_min, walk_speed_scale_max)
	_anim_player.speed_scale = lerpf(_anim_player.speed_scale, want, 1.0 - exp(-10.0 * delta))


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


var _head_tracking := false

## Full body awareness : la caméra du joueur suit la tête de l'avatar PENDANT les animations (rebond de la marche,
## inclinaison de l'idle, accroupissement…) : on lui transmet l'écart entre la position animée de l'os de la tête et
## sa position de repos (celle qui fixe la hauteur d'yeux, cf. get_eye_height_local), dans le repère du joueur.
func _track_head_camera() -> void:
	var active := _fp and _fp_supported and not _suppressed and _head_hider != null
	var player := get_parent()
	if player == null or not player.has_method("set_head_follow"):
		return
	if not active:
		if _head_tracking:
			_head_tracking = false
			player.set_head_follow(Vector3.ZERO)
		return
	var sk := _find_skeleton(self)
	var i := sk.find_bone(String(_head_hider.get("bone_name"))) if sk != null else -1
	if i < 0:
		return
	var animated := sk.global_transform * sk.get_bone_global_pose(i).origin
	var rest := sk.global_transform * sk.get_bone_global_rest(i).origin
	_head_tracking = true
	player.set_head_follow((player as Node3D).to_local(animated) - (player as Node3D).to_local(rest))


func _exit_tree() -> void:
	var player := get_parent()
	if _head_tracking and player != null and is_instance_valid(player) and player.has_method("set_head_follow"):
		player.set_head_follow(Vector3.ZERO)


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
			var neck := _find_bone_named(sk, "neck")
			if neck >= 0 and neck != bone:
				var nb: Array[String] = [sk.get_bone_name(neck)]
				_head_hider.set("extra_bones", nb)
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


## Os le plus haut dans la hiérarchie dont le nom contient `word` (hors « twist »).
func _find_bone_named(sk: Skeleton3D, word: String) -> int:
	var best := -1
	var best_depth := 1 << 30
	for i in sk.get_bone_count():
		var low := sk.get_bone_name(i).to_lower()
		if not low.contains(word) or low.contains("twist"):
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
	var names: Array = [String(_head_hider.get("bone_name"))] + (_head_hider.get("extra_bones") as Array)
	for nm in names:
		var i := sk.find_bone(nm)
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
