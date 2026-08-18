extends PanelContainer
## Menu de navigation entre fenêtres ouvertes.
## S'ouvre/ferme avec B. Affiche une preview de la fenêtre sélectionnée,
## des onglets en haut, et des actions à gauche.

signal action_grab(window_id: int)
signal action_focus(window_id: int)
signal action_toggle_hide(window_id: int)
signal action_find(window_id: int)
signal action_pin(window_id: int)
signal action_share(window_id: int)
signal action_quit(window_id: int)
signal menu_closed()

@onready var tabs_container: HBoxContainer = $VBox/TopBar/Tabs
@onready var preview_rect: TextureRect = $VBox/Content/Preview
@onready var actions_container: VBoxContainer = $VBox/Content/Actions

var compositor: WlrCompositor
var selected_window_id := -1

var tab_buttons: Dictionary = {} # window_id -> Button
var action_buttons: Array[Button] = []
var _share_button: Button
var _grab_button: Button

var _get_texture_func: Callable # Callable(window_id) -> Texture2D
var _get_shared_func: Callable # Callable(window_id) -> bool
var _get_grabbed_id_func: Callable # Callable() -> int (wid du grab en cours, -1 sinon)

func _ready() -> void:
	visible = false
	_build_action_buttons()
	_apply_styling()

func setup(compositor_ref: WlrCompositor, get_texture: Callable, get_shared: Callable, get_grabbed_id: Callable) -> void:
	compositor = compositor_ref
	_get_texture_func = get_texture
	_get_shared_func = get_shared
	_get_grabbed_id_func = get_grabbed_id

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
	bg.content_margin_left = 0
	bg.content_margin_right = 0
	bg.content_margin_top = 0
	bg.content_margin_bottom = 0
	add_theme_stylebox_override("panel", bg)

	custom_minimum_size = Vector2(900, 600)
	size = Vector2(900, 600)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -450
	offset_right = 450
	offset_top = -300
	offset_bottom = 300

func _build_action_buttons() -> void:
	var action_defs := [
		{"label": "GRAB", "signal": "action_grab"},
		{"label": "FOCUS", "signal": "action_focus"},
		{"label": "HIDE/SHOW", "signal": "action_toggle_hide"},
		{"label": "PIN", "signal": "action_pin"},
		{"label": "SHARE", "signal": "action_share"},
		{"label": "FIND", "signal": "action_find"},
		{"label": "QUIT", "signal": "action_quit"},
	]
	for def in action_defs:
		var btn := Button.new()
		btn.text = def["label"]
		btn.custom_minimum_size = Vector2(140, 40)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER

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
		normal.content_margin_left = 10
		normal.content_margin_right = 10
		normal.content_margin_top = 6
		normal.content_margin_bottom = 6
		btn.add_theme_stylebox_override("normal", normal)

		var hover := normal.duplicate()
		hover.bg_color = Color(0.18, 0.22, 0.35, 0.95)
		hover.border_color = Color(0.4, 0.6, 1.0, 0.7)
		btn.add_theme_stylebox_override("hover", hover)

		var pressed := normal.duplicate()
		pressed.bg_color = Color(0.2, 0.3, 0.5, 0.95)
		btn.add_theme_stylebox_override("pressed", pressed)

		btn.add_theme_font_size_override("font_size", 14)

		var sig_name: String = def["signal"]
		btn.pressed.connect(func(): _on_action(sig_name))
		if sig_name == "action_share":
			_share_button = btn
		elif sig_name == "action_grab":
			_grab_button = btn
		actions_container.add_child(btn)
		action_buttons.append(btn)

func _on_action(sig_name: String) -> void:
	if selected_window_id == -1:
		return
	match sig_name:
		"action_grab":
			action_grab.emit(selected_window_id)
			_update_grab_label()
		"action_focus":
			action_focus.emit(selected_window_id)
		"action_toggle_hide":
			action_toggle_hide.emit(selected_window_id)
		"action_find":
			action_find.emit(selected_window_id)
		"action_pin":
			action_pin.emit(selected_window_id)
		"action_share":
			action_share.emit(selected_window_id)
			_update_share_label()
		"action_quit":
			action_quit.emit(selected_window_id)
			# Rafraîchir après un court délai pour laisser le temps au client de fermer
			await get_tree().create_timer(0.15).timeout
			_refresh_tabs()

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	visible = true
	# Si une fenêtre est en cours de déplacement (grab), la resélectionner
	# d'office pour que le toggle GRAB la vise directement à la réouverture.
	if _get_grabbed_id_func.is_valid():
		var grabbed_id := int(_get_grabbed_id_func.call())
		if grabbed_id != -1:
			selected_window_id = grabbed_id
	_refresh_tabs()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	visible = false
	selected_window_id = -1
	menu_closed.emit()

