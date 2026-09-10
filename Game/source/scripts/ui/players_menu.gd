extends GameMenu
## Menu d'actions sur les joueurs distants (LAN) : un onglet par joueur,
## preview 3D de son avatar, et actions (message / fichier / kick / ban).
## S'ouvre/ferme avec SUPER+SHIFT+P (OU manière), Échap, Start ou B.

signal menu_closed()

const DEFAULT_AVATAR := "res://scenes/avatar.tscn"

@onready var tabs_container: HBoxContainer = $VBox/TopBar/Tabs
@onready var preview_viewport: SubViewport = $VBox/Content/Preview/AvatarViewport
@onready var actions_container: VBoxContainer = $VBox/Content/Actions

var _lan: Node
var _compositor: Node
var _file_share: Node
var selected_peer := 0
var tab_buttons: Dictionary = {} # peer_id -> Button
var _preview_avatar: Node3D = null
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

func _ready() -> void:
	visible = false
	_apply_styling()
	_build_action_buttons()

func setup(lan_ref: Node, compositor_ref: Node, file_share_ref: Node) -> void:
	_lan = lan_ref
	_compositor = compositor_ref
	_file_share = file_share_ref
	if _lan != null and _lan.has_signal("players_changed"):
		if not _lan.players_changed.is_connected(_refresh_tabs):
			_lan.players_changed.connect(_refresh_tabs)

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

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	_refresh_tabs()
	visible = true

func hide_menu() -> void:
	visible = false
	_clear_preview()
	menu_closed.emit()

func _process(_delta: float) -> void:
	super(_delta)
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
		var ok: bool = _file_share.send_file_to_peer(_picker_peer, path) if _file_share != null else false
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

func _input(event: InputEvent) -> void:
	super(event) # GameMenu : consomme les JoypadMotion
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_START, JOY_BUTTON_B]:
		hide_menu()
		get_viewport().set_input_as_handled()

# ── Onglets ────────────────────────────────────────────────────────────

func _refresh_tabs() -> void:
	for child in tabs_container.get_children():
		child.queue_free()
	tab_buttons.clear()

	if _lan == null or not _lan.is_session_active():
		_empty_state("No LAN session")
		return

	var me := multiplayer.get_unique_id()
	var remote: Array = []
	for e in _lan.get_players_roster():
		if int(e.get("id", 0)) != me:
			remote.append(e)

	if remote.is_empty():
		_empty_state("No players joined")
		return

	if not _peer_present(remote, selected_peer):
		selected_peer = int(remote[0].get("id", 0))

	for e in remote:
		var peer_id := int(e["id"])
		var btn := Button.new()
		btn.text = "  " + String(e.get("name", "Player")) + "  "
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

		if peer_id == selected_peer:
			var selected := normal.duplicate()
			selected.bg_color = Color(0.15, 0.22, 0.4, 0.95)
			selected.border_color = Color(0.4, 0.6, 1.0, 0.8)
			selected.border_width_bottom = 2
			btn.add_theme_stylebox_override("normal", selected)

		var hover := normal.duplicate()
		hover.bg_color = Color(0.15, 0.2, 0.35, 0.95)
		hover.border_color = Color(0.4, 0.6, 1.0, 0.6)
		hover.border_width_bottom = 2
		btn.add_theme_stylebox_override("hover", hover)

		btn.set_meta("peer_id", peer_id)
		btn.pressed.connect(func(): _on_tab_pressed(peer_id))
		tabs_container.add_child(btn)
		tab_buttons[peer_id] = btn

	if tab_buttons.has(selected_peer):
		tab_buttons[selected_peer].grab_focus()
	_update_preview()
	_update_actions()

func _peer_present(remote: Array, peer_id: int) -> bool:
	for e in remote:
		if int(e.get("id", 0)) == peer_id:
			return true
	return false

func _empty_state(text: String) -> void:
	selected_peer = 0
	_clear_preview()
	_update_actions()
	var lbl := Label.new()
	lbl.text = "  " + text + "  "
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.7))
	tabs_container.add_child(lbl)

