extends Node
## Tests de la rotation d'une fenêtre collée au scroll (_rotate_snapped).
##
## Une seule action, « scroll_up »/« scroll_down », sert DEUX périphériques aux
## sémantiques opposées : la molette émet un événement par cran (discret), une
## gâchette manette reste pressée tant qu'on la tient (continu). Tant que les
## deux passent par le même code, tenir la gâchette appliquait un cran de 15°
## À CHAQUE FRAME — un tour en quatre secondes.
##
## Ces tests verrouillent donc l'angle réellement appliqué, pas la source :
##  - un cran de molette vaut SNAP_YAW_STEP (15°) ;
##  - une seconde de gâchette tenue vaut SNAP_ROTATE_RATE (90°), donc 1.5° par
##    frame à 60 Hz, et non 15°.
##
## La DÉTECTION du périphérique (_scroll_from_gamepad) n'est pas couverte ici :
## elle lit l'état réel d'une manette, qu'aucun test headless ne peut
## fabriquer. Elle reste vérifiée à la manette.
##
## Aucune liaison n'est installée à la main : le collage vient d'un recouvrement
## RÉEL de zones (moteur physique), pas d'un dictionnaire écrit.

const Runner := preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

const WID := 41
const NEI := 42
const MESH := Vector2(3.2, 2.0)

# Fenêtres de largeur 3.2 placées bord à bord : la moitié de WID est à x=1.6 et
# celle de NEI à x=3.2-1.6, donc leurs zones de bord sont centrées au MÊME point.
const FLUSH_X := 3.2

const FRAME := 1.0 / 60.0
const TOL := 0.002 # rad

## Périphérique de la manette simulée. Les binds du projet sont enregistrés avec
## device = -1 (« n'importe quelle manette ») : l'événement transporte le
## périphérique réel, c'est la détection qui doit savoir le retrouver.
const PAD_DEVICE := 0

var win3d: Node3D
var player: Node3D

# Repères de la mesure : la base ET l'axe sont capturés AVANT toute rotation.
# La zone de pivot est un enfant du quad, elle tourne donc avec lui — l'axe
# doit être figé au départ, pas relu après coup.
var _before: Basis
var _axis: Vector3


# Monde à deux fenêtres réellement collées bord à bord (côté « right »).
func _build_world() -> Variant:
	win3d = Node3D.new()
	win3d.set_script(Windows3DScript)
	player = Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	player.add_child(cam)
	get_tree().root.add_child(player)
	get_tree().root.add_child(win3d)
	win3d.setup(null, player)
	win3d.on_window_mapped(WID, "Test Window", "app")
	(win3d.quads[WID].mesh as QuadMesh).size = MESH
	win3d.quads[WID].position = Vector3.ZERO
	win3d.on_window_mapped(NEI, "Neighbour", "app")
	(win3d.quads[NEI].mesh as QuadMesh).size = MESH
	win3d.quads[NEI].position = Vector3(FLUSH_X, 0.0, 0.0)
	win3d.active_window_id = WID
	# Une seule fenêtre inventorie ses recouvrements : c'est ce que fait le
	# déplacement réel en tête de frame.
	win3d._sync_snap_monitoring(WID)
	# Le recouvrement de deux Area3D est un état du moteur physique : il
	# n'existe qu'après un pas de simulation.
	await get_tree().physics_frame
	await get_tree().physics_frame
	win3d._set_snap(WID, win3d._find_snap(Vector3.ZERO))
	if not win3d.snapped_to.has(WID):
		return "les deux fenêtres bord à bord ne se sont pas collées"
	return true

func _teardown(res: Variant) -> Variant:
	_release_scroll()
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()
	return res

func _fail(res: Variant) -> bool:
	return res is String

# Fige les repères avant une série de rotations.
func _mark() -> void:
	var area: Area3D = win3d._snap_pivot_area(WID)
	_axis = area.global_transform.basis.y.normalized()
	_before = win3d._stored_basis(WID)

# Angle déjà parcouru autour de l'axe du pivot, mesuré sur un vecteur
# perpendiculaire à cet axe (la profondeur de la fenêtre) : c'est l'angle que
# voit le joueur.
#
# Négation volontaire : Vector3.signed_angle_to() tire son signe de
# self.cross(to), soit la convention INVERSÉE de la règle de la main droite.
# On ramène donc la mesure dans le sens de l'angle appliqué, pour que le test
# se lise comme la constante qu'il vérifie.
func _turned() -> float:
	return -_before.z.signed_angle_to(win3d._stored_basis(WID).z, _axis)

