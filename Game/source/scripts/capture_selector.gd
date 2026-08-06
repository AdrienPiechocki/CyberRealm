extends PanelContainer
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

func setup(compositor_ref: WlrCompositor) -> void:
	compositor = compositor_ref

func _apply_styling() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.06, 0.08, 0.95)
	bg.border_color = Color(0.3, 0.4, 0.6, 0.8)
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.corner_radius_top_left = 10
	bg.corner_radius_top_right = 10
	bg.corner_radius_bottom_left = 10
	bg.corner_radius_bottom_right = 10
	add_theme_stylebox_override("panel", bg)

	custom_minimum_size = Vector2(560, 420)
	size = Vector2(560, 420)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -280
	offset_right = 280
	offset_top = -210
	offset_bottom = 210

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
	_title_label.text = "CHOISIR UNE CIBLE DE CAPTURE"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.text = "Une source « Screen Capture (PipeWire) » vient d'être ajoutée dans OBS. Choisissez ce qu'elle doit capturer :"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 13)
	_hint_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7, 0.9))
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

	var cancel_btn := _make_button("ANNULER (ECHAP)")
	cancel_btn.pressed.connect(func(): selector_cancelled.emit())
	vbox.add_child(cancel_btn)

func _make_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size.y = 42
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", 14)

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.14, 0.2, 0.9)
	normal.border_color = Color(0.3, 0.4, 0.6, 0.5)
	normal.border_width_top = 1
	normal.border_width_bottom = 1
	normal.border_width_left = 1
	normal.border_width_right = 1
	normal.corner_radius_top_left = 4
	normal.corner_radius_top_right = 4
	normal.corner_radius_bottom_left = 4
	normal.corner_radius_bottom_right = 4
	normal.content_margin_left = 12
	normal.content_margin_right = 12
	btn.add_theme_stylebox_override("normal", normal)

	var hover := normal.duplicate()
	hover.bg_color = Color(0.18, 0.22, 0.35, 0.95)
	hover.border_color = Color(0.4, 0.6, 1.0, 0.7)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.2, 0.3, 0.5, 0.95)
	btn.add_theme_stylebox_override("pressed", pressed)
	return btn

func open_selector() -> void:
	_refresh_options()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

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
		empty_label.text = "  (aucune fenêtre ouverte)  "
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.7))
		_options_container.add_child(empty_label)
		return

	for entry in window_list:
		var wid: int = entry["id"]
		var title: String = entry["title"]
		var app_id: String = entry["app_id"]
		var label := title if title != "" else app_id
		if label == "":
			label = "Fenêtre #" + str(wid)
		elif app_id != "" and title != "" and app_id != title:
			label = "%s   (%s)" % [title, app_id]
		var target := app_id if app_id != "" else title
		if target == "":
			target = "Fenêtre #" + str(wid)
		var btn := _make_button("  " + label)
		btn.pressed.connect(func(): target_chosen.emit(target))
		_options_container.add_child(btn)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			selector_cancelled.emit()
			get_viewport().set_input_as_handled()
