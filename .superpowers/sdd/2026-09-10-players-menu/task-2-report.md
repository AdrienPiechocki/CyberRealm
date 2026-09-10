# Task 2 Report: Network actions — message / kick / ban RPCs + join-time ban check

**Status:** DONE

**Commit:** `0c39c19` — `feat(lan): message/kick/ban RPCs + persisted ban enforcement on join`

**Files changed:** `Game/source/scripts/network/lan_manager.gd` (+84 lines only; nothing else staged, `docs/superpowers/plans/` left untracked).

## What was implemented

1. **Three signals** added after `signal pin_changed(pin: String)` (top of file):
   - `message_received(sender_name: String, text: String)`
   - `kicked()`
   - `banned()`

2. **State flag** `var _kick_notified := false` added next to `var _session_closed_received := false` (in the Heartbeat/reconnexion block).

3. **New section `# ── Messages / kick / ban ──────────────────`** inserted right after the end of `_remove_player` (anchor: `_clear_remote_windows(peer_id)` / `_emit_players()`), containing:
   - `func send_message_to(peer_id: int, text: String) -> void` — strips/validates, uses `player_name`, sends via `_rpc_recv_message.rpc_id`.
   - `@rpc("any_peer", "reliable") func _rpc_recv_message(sender_name: String, text: String) -> void` — emits `message_received`.
   - `func kick_player(peer_id: int) -> void` — host-only guard, sends `_rpc_you_were_kicked.rpc_id` first, then local `_remove_player(peer_id)`, then `disconnect_peer`.
   - `func ban_player(peer_id: int) -> void` — host-only, resolves IP via `_remote_ip`, persists to ban list via `_load_ban_list`/`_append`/`_save_ban_list`, then `kick_player`, then `banned.emit()`.
   - `func unban_ip(ip: String) -> void` — erases IP from ban list and persists.
   - `@rpc("any_peer", "reliable") func _rpc_you_were_kicked() -> void` — sets `_kick_notified = true`, emits `kicked()`.

4. **Join-time ban check** at the very top of the `if is_host:` block of `_on_peer_connected`, BEFORE `_set_status("Player %d connected — waiting for PIN…")`: short-circuit disconnect of banned IPs via `is_ip_banned(_remote_ip(id), _load_ban_list())`, with status `"Banned IP rejected: %s"`, then `return`.

5. **Client-side kick fallback** at the top of `_on_peer_disconnected`, before the roster purge: `if not is_host and id == 1 and not _session_closed_received and not _kick_notified: kicked.emit()`.

All new code uses `@rpc("any_peer", "reliable")` annotation style, typed parameters/returns, French doc comments, and follows existing patterns.

## Parse-check

```
godot --headless --check-only --script scripts/network/lan_manager.gd
```
Output: clean (only the Godot version banner). No errors.

## Test suite

```
godot --headless --script res://tests/runner.gd
```
Results: **40 passed, 0 failed, 40 total** (including Task 1's `test_lan_ban_list.gd` 3 tests).

Note on output cleanliness: `test_ban_list_corrupt` intentionally feeds corrupted JSON to `load_ban_list_from`, which triggers one expected `ERROR: Parse JSON failed` stderr line from `JSON.parse_string`. This is pre-existing Task 1 behavior (not introduced or aggravated by this task) — the test itself passes.

## Self-review findings

- Completeness: all three signals present; `_kick_notified` flag present; all five methods + two `@rpc` receivers present with signatures matching the brief; ban check is the first statement in `_on_peer_connected`'s `if is_host:` block; kick fallback is the first statement of `_on_peer_disconnected`.
- `_remove_player` carries an `@rpc("any_peer", "reliable", "call_local")` annotation; calling it directly inside `kick_player` is a plain local invocation (RPC only propagates through `MultiplayerAPI.rpc`/`rpc_id`), so no spurious broadcast or recursion — safe as written.
- No overbuilding: verbatim code from the brief, no extra helpers or refactors.
- Only the single target file staged; commit message matches the brief exactly.

## Concerns

- None blocking. The one `ERROR: Parse JSON failed` line during the suite is intentional test output from Task 1's corruption test, matching baseline.