func _refresh_tabs() -> void:
	for child in tabs_container.get_children():
		child.queue_free()
	tab_buttons.clear()

	if not compositor:
		return

	var window_list: Array = compositor.get_window_list()
	if window_list.is_empty():
		var empty_label := Label.new()
		empty_label.text = "  (no window open)  "
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.7))
		tabs_container.add_child(empty_label)
		selected_window_id = -1
		preview_rect.texture = null
		return

	# Par défaut, sélectionner la dernière fenêtre ouverte (id le plus haut :
	# next_window_id est incrémenté à chaque création côté compositeur).
	# On vérifie aussi que l'id encore en mémoire existe toujours (une fenêtre
	# a pu être fermée) avant de la garder.
	var wid_in_list := false
	for entry in window_list:
		if int(entry["id"]) == selected_window_id:
			wid_in_list = true
			break
	if selected_window_id == -1 or not wid_in_list:
		selected_window_id = _last_opened_window_id(window_list)

	for entry in window_list:
		var wid: int = entry["id"]
		var title: String = entry["title"]
		var app_id: String = entry["app_id"]
		var display_name := title if title != "" else app_id
		if display_name == "":
			display_name = "Fenêtre #" + str(wid)

		var btn := Button.new()
		btn.text = "  " + display_name + "  "
		btn.custom_minimum_size.y = 32
		btn.add_theme_font_size_override("font_size", 13)

		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.1, 0.1, 0.15, 0.8)
		normal.corner_radius_top_left = 4
		normal.corner_radius_top_right = 4
		normal.corner_radius_bottom_left = 0
		normal.corner_radius_bottom_right = 0
		normal.content_margin_left = 10
		normal.content_margin_right = 10
		normal.content_margin_top = 4
		normal.content_margin_bottom = 4
		btn.add_theme_stylebox_override("normal", normal)

		var selected := normal.duplicate()
		selected.bg_color = Color(0.15, 0.2, 0.35, 0.95)
		selected.border_color = Color(0.4, 0.6, 1.0, 0.6)
		selected.border_width_bottom = 2
		btn.add_theme_stylebox_override("hover", selected)

		var selected_style := normal.duplicate()
		selected_style.bg_color = Color(0.15, 0.22, 0.4, 0.95)
		selected_style.border_color = Color(0.4, 0.6, 1.0, 0.8)
		selected_style.border_width_bottom = 2
		btn.add_theme_stylebox_override("pressed", selected_style)

		if wid == selected_window_id:
			btn.add_theme_stylebox_override("normal", selected_style)

		btn.set_meta("window_id", wid)
		btn.pressed.connect(func(): _on_tab_pressed(wid))
		tabs_container.add_child(btn)
		tab_buttons[wid] = btn

	_update_preview()

# Renvoie l'id de la fenêtre la plus récemment ouverte dans la liste.
func _last_opened_window_id(window_list: Array) -> int:
	var best_id := -1
	for entry in window_list:
		var wid: int = int(entry["id"])
		if wid > best_id:
			best_id = wid
	return best_id

func _on_tab_pressed(wid: int) -> void:
	selected_window_id = wid
	# Mettre à jour le style des onglets
	for child in tabs_container.get_children():
		if child.has_meta("window_id"):
			var child_wid: int = child.get_meta("window_id")
			# On ne peut pas récupérer le style original facilement, on reconstruit
			var normal := StyleBoxFlat.new()
			normal.bg_color = Color(0.1, 0.1, 0.15, 0.8)
			normal.corner_radius_top_left = 4
			normal.corner_radius_top_right = 4
			normal.corner_radius_bottom_left = 0
			normal.corner_radius_bottom_right = 0
			normal.content_margin_left = 10
			normal.content_margin_right = 10
			normal.content_margin_top = 4
			normal.content_margin_bottom = 4
			if child_wid == wid:
				normal.bg_color = Color(0.15, 0.22, 0.4, 0.95)
				normal.border_color = Color(0.4, 0.6, 1.0, 0.8)
				normal.border_width_bottom = 2
			child.add_theme_stylebox_override("normal", normal)
	_update_preview()

func _update_preview() -> void:
	if selected_window_id == -1 or not _get_texture_func:
		preview_rect.texture = null
		_update_share_label()
		_update_grab_label()
		return
	var tex: Texture2D = _get_texture_func.call(selected_window_id)
	preview_rect.texture = tex
	_update_share_label()
	_update_grab_label()

func refresh_preview() -> void:
	if visible:
		_update_preview()

# Affiche l'état de grab de la fenêtre sélectionnée (toggle ON/OFF).
func _update_grab_label() -> void:
	if _grab_button == null or not _get_grabbed_id_func.is_valid() or selected_window_id == -1:
		return
	var grabbed: bool = int(_get_grabbed_id_func.call()) == selected_window_id
	_grab_button.text = "GRAB: ON" if grabbed else "GRAB: OFF"

# Affiche l'état de partage (« screenshare ») de la fenêtre sélectionnée.
func _update_share_label() -> void:
	if _share_button == null or not _get_shared_func.is_valid() or selected_window_id == -1:
		return
	var shared: bool = bool(_get_shared_func.call(selected_window_id))
	_share_button.text = "SHARE: ON" if shared else "SHARE: OFF"

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
