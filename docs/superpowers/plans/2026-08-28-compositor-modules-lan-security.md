# Découpe Compositor + Sécurisation LAN + Gestion Erreurs Réseau

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Découper `wlr_compositor.cpp` en modules par domaine, chiffrer le protocole LAN par DTLS (+ durcissement PIN) et ajouter la reconnexion automatique/heartbeat côté client.

**Architecture:** La classe `WlrCompositor` reste unique (header intact) ; ses 321 méthodes membres sont réparties dans 8 TU par domaine sans changement de comportement. Côté GDScript, `lan_manager.gd` gagne DTLS (via `ENetConnection.dtls_*_setup`), un anti brute-force PIN et une machine à états de reconnexion/heartbeat.

**Tech Stack:** C++ (wlroots 0.19, godot-cpp 4.7, Vulkan, VAAPI), GDScript, ENetHighLevelMultiplayer, DTLS (mbedTLS via Godot), scons.

**Spec:** `docs/superpowers/specs/2026-08-28-compositor-modules-lan-security-design.md`

## Global Constraints

- Header `wlr_compositor.h` **inchangé** (déclarations/membres intacts).
- `SConstruct` **inchangé** : il compile `Glob("compositors/ingame/*.cpp")` ; les nouveaux .cpp sont pris automatiquement.
- `_bind_methods()` reste intégralement dans `wlr_compositor.cpp`.
- Aucun changement de comportement du compositor : la découpe = déplacement de code.
- Toute fonction statique de fichier partagée par plusieurs TU reste dans `wlr_compositor.cpp` ou monte dans le header (aucun cas attendu).
- PIN = factor d'authentification, DTLS = confidentialité. PAS de chiffrement ad hoc des payloads.
- Cert inst/deploy : `Game/source/certs/lan_cert.crt` + `lan_key.pem`.
- Build : `cd /home/adrien/Projets/CyberRealm && scons -j$(nproc)`.
- Tests : `cd Game/source && godot --headless --script tests/runner.gd` (depuis `Game/source`, jamais depuis la racine).
- GDScript : fonctions sans annotation de retour si elles retournent `bool`/`String` de façon polymorphe ; pas de `:=` vers un retour `Variant`.

---

## Phase A — Découpe du compositor C++

Chaque tâche A est un déplacement pur. **Stratégie commune** : dans la TU cible, inclure `wlr_compositor.h` + les mêmes headers que la fonction utilisait, préfixer `using namespace godot;`, copier les définitions membres + leurs statics de fichier, puis supprimer ces définitions de `wlr_compositor.cpp`. Après CHAQUE tâche : `scons -j$(nproc)` doit compiler sans erreur ET l'exécutable se comporte identiquement.

Ordre d'exécution indispensable : traiter d'abord les TU qui ne partagent pas de statics, garder les statics partagées dans le fichier principal tant qu'une 2e TU ne les consomme pas.

### Task A1: cap_surface.cpp — pipeline de capture pixmap

**Files:**
- Create: `compositors/ingame/cap_surface.cpp`

**Interfaces:**
- Consumes: membres `WlrCompositor` existants (`renderer, allocator, gpu_pipeline_active, compositor, capture_pressure…`), `CaptureCache` (déjà dans le header).
- Produces: définitions de `check_dmabuf_linear_available`, `probe_dmabuf_vulkan_import`, `capture_surface`, `capture_surface_dmabuf`, `capture_surface_vulkan`, `capture_surface_pixels`, `submit_video_frame`, `get_window_cpu_image`, `set_cpu_capture_requested`, `CaptureCache::reset`.

- [ ] **Step 1: Créer `cap_surface.cpp` avec l'en-tête et les includes**
  Inclure `wlr_compositor.h` + headers wlroots (buffer, render, dmabuf, pass, renderer, box, drm_fourcc, subcompositor, linux_dmabuf) + `<sstream>`/`<fstream>` nécessaires + `using namespace godot;`. Copier les **statics de fichier dédiées au domaine** : `round_up_capture_size`, `wait_for_dmabuf_gpu_writes`, `capture_crop_box`, et les constantes `CAPTURE_*`, `SLOW_/FAST_INTERVALS_US`, `MAX_WINDOW_CAPTURES_PER_FRAME`, `WINDOW_SAFETY_RECAPTURE_INTERVAL`. (Laisser `LAYER_SAFETY_RECAPTURE_INTERVAL` et `PINCH_END_TIMEOUT_MS` au fichier principal si non utilisées ici — vérifier.)
