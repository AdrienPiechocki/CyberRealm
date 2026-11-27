extends Node
## Clavier virtuel ouvert automatiquement sur un champ de texte (lot I, text_input_v3).
##
## Le compositeur émet text_input_changed(window_id, active, …) quand un champ de texte d'une fenêtre devient actif
## ou ne l'est plus. Selon l'option (General > Virtual keyboard on text fields) : « pad » (défaut : seulement si la
## dernière entrée vient d'une manette) ou « never ». Seulement quand le clavier va réellement à la
## fenêtre (mode focus ou mode interaction). Le clavier ouvert ainsi se referme seul quand le champ est quitté, sans
## couper le mode interaction ; un clavier ouvert à la main n'est jamais refermé par ce script.

var compositor: Object = null
var keyboard: Node = null            # VirtualKeyboard
var settings: Node = null            # pause_menu : get_osk_on_text_input()
var routed: Callable                 # () -> bool : le clavier du jeu va-t-il à une fenêtre ?

var _last_was_pad := false
var _auto_opened := false

func setup(p_compositor: Object, p_keyboard: Node, p_settings: Node, p_routed: Callable) -> void:
	compositor = p_compositor
	keyboard = p_keyboard
	settings = p_settings
	routed = p_routed
	if compositor != null and compositor.has_signal("text_input_changed"):
		compositor.text_input_changed.connect(on_text_input_changed)

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		_last_was_pad = true
	elif event is InputEventKey or event is InputEventMouseButton:
		_last_was_pad = false

func _mode() -> String:
	if settings != null and settings.has_method("get_osk_on_text_input"):
		return String(settings.get_osk_on_text_input())
	return "pad"

static func should_open(mode: String, last_was_pad: bool, keyboard_routed: bool) -> bool:
	if not keyboard_routed:
		return false
	return mode == "pad" and last_was_pad

func on_text_input_changed(_window_id: int, active: bool, _hint: int, _purpose: int, _rect: Rect2i) -> void:
	if keyboard == null:
		return
	if keyboard.has_method("_refresh_extra_row"):
		keyboard._refresh_extra_row()
	if active:
		var is_routed: bool = routed.is_valid() and bool(routed.call())
		if not keyboard.visible and should_open(_mode(), _last_was_pad, is_routed):
			keyboard.show_menu(null, false)
			_auto_opened = true
	elif _auto_opened:
		_auto_opened = false
		if keyboard.visible:
			keyboard.hide_menu(false)