# Une action Input maintenue, simulée SANS manette : c'est la branche molette
# qui s'exerce.
func _press(action: String) -> void:
	Input.action_press(action)

# Une VRAIE gâchette de manette : le même événement que celui du pilote, qui
# traverse l'InputMap du projet — c'est le trajet réel, pas une simulation de la
# sortie. L'InputMap enregistre les binds avec device = -1 (« n'importe quelle
# manette ») ; l'événement garde le périphérique réel, PAD_DEVICE.
#
# L'état n'est visible qu'APRÈS une frame : parse_input_event met l'événement
# en file, il est dépensé au flush d'entrée suivant.
func _press_pad(button: int) -> void:
	var ev := InputEventJoypadButton.new()
	ev.device = PAD_DEVICE
	ev.button_index = button
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().physics_frame

func _release_pad(button: int) -> void:
	var ev := InputEventJoypadButton.new()
	ev.device = PAD_DEVICE
	ev.button_index = button
	ev.pressed = false
	Input.parse_input_event(ev)
	await get_tree().physics_frame

func _release_scroll() -> void:
	for action: String in ["scroll_up", "scroll_down"]:
		if Input.is_action_pressed(action):
			Input.action_release(action)


func test_a_gamepad_button_is_read_as_a_gamepad_scroll() -> Variant:
	## Les binds du projet enregistrent la gâchette avec device = -1, qui
	## signifie « n'importe quelle manette » et n'est AUCUN périphérique :
	## interroger son état répond toujours faux. La gâchette retombait alors sur
	## le cran de molette — 15° par frame — et le taux restait mort. Ce test
	## Covers le chemin de détection complet, sur les binds RÉELS du projet.
	var ctx: Variant = await _build_world()
	if _fail(ctx):
		return ctx
	await _press_pad(JOY_BUTTON_LEFT_SHOULDER)
	var res: Variant = Runner.assert_true(win3d._scroll_from_gamepad("scroll_up"),
		"la gâchette haute pressée doit être reconnue comme manette")
	if _fail(res):
		await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
		return _teardown(res)
	res = Runner.assert_true(not win3d._scroll_from_gamepad("scroll_down"),
		"et elle ne doit rien faire pour l'autre sens")
	if _fail(res):
		await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
		return _teardown(res)
	await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
	res = Runner.assert_true(not win3d._scroll_from_gamepad("scroll_up"),
		"le relâchement doit être vu : pas d'état collé")
	return _teardown(res)


func test_pad_devices_never_query_the_device_minus_one() -> Variant:
	## L'invariant qui a fait le bug : un bind est enregistré avec device = -1
	## (« n'importe quelle manette »), mais l'état d'un périphérique -1 n'existe
	## pas. La résolution doit donc laisser le -1 de côté et interroger les
	## manettes branchées. Le second paramètre est injecté pour pouvoir vérifier
	## ça sans brancher de matériel.
	var any_pad := InputEventJoypadButton.new()
	any_pad.device = -1
	any_pad.button_index = JOY_BUTTON_LEFT_SHOULDER
	var res: Variant = Runner.assert_eq(Windows3DScript._pad_devices(any_pad, [0]), [0],
		"un bind « n'importe quelle manette » doit se résoudre sur les manettes branchées")
	if _fail(res):
		return res
	var one_pad := InputEventJoypadButton.new()
	one_pad.device = 2
	one_pad.button_index = JOY_BUTTON_LEFT_SHOULDER
	res = Runner.assert_eq(Windows3DScript._pad_devices(one_pad, [0]), [0, 2],
		"un bind sur une manette précise doit rester interrogeable")
	if _fail(res):
		return res
	res = Runner.assert_true(not Windows3DScript._pad_devices(any_pad, [0, 3]).has(-1),
		"le -1 ne doit jamais être interrogé")
	return res

func test_a_wheel_step_turns_fifteen_degrees() -> Variant:
	## Le cran de molette reste ce qu'il est : 15°, dans un sens comme dans
	## l'autre. C'est le comportement de référence, à ne pas décaler.
	var ctx: Variant = await _build_world()
	if _fail(ctx):
		return ctx
	_mark()
	var res: Variant = Runner.assert_approx(_turned(), 0.0, TOL,
		"aucun cran avant le scroll")
	if _fail(res):
		return _teardown(res)
	win3d._rotate_snapped(win3d.SNAP_YAW_STEP)
	res = Runner.assert_approx(_turned(), win3d.SNAP_YAW_STEP, TOL,
		"un cran doit tourner de exactement SNAP_YAW_STEP")
	if _fail(res):
		return _teardown(res)
	win3d._rotate_snapped(-win3d.SNAP_YAW_STEP)
	res = Runner.assert_approx(_turned(), 0.0, TOL,
		"un cran inverse doit ramener à l'angle de départ")
	return _teardown(res)

