extends CharacterBody3D

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var speed = 5
var jump_speed = 3
var mouse_sensitivity = 0.002

var interact_mode_active := false
var focus_mode_active := false

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta):
	if position.y <= -50:
		position = Vector3.ZERO
	velocity.y += -gravity * delta
	if $LauncherLayer/LauncherMenu.visible or $WindowMenuLayer/WindowMenu.visible or $PauseMenuLayer/PauseMenu.visible or $VolumeMixerLayer/VolumeMixer.visible or focus_mode_active:
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
		if $LauncherLayer/LauncherMenu.visible or $WindowMenuLayer/WindowMenu.visible or $VolumeMixerLayer/VolumeMixer.visible:
			return
		$PauseMenuLayer/PauseMenu.show_menu()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		if $LauncherLayer/LauncherMenu.visible or $WindowMenuLayer/WindowMenu.visible or $VolumeMixerLayer/VolumeMixer.visible:
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		$Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(80), deg_to_rad(80))
