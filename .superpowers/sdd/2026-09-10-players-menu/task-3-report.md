# Task 3 Report: file_share — `send_file_to_peer` + shared `readable_file_size` helper + tests

## Status: DONE

## What I implemented

In `Game/source/scripts/network/file_share_manager.gd` (branch `players-menu`, worktree `.worktrees/players-menu`):

1. **`static func readable_file_size(path: String) -> int`** — added right after `downloads_dir()` (line ~23). Opens the file in READ mode, returns `get_length()`, `0` if unreadable. French doc comment. Shared size helper for both drops and programmatic send.
2. **Refactored `on_files_dropped`** — the per-path file loop now calls `readable_file_size(p)` instead of inline `FileAccess.open`/`get_length()`. No duplicated size-fetch code path remains (checked the diff: the old `open() failed` branch is gone, replaced by the brief's `unreadable:` branch).
3. **`func send_file_to_peer(peer_id: int, path: String) -> bool`** — added right after `on_files_dropped`. Guards: peer_id validity/self, `lan`/`is_session_active`/`ensure_local_keypair`, non-zero readable size, `_can_start_transfer`. Then reserves `_next_offer_id`, builds `_pending_offers[oid]` with `{peer, files, names, total, msec}`, calls `_show_progress("Offer to %s — waiting…")` and `_offer_files.rpc_id(...)`, returns `true`. Reuses only existing internal members — no new plumbing.

## TDD evidence

**RED** — `godot --headless --script res://tests/runner.gd` after creating `tests/test_file_share.gd` but before implementing:

```
SCRIPT ERROR: Parse Error: Static function "readable_file_size()" not found in base "res://scripts/network/file_share_manager.gd".
          at: GDScript::reload (res://tests/test_file_share.gd:15)
SCRIPT ERROR: Parse Error: Static function "readable_file_size()" not found in base "res://scripts/network/file_share_manager.gd".
          at: GDScript::reload (res://tests/test_file_share.gd:22)
ERROR: Failed to load script "res://tests/test_file_share.gd" with error "Parse error".
  RESULTS: 40 passed, 0 failed, 40 total
```

The two new tests cannot load until the static function exists, so the runner reports 40/40 with the parse errors — the expected failure mode when the tested symbol is undefined.

**GREEN** — after implementing:

```
true
  ✓ test_file_share.gd::test_readable_file_size
true
  ✓ test_file_share.gd::test_readable_file_size_missing
═══════════════════════════════════════════════
  RESULTS: 42 passed, 0 failed, 42 total
═══════════════════════════════════════════════
```

Both new tests pass; total 42/42. The one pre-existing expected `Parse JSON failed` line from Task 1's corrupt-ban-list test (`test_ban_list_corrupt`) appears before the pass line — out of scope.

## Parse check

`godot --headless --check-only --script scripts/network/file_share_manager.gd` — exit 0, no output. OK.

## Files changed

- Modified: `Game/source/scripts/network/file_share_manager.gd` (+33 −4: helper, refactor, new method; 64 insertions/4 deletions total across commit)
- New: `Game/source/tests/test_file_share.gd` (18 lines, matches brief verbatim, style of `test_lan_protocol.gd` / `test_lan_ban_list.gd`)

## Commit

`9c70f22` — `feat(fileshare): programmatic send_file_to_peer + shared size helper`
- Staged exactly the two files above. `docs/superpowers/plans/` left untracked and untouched. No earlier commits amended.

## Self-review findings

- Completeness: exact brief signatures for both `readable_file_size` (static) and `send_file_to_peer` (instance, returns bool); `on_files_dropped` reuses the helper (verified via `git diff`, no leftover inline size fetch).
- Quality: French doc comments on all new code; no overbuilding beyond brief; existing patterns followed (offer-flow mirrors `on_files_dropped`).
- YAGNI: no new internal members, no UI changes, no RPC changes.

## Concerns

None. Note the RED output differs from the brief's guess of "2 FAILs, total 42": because the missing static symbol is caught at GDScript parse/load time, the runner drops the whole script and stays at 40/40 instead of counting 42 with 2 failing. This is a runner-parse characteristic of static-member tests, not a defect; it is the natural RED for this task and both tests are green after implementation.