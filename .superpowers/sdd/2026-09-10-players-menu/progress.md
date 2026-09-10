# SDD ledger — plan: docs/superpowers/plans/2026-09-10-players-menu.md

## Setup
- Branch: `players-menu` (worktree `.worktrees/players-menu`, repo root `/home/adrien/Projets/CyberRealm`)
- BASE before Task 1: `8c927b9` (chore: gitignore worktrees directory)
- Spec: `docs/superpowers/specs/2026-09-10-players-menu-design.md` (committed e8ee0b2)
- Baseline: 37/37 tests pass in worktree (after copying gitignored `.godot` cache and `Game/source/bin/*.so` prereqs)
- Platform note: no subagent model selection available in opencode Task tool (no `model` param); all subagents dispatch as `general`. Scoping by prompt, not model tier.
- Path note: plan commands hardcode `/home/adrien/Projets/CyberRealm`; all commands must run in the worktree root `/home/adrien/Projets/CyberRealm/.worktrees/players-menu`.

## Global Constraints (verbatim from plan, bind all tasks)
- Godot 4.7.2, GDScript with typed parameters/returns; class-level doc comments in French.
- All menus extend `GameMenu`; fill `panel` style identical to `window_menu` (StyleBoxFlat dark blue, 900x600 centered).
- Hotkey: new input action `players_menu` = InputEventKey `physical_keycode=77` (KEY_P) with `meta_pressed=true`, `shift_pressed=true`. `pin_window` (SUPER+P) MUST NOT be touched.
- Local player always excluded from player tabs (only remote players).
- Kick/Ban host-only (`lan.is_host == true`); host self-kick impossible (self excluded).
- Ban list file: `user://lan_ban_list.json` (JSON `Array` of IP strings), loaded/saved on each operation.
- Networking RPC annotation style: `@rpc("any_peer", "reliable")`.
- No new third-party libraries; headless verification only:
  - Parse: `godot --headless --check-only --script <relative-path>` (run from `Game/source`)
  - Tests: `godot --headless --script res://tests/runner.gd` (run from `Game/source`)

## Pre-flight scan

Pairs sharing a file/interface, what each produces vs consumes, finding. (Then a ruling on each finding.)

| Pair | Produce vs Consume | Finding |
|---|---|---|
| T1→T2 (lan_manager.gd) | T1 adds `BAN_LIST_FILE` (after line ~63), ban section after `_remote_ip` (line 591), instance wrappers. T2 consumes `_load_ban_list`/`_save_ban_list`/`is_ip_banned`/`_remote_ip`; adds section after `_remove_player` (~1043), `_kick_notified` near `_session_closed_received`, join check top of `_on_peer_connected` (~1046), kick fallback top of `_on_peer_disconnected` (1620) | Compatible; line numbers shift after T1's ~40-line insert — implementers anchor on content |
| T1→T7 (pause_menu) | T1 `get_banned_ips()` consumed by T7 `_show_banned` | Compatible. Ruling R1 on return type |
| T2→T4/5/6/7 | T2 produces `message_received`/`kicked`/`banned`, `send_message_to`, `kick_player`, `ban_player`, `unban_ip`. T5 consumes send/kick/ban + `is_host`; T6 consumes the three signals; T7 consumes `get_banned_ips`/`unban_ip` | Compatible |
| T3→T5 | T3 `send_file_to_peer(peer_id, path) -> bool` + `readable_file_size`; T5 consumes both + `_compositor.launch_app` | Compatible |
| T4→T5 (players_menu.gd) | T4 creates full script with `pass` stubs `_build_action_buttons`/`_update_actions` and a base `_process`; T5 replaces the two stubs, adds members, extends `_process` with pic-poll | Compatible — T5 explicitly overrides the T4 `_process` with same signature |
| T4→T6 | T4 adds `PlayersMenuLayer/PlayersMenu` branch + input action + script; T6 references `$Level/Player/PlayersMenuLayer/PlayersMenu` and action `players_menu` | Compatible |
| T6→T7 (wayland_room.gd) | T6 adds `players_menu.setup(...)` + signal connects in LAN setup block; T7 adds `pause_menu.set_lan_ref(lan)` in same block | Compatible, additive |

### Per-task self-consistency

