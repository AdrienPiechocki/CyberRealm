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
	# Construit uniquement les conteneurs vides ; les vrais boutons arrivent
	# dans _refresh_tabs (Task 5). Rien ici pour le moment.
	pass

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

func _process(delta: float) -> void:
	super(delta)
	if _preview_avatar != null and is_instance_valid(_preview_avatar):
		_preview_avatar.rotation.y += delta * 0.5

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
	# Implémenté dans Task 5 (boutons d'action).
	pass

# ── Preview avatar ─────────────────────────────────────────────────────

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
