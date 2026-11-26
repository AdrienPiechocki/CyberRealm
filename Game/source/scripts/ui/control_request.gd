extends CanvasLayer
## Demande de prise de contrôle d'une fenêtre partagée (lot J), côté propriétaire.
##
## Dit explicitement ce que l'invité pourra faire ; Accepter / Refuser, refus automatique au bout de 15 s
## (le décompte vit dans LAN/RemoteControl, cette boîte ne fait qu'afficher et répondre). « Refuser » a le focus
## par défaut : un appui distrait sur Entrée / A ne donne jamais la main.

var remote_control: Node = null
var name_of: Callable            # (peer) -> String
var title_of: Callable           # (wid) -> String

var _wid := -1
var _shown_at := 0
var _prev_mouse := Input.MOUSE_MODE_CAPTURED
var _root: Control
var _title: Label
var _warn: Label
var _countdown: Label
var _refuse: Button

func setup(p_rc: Node, p_name_of: Callable, p_title_of: Callable) -> void:
	remote_control = p_rc
	name_of = p_name_of
	title_of = p_title_of
	remote_control.control_requested.connect(_on_requested)

func _ready() -> void:
	layer = 120
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 16)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(460, 0)
	margin.add_child(vbox)
	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_title)
	_warn = Label.new()
	_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	_warn.text = "In a terminal, this is full access to your session."
	vbox.add_child(_warn)
	_countdown = Label.new()
	_countdown.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_countdown)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)
	_refuse = Button.new()
	_refuse.text = "Decline"
	_refuse.pressed.connect(func(): _answer(false))
	buttons.add_child(_refuse)
	var accept := Button.new()
	accept.text = "Accept"
	accept.pressed.connect(func(): _answer(true))
	buttons.add_child(accept)

static func request_text(player: String, window: String) -> String:
	return "%s wants to control « %s ».\n%s will be able to click and type in this window." % [player, window, player]

func _on_requested(peer: int, wid: int) -> void:
	_wid = wid
	_shown_at = Time.get_ticks_msec()
	var player := String(name_of.call(peer)) if name_of.is_valid() else "Player %d" % peer
	var window := String(title_of.call(wid)) if title_of.is_valid() else "window %d" % wid
	_title.text = request_text(player, window)
	if not _root.visible:
		_prev_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_root.visible = true
	_refuse.grab_focus()

func _answer(ok: bool) -> void:
	if _wid != -1 and remote_control != null:
		remote_control.answer(_wid, ok)
	_close()

func _close() -> void:
	_wid = -1
	if _root.visible:
		_root.visible = false
		Input.mouse_mode = _prev_mouse

func _process(_delta: float) -> void:
	if not _root.visible:
		return
	# Refus automatique (ou demande annulée) : la demande n'est plus en attente dans le module.
	if remote_control == null or not remote_control._pending.has(_wid):
		_close()
		return
	var left := maxi(0, (remote_control.REQUEST_TIMEOUT_MSEC - (Time.get_ticks_msec() - _shown_at)) / 1000)
	_countdown.text = "Declined automatically in %d s" % left

func _input(event: InputEvent) -> void:
	if _root.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_answer(false)
		get_viewport().set_input_as_handled()