func test_a_held_trigger_accumulates_a_quarter_turn_per_second() -> Variant:
	## Le défaut à verrouiller : la gâchette tenue appliquait un cran par frame.
	## Une frame de maintien vaut 1.5°, et une seconde un QUART DE TOUR — pas
	## 15° par frame, soit six tours.
	var ctx: Variant = await _build_world()
	if _fail(ctx):
		return ctx
	var res: Variant = Runner.assert_approx(win3d.SNAP_ROTATE_RATE, deg_to_rad(90.0), TOL,
		"le taux de la manette est un quart de tour par seconde")
	if _fail(res):
		return _teardown(res)
	_mark()
	win3d._rotate_snapped(win3d.SNAP_ROTATE_RATE * FRAME)
	res = Runner.assert_approx(_turned(), deg_to_rad(1.5), TOL,
		"une frame de gâchette vaut 1.5°, pas un cran de 15°")
	if _fail(res):
		return _teardown(res)
	for i in 59:
		win3d._rotate_snapped(win3d.SNAP_ROTATE_RATE * FRAME)
	res = Runner.assert_approx(_turned(), deg_to_rad(90.0), TOL,
		"une seconde de gâchette doit tourner d'un quart de tour")
	return _teardown(res)

func test_a_held_gamepad_scroll_turns_at_the_rate() -> Variant:
	## Le câblage réel, bout en bout : une gâchette TENUE fait tourner de
	## SNAP_ROTATE_RATE × delta par frame, sans passer par un cran. Ni la
	## détection seule ni un test qui calcule lui-même son angle ne prouvent que
	## le taux est utilisé — il faut les deux ensemble.
	var ctx: Variant = await _build_world()
	if _fail(ctx):
		return ctx
	await _press_pad(JOY_BUTTON_LEFT_SHOULDER)
	_mark()
	win3d._rotate_from_scroll(FRAME)
	var res: Variant = Runner.assert_approx(_turned(), deg_to_rad(1.5), TOL,
		"une frame de gâchette vaut 1.5°, pas un cran de 15°")
	if _fail(res):
		await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
		return _teardown(res)
	for i in 59:
		win3d._rotate_from_scroll(FRAME)
	res = Runner.assert_approx(_turned(), deg_to_rad(90.0), TOL,
		"une seconde de gâchette doit tourner d'un quart de tour")
	if _fail(res):
		await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
		return _teardown(res)
	# Relâchée : plus rien ne doit tourner, sinon la fenêtre continuerait sa
	# route toute seule une fois la gâchette lâchée.
	await _release_pad(JOY_BUTTON_LEFT_SHOULDER)
	win3d._rotate_from_scroll(FRAME)
	res = Runner.assert_approx(_turned(), deg_to_rad(90.0), TOL,
		"une gâchette relâchée ne doit plus rien faire")
	return _teardown(res)

func test_a_wheel_event_turns_exactly_one_step() -> Variant:
	## Le chemin souris passe par _rotate_from_scroll, qui décide du pas. Aucune
	## manette en headless : _scroll_from_gamepad() est donc toujours faux et
	## c'est bien la branche molette qui s'exerce — un CRAN par frame, jamais
	## le taux continu (1.5°), qui est la régression qu'on surveille.
	##
	## Action maintenue = un cran par frame : c'est le comportement d'avant,
	## inchangé, et une molette réelle n'étant pas maintenable (un événement
	## par cran), la différence ne s'observe pas au jeu.
	var ctx: Variant = await _build_world()
	if _fail(ctx):
		return ctx
	_mark()
	_press("scroll_up")
	win3d._rotate_from_scroll(FRAME)
	var res: Variant = Runner.assert_approx(_turned(), win3d.SNAP_YAW_STEP, TOL,
		"le scroll souris doit appliquer un cran")
	if _fail(res):
		return _teardown(res)
	win3d._rotate_from_scroll(FRAME)
	res = Runner.assert_approx(_turned(), 2.0 * win3d.SNAP_YAW_STEP, TOL,
		"et un second cran, pas le taux de la manette")
	if _fail(res):
		return _teardown(res)
	_release_scroll()
	_mark()
	_press("scroll_down")
	win3d._rotate_from_scroll(FRAME)
	res = Runner.assert_approx(_turned(), -win3d.SNAP_YAW_STEP, TOL,
		"scroll_down doit tourner dans l'autre sens")
	return _teardown(res)
