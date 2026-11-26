extends Node
## Page Multiplayer : hébergement, connexion, découverte LAN, PIN, liste des joueurs.
##
## Module de PauseMenu (nœud enfant « PageMultiplayer »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
const MicSources := preload("res://scripts/main/mic_sources.gd")
var menu: PauseMenu = null

# Page LAN
var _lan_status_label: Label = null
var _lan_players_label: Label = null
var _lan_mute_box: VBoxContainer = null   # une case « Mute » par autre joueur (chat, emotes)
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
	_add_invite_host()

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
	_lan_ip_edit.placeholder_text = "Host IP, name or invitation code (192.168.1.5 / play.example.org / CR1-…)"
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
		if ip.begins_with("CR1-"):
			menu.lan_join_invite_requested.emit(ip)          # code d'invitation : adresse, mot de passe, certificat
		elif ip != "":
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
	_lan_mute_box = VBoxContainer.new()
	menu.container.add_child(_lan_mute_box)
	_update_lan_players_label()

	# Bulles de chat au-dessus des avatars (lu par chat_box.gd à chaque message).
	var bubbles_check := CheckButton.new()
	bubbles_check.text = "Chat bubbles above players"
	bubbles_check.button_pressed = menu.is_chat_bubbles_enabled()
	bubbles_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(bubbles_check)
	bubbles_check.toggled.connect(func(on: bool):
		menu._settings["chat_bubbles"] = on
		menu._save_settings()
	)

	# Annotations sur les fenêtres partagées (lu par annotations_view.gd).
	var eph_check := CheckButton.new()
	eph_check.text = "Ephemeral annotations (strokes vanish after 4 s, like a laser pointer)"
	eph_check.button_pressed = menu.is_annotation_ephemeral()
	eph_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(eph_check)
	eph_check.toggled.connect(func(on: bool):
		menu._settings["annotation_ephemeral"] = on
		menu._save_settings()
	)

	_add_voice_settings()
	_add_server_admin()
	
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
	_rebuild_mute_box()
	if menu._lan_roster.is_empty():
		_lan_players_label.text = ""
		return
	var parts: PackedStringArray = []
	for p in menu._lan_roster:
		parts.append("• %s (%d)" % [String(p.get("name", "?")), int(p.get("id", 0))])
	_lan_players_label.text = "Players:\n" + "\n".join(parts)

## Une ligne par autre joueur : sourdine du chat, sourdine et volume de sa voix (local, rien n'est transmis).
func _rebuild_mute_box() -> void:
	if _lan_mute_box == null or not is_instance_valid(_lan_mute_box):
		return
	for c in _lan_mute_box.get_children():
		c.queue_free()
	var lan: Node = menu._lan
	if lan == null or not ("chat" in lan) or lan.chat == null or not lan.multiplayer.has_multiplayer_peer():
		return
	var vm: Node = menu.voice_manager
	var me: int = lan.multiplayer.get_unique_id()
	for p in menu._lan_roster:
		var id := int(p.get("id", 0))
		if id == me or id == 0:
			continue
		var row := HBoxContainer.new()
		var name_lbl := Label.new()
		name_lbl.text = String(p.get("name", "?"))
		name_lbl.custom_minimum_size = Vector2(140, 0)
		row.add_child(name_lbl)
		var chat_cb := CheckButton.new()
		chat_cb.text = "Mute chat"
		chat_cb.button_pressed = lan.chat.is_muted(id)
		chat_cb.add_theme_font_size_override("font_size", 13)
		chat_cb.toggled.connect(func(on: bool): lan.chat.set_muted(id, on))
		row.add_child(chat_cb)
		if vm != null:
			var voice_cb := CheckButton.new()
			voice_cb.text = "Mute voice"
			voice_cb.button_pressed = vm.muted.has(id)
			voice_cb.add_theme_font_size_override("font_size", 13)
			voice_cb.toggled.connect(func(on: bool): vm.set_muted(id, on))
			row.add_child(voice_cb)
			var vol := HSlider.new()
			vol.min_value = 0.0
			vol.max_value = 2.0
			vol.step = 0.05
			vol.value = float(vm.volumes.get(id, 1.0))
			vol.custom_minimum_size = Vector2(120, 0)
			vol.tooltip_text = "Voice volume"
			vol.value_changed.connect(func(v: float): vm.set_volume(id, v))
			row.add_child(vol)
		_lan_mute_box.add_child(row)

