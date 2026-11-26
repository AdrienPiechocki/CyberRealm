# CyberRealm

A game where your desktop lives inside a 3D virtual world.

CyberRealm embeds a **complete Wayland compositor inside a Godot 4 game**. Every
window is a real Wayland surface rendered as a textured 3D quad that floats in a
room you walk around in — with a first-person camera, raycast interaction,
drag-and-drop, and even a fullscreen "focus" mode. Your Linux desktop's apps
(KDE/Plasma, GTK, Firefox, terminals, games…) run unmodified inside the game
world. Add **LAN multiplayer**: friends join the same room — each still on their
own desktop — and you can share windows, audio and custom levels with them.

Built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.19 and
Godot 4.7, with a GDExtension (C++) that instantiates the compositor as a native
Godot node and streams every surface into the engine through a **zero-copy
Vulkan DMA-BUF import**.

## Demo

Watch it in action: https://www.youtube.com/watch?v=6JxNVUvpcjI

## Features

- **A real compositor, in-game** — a headless wlroots backend runs inside the
  game. Windows are fully functional Wayland surfaces: keyboard, pointer,
  pointer constraints, primary selection and data drag-and-drop are forwarded
  between the game and the apps.
- **3D windows** — each mapped window becomes a raycastable quad in the scene.
  Grab (`SUPER+G`), move, resize from any edge, or point and click into it.
- **Focus mode** (`SUPER+F`) — pull any window to the front as a fullscreen 2D overlay
  for real work; press the same key again to release it back into the 3D world.
- **Picture-in-picture** (`SUPER+P`) — pin windows as small overlays that stay on top
  while you keep interacting with the world.
- **Layer surfaces** — waybar, rofi and friends are rendered as screen-anchored
  2D overlays inside the 3D view, with proper keyboard-interactive focus
  (a modifier key hands the pointer to the overlay).
