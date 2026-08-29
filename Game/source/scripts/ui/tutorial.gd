extends Control
class_name Tutorial
## Tutoriel de premier lancement (onboarding).
##
## Affiche des pages plein écran séquentielles expliquant au joueur les
## commandes et les menus du jeu. Au premier lancement, il capture les menus
## réels (pause, radial, fenêtres) à l'écran ; en cas d'échec, la page
## retombe sur une liste de texte + raccourcis. Se relance depuis le menu
## pause (Tutorial).

signal closed

const BODY := "body"
const TITLE := "title"
const KEYS := "keys"
const IMAGE := "image"
const IMAGE_NAME := "image_name"
const IMAGE_FIT := "image_fit"

const CONTROLS_IMG := "res://assets/controls.jpg"

# Références vers les menus du joueur, fournies par setup() (capture runtime).
var _pause_menu
var _radial_menu
var _window_menu

var _pages: Array = []
var _index := 0
var _root: Control = null
var _title_label: Label = null
var _body_label: RichTextLabel = null
var _keys_label: RichTextLabel = null
var _image_rect: TextureRect = null
var _prev_btn: Button = null
var _next_btn: Button = null
var _counter_label: Label = null
var _captured := false
var _nb_keys := 12

# Navigation manette (d-pad / stick gauche) avec cooldown, comme GameMenu.
const PAD_NAV_COOLDOWN := 0.12
var _pad_nav_cooldown := 0.0

func _ready() -> void:
	visible = false
	set_process_input(visible)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_pages()
	_build_ui()
	hide_tutorial()

# ── API publique ───────────────────────────────────────────────────────

func setup(pause_menu, radial_menu, window_menu) -> void:
	_pause_menu = pause_menu
	_radial_menu = radial_menu
	_window_menu = window_menu