## Héberger par Internet : bouton, puis code d'invitation à copier (cf. scripts/network/lan/invite.gd).
func _add_invite_host() -> void:
	var lan: Node = menu._lan
	if lan == null or lan.get("invite") == null:
		return
	var btn: Button = menu._make_btn("Host over the Internet (invitation code)")
	btn.tooltip_text = "Opens the ports on your router (UPnP) and gives a code to send to your friends.\nThe code contains your address, a long random password and this machine's certificate."
	btn.pressed.connect(func(): menu.lan_host_invite_requested.emit())
	btn.visible = not menu._lan_connected
	menu.container.add_child(btn)
	var trust := CheckButton.new()
	trust.text = "Trust invited players like on a LAN (window & file sharing, avatar scripts)"
	trust.tooltip_text = "Off: sessions by invitation code (hosted or joined) get the online restrictions."
	trust.button_pressed = bool(lan.get("invite_trusted"))
	trust.toggled.connect(func(on: bool): lan.invite_trusted = on)
	menu.container.add_child(trust)
	var box := VBoxContainer.new()
	menu.container.add_child(box)
	var show_code := func(code: String, status: String) -> void:
		if not is_instance_valid(box):
			return
		for c in box.get_children():
			c.queue_free()
		if code == "":
			return
		var info := Label.new()
		info.text = status
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_theme_font_size_override("font_size", 12)
		box.add_child(info)
		var row := HBoxContainer.new()
		var field := LineEdit.new()
		field.text = code
		field.editable = false
		field.secret = true                  # le code contient le mot de passe : masqué à l'écran (stream…)
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(field)
		var copy: Button = menu._make_btn("Copy code")
		copy.pressed.connect(func():
			DisplayServer.clipboard_set(code)
			copy.text = "Copied")
		row.add_child(copy)
		box.add_child(row)
	if bool(lan.get("is_host")) and String(lan.invite.invite_code) != "":
		show_code.call(lan.invite.invite_code, "Invitation code (send it privately: it contains the password)")
	set_meta("invite_show", show_code)
	if not lan.invite.invite_ready.is_connected(_on_invite_ready):
		lan.invite.invite_ready.connect(_on_invite_ready)

func _on_invite_ready(code: String, status: String) -> void:
	if has_meta("invite_show"):
		var f: Callable = get_meta("invite_show")
		if f.is_valid():
			f.call(code, status + "\nInvitation code (send it privately: it contains the password):")

## Serveur dédié : connexion admin et remise à zéro du monde (le serveur efface l'état enregistré et redémarre).
## Visible seulement dans une session sur serveur dédié.
func _add_server_admin() -> void:
	var lan: Node = menu._lan
	if lan == null or not bool(lan.get("session_dedicated")):
		return
	menu.container.add_child(menu._make_section("Server"))
	var status := Label.new()
	menu.container.add_child(status)
	var row := HBoxContainer.new()
	var pw := LineEdit.new()
	pw.secret = true
	pw.placeholder_text = "Admin password"
	pw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(pw)
	var unlock: Button = menu._make_btn("Unlock as admin")
	row.add_child(unlock)
	menu.container.add_child(row)
	var reset: Button = menu._make_btn("Reset world (moved / broken objects)", "warning-button")
	menu.container.add_child(reset)
	var refresh := func() -> void:
		if not is_instance_valid(status):
			return
		var is_admin: bool = lan.is_admin()
		status.text = "You are the server admin" if is_admin else "Admin: locked"
		row.visible = not is_admin
		reset.disabled = not is_admin
	refresh.call()
	unlock.pressed.connect(func(): lan.request_admin(pw.text); pw.text = "")
	if not lan.admin_changed.is_connected(_on_admin_changed):
		lan.admin_changed.connect(_on_admin_changed)
	set_meta("admin_refresh", refresh)
	var armed := [false]
	reset.pressed.connect(func():
		if not armed[0]:
			armed[0] = true
			reset.text = "Click again to reset the world for everyone"
			return
		lan.send_level_message("admin_reset_world")
		reset.text = "Reset world (moved / broken objects)"
		armed[0] = false
	)

func _on_admin_changed(_is_admin: bool) -> void:
	if has_meta("admin_refresh"):
		var f: Callable = get_meta("admin_refresh")
		if f.is_valid():
			f.call()

