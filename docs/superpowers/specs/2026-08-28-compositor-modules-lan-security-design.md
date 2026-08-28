# Découpe du compositor, sécurisation LAN et gestion d'erreurs réseau

Date : 2026-08-28

## Objectif

Trois chantiers sur CyberRealm :

1. **Découpe de `wlr_compositor.cpp`** (6424 lignes) en modules par domaine, sans
   changer l'architecture de la classe `WlrCompositor`.
2. **Sécurisation du protocole LAN** : l'auth PIN existante est durcie
   (anti brute-force) et le transport est chiffré par DTLS optionnel.
3. **Gestion d'erreurs réseau** : reconnexion automatique avec rejoin côté
   client, heartbeat applicatif hôte→client, timeouts explicites.

Décisions actées : découpe « par domaine » (la classe reste unique, les
fonctions membres sont réparties dans des TU dédiées), DTLS via ENet+Godot,
et reconnexion automatique avec rejoin.

---

## Partie 1 — Découpe du compositor C++

### Contexte actuel

- `compositors/ingame/wlr_compositor.cpp` : 6424 lignes, class `WlrCompositor`
  (1149 lignes dans `wlr_compositor.h`), plusieurs structs helper
  (`CaptureCache`, `SurfaceCommitTracker`, `WlrCompositorToplevelSource`,
  `PopupState`, `LayerSurfaceState`, `SessionLockState`, `IdleInhibitorState`,
  `WindowCursorState`).
- Les méthodes membres sont toutes déclarées dans `WlrCompositor` (membres
  privés) → le découpage par domaine ne nécessite aucune modification de visibilité.
- `SConstruct` compile via `Glob("compositors/ingame/*.cpp")` → pas de modif de build.

### Approche retenue : découpe par domaine

Le header `wlr_compositor.h` ne change **pas** (déclarations inchangées ; pas de
redécoupage de `_bind_methods()`). Le `.cpp` est éclaté en TU, chacune
implémentant un sous-ensemble de méthodes membres + les statics de fichier qui
leur appartiennent.

### Fichiers résultants

| Fichier | Contenu | ~Lignes |
|---|---|---|
| `wlr_compositor.cpp` (réduit) | `_bind_methods()`, cycle de vie (`start_headless`, `_process`), helpers registry (`find_window`, `find_popup`, `find_layer_surface`, `get_time_msec`), app launching/portals/dbus/polkit, `present_viewport_frame`, gestion socket/output | ~2200 |
| `cap_surface.cpp` | `check_dmabuf_linear_available`, `probe_dmabuf_vulkan_import`, `capture_surface` (+3 chemins `_dmabuf`/`_vulkan`/`_pixels`), `wait_for_dmabuf_gpu_writes`, `capture_crop_box`, `CaptureCache::reset`, constantes capture (pression, intervalles), `submit_video_frame`, `get_window_cpu_image`, `set_cpu_capture_requested` | ~1300 |
| `cap_image_source.cpp` | protocole `ext_foreign_toplevel_image_capture_source_v1` : `toplevel_source_*`, `toplevel_cursor_*`, manager bind/create/destroy, `update_toplevel_source_constraints`, `blit_toplevel_capture`, `update_toplevel_cursor`, `destroy_toplevel_image_source` | ~450 |
| `input.cpp` | maps `GODOT_TO_EVDEV`/`NUMPAD_EVDEV`, impl clavier virtuel, `on_keyboard_key`/`on_keyboard_modifiers`, `forward_keyboard_key`, `release_all_keys`, `reload_keymap`, layout clavier, focus clavier, pointeur (constraints/lock/pinch/relative), curseur (`on_cursor_*`, `on_request_set_cursor`, `capture_window_cursor`, `clear_window_cursor`, `get_window_cursor`, `set_window_pointer`, `get_window_pointer`), `set_cursor_position/visible`, `window_pointer_locked`, PID audio share | ~1400 |
| `window.cpp` | flux toplevel : `on_new_toplevel`, xdg-decoration, `SurfaceCommitTracker` (+`sync_window_subsurfaces`), `on_surface_commit`, `on_toplevel_*`, `on_request_*` (fullscreen/maximize/minimize/move/resize), popups (`wire_popup`, `on_popup_*`, `focus_surface`, `restore_focus_after_popup`, `emit_popup_mapped`), `on_new_constraint`, drop targets, windows list/geometry | ~1600 |
| `layer_shell.cpp` | `arrange_layer_surfaces`, `focus/unfocus_layer_surface`, `on_new_layer_surface` + handlers map/unmap/destroy/commit/popup, `layer_apply_exclusive`, `get_layer_surface_info`, `close_layer_surface`, `get_keyboard_focus_layer_id`, `apply_content_opacity` | ~400 |
| `session_lock.cpp` | `ext-session-lock-v1` complet : `session_lock_active`, `get_active_lock_surface`, `on_new_session_lock`, `on_session_lock_*` | ~200 |
| `idle.cpp` | idle notif/inhibit : `notify_activity`, `update_idle_inhibited`, `on_new_idle_inhibitor`, `on_idle_inhibitor_*` | ~90 |
| `drag_drop.cpp` | DnD de fichiers : `on_request_start_drag`, `on_start_drag`, `on_drag_destroy`, `extract_file_drop_start`, `_finish_file_drop`, pressepapier (`on_request_set_selection`, `on_request_set_primary_selection`), `is_drag_active` | ~230 |

