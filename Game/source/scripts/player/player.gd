extends CharacterBody3D

@export var MaxDepth := 50
@export var StepHeight := 0.5 # hauteur max d'UNE marche
@export var StepSmoothSpeed := 12.0
@export var gravity:float = 9.8

var _cam_rest_y := 0.0
var _cam_rest_default := 0.0
var _head_follow := Vector3.ZERO     # écart caméra voulu (suivi de la tête de l'avatar)
var _head_applied := Vector3.ZERO    # part déjà ajoutée à Camera3D.position
var _body_radius := 0.3
var _floor_grace := 0.0

const PROP_LAYER := 1 << 20   # couche physique des objets de décor (props.gd du niveau)
var speed = 5
var jump_speed = 3
var mouse_sensitivity = 0.002

# Vitesse angulaire du stick droit à pleine déflexion (rad/s), réponse
# quadratique pour la précision en near-center. La souris garde son chemin
# InputEventMouseMotion, inchangé. Les touches fléchées (actions look_*)
# suivent le même chemin.
var pad_look_speed := 2.5

# Visée au gyroscope de manette (Input.get_joy_gyroscope, rad/s).
# SDL (Switch/PlayStation convention) : gyro.x = roll, gyro.y = yaw, gyro.z = pitch.
# _gyro_device = premier joypad connecté avec capteurs.
var gyro_aim_enabled := false
var gyro_speed := 1.0
const GYRO_DEADZONE := 0.05
const GYRO_BASE_SCALE := 0.1
var _gyro_device := -1

var interact_mode_active := false
var focus_mode_active := false
# Positionné par wayland_room.gd : vrai quand la caméra libre est active.
# Le corps du joueur est figé (pas de gravité, pas de déplacement) et toute
# l'entrée jeu est routée vers le nœud FreeCam (scripts/player/free_cam.gd)
# via le retour anticipé de _input.
var freecam_active := false
var _menu_just_closed := false
# Positionné par wayland_room.gd : vrai quand la souris survole une layer
# surface (waybar/rofi) en mode visible. Empêche le click de recapturer la
# souris (FPS) pour laisser wayland_room forwarder le clic vers l'overlay.
var layer_pointer_active := false
# Positionné par wayland_room.gd : vrai tant que le session est verrouillé.
# Empêche la recapture de la souris (MOUSE_MODE_CAPTURED) pendant le lockscreen.
var session_locked := false
# Positionné par wayland_room.gd (via pins.zoom_changed) : vrai pendant la
# loupe sur une fenêtre épinglée. La souris est alors capturée pour recadrer le
# PiP : elle ne doit plus piloter la caméra, et le monde est figé comme pour le
# menu pause.
var pin_zoom_active := false
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
var _pad_diag_gyro_ticks := 0

var spawn_pos: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.ZERO
var spawn_scale: Vector3 = Vector3.ONE

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Objets de décor physiques : collision (pour les pousser) mais jamais « plateforme » — leur mouvement ne
	# porte ni ne déplace le joueur.
	collision_mask |= PROP_LAYER
	platform_floor_layers = 0xFFFFFFFF & ~PROP_LAYER
	platform_wall_layers = 0xFFFFFFFF & ~PROP_LAYER
	spawn_pos = position
	spawn_rotation = rotation
	spawn_scale = scale
	_cam_rest_y = $Camera3D.position.y
	_cam_rest_default = _cam_rest_y
	for c in get_children():
		if c is CollisionShape3D and c.shape != null and "radius" in c.shape:
			_body_radius = c.shape.radius
			break
	floor_snap_length = StepHeight # colle au sol en descendant les escaliers
	$WindowMenuLayer/WindowMenu.visibility_changed.connect(_on_menu_visibility_changed)
	$PauseMenuLayer/PauseMenu.visibility_changed.connect(_on_menu_visibility_changed)
	$RadialMenuLayer/RadialMenu.visibility_changed.connect(_on_menu_visibility_changed)
	$PauseMenuLayer/PauseMenu.respawn_requested.connect(respawn)
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)
	_apply_cursor_css()
	# Vérification gyro : print de présence des capteurs manette, activé par
	# CYBERREALM_PAD_DEBUG=1 (ex. à valider avec une 8BitDo après passage à
	# Godot 4.8, dont le SDL 3.4.16 inclut le driver HIDAPI 8BitDo).
	if _pad_diag:
		for dev in Input.get_connected_joypads():
			print("PAD dev=%d guid=%s has_sensors=%s" % [
				dev, Input.get_joy_guid(dev), Input.has_joy_motion_sensors(dev)])

func respawn() -> void:
	position = spawn_pos
	rotation = spawn_rotation
	velocity = Vector3.ZERO

