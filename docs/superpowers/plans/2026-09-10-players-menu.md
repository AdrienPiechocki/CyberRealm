# Players Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "players menu" openable with SUPER+SHIFT+P (gamepad or keyboard) showing one tab per remote LAN player, a 3D avatar preview, and per-player actions (send file, send message, kick, ban).

**Architecture:** A new monotab menu `PlayersMenu` (`extends GameMenu`, same layout/theme as `window_menu`) built around the existing LAN roster. The LAN manager gains message/kick/ban RPCs plus a persisted IP ban list (JSON), the file-share manager gains a programmatic `send_file_to_peer()`, and the compositor-launched `zenity --file-selection` picker is polled by the menu itself. `wayland_room` wires the hotkey/gating and consumes the new signals (`message_received`, `kicked`, `banned`); the pause menu hosts a "Banned IPs" admin page.

**Tech Stack:** Godot 4.7.2 (GDScript), ENet multiplay, `notify-send`/`zenity`/`sh -c` host tools, JSON settings files (existing `_settings` pattern).

**Spec:** `docs/superpowers/specs/2026-09-10-players-menu-design.md`

## Global Constraints

- Godot 4.7.2, GDScript with typed parameters/returns; class-level doc comments in French (existing convention).
- All menus extend `GameMenu`; fill `panel` style identical to `window_menu` (`StyleBoxFlat` dark blue, 900x600 centered).
- Hotkey: new input action `players_menu` = InputEventKey `physical_keycode=77` (KEY_P) with `meta_pressed=true`, `shift_pressed=true`. `pin_window` (SUPER+P) must NOT be touched.
- Local player is always excluded from player tabs (only remote players).
- Kick/Ban are host-only (`lan.is_host == true`); host self-kick is impossible (self excluded).
- Ban list file: `user://lan_ban_list.json` (JSON `Array` of IP strings), loaded/saved on each operation.
- Networking RPC annotation style: `@rpc("any_peer", "reliable")` (existing pattern).
- No new third-party libraries; headless verification only:
  - Parse: `godot --headless --check-only --script <relative-path>` (run from `Game/source`)
  - Tests: `godot --headless --script res://tests/runner.gd` (run from `Game/source`)

---

### Task 1: Ban list core (lan_manager) — pure functions + tests

**Files:**
- Modify: `Game/source/scripts/network/lan_manager.gd` (add const near line 21-22 area, add static helpers after `_remote_ip`, add instance wrappers
  near `_remote_ip`/`_on_pin_success`)
- Test: `Game/source/tests/test_lan_ban_list.gd` (new)

**Interfaces:**
- Produces (consumed by Tasks 2 & 7):
  - `const BAN_LIST_FILE := "user://lan_ban_list.json"`
  - `static func is_ip_banned(ip: String, banned: Array) -> bool`
  - `static func load_ban_list_from(path: String) -> Array`
  - `static func save_ban_list_to(path: String, banned: Array) -> void`
  - `func _load_ban_list() -> Array`
  - `func _save_ban_list(banned: Array) -> void`
  - `func get_banned_ips() -> Array`

- [x] **Step 1: Write the failing test**

Create `Game/source/tests/test_lan_ban_list.gd`:

```gdscript
extends Node
## Tests pour la liste de ban IP persistée du lan_manager.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func _ban_path() -> String:
	return OS.get_cache_dir().path_join("cyberrealm_ban_test.json")

func test_is_ip_banned():
	var list := ["192.168.1.23", "10.0.0.7"]
	var r = Runner.assert_eq(LANManager.is_ip_banned("192.168.1.23", list), true, "IP presente -> bannie")
	if r != true: return r
	r = Runner.assert_eq(LANManager.is_ip_banned("192.168.1.99", list), false, "IP absente -> libre")
	if r != true: return r
	r = Runner.assert_eq(LANManager.is_ip_banned("", list), false, "IP vide -> jamais bannie")
	if r != true: return r
	return true

func test_ban_list_roundtrip():
	var path := _ban_path()
	var r = Runner.assert_eq(LANManager.load_ban_list_from(path), [], "Fichier absent -> liste vide")
	if r != true: return r
	var list := ["192.168.1.23", "10.0.0.7"]
	LANManager.save_ban_list_to(path, list)
	var loaded := LANManager.load_ban_list_from(path)
	r = Runner.assert_eq(loaded.size(), 2, "Round-trip : 2 entrees conservees")
	if r != true: return r
	r = Runner.assert_eq(String(loaded[0]), "192.168.1.23", "IP 0 conservee")
	if r != true: return r
	DirAccess.remove_absolute(path)
	return true

func test_ban_list_corrupt():
	var path := _ban_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var loaded := LANManager.load_ban_list_from(path)
	var r = Runner.assert_eq(loaded, [], "Fichier corrompu -> liste vide")
	if r != true: return r
	DirAccess.remove_absolute(path)
	return true
```

