extends CharacterBody3D

@export var MaxDepth := 50
@export var MaxClimbDistance := 5.0
@export var MaxClimbTime := 0.2
@export var ClimbSpeed := 2.5
var climbed_distance := 0.0
var climb_time := 0.0

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var speed = 5
var jump_speed = 3
var mouse_sensitivity = 0.002

# Vitesse angulaire du stick droit à pleine déflexion (rad/s), réponse
# quadratique pour la précision en near-center. La souris garde son chemin
# InputEventMouseMotion, inchangé. Les touches fléchées (actions look_*)
# suivent le même chemin.
var pad_look_speed := 2.5

var interact_mode_active := false
var focus_mode_active := false
var _menu_just_closed := false
# Positionné par wayland_room.gd : vrai quand la souris survole une layer
# surface (waybar/rofi) en mode visible. Empêche le click de recapturer la
# souris (FPS) pour laisser wayland_room forwarder le clic vers l'overlay.
var layer_pointer_active := false
# Positionné par wayland_room.gd : vrai tant que le session est verrouillé.
# Empêche la recapture de la souris (MOUSE_MODE_CAPTURED) pendant le lockscreen.
var session_locked := false
# Positionné par wayland_room.gd : vrai pendant le chargement de la map LAN
# (join pas encore finalisé). Gèle déplacement et caméra ; Escape (menu pause)
# reste fonctionnel pour pouvoir annuler la connexion.
var input_locked := false
# Référence paresseuse au compositeur, pour connaître la layer qui
# détient le focus clavier (rofi, menu waybar...).
var _compositor: WlrCompositor = null

# Diagnostic manette (CYBERREALM_PAD_DEBUG=1) : trace les événements bruts
# émis par le matériel — indispensable quand un pad dévie de la
# cartographie standard (sticks/gâchettes sur des axes inattendus).
var _pad_diag := OS.get_environment("CYBERREALM_PAD_DEBUG") == "1"
var _pad_diag_axes := {} # "device|axis" -> dernière valeur tracée

var spawn_pos: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.ZERO
var spawn_scale: Vector3 = Vector3.ONE

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spawn_pos = position
	spawn_rotation = rotation
	spawn_scale = scale
	$WindowMenuLayer/WindowMenu.visibility_changed.connect(_on_menu_visibility_changed)
	$PauseMenuLayer/PauseMenu.visibility_changed.connect(_on_menu_visibility_changed)
	$RadialMenuLayer/RadialMenu.visibility_changed.connect(_on_menu_visibility_changed)

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
	if position.y <= -MaxDepth:
		position = spawn_pos
	if velocity.y > jump_speed:
		velocity.y = jump_speed
	velocity.y += -gravity * delta
	if $WindowMenuLayer/WindowMenu.visible or $PauseMenuLayer/PauseMenu.visible or focus_mode_active or _keyboard_busy() or input_locked or $RadialMenuLayer/RadialMenu.visible:
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	var input := Input.get_vector("left", "right", "forward", "back")
	var movement_dir = transform.basis * Vector3(input.x, 0, input.y)
	var pad_cursor_active := Input.is_action_pressed("layer_interact", true) or layer_pointer_active
	if not pad_cursor_active:
		velocity.x = movement_dir.x * speed
		velocity.z = movement_dir.z * speed
	else:
		velocity.x = 0
		velocity.z = 0

	# Stick droit / flèches : caméra analogique, active dans tous les modes
	# (souris capturée incluse — la souris passe par _input, sans conflit).
	# Réponse quadratique : précision près du centre, vitesse pleine en bord.
	# RT tenu (mode curseur pad) ou layer focus actif : le stick gauche
	# appartient au curseur souris, pas au joueur ; la caméra reste libre.
	if not pad_cursor_active:
		var look := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)).limit_length(1.0)
		if look != Vector2.ZERO:
			var look_amt: Vector2 = look * look.length()
			rotate_y(-look_amt.x * pad_look_speed * delta)
			$Camera3D.rotate_x(-look_amt.y * pad_look_speed * delta)
			$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(80), deg_to_rad(80))

	if not interact_mode_active:
		move_and_slide()
		if not is_on_floor():
			climb_time += delta
		else:
			climb_time = 0.0
		if is_on_wall() and climb_time < MaxClimbTime and absf(Vector2(movement_dir.x, movement_dir.z).length()) > 0.0:
			climb(delta)
		if is_on_floor() and Input.is_action_just_pressed("jump", true) and not _menu_just_closed:
			velocity.y = jump_speed
		$UI/Cursor.label_settings.font_color = Color.WHITE
	else:
		$UI/Cursor.label_settings.font_color = Color.BLACK
	_menu_just_closed = false

