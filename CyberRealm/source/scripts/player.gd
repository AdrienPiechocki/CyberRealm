extends CharacterBody3D

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var speed = 5
var jump_speed = 3
var mouse_sensitivity = 0.002

var interact_mode_active := false
var focus_mode_active := false
# Positionné par wayland_room.gd : vrai quand la souris survole une layer
# surface (waybar/rofi) en mode visible. Empêche le click de recapturer la
# souris (FPS) pour laisser wayland_room forwarder le clic vers l'overlay.
var layer_pointer_active := false
# Référence paresseuse au compositeur, pour connaître la layer surface qui
# détient le focus clavier (rofi, menu waybar...).
var _compositor: WlrCompositor = null

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _get_compositor() -> WlrCompositor:
	if _compositor == null or not is_instance_valid(_compositor):
		var scene := get_tree().current_scene
		if scene != null:
			_compositor = scene.get_node_or_null("WlrCompositor") as WlrCompositor
	return _compositor

func _keyboard_busy() -> bool:
	var comp := _get_compositor()
	return comp != null and comp.get_keyboard_focus_layer_id() >= 0

func _physics_process(delta):
	if position.y <= -50:
		position = Vector3.ZERO
	velocity.y += -gravity * delta
	if $WindowMenuLayer/WindowMenu.visible or $PauseMenuLayer/PauseMenu.visible or focus_mode_active or _keyboard_busy():
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	var input = Input.get_vector("left", "right", "forward", "back")
	var movement_dir = transform.basis * Vector3(input.x, 0, input.y)
	velocity.x = movement_dir.x * speed
	velocity.z = movement_dir.z * speed

	if not interact_mode_active:
		move_and_slide()
		if is_on_floor() and Input.is_action_just_pressed("jump"):
			velocity.y = jump_speed
		$UI/Label.text = "Keyboard Capture : OFF"
	else:
		$UI/Label.text = "Keyboard Capture : ON"

func _input(event):
	if focus_mode_active:
		return
	if $PauseMenuLayer/PauseMenu.visible:
		return
	if event.is_action_pressed("ui_cancel") and not interact_mode_active:
		if $WindowMenuLayer/WindowMenu.visible:
			return
		# Un overlay keyboard-interactive (rofi, menu waybar...) détient le
		# clavier : laisser l'Escape lui être routé au lieu d'ouvrir le menu
		# pause.
		if _get_compositor() and _get_compositor().get_keyboard_focus_layer_id() >= 0:
			return
		$PauseMenuLayer/PauseMenu.show_menu()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		if $WindowMenuLayer/WindowMenu.visible:
			return
		if layer_pointer_active:
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		$Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(80), deg_to_rad(80))
