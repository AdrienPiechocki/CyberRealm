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

## 2. Run the server

Copy `Game/source` and `level.crblob` to the server (any Godot 4.7 binary for the target architecture — on a Pi 5 the
`linux.arm64` build), import once, then run:

```sh
godot --headless --path Game/source --import        # once
godot --headless --path Game/source scenes/dedicated_server.tscn -- \
    --blob=/srv/cyberrealm/level.crblob --pin=4242 --name="My server" --max-players=8
```

| Option | Default | |
|---|---|---|
| `--blob=FILE` | *(required)* | level exported at step 1 |
| `--pin=NNNN` | random | fixed PIN (printed at startup otherwise) |
| `--name=TEXT` | `CyberRealm Server` | name shown by LAN discovery |
| `--max-players=N` | `8` | |
| `--no-dtls` | encrypted | disable DTLS (debug only) |

Ports: **UDP 7777** (game), **UDP 9999** (LAN discovery), **TCP 7778** (level transfer). Players connect with the
LAN page of the pause menu: enter the server IP and PIN.

On a non-x86_64 machine Godot logs that the `waylandgodot` extension has no library for this architecture: this is
expected and harmless, the server never uses it.

## systemd unit (example)

```ini
[Unit]
Description=CyberRealm dedicated server
After=network-online.target

[Service]
User=cyberrealm
WorkingDirectory=/srv/cyberrealm
ExecStart=/usr/local/bin/godot --headless --path /srv/cyberrealm/Game/source scenes/dedicated_server.tscn -- --blob=/srv/cyberrealm/level.crblob --pin=4242
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

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