- [x] **Step 2: Run tests to verify they fail**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: 3 new FAILs (`is_ip_banned` not found / etc.), total rises to 40.

- [x] **Step 3: Implement in lan_manager.gd**

Add after the existing `const RECONNECT_MAX_ATTEMPTS := 12` (line ~63) a new const:

```gdscript
# Fichier de la liste de bannis (IP) persistée. Lue/écrite à chaque
# opération (pas de cache : le pause_menu la relit en direct).
const BAN_LIST_FILE := "user://lan_ban_list.json"
```

Insert a new section right after `_remote_ip` (ends at line 591):

```gdscript
# ── Ban list (kick/ban persistés) ─────────────────────────────────────

## Vrai si `ip` figure dans la liste de bannis. Pure et statique
## (testable headless) : la liste est passée en argument.
static func is_ip_banned(ip: String, banned: Array) -> bool:
	if ip.is_empty():
		return false
	return banned.has(ip)

## Lit la ban list depuis un fichier JSON (Array de String). Fichier
## absent ou corrompu -> liste vide.
static func load_ban_list_from(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Array:
		return parsed
	return []

static func save_ban_list_to(path: String, banned: Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("LAN: cannot write ban list: " + path)
		return
	f.store_string(JSON.stringify(banned))
	f.close()

func _load_ban_list() -> Array:
	return load_ban_list_from(BAN_LIST_FILE)

func _save_ban_list(banned: Array) -> void:
	save_ban_list_to(BAN_LIST_FILE, banned)

## Liste actuelle des IP bannies (pour la page admin du pause_menu).
func get_banned_ips() -> Array:
	return _load_ban_list()
```

- [x] **Step 4: Run tests to verify they pass**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: all pass (40/40, 3 new).

- [x] **Step 5: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/lan_manager.gd Game/source/tests/test_lan_ban_list.gd && git commit -m "feat(lan): persisted IP ban list core with tests"
```

---

### Task 2: Network actions — message / kick / ban RPCs and join-time ban check

**Files:**
- Modify: `Game/source/scripts/network/lan_manager.gd`
  - signals block (lines 7-15), new `@rpc` methods after `_remove_player` / near line 1043, `_on_peer_connected` (line 1045), `_on_peer_disconnected` (line 1620), `var _kick_notified` near line 127

**Interfaces:**
- Consumes: `_load_ban_list()` / `_save_ban_list()` / `is_ip_banned()` / `BAN_LIST_FILE` (Task 1); existing `_remote_ip(peer_id)` (line 584), `_remove_player(peer_id)` (line 1033), `bool is_host`, `String player_name`, `_session_closed_received`, `__set_status` (line 3424)
- Produces (consumed by Tasks 4/5/6/7):
  - `signal message_received(sender_name: String, text: String)`
  - `signal kicked()`
  - `signal banned()`
  - `func send_message_to(peer_id: int, text: String) -> void`
  - `func kick_player(peer_id: int) -> void`
  - `func ban_player(peer_id: int) -> void`
  - `func unban_ip(ip: String) -> void`
  - `func _rpc_recv_message(sender_name: String, text: String) -> void` (`@rpc("any_peer", "reliable")`)
  - `func _rpc_you_were_kicked() -> void` (`@rpc("any_peer", "reliable")`)

This task's network logic is not unit-testable headless; verification is parse-check + full suite still green + the Task 1 tests passing.

- [x] **Step 1: Add the three signals**

In the signal declarations at the top of `lan_manager.gd` (after `signal pin_changed(pin: String)`, line 15):

```gdscript
# Message reçu d'un pair (send_message_to). wayland_room affiche la
# notification (notify-send) sur la machine cible.
signal message_received(sender_name: String, text: String)
# Émis sur la machine d'un joueur expulsé (kick) ou déconnecté sans préavis.
signal kicked()
# Émis sur l'HÔTE après un ban réussi (pour rafraîchir l'UI locale).
signal banned()
```

And add a state flag next to `var _session_closed_received := false` (line ~51):

```gdscript
# Vrai si on a déjà été notifié d'un kick cette session (évite un double
# affichage quand _rpc_you_were_kicked arrive puis le serveur coupe).
var _kick_notified := false
```

- [x] **Step 2: Add the message + kick/ban methods**

Insert a new section right after `_remove_player` (after line 1043):

```gdscript
# ── Messages / kick / ban ─────────────────────────────────────────────