func _apply_cursor_css() -> void:
	var cursor := get_node_or_null("UI/Cursor")
	if cursor is Label and (cursor as Label).label_settings != null:
		(cursor as Label).label_settings.font_size = int(UITheme.get_number("hud", "cursor-size", 24.0))

func _on_stylesheet_reloaded() -> void:
	_apply_cursor_css()

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
	if freecam_active:
		return
	if position.y <= -MaxDepth:
		position = spawn_pos
	if velocity.y > jump_speed:
		velocity.y = jump_speed
	velocity.y += -gravity * delta
	if $WindowMenuLayer/WindowMenu.visible or $PauseMenuLayer/PauseMenu.visible or focus_mode_active or _keyboard_busy() or input_locked or session_locked or pin_zoom_active or $RadialMenuLayer/RadialMenu.visible or $TutorialLayer/Tutorial.visible:
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
			$Camera3D.rotation.x = clampf($Camera3D.rotation.x - look_amt.y * pad_look_speed * delta, -deg_to_rad(80), deg_to_rad(80))
		if gyro_aim_enabled:
			if _gyro_device >= 0 and not Input.get_connected_joypads().has(_gyro_device):
				_gyro_device = -1
			if _gyro_device < 0:
				_resolve_gyro_device()
			if _gyro_device >= 0:
				var raw_gyro := Input.get_joy_gyroscope(_gyro_device)
				if _pad_diag:
					_pad_diag_gyro_ticks += 1
					if _pad_diag_gyro_ticks >= 20 and (absf(raw_gyro.x) > 0.02 or absf(raw_gyro.y) > 0.02 or absf(raw_gyro.z) > 0.02):
						_pad_diag_gyro_ticks = 0
						print("GYRO dev=%d x=%+.3f y=%+.3f z=%+.3f" % [_gyro_device, raw_gyro.x, raw_gyro.y, raw_gyro.z])
				_apply_gyro_aim(raw_gyro, gyro_speed, delta)

	if not interact_mode_active:
		_step_up(delta)
		move_and_slide()
		_push_rigid_bodies()
		if is_on_floor() and Input.is_action_just_pressed("jump", true) and not _menu_just_closed:
			velocity.y = jump_speed
		$UI/Cursor.label_settings.font_color = UITheme.get_color("hud", "cursor-color", Color(1, 1, 1))
	else:
		$UI/Cursor.label_settings.font_color = UITheme.get_color("hud", "cursor-active-color", Color(0, 0, 0))
	_menu_just_closed = false

func set_gyro_aim_enabled(enabled: bool) -> void:
	gyro_aim_enabled = enabled
	if not enabled:
		if _gyro_device >= 0:
			Input.set_joy_motion_sensors_enabled(_gyro_device, false)
		_gyro_device = -1
	else:
		_resolve_gyro_device()

func _resolve_gyro_device() -> void:
	_gyro_device = -1
	for dev in Input.get_connected_joypads():
		if Input.has_joy_motion_sensors(dev):
			_gyro_device = dev
			Input.set_joy_motion_sensors_enabled(dev, true)
			return

func _apply_gyro_aim(gyro: Vector3, sens: float, delta: float) -> void:
	var scaled := sens * GYRO_BASE_SCALE
	if absf(gyro.x) <= GYRO_DEADZONE and absf(gyro.y) <= GYRO_DEADZONE:
		return
	rotate_y(gyro.y * scaled * delta)
	# Modification directe de rotation.x avec clamp
	$Camera3D.rotation.x = clampf($Camera3D.rotation.x + gyro.x * scaled * delta, -deg_to_rad(80), deg_to_rad(80))

# Lissage caméra au rendu (pas au tick physique) : supprime le tremblement.
func _process(delta: float) -> void:
	# Le suivi de la tête de l'avatar (full body awareness) s'ajoute APRÈS le lissage des marches : on retire celui
	# de la frame précédente avant de lisser, sinon il serait lissé (retard) puis accumulé.
	$Camera3D.position -= _head_applied
	$Camera3D.position.y = lerpf($Camera3D.position.y, _cam_rest_y, 1.0 - exp(-StepSmoothSpeed * delta))
	_head_applied = _head_follow
	$Camera3D.position += _head_applied
	if tps_active:
		_update_tps_camera(delta)

# ── Vue 3e personne ──────────────────────────────────────────────────
# Le Camera3D du joueur reste la « tête » (visée, fenêtres, pitch réseau, prise d'objets) ; en TPS le rendu passe
# par une seconde caméra reculée le long de l'axe du regard (collision avec le décor). Comme elle est exactement
# sur l'axe tête→regard, le centre de l'écran vise toujours le même point que le viseur en première personne.
const TPS_DISTANCE := 3.0
const TPS_MIN_DISTANCE := 0.4        # plus près que ça, la caméra reste collée à la tête
const TPS_MARGIN := 0.25
var tps_active := false
var tps_distance := TPS_DISTANCE     # distance voulue (réglable)
var tps_dist_now := 0.0              # distance réelle après collision
var _tps_cam: Camera3D = null

