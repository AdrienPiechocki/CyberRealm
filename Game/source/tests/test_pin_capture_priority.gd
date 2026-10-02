extends Node
## Tests de la cadence de capture du PiP (pinned_windows.gd).
##
## BUG : la fenêtre épinglée n'avait AUCUNE garantie de cadence. Le
## compositeur n'accorde la cadence prioritaire (FAST) qu'à UNE fenêtre — celle
## du mode focus — et épingler ne passait par rien du tout. Le PiP retombait
## donc sur la cadence SLOW des quads 3D, et le mode focus, qui charge le GPU,
## fait monter `capture_pressure` : le palier SLOW s'allonge de 33 ms à 100 ms
## puis 200 ms. D'où un PiP saccadé à 30, puis 10, puis 5 images/s.
##
## Le correctif fait de la priorité de capture un ENSEMBLE natif, et n'y inscrit
## la fenêtre épinglée que lorsque son PiP est RÉELLEMENT affiché : une priorité
## payée en captures GPU pour une image cachée derrière l'overlay de focus
## serait du gaspillage — et aggraverait la pression qu'on essaie de dodger.
##
## Le basculement du mode focus n'est pas observable depuis pins (aucun signal),
## d'où la réévaluation dans _process : c'est déjà là que pins lit
## `focus.focus_mode` chaque frame pour le survol du PiP. _sync_capture_priority
## est idempotente, donc la poll ne coûte qu'une comparaison par frame.

const Runner = preload("res://tests/runner.gd")
const Pins = preload("res://scripts/windows/pinned_windows.gd")
const CompStub = preload("res://tests/fixtures/focus_compositor_stub.gd")

var comp: Node
var ui: CanvasLayer
var pins: Node3D
var focus_stub: Node3D
var layers: Node3D

func _setup() -> Variant:
	comp = CompStub.new()
	get_tree().root.add_child(comp)
	ui = CanvasLayer.new()
	get_tree().root.add_child(ui)
	# setup() lit _layers._cursor_pos : un Factice suffit, on ne teste pas le
	# curseur du monde ici.
	var layers_script := GDScript.new()
	layers_script.source_code = "extends Node3D\nvar _cursor_pos := Vector2.ZERO"
	if layers_script.reload() != OK:
		return "échec de compilation du fake layers"
	layers = Node3D.new()
	layers.set_script(layers_script)
	get_tree().root.add_child(layers)
	# Factice du mode focus : il ne faut porter que les DEUX champs que
	# pinned_windows lit (focus_mode pour la visibilité du PiP,
	# focus_fullscreen_id pour le survol). Le script de pinned_windows
	# lui-même ne convient pas — focus_mode n'y existe pas.
	var focus_script := GDScript.new()
	focus_script.source_code = "extends Node3D\nvar focus_mode := false\nvar focus_fullscreen_id := -1\nvar mouse_pos := Vector2.ZERO"
	if focus_script.reload() != OK:
		return "échec de compilation du fake focus"
	focus_stub = Node3D.new()
	focus_stub.set_script(focus_script)
	get_tree().root.add_child(focus_stub)
	pins = Pins.new()
	get_tree().root.add_child(pins)
	pins.setup(ui, focus_stub, layers, comp)
	var img := Image.create(640, 360, false, Image.FORMAT_RGBA8)
	pins.pin(1, ImageTexture.create_from_image(img))
	if not pins.pinned_windows.has(1):
		return "le PiP n'a pas été créé"
	return true

## Une frame de pinned_windows : c'est là que la priorité est réévaluée.
func _frame() -> void:
	pins._process(0.016)

func _teardown() -> void:
	for n in [pins, focus_stub, layers, ui, comp]:
		if n != null and is_instance_valid(n):
			n.free()
	pins = null
	focus_stub = null
	layers = null
	ui = null
	comp = null

func _fail(res) -> bool:
	return res is String

func _with(res) -> Variant:
	if _fail(res):
		_teardown()
		return res
	return true

# ── Cas nominal ─────────────────────────────────────────────────────────

func test_pinned_window_gets_priority_capture() -> Variant:
	## Le PiP affiché hors focus EST une image à l'écran : sa fenêtre doit
	## bénéficier de la cadence prioritaire. C'est le cœur du correctif.
	if _setup() != true: return "setup"
	_frame()
	var res: Variant = Runner.assert_true(comp.is_capture_priority(1),
		"une fenêtre épinglée dont le PiP est visible doit être prioritaire")
	return _with(res)

# ── Le PiP caché derrière l'overlay de focus ─────────────────────────────

func test_pip_hidden_behind_focus_gets_no_priority() -> Variant:
	## En focus, le PiP est posé SOUS l'overlay plein écran (PIN_Z_BASE 1900 <
	## FOCUS_Z_BASE 2000) : il est invisible. Lui accorder la priorité
	##vereignnait des captures GPU par frame pour une image que personne ne
	##voit — et la pression GPU qui fait saccader le PiP enCirait.
	if _setup() != true: return "setup"
	focus_stub.focus_mode = true
	pins.set_pins_above_focus(false)
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(1),
		"un PiP caché derrière l'overlay de focus ne doit pas être prioritaire")
	return _with(res)

func test_pip_above_focus_gets_priority() -> Variant:
	## Symétrique : avec pins_above_focus, le PiP EST visible en focus, donc il
	## doit retrouver la priorité. C'est le réglage du menu pause.
	if _setup() != true: return "setup"
	focus_stub.focus_mode = true
	pins.set_pins_above_focus(true)
	_frame()
	var res: Variant = Runner.assert_true(comp.is_capture_priority(1),
		"un PiP au-dessus du focus doit être prioritaire")
	return _with(res)

