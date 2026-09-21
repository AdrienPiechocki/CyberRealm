extends Node3D
## Caméra libre (mode vue détachée) — activée par Super+Shift+F depuis
## wayland_room. La caméra vole vers la direction visée : regarder en haut
## et avancer = monter (pas besoin de saut). Rotation souris / stick droit
## identique au ressenti FPS (sensibilités recopiées depuis le joueur).
##
## Ce nœud est instancié en pur code par wayland_room : attachez ce script à
## un Node3D, renseignez `player` / `sensitivity` / `pad_look_speed` AVANT
## l'ajout dans l'arbre (le _ready fabrique sa propre Camera3D).

var player: Node3D = null
var sensitivity := 0.002
var pad_look_speed := 2.5

const SPEED := 10.0
const PITCH_LIMIT := deg_to_rad(80.0)

var _cam: Camera3D = null


func _ready() -> void:
	_cam = Camera3D.new()
	_cam.name = "FreeCamCamera"
	add_child(_cam)
	# Reprendre la transform de la caméra du joueur (position + orientation
	# figées) : l'entrée en vue libre ne saute pas visuellement.
	if player != null and is_instance_valid(player):
		var pc := player.get_node_or_null("Camera3D") as Camera3D
		if pc != null:
			global_transform = pc.global_transform
	_cam.current = true


## Gèle la caméra tant qu'un menu du jeu est ouvert (même règle que le
## joueur) : le déplacement et le regard n'ont pas cours en plein menu.
func _menus_frozen() -> bool:
	if player == null or not is_instance_valid(player):
		return true
	for path: NodePath in [
			^"WindowMenuLayer/WindowMenu",
			^"PauseMenuLayer/PauseMenu",
			^"RadialMenuLayer/RadialMenu",
			^"TutorialLayer/Tutorial"]:
		var ctl := player.get_node_or_null(path) as Control
		if ctl != null and ctl.visible:
			return true
	return false


func _physics_process(delta: float) -> void:
	if _menus_frozen() or _cam == null:
		return

	# Regard analogique — même courbe quadratique que le joueur.
	var look := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
			Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)).limit_length(1.0)
	if look != Vector2.ZERO:
		var amt: Vector2 = look * look.length()
		rotate_y(-amt.x * pad_look_speed * delta)
		_cam.rotate_x(-amt.y * pad_look_speed * delta)
		_cam.rotation.x = clampf(_cam.rotation.x, -PITCH_LIMIT, PITCH_LIMIT)

	# Déplacement vers la direction VISÉE (pitch inclus : regarder en haut +
	# avant = monter). Basis de la caméra : le long axe suit le regard, l'axe
	# latéral (basis.x) reste horizontal pour le strafe.
	var input := Input.get_vector("left", "right", "forward", "back")
	if input != Vector2.ZERO:
		var dir := _cam.global_transform.basis * Vector3(input.x, 0, input.y)
		global_position += dir * SPEED * delta


func _input(event: InputEvent) -> void:
	if _menus_frozen() or _cam == null:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * sensitivity)
		_cam.rotate_x(-event.relative.y * sensitivity)
		_cam.rotation.x = clampf(_cam.rotation.x, -PITCH_LIMIT, PITCH_LIMIT)