## Chat vocal : mode du micro (désactivé par défaut), seuil de l'activation vocale, voix spatialisée,
## annulation d'écho de PipeWire, volume général. Lus à chaque frame par voice_manager.gd.
func _add_voice_settings() -> void:
	menu.container.add_child(menu._make_section("Voice chat"))
	var mode_row := HBoxContainer.new()
	mode_row.add_child(menu._make_row_label("Microphone"))
	var mode := OptionButton.new()
	var modes := ["off", "ptt", "vad"]
	mode.add_item("Off")
	mode.add_item("Push to talk (%s)" % _action_key_text("push_to_talk"))
	mode.add_item("Voice activation")
	mode.selected = modes.find(menu.get_voice_mode())
	mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(mode)
	menu.container.add_child(mode_row)

	# Micro, gain, niveau en direct (avec le trait du seuil), puis le seuil d'activation EN dB, sur la même échelle.
	var bar: ProgressBar = _add_mic_device_row()
	var vad_row := HBoxContainer.new()
	vad_row.add_child(menu._make_row_label("Activation threshold"))
	var vad := HSlider.new()
	vad.min_value = VAD_MIN_DB
	vad.max_value = VAD_MAX_DB
	vad.step = 1.0
	vad.value = clampf(linear_to_db(menu.get_voice_vad_threshold()), VAD_MIN_DB, VAD_MAX_DB)
	vad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vad_row.add_child(vad)
	var vad_label := Label.new()
	vad_label.custom_minimum_size = Vector2(64, 0)
	vad_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vad_label.add_theme_font_size_override("font_size", 12)
	vad_label.text = "%d dB" % roundi(vad.value)
	vad_row.add_child(vad_label)
	vad_row.visible = menu.get_voice_mode() == "vad"
	menu.container.add_child(vad_row)
	var marker := bar.get_node_or_null("Threshold") as Control if bar != null else null
	if marker != null:
		marker.visible = vad_row.visible
	mode.item_selected.connect(func(i: int):
		menu._settings["voice_mode"] = modes[i]
		menu._save_settings()
		vad_row.visible = modes[i] == "vad"
		if marker != null:
			marker.visible = vad_row.visible
	)
	vad.value_changed.connect(func(v: float):
		menu._settings["voice_vad_threshold"] = db_to_linear(v)
		menu._save_settings()
		vad_label.text = "%d dB" % roundi(v)
	)

	var vol_row := HBoxContainer.new()
	vol_row.add_child(menu._make_row_label("Voice volume"))
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 2.0
	vol.step = 0.05
	vol.value = menu.get_voice_volume()
	vol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_row.add_child(vol)
	menu.container.add_child(vol_row)
	vol.value_changed.connect(func(v: float):
		menu._settings["voice_volume"] = v
		menu._save_settings()
	)

	# Annulation d'écho demandée sans le module echo-cancel : prévenir (le micro choisi est utilisé à la place).
	var echo_warn := Label.new()
	echo_warn.text = "PipeWire's echo-cancel module isn't running: the microphone above is used without echo cancellation."
	echo_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	echo_warn.add_theme_font_size_override("font_size", 12)
	echo_warn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	var refresh_echo_warn := func():
		echo_warn.visible = menu.is_voice_echo_cancel() \
				and not MicSources.echo_cancel_available(MicSources.list_sources())
	for spec in [["voice_spatial", "Spatial voice (comes from the player's avatar)", menu.is_voice_spatial()],
			["voice_echo_cancel", "Use PipeWire echo cancellation (needs the echo-cancel module)", menu.is_voice_echo_cancel()]]:
		var cb := CheckButton.new()
		cb.text = String(spec[1])
		cb.button_pressed = bool(spec[2])
		cb.add_theme_font_size_override("font_size", 14)
		var key := String(spec[0])
		cb.toggled.connect(func(on: bool):
			menu._settings[key] = on
			menu._save_settings()
			refresh_echo_warn.call()
		)
		menu.container.add_child(cb)
	menu.container.add_child(echo_warn)
	refresh_echo_warn.call()

const VAD_MIN_DB := -60.0      # seuil d'activation vocale, même échelle que la barre de niveau
const VAD_MAX_DB := -10.0