## Envoie un court message à un peer précis. Le destinataire reçoit
## `message_received` et l'affiche via notify-send (wayland_room).
func send_message_to(peer_id: int, text: String) -> void:
	var clean := text.strip_edges()
	if clean.is_empty() or peer_id <= 0 or peer_id == multiplayer.get_unique_id():
		return
	var sender := player_name if not player_name.is_empty() else "Player"
	_rpc_recv_message.rpc_id(peer_id, sender, clean)

@rpc("any_peer", "reliable")
func _rpc_recv_message(sender_name: String, text: String) -> void:
	if sender_name.is_empty() or text.is_empty():
		return
	message_received.emit(sender_name, text)

## Expulse un joueur (hôte uniquement). Best-effort : un flag RPC part
## AVANT la coupure pour que le client affiche « Kicked by host ».
func kick_player(peer_id: int) -> void:
	if not is_host:
		_set_status("Only the host can kick players")
		return
	var mp := multiplayer.multiplayer_peer
	if mp == null:
		return
	_rpc_you_were_kicked.rpc_id(peer_id)
	_remove_player(peer_id) # purge locale + broadcast immédiats
	mp.disconnect_peer(peer_id)
	_set_status("Kicked player %d" % peer_id)

## Bannir = expulser + persister l'IP (tout rejoin sera refusé en tête de
## _on_peer_connected). Hôte uniquement.
func ban_player(peer_id: int) -> void:
	if not is_host:
		_set_status("Only the host can ban players")
		return
	var ip := _remote_ip(peer_id)
	if ip.is_empty():
		_set_status("Cannot ban player %d: IP unknown" % peer_id)
		return
	var list := _load_ban_list()
	if not list.has(ip):
		list.append(ip)
		_save_ban_list(list)
	kick_player(peer_id)
	_set_status("Banned %s" % ip)
	banned.emit()

func unban_ip(ip: String) -> void:
	if ip.is_empty():
		return
	var list := _load_ban_list()
	if list.has(ip):
		list.erase(ip)
		_save_ban_list(list)
		_set_status("Unbanned %s" % ip)

@rpc("any_peer", "reliable")
func _rpc_you_were_kicked() -> void:
	_kick_notified = true
	kicked.emit()
```

- [x] **Step 3: Add the join-time ban check in `_on_peer_connected`**

At the very top of the `if is_host:` block in `_on_peer_connected` (line 1046), BEFORE `_set_status("Player %d connected...")`:

```gdscript
	if is_host:
		# Refus immédiat des adresses bannies : aucun timeout/PIN, coupure
		# nette AVANT de la marquer en attente d'auth.
		if is_ip_banned(_remote_ip(id), _load_ban_list()):
			multiplayer.multiplayer_peer.disconnect_peer(id)
			_set_status("Banned IP rejected: %s" % _remote_ip(id))
			return
		_set_status("Player %d connected — waiting for PIN…" % id)
```

- [x] **Step 4: Add the client-side kick fallback in `_on_peer_disconnected`**

Read the current body of `_on_peer_disconnected` (line 1620). Add this block near the TOP of the function (before the existing roster purge), so a client that was cut without receiving the RPC flag still shows the notice:

```gdscript
	# Kick silencieux (coupure du serveur sans _rpc_you_were_kicked reçu) :
	# notifier l'UI. L'ID 1 est l'hôte ; un shutdown propre passe par
	# session_closed (flag posé) et ne doit PAS déclencher l'affiche.
	if not is_host and id == 1 and not _session_closed_received and not _kick_notified:
		kicked.emit()
```

- [x] **Step 5: Parse-check + run full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/network/lan_manager.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 40/40 tests pass.

- [x] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/lan_manager.gd && git commit -m "feat(lan): message/kick/ban RPCs + persisted ban enforcement on join"
```

---

### Task 3: file_share — `send_file_to_peer` + shared file-size helper + tests

**Files:**
- Modify: `Game/source/scripts/network/file_share_manager.gd` (helper after `downloads_dir()` ~line 27, `send_file_to_peer` right after `on_files_dropped` ~line 417, refactor the size loop in `on_files_dropped`)
- Test: `Game/source/tests/test_file_share.gd` (new)