func climb(delta):
	if climbed_distance < MaxClimbDistance:
		climbed_distance += (gravity * delta) * ClimbSpeed
		velocity.y += (gravity * delta) * ClimbSpeed
	else:
		velocity.y = 0.0
		climbed_distance = 0.0

func _on_menu_visibility_changed() -> void:
	if not $WindowMenuLayer/WindowMenu.visible \
			and not $PauseMenuLayer/PauseMenu.visible \
			and not $RadialMenuLayer/RadialMenu.visible:
		_menu_just_closed = true

func _input(event):
	if _pad_diag:
		_pad_diag_event(event)
	# Manette dans les menus : activer le bouton focalisé directement.
	if event is InputEventJoypadButton and event.pressed:
		if _pad_menu_activate(event):
			return
	if focus_mode_active:
		return
	if $RadialMenuLayer/RadialMenu.visible:
		return
	if $PauseMenuLayer/PauseMenu.visible:
		# Afficher la souris uniquement quand l'utilisateur la bouge (pas au d-pad).
		if event is InputEventMouseMotion or (event is InputEventMouseButton and event.pressed):
			if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if $CaptureSelectorLayer/CaptureSelector.visible:
		return
	# Chargement de la map LAN : tout l'input jeu est gelé (déplacement,
	# caméra, clics) sauf Escape pour ouvrir le menu pause (annuler).
	if input_locked and not event.is_action_pressed("pause_menu"):
		return
	if event.is_action_pressed("pause_menu") and not interact_mode_active:
		if session_locked:
			return
		if $WindowMenuLayer/WindowMenu.visible:
			return
		# Un overlay keyboard-interactive (rofi, menu waybar...) détient le
		# clavier : laisser l'Escape lui être routé au lieu d'ouvrir le menu
		# pause.
		if _get_compositor() and _get_compositor().get_keyboard_focus_layer_id() >= 0:
			return
		$PauseMenuLayer/PauseMenu.show_menu()
	if $PauseMenuLayer/PauseMenu.visible or $CaptureSelectorLayer/CaptureSelector.visible or $WindowMenuLayer/WindowMenu.visible:
		return
	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		if layer_pointer_active or session_locked:
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		$Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x, -deg_to_rad(80), deg_to_rad(80))

## Trace brute des événements manette (axes dédupliqués à ±0.05). La liste
## des pads connectés est imprimée une fois au premier événement reçu.
func _pad_diag_event(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if event.pressed:
			print("[PadDiag] device=%d button=%d pressed" % [
				event.device, event.button_index])
	elif event is InputEventJoypadMotion:
		var key := "%d|%d" % [event.device, event.axis]
		var prev := float(_pad_diag_axes.get(key, 99.0))
		if absf(event.axis_value - prev) > 0.05:
			_pad_diag_axes[key] = event.axis_value
			print("[PadDiag] device=%d axis=%d value=%+.2f" % [
				event.device, event.axis, event.axis_value])
	elif _pad_diag_axes.is_empty() or not _pad_diag_axes.has("_pads_listed"):
		_pad_diag_axes["_pads_listed"] = true
		for d in Input.get_connected_joypads():
			print("[PadDiag] pad connecté : device=%d name=\"%s\" guid=%s" % [
				d, Input.get_joy_name(d), Input.get_joy_guid(d)])

func _pad_menu_activate(event: InputEventJoypadButton) -> bool:
	# A sert à la fois de jump (jeu) et de confirm (menus).
	# Si un bouton UI est focalisé, A l'active (comme ui_accept).
	if event.button_index != JOY_BUTTON_A:
		return false
	var fe := get_viewport().gui_get_focus_owner()
	if fe == null or not fe is BaseButton:
		return false
	if fe.disabled:
		return false
	fe.pressed.emit()
	return true