- **X11 support** — X applications run through
  [xwayland-satellite](https://gitlab.freedesktop.org/xwayland-satellite/xwayland-satellite),
  forwarded as XWayland surfaces.
- **Context-sensitive radial menu** (`B` on gamepad) — a ring-style radial menu
  with emoji icons that adapts to context: FPS mode shows window menu / mouse
  mode / keyboard mode / custom binds; aiming at a window
  shows grab / focus / hide / kill / pin / share; in focus mode shows exit focus /
  kill. Select with the left stick, confirm with `A`.
- **Virtual keyboard** — an on-screen keyboard opened from the radial menu
  (VIRTUAL KBD). Supports AZERTY (FR), QWERTY (US), and QWERTZ (DE) layouts,
  auto-detected from the pause menu settings. D-PAD navigates spatially between
  keys with warp-around, `A` presses the focused key, mouse clicks also work.
  Shift / Ctrl / Alt are toggles (press once to lock, again to unlock). Key
  events are forwarded to the compositor via `forward_keyboard_key()`.
- **Custom binds radial** — the radial menu's BINDS action opens a sub-menu
  listing all custom key binds, each showing its key combo and target command.
  Selecting one launches the command via the compositor.
- **Sharp windows up close** (pause menu → General → *Window sharpness*, default
  *up to ×1.5*) — a window you look at from near gets a higher scale through
  `wp_fractional_scale_v1` (×1.25, ×1.5 or ×2): the app renders more pixels for
  the same size, so text stays crisp. Decided 4×/s from the window's height on
  screen, applied after 1 s of stability; back to ×1 when hidden, pinned, shown
  by focus mode (already pixel-exact) or under GPU pressure. X11 apps
  (xwayland-satellite) stay at ×1.
- **Spatial window sound** (pause menu → General → *Window sound*) — in
  *Spatial* mode the sound of each app comes from its window in the room (3D,
  fading out with distance); in focus mode the focused window plays at full
  volume, a hidden window is quieter, a pinned one plays in 2D, and a program
  without a window (a `paplay` in a terminal) sounds from its parent's window.
  How: apps launched by the game get `PULSE_SINK` and `PIPEWIRE_NODE` set to
  `cyberrealm-spatial` (PulseAudio and native PipeWire apps such as mpv); the game
  creates that silent output only in Spatial mode (tied to its PipeWire
  connection, so it vanishes if the game crashes), apps switch to it by
  themselves and the game replays their sound. Only apps actually linked to it
  are replayed, so nothing is ever heard twice; desktop apps are never touched
  and nothing is stored by WirePlumber; recording streams keep the default
  microphone. Limits: ALSA-only or JACK apps and apps started before this
  version keep playing directly.
- **Session restore** — the apps still open when you quit the game come back
  by themselves at the next launch, each window at its place (position,
  orientation, the size you gave it, hidden / pinned / `force_game` state).
  Apps are relaunched with their command line and working directory (Flatpak
  apps through `flatpak run <id>`), once per process: Firefox with two windows
  is started once and reopens its own windows. Terminals (Konsole, kitty,
  foot, Alacritty…) are reopened window by window with the program that was
  running in the foreground (`cava`, `vim`…) in its directory; the shell takes
  over when it exits. Only those windows (and those of the startup apps) get
  their place back, for 90 s after launch: a window you open yourself appears
  in front of you as usual, and places of older sessions are forgotten.
  When you quit, every window is first asked to close, as if you clicked its
  close button, then apps still running get SIGTERM (5 s each step) — so they
  save their own state: Firefox offers to restore its tabs (History → *Restore
  previous session*, or automatically with *Open previous windows and tabs*).
  Not restored: apps closed during the game, dialogs, the polkit agent, and
  terminal tabs beyond the first one of each window.
  Stored in `user://window_layouts.json`; per level, inactive on a level
  received from a LAN host (apps are still relaunched). One switch in the
  pause menu (General → *Restore the previous session (apps and window
  positions)*).
- **Taskbars** — implements `zwlr_foreign_toplevel_management_v1`, so a taskbar
  launched inside the game (waybar's `wlr/taskbar` module, `lswt`…) lists the
  windows and drives them: clicking a window un-hides it, gives it the keyboard
  and flashes it so you can find it in the room (or brings it into focus mode
  when focus mode is open); minimize hides it, fullscreen/maximize opens it in
  focus mode, close closes it. The taskbar sees each window as minimized while
  it is hidden and fullscreen while it is in focus mode.
- **Apps that capture shortcuts** — implements
  `zwp_keyboard_shortcuts_inhibit_v1`: a VM viewer, a remote-desktop client or
  a game streaming client can receive `Super`, `Alt+Tab`… while it is the
  window in **focus mode** (never in the 3D view, where the game needs its
  keys). A banner tells you when it happens; `SUPER+SHIFT+Esc` (remappable,
  *release_shortcuts*) takes the shortcuts back until you leave that window.
  Disable it in the pause menu (General → *Let apps capture shortcuts in focus
  mode*).
- **Cursor shapes** — implements `wp_cursor_shape_v1`: apps that name their
  cursor (GTK 4, Qt ≥ 6.6, kitty…) instead of sending an image get the
  matching cursor from your theme, in focus mode and on remote views alike.
- **Global shortcuts** — implements the `org.freedesktop.portal.GlobalShortcuts`
  portal, so any app can register a key that works whatever window has focus
  (e.g. the Ludodex in-game overlay on `Shift+Tab`). The game sees every key
  first: a recognised shortcut key is consumed (the focused window, focus mode
  and custom binds never see it) and the app gets the portal's `Activated` signal.
  The protocol part is `compositors/portal-shortcuts/cyberrealm-portal-shortcuts`
  (Python, needs PyGObject), started with the portals on the game's private bus;
  `global_shortcuts.gd` is the keyboard half. Requested triggers are granted as
  asked; override or disable one in `~/.config/cyberrealm/shortcuts.json`
  (`{"<app_id>/<shortcut id>": "CTRL+ALT+o"}`, empty string = off; the app id of a
  non-Flatpak app is `host`).
- **OBS capture built-in** — ships a patched `xdg-desktop-portal-wlr` so OBS can
  add *screen* and *window* capture sources straight from the game, choosing the
  target with an in-game selector UI.
- **In-game screenshots** (`Print Screen`) — capture exactly what you see (the
  full viewport, world and HUD) straight into the screenshot folder of the
  pause menu (defaults to your `~/Pictures`). The navigation menu adds a
  **SCREENSHOT** action to save a single window. A brief white flash confirms the
  shot; failures stay silent.
- **Free camera mode** (`SUPER+SHIFT+F`) — detach the view to fly around the room
  for screenshots or touring. `W`/`A`/`S`/`D` (or the left stick) move toward
  wherever you are looking — look up and move forward to climb, no jump needed.
  Your own avatar stands at the player's body (last position and rotation), so
  you can frame yourself even in solo; window interaction is disabled while the
  camera is detached, and the key returns you to your body.
- **HUD hide** (`SUPER+SHIFT+H`) — toggle the crosshair and FPS counter on and
  off for clean captures.
- **Effects** — X-RAY finder highlights any window's quad; windows flash when
  they open.
- **Navigation menu** (`SUPER+SHIFT+B`) — a window switcher with live previews (grab, focus,
  hide, find, pin, close, screenshot) and a **SHARE** action to stream a window to the other
  players.
- **Pause menu** (`Esc`) — remappable keybinds (independent keyboard/mouse
  and gamepad bindings per action), startup apps, custom keybinds that launch
  arbitrary
  commands inside the compositor, a screenshot folder setting, and a **LAN Game**
  page (host/join, player
  name & color, avatar picker, LAN discovery with a single **Apply** button).
- **KWin integration** — an optional KWin script fullscreens the game when
  launched from Plasma and blocks all KDE global shortcuts while it has focus.
- **GNOME Shell integration** — the same fullscreen/focus helper ships as a
  GNOME Shell extension (45–50). Because a GNOME extension cannot bind
  `zwp_keyboard_shortcuts_inhibit_v1` on the game's behalf, blocking Super,
  Alt+Tab, PrtScr… during play is done by the game itself: the Wayland driver
  of the exported Godot template is patched
  (`compositors/gnome/godot-4.7-shortcuts-inhibit.patch`) to expose the
  keyboard-shortcuts-inhibit protocol and request it on every window the game
  creates. The polkit agent of the host session is stopped at launch and
  restarted (or relaunched) on exit so the game can take over the whole
  desktop, mirroring the KWin behavior.
- **Hyprland integration** — a Lua window rule
  (`compositors/hyprland/cyberrealm.lua`) reproduces the same fullscreen/focus
  behavior on Hyprland via `hl.window_rule` (`fullscreen` + `stay_focused`).
  Global shortcuts are not blocked host-side, mirroring the GNOME/KWin tradeoff.

### LAN multiplayer

- **Host or join (2–4 players)** — each machine keeps its own
  compositor/desktop; you only share the room. From the pause menu LAN Game
  page: *Host Game*, *Join* (host IP) or *Find LAN games* (automatic UDP
  discovery via broadcast + `/24` sweep). Traffic runs over ENet on **UDP 7777**,
  discovery on **UDP 9999**.
- **Avatars** — other players appear as colored capsules with name labels,
  interpolated from unreliable position RPCs, fading out when you get close.
  The avatar you incarnate is picked from the LAN page dropdown, which lists
  every `avatar.tscn` found in the project (named after each scene's root
  node; default first). Your choice is persisted and the actual scene is baked
  with embedded assets and streamed to peers — everyone sees your real model,
  animations included.
- **Text chat & emotes** — press `SUPER+T` (remappable *chat*) to type,
  `Esc` to cancel, `Enter` to send; on a gamepad, **CHAT** in the radial menu
  opens it with the virtual keyboard. Messages fade after 10 s (opening the
  chat shows the last 50) and appear as bubbles above the speaker (Multiplayer page). `/wave`,
  `/point`, `/clap`, `/thumbsup`, `/laugh`, `/dance`, `/sit`, `/shrug` (or the
  radial **EMOTES** sub-menu, or the optional *emote_…* keybinds) show an emoji
  above your head and play the avatar's `emote_<id>` animation when it has one
  (dance and sit last until you move). The host or the dedicated server checks
  every message (registered player, 280 characters, 5 messages / 5 s, 1 emote
  / s) and relays it; text is never interpreted as markup. Mute a player from
  the Multiplayer page (local only). Allowed in online mode; the dedicated
  server writes the chat to its log.
- **Voice chat** — off by default: pick *Push to talk* (`V`, remappable
  *push_to_talk*) or *Voice activation* (adjustable threshold, 300 ms hangover)
  in the Multiplayer page. The microphone (PipeWire default source, or the
  `echo-cancel-source` of PipeWire's echo-cancel module when that option is on)
  is only opened during a multiplayer session; speech is encoded as 20 ms OPUS
  frames (24 kb/s, in-band FEC, DTX) and relayed by the host or dedicated
  server, which checks size, rate (60 frames/s) and sender. Voices come from
  the speaker's avatar (3D, fading out by 25 m) unless *Spatial voice* is off;
  a 🔊 appears before the name of who is talking; per-player mute and volume,
  global voice volume (`Voice` audio bus). Use a headset, or the echo-cancel
  module, so others don't hear themselves. Allowed in online mode; a dedicated
  server started with `--no-voice` does not relay voice. `CYBERREALM_VOICE_DEBUG=1`
  prints frames sent / relayed / received every second.
- **Window sharing** — select a window in the navigation menu and hit **SHARE**:
  its live content is streamed (H.264/AV1 inter-frame through a VAAPI hardware
  encoder, with a JPEG-per-frame fallback) and shown on a real quad in the other
  players' rooms. Unshared windows appear as black placeholders. Remote windows
  are **view-only**: `F` opens a fullscreen view-only focus mode, `P` pins them
  as PiP — no remote input, no kill. The owner's pointer position and custom
  cursor are mirrored on remote views.
- **Shared audio** — the audio of each *shared* window is captured
  per-application (PipeWire) and streamed as its own OPUS stream to the other
  players, who hear it coming from that window's quad in their room, so you
  can watch and listen together.
- **Custom levels over LAN** — the host bakes its current level (default or
  `res://user/`) into a self-contained binary blob (`LevelBaker`), compresses it
  (ZSTD) and streams it to joining players in chunks. Custom maps are playable in
  LAN **even with different builds**.

## How it works

```
             ┌────────────────────────────────────────  CyberRealm  ───────────────────────────────────────┐
             │                                                                                             │
   Godot 4.7 │  Game scripts (GDScript)                                                                    │
   + Jolt    │    wayland_room.gd  (orchestrator)                                                          │
             │       ├─ Windows3D    3D quads, grab/move/resize, raycast pointer                           │
             │       ├─ FocusMode    fullscreen 2D focus mode (+ remote view-only)                         │
             │       ├─ LayerSurfaces  waybar/rofi overlays + session lock                                 │
             │       ├─ PinnedWindows  picture-in-picture (+ remote PiP)                                   │
             │       ├─ Effects      X-RAY finder + open-flash                                             │
             │       ├─ RadialMenu   context-sensitive ring menu with emoji icons                          │
             │       ├─ VirtualKbd   on-screen keyboard (spatial D-PAD navigation)                         │
             │       └─ LanManager   host/join, avatars, shared windows, host level                        │
             │                                                                                             │
             │   GDExtension "libwaylandgodot" (C++, SCons)                                                │
             │     WlrCompositor (Node)  — full wlroots 0.19 compositor                                    │
             │       ├─ xdg-shell, layer-shell, session-lock, pointer-constraints,                         │
             │       │  relative-pointer, primary-selection, data-device (DnD),                            │
             │       │  cursor-shape, foreign-toplevel-management, keyboard-shortcuts-inhibit              │
             │       ├─ headless backend + xwayland-satellite (XWayland)                                   │
             │       ├─ VulkanDmaBufImport — zero-copy DMA-BUF → VkImage → Texture2D                       │
             │       ├─ VideoShare  — H.264/AV1 inter-frame (VAAPI hw / libx264 sw)                        │
             │       └─ AudioShare  — OPUS capture of shared windows (PipeWire)                            │
             │                                                                                             │
             └─────────────────────┬─────────────────────────────────────┬─────────────────────────────────┘
                                  │   Wayland socket                    │   LAN over ENet (UDP 7777)       
                                  │   (XDG_RUNTIME_DIR/cyberrealm-0)    │   discovery on UDP 9999          
                                  │                                     │   avatars · shared windows       
                                  │                                     │   shared audio · host level      
             ┌────────────────────▼───────────────────────────┐         ┌────────────────────────┐         
             │   Real apps: Dolphin, Firefox,                 │         │   Other players'       │         
             │   terminals, games, rofi…                      │         │   CyberRealm (same     │         
             │   xdg-desktop-portal-wlr (OBS)                 │         │   game, own desktop)   │         
             └────────────────────────────────────────────────┘         └────────────────────────┘         
```

The heavy lifting lives in the C++ module: it renders every Wayland surface into
an offscreen DMA-BUF buffer, imports the file descriptor into Godot's Vulkan
renderer as a `Texture2DRD` (via `VK_KHR_external_memory_fd`), and the GDScript
layer handles presentation and interaction. Capture caches are reused across
frames to avoid re-exporting/re-mapping buffers every frame.

For LAN sharing the same capture path feeds the network: `VideoShare` submits the
DMA-BUFs of the shared windows to an inter-frame encoder (VAAPI hardware
H.264/AV1, libx264 fallback) on a worker thread, and `AudioShare` captures the
PipeWire output of the shared windows' applications and encodes 20 ms OPUS
packets. The GDScript layer (`lan_manager.gd`) handles discovery, avatar sync,
window-state sync, flow control (keyframes/ACK/NACK), and the host's baked level
transfer.

## Repository layout

```
.
├── Game/source/          Godot 4.7 project (scenes, GDScript scripts, assets)
│   ├── scenes/
│   │   ├── wayland_room.tscn     main scene (WlrCompositor + Player + UI)
│   │   ├── level.tscn            default level (space station)
│   │   ├── player.tscn           first-person player
│   │   └── avatar.tscn           LAN avatar of another player
│   ├── scripts/
│   │   ├── wayland_room.gd       orchestrator
│   │   ├── radial_menu.gd        context-sensitive ring menu with emoji icons
│   │   ├── virtual_keyboard.gd   on-screen keyboard (AZERTY/QWERTY/QWERTZ)
│   │   ├── lan_manager.gd        LAN host/join, avatars, window + level sync
│   │   ├── avatar.gd             avatar interpolation/transparency
│   │   ├── level_baker.gd        bakes the level into a self-contained blob
│   │   └── ...                   windows_3d, focus_mode, layers, pins, menus
│   └── user/                     YOUR custom level & assets (overrides default)
├── compositors/
│   ├── ingame/           GDExtension C++ module — the embedded compositor
│   │   ├── wlr_compositor.cpp    the Wayland compositor as a Godot Node
│   │   ├── vulkan_dmauf.*        zero-copy DMA-BUF → Vulkan texture import
│   │   ├── video_share.*         H.264/AV1 inter-frame encode/decode (FFmpeg)
│   │   ├── audio_share.*         OPUS capture of shared windows (PipeWire)
│   │   └── register_types.cpp    GDExtension entry point
│   ├── portal-wlr/       patches for xdg-desktop-portal-wlr (window capture)
│   ├── cyberrealm-*      host-independent launchers: `cyberrealm-launch`
│   │                     (launch an app inside the game's compositor),
│   │                     `cyberrealm-run` (game launcher, systemd scope
│   │                     cleanup) and `cyberrealm-exec` (runtime IPC commands)
│   ├── kwin/             KWin script (fullscreen + block global shortcuts)
│   ├── gnome/            GNOME Shell extension (fullscreen + focus) and the
│   │                     Godot Wayland driver patch adding
│   │                     zwp_keyboard_shortcuts_inhibit_v1 so the game blocks
│   │                     the composite shortcuts while it has keyboard focus
│   ├── hyprland/         Hyprland Lua window rule (fullscreen + focus),
│   │                     mirroring the GNOME/KWin behavior
│   └── protocols/        vendored/protocol-generated headers
├── godot-cpp/            godot-cpp dependency (built via SCons)
├── install.sh            one-shot build & install (Arch Linux)
└── SConstruct            GDExtension build script
```

## Requirements

- Arch Linux (the install script uses `pacman`)
- Godot 4.7 (headless-capable build, used to export the game)
- `wlroots 0.19`, `wayland`, `wayland-protocols`, `pixman`, `libdrm`,
  `libinput`, `xwayland-satellite`, `vulkan-headers`, `vulkan-icd-loader`,
  `scons`, `pkgconf`, `meson`, `ninja`
- `xdg-desktop-portal-wlr` (for OBS capture)
- `ffmpeg`, `libva`, `libva-mesa-driver` (hardware H.264/AV1 encoding for
  shared windows)
- `libpipewire`, `libspa`, `opus` (shared audio capture)
- `libx11` (resolving the real PID of X11 windows for audio sharing, via the
  satellite's X server `_NET_WM_PID`)
- `openssh` + `rsync` on **every** machine playing (drag & drop file sharing
  over a throwaway SSH keypair), and an enabled `sshd` on machines that want
  to *receive* files (`systemctl enable --now sshd`)
- A running Wayland session (e.g. KDE/Plasma or GNOME) to launch the game from

## Build & install

```bash
git clone https://github.com/you/CyberRealm.git
cd CyberRealm
./install.sh
```

`install.sh`:

1. Installs the system dependencies with `pacman`.
2. Clones `godot-cpp` and builds the GDExtension (`scons target=template_debug`
   and `template_release`).
3. Clones and patches `xdg-desktop-portal-wlr` (v0.8.2) into `build/portal`.
4. Builds the Linux Godot export template from source. If a GNOME session is
   detected (or `--with-gnome` is passed), it first applies
   `compositors/gnome/godot-4.7-shortcuts-inhibit.patch` (keyboard-shortcuts
   inhibition for the Wayland driver) and stores a checksum stamp next to the
   template so a later patch change triggers a rebuild — idempotent.
5. Exports the Godot project to `Game/build/CyberRealm.x86_64`.
6. Installs the KWin script and the `cyberrealm-launch`, `cyberrealm-run` and
   `cyberrealm-exec` launchers (`compositors/`), plus a `.desktop` launcher.
   On GNOME it additionally installs and enables the
   `cyberrealm@cyberrealm.local` Shell extension (fullscreen + focus). On
   Hyprland it copies `compositors/hyprland/cyberrealm.lua` into
   `~/.config/hypr/` and appends `require("cyberrealm")` to
   `~/.config/hypr/hyprland.lua` only if it is not already present.
7. Opens the firewall for LAN multiplayer (`ufw allow 7777/udp` and
   `9999/udp`) and for file sharing (`22/tcp`), then reminds you to enable
   `sshd` if you want to receive files by drag & drop.

#### Standalone KMS session (optional, experimental)

`./install.sh --with-kms` additionally applies
`compositors/godot-patches/kms-display-driver.patch` (a `kms` DisplayServer for
Godot: libseat + Vulkan `VK_KHR_display` + libinput/xkbcommon), builds the
template with `kms=yes`, and installs a **CyberRealm (KMS)** entry in
`/usr/share/wayland-sessions` (sudo). Picking it in your login manager runs the
game as the whole session — no host compositor. The game's output goes to
`~/.local/state/cyberrealm/kms-session.log`. Limitations: single screen, no VT
switching by default (the keyboard is owned by the game; quit from the pause
menu — `CYBERREALM_KMS_VT_SWITCH=1` enables Ctrl+Alt+F1..F12, guarded by a
watchdog that kills a frozen game so the screen is released), and
the first run should be done with an `ssh` session open as a safety net. See
`compositors/godot-patches/kms-display-driver.md`.

If you'd rather build manually, `scons target=template_debug platform=linux`
builds the GDExtension and `godot --headless --path Game/source --export-release Linux Game/build/CyberRealm.x86_64` exports the game.

## Running

Launch the game (from Plasma or any launcher):

```bash
Game/build/CyberRealm.x86_64
```

The preferred way is via the `cyberrealm-run` wrapper installed by
`install.sh` (`~/.local/bin/cyberrealm-run`, also used by the
`cyberrealm.desktop` launcher). It runs the game inside its own systemd user
scope (cgroup) and, when the game process exits — for **any** reason, crash,
SIGKILL or normal quit — it stops the scope, which kills every remaining
process in the cgroup. This guarantees no daemon spawned inside the game
(out of the `shutdown_apps()` tree, setsid/double-fork…) survives the game.

On startup the game spawns its own compositor, starts XWayland on `:1`, and
launches your configured startup apps inside the room. The KWin script puts the
game in fullscreen and blocks KDE global shortcuts while it has focus.

To launch an app inside the compositor from outside the game, use the wrapper
(useful in `.desktop` files):

```bash
cyberrealm-launch firefox
```

## LAN multiplayer

1. In the pause menu (`Esc`) open **LAN Game** and set your name and avatar
   color. When connected, click **Apply** to broadcast your changes to other
   players.
2. On the machine hosting the room press **Host Game**. The other players either
   type the host IP under **Join**, or press **Find LAN games** to scan the
   network and pick the host. Both machines must be on the same network with UDP
   ports **7777** and **9999** open (the firewall is configured by
   `install.sh`; the host's status line shows its IP).
3. Once connected, everyone shares the room. Other players' windows appear as
   black quads until their owner marks them **SHARE** in the window menu (`B`) —
   then you see the streamed content (H.264/AV1, JPEG fallback) and hear its
   audio.
4. When you join, the host's current level is streamed to you, so you always
   stand in the same room — even with custom maps and different builds.

Remote windows are view-only: `SUPER+F` opens a fullscreen view of them (with the
owner's cursor overlaid), `SUPER+P` pins them as PiP. You cannot type or click into
them.

### Playing over the Internet (invitation code)

Without a dedicated server, a player can host for friends outside the local network: pause menu → Multiplayer →
**Host over the Internet (invitation code)**.

- The game asks the router to open UDP **7777** and TCP **7778** (UPnP; closed again when the session ends). Without
  UPnP, forward those two ports to the host machine by hand. Behind a CGNAT (no public IPv4) this cannot work: use a
  dedicated server.
- It shows a code `CR1-…` (masked; **Copy code**) holding the public address, a long random password (instead of the
  4-digit PIN) and **this machine's own certificate** (generated once, `user://certs/host_invite.*`, never the shared
  one in `certs/`). Send it privately: it contains the password.
- Friends paste the code in the **Join** address field. Their game accepts only that certificate (pinning): another
  machine, even with the address and password, fails the DTLS handshake.
- Sessions by invitation get the **online restrictions** (no window, sound or file sharing, no avatar scripts)
  unless the player ticks **Trust invited players like on a LAN** — host and guests each decide for themselves.

### LAN security

Joining is protected by a 4-digit **PIN** the host shares with its friends (shown
on the host's LAN page). The client sends it on every join; the host validates it
and, on failure, applies exponential back-off anti brute-force — after 3 wrong PINs
in a row the source IP is blacklisted for 30 s. Optionally (checkbox **TLS** when
joining), the session is additionally encrypted with **DTLS** using the
self-signed certificate shipped in `Game/source/certs/` (`lan_cert.crt` /
`lan_key.pem`). Host and clients must both enable TLS for a session to be
encrypted; a TLS client joining a plain host is refused at the DTLS handshake.

The room also self-heals: the host broadcasts a heartbeat every second and, if a
client loses it for more than 4 s or is disconnected unexpectedly, it
automatically reconnects with back-off (`should_reconnect`) for up to 12 attempts
within a 30 s window — unless the host closed the session gracefully.

A headless GDScript test suite verifies the LAN protocol logic:

```bash
cd Game/source && godot --headless --script tests/runner.gd
```

### File sharing by drag & drop

Drag files from any in-game application onto another player's avatar to send
them to their Downloads folder (XDG, as configured in their desktop
environment) over rsync-over-ssh — **no password
is ever typed or transmitted**: the receiver accepts the request with one
click, which temporarily authorizes the sender's throwaway SSH key for that
single transfer (restricted line, auto-removed afterwards). Every machine
needs `openssh` + `rsync`; receivers additionally need `sshd` running and
port 22 reachable on the LAN (both handled/checked by `install.sh`). The
receiver also announces its `sshd` **host public keys**
(`/etc/ssh/ssh_host_*_key.pub`) with its contact; the sender pins them in a
per-transfer `known_hosts` and connects with `StrictHostKeyChecking=yes`, so a
machine impersonating the receiver on the LAN is refused. If no host key was
announced (sshd missing or keys unreadable), it falls back to
trust-on-first-use and logs a warning. The pinning is only as trustworthy as
the game session itself: enable the session encryption (TLS) on untrusted
networks. Full details: `Game/source/user/README.md`.

## Controls

| Input                | Action                                            |
| -------------------- | ------------------------------------------------- |
| `W` `A` `S` `D`      | Move in the room                                  |
| `Space`              | Jump                                              |
| Mouse                | Look around / point at windows                    |
| Middle-click (hold)  | Interact mode (grab, move, resize windows)        |
| Left / right click   | Click into a window / pass to the compositor      |
| `SUPER+G`            | Grab a window (drag it around)                    |
| `SUPER+F`            | Focus a window (fullscreen 2D mode)               |
| `SUPER+P`            | Pin / unpin a window (picture-in-picture)         |
| `SUPER+H`            | Hide a window                                     |
| `SUPER+S`            | Share a window for LAN multiplayer                |
| `SUPER+K`            | Close the focused window                          |
| `SUPER+J`            | Toggle the focused window as a game (`force_game`) |
| `SUPER+SHIFT+B`      | Window navigation menu                            |
| `SUPER+TAB`          | Hand the pointer to a layer overlay (waybar/rofi) |
| `SUPER+SHIFT+F`      | Free camera mode (detach the view)                |
| `SUPER+SHIFT+H`      | Hide / show the HUD (crosshair, FPS counter)      |
| `SUPER+SHIFT+Esc`    | Take back the shortcuts captured by a VM / remote desktop in focus mode |
| `Print Screen`       | Take a full-screen screenshot                     |
| `Esc`                | Pause menu (keybinds, startup apps, LAN Game)     |
| `SUPER+T`            | Open the chat (multiplayer)                       |

All keybinds can be remapped from the pause menu — each action has an
independent keyboard/mouse and gamepad binding, both editable.

`force_game` (`SUPER+J`, remappable): while in focus mode, marks the focused
window as a **game**. In a game, pointer-lock and gamepad input are handed
straight to the window and the radial menu stays closed. Pressing it again
removes the mark, even for windows that request pointer lock.

### Gamepad

Full controller support, alongside keyboard & mouse (both stay active):

| Input                     | Action                                            |
| ------------------------- | ------------------------------------------------- |
| Left stick                | Move (analog)                                     |
| Right stick               | Look around / point at windows                    |
| `A`                       | Jump / confirm in menus                           |
| `B`                       | Toggle radial menu (context-sensitive ring)       |
| `X`                       | Left click                                        |
| `Y`                       | Right click                                       |
| `Select`                  | Middle click                                      |
| `Start`                   | Pause menu                                        |
| `LB`                      | Scroll Up                                         |
| `RB`                      | Scroll Down                                       |

#### Radial menu (`B`)

Press `B` to open the context-sensitive radial menu. Navigate with the left
stick, confirm with `A`, close with `B` or `Esc`. The menu adapts to context:

- **FPS mode** — Window Menu, Mouse Mode, Keyboard Mode, Custom Binds
- **Aiming at a window** — Grab, Focus, Hide, Kill, Pin, Share (+ the five FPS actions)
- **Focus mode** — Exit Focus, Kill

The Custom Binds sub-menu lists all configured binds with their key combos
and launches the bound command when selected.

## Capturing with OBS

The game runs its own `xdg-desktop-portal-wlr`, so in OBS you can add a
**Screen Capture (PipeWire)** source. When you do, CyberRealm pops up a capture
selector letting you pick between the whole screen or any open window. Your
choice is fed back to the portal and OBS starts streaming the game view.

## Notes & limitations

- The project currently targets a Linux Wayland environment (KDE Plasma was the
  reference session, GNOME Shell is supported); the embedded compositor
  requires wlroots 0.19.
- The GDExtension must be rebuilt if your wlroots version differs (see the
  `pkg-config` line in `SConstruct`).
- Internet play: either host with an **invitation code** (needs UPnP or two forwarded ports; no NAT hole punching,
  no relay), or run the dedicated server in `--online` mode (`server/README.md`).
- Remote windows are view-only: input is never forwarded to another player's
  compositor.
- Audio sharing matches applications by PID. For X11 windows the real PID is
  resolved on the satellite's X server (`_NET_WM_PID`), so X11 apps (GTK/Qt,
  Firefox…) are captured like Wayland apps. Apps that don't set `_NET_WM_PID`
  (some games) still have no audio.
- Custom maps shipped over LAN embed meshes/materials/textures but **not**
  scripts (see `Game/source/user/README.md`).
- No release binary is committed — `build/` is gitignored and produced by
  `install.sh`.

## Troubleshooting

| Symptom | Session | What to check |
|---|---|---|
| Black screen / `Failed to connect to Wayland display` | Wayland | The game needs a running host compositor (`echo $WAYLAND_DISPLAY`). Under KMS use the dedicated session instead. |
| Client windows never appear | any | Launch the app from inside the game (it sets `WAYLAND_DISPLAY` to the game's own socket); an app started before the game connects to the host. |
| Players can't join a LAN game | any | Firewall: UDP 7777/9999 and TCP 7778 must be open (`./install.sh` does it; for nftables, check the chain `inet filter input` exists). Router AP isolation also blocks it. |
| Drag & drop file transfer fails | any | `sshd` running on the receiver, `rsync` and `ssh` installed on both, TCP 22 open. |
| Polkit prompts appear on the wrong desktop | Wayland | Set the polkit agent in the pause menu; the host agent is stopped while the game runs and restarted on exit. |
| `KMS: libseat … Function not implemented` | KMS | KMS cannot start from a graphical session: switch to a TTY (Ctrl+Alt+F3) or pick the *CyberRealm (KMS)* session at login. |
| `^`, `¨` do nothing in the KMS session | KMS | Needs the `kms-display-driver.patch` revision with Compose support; check `LANG`/`LC_ALL` (the Compose table comes from the locale) and `/etc/vconsole.conf` for the layout. |
| KMS session froze or exited with code 70 | KMS | `~/.local/state/cyberrealm/kms-session.log` (the watchdog logs there). `CYBERREALM_KMS_WATCHDOG=off|always` and `CYBERREALM_KMS_WATCHDOG_TIMEOUT=<s>` tune it. Keep an `ssh` session open when testing. |
| Wrong monitor / resolution under KMS | KMS | `CYBERREALM_KMS_OUTPUT=DP-1`, `CYBERREALM_KMS_MODE=1920x1080@60`. |
| Layout is QWERTY under KMS | KMS | Set `XKB_DEFAULT_LAYOUT` or fix `XKBLAYOUT` in `/etc/vconsole.conf` (`localectl set-x11-keymap fr`). |

Regenerating the Godot KMS patch after editing the Godot tree:
`compositors/godot-patches/make-patch.sh [build/godot-kms-src]`.

## UI theming

The in-game UI (pause menu, window menu, capture selector, virtual keyboard,
tutorial, radial menu and HUD) is styled from CSS. The bundled default lives in
`Game/source/ui/style.css`; drop a `user://style.css`
(`~/.local/share/godot/app_userdata/CyberRealm/style.css`) beside it to
override any rule — user rules are parsed after the bundled ones, so they win.
Both files are watched: saving either reloads the theme live, no restart
needed.

The accent color is set in the pause menu (General → Accent color) and is
saved in `settings.json`. In any CSS color value, `accent` or `accent(.5)`
(with alpha) stands for it; the bundled theme uses it for hover/focus/selected
highlights, and your `style.css` can too.

The supported subset is deliberately small. A selector is an element (`button`,
`label`, `line-edit`, `check-button`, `option-button`, `slider`, `panel`, `hud`,
`radial`, `tutorial`), optionally with a class (`.name` or `element.name`) and a
state pseudo-class (`:hover`, `:pressed`, `:focus`):

```css
button             { background-color: rgba(31,36,51,.9); corner-radius: 5px; }
button:hover       { background-color: rgba(46,56,89,.95); }
button.quit-button { background-color: rgba(77,20,20,.9); }
```

Supported properties:

- **Colors** — `background-color`, `border-color` and `color` (text), as
  `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`.
- **Borders** — `border-width` plus `border-top/right/bottom/left-width`.
- **Corners** — `corner-radius` plus `corner-top-left/…-radius`.
- **Spacing** — `padding` plus `padding-top/right/bottom/left`, and
  `separation` (applied to `BoxContainer` classes).
- **Margins** — `margin` plus `margin-top/right/bottom/left`, accepting `px`
  or `%` of the screen (used to inset the four full-screen menu panels:
  `.pause-menu`, `.window-menu`, `.capture-menu`, `.keyboard-menu`).
- **Text** — `font-size`.

`border-width`, `corner-radius` and `padding` accept 1, 2 or 4 values
(top, right, bottom, left); numbers take an optional `px`.

Typed classes shipped in the default stylesheet: `.menu-panel`,
`.tutorial-panel`, `.back-button`, `.action-button`, `.key-button`,
`.key-mod-button`, `.key-mod-active`, `.tab-button`, `.tab-button-selected`,
`.pause-menu`, `.window-menu`, `.capture-menu`, `.keyboard-menu`,
`.quit-button`, `.remove-button`, `.success-button`, `.warning-button`,
`.title`, `.title-keyboard`, `.title-tutorial` and `.hint`.

The `hud`, `radial` and `tutorial` elements expose element-specific properties
read directly by their code — for example `hud { cursor-color; cursor-size;
fps-color; fps-size; cursor-active-color; }`, `radial { ring-radius;
ring-width; center-radius; gap-size; selector-width; decorator-width;
ring-color; ring-selected-color; ring-stroke-color; selector-color;
decorator-color; center-color; center-stroke-color; title-color;
title-font-size; emoji-size; }`, `tutorial { dim-color; }` and `chat {
background-color; color; font-size; fade-delay; }` (`fade-delay` in seconds).
