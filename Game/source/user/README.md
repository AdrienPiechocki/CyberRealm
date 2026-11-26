# Customization

This folder is reserved for **your** assets, **your** level and **your**
avatar. Everything here is ignored by git and overrides the game's default
content at startup.

## Creating your level

1. Put your assets (`.glb`, `.fbx`, `.png`, …) into `res://user/assets/`.
2. Open the project in the Godot 4.7 editor: assets are imported
   automatically.
3. Create your scene in its own folder, `res://user/Levels/<Name>/`:
   - either copy `res://scenes/level.tscn` to
     `res://user/Levels/<Name>/level.tscn` and edit it (move the walls, add
     your assets),
   - or create a new 3D scene there and save it with the exact name
     `level.tscn`.
4. Run the game and pick it in **pause menu → World** (see below). Until a
   level has been picked there, the first custom level found is loaded
   instead of the default one.

## Several levels: the World menu

You can keep several levels side by side and switch between them in game:
**pause menu → World** lists the default level plus every file named
`level.tscn` found anywhere under `res://user/`, for example:

| File | Shown as |
|---|---|
| `res://scenes/level.tscn` | Default |
| `res://user/Levels/Morrowind/level.tscn` | Morrowind |
| `res://user/Levels/Station/level.tscn` | Station |
| `res://user/level.tscn` (legacy single-level location) | Custom |

Entries are named after the folder that holds the file. Picking one loads it
in the background (progress is shown under the list) and swaps the
environment on the fly: you keep your player, menus and open windows, and
reappear at the new level's player spawn. The choice is remembered and loaded
at the next start (if the file disappears, the game falls back to the first
custom level, then to the default level).

In multiplayer, **only the selected level is baked** and sent to the other
players, when you host. The World page is **locked during a multiplayer
session** (hosting or joined): disconnect first to change level.

## Rules

- The file must be named **exactly** `level.tscn` and live under
  `res://user/`, ideally in its own folder `res://user/Levels/<Name>/` (the
  folder name is what the World menu shows).
- The root node can be any `Node3D` (the game instantiates it as a child of
  the `WaylandRoom` scene).
- The scene must contain a player. Use the one from
  `res://scenes/player.tscn`.
- The player is teleported back to its spawn if it falls below MAX_DEPTH on
  the Y axis (MAX_DEPTH is editable in the player script), in case it falls
  out of the map.
- App windows can be placed anywhere; only objects with collision are solid
  (use `StaticBody3D`/`CSGShape3D` for walls, like the sample level does).

## Performance: occlusion culling

For dense maps (multi-room interiors), the game **automatically** generates
an occluder based on the level's actual geometry on load (at boot, and also
for maps received over LAN): whatever sits behind walls and large objects is
no longer drawn by the GPU. An arch or doorway only hides what the geometry
actually blocks — no objects vanishing across openings.

- No action required: generation copies triangles from opaque meshes
  (~120k triangle budget, largest objects first, ~20 ms).
- **Manual bake supported**: if you add your own baked
  `OccluderInstance3D` ("Bake Occlusion" in the editor), it takes precedence
  and auto-generation is skipped.
- Diagnostics: run the game with `CYBERREALM_OCC_DEBUG=1` to visualize the
  generated occluder volume.
- Works with the Forward+ renderer (project default); no effect in
  Compatibility mode.

## Performance: adaptive 3D resolution

On integrated GPUs, full-resolution shading can saturate the GPU even after
occlusion culling. The game then automatically lowers the internal 3D render
resolution in steps (1.0 → 0.5, bilinear upscale) when FPS drops below ~45
sustained, and raises it back above ~58. Changes are logged (`[scaler]`).

- Disable: `CYBERREALM_ADAPTIVE_SCALE=0`.
- Full render diagnostics (FPS, draw calls, primitives, VRAM, scale):
  `CYBERREALM_RENDER_DEBUG=1` — useful to compare two machines.
- Very weak integrated GPUs: try the Mobile renderer, cheaper in fillrate
  than Forward+: `./cyberrealm --rendering-method mobile`.