| Task | Checks | Finding |
|---|---|---|
| T1 | Test vs impl: `is_ip_banned(ip,banned)`, `load_ban_list_from`, `save_ban_list_to` signatures match; test count 37→40; commit names both files | Clean |
| T2 | `_kick_notified` mentioned at "line ~127" (state) and "next to `_session_closed_received` (~51)" (Step 1) — stale anchor. Interfaces cite `__set_status` (actual: `_set_status`) | Ruling R2, R4 |
| T3 | Test vs impl: `readable_file_size` static matches; refactor size loop; `send_file_to_peer` bool; 40→42 | Clean |
| T4 | Staff complete scene; script fully given; stub actions callable in `_ready`; `super(delta)`/`super(event)` presume GameMenu base methods (window_menu pattern) | Clean (GameMenu base to confirm at impl) |
| T5 | Replaces stubs; all members/helpers declared; zenity poll paths symmetric; ternary expr valid Godot 4 | Clean |
| T6 | Hotkey guard block vs gating at 724/746; `_on_menu_visibility_changed` reuse; `_lan_flash` await-in-lambda OK | Clean |
| T7 | `_show_banned` + `_on_unban(ip)` bind; `_current_view` value list updated; button in `_show_lan` after player label | Clean |

## Rulings
- R1: `get_banned_ips()` returns `Array` (plan Task 1) not `Array[String]` (spec §6). JSON round-trip of a plain `Array` file is untyped in Godot; the typed spec signature would force a cast on load. Plan's untyped return is the operative contract; T7 iterates `for ip: String in list` which binds at runtime. Cost if wrong: pause_menu list typed-iteration is a cosmetic nicety; untyped iteration still works.
- R2: `_kick_notified` is placed next to `_session_closed_received` (~line 51 pre-T1) per Task 2 Step 1; the "line 127" anchor in the interfaces list is stale (it was the old `_session_closed_received` line). Cost if wrong: none (placement of a bool local to intent).
- R3: Line numbers cited in plan steps are anchors against the pre-T1 file and shift as earlier tasks insert code. Implementers anchor on the named code block/comment text, not raw line numbers. Cost if wrong: misplaced insertions → caught by parse-check + review.
- R4: Task 2 interfaces' `__set_status` is a typo for the existing `_set_status` (line 3424). No rename performed. Cost if wrong: a broken method reference, caught at parse.
- R5 (Task 1 review): Reviewer's Important finding "load_ban_list_from missing -> Array return type" is a FALSE POSITIVE — verified lan_manager.gd:607 `static func load_ban_list_from(path: String) -> Array:` present, matching brief verbatim. Dismissed with evidence. Cost if wrong: none.

## Task progress

Task 1: complete (commits 8c927b9..2b4ba0a, review clean)
- Task 1: minor (deferred): `test_ban_list_roundtrip` only asserts `loaded[0]` (size==2 asserted meanwhile; adequate coverage).
- Task 1: minor (deferred): `test_ban_list_corrupt` deliberately feeds invalid JSON, so each suite run prints one expected SCRIPT ERROR/push_error from Godot's JSON parser — runner output is not 100% pristine. Options at final review: silence via captured stderr or accept.

Task 2: complete (commits 2b4ba0a..0c39c19, review clean)
- Task 2: minor (deferred): ban check calls `_remote_ip(id)` twice (lan_manager.gd:1145,1147); verbatim from brief, could hoist to a local later.
- ⚠️ resolved: `_rpc_you_were_kicked` RPC-vs-disconnect race and kick-fallback guard correctness are runtime behaviors not exercisable headless; covered by the plan's manual 2-machine verification (final verification checklist). Not gaps.
- R6 (Task 3): TDD RED phase differed from the plan's expected "2 new FAILs, total 42" — the test file statically calls `FileShare.readable_file_size`, which GDScript resolves at parse time, so the whole test script fails to load and the suite stays at 40/40 during RED. Natural artifact, not a defect; final state is 42/42 as specified. Cost if wrong: none (suite count still lands exactly as planned).

Task 3: complete (commits 0c39c19..9c70f22, review clean)
- Task 3: minor (deferred): `on_files_dropped` refactor dropped the old `error_string(FileAccess.get_open_error())` debug detail (file_share_manager.gd:68, now prints only the path); spec-compliant per brief, was useful for diagnosing permission-vs-missing errors. Option at final review: re-add error detail behind `_debug`.

Task 4: fix round 1/5 pending
- Task 4: minor (deferred): `_on_tab_pressed` allocates a fresh StyleBoxFlat per child per click (players_menu.gd:185-199) — could cache styles.
- Task 4: minor (deferred): redundant `get_remote_players()` call between `_update_preview` and `_avatar_scene` (players_menu.gd:213,237).
- Task 4: minor (deferred): no `_exit_tree()` cleanup for `_preview_avatar`/`menu_closed`.
- Task 4: minor (deferred): `_apply_styling` re-applies anchors/size already set in player.tscn (harmless redundancy).
- ⚠️ resolved: consume-side lan_manager APIs (`get_players_roster`, `get_remote_players`, `is_session_active`, `players_changed`) verified present in Tasks 1-2 commits; wiring in Task 6.
- R7 (Task 4): reviewer's Important finding "signal connection leak in setup()" is real — `setup()` connects `players_changed` without a guard; wayland_room can re-create LAN sessions (host start/stop/restart) making a repeat setup plausible. Deviating from the plan's verbatim one-liner to guard the connect (connect once). Cost if wrong: negligible guard; behavior unchanged for the single-setup path.
- Task 4: fix round 1/5 (1 addressed, 0 open; commits 196afa9..72b209f)