**Interfaces:**
- Consumes: existing `_can_start_transfer()`, `_pending_offers`, `_next_offer_id`, `_offer_files.rpc_id`, `_show_progress`, `_peer_name(peer_id)`, `ensure_local_keypair()`, `lan.is_session_active()`, `CHANNEL` consts (all internal to the file)
- Produces (consumed by Task 5):
  - `static func readable_file_size(path: String) -> int`
  - `func send_file_to_peer(peer_id: int, path: String) -> bool`

- [x] **Step 1: Write the failing test**

Create `Game/source/tests/test_file_share.gd`:

```gdscript
extends Node
## Tests pour la validation de fichiers du partage LAN.

const Runner = preload("res://tests/runner.gd")
const FileShare = preload("res://scripts/network/file_share_manager.gd")

func _sample_path(filename: String) -> String:
	return OS.get_cache_dir().path_join(filename)

func test_readable_file_size():
	var path := _sample_path("cyberrealm_fs_sample.bin")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("0123456789")
	f.close()
	var r = Runner.assert_eq(FileShare.readable_file_size(path), 10, "Fichier lisible -> taille exacte")
	DirAccess.remove_absolute(path)
	return r

func test_readable_file_size_missing():
	var path := _sample_path("cyberrealm_fs_missing.bin")
	DirAccess.remove_absolute(path) # s'assurer qu'il n'existe pas
	var r = Runner.assert_eq(FileShare.readable_file_size(path), 0, "Fichier absent -> 0")
	if r != true: return r
	return true
```

- [x] **Step 2: Run tests to verify they fail**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: 2 new FAILs (`readable_file_size` undefined), total 42.

- [x] **Step 3: Add the helper and refactor `on_files_dropped`**

After `downloads_dir()` (line 27):

```gdscript
## Taille d'un fichier localement lisible, 0 sinon. Helper unique partagé
## entre les drops (drag & drop) et l'envoi programmatique (players_menu).
static func readable_file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size
```

Replace the file-loop inside `on_files_dropped` (lines 388-396):

```gdscript
	for p in paths:
		if _debug:
			print("[FileShare] raw path : [", p, "]")
		var size := readable_file_size(p)
		if size > 0:
			files.append(p)
			total += size
		elif _debug:
			print("[FileShare] unreadable: ", p)
```

- [x] **Step 4: Add `send_file_to_peer`**

Right after `on_files_dropped` (after line 417):

```gdscript
## Envoi programmatique d'un fichier vers un peer (players_menu). Réutilise
## le flux d'offre du drag & drop : prompt d'acceptation côté pair, puis
## transfert rsync-over-ssh. Retourne false si invalide/injoignable/busy.
func send_file_to_peer(peer_id: int, path: String) -> bool:
	if peer_id <= 0 or peer_id == multiplayer.get_unique_id():
		return false
	if lan == null or not lan.is_session_active() or not ensure_local_keypair():
		return false
	var total := readable_file_size(path)
	if total <= 0:
		return false
	if not _can_start_transfer():
		return false
	var oid := _next_offer_id
	_next_offer_id += 1
	var names := PackedStringArray([path.get_file()])
	_pending_offers[oid] = {
		"peer": peer_id, "files": [path], "names": names,
		"total": total, "msec": Time.get_ticks_msec(),
	}
	_show_progress("Offer to %s — waiting…" % _peer_name(peer_id), -1, "")
	_offer_files.rpc_id(peer_id, oid, names, total)
	return true
```

- [x] **Step 5: Run tests to verify they pass + parse-check**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/network/file_share_manager.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 42/42 pass.

