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

- [ ] **Step 1: Add the three signals**

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

- [ ] **Step 2: Add the message + kick/ban methods**

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

- [ ] **Step 3: Add the join-time ban check in `_on_peer_connected`**

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

- [ ] **Step 4: Add the client-side kick fallback in `_on_peer_disconnected`**

Read the current body of `_on_peer_disconnected` (line 1620). Add this block near the TOP of the function (before the existing roster purge), so a client that was cut without receiving the RPC flag still shows the notice:

```gdscript
	# Kick silencieux (coupure du serveur sans _rpc_you_were_kicked reçu) :
	# notifier l'UI. L'ID 1 est l'hôte ; un shutdown propre passe par
	# session_closed (flag posé) et ne doit PAS déclencher l'affiche.
	if not is_host and id == 1 and not _session_closed_received and not _kick_notified:
		kicked.emit()
```

- [ ] **Step 5: Parse-check + run full suite**

```bash
cd /home/adrien/Projets/CyberRealm/Game/source && godot --headless --check-only --script scripts/network/lan_manager.gd && godot --headless --script res://tests/runner.gd
```
Expected: parse OK, 40/40 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /home/adrien/Projets/CyberRealm && git add Game/source/scripts/network/lan_manager.gd && git commit -m "feat(lan): message/kick/ban RPCs + persisted ban enforcement on join"
```

---

