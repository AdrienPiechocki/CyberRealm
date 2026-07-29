# Wayland-Godot — Wayland Compositor as a Godot GDExtension

A full-featured Wayland compositor implemented as a Godot 4 GDExtension plugin. Uses **wlroots 0.18** as the compositor backend and renders Wayland windows as textured 3D quads inside a Godot scene. No physical display required — runs headless with `wlr_headless_backend`.

---

## Build

```bash
# Dependencies (Arch Linux)
sudo pacman -S wlroots0.18 wayland wayland-protocols pixman libdrm xwayland-satellite \
               libinput xkbcommon scons pkgconf vulkan-headers vulkan-icd-loader

# Godot-cpp
git clone https://github.com/godotengine/godot-cpp.git

scons target=template_debug platform=linux
```

The built shared library lands in `demo/bin/`. Open `demo/` as a Godot 4.2+ project and run `wayland_room.gd`.

---

## Features

### Compositor Core (C++, wlroots 0.18)

- **Headless backend** — `wlr_headless_backend_create()`, no physical display or GPU output needed
- **Fake output** — 1280x720 output committed at up to 120 FPS
- **Wayland protocols supported:**

| Protocol | Version | Purpose |
|---|---|---|
| `wl_compositor` | 6 | Surface management |
| `wl_seat` | — | Pointer + keyboard capabilities |
| `xdg_shell` | 3 | Toplevel windows, popups, nested popups |
| `wl_subcompositor` | — | Sub-surfaces (required by Firefox WebRender) |
| `wl_viewporter` | — | Surface viewport / cropping |
| `linux_dmabuf_v1` | 4 | DMA-BUF buffer sharing for GPU clients |
| `wl_data_device_manager` | — | Clipboard, drag-and-drop |
| `wl_primary_selection_v1` | — | Middle-click primary selection |
| `zwp_pointer_constraints_v1` | — | Pointer lock (LOCKED + CONFINED) |
| `zwp_relative_pointer_v1` | — | Relative pointer motion events |

### Three-Tier Rendering Pipeline

Auto-negotiated per-surface, in priority order:

#### 1. Vulkan Zero-Copy (GPU → GPU, preferred)
- wlroots renders via EGL/GLES2 to a DMA-BUF offscreen buffer
- DMA-BUF fd imported into Godot's Vulkan device via `VK_KHR_external_memory_fd`
- `VkImage` (LINEAR tiling) + `VkDeviceMemory` bound to the imported buffer
- Wrapped as a Godot `RID` via `texture_create_from_extension`, then `Texture2DRD`
- **No mmap, no memcpy** — the shader samples the GPU buffer directly
- Cross-API GPU sync via `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` (Linux 5.20+) with `DMA_BUF_IOCTL_SYNC` fallback
- Deferred resource destruction (one frame delayed) to avoid GPU stalls

#### 2. DMA-BUF + mmap (fallback)
- GPU-rendered DMA-BUF, checked for linear modifier
- mmap the fd for direct CPU read
- Per-pixel copy with BGRA→RGBA swizzle when needed
- `CaptureCache` reuses buffers across frames

#### 3. Pixman CPU (last resort)
- Software rendering via Pixman, direct pixel access through `wlr_buffer_begin_data_ptr_access`
- Per-pixel BGRA→RGBA swizzle
- Can be forced with `WAYLANDGODOT_FORCE_PIXMAN=1`

#### Rendering Optimizations
- **Rounded allocation** — capture dimensions rounded up to next 64px step to avoid reallocation during resize
- **Per-frame recapture** — all mapped windows re-captured each frame (Firefox needs this without focus)
- **Performance logging** — per-stage timing logged when total exceeds 2ms

### Window Management

- **Toplevel windows** spawn as 3D quads facing the player
- **Popups** — nested sub-menus, tooltips, context menus with correct positioning
- **Drag-and-drop** — full `wl_data_device_manager` protocol with drag icon capture
- **Window moving** — middle-click drag (3D depth), titlebar drag (2D on plane)
- **Window resizing** — 8 edge/corner zones (20px corners, 5px edges), 500px minimum
- **Depth adjustment** — scroll while grabbing moves window closer/farther
- **`close_window(id)`** — sends `xdg_toplevel.send_close()`
- **`set_window_size(id, w, h)`** — configures a new size

### Keyboard Input

- Virtual software keyboard (`wlr_keyboard`, XKB layout `fr`)
- 75+ key Godot→evdev translation table
- AZERTY fixes (`<` and `>` keys)
- AltGr support (key location 2 → `KEY_RIGHTALT`)
- Keyboard focus on click, `release_all_keys()` on mode exit
- **Interact mode** (middle-click toggle) — all keyboard forwarded to focused window

### Pointer Input