- [ ] **Step 2: Supprimer ces définitions de `wlr_compositor.cpp`**
  (lignes ~668-1945 : `check_dmabuf_linear_available` → fin de `capture_surface_pixels`, ainsi que `CaptureCache::reset` ligne 769, `submit_video_frame` 5953, `get_window_cpu_image` 5847, `set_cpu_capture_requested` 5860). Retirer les statics déplacées.
- [ ] **Step 3: Build de vérification**
  `cd /home/adrien/Projets/CyberRealm && scons -j$(nproc)` → 0 erreur.
- [ ] **Step 4: Commit**
  `git add compositors/ingame && git commit -m "refactor(compositor): extraire cap_surface.cpp"`

### Task A2: cap_image_source.cpp — capture fenêtres (foreign toplevel)

**Files:**
- Create: `compositors/ingame/cap_image_source.cpp`

**Interfaces:**
- Consumes: `WlrCompositorToplevelSource` struct (header), `wlr_ext_image_capture_source_v1_interface`.
- Produces: `toplevel_source_start/stop/schedule_frame/copy_frame`, `toplevel_cursor_*`, `toplevel_source_get_pointer_cursor`, interfaces statiques `toplevel_cursor_impl`/`toplevel_source_impl`/`foreign_toplevel_source_manager_impl`, `on_foreign_toplevel_source_manager_*`, `update_toplevel_source_constraints`, `blit_toplevel_capture`, `update_toplevel_cursor`, `destroy_toplevel_image_source`.

- [ ] **Step 1: Créer `cap_image_source.cpp`**
  Inclure `ext-image-capture-source-v1-protocol.h` + `#include "ext-foreign-toplevel-image-capture-source-v1-protocol.h"` si généré (vérifier le nom du header généré dans compositors/protocols/). Copier les 8 fonctions membres et les 3 `static const …_interface` (lignes 65-199, 2249-2450).
- [ ] **Step 2: Supprimer de `wlr_compositor.cpp`** les lignes 59-199 (bloc manager+toplevel) et 2249-2450 (`update_toplevel_source_constraints`→`destroy_toplevel_image_source`).
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A3: input.cpp — clavier, pointeur, curseur

**Files:**
- Create: `compositors/ingame/input.cpp`

**Interfaces:**
- Consumes: `pressed_keys`, `window_pointer_locked`, `window_cursor`, `WindowCursorState`, `cursor_image_*`, `cursor_*`, `pinch_*`.
- Produces: `GODOT_TO_EVDEV`, `NUMPAD_EVDEV`, `waylandgodot_KEYBOARD_IMPL`, `waylandgodot_keyboard_led_update`, `on_keyboard_key/modifiers`, `forward_keyboard_key`, `release_all_keys`, `reload_keymap`, `set/get_keyboard_layout`, `set_window_keyboard_focus`, `on_new_constraint`, `is_window_pointer_locked`, `get_window_pid`, `set_audio_share_pids`, tous les `forward_pointer_*`, `on_pointer_grab_*`, `on_request_set_cursor`, `on_cursor_surface_*`, `capture_window_cursor`, `clear_window_cursor`, `get_window_cursor`, `set_cursor_position/visible`, `set_window_pointer`, `get_window_pointer`, `forward_pointer_relative_motion`, `ensure_cursor_image_buffer` (statique `cursor_debug_enabled`).

- [ ] **Step 1: Créer `input.cpp`**
  Copier les définitions (lignes 205-303 maps+impl, 1951-1962 key, 4202-4730 bloc pointeur/clavier, 5016-5352 curseur). Déplacer les statics `GODOT_TO_EVDEV`, `NUMPAD_EVDEV`, `waylandgodot_KEYBOARD_IMPL`, `waylandgodot_keyboard_led_update`, `cursor_debug_enabled`.
- [ ] **Step 2: Supprimer les originaux de `wlr_compositor.cpp`**.
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A4: window.cpp — toplevel, popups, décoration

**Files:**
- Create: `compositors/ingame/window.cpp`

