# Task 1 Report: Ban list core (lan_manager.gd)

## What was implemented

Added the persisted IP ban list core to `lan_manager.gd`:
- `const BAN_LIST_FILE := "user://lan_ban_list.json"` (after `RECONNECT_MAX_ATTEMPTS`)
- 3 static functions (testable headless): `is_ip_banned`, `load_ban_list_from`, `save_ban_list_to`
- 3 instance wrappers: `_load_ban_list`, `_save_ban_list`, `get_banned_ips`
- Section placed after `_remote_ip`, before `# ── Host ──`

Created `tests/test_lan_ban_list.gd` with 3 tests: `test_is_ip_banned`, `test_ban_list_roundtrip`, `test_ban_list_corrupt`.

## TDD Evidence

**RED (test file created, implementation absent):**
Running the test script directly (`godot --headless --script res://tests/test_lan_ban_list.gd`) produces 10 parse errors — all "Static function not found" for `is_ip_banned`, `load_ban_list_from`, `save_ban_list_to`. The runner skips the script entirely (can't load it), total stays at 37/37.

**GREEN (after implementation):**
```
  ✓ test_lan_ban_list.gd::test_is_ip_banned
  ✓ test_lan_ban_list.gd::test_ban_list_roundtrip
  ✓ test_lan_ban_list.gd::test_ban_list_corrupt
  RESULTS: 40 passed, 0 failed, 40 total
```
Note: `test_ban_list_corrupt` triggers an expected `push_error` from Godot's JSON parser (corrupt JSON) — this is correct behavior, not a test failure.

**Parse check:** `godot --headless --check-only --script scripts/network/lan_manager.gd` — clean, no errors.

## Files changed

- `Game/source/scripts/network/lan_manager.gd` — added const + 7 functions (~40 lines)
- `Game/source/tests/test_lan_ban_list.gd` — new, 43 lines

## Self-review findings

- All 7 functions/const from the brief present, signatures match exactly
- Names match brief exactly, no overbuilding
- French class doc comments intact
- Test file is verbatim from the plan
- Commit message matches the brief: `feat(lan): persisted IP ban list core with tests`
- Only the 2 specified files staged/committed (no `.uid`, no other files)

## Concerns

None. The `push_error` from Godot's JSON parser on corrupt input is expected and harmless — the function returns `[]` correctly.