## Le joueur est-il réellement en l'air (saut, chute) ? Utilisé par l'avatar pour l'animation de saut. S'appuie sur la
## physique (is_on_floor + la tolérance de _step_up qui absorbe le clignotement dans les escaliers) : une montée de
## marches ou de pente reste « au sol ». Un élan vers le haut compte tout de suite comme un saut.
func is_airborne() -> bool:
	if is_on_floor():
		return false
	return _floor_grace <= 0.0 or velocity.y > 1.0

## Écart (repère du joueur) à ajouter à la caméra pour qu'elle suive la tête animée de l'avatar.
func set_head_follow(offset: Vector3) -> void:
	_head_follow = offset
	# Appliqué tout de suite (l'avatar l'appelle après la mise à jour de son animation, dans la même frame) :
	# la caméra suit la tête sans retard d'une frame.
	$Camera3D.position += offset - _head_applied
	_head_applied = offset

## Hauteur de la caméra « tête » (1ère personne) : celle de la tête de l'avatar. NAN = hauteur par défaut de la scène.
func set_eye_height(y: float) -> void:
	_cam_rest_y = _cam_rest_default if is_nan(y) else y

func set_tps(on: bool) -> void:
	if on == tps_active:
		return
	tps_active = on
	if on:
		if _tps_cam == null:
			_tps_cam = Camera3D.new()
			_tps_cam.name = "TpsCamera"
			add_child(_tps_cam)
		tps_dist_now = 0.0
		_update_tps_camera(1.0)
	refresh_current_camera()

## Rend courante la bonne caméra (appelé aussi à la sortie de la vue libre).
func refresh_current_camera() -> void:
	if freecam_active:
		return
	if tps_active and _tps_cam != null:
		_tps_cam.make_current()
	else:
		$Camera3D.make_current()

## Caméra qui produit l'image du joueur (pour projeter les rayons de visée).
func get_view_camera() -> Camera3D:
	return _tps_cam if tps_active and _tps_cam != null else $Camera3D as Camera3D

## Rayon de visée sous la souris/viseur : [origine, direction]. En TPS l'origine est avancée jusqu'à la tête
## pour que la portée d'interaction se compte depuis le joueur, pas depuis la caméra reculée.
func aim_ray(mouse_pos: Vector2) -> Array:
	var cam := get_view_camera()
	var origin := cam.project_ray_origin(mouse_pos)
	var dir := cam.project_ray_normal(mouse_pos)
	if tps_active:
		origin += dir * tps_dist_now
	return [origin, dir]

