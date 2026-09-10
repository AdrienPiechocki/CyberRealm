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

- [ ] **Step 1: Write the failing test**

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

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: 3 new FAILs (`is_ip_banned` not found / etc.), total rises to 40.

- [ ] **Step 3: Implement in lan_manager.gd**

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

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: all pass (40/40, 3 new).

- [ ] **Step 5: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/lan_manager.gd Game/source/tests/test_lan_ban_list.gd && git commit -m "feat(lan): persisted IP ban list core with tests"
```

---