- Absolute motion with auto-enter/motion/frame
- Mouse buttons (left, right) and axis (vertical + horizontal scroll)
- Relative pointer via `zwp_relative_pointer_v1`
- Pointer lock via `zwp_pointer_constraints_v1` (LOCKED + CONFINED)
- Physics raycast from camera to 3D quads for hit-testing

### Focus Mode

- **F** key to enter/exit fullscreen focus on a targeted window
- Fullscreen `TextureRect` with `STRETCH_KEEP_ASPECT_CENTERED`
- Pixel-perfect pointer mapping
- Pointer lock auto-captures mouse when client requests it (FPS games)
- Keyboard and mouse input forwarded to the focused window
- Popup overlays rendered as sub-TextureRects in focus mode
- Auto-exit if the window is unmapped
- **✕** close button in top-right corner

### Window Pinning (Picture-in-Picture)

- **P** key to pin/unpin a window
- Stacked thumbnails (640x360) with blue border in the top-left corner
- Live updates from `window_texture_updated` signal

### X-Ray / Find Mode

- Window menu **FIND** action toggles a red pulsing overlay on a window
- `no_depth_test = true`, `render_priority = 10`, ~1Hz alpha pulse

### Desktop Notifications

- Subprocess `dbus-monitor --session interface='org.freedesktop.Notifications'` with pipe IPC
- Parses notification fields: app_name, summary, body, icon, urgency
- Emitted as `notification_received(app_name, summary, body, app_icon, urgency)` signal
- Urgency levels: 0=low, 1=normal, 2=critical
- Displayed as stacking toasts in the 3D UI overlay

### Application Launcher

- **R** key opens the launcher menu
- Parses `.desktop` files from standard XDG directories
- Deduplication by `Exec` line
- 10 canonical categories with collapsible headers and app counts
- Real-time search across all categories
- Favorites system (F1–F12 quick-launch slots)
- Right-click to assign, persistent in `user://favorites.json`
- Auto-detection of terminal emulator (konsole, alacritty, kitty, xterm) for `Terminal=true` apps

### Window Menu

- **B** key opens the window navigation menu
- Tab bar with all open windows, click to select
- Live preview of selected window's texture
- Action buttons: **GRAB**, **FOCUS**, **HIDE/SHOW**, **PIN**, **FIND**, **QUIT**

### Settings Menu (Pause Menu)

- **Escape** opens the pause menu with multi-page settings:
  - **Resolution** — 6 presets (1280x720 to 3840x2160), fullscreen toggle
  - **Terminal** — custom terminal command
  - **Portal Backend** — `XDG_CURRENT_DESKTOP` value
  - **Polkit Agent** — path to authentication agent
  - **Keybinds** — rebind any of 11 actions (forward, back, left, right, jump, interact_mode, launcher, window_menu, grab, focus_window, pin_window)
  - FPS counter toggle, capture label toggle
- Persisted to `user://settings.json`

### XWayland Support

- `xwayland-satellite :1` launched automatically on startup
- `DISPLAY=:1` environment variable set for X11 clients

### Child Process Management

- All forked processes tracked in a `child_pids` vector
- `killpg(SIGTERM)` on shutdown, zombies reaped with `WNOHANG`

---

## GDExtension Signals

| Signal | Parameters | Description |
|---|---|---|
| `window_mapped` | id, title, app_id | New toplevel window |
| `window_unmapped` | id | Toplevel window closed |
| `window_texture_updated` | id, texture, width, height | Content re-rendered |
| `popup_mapped` | id, parent_window_id, parent_popup_id, x, y, w, h | Popup appeared |
| `popup_unmapped` | id | Popup closed |
| `popup_texture_updated` | id, texture, width, height | Popup re-rendered |
| `pointer_lock_changed` | window_id, locked | Pointer lock toggled |
| `window_fullscreen_changed` | id, fullscreen | Fullscreen state changed |
| `drag_icon_updated` | texture, width, height | Drag icon appeared |
| `drag_icon_removed` | — | Drag icon removed |
| `notification_received` | app_name, summary, body, app_icon, urgency | Desktop notification |

---

## Input Map (Default Bindings)

| Action | Key | Description |
|---|---|---|
| `forward` | Z | Move forward (AZERTY) |
| `back` | S | Move backward |
| `left` | Q | Strafe left (AZERTY) |
| `right` | D | Strafe right |
| `jump` | Space | Jump |
| `interact_mode` | Middle-click | Toggle keyboard capture to window |
| `launcher` | R | Open app launcher |
| `window_menu` | B | Open window menu |
| `grab` | G | Grab window |
| `focus_window` | F | Enter/exit focus mode |
| `pin_window` | P | Pin/unpin window |
| `left_click` | Mouse 1 | Click Wayland window |
| `right_click` | Mouse 2 | Right-click Wayland window |
| `scroll_up` | Wheel up | Scroll up |
| `scroll_down` | Wheel down | Scroll down |
| `ui_cancel` | Escape | Pause menu / exit menus |


