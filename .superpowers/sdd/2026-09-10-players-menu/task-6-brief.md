### Task 6: wayland_room + player.gd — wiring, hotkey, gating, notify-send, kick overlay

**Files:**
- Modify: `Game/source/scripts/main/wayland_room.gd` (`@onready` ~line 16-18, LAN setup block ~line 467-472, `_process` gating ~line 700-746, hotkey ~line 733-738, `_open_window_menu` helper area ~line 984, `_on_menu_visibility_changed` line 1297)
- Modify: `Game/source/scripts/player/player.gd` (signal conn at ~line 54-56, `_input` gating ~line 150-173)

**Interfaces:**
- Consumes: `players_menu.setup(...)`, `players_menu.visible`, `lan.kicked`, `lan.banned`, `lan.message_received` (Tasks 1-5), `_on_menu_visibility_changed` pattern
- Produces: nothing for later tasks

- [ ] **Step 1: Add the players_menu pointer + wiring in `_ready`**

In `wayland_room.gd`, next to the other `@onready` menu refs (lines 16-18):

```gdscript
@onready var players_menu = $Level/Player/PlayersMenuLayer/PlayersMenu
```

In the LAN setup block after `file_share.setup(player, lan, compositor)` (line 471) add:

```gdscript
	players_menu.setup(lan, compositor, file_share)
	players_menu.visibility_changed.connect(_on_menu_visibility_changed)
	lan.message_received.connect(_on_lan_message_received)
	lan.kicked.connect(func(): _lan_flash("Kicked by host"))
	lan.banned.connect(func(): _lan_flash("You banned a player"))
```

Note: `_on_menu_visibility_changed` is already connected to `pause_menu`/`window_menu` (lines 363-364) — connecting `players_menu` reuse it.

- [ ] **Step 2: Add the hotkey toggle + `_open_players_menu`**

In `_process`, right after the `window_menu` toggle block (lines 733-738):

```gdscript
	if Input.is_action_just_pressed("players_menu", true) and not focus.is_active() and not layers.keyboard_busy():
		if players_menu.visible:
			layers.deactivate_layer_interact()
			players_menu.hide_menu()
		else:
			_open_players_menu()
```

Add the helper next to `_open_window_menu` (line 984):

```gdscript
func _open_players_menu() -> void:
	layers.deactivate_layer_interact()
	if interact_mode_active:
		compositor.release_all_keys()
		interact_mode_active = false
		player.interact_mode_active = false
	players_menu.show_menu()

- [ ] **Step 3: Add players_menu to the `_process` gating returns**

At the radial-menu guard (line 724), add `and not players_menu.visible`:

```gdscript
		elif not _menu_just_closed \
				and not focus.in_game() \
				and not window_menu.visible and not pause_menu.visible and not players_menu.visible:
```

At the early-return (line 746):

```gdscript
	if window_menu.visible or capture_selector.visible or players_menu.visible:
		return
```

- [ ] **Step 4: Update `_on_menu_visibility_changed`**

```gdscript
func _on_menu_visibility_changed() -> void:
	if not window_menu.visible and not pause_menu.visible and not players_menu.visible:
		_menu_just_closed = true
```

- [ ] **Step 5: Add notify-send + notice overlay handlers**

```gdscript
func _on_lan_message_received(sender_name: String, text: String) -> void:
	var output := []
	var err := OS.execute("notify-send", ["CyberRealm", "%s: %s" % [sender_name, text]], output, false)
	if err != 0:
		print("[LAN] notify-send failed: exit ", err)
```

And the transient top overlay (used for kicked/banned):

```gdscript
var _hud_notice: Label = null

func _lan_flash(text: String) -> void:
	if _hud_notice == null:
		_hud_notice = Label.new()
		_hud_notice.add_theme_font_size_override("font_size", 24)
		_hud_notice.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
		_hud_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hud_notice.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_hud_notice.offset_top = 80
		_hud_notice.offset_bottom = 120
		$Level/Player/UI.add_child(_hud_notice)
	_hud_notice.text = text
	_hud_notice.visible = true
	await get_tree().create_timer(4.0).timeout
	if is_instance_valid(_hud_notice) and _hud_notice.text == text:
		_hud_notice.visible = false
```

**Note:** `func _lan_flash ... await ...` — the results of `_on_menu_visibility_changed` and connections that call it are fine. `_lan_flash` is called from a lambda (`func(): _lan_flash(...)`) — awaiting in a function invoked without await is allowed (it just returns immediately).

- [ ] **Step 6: player.gd — connect visibility + `_input` gating**

In `player.gd` `_ready` next to the other `visibility_changed` connects (lines 54-56):

```gdscript
	$PlayersMenuLayer/PlayersMenu.visibility_changed.connect(_on_menu_visibility_changed)