**Interfaces:**
- Consumes: `windows`, `popups`, `WindowState`, `PopupState`, `SurfaceCommitTracker`, `active_toplevel_id`, `keyboard_focus_layer_id`.
- Produces: `SurfaceCommitTracker::on_commit/on_destroy`, `sync_window_subsurfaces`, `on_new_toplevel`, `on_new_toplevel_decoration`, `on_toplevel_decoration_*`, `on_toplevel_map/unmap/destroy/set_title`, `on_surface_commit`, `on_request_fullscreen/maximize/minimize/move/resize`, `wire_popup`, `on_new_popup`, `on_new_popup_from_popup`, `on_popup_*`, `focus_surface`, `restore_focus_after_popup`, `emit_popup_mapped`, `on_new_constraint` (si pas déjà dans input), `extract_file_drop_start` (si gardé ici).

- [ ] **Step 1: Créer `window.cpp`**
  Copier les définitions (lignes 1964-2200 toplevel, 2472-2908 surface commit + windows + popups + request_*, 5750-5860 set_window_size/fullscreen/geometry/list/close). Noter que `on_new_constraint` et `extract_file_drop_start` sont déclarés avec d'autres → décider leur maison (input.cpp pour le premier, drag_drop.cpp pour l'autre) et NE PAS les dupliquer.
- [ ] **Step 2: Supprimer les originaux de `wlr_compositor.cpp`**.
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A5: layer_shell.cpp — layer surfaces

**Files:**
- Create: `compositors/ingame/layer_shell.cpp`

**Interfaces:**
- Consumes: `layer_surfaces`, `next_layer_surface_id`, `output_width/height`, `headless_output`, `keyboard_focus_layer_id`.
- Produces: `layer_apply_exclusive`, `arrange_layer_surfaces`, `focus/unfocus_layer_surface`, `find_layer_surface` (si déplacé), `on_new_layer_surface`, `on_layer_surface_*`, `on_layer_new_popup`, `get_layer_surface_info`, `get_keyboard_focus_layer_id`, `close_layer_surface`, `apply_content_opacity`.

- [ ] **Step 1: Créer `layer_shell.cpp`**
  Copier (lignes 2922-3211 du bloc layer, 6355-6410 API layer). Déplacer `layer_apply_exclusive` + `LAYER_SAFETY_RECAPTURE_INTERVAL` si utilisé ici (sinon laisser).
- [ ] **Step 2: Supprimer les originaux de `wlr_compositor.cpp`**.
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A6: session_lock.cpp — lockscreen

**Files:**
- Create: `compositors/ingame/session_lock.cpp`

**Interfaces:**
- Consumes: `session_lock_manager`, `session_lock`, `SessionLockState`, `next_layer_surface_id`.
- Produces: `session_lock_active`, `get_active_lock_surface`, `on_new_session_lock`, `on_session_lock_new_surface`, `on_session_lock_surface_*`, `on_session_lock_unlock`, `on_session_lock_destroy`.

- [ ] **Step 1: Créer `session_lock.cpp`** (lignes 3213-3397).
- [ ] **Step 2: Supprimer les originaux de `wlr_compositor.cpp`**.
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A7: idle.cpp + drag_drop.cpp

**Files:**
- Create: `compositors/ingame/idle.cpp`, `compositors/ingame/drag_drop.cpp`

**Interfaces:**
- Consumes: `idle_inhibitors`, `IdleInhibitorState`, delight `on_request_start_drag`.
- Produces: `notify_activity`, `update_idle_inhibited`, `on_new_idle_inhibitor`, `on_idle_inhibitor_*` (idle.cpp) ; `on_request_start_drag`, `on_start_drag`, `on_drag_destroy`, `extract_file_drop_start`, `_finish_file_drop`, `on_request_set_selection`, `on_request_set_primary_selection`, `is_drag_active` (drag_drop.cpp).

- [ ] **Step 1: Créer `idle.cpp`** (lignes 4132-4202) + `drag_drop.cpp` (lignes 4773-4986).
- [ ] **Step 2: Supprimer les originaux de `wlr_compositor.cpp`**.
- [ ] **Step 3: Build** → 0 erreur.
- [ ] **Step 4: Commit**

### Task A8: Nettoyage final

- [ ] **Step 1: Vérifier qu'aucune fonction membre n'est définie deux fois**
  `grep -c "WlrCompositor::" compositors/ingame/*.cpp | sort` ; comparer la somme au total initial (321).
