### Task 4: PlayersMenu scene + core script + input action

Builds the menu shell: tabs per remote player, 3D avatar preview with slow rotation, open/close (Esc/Start/B), live roster refresh. Action buttons are stubbed here and implemented in Task 5.

**Files:**
- Create: `Game/source/scripts/ui/players_menu.gd`
- Modify: `Game/source/scenes/player.tscn` (new `PlayersMenuLayer` branch), `Game/source/project.godot` (input action)

**Interfaces:**
- Consumes: `lan.get_players_roster()`, `lan.get_remote_players()`, `lan.is_session_active()`, `lan.players_changed` (Task 1/2 established), `GameMenu` base, avatar `setup/set_arrived/start_prewarm` (existing `player/avatar.gd`), `get_scene_file_path()` on remote avatar nodes
- Produces (consumed by Tasks 5 & 6):
  - `func setup(lan_ref: Node, compositor_ref: Node, file_share_ref: Node) -> void`
  - `func show_menu() / hide_menu() / toggle_menu()`
  - `signal menu_closed()`
  - `var selected_peer := 0`
  - script path `res://scripts/ui/players_menu.gd`, node path `PlayersMenuLayer/PlayersMenu`

- [ ] **Step 1: Add the input action in project.godot**

Add at the end of the `[input]` section, right after the `radial_menu` block (entry `physical_keycode` = 80 unicode, mirroring `window_menu`'s serialization but with physical key 77 = KEY_P):

```
players_menu={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":true,"ctrl_pressed":false,"meta_pressed":true,"pressed":false,"keycode":0,"physical_keycode":77,"key_label":0,"unicode":80,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 2: Add the PlayersMenuLayer branch to `scenes/player.tscn`**

Add `PlayersMenu` as a sibling of the existing `WindowMenuLayer`/`CaptureSelectorLayer` layers. Insert right after the `WindowMenu` subtree (after line 114). Add `[ext_resource]` for the script at the top of the file (after line 10):

```
[ext_resource type="Script" path="res://scripts/ui/players_menu.gd" id="10_players_menu"]
```

Then the node block (use `unique_id` values NOT already present in the file, e.g. `4200000001`-`4200000008`):

```
[node name="PlayersMenuLayer" type="CanvasLayer" parent="." unique_id=4200000001]

[node name="PlayersMenu" type="PanelContainer" parent="PlayersMenuLayer" unique_id=4200000002]
anchors_preset = 8
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -450.0
offset_top = -300.0
offset_right = 450.0
offset_bottom = 300.0
grow_horizontal = 2
grow_vertical = 2
script = ExtResource("10_players_menu")

[node name="VBox" type="VBoxContainer" parent="PlayersMenuLayer/PlayersMenu" unique_id=4200000003]
layout_mode = 2
theme_override_constants/separation = 0

[node name="TopBar" type="ScrollContainer" parent="PlayersMenuLayer/PlayersMenu/VBox" unique_id=4200000004]
custom_minimum_size = Vector2(0, 40)
layout_mode = 2
vertical_scroll_mode = 0

[node name="Tabs" type="HBoxContainer" parent="PlayersMenuLayer/PlayersMenu/VBox/TopBar" unique_id=4200000005]
layout_mode = 2
size_flags_vertical = 3
theme_override_constants/separation = 2

[node name="Content" type="HBoxContainer" parent="PlayersMenuLayer/PlayersMenu/VBox" unique_id=4200000006]
layout_mode = 2
size_flags_vertical = 3
theme_override_constants/separation = 0

[node name="Preview" type="SubViewportContainer" parent="PlayersMenuLayer/PlayersMenu/VBox/Content" unique_id=4200000007]
layout_mode = 2
size_flags_horizontal = 3
size_flags_vertical = 3
stretch = true

[node name="AvatarViewport" type="SubViewport" parent="PlayersMenuLayer/PlayersMenu/VBox/Content/Preview" unique_id=4200000008]
handle_input_locally = false
render_target_update_mode = 4
size = Vector2i(600, 500)

[node name="Camera3D" type="Camera3D" parent="PlayersMenuLayer/PlayersMenu/VBox/Content/Preview/AvatarViewport"]
transform = Transform3D(1, 0, 0, 0, 0.992, -0.124, 0, 0.124, 0.992, 0, 1.6, 3.2)
current = true

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="PlayersMenuLayer/PlayersMenu/VBox/Content/Preview/AvatarViewport"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 4.5, 3)

[node name="VSeparator" type="VSeparator" parent="PlayersMenuLayer/PlayersMenu/VBox/Content" unique_id=4200000009]

[node name="Actions" type="VBoxContainer" parent="PlayersMenuLayer/PlayersMenu/VBox/Content" unique_id=4200000010]
custom_minimum_size = Vector2(200, 0)
layout_mode = 2
theme_override_constants/separation = 6
```

- [ ] **Step 3: Write the core script `players_menu.gd`**

```gdscript
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
```

- [ ] **Step 4: Parse-check both new/changed scripts**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/players_menu.gd
```
Expected: no errors (scene/action wired in Task 6, so the game won't launch yet — parse check only).

- [ ] **Step 5: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scenes/player.tscn Game/source/project.godot Game/source/scripts/ui/players_menu.gd && git commit -m "feat(ui): PlayersMenu scene + tabs + avatar preview + input action"
```

---

