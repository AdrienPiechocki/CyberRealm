extends GameMenu
## Menu de navigation entre fenêtres ouvertes.
## S'ouvre/ferme avec B. Affiche une preview de la fenêtre sélectionnée,
## des onglets en haut, et des actions à gauche.

signal action_grab(window_id: int)
signal action_focus(window_id: int)
signal action_toggle_hide(window_id: int)
signal action_find(window_id: int)
signal action_pin(window_id: int)
signal action_share(window_id: int)
signal action_screenshot(window_id: int)
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

var _preview_box: Control = null

func _ready() -> void:
	visible = false
	_build_action_buttons()
	_apply_styling()
	_build_preview_box()
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)

# Construit (en code, sans toucher à la scène) un conteneur borné autour de
# la preview : le TextureRect est reparenté dedans et ne pilote plus la taille
# du menu (une très grande fenêtre ne rescale plus tout le menu).
func _build_preview_box() -> void:
	var content: HBoxContainer = $VBox/Content
	_preview_box = Control.new()
	_preview_box.name = "PreviewBox"
	_preview_box.clip_contents = true
	_preview_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.remove_child(preview_rect)
	_preview_box.add_child(preview_rect)
	# _preview_box est un Control simple (pas un Container) : il ne trie pas
	# ses enfants. Sans ancrage plein-rect, le TextureRect garde une taille
	# (0,0) et la preview n'affiche rien.
	preview_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_preview_box)
	content.move_child(_preview_box, 0)
	preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_resize_preview_box()

## Le conteneur preview est borné (fraction de la vue) : la preview letterboxe
## dedans mais ne change jamais la taille du menu quand on change de fenêtre.
func _resize_preview_box() -> void:
	if _preview_box == null:
		return
	var vp := get_viewport_rect().size
	_preview_box.custom_maximum_size = Vector2(vp.x * 0.50, vp.y * 0.75)

func _on_menu_resized() -> void:
	_resize_preview_box()

func setup(compositor_ref: WlrCompositor, get_texture: Callable, get_shared: Callable, get_grabbed_id: Callable) -> void:
	compositor = compositor_ref
	_get_texture_func = get_texture
	_get_shared_func = get_shared
	_get_grabbed_id_func = get_grabbed_id

func _apply_styling() -> void:
	theme = UITheme.theme
	set_meta("ui_class", "menu-panel window-menu")
	UITheme.apply_class(self, "menu-panel window-menu")

func _on_stylesheet_reloaded() -> void:
	theme = UITheme.theme
	UITheme.apply_css(self)
	_resize_preview_box()

func _build_action_buttons() -> void:
	var action_defs := [
		{"label": "GRAB", "signal": "action_grab"},
		{"label": "FOCUS", "signal": "action_focus"},
		{"label": "HIDE/SHOW", "signal": "action_toggle_hide"},
		{"label": "PIN", "signal": "action_pin"},
		{"label": "SHARE", "signal": "action_share"},
		{"label": "SCREENSHOT", "signal": "action_screenshot"},
		{"label": "FIND", "signal": "action_find"},
		{"label": "QUIT", "signal": "action_quit"},
	]
	for def in action_defs:
		var btn := Button.new()
		btn.text = def["label"]
		btn.custom_minimum_size = Vector2(140, 40)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER

		btn.set_meta("ui_class", "action-button")
		UITheme.apply_class(btn, "action-button")

		var sig_name: String = def["signal"]
		btn.pressed.connect(func(): _on_action(sig_name))
		if sig_name == "action_share":
			_share_button = btn
		elif sig_name == "action_grab":
			_grab_button = btn
		actions_container.add_child(btn)
		action_buttons.append(btn)

func _on_action(sig_name: String) -> void:
	# La capture ne dépend d'aucune fenêtre : fonctionne même sans sélection.
	if sig_name == "action_screenshot":
		action_screenshot.emit(selected_window_id)
		return
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
	#Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	visible = false
	menu_closed.emit()

# Une nouvelle fenêtre vient d'être ouverte : elle devient l'onglet
# sélectionné à la prochaine ouverture du menu (ou immédiatement, avec
# rafraîchissement des onglets, si le menu est déjà ouvert).
func on_window_opened(id: int) -> void:
	selected_window_id = id
	if visible:
		_refresh_tabs()

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
		empty_label.set_meta("ui_class", "hint")
		UITheme.apply_class(empty_label, "hint")
		tabs_container.add_child(empty_label)
		selected_window_id = -1
		preview_rect.texture = null
		return

	# L'ordre renvoyé par le compositeur (std::unordered_map) n'est pas garanti :
	# on trie explicitement par id décroissant pour que la fenêtre la plus
	# récemment ouverte soit toujours le premier onglet.
	window_list.sort_custom(func(a, b): return int(a["id"]) > int(b["id"]))

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
			display_name = "Window #" + str(wid)

		var btn := Button.new()
		btn.text = "  " + display_name + "  "
		btn.custom_minimum_size.y = 32

		var kclass := "tab-button-selected" if wid == selected_window_id else "tab-button"
		btn.set_meta("ui_class", kclass)
		UITheme.apply_class(btn, kclass)

		btn.set_meta("window_id", wid)
		btn.pressed.connect(func(): _on_tab_pressed(wid))
		tabs_container.add_child(btn)
		tab_buttons[wid] = btn

	_update_preview()

	# Donner le focus clavier à l'onglet sélectionné pour pouvoir naviguer
	# immédiatement entre les fenêtres avec les flèches.
	if tab_buttons.has(selected_window_id):
		tab_buttons[selected_window_id].grab_focus()

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
	# Mettre à jour la classe des onglets
	for child in tabs_container.get_children():
		if child.has_meta("window_id"):
			var cwid: int = child.get_meta("window_id")
			var kclass := "tab-button-selected" if cwid == wid else "tab-button"
			child.set_meta("ui_class", kclass)
			UITheme.apply_class(child, kclass)
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
	super(event)  # GameMenu : consomme les JoypadMotion
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
	# Manette : Start/B ferme le menu fenêtre.
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_START, JOY_BUTTON_B]:
		hide_menu()
		get_viewport().set_input_as_handled()
