# Task 7: pause_menu — "Banned IPs" admin page

**Files:**
- Modify: `Game/source/scripts/ui/pause_menu.gd` (new `lan` back-reference + `set_lan_ref` near the `lan` signal decls ~line 12, `_current_view` doc line 68, `_show_banned` near `_show_lan`, "Banned IPs" button in `_show_lan` after `_lan_results_box` ~line 1400)
- Modify: `Game/source/scripts/main/wayland_room.gd` (one setup line)

**Interfaces:**
- Consumes: `lan.get_banned_ips()`, `lan.unban_ip(ip)` (Task 1/2), `_make_*` menu builders (existing)
- Produces: nothing

### Step 1: Add the `_lan` reference + setter in pause_menu.gd

Add a member next to line 67 (`var _settings`):

```gdscript
var _lan: Node = null

## Réf. directe vers le lan_manager (retour de get_banned_ips/unban_ip dans
## la page admin). Injectée par wayland_room au setup LAN.
func set_lan_ref(lan: Node) -> void:
	_lan = lan
```

### Step 2: Implement `_show_banned()`

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

### Step 3: Add the "Banned IPs" entry button in `_show_lan`

In `_show_lan`, right after the `_lan_players_label` block (after line 1391), before the Disconnect button:

```gdscript
	var banned_btn := _make_btn("Banned IPs", Color(0.2, 0.18, 0.28, 0.9))
	banned_btn.pressed.connect(_show_banned)
	container.add_child(banned_btn)
```

### Step 4: Inject the reference in wayland_room

In the LAN setup block (same area as Task 6 Step 1), add:

```gdscript
	pause_menu.set_lan_ref(lan)
```

### Step 5: Parse-check + full suite

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/pause_menu.gd && godot --headless --check-only --script scripts/main/wayland_room.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK on both, 42/42 pass.

### Step 6: Commit

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