- [x] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/file_share_manager.gd Game/source/tests/test_file_share.gd && git commit -m "feat(fileshare): programmatic send_file_to_peer + shared size helper"
```

---

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

- [x] **Step 1: Add the input action in project.godot**

Add at the end of the `[input]` section, right after the `radial_menu` block (entry `physical_keycode` = 80 unicode, mirroring `window_menu`'s serialization but with physical key 77 = KEY_P):

```
players_menu={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":true,"ctrl_pressed":false,"meta_pressed":true,"pressed":false,"keycode":0,"physical_keycode":77,"key_label":0,"unicode":80,"location":0,"echo":false,"script":null)
]
}
```

- [x] **Step 2: Add the PlayersMenuLayer branch to `scenes/player.tscn`**

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

- [x] **Step 3: Write the core script `players_menu.gd`**

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

- [x] **Step 4: Parse-check both new/changed scripts**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/players_menu.gd
```
Expected: no errors (scene/action wired in Task 6, so the game won't launch yet — parse check only).

- [x] **Step 5: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scenes/player.tscn Game/source/project.godot Game/source/scripts/ui/players_menu.gd && git commit -m "feat(ui): PlayersMenu scene + tabs + avatar preview + input action"
```

---

### Task 5: PlayersMenu actions — message, send-file (zenity poll), kick/ban confirm

**Files:**
- Modify: `Game/source/scripts/ui/players_menu.gd`

**Interfaces:**
- Consumes: `lan.send_message_to(peer_id, text)`, `lan.kick_player(peer_id)`, `lan.ban_player(peer_id)`, `lan.is_host`, `file_share.send_file_to_peer(peer_id, path)` (Tasks 2/3), `_compositor.launch_app(cmd)` (existing `WlrCompositor`)
- Produces: nothing new for later tasks (only internal UI behavior)

- [x] **Step 1: Add action-panel members and builders**

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

- [x] **Step 2: Implement `_update_actions`**

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

- [x] **Step 3: Implement message / kick / ban handlers**

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

- [x] **Step 4: Implement the zenity file picker + polling**

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

- [x] **Step 5: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/players_menu.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 42/42 pass.

- [x] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/ui/players_menu.gd && git commit -m "feat(ui): players menu actions (message, file picker, kick/ban confirm)"
```

---

### Task 6: wayland_room + player.gd — wiring, hotkey, gating, notify-send, kick overlay

**Files:**
- Modify: `Game/source/scripts/main/wayland_room.gd` (`@onready` ~line 16-18, LAN setup block ~line 467-472, `_process` gating ~line 700-746, hotkey ~line 733-738, `_open_window_menu` helper area ~line 984, `_on_menu_visibility_changed` line 1297)
- Modify: `Game/source/scripts/player/player.gd` (signal conn at ~line 54-56, `_input` gating ~line 150-173)

**Interfaces:**
- Consumes: `players_menu.setup(...)`, `players_menu.visible`, `lan.kicked`, `lan.banned`, `lan.message_received` (Tasks 1-5), `_on_menu_visibility_changed` pattern
- Produces: nothing for later tasks

- [x] **Step 1: Add the players_menu pointer + wiring in `_ready`**

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

- [x] **Step 2: Add the hotkey toggle + `_open_players_menu`**

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

- [x] **Step 3: Add players_menu to the `_process` gating returns**

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

- [x] **Step 4: Update `_on_menu_visibility_changed`**

```gdscript
func _on_menu_visibility_changed() -> void:
	if not window_menu.visible and not pause_menu.visible and not players_menu.visible:
		_menu_just_closed = true
```

- [x] **Step 5: Add notify-send + notice overlay handlers**

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

- [x] **Step 6: player.gd — connect visibility + `_input` gating**

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

- [x] **Step 7: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/main/wayland_room.gd && godot --headless --check-only --script scripts/player/player.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK on both, 42/42 pass.

- [x] **Step 8: Commit**

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

- [x] **Step 1: Add the `_lan` reference + setter in pause_menu.gd**

Add a member next to line 67 (`var _settings`):

```gdscript
var _lan: Node = null

## Réf. directe vers le lan_manager (retour de get_banned_ips/unban_ip dans
## la page admin). Injectée par wayland_room au setup LAN.
func set_lan_ref(lan: Node) -> void:
	_lan = lan
```

- [x] **Step 2: Implement `_show_banned()`**

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

- [x] **Step 3: Add the "Banned IPs" entry button in `_show_lan`**

In `_show_lan`, right after the `_lan_players_label` block (after line 1391), before the Disconnect button:

```gdscript
	var banned_btn := _make_btn("Banned IPs", Color(0.2, 0.18, 0.28, 0.9))
	banned_btn.pressed.connect(_show_banned)
	container.add_child(banned_btn)
```

- [x] **Step 4: Inject the reference in wayland_room**

In the LAN setup block (same area as Task 6 Step 1), add:

```gdscript
	pause_menu.set_lan_ref(lan)
```

- [x] **Step 5: Parse-check + full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/ui/pause_menu.gd && godot --headless --check-only --script scripts/main/wayland_room.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK on both, 42/42 pass.

- [x] **Step 6: Commit**

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