- [ ] **Step 2: Purger les includes devenus inutiles** dans `wlr_compositor.cpp` (les headers de capture n'y sont plus référencés).
- [ ] **Step 3: Build final** → 0 erreur.
- [ ] **Step 4: Commit**

---

## Phase B — Sécurisation LAN (DTLS + anti brute-force PIN)

Config/fixtures d'abord, puis tests TDD sur la logique pure, puis intégration.

### Task B1: Certificats embarqués

**Files:**
- Create: `Game/source/certs/lan_cert.crt`, `Game/source/certs/lan_key.pem`

- [ ] **Step 1: Générer cert auto-signé (10 ans, CN "CyberRealm LAN")**
  `openssl req -x509 -newkey rsa:2048 -nodes -keyout Game/source/certs/lan_key.pem -out Game/source/certs/lan_cert.crt -days 3650 -subj "/CN=CyberRealm LAN" -addext "subjectAltName=IP:0.0.0.0"`
- [ ] **Step 2: Commit**
  `git add Game/source/certs && git commit -m "chore: certs DTLS embarqués pour LAN"`

### Task B2: Helpers tests DTLS/backoff/blacklist (TDD)

**Files:**
- Modify: `Game/source/tests/test_lan_protocol.gd`

**Interfaces:**
- Consumes: rien de nouveau.
- Produces: fonctions pures dans `lan_manager.gd` : `backoff_delay(attempt:int)->float`, `should_reconnect(last_heartbeat_msec, now, session_closed_received, window_msec, attempts)->bool`, `pin_attempt(addr, ok, state:Dictionary)->bool` (retourne `true` si rejet). L'état blacklist est une `Dictionary` externe passée en paramètre pour testabilité.

- [ ] **Step 1: Écrire les tests qui échouent** dans `test_lan_protocol.gd`

Rappel : ajouter en tête du fichier le preload du script à tester (le fichier
`test_lan_protocol.gd` commence par `const Runner = preload("res://tests/runner.gd")`) :

```gdscript
const LANManager = preload("res://scripts/lan_manager.gd")
```

```gdscript
func test_backoff_schedule():
	var r = true
	for a in range(0, 7):
		var d = LANManager.backoff_delay(a)
		if d < 0.0 or d > 2.5:
			r = false
	return r

func test_backoff_grows():
	var r = true
	var prev = LANManager.backoff_delay(0)
	for a in range(1, 6):
		var d = LANManager.backoff_delay(a)
		if d <= prev:
			r = false
		prev = d
	return r

func test_should_reconnect_yes():
	var r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, false, 30000, 2), true, "heartbeat expiré → reconnect")
	if r != true: return r
	r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, false, 30000, 12), false, "window épuisée → abandon")
	if r != true: return r
	r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, true, 30000, 2), false, "session_closed → pas de reconnect")
	return true

func test_pin_blacklist():
	var state := {}
	var r = true
	for i in range(3):
		if LANManager.pin_attempt("1.2.3.4", false, state) == true:
			r = false
	if r != true: return "doit échouer seulement au 3e"
	if LANManager.pin_attempt("1.2.3.4", false, state) == false:
		return "3e échec doit rejeter"
	if LANManager.pin_attempt("1.2.3.4", true, state) == false:
		return "un succès réarme"
	return true
```
  (Note : `LANManager` = `preload("../scripts/lan_manager.gd")` ; vérifier le chemin. Si `lan_manager.gd` est `extends Node` avec `setup`, les fonctions statiques doivent être `static func`. Adapter en conséquence dans B3.)
- [ ] **Step 2: Runer → attendu FAIL** (fonctions inexistantes).
- [ ] **Step 3: Implémenter les 3 fonctions pures + helpers dans `lan_manager.gd`** (top du fichier, `static func`)
```gdscript
const RECONNECT_WINDOW_MSEC := 30000
const RECONNECT_MAX_ATTEMPTS := 12
const HEARTBEAT_INTERVAL_MSEC := 1000
const HOST_HEARTBEAT_TIMEOUT_MSEC := 4000
const PIN_FAIL_LIMIT := 3
const PIN_BLACKLIST_MSEC := 30000

static func backoff_delay(attempt: int) -> float:
	var base := 0.5 * pow(2.0, float(attempt))
	var jitter := randf_range(-0.3, 0.3) * base
	return clampf(base + jitter, 0.0, 2.5)

static func should_reconnect(last_hb: int, now: int, closed: bool, window: int, attempts: int) -> bool:
	if closed or attempts >= RECONNECT_MAX_ATTEMPTS:
		return false
	if attempts == 0:
		return true
	return (now - last_hb) <= window

static func pin_attempt(addr: String, ok: bool, state: Dictionary) -> bool:
	if ok:
		state.erase(addr)
		return false
	var fails: int = int(state.get(addr, 0)) + 1
	state[addr] = fails
	return fails >= PIN_FAIL_LIMIT
```
- [ ] **Step 4: Runer → PASS.** Commit : `git add Game/source/tests/test_lan_protocol.gd Game/source/scripts/lan_manager.gd && git commit -m "test: helpers backoff/reconnect/blacklist LAN"`

### Task B3: Intégration DTLS hôte+client + blacklist runtime

**Files:**
- Modify: `Game/source/scripts/lan_manager.gd`
- Modify: `Game/source/scripts/pause_menu.gd`
- Modify: `Game/source/scripts/wayland_room.gd`

**Interfaces:**
- Consumes: les constantes B2, `multiplayer.multiplayer_peer.host` (ENetConnection).
- Produces: `var encryption_enabled := true` (export set depuis pause_menu) ; `_pin_blacklist := {}` (Dictionary : IP dernière échec msec) ; helpers `_load_dtls_options()` (hôte) et `_dtls_client_options()` ; `_on_pin_fail(ip)` appliquant `pin_attempt`.

- [ ] **Step 1: Hôte** — dans `host_game()`, après `create_server`, si `encryption_enabled` :
```gdscript
var key := load("res://certs/lan_key.pem") as CryptoKey
var cert := load("res://certs/lan_cert.crt") as X509Certificate
if key != null and cert != null:
	var opts := TLSOptions.server(key, cert)
	peer.host.dtls_server_setup(opts)
```
- [ ] **Step 2: Client** — dans `join_game(ip, pin, encrypted:bool=false)`, après `create_client`, si `encrypted` :
```gdscript
var cert := load("res://certs/lan_cert.crt") as X509Certificate
if cert != null:
	peer.host.dtls_client_setup(ip, TLSOptions.client(cert))
```
- [ ] **Step 3: Blacklist runtime** — dans `auth_request` (côté hôte), capturer l'adresse du peer via `(multiplayer.multiplayer_peer as ENetMultiplayerPeer).host.get_peer(from).get_remote_address()` (ou `get_peer(from).get_remote_address()`), sur échec PIN appeler `_on_pin_fail(ip)` ; si blacklisté → `disconnect_peer` + log. Au-delà de `PIN_BLACKLIST_MSEC` sans nouvel échec, l'entrée est purgée.
- [ ] **Step 4: Toggle UI** — dans `pause_menu.gd`, ajouter un checkbox « Chiffrement TLS » lié à `lan.encryption_enabled` ; dans `wayland_room.gd`, transmettre `encrypted` dans le trajet `lan_join_requested` (le paquet de découverte existant porte déjà l'info) ; renvoyer `lan.join_game(ip, pin)` → `lan.join_game(ip, pin, encrypted)`.
- [ ] **Step 5: Build/tests** — `scons` + runner → 0 échec. **Validation manuelle** (documentée, hors CI) : hôte chiffré + client chiffré = session OK ; hôte chiffré + client non chiffré = refus clair ; 3 échecs PIN = déconnexion+blacklist.
- [ ] **Step 6: Commit**
  `git add Game/source/scripts && git commit -m "feat(lan): chiffrement DTLS optionnel + anti brute-force PIN"`

---

## Phase C — Reconnexion auto + heartbeat

### Task C1: Heartbeat + session_closed

**Files:**
- Modify: `Game/source/scripts/lan_manager.gd`

**Interfaces:**
- Consumes: constantes B2.
- Produces: `_last_heartbeat_msec := 0`, `_session_closed_received := false`, RPCs `_host_heartbeat()` (authority, reliable, cron toutes les 1 s via `_process`) et `session_closed()` (any_peer).

- [ ] **Step 1: Hôte** — dans `_process` (ou timer), si `is_host and session_active`, émettre `_host_heartbeat.rpc()` toutes `HEARTBEAT_INTERVAL_MSEC` ; dans `disconnect_session()` public, avant `_disconnect_session()`, si hôte : `session_closed.rpc()`.
- [ ] **Step 2: Client** — `_host_heartbeat` (côté client) : `_last_heartbeat_msec = Time.get_ticks_msec()` ; `session_closed` : `_session_closed_received = true`.
- [ ] **Step 3: Build + runner** → 0 échec. Commit.

### Task C2: Machine à états de reconnexion

**Files:**
- Modify: `Game/source/scripts/lan_manager.gd`

**Interfaces:**
- Consumes: `should_reconnect` (B2), `_reconnect_ip/_reconnect_pin`, heartbeat (C1).
- Produces: `var _reconnecting := false`, `_reconnect_attempts := 0`, `_reconnect_ip := ""`, `_reconnect_pin := ""` ; `_begin_reconnect()` ; hook dans `_process` pour heartbeat timeout ; hook dans `_on_server_disconnected` et `_disconnect_session`.

- [ ] **Step 1: Capture contexte** — dans `_on_connected_to_server` (succès), enregistrer `_reconnect_ip`/`_reconnect_pin` et `_session_closed_received=false` ; réinitialiser `_reconnect_attempts=0` et `_reconnecting=false`.
- [ ] **Step 2: Détection timeout** — dans `_process`, côté client non-hôte et `session_active` : si `now - _last_heartbeat_msec > HOST_HEARTBEAT_TIMEOUT_MSEC` → `_begin_reconnect()`.
- [ ] **Step 3: `_begin_reconnect()`**
```gdscript
func _begin_reconnect() -> void:
	if _reconnecting or _session_closed_received or _reconnect_ip == "":
		return
	_reconnecting = true
	_reconnect_attempts += 1
	var delay := backoff_delay(_reconnect_attempts - 1)
	await get_tree().create_timer(delay).timeout
	if not session_active:
		return
	_set_status("Reconnexion… (%d/%d)" % [_reconnect_attempts, RECONNECT_MAX_ATTEMPTS])
	_disconnect_session(keep_context=true)
	join_game(_reconnect_ip, _reconnect_pin, _last_join_encrypted)
```
  (Adapter `_disconnect_session` pour accepter un flag `keep_context=true` qui ne nettoie PAS `_reconnecting`/`_reconnect_*` et ne force pas la restauration du niveau local si on repart en reconnexion.)
- [ ] **Step 4: Hook déconnexion** — dans `_on_server_disconnected` : si `should_reconnect(_last_heartbeat_msec, now, _session_closed_received, RECONNECT_WINDOW_MSEC, _reconnect_attempts)` → `_begin_reconnect()` ; sinon `_disconnect_session()` normal.
- [ ] **Step 5: Window épuisée** — dans `_begin_reconnect`, si `_reconnect_attempts >= RECONNECT_MAX_ATTEMPTS` ou fenêtre expirée → reset `_reconnecting=false`, `_reconnect_ip=""`, `_disconnect_session()` complet + message « Hôte injoignable — retour au niveau local ».
- [ ] **Step 6: Auth réutilisé** — le rejoin repasse par `_on_connected_to_server` qui renvoie `auth_request` → session reprise via mécanismes existants. Dans `_on_connected_to_server`, quand `_reconnecting`, mettre à jour les compteurs.
- [ ] **Step 7: Build + runner** → 0 échec. Commit.

### Task C3: Purge slots reconnectables (hôte)

**Files:**
- Modify: `Game/source/scripts/lan_manager.gd`

- [ ] **Step 1**: côté hôte `_on_peer_disconnected`, vider aussi les clés du peer dans `_avatar_send_queue`, `_level_send_queue`, `_video_*` si absentes (vérifier l'existant ligne 1413-1442 et compléter).
- [ ] **Step 2: Build + runner** → 0 échec. Commit.

---

## Phase D — Vérification finale

### Task D1: Passes de validation

- [ ] **Step 1**: `cd /home/adrien/Projets/CyberRealm && scons -j$(nproc)` → 0 erreur.
- [ ] **Step 2**: `cd Game/source && godot --headless --script tests/runner.gd` → 0 échec (≥ 36 tests).
- [ ] **Step 3**: `git status` propre (rien de non committé non voulu).
- [ ] **Step 4**: Mise à jour éventuelle de `README.md` si la commande de test ou les certs le requièrent.

---

## Ordre et dépendances

- A1→A8 : MAIS le découpage C++ est **indépendant** des phases B/C (fichiers distincts). On peut exécuter A puis B/C, ou B/C avant A. Recommandation : terminer A (risque de builds) d'abord, ensuite B, C, D.
- B2 précède B3 (helpers avant intégration).
- C1 précède C2 (heartbeat avant machine à états).
- Les fonctions statiques de `lan_manager.gd` étant ajoutées en B2, vérifier que `lan_manager.gd` étend `Node` et que les `static func` n'accèdent à rien d'instance.