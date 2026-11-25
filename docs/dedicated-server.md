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

## Current limits

- LAN / VPN only for now: the PIN and DTLS protect the session, but no Internet hardening (rate limits per IP, bans)
  has been reviewed for exposure.
- The server relays players and serves the level; it does not simulate it yet. Level physics (props, breakage) stays
  local to each client until server-side authority is added.
- The RPC node path is identical on server and clients (`/root/WaylandRoom/LAN`): `scenes/dedicated_server.tscn`'s root
  must keep the name `WaylandRoom`.
