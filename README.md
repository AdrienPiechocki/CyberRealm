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
  mode / keyboard mode / custom binds; aiming at a window shows grab / focus /
  hide / kill / pin / share; in focus mode shows exit focus / kill. Select with
  the left stick, confirm with `A`.
- **Custom binds radial** — the radial menu's BINDS action opens a sub-menu
  listing all custom key binds, each showing its key combo and target command.
  Selecting one launches the command via the compositor.
- **OBS capture built-in** — ships a patched `xdg-desktop-portal-wlr` so OBS can
  add *screen* and *window* capture sources straight from the game, choosing the
  target with an in-game selector UI.
- **Effects** — X-RAY finder highlights any window's quad; windows flash when
  they open.
- **Navigation menu** (`SUPER+SHIFT+B`) — a window switcher with live previews (grab, focus,
  hide, find, pin, close) and a **SHARE** action to stream a window to the other
  players.
- **Pause menu** (`Esc`) — remappable keybinds (keyboard & mouse only, gamepad
  bindings are fixed), startup apps, custom keybinds that launch arbitrary
  commands inside the compositor, and a **LAN Game** page (host/join, player
  name & color, avatar picker, LAN discovery with a single **Apply** button).
- **KWin integration** — an optional KWin script fullscreens the game when
  launched from Plasma and blocks all KDE global shortcuts while it has focus.

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
- **Window sharing** — select a window in the navigation menu and hit **SHARE**:
  its live content is streamed (H.264/AV1 inter-frame through a VAAPI hardware
  encoder, with a JPEG-per-frame fallback) and shown on a real quad in the other
  players' rooms. Unshared windows appear as black placeholders. Remote windows
  are **view-only**: `F` opens a fullscreen view-only focus mode, `P` pins them
  as PiP — no remote input, no kill. The owner's pointer position and custom
  cursor are mirrored on remote views.
- **Shared audio** — the audio of the *shared* windows is captured
  per-application (PipeWire) and streamed as OPUS to the other players, so you
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
             │       └─ LanManager   host/join, avatars, shared windows, host level                        │
            │                                                                                             │
            │   GDExtension "libwaylandgodot" (C++, SCons)                                                │
            │     WlrCompositor (Node)  — full wlroots 0.19 compositor                                    │
            │       ├─ xdg-shell, layer-shell, session-lock, pointer-constraints,                         │
            │       │  relative-pointer, primary-selection, data-device (DnD)                             │
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
│   ├── kwin/             KWin script (fullscreen + block global shortcuts),
│   │                     the `cyberrealm-launch` app launcher wrapper and the
│   │                     `cyberrealm-run` game launcher (systemd scope cleanup)
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
- A running Wayland session (e.g. KDE/Plasma) to launch the game from

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
4. Exports the Godot project to `Game/build/CyberRealm.x86_64`.
5. Installs the KWin script, the `cyberrealm-launch` wrapper, and a
   `.desktop` launcher.
6. Opens the firewall for LAN multiplayer (`ufw allow 7777/udp` and
   `9999/udp`) and for file sharing (`22/tcp`), then reminds you to enable
   `sshd` if you want to receive files by drag & drop.

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

### File sharing by drag & drop

Drag files from any in-game application onto another player's avatar to send
them to their Downloads folder (XDG, as configured in their desktop
environment) over rsync-over-ssh — **no password
is ever typed or transmitted**: the receiver accepts the request with one
click, which temporarily authorizes the sender's throwaway SSH key for that
single transfer (restricted line, auto-removed afterwards). Every machine
needs `openssh` + `rsync`; receivers additionally need `sshd` running and
port 22 reachable on the LAN (both handled/checked by `install.sh`). Full
details: `Game/source/user/README.md`.

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
| `SUPER+Q`            | Close the focused window                          |
| `SUPER+SHIFT+B`      | Window navigation menu                            |
| `SUPER+TAB`          | Hand the pointer to a layer overlay (waybar/rofi) |
| `Esc`                | Pause menu (keybinds, startup apps, LAN Game)     |

All keybinds can be remapped from the pause menu (keyboard & mouse only;
gamepad bindings are fixed).

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
| `Select`                  | Interact mode                                     |
| `Start`                   | Pause menu                                        |
| `LB`                      | Scroll Up                                         |
| `RB`                      | Scroll Down                                       |

#### Radial menu (`B`)

Press `B` to open the context-sensitive radial menu. Navigate with the left
stick, confirm with `A`, close with `B` or `Esc`. The menu adapts to context:

- **FPS mode** — Window Menu, Mouse Mode, Keyboard Mode, Custom Binds
- **Aiming at a window** — Grab, Focus, Hide, Kill, Pin, Share (+ the four FPS actions)
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
  reference session); the embedded compositor requires wlroots 0.19.
- The GDExtension must be rebuilt if your wlroots version differs (see the
  `pkg-config` line in `SConstruct`).
- LAN multiplayer is local-network only (no NAT traversal / internet play).
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
