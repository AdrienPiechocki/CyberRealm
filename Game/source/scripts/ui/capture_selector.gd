extends GameMenu
## Sélecteur de cible de capture OBS. S'ouvre quand une source
## « Screen Capture (PipeWire) » est ajoutée dans OBS : xdg-desktop-portal-wlr
## écrit $XDG_RUNTIME_DIR/cyberrealm-capture-pending, le jeu détecte le fichier
## et affiche ce sélecteur pour choisir entre l'écran et les fenêtres ouvertes.
## Le choix est écrit dans cyberrealm-capture-choice, consommé par portal-wlr.

signal target_chosen(choice: String) # "screen" ou app_id/titre de fenêtre
signal selector_cancelled

var compositor: WlrCompositor

var _options_container: VBoxContainer
var _title_label: Label
var _hint_label: Label

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_build_ui()
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)

func setup(compositor_ref: WlrCompositor) -> void:
	compositor = compositor_ref

func _apply_styling() -> void:
	theme = UITheme.theme
	set_meta("ui_class", "menu-panel capture-menu")
	UITheme.apply_class(self, "menu-panel capture-menu")

func _on_stylesheet_reloaded() -> void:
	theme = UITheme.theme
	UITheme.apply_css(self)

func _build_ui() -> void:
	_apply_styling()

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.add_theme_constant_override("content_margin_left", 20)
	vbox.add_theme_constant_override("content_margin_right", 20)
	vbox.add_theme_constant_override("content_margin_top", 16)
	vbox.add_theme_constant_override("content_margin_bottom", 16)
	add_child(vbox)

	_title_label = Label.new()
	_title_label.text = "CHOSE A WINDOW TO CAPTURE"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.set_meta("ui_class", "title")
	UITheme.apply_class(_title_label, "title")
	vbox.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.text = "Chose what to capture :"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.set_meta("ui_class", "hint")
	UITheme.apply_class(_hint_label, "hint")
	vbox.add_child(_hint_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_options_container = VBoxContainer.new()
	_options_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_container.add_theme_constant_override("separation", 6)
	scroll.add_child(_options_container)

	var cancel_btn := _make_button("CANCEL (ESCAPE)")
	cancel_btn.pressed.connect(func(): selector_cancelled.emit())
	vbox.add_child(cancel_btn)

func _make_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size.y = 42
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

	btn.set_meta("ui_class", "action-button")
	UITheme.apply_class(btn, "action-button")
	return btn

func open_selector() -> void:
	_refresh_options()
	visible = true
	#Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_focus_first_deferred.call_deferred()

# Navigation manette : focus initial sur le premier choix (d-pad/stick +
# A naviguent via les actions ui_* par défaut de Godot).
func _focus_first_deferred() -> void:
	for c in _options_container.get_children():
		if c is BaseButton and not c.is_queued_for_deletion():
			c.grab_focus()
			return

func close_selector() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _refresh_options() -> void:
	for c in _options_container.get_children():
		c.queue_free()

	var screen_btn := _make_button("SCREEN")
	screen_btn.pressed.connect(func(): target_chosen.emit("screen"))
	_options_container.add_child(screen_btn)

	if not compositor:
		return

	var window_list: Array = compositor.get_window_list()
	if window_list.is_empty():
		var empty_label := Label.new()
		empty_label.text = "  (no window open)  "
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.set_meta("ui_class", "hint")
		UITheme.apply_class(empty_label, "hint")
		_options_container.add_child(empty_label)
		return

	for entry in window_list:
		var wid: int = entry["id"]
		var title: String = entry["title"]
		var app_id: String = entry["app_id"]
		var label := title if title != "" else app_id
		if label == "":
			label = "Window #" + str(wid)
		elif app_id != "" and title != "" and app_id != title:
			label = "%s   (%s)" % [title, app_id]
		var target := app_id if app_id != "" else title
		if target == "":
			target = "Window #" + str(wid)
		var btn := _make_button("  " + label)
		btn.pressed.connect(func(): target_chosen.emit(target))
		_options_container.add_child(btn)

func _input(event: InputEvent) -> void:
	super(event)  # GameMenu : consomme les JoypadMotion
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			selector_cancelled.emit()
			get_viewport().set_input_as_handled()
			return
	# Manette : Start ou B annulent (B = retour conventionnel console).
	if event is InputEventJoypadButton and event.pressed \
			and (event.button_index == JOY_BUTTON_START \
				or event.button_index == JOY_BUTTON_B):
		selector_cancelled.emit()
		get_viewport().set_input_as_handled()
