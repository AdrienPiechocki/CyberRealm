extends Node
## Page Multiplayer : hébergement, connexion, découverte LAN, PIN, liste des joueurs.
##
## Module de PauseMenu (nœud enfant « PageMultiplayer »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

# Page LAN
var _lan_status_label: Label = null
var _lan_players_label: Label = null
var _lan_results_box: VBoxContainer = null
var _lan_status_text := ""
var _lan_pin_label: Label = null
var _lan_pin_value := ""
var _lan_pin_visible := true
var _lan_pin_toggle_btn: Button = null
var _lan_ip_edit: LineEdit = null
var _lan_pin_edit: LineEdit = null
var _lan_encryption_btn: CheckButton = null
var _lan_disconnect_btn: Button = null

func _save_lan_name(edit: LineEdit) -> void:
	var nm := edit.text.strip_edges()
	if nm == "":
		nm = OS.get_environment("USER")
		edit.text = nm
	menu._settings["lan_player_name"] = nm
	menu._save_settings()
	menu.lan_name_changed.emit(nm)

func _show_lan() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "lan"

	menu.container.add_child(menu._make_title("MULTIPLAYER"))

	var hint := Label.new()
	if menu._lan_connected:
		hint.text = "Connected — changes are broadcast to other players automatically."
	else:
		hint.text = "Multiplayer on your local network (2-4 players).\nEach player keeps their own desktop; you see each other's avatar."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	menu.container.add_child(menu._make_section("Session"))
	var host_btn := menu._make_btn("Host Game")
	host_btn.pressed.connect(func():
		menu.lan_host_requested.emit()
	)
	menu.container.add_child(host_btn)

	# PIN label (visible when hosting — shows the generated PIN) + bouton 👁
	# pour le masquer à l'écran sans l'oublier (état persistant dans le membre).
	var pin_row := HBoxContainer.new()
	pin_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pin_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_lan_pin_label = Label.new()
	_lan_pin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_lan_pin_label.add_theme_font_size_override("font_size", 16)
	_lan_pin_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_lan_pin_label.visible = false
	pin_row.add_child(_lan_pin_label)
	_lan_pin_toggle_btn = Button.new()
	_lan_pin_toggle_btn.text = "👁"
	_lan_pin_toggle_btn.flat = true
	_lan_pin_toggle_btn.tooltip_text = "Mask / show the session PIN"
	_lan_pin_toggle_btn.visible = false
	_lan_pin_toggle_btn.pressed.connect(_toggle_lan_pin_visibility)
	pin_row.add_child(_lan_pin_toggle_btn)
	menu.container.add_child(pin_row)
	# Le PIN vit dans le lan_manager : on le restaure après un rebuild de l'UI
	# (BACK → retour dans le menu LAN) au lieu de le perdre.
	if menu._lan != null and bool(menu._lan.get("is_host")) and String(menu._lan.get_pin()) != "":
		set_lan_pin(String(menu._lan.get_pin()))

	var join_row := HBoxContainer.new()
	join_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_ip_edit = menu._make_line_edit()
	_lan_ip_edit.placeholder_text = "Host IP or name (ex: 192.168.1.5 / play.example.org)"
	join_row.add_child(_lan_ip_edit)
	_lan_pin_edit = menu._make_line_edit()
	_lan_pin_edit.placeholder_text = "PIN / password"
	_lan_pin_edit.custom_minimum_size = Vector2(150, 36)
	_lan_pin_edit.secret = true
	_lan_pin_edit.max_length = 64          # PIN (4 chiffres) en LAN, mot de passe long pour un serveur en ligne
	join_row.add_child(_lan_pin_edit)
	_lan_encryption_btn = CheckButton.new()
	_lan_encryption_btn.text = "TLS"
	_lan_encryption_btn.tooltip_text = "Encrypt the session (DTLS) with the embedded certificates"
	_lan_encryption_btn.button_pressed = true
	join_row.add_child(_lan_encryption_btn)
	var join_btn := menu._make_btn("Join")
	join_btn.custom_minimum_size = Vector2(100, 36)
	join_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	join_btn.pressed.connect(func():
		var ip := _lan_ip_edit.text.strip_edges()
		var pin := _lan_pin_edit.text.strip_edges()
		if ip != "":
			menu.lan_join_requested.emit(ip, pin, _lan_encryption_btn.button_pressed)
	)
	join_row.add_child(join_btn)
	menu.container.add_child(join_row)

	var find_btn := menu._make_btn("Find LAN games")
	find_btn.pressed.connect(func():
		menu.lan_discover_requested.emit()
	)
	menu.container.add_child(find_btn)

	_lan_results_box = VBoxContainer.new()
	_lan_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_results_box.add_theme_constant_override("separation", 4)
	menu.container.add_child(_lan_results_box)
	
	_lan_status_label = Label.new()
	_lan_status_label.text = _lan_status_text
	_lan_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_status_label.add_theme_font_size_override("font_size", 13)
	_lan_status_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(_lan_status_label)

	_lan_players_label = Label.new()
	_lan_players_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_players_label.add_theme_font_size_override("font_size", 13)
	_lan_players_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(_lan_players_label)
	_update_lan_players_label()
	
	menu.container.add_child(menu._make_section("Video share"))

	var codec_row := HBoxContainer.new()
	codec_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var codec_label := Label.new()
	codec_label.text = "Codec"
	codec_label.custom_minimum_size = Vector2(90, 36)
	codec_row.add_child(codec_label)
	var codec_opt := OptionButton.new()
	codec_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	codec_opt.add_item("Auto (h264, av1)")
	codec_opt.add_item("H.264")
	codec_opt.add_item("AV1")
	codec_opt.select(0)
	codec_opt.tooltip_text = "H.264 VAAPI is the most reliable; AV1 is hardware only (may be slow/unstable depending on the GPU)"
	codec_row.add_child(codec_opt)
	menu.container.add_child(codec_row)

	var bitrate_row := HBoxContainer.new()
	bitrate_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bitrate_label := Label.new()
	bitrate_label.text = "Bitrate (Mb/s)"
	bitrate_label.custom_minimum_size = Vector2(90, 36)
	bitrate_row.add_child(bitrate_label)
	var bitrate_spin := SpinBox.new()
	bitrate_spin.min_value = 1.0
	bitrate_spin.max_value = 20.0
	bitrate_spin.step = 1.0
	bitrate_spin.value = 6.0
	bitrate_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bitrate_spin.tooltip_text = "Target bitrate per shared window (bits/s ÷ 1e6). Raise it on fast wired LAN for less compression"
	bitrate_row.add_child(bitrate_spin)
	menu.container.add_child(bitrate_row)

	var fps_row := HBoxContainer.new()
	fps_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fps_label := Label.new()
	fps_label.text = "FPS"
	fps_label.custom_minimum_size = Vector2(90, 36)
	fps_row.add_child(fps_label)
	var fps_spin := SpinBox.new()
	fps_spin.min_value = 10.0
	fps_spin.max_value = 60.0
	fps_spin.step = 1.0
	fps_spin.value = 60.0
	fps_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_spin.tooltip_text = "Encoding framerate (10-60). 30 halves the CPU load"
	fps_row.add_child(fps_spin)
	menu.container.add_child(fps_row)

	var emit_video := func() -> void:
		var codec := "auto"
		if codec_opt.selected == 1:
			codec = "h264"
		elif codec_opt.selected == 2:
			codec = "av1"
		menu.lan_video_settings_changed.emit(int(bitrate_spin.value) * 1_000_000, codec, int(fps_spin.value))
	codec_opt.item_selected.connect(func(_i: int): emit_video.call())
	bitrate_spin.value_changed.connect(func(_v: float): emit_video.call())
	fps_spin.value_changed.connect(func(_v: float): emit_video.call())

	menu.container.add_child(menu._make_spacer())
	
	var disconnect_btn := menu._make_btn("Disconnect", "warning-button")
	disconnect_btn.pressed.connect(func():
		menu.lan_disconnect_requested.emit()
	)
	disconnect_btn.visible = menu._lan_connected
	menu.container.add_child(disconnect_btn)
	_lan_disconnect_btn = disconnect_btn

	menu.container.add_child(menu._make_back_btn())

