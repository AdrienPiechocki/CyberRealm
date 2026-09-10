### Task 3: file_share — `send_file_to_peer` + shared file-size helper + tests

**Files:**
- Modify: `Game/source/scripts/network/file_share_manager.gd` (helper after `downloads_dir()` ~line 27, `send_file_to_peer` right after `on_files_dropped` ~line 417, refactor the size loop in `on_files_dropped`)
- Test: `Game/source/tests/test_file_share.gd` (new)

**Interfaces:**
- Consumes: existing `_can_start_transfer()`, `_pending_offers`, `_next_offer_id`, `_offer_files.rpc_id`, `_show_progress`, `_peer_name(peer_id)`, `ensure_local_keypair()`, `lan.is_session_active()`, `CHANNEL` consts (all internal to the file)
- Produces (consumed by Task 5):
  - `static func readable_file_size(path: String) -> int`
  - `func send_file_to_peer(peer_id: int, path: String) -> bool`

- [ ] **Step 1: Write the failing test**

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

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --script res://tests/runner.gd
```
Expected: 2 new FAILs (`readable_file_size` undefined), total 42.

- [ ] **Step 3: Add the helper and refactor `on_files_dropped`**

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

- [ ] **Step 4: Add `send_file_to_peer`**

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

- [ ] **Step 5: Run tests to verify they pass + parse-check**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/network/file_share_manager.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 42/42 pass.

- [ ] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/file_share_manager.gd Game/source/tests/test_file_share.gd && git commit -m "feat(fileshare): programmatic send_file_to_peer + shared size helper"
```

---

