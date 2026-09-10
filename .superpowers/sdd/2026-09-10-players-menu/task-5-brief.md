### Task 5: PlayersMenu actions — message, send-file (zenity poll), kick/ban confirm

**Files:**
- Modify: `Game/source/scripts/ui/players_menu.gd`

**Interfaces:**
- Consumes: `lan.send_message_to(peer_id, text)`, `lan.kick_player(peer_id)`, `lan.ban_player(peer_id)`, `lan.is_host`, `file_share.send_file_to_peer(peer_id, path)` (Tasks 2/3), `_compositor.launch_app(cmd)` (existing `WlrCompositor`)
- Produces: nothing new for later tasks (only internal UI behavior)

- [ ] **Step 1: Add action-panel members and builders**

Replace the `_build_action_buttons() { pass }` and `_update_actions() { pass }` stubs from Task 4. Add member vars after `var _preview_avatar`:

```gdscript
var _status_label: Label = null
var _send_msg_btn: Button = null
var _send_file_btn: Button = null
var _kick_btn: Button = null
var _ban_btn: Button = null
var _msg_row: HBoxContainer = null
var _msg_edit: LineEdit = null
var _confirm_row: HBoxContainer = null
var _confirm_label: Label = null
var _confirm_confirm_btn: Button = null
var _confirm_cancel_btn: Button = null
var _confirm_kind := "" # "kick" | "ban"
# ── Sélecteur de fichier (zenity) ──────────────────────────────────────
var _picker_running := false
var _picker_peer := 0
var _picker_deadline := 0

# Fichiers tampons du sélecteur (filtre XDG runtime dir, hérité de l'environnement).
func _pick_buf_path(suffix: String) -> String:
	var runtime := OS.get_environment("XDG_RUNTIME_DIR")
	if runtime.is_empty():
		runtime = OS.get_temp_dir()
	return runtime.path_join("cyberrealm-filepick" + suffix)
```

```gdscript
func _build_action_buttons() -> void:
	_send_msg_btn = _build_std_button("SEND MESSAGE", "_on_send_message_pressed")
	_send_file_btn = _build_std_button("SEND FILE", "_on_file_pick_pressed")
	_kick_btn = _build_std_button("KICK", "_on_kick_pressed")
	_ban_btn = _build_std_button("BAN", "_on_ban_pressed")

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	_status_label.custom_minimum_size.y = 34
	actions_container.add_child(_status_label)

	_msg_row = HBoxContainer.new()
	_msg_row.visible = false
	_msg_edit = LineEdit.new()
	_msg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg_edit.placeholder_text = "Message…"
	var msg_send := Button.new()
	msg_send.text = "Send"
	msg_send.pressed.connect(_on_send_message)
	_msg_row.add_child(_msg_edit)
	_msg_row.add_child(msg_send)
	actions_container.add_child(_msg_row)

	_confirm_row = HBoxContainer.new()
	_confirm_row.visible = false
	_confirm_label = Label.new()
	_confirm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_label.add_theme_font_size_override("font_size", 12)
	_confirm_cancel_btn = Button.new()
	_confirm_cancel_btn.text = "Cancel"
	_confirm_cancel_btn.pressed.connect(func():
		_confirm_row.visible = false
		_confirm_kind = ""
	)
	_confirm_confirm_btn = Button.new()
	_confirm_confirm_btn.text = "Confirm"
	_confirm_confirm_btn.pressed.connect(_on_confirm)
	_confirm_row.add_child(_confirm_label)
	_confirm_row.add_child(_confirm_cancel_btn)
	_confirm_row.add_child(_confirm_confirm_btn)
	actions_container.add_child(_confirm_row)
```