### Règles de migration

1. Les **statics de fichier** sont déplacés vers la TU qui les consomme (les
   maps de keycode vont dans `input.cpp`, `capture_crop_box` dans `cap_surface.cpp`).
2. Toute **fonction statique utilisée par plusieurs TU** doit rester
   accessible : soit conservée dans le fichier principal, soit promue inline
   dans le header (aucun cas connu aujourd'hui).
3. `_bind_methods()` reste intégralement dans `wlr_compositor.cpp` : il
   référence les méthodes par nom (chaîne) — la dispersion des définitions ne
   change rien.
4. Les **constantes** propres à un domaine (`capture_pressure`, intervalles)
   migrent avec lui ; les constantes partagées restent dans le fichier
   principal ou montent dans le header.
5. Aucune modification de comportement : c'est un déplacement de code, pas une
   réécriture. La porte de validation est la compilation `scons` inchangée.

### Critère d'acceptation Partie 1

- `scons -j$(nproc)` compile sans erreur ni warning nouveau.
- `git diff` sur `wlr_compositor.cpp` = uniquement les fonctions déplacées en
  moins ; le header est intact.

---

## Partie 2 — Sécurisation du protocole LAN

### État actuel

- Auth PIN déjà en place dans `lan_manager.gd` (`pin_changed`, `_generate_pin`,
  `auth_request`/`auth_result`, `_pending_auth`, `AUTH_TIMEOUT_MSEC`).
- Transport : `ENetMultiplayerPeer.create_server/create_client` en clair.

### Contraintes Godot 4.7 (vérifiées dans le code source local)

- `ENetMultiplayerPeer` expose `host` (`ENetConnection.get_host()`).
- `ENetConnection` a `dtls_server_setup(server_options)` et
  `dtls_client_setup(hostname, client_options)`.
- `create_client()` crée le host ET appelle `connect_to_host()` en interne ;
  mais aucune donnée n'est émise avant le premier `poll()` → on peut appeler
  `host.dtls_client_setup(...)` immédiatement après `create_client()` sans
  broken window.
- Le mode mesh (`create_mesh` + `add_mesh_peer`) est le fallback documenté si
  le timing ci-dessus s'avérait cassé en pratique.

### Design

**Certificats embarqués** (`Game/source/certs/`) : un cert auto-signé
`lan_cert.crt` + clé `lan_key.pem` générés une fois et commités au dépôt.
Documentation : « le PIN est l'authentification, DTLS apporte la
confidentialité sur un LAN ». Rotation : hors scope (optionnel par nature).

**Hôte** (menu pause : toggle « Chiffrement » défaut ON) :
```
peer.create_server(PORT, MAX_PLAYERS, 8)
if encryption_enabled:
    var opts := TLSOptions.server(key, cert)
    peer.host.dtls_server_setup(opts)
```

**Client** :
```
peer.create_client(ip, PORT, 8)
if discover_result.encrypted:   # annoncé par la découverte UDP
    var opts := TLSOptions.client(cert)   # pinning du cert embarqué
    peer.host.dtls_client_setup(ip, opts)
```
- La **découverte** (_responder/_scanner) annonce `encrypted: bool` dans le
  paquet de réponse.
- Un client ne supportant pas DTLS refuse de joindre un hôte chiffré (message
  clair) et vice-versa.

**Durcissement anti brute-force PIN** :
- Côté hôte, compteur d'échecs par adresse ; au-delà de `PIN_FAIL_LIMIT = 3`,
  blacklist temporaire de l'adresse (`PIN_BLACKLIST_MSEC = 30000`). Les
  `auth_request` d'une adresse blacklistée sont ignorés (et le peer
  déconnecté). Le compteur est réarmé à un succès.

### Critère d'acceptation Partie 2

- Hôte chiffré + client chiffré : session fonctionnelle, PIN ok.
- Hôte chiffré + client non chiffré : refus coté client avec message.
- 3+ échecs de PIN depuis un peer : déconnexion + blacklist temporaire.

---

## Partie 3 — Gestion d'erreurs réseau