- High GPU usage: the project caps at 120 FPS, so a fast GPU works flat out.
  `CYBERREALM_MAX_FPS=60` (or 30) reduces load and fan noise without
  touching the project.

## Performance: adaptive window captures

The compositor recaptures windows that keep redrawing (30/s, 60/s when
shared as video). On an integrated GPU these captures compete with the game
rendering: when frame time exceeds ~25 ms, the rate drops automatically to
10/s (then 5/s below ~25 ms) and recovers as soon as the GPU breathes again.
Two extra safeguards: at most 2 captures of unshared windows per frame (the
others wait for the next frame), and each capture's GPU wait is capped at
4 ms under pressure instead of 25 ms. Changes are logged
(`[capture] … pressure N`).

- Force the normal capture rate (diagnostics):
  `CYBERREALM_CAPTURE_UNTHROTTLED=1`.

## Performance: video sharing over LAN

Sharing a window keeps an encoding thread busy on the host side (DMA-BUF
readback, color conversion, H.264/AV1 encoding) at 60 fps per window. The
encoding mode is announced when sharing starts
(`video_share: started codec=… mode=…`): "hardware (VAAPI)" uses the GPU's
video block, "SOFTWARE (libx264)" means VAAPI failed and the CPU encodes —
watch out for that on modest machines.

- Reduce host load: `CYBERREALM_SHARE_FPS=30` (or 20) divides the encode +
  capture cost accordingly; 30 fps is plenty for most uses.

## Creating your avatar

1. Put your 3D assets (`.glb`, `.fbx`, …) into `res://user/assets/`.
2. Copy `res://scenes/avatar.tscn` to `res://user/avatar.tscn` and edit it,
   or create a brand-new 3D scene.
3. **The `avatar.gd` script must be attached** to the scene.
4. Add a `Label3D` node named **NameLabel** (billboard mode) for the player
   name. Add your meshes (`MeshInstance3D`) as children.
5. Run the game: if it finds `res://user/avatar.tscn`, it uses it instead of
   the default scene.