func test_toggling_above_focus_re_evaluates_priority() -> Variant:
	## Le réglage pins_above_focus bascule EN COURS de focus : la priorité doit
	## suivre, sans ré-épingler. Sans réévaluation, le PiP resterait à 30/s
	## (voire 5/s sous pression) alors qu'il vient de devenir visible.
	if _setup() != true: return "setup"
	focus_stub.focus_mode = true
	pins.set_pins_above_focus(false)
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(1),
		"précondition : caché, donc non prioritaire")
	if _fail(res): return _with(res)
	pins.set_pins_above_focus(true)
	_frame()
	res = Runner.assert_true(comp.is_capture_priority(1),
		"basculer pins_above_focus doit rendre la priorité dès la frame suivante")
	return _with(res)

func test_entering_focus_re_evaluates_priority() -> Variant:
	## L'entrée en focus ne passe par aucun setter de pins : il n'y a pas de
	## signal d'entrée/sortie de focus. Sans la réévaluation par frame, le PiP
	## garderait sa priorité alors qu'il passe derrière l'overlay — le cas
	## exact du saccadé signalé.
	if _setup() != true: return "setup"
	_frame()
	var res: Variant = Runner.assert_true(comp.is_capture_priority(1),
		"précondition : prioritaire hors focus")
	if _fail(res): return _with(res)
	focus_stub.focus_mode = true
	_frame()
	res = Runner.assert_true(not comp.is_capture_priority(1),
		"l'entrée en focus doit révoquer la priorité d'un PiP désormais caché")
	return _with(res)

# ── Le PiP rendu totalement invisible ────────────────────────────────────

func test_fully_transparent_pip_gets_no_priority() -> Variant:
	## Opacité 100 % : le PiP est invisible, capture inutile.
	if _setup() != true: return "setup"
	pins.set_pins_opacity(100)
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(1),
		"un PiP à 100 % d'opacité ne doit pas être prioritaire")
	return _with(res)

# ── Libération ───────────────────────────────────────────────────────────

func test_unpin_releases_priority() -> Variant:
	## Déposer le PiP rend les captures inutiles : la priorité doit être
	## révoquée, sinon la fenêtre garderait une cadence 60/s pour rien — et
	## pèserait sur la pression GPU pour le reste de la session.
	if _setup() != true: return "setup"
	_frame()
	var res: Variant = Runner.assert_true(comp.is_capture_priority(1),
		"précondition : épinglée = prioritaire")
	if _fail(res): return _with(res)
	pins.unpin(1)
	_frame()
	res = Runner.assert_true(not comp.is_capture_priority(1),
		"déposer le PiP doit révoquer la priorité de capture")
	return _with(res)

func test_replacing_the_pin_moves_the_priority() -> Variant:
	## Il n'y a qu'un PiP à la fois : épingler B après A doit RÉVOQUER A, pas
	## laisser les deux. Sans révocation, l'ensemble natif accumule des ids
	## périmés, que plus rien ne retire ensuite.
	if _setup() != true: return "setup"
	var img := Image.create(640, 360, false, Image.FORMAT_RGBA8)
	pins.pin(2, ImageTexture.create_from_image(img))
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(1),
		"l'ancienne fenêtre épinglée doit perdre la priorité")
	if _fail(res): return _with(res)
	res = Runner.assert_true(comp.is_capture_priority(2),
		"la nouvelle fenêtre épinglée doit prendre la priorité")
	return _with(res)

# ── Les pins distants ────────────────────────────────────────────────────

func test_remote_pin_never_gets_priority() -> Variant:
	## Un pin distant est le flux d'un AUTRE joueur : il n'y a pas de surface
	## wlr locale à capturer, la priorité serait un no-op côté compositeur.
	## Laisser l'entrée dans l'ensemble encoderait un id inexistant.
	if _setup() != true: return "setup"
	var img := Image.create(640, 360, false, Image.FORMAT_RGBA8)
	pins.pin_remote(7, 3, ImageTexture.create_from_image(img))
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(3),
		"un pin distant ne doit jamais être prioritaire")
	return _with(res)

func test_remote_pin_does_not_revoke_the_local_one() -> Variant:
	## Un pin distant peut remplacer un pin LOCAL (un seul PiP à la fois).
	## L'épinglage distant ne doit donc pas révoquer par accident la priorité
	## d'une fenêtre locale : le révoquement ne concerne que le pin LOCAL qui
	## sort, pas le pin entrant.
	if _setup() != true: return "setup"
	_frame()
	var img := Image.create(640, 360, false, Image.FORMAT_RGBA8)
	pins.pin_remote(7, 3, ImageTexture.create_from_image(img))
	_frame()
	var res: Variant = Runner.assert_true(not comp.is_capture_priority(1),
		"le pin local remplacé par un pin distant doit perdre la priorité")
	return _with(res)

# ── Non-régression du câblage ───────────────────────────────────────────

func test_setup_gives_pins_the_compositor() -> Variant:
	## setup() est le SEUL endroit où pins reçoit ses références. Si le
	## compositeur n'y est pas câblé, _sync_capture_priority() reste inerte en
	## silence et tous les autres tests passent pour la mauvaise raison.
	var src := FileAccess.get_file_as_string("res://scripts/main/wayland_room.gd")
	if src.is_empty():
		return "scripts/main/wayland_room.gd introuvable"
	if not src.contains("pins.setup(ui, focus, layers, compositor)"):
		return "wayland_room doit passer le compositeur à pins.setup()"
	return true