func set_lan_status(text: String) -> void:
	_lan_status_text = text
	if _lan_status_label:
		_lan_status_label.text = text
	menu.shell._refresh_header()

func set_lan_players(roster: Array) -> void:
	menu._lan_roster = roster
	_update_lan_players_label()
	menu.shell._refresh_header()

func set_lan_connected(connected: bool) -> void:
	var changed := connected != menu._lan_connected
	menu._lan_connected = connected
	# Page World ouverte : (dé)verrouiller la liste dès que la session change.
	if changed and menu.visible and menu._current_view == "levels":
		menu.page_world._show_levels.call_deferred()
	if _lan_disconnect_btn != null and is_instance_valid(_lan_disconnect_btn):
		_lan_disconnect_btn.visible = connected
	menu.shell._refresh_header()

func set_lan_pin(pin: String) -> void:
	_lan_pin_value = pin
	if _lan_pin_label == null or _lan_pin_toggle_btn == null:
		return
	if pin != "":
		_lan_pin_label.visible = true
		_lan_pin_toggle_btn.visible = true
		_render_lan_pin()
	else:
		_lan_pin_label.visible = false
		_lan_pin_toggle_btn.visible = false

func _toggle_lan_pin_visibility() -> void:
	_lan_pin_visible = not _lan_pin_visible
	_render_lan_pin()

func _render_lan_pin() -> void:
	if _lan_pin_label == null:
		return
	if _lan_pin_visible:
		_lan_pin_label.text = "Session PIN: %s" % _lan_pin_value
	else:
		var masked := ""
		for i in _lan_pin_value.length():
			masked += "• "
		_lan_pin_label.text = "Session PIN: %s" % masked.strip_edges()

func _update_lan_players_label() -> void:
	if _lan_players_label == null:
		return
	if menu._lan_roster.is_empty():
		_lan_players_label.text = ""
		return
	var parts: PackedStringArray = []
	for p in menu._lan_roster:
		parts.append("• %s (%d)" % [String(p.get("name", "?")), int(p.get("id", 0))])
	_lan_players_label.text = "Players:\n" + "\n".join(parts)

func set_lan_discovery_results(results: Array) -> void:
	if menu._current_view != "lan" or _lan_results_box == null:
		return
	for c in _lan_results_box.get_children():
		c.queue_free()
	for r in results:
		var ips: Array = r.get("ips", [])
		var ip := ""
		if ips.size() > 0:
			ip = String(ips[0])
		else:
			ip = String(r.get("ip", ""))
		var btn := menu._make_btn("%s — %s" % [String(r.get("name", "?")), ip])
		btn.custom_minimum_size = Vector2(0, 34)
		btn.pressed.connect(_join_discovered.bind(ip))
		_lan_results_box.add_child(btn)

func _join_discovered(ip: String) -> void:
	if _lan_ip_edit == null:
		return
	_lan_ip_edit.text = ip
	_lan_pin_edit.text = ""
	_lan_pin_edit.grab_focus()
	set_lan_status("Game selected — enter the host's PIN (shown on the host), then press Join.")