```

In `_input`, after the `CaptureSelector` block (line 156-157) add:

```gdscript
	if $PlayersMenuLayer/PlayersMenu.visible:
		return
```

In the pause-menu Escape handler, after the existing `WindowMenu` guard (line 165-166), add the same guard so the players menu's own Escape handling (hide) wins instead of opening the pause menu:

```gdscript
		if $PlayersMenuLayer/PlayersMenu.visible:
			return
```

- [ ] **Step 7: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/main/wayland_room.gd && godot --headless --check-only --script scripts/player/player.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK on both, 42/42 pass.

- [ ] **Step 8: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/main/wayland_room.gd Game/source/scripts/player/player.gd && git commit -m "feat(ui): wire players menu hotkey, gating, notify-send and kick overlay"
```

---

### Task 7: pause_menu — "Banned IPs" admin page

**Files:**
- Modify: `Game/source/scripts/ui/pause_menu.gd` (new `lan` back-reference + `set_lan_ref` near the `lan` signal decls ~line 12, `_current_view` doc line 68, `_show_banned` near `_show_lan`, "Banned IPs" button in `_show_lan` after `_lan_results_box` ~line 1400)
- Modify: `Game/source/scripts/main/wayland_room.gd` (one setup line)

**Interfaces:**
- Consumes: `lan.get_banned_ips()`, `lan.unban_ip(ip)` (Task 1/2), `_make_*` menu builders (existing)
- Produces: nothing

- [ ] **Step 1: Add the `_lan` reference + setter in pause_menu.gd**

Add a member next to line 67 (`var _settings`):

```gdscript
var _lan: Node = null

## Réf. directe vers le lan_manager (retour de get_banned_ips/unban_ip dans
## la page admin). Injectée par wayland_room au setup LAN.
func set_lan_ref(lan: Node) -> void:
	_lan = lan
```

- [ ] **Step 2: Implement `_show_banned()`**

Add near `_show_lan` (after line 1150):

```gdscript
func _show_banned() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "banned"

	container.add_child(_make_title("BANNED IPS"))

	var hint := Label.new()
	hint.text = "Banned IPs cannot rejoin this machine's LAN sessions.\nThis list is local to this computer."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var list: Array = _lan.get_banned_ips() if _lan != null else []
	if list.is_empty():
		var empty := Label.new()
		empty.text = "No banned IPs"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
		container.add_child(empty)
	else:
		for ip: String in list:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var ip_label := Label.new()
			ip_label.text = ip
			ip_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ip_label.add_theme_font_size_override("font_size", 14)
			row.add_child(ip_label)
			var unban_btn := _make_btn("Unban", Color(0.2, 0.2, 0.3, 0.9))
			unban_btn.custom_minimum_size = Vector2(110, 36)
			unban_btn.pressed.connect(_on_unban.bind(ip))
			row.add_child(unban_btn)
			container.add_child(row)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _on_unban(ip: String) -> void:
	if _lan:
		_lan.unban_ip(ip)
	_show_banned()
```

Update the `_current_view` doc comment on line 68 to add `"banned"`:

```gdscript
var _current_view := "main" # "main" | "keybinds" | "startup" | "custom" | "keyboard_layout" | "polkit" | "lan" | "banned"
```

- [ ] **Step 3: Add the "Banned IPs" entry button in `_show_lan`**

In `_show_lan`, right after the `_lan_players_label` block (after line 1391), before the Disconnect button:

```gdscript
	var banned_btn := _make_btn("Banned IPs", Color(0.2, 0.18, 0.28, 0.9))
	banned_btn.pressed.connect(_show_banned)
	container.add_child(banned_btn)
```

- [ ] **Step 4: Inject the reference in wayland_room**

In the LAN setup block (same area as Task 6 Step 1), add:

```gdscript
	pause_menu.set_lan_ref(lan)
```

- [ ] **Step 5: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/pause_menu.gd && godot --headless --check-only --script scripts/main/wayland_room.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK on both, 42/42 pass.

- [ ] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/ui/pause_menu.gd Game/source/scripts/main/wayland_room.gd && git commit -m "feat(ui): pause menu Banned IPs admin page"
```

---

## Final verification (manual, 2 machines)

1. Build/run the compositor game on two LAN machines (existing dev flow).
2. Join the LAN session from `pause_menu → LAN`.
3. Press SUPER+SHIFT+P → menu opens, one tab per remote player, 3D avatar preview rotating.
4. Send Message → target shows a `notify-send` "CyberRealm" toast with `<sender>: <text>`.
5. Send File → zenity dialog opens in-compositor; pick a file → target gets the standard accept prompt → transfer runs over rsync/ssh.
6. KICK / BAN (host only) → target shows the "Kicked by host" overlay; the banned IP's rejoin is rejected with status "Banned IP rejected: <ip>".
7. pause_menu → LAN → Banned IPs: unban restores rejoin.
