## Task 4 Report: PlayersMenu scene + core script + input action

### What was implemented

**Files modified/created:**

1. **`Game/source/scripts/ui/players_menu.gd`** (NEW) — 305 lines. Core script extending `GameMenu` with:
   - `setup()`, `show_menu()`, `hide_menu()`, `toggle_menu()`, `menu_closed` signal
   - Tab management (`_refresh_tabs`, `_on_tab_pressed`, `_peer_present`, `_empty_state`)
   - 3D avatar preview (`_update_preview`, `_avatar_scene`, `_clear_preview`) with slow rotation in `_process`
   - `_input` handling (Escape, Start/B buttons) calling `super(event)` for GameMenu JoypadMotion
   - `_build_action_buttons()` and `_update_actions()` stubbed with `pass` (Task 5)
   - French doc comments throughout

2. **`Game/source/scenes/player.tscn`** (MODIFIED) — +61 lines:
   - `[ext_resource]` for `players_menu.gd` added after line 10 (`id="10_players_menu"`)
   - Full `PlayersMenuLayer` branch (10 nodes) inserted after WindowMenu subtree, before CaptureSelectorLayer
   - Uses `unique_id=4200000001`..`4200000010` — no collisions with existing IDs (existing range: 1446411886–390218742)
   - 3-space node indentation convention preserved throughout

3. **`Game/source/project.godot`** (MODIFIED) — +5 lines:
   - `players_menu` input action added at end of `[input]` section, after `radial_menu` block
   - Physical keycode 77 (KEY_P), `shift_pressed=true`, `meta_pressed=true` → SUPER+SHIFT+P
   - `pin_window` and `window_menu` blocks untouched

### Parse-check output

```
$ godot --headless --check-only --script scripts/ui/players_menu.gd
Godot Engine v4.7.2.stable.arch_linux.ed1daf0bf (2026-08-17 01:18:38 UTC)
```
No errors. Clean parse.

### Test suite output

```
RESULTS: 42 passed, 0 failed, 42 total
```
Pre-existing "SCRIPT ERROR: Parse JSON failed" line from Task 1's corrupt-list test is expected noise, out of scope.

### Conventions matched

- 3-space indentation in `.tscn` node declarations (consistent with existing nodes)
- `ExtResource("10_players_menu")` naming follows the `id="10_players_menu"` ext_resource convention
- `unique_id` values 4200000001–4200000010: no collisions (existing IDs are 1.4B–3.9B range)
- French doc comments on class and methods (matching codebase convention)
- `super(delta)` in `_process` and `super(event)` in `_input` (matching `window_menu.gd` pattern)

### Self-review findings

- Script matches brief verbatim (character-by-character match)
- tscn ext_resource + full node subtree inserted in correct position (after WindowMenu, before CaptureSelectorLayer)
- project.godot action serialized exactly as brief specifies
- `_build_action_buttons()` and `_update_actions()` are `pass` stubs as specified
- pin_window untouched ✓
- window_menu untouched ✓

### Concerns

None. All three files match the brief exactly. No unique_id collisions found.

---

### Fix: R7 — Signal connection leak in `setup()`

**What changed:** Added an `is_connected` guard in `setup()` (`players_menu.gd:30-31`) so `_lan.players_changed.connect(_refresh_tabs)` is only called if the signal is not already connected. This prevents duplicate connections if `setup()` is called more than once.

**Before:**
```gdscript
if _lan != null and _lan.has_signal("players_changed"):
    _lan.players_changed.connect(_refresh_tabs)
```

**After:**
```gdscript
if _lan != null and _lan.has_signal("players_changed"):
    if not _lan.players_changed.is_connected(_refresh_tabs):
        _lan.players_changed.connect(_refresh_tabs)
```

**Verification:**
```
$ godot --headless --check-only --script scripts/ui/players_menu.gd
Godot Engine v4.7.2.stable.arch_linux.ed1daf0bf (2026-08-17 01:18:38 UTC)

$ godot --headless --script res://tests/runner.gd
RESULTS: 42 passed, 0 failed, 42 total
```

Commit: `72b209f` — `fix(ui): guard players_menu players_changed connection against duplicate setup`
