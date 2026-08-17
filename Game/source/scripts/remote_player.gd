extends Node3D
## Avatar d'un autre joueur en LAN : simple représentation visuelle
## (capsule colorée + nom), synchronisée en position/rotation par le
## lan_manager. Pas de collision : on peut traverser les autres joueurs.
## Transparence progressive sous 1 m du joueur local : plus le joueur
## distant est proche, plus il devient transparent (alpha 0 à distance 0).

var peer_id := 0
var player_name := ""
# Joueur local (posé par lan_manager à la création de l'avatar) : référence
# pour calculer la distance → transparence.
var local_player: Node3D = null

var _interp_pos := Vector3.ZERO
var _interp_yaw := 0.0
var _interp_pitch := 0.0
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0

const LERP_SPEED := 20.0
# Distance (m) en dessous de laquelle l'avatar commence à s'estomper.
const FADE_DISTANCE := 2.0

var _body_mat: StandardMaterial3D = null
var _head_mat: StandardMaterial3D = null
var _label: Label3D = null

func setup(id: int, name: String, color: Color) -> void:
	peer_id = id
	player_name = name
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	# ALPHA_DEPTH_PRE_PASS (et pas ALPHA) : la tête (Helm) et la capsule
	# sont triées par profondeur réelle au lieu du painter's algorithm (tri par
	# centre) — sans pré-pass la tête "traversait" le corps (pas de profondeur).
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	# depth_write : la face avant écrit sa profondeur pendant le rendu
	# transparent. Sans ça, quand l'avatar s'estompe (alpha < 1) on voit
	# l'intérieur du personnage : la tête à travers le corps, et les faces
	# arrière à travers les faces avant. Avec l'écriture de profondeur, ce qui
	# est derrière une face avant est occulté au lieu d'être mélangé.
	mat.depth_write = true
	($MeshInstance3D as MeshInstance3D).material_override = mat
	_body_mat = mat
	# La tête (Helm, MeshInstance3D custom) : dupliquer son matériau pour ne
	# pas muter le sub_resource partagé de la scène (une modification
	# affecterait toutes les instances). Le matériau de surface du mesh est
	# appliqué en material_override (dupliqué), comme pour le corps.
	var helm := $Helm as MeshInstance3D
	var head_mat := helm.material_override as StandardMaterial3D
	if head_mat == null:
		head_mat = helm.get_active_material(0) as StandardMaterial3D
	if head_mat != null:
		head_mat = head_mat.duplicate() as StandardMaterial3D
		head_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		head_mat.depth_write = true
		helm.material_override = head_mat
		_head_mat = head_mat
	_label = $NameLabel as Label3D
	_label.text = name
	_interp_pos = position
	_target_pos = position
	_target_yaw = rotation.y

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
	rotation.x = _interp_pitch / 2
	_update_transparency()

# Alpha = distance / FADE_DISTANCE, clampé [0,1] : à 1 m et au-delà l'avatar
# est opaque, il s'estompe linéairement jusqu'à être invisible à 0 m.
func _update_transparency() -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var dist := global_position.distance_to(local_player.global_position) - 1
	var alpha := clampf(dist / FADE_DISTANCE, 0.0, 1.0)
	if _body_mat != null:
		_body_mat.albedo_color.a = alpha
	if _head_mat != null:
		_head_mat.albedo_color.a = alpha