func _update_tps_camera(delta: float) -> void:
	var head := $Camera3D as Camera3D
	var hp := head.global_position
	var back := head.global_basis.z
	var want := tps_distance
	var q := PhysicsRayQueryParameters3D.create(hp, hp + back * (tps_distance + TPS_MARGIN), 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = clampf(hp.distance_to(hit.position) - TPS_MARGIN, TPS_MIN_DISTANCE, tps_distance)
	# Se rapproche vite (pas de traversée de mur), s'éloigne en douceur.
	tps_dist_now = want if want < tps_dist_now or tps_dist_now == 0.0 \
			else lerpf(tps_dist_now, want, 1.0 - exp(-8.0 * delta))
	_tps_cam.global_transform = Transform3D(head.global_basis, hp + back * tps_dist_now)
	# Mêmes réglages de rendu que la tête (l'intérieur y pose son propre Environment, interiors.gd).
	if _tps_cam.environment != head.environment:
		_tps_cam.environment = head.environment
	if _tps_cam.attributes != head.attributes:
		_tps_cam.attributes = head.attributes
	_tps_cam.cull_mask = head.cull_mask
	_tps_cam.fov = head.fov
	_tps_cam.near = head.near
	_tps_cam.far = head.far
	_tps_cam.keep_aspect = head.keep_aspect

func _ground_y(from: Vector3, length: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * length, collision_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or hit.normal.y < cos(floor_max_angle):
		return NAN
	return hit.position.y

func _step_up(delta: float) -> void:
	# Petite tolérance : is_on_floor() clignote en montant
	if is_on_floor():
		_floor_grace = 0.1
	else:
		_floor_grace -= delta
	if _floor_grace <= 0.0 or velocity.y > 0.0:
		return
	var h := Vector3(velocity.x, 0.0, velocity.z)
	if h.is_zero_approx():
		return
	var dir := h.normalized()
	var xf := global_transform

	# Rien devant : pas de marche
	var fwd := KinematicCollision3D.new()
	if not test_move(xf, dir * (h.length() * delta + 0.05), fwd):
		return
	# Pente praticable : move_and_slide la monte déjà, pas de step-up
	if fwd.get_normal().y >= cos(floor_max_angle) - 0.01:
		return

	# Hauteur de montée limitée par le dégagement au-dessus de la tête
	var up := Vector3.UP * StepHeight
	var col := KinematicCollision3D.new()
	if test_move(xf, up, col):
		up = col.get_travel()
	if up.y < 0.05:
		return

	# Corps relevé : doit pouvoir avancer un peu
	if test_move(xf.translated(up), dir * 0.05):
		return

	# Hauteur du sol actuel, puis du dessus de la marche juste devant le bord
	# de la capsule (indépendant de la profondeur des marches)
	var base := _ground_y(xf.origin + Vector3.UP * 0.05, 4.0)
	if is_nan(base):
		return
	var ahead := xf.origin + dir * (_body_radius + 0.03)
	ahead.y = base + up.y + 0.02
	var top := _ground_y(ahead, up.y + 0.04)
	if is_nan(top):
		return

	var gained := top - base
	if gained > 0.03 and gained <= up.y:
		global_position.y += gained
		$Camera3D.position.y -= gained # rattrapé par le lerp dans _process

func _on_menu_visibility_changed() -> void:
	if not $WindowMenuLayer/WindowMenu.visible \
			and not $PauseMenuLayer/PauseMenu.visible \
			and not $RadialMenuLayer/RadialMenu.visible:
		_menu_just_closed = true

func _input(event):
	if _pad_diag:
		_pad_diag_event(event)
	# Caméra libre : le joueur n'est plus pilotable — seuls la gestion du
	# menu pause (Escape) reste ici, tout le reste de l'input est géré par
	# le nœud FreeCam.
	if freecam_active:
		if event.is_action_pressed("pause_menu") and not session_locked \
				and not _get_compositor().get_keyboard_focus_layer_id() >= 0:
			$PauseMenuLayer/PauseMenu.show_menu()
		return
	# Manette dans les menus : activer le bouton focalisé directement.
	if event is InputEventJoypadButton and event.pressed:
		if _pad_menu_activate(event):
			return
	if focus_mode_active:
		return
	# Loupe sur un PiP : la souris est capturée pour recadrer la fenêtre
	# épinglée. Retour sans condition — pinned_windows consomme l'input de la
	# loupe (molette, mouvement, Échap), et le joueur ne doit surtout pas
	# ouvrir le menu pause sur l'Échap qui referme la loupe. Cette sortie
	# inconditionnelle rend le comportement indépendant de l'ordre de
	# propagation de _input entre les deux nœuds.
	if pin_zoom_active:
		return
	if $RadialMenuLayer/RadialMenu.visible:
		return
	if $TutorialLayer/Tutorial.visible:
		# Tutoriel ouvert : la souris reste libre (les boutons du tuto
		# capturent le clic) et aucun input ne touche au jeu.
		if event is InputEventMouseMotion or (event is InputEventMouseButton and event.pressed):
			if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
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
		# Modification directe de rotation.x avec clamp
		$Camera3D.rotation.x = clampf($Camera3D.rotation.x - event.relative.y * mouse_sensitivity, -deg_to_rad(80), deg_to_rad(80))

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
			print("[PadDiag] pad connected : device=%d name=\"%s\" guid=%s" % [
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
	# Bouton toggle (CheckButton…) : émettre `pressed` ne bascule pas l'état
	# (flip interne du GUI). On laisse l'événement atteindre le GUI, seul
	# capable de toggler correctement.
	if fe.toggle_mode:
		return false
	fe.pressed.emit()
	get_viewport().set_input_as_handled()
	return true


# Le joueur pousse les RigidBody3D qu'il percute (objets de décor physiques) ; la vitesse transmise reste
# modeste pour qu'un simple frôlement ne les propulse pas.
func _push_rigid_bodies() -> void:
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var rb := col.get_collider() as RigidBody3D
		if rb == null:
			continue
		var push := -col.get_normal()
		push.y = 0.0
		var spd := Vector3(velocity.x, 0.0, velocity.z).length()
		var impulse := Vector3.ZERO
		if spd >= 0.1 and push != Vector3.ZERO:
			impulse = push.normalized() * minf(spd, 4.0) * minf(rb.mass, 3.0) * 0.5
		if rb.freeze:       # objet de décor encore figé : le contact enclenche sa physique (ou la demande au serveur)
			if rb.has_method("touch"):
				rb.touch(impulse)
			continue
		if impulse == Vector3.ZERO:
			continue
		rb.sleeping = false
		rb.apply_impulse(impulse, col.get_position() - rb.global_position)
