# Task 5 Report — PlayersMenu actions (message, send-file zenity poll, kick/ban confirm)

## Status

DONE_WITH_CONCERNS (one required, documented deviation from the brief's literal code; see below).

## What was implemented

All changes are inside `Game/source/scripts/ui/players_menu.gd`.

**New member vars** (added after `var _preview_avatar`):
- `_status_label`, `_send_msg_btn`, `_send_file_btn`, `_kick_btn`, `_ban_btn`
- `_msg_row`, `_msg_edit`, `_confirm_row`, `_confirm_label`, `_confirm_confirm_btn`, `_confirm_cancel_btn`, `_confirm_kind`
- `_picker_running`, `_picker_peer`, `_picker_deadline` (zenity picker state)

**New methods:**
- `_pick_buf_path(suffix)` — XDG_RUNTIME_DIR (fallback temp dir) buffer path helper
- `_build_std_button(label, handler)` — styled std button (window_menu-style StyleBoxFlat), wired via `Callable(self, handler)`
- `_poll_file_picker()` — polls `.done` marker; reads file path; sends via `_file_share.send_file_to_peer`; handles cancel / 60 s timeout / target-left cases
- `_on_send_message_pressed()`, `_on_send_message()`, `_on_kick_pressed()`, `_on_ban_pressed()`, `_show_confirm(kind)`, `_on_confirm()`, `_player_display_name()`, `_set_status(text)`, `_on_file_pick_pressed()`

**Stubs replaced:**
- `_build_action_buttons()` (was `pass`, line 60) → builds 4 action buttons + status label + message row + confirm row
- `_update_actions()` (was `pass`, line 204) → enable/disable/visibility logic per selected peer, host-only kick/ban, picker lock

**`_process` extension:** same signature, calls `super(delta)`, keeps avatar rotation, then `_poll_file_picker()` when `_picker_running`. Verified exactly ONE `_process` in the file (line 180).

## Deviation from brief (must note)

The brief states the ternary `var ok := _file_share.send_file_to_peer(...) if _file_share != null else false` is valid Godot 4 GDScript. In this repo (Godot 4.7.2) it fails to parse:

```
SCRIPT ERROR: Parse Error: Cannot infer the type of "ok" variable because the value doesn't have a set type.
```

Cause: `_file_share` is typed as bare `Node` (file_share_manager.gd has no `class_name`, so its method return type is not statically resolvable → Variant). Mixing a Variant operand with the `bool` literal `false` in a `:=` ternary is a type-inference error in GDScript.

Minimal behavior-preserving fix applied (only change from the brief's line):
```gdscript
var ok: bool = _file_share.send_file_to_peer(_picker_peer, path) if _file_share != null else false
```
Logic, branches, and runtime behavior are identical. No other file modified.

## Verification

Parse check (`godot --headless --check-only --script scripts/ui/players_menu.gd`, from Game/source):
- OK, no errors.

Full suite (`godot --headless --script res://tests/runner.gd`, from Game/source):
- RESULTS: 42 passed, 0 failed, 42 total.
- The pre-existing expected noise `SCRIPT ERROR: Parse JSON failed` (Task 1's corrupt ban-list test) appears as expected; all tests pass.

## Files changed

- `Game/source/scripts/ui/players_menu.gd` (+224 / −5), committed only.

## Commit

- `427a814` — `feat(ui): players menu actions (message, file picker, kick/ban confirm)`
- Only `Game/source/scripts/ui/players_menu.gd` staged; `docs/superpowers/plans/` left untracked; no amend.

## Self-review findings

- Completeness: all brief members/handlers present; both stubs now real implementations; exactly one `_process` doing rotation + poll; message button wired via `Callable(self, handler)`, msg "Send" via `pressed.connect(_on_send_message)`, confirm via `pressed.connect(_on_confirm)` per brief.
- Quality: French doc comments preserved/added (`_pick_buf_path`, "Drop le peer ciblé…" note); no overbuilding; styling reuses window_menu button pattern referenced in the brief.
- One concern: the type-inference deviation above (unavoidable under the "don't modify other files" constraint).

## Concerns

- Only the documented `:=` → `: bool` deviation. Everything else matches the brief verbatim.