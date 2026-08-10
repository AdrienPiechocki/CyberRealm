# CyberRealm

A game where your desktop lives inside a 3D virtual world.

CyberRealm embeds a **complete Wayland compositor inside a Godot 4 game**. Every
window is a real Wayland surface rendered as a textured 3D quad that floats in a
room you walk around in — with a first-person camera, raycast interaction,
drag-and-drop, and even a fullscreen "focus" mode. Your Linux desktop's apps
(KDE/Plasma, GTK, Firefox, terminals, games…) run unmodified inside the game
world.

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
  Grab (`G`), move, resize from any edge, or point and click into it.
- **Focus mode** (`F`) — pull any window to the front as a fullscreen 2D overlay
  for real work; press the same key again to release it back into the 3D world.
- **Picture-in-picture** (`P`) — pin windows as small overlays that stay on top
  while you keep interacting with the world.
- **Layer surfaces** — waybar, rofi and friends are rendered as screen-anchored
  2D overlays inside the 3D view, with proper keyboard-interactive focus
  (a modifier key hands the pointer to the overlay).
- **X11 support** — X applications run through
  [xwayland-satellite](https://gitlab.freedesktop.org/xwayland-satellite/xwayland-satellite),
  forwarded as XWayland surfaces.
- **OBS capture built-in** — ships a patched `xdg-desktop-portal-wlr` so OBS can
  add *screen* and *window* capture sources straight from the game, choosing the
  target with an in-game selector UI.
- **Effects** — X-RAY finder highlights any window's quad; windows flash when
  they open.
- **Navigation menu** (`B`) — a window switcher with live previews (grab, focus,
  hide, find, pin, close).
- **Pause menu** (`Esc`) — remappable keybinds, startup apps, and custom
  keybinds that launch arbitrary commands inside the compositor.
- **KWin integration** — an optional KWin script fullscreens the game when
  launched from Plasma and blocks all KDE global shortcuts while it has focus.

## How it works

```
            ┌───────────────────────────────  CyberRealm  ────────────────────────────────┐
            │                                                                             │
  Godot 4.7 │   Game scripts (GDScript)                                                   │
  + Jolt    │     wayland_room.gd  (orchestrator)                                         │
            │       ├─ Windows3D    3D quads, grab/move/resize, raycast pointer           │
            │       ├─ FocusMode    fullscreen 2D focus mode                              │
            │       ├─ LayerSurfaces  waybar/rofi overlays + session lock                 │
            │       ├─ PinnedWindows  picture-in-picture                                  │
            │       └─ Effects      X-RAY finder + open-flash                             │
            │                                                                             │
            │   GDExtension "libwaylandgodot" (C++, SCons)                                │
            │     WlrCompositor (Node)  — full wlroots 0.19 compositor                    │
            │       ├─ xdg-shell, layer-shell, session-lock, pointer-constraints,         │
            │       │  relative-pointer, primary-selection, data-device (DnD)             │
            │       ├─ headless backend + xwayland-satellite (XWayland)                   │
            │       └─ VulkanDmaBufImport — zero-copy DMA-BUF → VkImage → Texture2D       │
            │                                                                             │
            └───────────────────────────┬─────────────────────────────────────────────────┘
                                        │  Wayland socket (e.g. XDG_RUNTIME_DIR/cyberrealm-0)
             ┌──────────────────────────▼──────────────────────────────┐
             │  Real apps: Dolphin, Firefox, terminals, games, rofi…   │
             │  xdg-desktop-portal(-wlr) for OBS capture (PipeWire)    │
             └─────────────────────────────────────────────────────────┘
```

The heavy lifting lives in the C++ module: it renders every Wayland surface into
an offscreen DMA-BUF buffer, imports the file descriptor into Godot's Vulkan
renderer as a `Texture2DRD` (via `VK_KHR_external_memory_fd`), and the GDScript
layer handles presentation and interaction. Capture caches are reused across
frames to avoid re-exporting/re-mapping buffers every frame.

## Repository layout

```
.
├── Game/source/          Godot 4.7 project (scenes, GDScript scripts, assets)
│   └── scenes/
│       ├── wayland_room.tscn     main scene (WlrCompositor + Player + UI)
│       └── player.tscn
├── compositors/
│   ├── ingame/           GDExtension C++ module — the embedded compositor
│   │   ├── wlr_compositor.cpp    the Wayland compositor as a Godot Node
│   │   ├── vulkan_dmauf.*        zero-copy DMA-BUF → Vulkan texture import
│   │   └── register_types.cpp    GDExtension entry point
│   ├── portal-wlr/       patches for xdg-desktop-portal-wlr (window capture)
│   ├── kwin/             KWin script (fullscreen + block global shortcuts)
│   │                     and the `cyberrealm-launch` app launcher wrapper
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

If you'd rather build manually, `scons target=template_debug platform=linux`
builds the GDExtension and `godot --headless --path Game/source --export-release
Linux Game/build/CyberRealm.x86_64` exports the game.

## Running

Launch the game (from Plasma or any launcher):

```bash
Game/build/CyberRealm.x86_64
```

On startup the game spawns its own compositor, starts XWayland on `:1`, and
launches your configured startup apps inside the room. The KWin script puts the
game in fullscreen and blocks KDE global shortcuts while it has focus.

To launch an app inside the compositor from outside the game, use the wrapper
(useful in `.desktop` files):

```bash
cyberrealm-launch firefox
```

## Controls

| Input                | Action                                            |
| -------------------- | ------------------------------------------------- |
| `W` `A` `S` `D`      | Move in the room                                  |
| `Space`              | Jump                                              |
| Mouse                | Look around / point at windows                    |
| Middle-click (hold)  | Interact mode (grab, move, resize windows)        |
| Left / right click   | Click into a window / pass to the compositor      |
| `G`                  | Grab a window (drag it around)                    |
| `F`                  | Focus a window (fullscreen 2D mode)               |
| `P`                  | Pin / unpin a window (picture-in-picture)         |
| `K`                  | Close the focused window                          |
| `B`                  | Window navigation menu                            |
| `tab`                | Hand the pointer to a layer overlay (waybar/rofi) |
| `Esc`                | Pause menu (keybinds, startup apps, custom binds) |

All keybinds can be remapped from the pause menu.

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
- No release binary is committed — `build/` is gitignored and produced by
  `install.sh`.