### Problèmes observés

- `_on_connection_failed` / `_on_server_disconnected` font un teardown complet
  sans tentative de reprise.
- Pas de distinction entre « l'hôte a quitté proprement » et « l'hôte est
  injoignable/réseau cassé ».
- Pas de timeout applicatif explicite côté hôte pour des clients zombie.

### Design

**Heartbeat applicatif** (hôte→clients) :
- RPC fiable et léger `_host_heartbeat()` toutes les `HEARTBEAT_INTERVAL_MSEC
  = 1000` ms quand la session est active.
- Client : horodate `_last_heartbeat_msec` ; si
  `now - last > HOST_HEARTBEAT_TIMEOUT_MSEC = 4000` → l'hôte est considéré
  injoignable → bascule en état `_reconnecting` (sauf si une déconnexion
  propre a déjà eu lieu).

**Graceful shutdown** : quand l'hôte ferme sa session (menu), il broadcast
`session_closed` RPC (reliable) avant `_disconnect_session()`. Les clients
reçoivent le signal → teardown propre SANS reconnexion.

**Reconnexion automatique (client)** :
- Nouvel état `_reconnecting : bool`, avec `_reconnect_ip`, `_reconnect_pin`.
- Déclencheurs : `_on_heartbeat_timeout` OU `_on_server_disconnected` (si pas
  de `session_closed` reçu).
- Boucle : retenter `join_game(_reconnect_ip, _reconnect_pin)` avec backoff
  exponentiel `0.5 → 1 → 2 s` + jitter aléatoire ±30 %, plafonné à
  `RECONNECT_WINDOW_MSEC = 30000` et `RECONNECT_MAX_ATTEMPTS = 12`.
- À chaque échec : statut « Reconnexion… (n/N) ». Au succès : le `auth`
  naturel de `_on_connected_to_server` reprépend la session (le niveau est
  re-téléchargé via les mécanismes existants).
- Si la fenêtre expire : teardown complet (`_disconnect_session`) + retour au
  niveau local + message clair.

**Timeout initial de join** : à `join_game`, si `connection_failed` survient
avant toute session établie → message explicite et PAS de reconnexion auto
(déjà l'existant, conservé).

### Critère d'acceptation Partie 3

- `server_disconnected` sans `session_closed` → boucle de reconnexion puis
  retour niveau local après échec.
- `session_closed` → teardown immédiat, pas de reconnexion.
- Hôte injoignable (kill du process hôte) → détection au heartbeat ≤ 5 s,
  reconnexion auto dès le retour de l'hôte.

---

## Partie 4 — Tests

### Tests GDScript (étendus dans `Game/source/tests/`)

La logique de reconnexion, heartbeat et blacklist est extraite en fonctions
pures/déterministes pour être testable sans réseau :

- `backoff_delay(attempt) -> float` : 0.5·2^attempt · jitter seedé.
- `should_reconnect(last_heartbeat_msec, now, session_closed_received, window, attempts) -> bool`.
- `is_pin_blacklisted(addr, blacklist, now_msec) -> bool` et mise à jour du compteur.
- `pin_attempt(addr, pin, expected, state) -> {ok, blacklisted, disconnect}`.

Nouveaux cas de test :
- `test_lan_protocol.gd` : `test_backoff_schedule`, `test_should_reconnect_logic`,
  `test_pin_blacklist`.
- `test_pin_blacklist` : 3 échecs → déconnecté + blacklisté ; 1 succès réarme.

### Portes de validation

1. `cd /home/adrien/Projets/CyberRealm && scons -j$(nproc)`
2. `cd Game/source && godot --headless --script tests/runner.gd` → 0 échec.

---

## Fichiers touchés

- `compositors/ingame/wlr_compositor.cpp` (réduit) + nouveaux `cap_surface.cpp`,
  `cap_image_source.cpp`, `input.cpp`, `window.cpp`, `layer_shell.cpp`,
  `session_lock.cpp`, `idle.cpp`, `drag_drop.cpp`.
- `compositors/certs/lan_cert.crt` + `lan_key.pem` (embarqués).
- `Game/source/scripts/lan_manager.gd` (DTLS, blacklist, heartbeat,
  reconnexion, backoff, `session_closed`).
- `Game/source/scripts/pause_menu.gd` (toggle chiffrement, statut reconnect).
- `Game/source/scripts/wayland_room.gd` (wiring si nécessaire).
- `Game/source/tests/test_lan_protocol.gd` (+ helpers testables).
- `SConstruct` : inchangé (Glob).

## Hors scope

- Pas de rotation de certificats ni de PKI.
- Pas de reconnexion côté hôte (les clients se reconnectent).
- Pas de chiffrement applicatif hors DTLS (pas de cryptage ad hoc des payloads).