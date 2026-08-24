# Customization

This folder is reserved for **your** assets, **your** level and **your**
avatar. Everything here is ignored by git and overrides the game's default
content at startup.

## Creating your level

1. Put your assets (`.glb`, `.fbx`, `.png`, …) into `res://user/assets/`.
2. Open the project in the Godot 4.7 editor: assets are imported
   automatically.
3. Create your scene:
   - either copy `res://scenes/level.tscn` to `res://user/level.tscn` and
     edit it (move the walls, add your assets),
   - or create a new 3D scene under `res://user/` and save it with the exact
     name `level.tscn`.
4. Run the game: if it finds `res://user/level.tscn`, it loads it instead of
   the default level. Otherwise it falls back to `res://scenes/level.tscn`.

## Rules

- The file must be named **exactly** `res://user/level.tscn`.
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

## Back to the default level

Delete (or rename) `res://user/level.tscn`. The game then uses
`res://scenes/level.tscn`.

## Back to the default avatar

Delete (or rename) `res://user/avatar.tscn`. The game then uses the default
capsule + helmet (`res://scenes/avatar.tscn`).

## Sending files to another player (drag & drop)

Drag one or more files from an application running inside the game (Dolphin,
Nautilus…) and **drop them onto another player's avatar** (within ~8 m): a
"Drop to send to …" hint appears while hovering. Files travel over
**rsync-over-ssh** to `~/CyberRealmRecu/` on the receiver.

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
  Files silently overwrite same-named ones in `~/CyberRealmRecu/`.
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
- The level is sent when a player joins. If you change levels, later joiners
  receive the new one.
- **The client loads the map BEFORE entering the game**: after connecting,
  it receives and applies the host's level while frozen and invisible to
  other players (progress shown: "Loading host map… X%"). It only becomes
  visible once the map is loaded.
- Large maps: the blob is compressed (ZSTD) and sent in chunks, but a very
  heavy level (hundreds of MB of assets) will take a while to load client
  side. If the transfer definitively dies (no chunk for 15 s), the client
  still enters the game on its local map.