func _on_tab_pressed(peer_id: int) -> void:
	selected_peer = peer_id
	_msg_row.visible = false
	_confirm_row.visible = false
	_confirm_kind = ""
	for child in tabs_container.get_children():
		if not child.has_meta("peer_id"):
			continue
		var this_id: int = child.get_meta("peer_id")
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
		if this_id == peer_id:
			normal.bg_color = Color(0.15, 0.22, 0.4, 0.95)
			normal.border_color = Color(0.4, 0.6, 1.0, 0.8)
			normal.border_width_bottom = 2
		child.add_theme_stylebox_override("normal", normal)
	_update_preview()
	_update_actions()

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

func _on_file_pick_pressed() -> void:
	if selected_peer == 0 or _picker_running:
		return
	var buf := _pick_buf_path("")
	var done := _pick_buf_path(".done")
	DirAccess.remove_absolute(buf)
	DirAccess.remove_absolute(done)
	var cmd := "sh -c 'zenity --file-selection > \"$XDG_RUNTIME_DIR/cyberrealm-filepick\" ; touch \"$XDG_RUNTIME_DIR/cyberrealm-filepick.done\"'"
	_compositor.launch_app(cmd)
	_picker_running = true
	_picker_peer = selected_peer
	_picker_deadline = Time.get_ticks_msec() + 60000
	_set_status("Selecting file… (cancel with Esc in the dialog, 60 s timeout)")
	_update_actions()

# ── Preview avatar ─────────────────────────────────────────────────────

static func apply_flat_preview_materials(avatar: Node) -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_preview_meshes(avatar, meshes)
	for mi in meshes:
		if mi.mesh == null:
			continue
		var source: BaseMaterial3D = null
		if mi.material_override is BaseMaterial3D:
			source = mi.material_override as BaseMaterial3D
		elif mi.get_surface_override_material(0) is BaseMaterial3D:
			source = mi.get_surface_override_material(0) as BaseMaterial3D
		elif mi.mesh.get_surface_count() > 0:
			source = mi.mesh.surface_get_material(0)
		var mat: BaseMaterial3D = source.duplicate() if source != null else StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mat


static func _collect_preview_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect_preview_meshes(child, out)


func _update_preview() -> void:
	_clear_preview()
	if selected_peer == 0 or _lan == null:
		return
	var av: Node = _lan.get_remote_players().get(selected_peer)
	if av == null or not is_instance_valid(av):
		return
	var name := ""
	var color := Color.WHITE
	for e in _lan.get_players_roster():
		if int(e.get("id", 0)) == selected_peer:
			name = String(e.get("name", ""))
			color = Color(e.get("color", Color.WHITE))
			break
	var scene := _avatar_scene(selected_peer)
	_preview_avatar = scene.instantiate()
	if _preview_avatar.has_method("setup"):
		_preview_avatar.setup(selected_peer, name, color)
	apply_flat_preview_materials(_preview_avatar)
	_preview_avatar.position = Vector3.ZERO
	_preview_avatar.rotation = Vector3.ZERO
	preview_viewport.add_child(_preview_avatar)
	# Prewarm + arrivé : visible une fois les shaders compilés (pas de TDR).
	if _preview_avatar.has_method("start_prewarm"):
		_preview_avatar.start_prewarm()
	if _preview_avatar.has_method("set_arrived"):
		_preview_avatar.set_arrived(true)

func _avatar_scene(peer_id: int) -> PackedScene:
	var av: Node = _lan.get_remote_players().get(peer_id)
	if av is Node and is_instance_valid(av):
		var p := av.get_scene_file_path()
		if p != "":
			var loaded := load(p) as PackedScene
			if loaded != null:
				return loaded
	return load(DEFAULT_AVATAR) as PackedScene

func _clear_preview() -> void:
	if _preview_avatar != null and is_instance_valid(_preview_avatar):
		_preview_avatar.queue_free()
	_preview_avatar = null