6. In LAN games, pick your avatar from the dropdown on the **LAN Game**
   page: every `avatar.tscn` in the project is listed there (named after
   each scene's root node). Your choice is remembered and the actual avatar —
   meshes and animations included — is sent to the other players.

### Avatar rules

- Convention: `res://user/avatar.tscn` is the "auto" avatar, used without
  touching the LAN menu. Any file named `avatar.tscn` elsewhere in the
  project also shows up in the LAN dropdown.
- **Mandatory script**: attach `res://scripts/avatar.gd` to the scene (root
  node or any child).
- **Mandatory NameLabel**: a `Label3D` named `NameLabel` (billboard). If it
  is missing, a dummy label is created automatically at `Y = 1.8`.
- The player color is applied automatically to meshes that have **no**
  material set. If you assign your own textured `StandardMaterial3D` to a
  mesh in the editor, the player color will not override it.
- Proximity transparency (< 1 m) works on every avatar mesh, including
  textured ones (their materials are duplicated automatically).
- The player name (NameLabel) is visible through walls.

### Emotes

When a player uses an emote (`/wave`, radial menu *EMOTES*…), an emoji appears above their head on every
machine. If your avatar's `AnimationPlayer` has an animation named `emote_<id>`, it is played too:
`emote_wave`, `emote_point`, `emote_clap`, `emote_thumbsup`, `emote_laugh`, `emote_dance`, `emote_sit`,
`emote_shrug`. One-shot emotes go back to idle at the end of the animation; `emote_dance` and `emote_sit`
last until the player moves (loop them in the editor). Moving or jumping interrupts any emote. Missing
animations are fine: the emoji alone is shown.

### First person / third person (full body awareness)

Each player sees **their own avatar** (the one they picked) as a body in first
person, with the head hidden, and entirely in third person (**F5**).

- Skeleton avatars: the head bone is auto-detected (first bone whose name
  contains `head`) and scaled to zero after the animation — skull, hair and
  helmet skinned to it disappear. If your rig names it differently, set
  **First person > Fps Head Bone** on the `avatar.gd` node.
- Skeleton-less avatars: meshes whose name contains `head`, `helm`, `hair`,
  `hat`, `hood`, `face`, `mask`, `brow` or `beard` are hidden. If nothing can
  be hidden, the avatar is simply not drawn in first person.
- **Fullbody Enabled** (off = never draw the avatar in first person) and
  **Fps Back Offset** (how far the body sits behind the camera) are exported
  on `avatar.gd`.
- `CYBERREALM_NO_FULLBODY=1` disables the local body entirely.
- **Walk in place** (`Walk In Place`, on by default): if the walk animation
  carries root motion (the avatar advances several meters per loop, then snaps
  back), the horizontal movement of the root track is removed at load; the
  vertical bounce is kept. Adjust `Root Motion Threshold` if a track is
  wrongly detected.
- **Idle Motion Scale** (default 0.35): amplitude of the idle animation
  around its first frame (1 = original, 0 = frozen). The walk is also aligned
  on the idle root position, so the body does not jump forward when walking.
- **Animation blending** (group *Animation blending*): idle <-> walk and jump
  transitions cross-fade (`Blend Idle Walk` 0.2 s, `Blend Jump` 0.1 s), and the
  walk plays faster/slower with the real speed so the feet do not slide. The
  reference speed is deduced from the root motion removed by *Walk In Place*;
  set `Walk Reference Speed` (m/s) if your walk has none. The speed factor is
  clamped by `Walk Speed Scale Min/Max`.
- **Directional locomotion** (subgroup *Directional locomotion*): set any of
  `Anim Walk Back/Left/Right` and `Anim Run`, `Anim Run Back/Left/Right` and the
  avatar blends them from its velocity in its own frame (an `AnimationTree` is
  built at runtime). The idle sits at the center of the blend space, so idle ->
  walk -> run is continuous, and strafing/backing up plays the matching
  animation. Each animation's natural speed comes from its root motion
  (`Default Walk Speed` / `Default Run Speed` if it has none). Directions left
  empty fall back to the forward walk; avatars without these fields keep the
  simple idle/walk/jump behavior. Jumps cross-fade (`Blend Loco Jump`).

## Custom scripts

Your levels and avatars can carry your own `.gd` scripts, including in
multiplayer: they travel with the map/avatar and run on every player's
machine.

1. Put your scripts under `res://user/` (e.g.
   `res://user/scripts/my_door.gd`).
2. Attach them to your nodes in the Godot editor like any script.
3. Run the game: over LAN, the sources travel with the baked level and are
   written to players' machines before the map loads. Custom avatars work
   the same way: their scripts are transmitted along with them.

### Rules

- Between your own scripts, reference each other via
  `preload("res://user/…")`, `load("res://user/…")` with a **literal** path,
  or `extends "res://user/base.gd"`: those dependencies are detected and
  transmitted along with everything else.
- Avoid `class_name` in user scripts: the global class registry does not
  exist on other players' machines — go through `preload()`.
- Game classes (`CharacterBody3D`, `res://scripts/avatar.gd`, …) are
  available normally on every machine.
- Each machine runs ITS copy of the script: keep logic deterministic, or
  pick an authority (typically the host). The `@rpc` annotations work — the
  scene being identical everywhere, NodePaths match from machine to machine.
- Limits: only `.gd` files are transmitted (`load()`ing an asset not embedded
  in the scene — texture, `.glb`… — will fail on clients); a dynamically
  built path (`"res://user/" + variable`) is not rewritten.
- Warning: joining a game means running the host's scripts; multiplayer
  assumes trust between players.

### Interacting with objects (left click)

A level object becomes interactive if its script (or one of its ancestors')
exposes `interact()`. Aim at the object within 3 m and left click: the
function is called on every machine in the session.

```gdscript
extends StaticBody3D  # any node WITH COLLISION

var open := false

# Mandatory — player_id = peer id of the player who interacted (1 = host).
func interact(_player_id: int) -> void:
	open = not open
	$AnimationPlayer.play("open" if open else "close")

# Optional — text shown under the crosshair while aiming at the object.
func get_interact_prompt() -> String:
	return "Open door"

# Optional — called when the crosshair enters/leaves the object (highlight…).
func interact_focus(aimed: bool) -> void:
	$Highlight.visible = aimed
```

Rules:

- The object must have **collision** (`StaticBody3D`, `CSGShape3D` with
  `use_collision`, mesh + collider…); clicks are resolved by raycast from
  the camera, like shooting in a classic FPS.
- `interact()` may omit the argument (`func interact()`), but declaring it
  lets you know WHO acted (e.g. host-only logic:
  `if player_id != 1: return`).
- Clicking a Wayland window never triggers a world interaction: the click
  belongs to the targeted application first.
- Over LAN, a click calls `interact()` on everyone (relayed through the
  network): keep the function deterministic for a coherent shared effect,
  or filter by `player_id` when only the author should do something.
- A spammer cannot flood the session: relaying is limited to one interaction
  per player every 150 ms.
- An object that handles its own input without being aimed at (e.g. a prop
  held in hand) can join the `interact_held` group: its
  `get_interact_prompt()` text then stays under the crosshair, aimed or not,
  until it leaves the group.

### Desktop-linked objects (media, notifications, system, clock)

Four ready-made objects can be instanced in your level (drag them from `res://scenes/objects/` into your scene in
the editor, then place and scale them like any node; their front faces +Z):

| Scene | Shows | Click |
|---|---|---|
| `media_player.tscn` | cover (local file, embedded image as with mpv, or web address), title, artist, progress of the current media player (MPRIS) | play / pause; ⏮ ⏭ buttons |
| `notification_board.tscn` | the last notifications (time, app, summary) | a row: its default action |
| `system_monitor.tscn` | CPU, RAM, GPU, temperature | — |
| `wall_clock.tscn` | real time and date | — |

Each player sees **their own** data (nothing is sent over the network); a click acts only for the player who
clicked. Players are those of apps running in the game *and* on your desktop; notifications are those of apps in
the game and of your desktop. A notification server running in the game (e.g. DankMaterialShell as a startup app)
always keeps priority and keeps showing its popups; the boards then only read the notifications. CyberRealm serves
them itself (with clickable actions) only if no server took the name 20 s after the game started. General → *Notifications in the world* chooses what boards show: full content, app name
only, or the count only. On a dedicated server these objects stay empty.

**Your own objects** can use the same bridge: `get_tree().get_first_node_in_group("desktop_bridge")` returns the
`DesktopBridge` node (null on a dedicated server, or before the game started it):

```gdscript
var b := get_tree().get_first_node_in_group("desktop_bridge")
b.media_changed.connect(func(p): print(p["title"], " ", p["status"]))   # p = {id, bus, identity, status, title,
                                                                         #  artist, album, art, length, position…}
b.media_removed.connect(func(id): pass)
b.notification_received.connect(func(n): print(n["app"], ": ", n["summary"]))  # n = {id, bus, app, summary, body,
                                                                                 #  actions, actionable, time}
var p: Dictionary = b.current_player()          # the playing one (or the last active), {} if none
b.media_command(p["id"], "play_pause")         # "play_pause", "next", "previous", "seek" (offset in µs)
b.notification_action(b.notifications()[0])   # default action (only "actionable" ones)
var pos_us: int = b.estimated_position(p)      # position extrapolated while playing
```

Lengths and positions are in microseconds (MPRIS). Respect `b.privacy.call()` (`"full"`, `"app"`, `"count"`) if
you display notifications. In multiplayer, `interact(player_id)` is called on every machine: act only when
`player_id == multiplayer.get_unique_id()`.

## Level options (pause menu)

A level can add its own settings to the pause menu: a **Level** row appears
under *Current level* in the **World** page and opens its options page. This is done by the level itself (see `Levels/Morrowind/scripts/level_options.gd`),
not by the game: levels without such a script simply have no **Level** button.

The Morrowind level provides:

| Option | Effect |
|---|---|
| **Time of day** | *Real time (local clock)*: the sky follows each machine's own clock. *Fixed hour*: freezes the sky at the hour set with the slider (00:00 – 23:45, 15 min steps). |
| **Fog** | In *Real time* mode the fog is **automatic**: thick at dawn (peak around 6:30), lifting during the morning, light in the afternoon, a light veil in the evening (the slider is disabled). With a *Fixed hour*, the **Fog thickness** slider (0 = no fog to 5, default 1.0) sets the density of the distance fog and of the volumetric fog. Interiors never have fog. |
| **Cloud density** | Cloud cover of the sky, from 0% (clear) to 100% (overcast). |
| **Rain** | Turns the rain (and the overcast sky) on or off. |

There are no keyboard shortcuts for these any more: everything goes through
this page.

Interiors use the level's environment (same effects and color adjustments as
outside) **without sky and without fog**; the graphics settings of the pause menu
keep applying to them.

### Multiplayer

- **Only the host can change the options** (or the player, in a solo game).
  Other players see the page read-only, with the current values.
- Every change is applied on the host, then sent to all clients (about 0.25 s
  after the last adjustment, so dragging the slider does not flood the
  network). A player who joins later receives the current state with the level.
- In *Real time* mode each player sees the time of their own machine, so
  players in different time zones see a different sky. Use *Fixed hour* to
  make everybody see the same one.
- Clients only accept the values above (mode, hour, fog, clouds, rain), and only from
  the host.

### Adding your own options

`level_options.gd` registers its page with the pause menu's extension point:

```gdscript
pause_menu.add_menu_page("level_options", "Level", _show_page)   # row in the World page
pause_menu.remove_menu_page("level_options")                     # in _exit_tree()
```

`_show_page` calls `_clear()`, sets `_current_view` to the same id and fills
`container` with the menu's helpers (`_make_title`, `_make_row_label`,
`_make_btn`…). A label followed by a slider (and its value label), a line edit
or a dropdown is laid out on one row automatically. The entry is removed when
the level is replaced. To add an option to this level, edit that script (it is
never overwritten by `Levels/Morrowind/integrate.py`): read and write the
state on the level's nodes (so late joiners get it through the baked level)
and send changes with the existing `authority` RPC. Reuse the same pattern
for another level.