Add the helper `_build_std_button` (reuses window_menu's button styling):

```gdscript
func _build_std_button(label: String, handler: String) -> Button:
	var btn := Button.new()
	btn.text = label
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
	btn.pressed.connect(Callable(self, handler))
	actions_container.add_child(btn)
	return btn
```

- [ ] **Step 2: Implement `_update_actions`**

```gdscript
func _update_actions() -> void:
	if _send_msg_btn == null:
		return
	var has_peer := selected_peer != 0
	_send_msg_btn.disabled = not has_peer
	_send_file_btn.disabled = not has_peer or _picker_running
	_kick_btn.visible = _lan != null and _lan.is_host and has_peer
	_ban_btn.visible = _lan != null and _lan.is_host and has_peer
	if not has_peer:
		_msg_row.visible = false
		_confirm_row.visible = false
		_confirm_kind = ""
	_msg_edit.editable = has_peer
```

- [ ] **Step 3: Implement message / kick / ban handlers**

```gdscript
func _on_send_message_pressed() -> void:
	_msg_row.visible = not _msg_row.visible
	if _msg_row.visible:
		_msg_edit.grab_focus()
	_confirm_row.visible = false
	_confirm_kind = ""

func _on_send_message() -> void:
	if selected_peer == 0 or _lan == null:
		return
	var text := _msg_edit.text.strip_edges()
	if text.is_empty():
		return
	_lan.send_message_to(selected_peer, text)
	_set_status("Message sent to %s" % _player_display_name())
	_msg_edit.text = ""
	_msg_row.visible = false

func _on_kick_pressed() -> void:
	_show_confirm("kick")

func _on_ban_pressed() -> void:
	_show_confirm("ban")

func _show_confirm(kind: String) -> void:
	if selected_peer == 0 or _lan == null or not _lan.is_host:
		return
	_confirm_kind = kind
	_confirm_label.text = "Confirm %s %s?" % [kind.to_upper(), _player_display_name()]
	_confirm_row.visible = true
	_msg_row.visible = false

func _on_confirm() -> void:
	if _confirm_kind.is_empty() or selected_peer == 0 or _lan == null:
		return
	if _confirm_kind == "kick":
		_lan.kick_player(selected_peer)
	else:
		_lan.ban_player(selected_peer)
	hide_menu()

func _player_display_name() -> String:
	if _lan == null or selected_peer == 0:
		return ""
	for e in _lan.get_players_roster():
		if int(e.get("id", 0)) == selected_peer:
			return String(e.get("name", "Player"))
	return "Player"

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
```

- [ ] **Step 4: Implement the zenity file picker + polling**

```gdscript
func _on_file_pick_pressed() -> void:
	if selected_peer == 0 or _picker_running:
		return
	var buf := _pick_buf_path("")
	var done := _pick_buf_path(".done")
	DirAccess.remove_absolute(buf)
	DirAccess.remove_absolute(done)
	var cmd := "sh -c 'zenity --file-selection > \"$XDG_RUNTIME_DIR/cyberrealm-filepick\" && touch \"$XDG_RUNTIME_DIR/cyberrealm-filepick.done\"'"
	_compositor.launch_app(cmd)
	_picker_running = true
	_picker_peer = selected_peer
	_picker_deadline = Time.get_ticks_msec() + 60000
	_set_status("Selecting file… (cancel with Esc in the dialog, 60 s timeout)")
	_update_actions()
```

Override `_process` (already present from Task 4) to poll after `super(delta)`:

```gdscript
func _process(delta: float) -> void:
	super(delta)
	if _preview_avatar != null and is_instance_valid(_preview_avatar):
		_preview_avatar.rotation.y += delta * 0.5
	if _picker_running:
		_poll_file_picker()

func _poll_file_picker() -> void:
	var buf := _pick_buf_path("")
	var done := _pick_buf_path(".done")
	if FileAccess.file_exists(done):
		var f := FileAccess.open(buf, FileAccess.READ)
		var path := ""
		if f != null:
			path = f.get_as_text().strip_edges()
			f.close()
		_picker_running = false
		DirAccess.remove_absolute(buf)
		DirAccess.remove_absolute(done)
		_update_actions()
		if path.is_empty():
			_set_status("File selection cancelled")
			return
		var ok := _file_share.send_file_to_peer(_picker_peer, path) if _file_share != null else false
		_picker_peer = 0
		if ok:
			_set_status("File offer sent")
		else:
			_set_status("Cannot send this file")
		return
	if Time.get_ticks_msec() > _picker_deadline:
		_picker_running = false
		_picker_peer = 0
		DirAccess.remove_absolute(buf)
		DirAccess.remove_absolute(done)
		_update_actions()
		_set_status("File selection timed out")
	# Drop le peer ciblé pendant la sélection
	if _picker_peer != 0 and (_lan == null or not _peer_present(_lan.get_players_roster(), _picker_peer)):
		_picker_running = false
		_picker_peer = 0
		DirAccess.remove_absolute(buf)
		DirAccess.remove_absolute(done)
		_update_actions()
		_set_status("Target player left")
```

- [ ] **Step 5: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/players_menu.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 42/42 pass.

- [ ] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/ui/players_menu.gd && git commit -m "feat(ui): players menu actions (message, file picker, kick/ban confirm)"
```

---