func show_tutorial() -> void:
	if not _captured:
		await _capture_menus()
	_index = 0
	_render_page()
	visible = true
	set_process_input(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Aucun bouton focalisé : A navigue en pages (évite le double-déclenchement
	# avec _pad_menu_activate de player.gd).
	get_viewport().gui_release_focus()

func hide_tutorial() -> void:
	visible = false
	set_process_input(false)
	closed.emit()

func is_visible_open() -> bool:
	return visible

# ── Captures runtime des menus ─────────────────────────────────────────

func _capture_menus() -> void:
	_captured = true
	# Capture le menu pause.
	if _pause_menu != null:
		_pause_menu.show_menu()
		await _frames(6)
		var img := _shot()
		_pause_menu.hide_menu()
		if img != null:
			_attach_capture("pause", img)
	# Capture le menu fenêtres (ne montre rien si aucune fenêtre n'est ouverte,
	# mais on tente quand même au premier lancement quand des apps démarrent).
	if _window_menu != null:
		_window_menu.show_menu()
		await _frames(6)
		var img2 := _shot()
		_window_menu.hide_menu()
		if img2 != null:
			_attach_capture("window", img2)
	# Capture le menu radial (contexte "window").
	if _radial_menu != null:
		_radial_menu.show_menu("window")
		await _frames(6)
		var img3 := _shot()
		_radial_menu.hide_menu()
		if img3 != null:
			_attach_capture("radial", img3)
	await _frames(3)

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _shot() -> Image:
	var vp := get_viewport()
	if vp == null:
		return null
	var tex := vp.get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	return img

func _attach_capture(name: String, img: Image) -> void:
	if img == null or img.is_empty():
		return
	var tex := ImageTexture.create_from_image(img)
	if tex == null:
		return
	for page in _pages:
		if String(page.get(IMAGE_NAME, "")) == name:
			page[IMAGE] = tex
			page[IMAGE_FIT] = "cover"

# ── Construction des pages ─────────────────────────────────────────────

func _build_pages() -> void:
	_pages.clear()
	# Touches réelles (dynamiques) pour les raccourcis modifiables.
	_pages.append(_page(
		"Welcome to CyberRealm",
		"Your desktop lives inside a 3D world. Every window is a real Wayland \
surface floating in the room.\n\nThis short guide shows you the menus and \
the main commands. You can reopen it anytime from the Pause menu (Esc), \
button Tutorial.\n\nYou can also move the mouse to look around.",
		[]))
	_pages.append(_page(
		"Moving around",
		"You control a first-person camera inside the room.",
		[_key("forward"), _key("back"), _key("left"), _key("right"),
			"Jump: " + _key("jump")],
		12))
	_pages.append(_page(
		"Interacting with windows",
		"Point at a floating window and click to interact with it (click goes \
to the app, like a real desktop).",
		["Click (left mouse): interact / pick",
			"Middle mouse: toggle keyboard mode on a window"]))
	_pages.append(_page(
		"Window shortcuts",
		"Each window can be focused fullscreen, pinned as a picture-in-picture, \
shared with friends or closed.",
		[_keys("focus_window"), _keys("pin_window"), _keys("share_window"),
			_keys("kill_window"), _keys("hide_window"), _keys("grab")],
		13))
	_pages.append(_page(
		"Window menu",
		"Open the window menu to list, preview, focus, pin, share or close the \
open windows.\n\n(Image: the window menu, if it could be captured at startup.)",
		[_key("window_menu")],
		1, "window"))
	_pages.append(_page(
		"Radial menu (gamepad)",
		"On a gamepad, hold B to open the radial menu with quick actions.",
		["B (gamepad): open radial menu"],
		2, "radial"))
	_pages.append(_page(
		"Gamepad controls",
		"Here is the full gamepad map:",
		[], 3, "", CONTROLS_IMG))
	_pages.append(_page(
		"Pause menu",
		"Press Esc to open the Pause menu: remap keybinds, startup apps, custom \
binds, keyboard layout, polkit agent, pinned windows, LAN game and this \
tutorial.\n\n(Image: the pause menu, if it could be captured at startup.)",
		[_key("pause_menu")],
		1, "pause"))
	_pages.append(_page(
		"Layer surfaces & capture",
		"You can also toggle interaction with the layer surfaces (waybar, rofi) \
and capture the screen for OBS.",
		[_key("layer_interact"),
			"OBS: add a PipeWire source; a capture selector appears"]))
	_pages.append(_page(
		"Drag & drop files",
		"Drag files from any in-game application onto another player's avatar \
to send them over the LAN (rsync, no password transmitted).",
		[]))
	_pages.append(_page(
		"LAN multiplayer",
		"From the Pause menu > LAN Game: Host a room (a PIN is shown) or Join by \
IP with the PIN. Friends can share windows, audio and your level.",
		[_key("pause_menu") + " → LAN Game"]))
	_pages.append(_page(
		"Enjoy!",
		"You now know the essentials. Reopen this guide anytime from the Pause \
menu. Good game!",
		[]))

func _page(title: String, body: String, keys: Array, nb_keys := 0, image_name := "", image := "") -> Dictionary:
	return {
		TITLE: title, BODY: body, KEYS: keys,
		IMAGE_NAME: image_name, IMAGE: image, IMAGE_FIT: "none",
		"nb_keys": nb_keys if nb_keys > 0 else keys.size(),
	}

# ── Raccourcis dynamiques ──────────────────────────────────────────────

func _kb_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var kev := ev as InputEventKey
		var code := kev.physical_keycode
		if code == 0:
			code = kev.keycode
		if code == 0:
			return ""
		var t := OS.get_keycode_string(code)
		var m := ev as InputEventWithModifiers
		var mods := ""
		if m.meta_pressed:
			mods += "Super+"
		if m.shift_pressed:
			mods += "Shift+"
		if m.ctrl_pressed:
			mods += "Ctrl+"
		if m.alt_pressed:
			mods += "Alt+"
		return mods + t
	if ev is InputEventMouseButton:
		var mev := ev as InputEventMouseButton
		var names := {1: "Left", 2: "Right", 3: "Middle", 4: "Wheel Up", 5: "Wheel Down"}
		return String(names.get(mev.button_index, "Mouse"))
	return ""

func _key(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return action
	for ev in events:
		if ev is InputEventKey or ev is InputEventMouseButton:
			var t := _kb_text(ev)
			if t != "":
				return t
	return action

func _keys(action: String) -> String:
	return _key(action)

# ── Construction de l'UI ──────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := Color(0.02, 0.02, 0.03, 0.9)
	var dim_rect := ColorRect.new()
	dim_rect.color = dim
	dim_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim_rect)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	var vp_size := get_viewport_rect().size
	panel.custom_minimum_size = Vector2(vp_size.x * 0.86, vp_size.y * 0.82)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var pan_style := StyleBoxFlat.new()
	pan_style.bg_color = Color(0.07, 0.07, 0.09, 0.98)
	pan_style.border_color = Color(0.4, 0.5, 0.7, 0.9)
	pan_style.set_border_width_all(2)
	pan_style.set_corner_radius_all(14)
	panel.add_theme_stylebox_override("panel", pan_style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 30)
	vbox.add_child(_title_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var body_col := VBoxContainer.new()
	body_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_col.add_theme_constant_override("separation", 10)
	scroll.add_child(body_col)

	_image_rect = TextureRect.new()
	_image_rect.visible = false
	_image_rect.custom_minimum_size = Vector2(0, 0)
	_image_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image_rect.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	body_col.add_child(_image_rect)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.scroll_active = false
	body_col.add_child(_body_label)

	_keys_label = RichTextLabel.new()
	_keys_label.bbcode_enabled = true
	_keys_label.fit_content = true
	_keys_label.scroll_active = false
	body_col.add_child(_keys_label)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	_prev_btn = _make_btn("◀ Previous")
	_prev_btn.disabled = true
	_prev_btn.pressed.connect(_prev_page)
	btn_row.add_child(_prev_btn)

	_counter_label = Label.new()
	_counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(_counter_label)

	_next_btn = _make_btn("Next ▶")
	_next_btn.pressed.connect(_next_page)
	btn_row.add_child(_next_btn)

	var close_btn := _make_btn("Close")
	close_btn.pressed.connect(hide_tutorial)
	btn_row.add_child(close_btn)

func _make_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(130, 40)
	btn.add_theme_font_size_override("font_size", 15)
	return btn

func _render_page() -> void:
	if _pages.is_empty():
		return
	var p: Dictionary = _pages[_index]
	_title_label.text = String(p[TITLE])
	_body_label.text = "[color=#cdd6e6]" + String(p[BODY]) + "[/color]"
	var keys: Array = p[KEYS]
	if keys.is_empty():
		_keys_label.visible = false
	else:
		_keys_label.visible = true
		var txt := "[color=#f5c86b]Controls:[/color]\n"
		for k in keys:
			txt += "  •  [color=#a6c8ff]" + String(k) + "[/color]\n"
		_keys_label.text = txt

	# Image (capture runtime, controls.jpg, ou rien). Grande taille : elle
	# utilise la largeur du panneau ; le scroll gère le surplus vertical.
	var img = p.get(IMAGE)
	var has_img := false
	var vp_size := get_viewport_rect().size
	var img_size := Vector2(vp_size.x * 0.82, vp_size.y * 0.8)
	if img is Texture2D:
		_image_rect.texture = img
		has_img = true
		_image_rect.visible = true
		_image_rect.custom_minimum_size = img_size
	elif img is String and String(img) != "":
		var tex := load(String(img))
		if tex is Texture2D:
			_image_rect.texture = tex
			_image_rect.visible = true
			has_img = true
			_image_rect.custom_minimum_size = img_size
	if not has_img:
		_image_rect.visible = false
		_image_rect.custom_minimum_size = Vector2(0, 0)

	_counter_label.text = "%d / %d" % [_index + 1, _pages.size()]
	_prev_btn.disabled = _index == 0
	_next_btn.text = "Finish ▶" if _index >= _pages.size() - 1 else "Next ▶"

func _next_page() -> void:
	if _index >= _pages.size() - 1:
		hide_tutorial()
		return
	_index += 1
	_render_page()

func _prev_page() -> void:
	if _index <= 0:
		return
	_index -= 1
	_render_page()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Manette : consommer sticks + d-pad (la navigation se fait en _process,
	# comme GameMenu) pour que rien ne fuie vers le reste de la scène.
	if event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
		get_viewport().set_input_as_handled()
		return
	# B : page précédente ; ferme le tuto si déjà sur la première page.
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B:
		get_viewport().set_input_as_handled()
		if _index <= 0:
			hide_tutorial()
		else:
			_prev_page()
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		hide_tutorial()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if Input.is_key_pressed(KEY_SHIFT):
			_prev_page()
		else:
			_next_page()
	elif (event is InputEventKey and event.pressed):
		if event.keycode == KEY_LEFT or event.keycode == KEY_RIGHT:
			get_viewport().set_input_as_handled()
			if event.keycode == KEY_LEFT:
				_prev_page()
			else:
				_next_page()

func _process(delta: float) -> void:
	if not visible:
		return
	var dir := _poll_nav_dir()
	if dir == 0:
		_pad_nav_cooldown = 0.0
		return
	_pad_nav_cooldown -= delta
	if _pad_nav_cooldown > 0.0:
		return
	_pad_nav_cooldown = PAD_NAV_COOLDOWN
	if dir < 0:
		_prev_page()
	else:
		_next_page()

func _poll_nav_dir() -> int:
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT):
		return -1
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT):
		return 1
	var lx := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	if lx <= -0.5:
		return -1
	if lx >= 0.5:
		return 1
	return 0