## Back to the default level

Pick **Default** in the pause menu's **World** page.

## Back to the default avatar

Delete (or rename) `res://user/avatar.tscn`. The game then uses the default
capsule + helmet (`res://scenes/avatar.tscn`).

## Sending files to another player (drag & drop)

Drag one or more files from an application running inside the game (Dolphin,
Nautilus…) and **drop them onto another player's avatar** (within ~8 m): a
"Drop to send to …" hint appears while hovering. Files travel over
**rsync-over-ssh** to their Downloads folder (XDG, as configured in the
receiver's desktop environment).

**No password is ever asked for or transmitted.** The receiver approves the
request with a single click; their game then temporarily installs the
sender's SSH public key into their own `~/.ssh/authorized_keys`, which
authorizes exactly this transfer. The line is removed as soon as the
transfer ends, and a sweep deletes any forgotten line (crash, disconnect)
at game startup, at session end, and before every new request.

Flow:

1. You drop the files onto their avatar → they receive a request (name,
   size, list, fingerprint of your SSH key).
2. On their side: "Allow their temporary SSH key?" — Accept / Refuse /
   Esc; without an answer within 30 s the request expires. They only type
   their SSH username (pre-filled).
3. Accepted → rsync starts, progress shown on both sides
   (`-az --partial --timeout=30`, resumable after transient failures),
   then the key is removed.

Requirements:

- **Every machine**: `openssh` (provides `ssh`/`ssh-keygen`) + `rsync`
  (`pacman -S openssh rsync`).
- **Receiver**: ssh server enabled (`systemctl enable --now sshd`) with key
  authentication allowed (on by default).

Security properties:

- Your system/SSH password is never typed, never transmitted.
- Authentication uses an ed25519 keypair dedicated to the game
  (`~/.local/share/godot/app_userdata/CyberRealm/ssh/`), never reused
  elsewhere.
- The installed line is restricted (`no-port-forwarding,no-agent-forwarding,
  no-X11-forwarding,no-pty`): it only allows depositing files via rsync,
  not a shell.
- Data travels encrypted by ssh; the game's `known_hosts` lives isolated in
  its user folder (trust on first use).
- Only one transfer at a time; new requests are refused automatically while
  one is running.

Limitations:

- The first meeting exchanges public keys over the LAN through the game
  session (unencrypted): just like custom scripts, only play with people you
  trust — an active attacker substituting keys during THAT first exchange
  remains theoretically possible.
- Only regular files are sent (no folders — drop their contents instead).
  Files silently overwrite same-named ones in the receiver's Downloads folder.
- If your machine has several network interfaces (VPN, docker…), the
  advertised IP may be the wrong one → the transfer fails cleanly
  ("ssh server unreachable").

## LAN multiplayer

Your custom level is **playable over LAN even with different builds**: the
host serializes their level into a self-contained binary blob (embedded
meshes, materials and textures) and sends it to joining players. Clients
therefore don't need `res://user/` on their machine.

### Picking your avatar in LAN

On the **LAN Game** page of the pause menu, a dropdown lists every
`avatar.tscn` found in the project (default avatar first, then custom ones
in path order). Each entry shows the **root node name** of its scene. The
choice — persisted between sessions — determines the baked scene sent to
other players: everyone sees your real model with its animations. Without an
explicit choice, the "auto" avatar is used (`res://user/avatar.tscn` if it
exists, otherwise the default).

Limitations to know:

- **Custom scripts supported**: `.gd` files under `res://user/` attached to
  the level (or to avatars) travel inside the blob and run on every player —
  see "Custom scripts" for the rules.
- Nodes added **on the fly during the game** (under the level, without an
  `owner`) are not transmitted — only the scene contents are.
- The **player** (`Player`) is not transmitted: each machine keeps its own
  player; the host's spawn point is applied on the client.
- The level is sent when a player joins. It is the level selected in the
  World menu when you hosted; it cannot be changed during the session.
- **The client loads the map BEFORE entering the game**: after connecting,
  it receives and applies the host's level while frozen and invisible to
  other players (progress shown: "Loading host map… X%"). It only becomes
  visible once the map is loaded.
- Large maps: the blob is compressed (ZSTD) and sent in chunks, but a very
  heavy level (hundreds of MB of assets) will take a while to load client
  side. If the transfer definitively dies (no chunk for 15 s), the client
  still enters the game on its local map.

## Custom window shaders (transitions and borders)

Three optional spatial shaders customise how windows look. Put them in this
folder (`res://user/`) or in the game's user data folder (`user://`, which
takes priority) — they are picked up and **hot-reloaded** while the game runs. Ready-to-copy
examples live in `res://ui/decorations/examples/`.

| File | Used for |
|---|---|
| `window_open.gdshader` | opening transition (first frame of content) |
| `window_close.gdshader` | closing transition (the window lingers until it ends) |
| `window_border.gdshader` | window frame and title bar strip |

Each must be a `shader_type spatial`. The game fills these uniforms **if your
shader declares them**:

- Transitions: `sampler2D window_texture`, `vec2 content_size`,
  `bool opaque_mode`, `bool is_decoration` (frame/buttons vs. content),
  `bool closing`, `float progress` (0 → 1), `vec2 part_offset` (position of the
  drawn piece inside the window), `vec2 window_half_size`.
  Deform in *window space* (`VERTEX.xy + part_offset`) so frame and content
  move together. The title text is hidden during a transition.
- Border: `sampler2D border_texture`, `vec2 part_offset`, `vec2 piece_size`,
  `vec2 window_half_size`. Use `TIME` for animation.

Durations are set in `decorations.json`: `transition_open_duration` and
`transition_close_duration` (seconds, default 0.3). Delete the file to go back
to the default look.
