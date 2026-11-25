# Dedicated server (headless)

Hosts a CyberRealm session without any local player — meant for an always-on machine such as a Raspberry Pi 5. It
reuses the LAN protocol unchanged (PIN, DTLS, level transfer, player relay), so clients join with **IP + PIN** exactly
like they join a LAN host. The server needs **no Wayland compositor, no window and no GDExtension**.

## 1. Export the level (on a game machine)

The server serves a **pre-baked level blob** (the same self-contained payload a LAN host sends):

```sh
godot --headless --path Game/source --script scripts/tools/export_level_blob.gd -- \
    res://user/Levels/Morrowind/level.tscn level.crblob
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

## Online mode (Internet)

`--online` hardens the server for the public Internet. Players join **by name** (`play.example.org`); joining by IP
keeps the old LAN behaviour and **cannot** reach an online server.

```sh
# 1. a DNS name pointing at your box (a free DDNS name works), and on the box forward to the server:
#    UDP 7777 (game), TCP 7778 (level), TCP 80 (Let's Encrypt, at issue and every renewal)
sudo ./server/install-server.sh install --online --domain play.example.org --email you@example.org \
     --blob level.crblob --admin-password 'another long secret' --open-firewall
# the script prints the generated join password (20 chars) — also stored in /opt/cyberrealm-server/server.conf
```
Port 80 already used on the server (a container, a reverse proxy)? Pick another local port for the validation and
forward public TCP 80 to it on your router: `--http-port 8080` (certbot remembers it for renewals; with ufw the script
opens it). Other options: DNS-01 validation with your DNS provider's certbot plugin, then `--tls-cert/--tls-key`.

**Best when a proxy (Traefik…) owns ports 80/443 — DNS-01, no port at all**: with a Cloudflare zone, create an API token
(*Edit zone DNS* on your zone), put `dns_cloudflare_api_token = <token>` in a file, then
`install-server.sh update --online --domain play.example.org --email you@example.org --dns-plugin cloudflare --dns-credentials FILE`.
The record of the game name must be **DNS only** (grey cloud): Cloudflare cannot proxy UDP.

Behind a reverse proxy that owns ports 80/443 (Traefik, nginx…) and public 80 must keep going to it: let certbot
free the port only while it validates — `--pre-hook "docker stop traefik" --post-hook "docker start traefik"` (a few
seconds of downtime every ~60 days, stored for the automatic renewals). The cleaner long-term alternative is DNS-01
validation through your DNS provider's certbot plugin, which needs no open port at all.

Own certificate instead of Let's Encrypt: `--tls-cert fullchain.pem --tls-key privkey.pem`. Renewals are automatic
(certbot timer + a deploy hook that copies the certificate and restarts the service).

What online mode changes:

| | LAN | Online |
|---|---|---|
| Server identity | embedded key (public in the repo), not verified | **real certificate, fully verified** by the client (chain + name); no downgrade |
| Login | 4-digit PIN over an RPC | **long password (12+), checked by the engine before the peer can send any RPC**; 8 s to authenticate |
| Brute force | 30 s per-IP lock | per-IP lock **doubling** 30 s → 1 h, plus a global cap of 40 attempts/min; password compared as SHA-256 |
| Discovery (UDP 9999) | on | **off** |
| Custom avatars | scripts travel and run | **no code accepted**: an avatar carrying scripts/scripted resources/sub-scenes is replaced by the default one; the server decodes no avatar |
| Window/audio/video/file sharing | on | **off** (RPCs ignored) |
| Level download | integrity by TCP only | **SHA-256 announced over the authenticated channel and checked** before the level is used |
| Messages | — | shape/size-checked, 120 msg/s per peer |
| systemd | — | sandboxed (no new privileges, read-only system, private /tmp, minimal capabilities) |

Players can also trust a private CA by dropping its certificate in `user://server_ca.crt`.

Remaining limits, honestly: a flood of UDP packets can still saturate the Pi's link (use your router/ISP protections);
the server is as trustworthy as the level you export (players run its scripts); the engine's own parsers (images,
meshes) handle data from other players' avatars.

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

- Exposing a server without `--online` (LAN mode) on the Internet is **not safe**: the 4-digit PIN and the unverified
  DTLS key do not protect it. Use `--online`.
- Late joiners receive the level as exported: props moved or broken before they joined are not replayed yet.
- Basic validation only (message sizes, impulse/throw speed clamps): a modified client could still ask to grab a
  prop from anywhere. Distance checks against the player's synced position are a possible next step.
- The RPC node path is identical on server and clients (`/root/WaylandRoom/LAN`): `scenes/dedicated_server.tscn`'s root
  must keep the name `WaylandRoom`.