## Choix du micro (sources PipeWire, défaut en tête), gain et niveau en direct : tant que cette page est affichée, le
## micro est ouvert en test (rien n'est envoyé hors session, voice_manager.mic_test). Renvoie la barre de niveau (son
## enfant « Threshold » marque le seuil d'activation), null sans gestionnaire de voix.
func _add_mic_device_row() -> ProgressBar:
	var row := HBoxContainer.new()
	row.add_child(menu._make_row_label("Input device"))
	var dev := OptionButton.new()
	dev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Noms de périphériques parfois très longs : sans ceci, le bouton prend la largeur du plus long et élargit tout
	# le menu. Le nom complet reste lisible dans la liste déroulante et en infobulle.
	dev.fit_to_longest_item = false
	dev.clip_text = true
	dev.custom_minimum_size = Vector2(120, 0)
	dev.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var names: Array = [""]
	var sources := MicSources.list_sources(true)
	var default_desc := ""
	for src in sources:
		if bool(src["default"]):
			default_desc = String(src["description"])
	dev.add_item("System default" + (" (%s)" % default_desc if default_desc != "" else ""))
	var chosen := menu.get_voice_mic()
	var selected := 0
	for src in sources:
		names.append(String(src["name"]))
		dev.add_item(String(src["description"]))
		if String(src["name"]) == chosen:
			selected = names.size() - 1
	if chosen != "" and selected == 0:
		names.append(chosen)                     # micro choisi débranché : gardé, signalé
		dev.add_item("%s (unavailable)" % chosen)
		selected = names.size() - 1
	dev.selected = selected
	dev.tooltip_text = dev.get_item_text(selected)
	dev.item_selected.connect(func(i: int):
		menu._settings["voice_mic"] = String(names[i])
		menu._save_settings()
		dev.tooltip_text = dev.get_item_text(i)
	)
	row.add_child(dev)
	menu.container.add_child(row)

	var gain_row := HBoxContainer.new()
	gain_row.add_child(menu._make_row_label("Microphone gain"))
	var gain := HSlider.new()
	gain.min_value = 0.0
	gain.max_value = 24.0
	gain.step = 1.0
	gain.value = menu.get_voice_mic_gain_db()
	gain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gain_row.add_child(gain)
	var gain_label := Label.new()
	gain_label.custom_minimum_size = Vector2(64, 0)
	gain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gain_label.add_theme_font_size_override("font_size", 12)
	gain_label.text = "+%d dB" % roundi(gain.value)
	gain_row.add_child(gain_label)
	gain.value_changed.connect(func(v: float):
		menu._settings["voice_mic_gain_db"] = v
		menu._save_settings()
		gain_label.text = "+%d dB" % roundi(v)
	)
	menu.container.add_child(gain_row)

	var level_row := HBoxContainer.new()
	level_row.add_child(menu._make_row_label("Input level"))
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	level_row.add_child(bar)
	var db_label := Label.new()
	db_label.custom_minimum_size = Vector2(64, 0)
	db_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	db_label.add_theme_font_size_override("font_size", 12)
	level_row.add_child(db_label)
	menu.container.add_child(level_row)
	# Trait du seuil d'activation vocale sur la barre : la voix doit le dépasser pour être envoyée.
	var marker := ColorRect.new()
	marker.name = "Threshold"
	marker.color = Color(1.0, 0.75, 0.3)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.size = Vector2(2, 14)
	bar.add_child(marker)
	var vm: Node = menu.voice_manager
	if vm == null:
		bar.visible = false
		db_label.text = "—"
		return null
	vm.set("mic_test", true)
	var timer := Timer.new()
	timer.wait_time = 0.05
	timer.autostart = true
	timer.timeout.connect(func():
		var lvl := float(vm.get("mic_level"))
		var db := linear_to_db(maxf(lvl, 0.00001))
		bar.value = level_bar_value(lvl)
		db_label.text = "%d dB" % roundi(db) if lvl > 0.00001 else "silent"
		marker.size = Vector2(2, bar.size.y)
		marker.position = Vector2(level_bar_value(menu.get_voice_vad_threshold()) * bar.size.x - 1.0, 0)
	)
	level_row.add_child(timer)
	level_row.tree_exiting.connect(func(): vm.set("mic_test", false))
	return bar

## Niveau linéaire (rms) -> barre 0..1 sur une échelle de -60 dB à 0 dB.
static func level_bar_value(rms: float) -> float:
	if rms <= 0.0:
		return 0.0
	return clampf((linear_to_db(rms) + 60.0) / 60.0, 0.0, 1.0)

static func _action_key_text(action: String) -> String:
	if not InputMap.has_action(action):
		return "?"
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return (ev as InputEventKey).as_text().replace(" (Physical)", "")
	return "unbound"

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
