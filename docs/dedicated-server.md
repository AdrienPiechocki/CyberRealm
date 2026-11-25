# Dedicated server (headless)

Hosts a CyberRealm session without any local player — meant for an always-on machine such as a Raspberry Pi 5. It
reuses the LAN protocol unchanged (PIN, DTLS, level transfer, player relay), so clients join with **IP + PIN** exactly
like they join a LAN host. The server needs **no Wayland compositor, no window and no GDExtension**.

## 1. Export the level (on a game machine)

The server serves a **pre-baked level blob** (the same self-contained payload a LAN host sends):

```sh
godot --headless --path Game/source --script scripts/tools/export_level_blob.gd -- \
    res://user/level.tscn level.crblob
```

Without arguments it exports `res://user/level.tscn` if present, else `res://scenes/level.tscn`, to `level.crblob`.
Re-export whenever the level changes, then copy the file to the server.

## 2. Install on the server (Raspberry Pi 5 or any Linux arm64/x86_64)

`server/install-server.sh` does everything: downloads the matching Godot 4.7.2 (arm64 on a Pi), installs a **minimal copy
of the project** (scripts + server scene — no assets, no Wayland extension, ~2 MB), imports it, installs the level,
writes a config and creates a systemd service.

```sh
git clone --depth 1 https://github.com/AdrienPiechocki/CyberRealm.git && cd CyberRealm   # or rsync Game/source over
scp you@desktop:level.crblob .                                                           # the blob from step 1
sudo ./server/install-server.sh install --blob level.crblob --pin 4242 --name "My server" --open-firewall
```

Other commands:

| Command | |
|---|---|
| `install-server.sh update [--blob NEW]` | re-sync the project from this checkout (after a `git pull`), optionally swap the level, restart |
| `install-server.sh blob FILE` | replace the level and restart |
| `install-server.sh status` | PIN, ports, systemd status |
| `install-server.sh uninstall [--purge]` | remove the service and the app (`--purge`: also level, config, user) |

Options: `--pin NNNN` (kept across updates, random if never given), `--name`, `--max-players N` (8), `--no-dtls`,
`--source DIR`, `--prefix DIR` (`/opt/cyberrealm-server`), `--user NAME`, `--godot-bin PATH`, `--no-service`
(local install without root/systemd — handy to try the script on a desktop).

Layout: `app/` (project), `godot/` (binary), `data/level.crblob`, `server.conf` (PIN, name, max players, DTLS),
`run-server.sh` (what systemd runs). Logs: `journalctl -u cyberrealm-server -f`.

**After every change to `lan_manager.gd` RPCs, re-export the game on the players' side too** (a stale client fails
with `rpc node checksum failed` in the server log and times out).

### Running it by hand

```sh
godot --headless --path Game/source scenes/dedicated_server.tscn -- \
    --blob=level.crblob [--pin=4242] [--name="My server"] [--max-players=8] [--no-dtls]
```

Ports: **UDP 7777** (game), **UDP 9999** (LAN discovery), **TCP 7778** (level transfer). Players connect with the
LAN page of the pause menu: enter the server IP and PIN (tick TLS unless started with `--no-dtls`).

On a non-x86_64 machine nothing about the `waylandgodot` extension is installed, so Godot never loads it.

## Admin player (level settings)

On a dedicated server nobody is "the host", so the level options (time of day, fog, clouds, rain — pause menu >
*Level*) would be read-only for everyone. Set an **admin password**:

```sh
sudo ./server/install-server.sh update --admin-password 'my secret'     # --admin-password "" disables admin
```

(by hand: environment variable `CYBERREALM_ADMIN_PASSWORD`, or `--admin-password=…` — visible in `ps`). A player then
opens pause menu > *Level*, types the password and presses *Unlock as admin*; the page becomes editable and every
change is applied by the server and broadcast to all players. Players who join later receive the current options.

- The password travels inside the DTLS-encrypted session (plaintext only with `--no-dtls`).
- 3 wrong attempts lock that player out for 30 s. Admin status ends when the player disconnects.
- Level scripts can reuse it: `lan.is_admin()` (client) / `lan.is_admin(peer)` (server) and the level-message channel.
  A level script runs on the server only if its node carries the `net_server` metadata (`LevelOptions` does).
- The re-exported blob and a re-exported game are both required (the game gained `is_admin` / `request_admin`).

## Server authority over level physics

The server loads the level from the blob (user scripts and assets installed like a client does) and strips every
script except the nodes tagged with the `net_server` metadata (the Morrowind level tags `Interiors`, which runs the
props in server mode: no weather, day/night, windows or player). Then:

- A client **touching/pushing, grabbing, holding, throwing or dropping** a prop sends a *level message*
  (`prop_touch`, `prop_grab`, `prop_hold`, `prop_throw`, `prop_drop`) to the server, which simulates the body.
- Moving props are streamed to clients through the existing level sync (`lan_sync` transforms, ~20 Hz); clients keep
  a kinematic mirror body glued to the mesh for collisions and aiming.
- **Breakage** is decided by the server (impact speed); it broadcasts `prop_break` and clients play the shards.
- The generic channel lives in `lan_manager.gd`: `send_level_message()` (client -> server),
  `broadcast_level_message()` / `send_level_message_to()` (server -> clients), signal `level_message`, plus
  `register_level_sync()` / `unregister_level_sync()` for nodes that move at runtime (clients accept updates only for
  nodes carrying the `lan_sync_dynamic` metadata).
- Solo and LAN-host play are unchanged: props stay local (`CYBERREALM_LOCAL_PROPS=1` forces this on a client).

## Current limits

- LAN / VPN only for now: the PIN and DTLS protect the session, but no Internet hardening (rate limits per IP, bans)
  has been reviewed for exposure.
- Late joiners receive the level as exported: props moved or broken before they joined are not replayed yet.
- Basic validation only (message sizes, impulse/throw speed clamps): a modified client could still ask to grab a
  prop from anywhere. Distance checks against the player's synced position are a possible next step.
- The RPC node path is identical on server and clients (`/root/WaylandRoom/LAN`): `scenes/dedicated_server.tscn`'s root
  must keep the name `WaylandRoom`.