Task 4: complete (commits 9c70f22..72b209f, review clean)
- R8 (Task 5): the brief's `var ok := _file_share.send_file_to_peer(...) if _file_share != null else false` fails GDScript parse in Godot 4.7.2 ("Cannot infer the type of 'ok'") because `_file_share` is an untyped `Node`; implementer switched to `var ok: bool =` (behavior-identical). Cost if wrong: none.

Task 5: complete (commits 72b209f..427a814, review clean; 1 parked as R9)
- Task 5: minor (deferred): `_on_confirm` does not guard `_confirm_kind` against unexpected values (anything ≠ "kick" falls to ban_player); only two callers (kick/ban), currently unreachable. Option at final review: explicit `match`.
- R9 (Task 5): reviewer's Important finding — the zenity shell command hardcodes `$XDG_RUNTIME_DIR/cyberrealm-filepick` while GDScript `_pick_buf_path("")` falls back to temp dir if XDG_RUNTIME_DIR empty. Plan/spec mandated the exact shell string. Ruled: PARKED. Wayland sessions REQUIRE XDG_RUNTIME_DIR (compositor-launched zenity runs inside the session), so the paths cannot diverge in the runtime environment; fixing would mean injecting the buffer path into the sh -c string (quoting/injection risk) or duplicating fallback logic in shell. Manual verification in the plan exercises the real flow. Cost if wrong: file-pick flow breaks only where XDG_RUNTIME_DIR is unset (the compositor game cannot run there anyway).
- ⚠️ resolved: `_peer_present` exists (defined in Task 4's players_menu.gd); not a gap.

Task 6: complete (commits 427a814..a73610f, review clean)
- Task 6: minor (deferred): player.gd:127-131 `_on_menu_visibility_changed` `_menu_just_closed` latch lacks `and not $PlayersMenuLayer/PlayersMenu.visible`; benign (fires on menu open → one-frame jump suppression; fires correctly on close), inconsistent with wayland_room.gd:1321 which was updated. Plan deliberately scoped OUT player.gd's latch. Option at final review: add the term.

Task 7: implementer complete (commit 3b56a80, parse OK both files, 42/42, no deviations reported)
- NOTE: task-brief script failed for Task 7 (`task 7 not found`): the plan file's fence-parity confuses the awk `infence` toggle around the Task 6/7 boundary, so it mis-reads the `### Task 7` heading as inside an open fence. Markdown renderer (python `markdown`) confirms Task 7 IS a valid heading; every ``` line has a blank line after it; all visible blocks pair correctly. Controllers: brief was written by hand from plan lines 1255..EOF. Not modifying the plan doc (still last task; cosmetic).

Task 7: review APPROVED (3b56a80, no Critical/Important). Minors (all acceptable/deferred): (a) `_make_back_btn` → `_show_main` means Back from banned goes to main, consistent with all views, brief silent; (b) `_lan` typed `Node` matches codebase convention; (c) `for ip: String in list` over untyped Array fine.

Final whole-branch review (8c927b9..3b56a80): stripped — APPROVED with 2 Important to fix:
- Important #1: players_menu.gd (~321) stale `_confirm_kind`/confirm label + msg draft across tab switches (host could kick/ban the NEW selection under the old label). Real (verified: `_update_actions` resets only when `!has_peer`).
- Important #2: players_menu.gd (~419) zenity `&&` — cancel exits non-zero, `.done` never written, "File selection cancelled" dead code, cancel degraded to 60 s timeout. Real (verified).
- All 9 triaged deferred items ruled DEFER (incl. R9 parked ruling confirmed standing; player.gd latch confirmed benign — latch self-clears each physics tick at player.gd:117; muted jump only on the SUPER+SHIFT+P frame).
Fix wave: ONE dispatch → commit bfef283 `fix(ui): clear stale confirm/message state on tab switch and write file-pick done marker on zenity cancel` (players_menu.gd only). Parse OK, 42/42 confirmed.
Scoped re-review (3b56a80..bfef283): both ADDRESSED, no new breakage. Out-of-scope minor: `_msg_edit.text` draft persists across tab switch (cosmetic, ledgered, DEFER).
- Final review clean.