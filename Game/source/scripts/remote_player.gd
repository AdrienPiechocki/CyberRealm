extends Node3D
## Avatar d'un autre joueur en LAN : simple représentation visuelle
## (capsule colorée + nom), synchronisée en position/rotation par le
## lan_manager. Pas de collision : on peut traverser les autres joueurs.

var peer_id := 0
var player_name := ""

var _interp_pos := Vector3.ZERO
var _interp_yaw := 0.0
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0

const LERP_SPEED := 20.0

func setup(id: int, name: String, color: Color) -> void:
	peer_id = id
	player_name = name
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	($MeshInstance3D as MeshInstance3D).material_override = mat
	($NameLabel as Label3D).text = name
	_interp_pos = position
	_target_pos = position
	_target_yaw = rotation.y

func apply_transform(pos: Vector3, yaw: float) -> void:
	_target_pos = pos
	_target_yaw = yaw

func _physics_process(delta: float) -> void:
	var k := minf(1.0, delta * LERP_SPEED)
	_interp_pos = _interp_pos.lerp(_target_pos, k)
	_interp_yaw = lerp_angle(_interp_yaw, _target_yaw, k)
	position = _interp_pos
	rotation.y = _interp_yaw
