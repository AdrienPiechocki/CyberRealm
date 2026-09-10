## Task 6 — wayland_room + player.gd wiring, hotkey, gating, notify-send, kick overlay

**Status:** DONE

### Files modified

| File | Lines changed |
|------|--------------|
| `Game/source/scripts/main/wayland_room.gd` | +51 / -1 |
| `Game/source/scripts/player/player.gd` | +5 / -0 |

### What was implemented (wayland_room.gd)

| Block | Location (final) | Description |
|-------|-----------------|-------------|
| `@onready var players_menu` | line 22 (after `tutorial`) | Pointer to `PlayersMenu` node |
| `var _hud_notice` | line 69 (after `_menu_just_closed`) | Lazy-created Label for kick/ban overlay |
| Setup + signal connects | lines 476–480 (after `file_share.setup`) | `players_menu.setup()`, `visibility_changed` connect, `lan.message_received/kicked/banned` connects |
| Radial-menu guard extension | line 732 | `and not players_menu.visible` appended |
| Hotkey toggle block | lines 748–752 (after window_menu toggle) | SUPER+SHIFT+P toggle for players menu |
| Early-return extension | line 761 | `or players_menu.visible` appended |
| `_open_players_menu()` | lines 1007–1013 (after `_open_window_menu`) | Opens menu + releases interact/focus |
| `_on_menu_visibility_changed` extension | line 1320 | `and not players_menu.visible` appended |
| `_on_lan_message_received` | lines 1341–1345 | `notify-send` with sender + text |
| `_lan_flash` | lines 1347–1363 | Transient centered-top Label, 4-second fade |

### What was implemented (player.gd)

| Block | Location (final) | Description |
|-------|-----------------|-------------|
| visibility_changed connect | line 57 | `$PlayersMenuLayer/PlayersMenu.visibility_changed.connect(_on_menu_visibility_changed)` |
| Input early-return | lines 159–160 (after CaptureSelector) | `if $PlayersMenuLayer/PlayersMenu.visible: return` |
| Escape handler guard | lines 170–171 (after WindowMenu guard) | `if $PlayersMenuLayer/PlayersMenu.visible: return` |

### Parse-check output

```
# wayland_room.gd
Godot Engine v4.7.2.stable.arch_linux.ed1daf0bf (2026-08-17 01:18:38 UTC) - https://godotengine.org
(exit 0, no errors)

# player.gd
Godot Engine v4.7.2.stable.arch_linux.ed1daf0bf (2026-08-17 01:18:38 UTC) - https://godotengine.org
(exit 0, no errors)
```

### Suite output

```
  RESULTS: 42 passed, 0 failed, 42 total
```

One pre-existing "SCRIPT ERROR: Parse JSON failed" line from Task 1's corrupt-list test (expected noise).

### Self-review findings

- All 10 verbatim code blocks from the brief placed correctly, anchored on named blocks.
- Only the two target files modified; no collateral changes.
- French doc comments preserved; no unnecessary comments added.
- The `await` in `_lan_flash` and lambda callers for `kicked`/`banned` are correct per the brief's note.
- Existing unmodified gating sites (wayland_room lines 505, 891, 915, 1044; player.gd lines 75, 173) left untouched.
- No concerns.

### Commit

```
a73610f feat(ui): wire players menu hotkey, gating, notify-send and kick overlay
```
