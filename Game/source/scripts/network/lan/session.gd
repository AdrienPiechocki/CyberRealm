extends Node
## Session LAN : DTLS, PIN, mode online (TLS vérifié, authentification moteur), heartbeat,
## reconnexion, administrateur.
##
## Module de LanManager (nœud enfant « Session »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

# ── DTLS : paire auto-signée EMBARQUÉE (pas de fichiers dans res://) ────
# Godot exclut les clés privées (CryptoKey) du pck exporté, même en
# all_resources → les fichiers res://certs/ ne sont jamais fiables à
# l'export. On embarque donc la paire dans le script (script_export_mode=0
# → le texte suit dans le pck), on l'écrit dans user:// au premier hébergement,
# et client_unsafe (pas de validation de la chaine) rend la chose indifférente
# au fait que la clé est lisible : l'AuthN mutuelle est assurée par le PIN.
const DTLS_KEY_PEM := "-----BEGIN PRIVATE KEY-----\nMIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQCttTJS4jpY1ODM\n1CYtu95H2MCtNMxYUCU4dKMrwUhq+sVx6IFILhFJwnSDYHUpszwkWqpqSFOXt7x0\nbOqn+eqvI0gvastxEXpU0uJrN31CFjKWBofN3+D5MrWnFxDRlmkfxdYIWBMLg+lE\nPFDCVvku5NfjswoVzFod0lyVKNoPXmemEfUDgbrwaPPGLGMM4HKnmcN7Vmqb+yuT\nmC0DJJ4MjdGbGCfr1GpIZbhYq83TkSfF++HPPoZApCFg0m4GGWm78xqzvLIdObi/\nmDhvP8HyW45PdhT1r27+nG1pEH8fZQv5B5+uwaI5XEqUy+VjW1mB1vpirMf2Ruaf\nV36T3KGrAgMBAAECggEAQcymUGEjiuywbsZZ4+8LJxoC+llKopVRVA5SlMt1XBi7\n3AcfmbDhmZgQPIe4OeCMApVZgkL9bzYJK+zqAlEXxdnOiS+h+qWNOj5byBNP3k28\nQbodjS2l8Z900eNZ2ppoHcH57lU2eaExJkjWqpb5cvr6kGUMh+9Nn4hEy7eaykDv\nrR7660Bsgy7E3vrmj2vwGGQIiBaQzjoSbA1nhUnv93fhLtjh2o/WkmoA5+zUNTsI\nYelUpdu03wtcsHjVO3iCi2lsNn6zewK5Cn+Hla2oNP0ZkQI6VEH9yrbqn/6kNaVP\nbpm1Xud7WOViiaXexeHb9czJgmVoC90sWOCwVo83MQKBgQDTzCZftNOQFSlpZV8C\nXmo7IxsKW//uvdxbrTudTPcyLZg0+f5gnmsRPlHSsgJAKO6v6JSVhOfs6oSyY9my\n03m/BF5zSga0Oy4hCObDeqOmsRcZ4x+RNSAQVgwHzGM6lUs9Gg55l+1o6ZgQ18JT\nQc38O9WiyTuBUVn2OSPnkDEY2QKBgQDR9gD9rLFoafdIUiQD27I6e+ycTxUN3AHz\nsTGYS2Z8grfwMRbNJ7admjxzm/tL9OksLIrMDnEC4lsU/DFbxqXAOqjBm1LfCs6o\nSxmrwzuItk669RmrVe3BtcRDgrKbeoDgqRHrQHibmnsmH9LsFjkQWRsj3HudULwO\nn6vEENKcIwKBgQCQgNclsVAvG+EXQcyi5xv/oSIP3Vku4Gb6PaVQ23REzgrtCive\na/eM2kIlSMJ0V/kSF9NYeEdsw00qESo08kg8ZZSzgCw2x7HfZB1d/cyuLGEgjm+5\nOM/ZlXu7zl1dWQLue1qo51lZnRbdVvgEqf8KOyC1YiqxPnnsnmu60AxPcQKBgQDM\nEO67n6o6Uqu+Rd+tRE3A3AuHjLFo7AmVogYTAE3W/HHsaLnBojSyj2Lr9pHTLHGo\nto4ccHjUlc5y4f7TNYqKADlfGyj7kZR0K7ICqFlnsdFpkqllRro0CQd9mj0gMnuq\nX4kD/oB6tDW3Qz0MqzjBM+nV/AjFSN/O0s/uW29nwwKBgQCQ/MoryfXD9U6aFSRR\nIzCYlpCQz7ZDhN9WWHLq+cW7w52UkSjTC9Bj4lIu6EawHHBNQKFpO3IRTpj6NzIv\nW8lY0oR4MkvYLWQdxRsVw9qkr9cj4OmmCf9DYioHpgGssjPZAT00wCknAFNfUwE5\nQnqVkTbUsHmmgTcoMMwDoT8O9g==\n-----END PRIVATE KEY-----\n"
const DTLS_CERT_PEM := "-----BEGIN CERTIFICATE-----\nMIIDJDCCAgygAwIBAgIUTyTDifJeXIwuvrgeQJYh1MGFPAQwDQYJKoZIhvcNAQEL\nBQAwGTEXMBUGA1UEAwwOQ3liZXJSZWFsbSBMQU4wHhcNMjYwODI4MjA1MjI2WhcN\nMzYwODI1MjA1MjI2WjAZMRcwFQYDVQQDDA5DeWJlclJlYWxtIExBTjCCASIwDQYJ\nKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK21MlLiOljU4MzUJi273kfYwK00zFhQ\nJTh0oyvBSGr6xXHogUguEUnCdINgdSmzPCRaqmpIU5e3vHRs6qf56q8jSC9qy3ER\nelTS4ms3fUIWMpYGh83f4PkytacXENGWaR/F1ghYEwuD6UQ8UMJW+S7k1+OzChXM\nWh3SXJUo2g9eZ6YR9QOBuvBo88YsYwzgcqeZw3tWapv7K5OYLQMkngyN0ZsYJ+vU\nakhluFirzdORJ8X74c8+hkCkIWDSbgYZabvzGrO8sh05uL+YOG8/wfJbjk92FPWv\nbv6cbWkQfx9lC/kHn67BojlcSpTL5WNbWYHW+mKsx/ZG5p9XfpPcoasCAwEAAaNk\nMGIwHQYDVR0OBBYEFN7nNrlafmMFIIqf0EgEBnkhL0k9MB8GA1UdIwQYMBaAFN7n\nNrlafmMFIIqf0EgEBnkhL0k9MA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0RBAgwBocE\nAAAAADANBgkqhkiG9w0BAQsFAAOCAQEANgH0HhBtOyD7hPNJQzKYUh1bMwxIw3A2\n3y0LwT3GsIel5vqrLBT2N+c5oaYez2eBKYMsALGaUhVn85A0PqtFMbchiN/mgXmP\nwdKtv7+NbUW+lz7GC1OHYoLwDFntVs3CYiQliFtwS/LIA1jX2GIjYX1Ix68U71/3\nxH/ZrlmPjyrFzGC6Py0BEb5uLe9ynyHqz+RVE/hRqWATmIckkEF1EThzeL5SKOpt\nk3CiPpmQMy8Xm3IJ0aSqp69sm73rGB2SLBN2yCzUoLP8P/njfURch5dRe2Vu6nOo\nh08dAqjapUbtp1Pr59hff7AyPIzpPVm03gHpSQ0atbN4XLjeOU//gA==\n-----END CERTIFICATE-----\n"
const DTLS_CREDS_NAME := "cyberrealm-lan"
# peer_id -> true : client en attente de vérification du PIN par l'hôte.
var _pending_auth: Dictionary = {}
const ONLINE_MIN_PASSWORD := 12
const ONLINE_LOCK_BASE_MSEC := 30000
const ONLINE_LOCK_MAX_MSEC := 3600000
const ONLINE_GLOBAL_ATTEMPTS := 40          # tentatives d'authentification max par minute, tous pairs confondus
var _auth_sent := false                     # client : mot de passe envoyé au serveur (échec ensuite = refus d'authentification)
var _online_fail: Dictionary = {}           # ip -> {count, level, until}
var _online_attempts: Array = []            # horodatages (ms) des tentatives récentes
# anti brute-force PIN : adresse IP -> timestamp (ms) du dernier échec (purge).
var _pin_blacklist: Dictionary = {}
# Compteur d'échecs PIN consécutifs par adresse (alimenté par pin_attempt).
var _pin_fail_counts: Dictionary = {}
# Chiffrement demandé pour le dernier join (réutilisé à la reconnexion).
var _last_join_encrypted := false
# ── Heartbeat / reconnexion (C1/C2) ──────────────────────────────────
var _last_heartbeat_msec := 0
var _session_closed_received := false
var _last_heartbeat_sent_msec := 0
var _reconnecting := false
var _reconnect_attempts := 0
var _reconnect_ip := ""
var _invite_cert := ""            # client : certificat épinglé du code d'invitation (vide : join classique)
var _reconnect_pin := ""
# Timeout de vérification PIN côté client (ms). Si l'hôte ne répond pas, déconnexion.
const AUTH_TIMEOUT_MSEC := 10000

# ── Reconnexion & anti brute-force PIN (B2) ──────────────────────────
const RECONNECT_WINDOW_MSEC := 30000
const RECONNECT_MAX_ATTEMPTS := 12
const HEARTBEAT_INTERVAL_MSEC := 1000
const HOST_HEARTBEAT_TIMEOUT_MSEC := 4000
const PIN_FAIL_LIMIT := 3
const PIN_BLACKLIST_MSEC := 30000

## Délai d'attente (secondes) avant la tentative de reconnexion n°attempt.
static func backoff_delay(attempt: int) -> float:
	var base := 0.5 * pow(2.0, float(attempt))
	var jitter := randf_range(-0.3, 0.3) * base
	return clampf(base + jitter, 0.0, 2.5)

## Décide si une reconnexion est encore pertinente. `closed` = on a reçu
## session_closed (l'hôte a fermé proprement → pas de reconnect). `attempts`
## = nombre de tentatives déjà effectuées. `window` = fenêtre de tolérance.
static func should_reconnect(last_hb: int, now: int, closed: bool, window: int, attempts: int) -> bool:
	if closed or attempts >= RECONNECT_MAX_ATTEMPTS:
		return false
	if attempts == 0:
		return true
	return (now - last_hb) <= window

## Un heartbeat est « frais » tant que le dernier reçu remonte à moins de
## `timeout` ms. Tout le reste du watchdog se déduit de cette primitive.
static func heartbeat_is_stale(last_hb: int, now: int, timeout: int) -> bool:
	return now - last_hb > timeout

## Watchdog heartbeat : armé UNIQUEMENT après le join terminé (`session_joined`
## = pas en _pending_join). Pendant le transfert niveau + avatar le thread
## principal reste occupé (décode/load) et les heartbeats ne sont pas traités
## — les déclarer perdus là serait un faux positif qui arrache la session.
## Ensuite, même après le join : si un chunk de niveau est arrivé dans les
## `progress_window` ms (`last_progress`), le transfert est vivant → on
## n'arme pas (un gel bref résiduel ne doit pas arracher la session).
static func heartbeat_reconnect_should_arm(session_joined: bool, last_hb: int, now: int,
		timeout: int, last_progress: int = -1, progress_window: int = 5000) -> bool:
	if session_joined and last_progress >= 0 and now - last_progress < progress_window:
		return false   # transfert de niveau vivant → un gel bref n'arrache pas la session
	return session_joined and heartbeat_is_stale(last_hb, now, timeout)

## Annulation d'un reconnect déjà programmé (backoff en cours) : si le heartbeat
## est revenu une fois la session établie, le réseau est vivant → on garde la
## session au lieu de l'arracher. Pendant un join interrompu physiquement, on
## ne cancelle jamais (le reconnect doit partir).
static func heartbeat_cancel_reconnect(session_joined: bool, last_hb: int, now: int, timeout: int) -> bool:
	return session_joined and not heartbeat_is_stale(last_hb, now, timeout)

## Enregistre une tentative de PIN. Retourne true si l'adresse doit être
## rejetée (≥ PIN_FAIL_LIMIT échecs consécutifs). Un succès (ok=true) réarme.
## `state` est une Dictionary externe (testable) : addr -> nb échecs consécutifs.
static func pin_attempt(addr: String, ok: bool, state: Dictionary) -> bool:
	if ok:
		state.erase(addr)
		return false
	var fails: int = int(state.get(addr, 0)) + 1
	state[addr] = fails
	return fails >= PIN_FAIL_LIMIT
# Timestamp (ms) de l'envoi de la requête auth par le client.
var _auth_request_sent_msec := 0

# ── DTLS (chiffrement de session) & anti brute-force PIN ─────────────

var _dtls_key: CryptoKey
var _dtls_cert: X509Certificate

## Matérialise la paire embarquée dans user:// puis la charge en ressource.
## Indépendant du packaging (fonctionne aussi bien en source qu'en export).
func _ensure_dtls_creds() -> bool:
	if _dtls_key != null and _dtls_cert != null:
		return true
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("certs"):
		dir.make_dir("certs")
	var key_path := "user://certs/%s.pem" % DTLS_CREDS_NAME
	var cert_path := "user://certs/%s.crt" % DTLS_CREDS_NAME
	var fa := FileAccess.open(key_path, FileAccess.WRITE)
	if fa == null:
		lan._lan_log("DTLS: cannot write key to user://, encryption disabled")
		return false
	fa.store_string(DTLS_KEY_PEM)
	fa.close()
	fa = FileAccess.open(cert_path, FileAccess.WRITE)
	if fa == null:
		lan._lan_log("DTLS: cannot write cert to user://, encryption disabled")
		return false
	fa.store_string(DTLS_CERT_PEM)
	fa.close()
	var key := CryptoKey.new()
	if key.load(key_path) != OK:
		lan._lan_log("DTLS: cannot load key from user://, encryption disabled")
		return false
	var cert := X509Certificate.new()
	if cert.load(cert_path) != OK:
		lan._lan_log("DTLS: cannot load cert from user://, encryption disabled")
		return false
	_dtls_key = key
	_dtls_cert = cert
	return true

func _load_dtls_options() -> TLSOptions:
	if not _ensure_dtls_creds():
		return null
	return TLSOptions.server(_dtls_key, _dtls_cert)

func _dtls_client_options() -> TLSOptions:
	if not _ensure_dtls_creds():
		return null
	# Chiffrement seul (pas de validation d'identite : cert auto-signe, IP LAN
	# variable, et l'authentification mutuelle est deja assuree par le PIN).
	return TLSOptions.client_unsafe(_dtls_cert)

## true si l'adresse est actuellement blacklistée (verrou intact et non expiré).
func _pin_blocked(ip: String) -> bool:
	if ip == "" or not _pin_blacklist.has(ip):
		return false
	if Time.get_ticks_msec() - int(_pin_blacklist[ip]) >= PIN_BLACKLIST_MSEC:
		_pin_blacklist.erase(ip)
		_pin_fail_counts.erase(ip)
		return false
	return true

## Enregistre un échec de PIN depuis une adresse IP. Retourne true si
## l'adresse doit être blacklistée (verrou atteint).
func _on_pin_fail(ip: String) -> bool:
	if ip == "":
		return false
	_pin_blacklist[ip] = Time.get_ticks_msec()
	var rejected := pin_attempt(ip, false, _pin_fail_counts)
	if rejected:
		lan._lan_log("PIN brute-force: %s blacklisted (%d failures)" % [ip, PIN_FAIL_LIMIT])
	else:
		lan._lan_log("PIN fail from %s (%d)" % [ip, int(_pin_fail_counts.get(ip, 0))])
	return rejected

## Réarme l'anti brute-force après un PIN valide d'une adresse donnée.
func _on_pin_success(ip: String) -> void:
	if ip == "":
		return
	pin_attempt(ip, true, _pin_fail_counts)
	_pin_blacklist.erase(ip)

## Adresse IP d'un peer distant (côté hôte). "" si indisponible.
func _remote_ip(peer_id: int) -> String:
	var mp := multiplayer.multiplayer_peer
	if mp == null or not mp is ENetMultiplayerPeer:
		return ""
	var p = mp.get_peer(peer_id)
	if p == null or not p is ENetPacketPeer:
		return ""
	return String(p.get_remote_address())

# ── Host ─────────────────────────────────────────────────────────────

func host_game() -> bool:
	if LanManager.session_active:
		lan._set_status("Already in a LAN session")
		return false
	if lan.online:
		var why := _online_preflight()
		if why != "":
			lan._set_status("Online mode refused: " + why)
			push_error("LAN online: " + why)
			return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(LanManager.PORT, lan.max_players, 8)
	if err != OK:
		lan._set_status("Host error: " + error_string(err))
		return false
	lan.session_encrypted = false
	if lan.online:
		var tls := _load_online_tls_options()
		if tls == null or peer.host.dtls_server_setup(tls) != OK:
			peer.close()
			lan._set_status("Online mode refused: TLS certificate/key unusable")
			push_error("LAN online: TLS certificate/key unusable (%s, %s)" % [lan.tls_cert_path, lan.tls_key_path])
			return false
		lan.session_encrypted = true
		lan._lan_log("DTLS: certificat réel chargé (online)")
	elif lan.invite_mode:
		# Invitation : identité propre à cet hôte (jamais la clé embarquée, commune à tous), chiffrement obligatoire.
		if peer.host.dtls_server_setup(lan.invite.server_tls()) != OK:
			peer.close()
			lan._set_status("Cannot host over the Internet: DTLS setup failed")
			return false
		lan.session_encrypted = true
		lan._lan_log("DTLS: identité d'invitation (hôte)")
	elif lan.encryption_enabled:
		var dtls := _load_dtls_options()
		if dtls != null:
			if peer.host.dtls_server_setup(dtls) != OK:
				lan._lan_log("DTLS: server setup failed, session not encrypted")
			else:
				lan.session_encrypted = true
				lan._lan_log("DTLS: session encrypted (server)")
	if lan.online:
		_setup_engine_auth()
	multiplayer.multiplayer_peer = peer
	LanManager.session_active = true
	lan.is_host = true
	lan.session_state_changed.emit(true)
	lan.level_sync._refresh_level_sync()
	lan._pin = lan.forced_pin if lan.forced_pin != "" else (lan.InviteModule.random_pin() if lan.invite_mode else lan._generate_pin())
	lan.pin_changed.emit(lan._pin)
	lan._lan_log("host password set" if lan.online else "host PIN: " + lan._pin)
	# Miroir des scripts utilisateur reparti à zéro pour cette session (les
	# manifests reçus — avatars des clients — réinstallent leurs lots).
	UserScriptMirror.clear()
	# L'hôte a déjà son niveau chargé (compilé au boot) : avatars immédiatement
	# préchauffables.
	lan._level_stable = true
	lan._session_start_msec = Time.get_ticks_msec()
	# Compteur d'émission heartbeat remis à zéro pour cette session : sans
	# ça, une 2e session d'hébergement dans la même exécution hériterait du
	# dernier horodatage et le 1er « heartbeat late » serait un faux positif
	# (garde > 0 côté _process traite le 0 comme une première émission).
	_last_heartbeat_sent_msec = 0
	lan.level_transfer._host_spawn_transform.clear()
	lan._players.clear()
	if not lan.dedicated:
		lan._players[multiplayer.get_unique_id()] = {"name": lan.player_name, "color": lan.player_color}
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if lan.invite_mode:
		lan.invite.start_host(lan._pin)       # ports (UPnP) + code d'invitation, en arrière-plan
	elif not lan.online:
		lan.discovery._start_responder()      # la découverte UDP n'a pas sa place sur Internet (et divulgue nom/adresses)
	lan._announced = false
	lan.players._avatar_sent_to.clear()
	lan.players._avatar_send_cache = PackedByteArray()
	lan.players._avatar_send_cache_raw_size = 0
	lan.players._avatar_send_scripts_cache = {}
	# Bake + compression ZSTD préparés ICI, au clic Héberger : jamais dans le
	# handler RPC _register_player (voir _prepare_level_send_cache). Un host
	# sans cache reste joignable — le miss de _send_level_to le préparera de
	# façon différée.
	lan._set_status("Preparing host level…")
	if not lan.level_transfer._prepare_level_send_cache():
		lan._lan_log("level cache prepare failed")
	lan._lan_log("host_game — waiting for clients", true)
	if lan.invite_mode:
		lan._set_status("Hosting over the Internet — preparing the invitation code (UPnP)…")
	else:
		lan._set_status("Hosting on %s:%d — open UDP port %d (and %d) and TCP port %d in the firewall if a client can't connect%s" % [lan._local_ip(), LanManager.PORT, LanManager.PORT, LanManager.DISCOVERY_PORT, LanManager.LEVEL_TCP_PORT, " (TLS ON)" if lan.session_encrypted else ""])
	lan._emit_players()
	return true

# ── Join ─────────────────────────────────────────────────────────────

func join_game(ip: String, pin: String = "", encrypted: bool = false) -> bool:
	if LanManager.session_active:
		lan._set_status("Already in a LAN session")
		return false
	ip = ip.strip_edges()
	if ip == "":
		return false
	_last_join_encrypted = encrypted
	lan._pin = pin.strip_edges()
	# Contexte de reconnexion : capturé au join initial (pas pendant un rejoin).
	if not _reconnecting:
		_reconnect_ip = ip
		_reconnect_pin = pin.strip_edges()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, LanManager.PORT, 8)
	if err != OK:
		lan._set_status("Connection error: " + error_string(err))
		return false
	# Un NOM d'hôte (pas une IP) = serveur en ligne : certificat vérifié OBLIGATOIRE, pas de repli vers le mode
	# non vérifié, authentification par le moteur. Une IP reste le mode LAN historique (chiffrement sans identité).
	var online_join := _is_hostname(ip)
	if online_join:
		if peer.host.dtls_client_setup(ip, _verified_client_options()) != OK:
			peer.close()
			lan._set_status("Cannot start a verified TLS session with %s" % ip)
			return false
		lan.session_encrypted = true
		lan.session_online = true
		_setup_engine_auth()
		lan._lan_log("DTLS: certificat vérifié exigé (client → %s)" % ip)
	elif _invite_cert != "":
		# Code d'invitation : seul le certificat de CET hôte est accepté (épinglage), sinon pas de connexion.
		var tls: TLSOptions = lan.InviteModule.client_tls(_invite_cert)
		if tls == null or peer.host.dtls_client_setup(lan.InviteModule.CN, tls) != OK:
			peer.close()
			lan._set_status("Invalid invitation code (certificate)")
			return false
		lan.session_encrypted = true
		lan._lan_log("DTLS: certificat épinglé (invitation → %s)" % ip)
	elif encrypted:
		var dtls := _dtls_client_options()
		if dtls != null:
			if peer.host.dtls_client_setup(ip, dtls) != OK:
				lan._lan_log("DTLS: client setup failed, session not encrypted")
			else:
				lan.session_encrypted = true
				lan._lan_log("DTLS: session encrypted (client → %s)" % ip)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	lan._set_status("Connecting to %s:%d…" % [ip, LanManager.PORT])
	return true

## Heartbeat de l'hôte vers les clients (fiabilité de session).
@rpc("authority", "reliable")
func _host_heartbeat() -> void:
	if lan.is_host:
		return
	var now := Time.get_ticks_msec()
	# Retard > 2× l'intervalle : un heartbeat a été perdu ou arrivé très
	# tard (T6). Ce handler ne s'exécute qu'une fois par heartbeat reçu et la
	# mise à jour juste après réinitialise l'écart → un log par
	# franchissement, jamais de martèlement par frame. Garde > 0 : avant toute
	# connexion le membre vaut 0 et l'écart depuis le démarrage de
	# l'application serait un faux positif.
	var gap := now - _last_heartbeat_msec
	if _last_heartbeat_msec > 0 and gap > 2 * HEARTBEAT_INTERVAL_MSEC:
		lan._lan_log("heartbeat gap %d ms from host" % gap)
	_last_heartbeat_msec = now

## L'hôte ferme proprement la session : les clients abandonnent la reconnexion.
@rpc("authority", "reliable")
func session_closed() -> void:
	if lan.is_host:
		return
	_session_closed_received = true
	lan._lan_log("session_closed received from host")

# ── Mode online : TLS réel, authentification moteur, verrouillage ────

## Avatar reçu d'un autre joueur, en session en ligne : accepté seulement s'il n'embarque AUCUN code. Autorisés :
## le script d'avatar du jeu (res://scripts/player/avatar.gd) sur ses nœuds ; ni autre script, ni ressource scriptée,
## ni sous-scène instanciée, ni connexion de signaux. Le contrôle est fait AVANT instanciation (rien ne s'exécute).
static func avatar_scene_safe(scene: PackedScene) -> bool:
	if scene == null:
		return false
	var st := scene.get_state()
	if st.get_connection_count() > 0:
		return false
	for i in st.get_node_count():
		if st.get_node_instance(i) != null:
			return false
		for j in st.get_node_property_count(i):
			var v: Variant = st.get_node_property_value(i, j)
			if st.get_node_property_name(i, j) == &"script":
				if v == null:
					continue
				if not (v is Script) or String((v as Script).resource_path) != "res://scripts/player/avatar.gd":
					return false
			elif v is Resource and (v as Resource).get_script() != null:
				return false
			elif v is Array:
				for e in v:
					if e is Resource and (e as Resource).get_script() != null:
						return false
	return true

static func _sha256_of(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var step := 4 * 1024 * 1024
	var i := 0
	while i < bytes.size():
		ctx.update(bytes.slice(i, mini(i + step, bytes.size())))
		i += step
	return ctx.finish()

## Nom d'hôte « public » (play.exemple.org) = serveur en ligne ; IP, nom court (raspberrypi) ou nom du réseau local
## (.local, .lan…) = LAN, mode historique. « localhost » compte comme en ligne (essais avec un vrai certificat).
static func _is_hostname(addr: String) -> bool:
	var a := addr.strip_edges().to_lower()
	if a == "" or ":" in a:
		return false                      # IPv6 littérale
	if a == "localhost":
		return true
	var all_ip := true
	for part in a.split("."):
		if not part.is_valid_int():
			all_ip = false
	if all_ip or not "." in a:
		return false
	for suffix in [".local", ".lan", ".home", ".internal", ".localdomain", ".home.arpa"]:
		if a.ends_with(suffix):
			return false
	return true

## Raisons pour lesquelles le serveur refuse de démarrer en mode online ("" = ok).
func _online_preflight() -> String:
	if not lan.dedicated:
		return "le mode online est réservé au serveur dédié"
	if lan.forced_pin.length() < ONLINE_MIN_PASSWORD:
		return "mot de passe trop court (%d caractères minimum)" % ONLINE_MIN_PASSWORD
	if lan.tls_cert_path == "" or lan.tls_key_path == "":
		return "certificat TLS manquant (--tls-cert / --tls-key)"
	if not FileAccess.file_exists(lan.tls_cert_path) or not FileAccess.file_exists(lan.tls_key_path):
		return "fichiers TLS introuvables"
	return ""

func _load_online_tls_options() -> TLSOptions:
	var cert := X509Certificate.new()
	var key := CryptoKey.new()
	if cert.load(lan.tls_cert_path) != OK or key.load(lan.tls_key_path) != OK:
		return null
	return TLSOptions.server(key, cert)

## Autorités racines de confiance pour la vérification du serveur en ligne : ISRG Root X1 et X2 (Let's Encrypt).
## EMBARQUÉES : le magasin de certificats de Godot dépend de la façon dont le moteur a été compilé (un build sans
## certificats intégrés rejetait TOUS les serveurs, alerte DTLS « certificat invalide » juste après le hello du serveur).
## Les chaînes Let's Encrypt récentes (YE1/Root YE) remontent à ISRG Root X2, croisée par ISRG Root X1.
const TRUSTED_ROOTS_PEM := '-----BEGIN CERTIFICATE-----\nMIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\nTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\ncmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\nWhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\nZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\nMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\nh77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\n0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\nA5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\nT8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\nB5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\nB5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\nKBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\nOlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\njh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\nqHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\nrU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\nHRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\nhkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\nubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\n3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\nNFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\nORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\nTkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\njNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\noyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\nmRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\nemyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQsw\nCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2gg\nR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00\nMDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBT\nZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYw\nEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW\n+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9\nItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0T\nAQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZI\nzj0EAwMDaAAwZQIwe3lORlCEwkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdW\ntL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtCnwr1\n/q4AaOeMSQ+2b1tbFfLn\n-----END CERTIFICATE-----\n'

## Client : validation complète de la chaîne et du nom d'hôte, contre les racines embarquées (+ une autorité privée
## éventuelle dans user://server_ca.crt, pour un serveur avec CA maison).
func _verified_client_options() -> TLSOptions:
	var pem := TRUSTED_ROOTS_PEM
	var extra := "user://server_ca.crt"
	if FileAccess.file_exists(extra):
		pem += "\n" + FileAccess.get_file_as_string(extra)
	var chain := X509Certificate.new()
	if chain.load_from_string(pem) != OK:
		return TLSOptions.client()          # (ne devrait pas arriver) magasin du moteur
	return TLSOptions.client(chain)

func _setup_engine_auth() -> void:
	var smp := multiplayer as SceneMultiplayer
	if smp == null:
		return
	smp.auth_callback = _auth_callback
	smp.auth_timeout = 8.0
	if not smp.peer_authenticating.is_connected(_on_peer_authenticating):
		smp.peer_authenticating.connect(_on_peer_authenticating)
	if not smp.peer_authentication_failed.is_connected(_on_peer_auth_failed):
		smp.peer_authentication_failed.connect(_on_peer_auth_failed)

func _teardown_engine_auth() -> void:
	var smp := multiplayer as SceneMultiplayer
	if smp == null:
		return
	smp.auth_callback = Callable()
	if smp.peer_authenticating.is_connected(_on_peer_authenticating):
		smp.peer_authenticating.disconnect(_on_peer_authenticating)
	if smp.peer_authentication_failed.is_connected(_on_peer_auth_failed):
		smp.peer_authentication_failed.disconnect(_on_peer_auth_failed)

func _on_peer_authenticating(id: int) -> void:
	if lan.is_host:
		return                       # le serveur attend les identifiants du client
	# Client : envoie le mot de passe (dans la session TLS dont le certificat a été vérifié).
	_auth_sent = true
	(multiplayer as SceneMultiplayer).send_auth(id, lan._pin.to_utf8_buffer())

func _on_peer_auth_failed(id: int) -> void:
	lan._lan_log("auth moteur échouée / expirée pour %d" % id)

# Appelé par le moteur à la réception des données d'auth d'un pair, AVANT qu'il n'existe pour les RPC.
func _auth_callback(id: int, data: PackedByteArray) -> void:
	var smp := multiplayer as SceneMultiplayer
	if not lan.is_host:
		smp.complete_auth(id)        # client : confirmation du serveur reçue
		return
	var ip := _remote_ip(id)
	var now := Time.get_ticks_msec()
	# Limite globale (anti credential-stuffing distribué) puis verrou par IP.
	while not _online_attempts.is_empty() and now - int(_online_attempts[0]) > 60000:
		_online_attempts.pop_front()
	if _online_attempts.size() >= ONLINE_GLOBAL_ATTEMPTS:
		lan._lan_log("auth: limite globale atteinte — %s refusé" % ip)
		smp.disconnect_peer(id)
		return
	_online_attempts.append(now)
	var st: Dictionary = _online_fail.get(ip, {"count": 0, "level": 0, "until": 0})
	if now < int(st["until"]):
		lan._lan_log("auth: %s verrouillé — refusé" % ip)
		smp.disconnect_peer(id)
		return
	if data.size() > 128:
		smp.disconnect_peer(id)
		return
	# Comparaison des empreintes (pas du texte brut) : temps indépendant du contenu.
	var given := data.get_string_from_utf8().sha256_buffer()
	var expected := lan._pin.sha256_buffer()
	var ok := given == expected and lan._pin != ""
	if ok:
		_online_fail.erase(ip)
		smp.send_auth(id, PackedByteArray([1]))
		smp.complete_auth(id)
		lan._lan_log("auth OK pour %d (%s)" % [id, ip])
		return
	st["count"] = int(st["count"]) + 1
	if int(st["count"]) >= PIN_FAIL_LIMIT:
		st["level"] = int(st["level"]) + 1
		st["count"] = 0
		var lock := mini(ONLINE_LOCK_BASE_MSEC * (1 << (int(st["level"]) - 1)), ONLINE_LOCK_MAX_MSEC)
		st["until"] = now + lock
		lan._lan_log("auth: %s verrouillé %d s (niveau %d)" % [ip, lock / 1000, int(st["level"])])
	_online_fail[ip] = st
	lan._lan_log("auth ÉCHEC pour %d (%s)" % [id, ip])
	smp.disconnect_peer(id)

func _on_connected_to_server() -> void:
	LanManager.session_active = true
	lan.is_host = false
	lan.session_state_changed.emit(true)
	# Reconnexion : chaque connexion réussie remet les compteurs à zéro.
	_session_closed_received = false
	_reconnecting = false
	_reconnect_attempts = 0
	_last_heartbeat_msec = Time.get_ticks_msec()
	# Miroir des scripts utilisateur reparti à zéro : le niveau et les avatars
	# de CETTE session réinstalleront leurs lots avant tout chargement de blob.
	UserScriptMirror.clear()
	# Le niveau de l'hôte arrive plus tard (chunks fiables) : les avatars
	# restent invisibles jusqu'à mark_level_stable() (fin de apply_host_level).
	lan._level_stable = false
	lan._session_start_msec = Time.get_ticks_msec()
	lan._last_level_chunk_msec = lan._session_start_msec
	lan.level_transfer._host_spawn_transform.clear()
	lan._players.clear()
	lan._players[multiplayer.get_unique_id()] = {"name": lan.player_name, "color": lan.player_color}
	# Timeouts ENet généreux côté client (voir _on_peer_connected).
	_set_peer_timeout(1)
	lan._announced = false
	lan.players._avatar_sent_to.clear()
	lan.players._avatar_send_cache = PackedByteArray()
	lan.players._avatar_send_cache_raw_size = 0
	lan.players._avatar_send_scripts_cache = {}
	lan._lan_log("connected to host — auth in progress (pending_join)", true)
	lan._set_status("Connected to server — authenticating…" + (" (TLS)" if lan.session_encrypted else ""))
	lan._emit_players()
	# S'annoncer DÈS la connexion : envoyer le PIN pour vérification.
	# L'hôte répondra par auth_result ; _announce_self() partira uniquement
	# si le PIN est valide.
	lan._pending_join = true
	if lan.session_online:
		# Déjà authentifié par le moteur avant que peer_connected n'existe : on s'annonce directement.
		_auth_request_sent_msec = 0
		_announce_self()
		return
	_auth_request_sent_msec = Time.get_ticks_msec()
	auth_request.rpc_id(1, lan._pin)

# Entrée effective dans la session : la map de l'hôte est appliquée (ou le
# délai de secours a expiré — on joue alors sur la map locale). L'annonce
# part normalement dès la connexion (_announce_self) ; ce rappel ne sert
# qu'aux chemins de secours où elle n'a pas encore eu lieu.
func _finalize_join() -> void:
	if not lan._pending_join:
		return
	lan._pending_join = false
	lan._lan_log("finalize_join — syncs unfrozen")
	if lan.local_player != null and "input_locked" in lan.local_player:
		lan.local_player.input_locked = false
	lan._set_status("Joined session")
	_announce_self()
	# Niveau chargé : l'hôte envoie l'état courant du décor (objets déplacés, cassés…), cf. level_sync.gd.
	lan.level_sync.request_snapshot()

# Annonce au serveur : registration (l'hôte re-broadcaste le spawn de tous)
# + envoi de notre avatar. Idempotent sur toute la session.
func _announce_self() -> void:
	if lan._announced:
		return
	lan._announced = true
	lan._lan_log("announce: register + avatar → host")
	lan.players._register_player.rpc_id(1, lan.player_name, lan.player_color)
	lan.players._send_avatar_to(1)

# ── Authentification PIN ─────────────────────────────────────────────

## Le client envoie le PIN saisi au serveur (hôte) pour vérification.
@rpc("any_peer", "reliable")
func auth_request(pin: String) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or not lan.is_host:
		return
	lan._lan_log("auth_request from %d" % from)
	if pin == lan._pin:
		_pending_auth.erase(from)
		# PIN valide → réarme l'anti brute-force pour cette adresse.
		_on_pin_success(_remote_ip(from))
		lan._set_status("Player %d authenticated (PIN OK)" % from)
		auth_result.rpc_id(from, true)
		# Enregistrer le joueur (registration) et démarrer les transferts.
		# On utilise les mêmes paramètres que _register_player mais via le
		# canal auth pour éviter les courses.
		lan._players[from] = {"name": "Player %d" % from, "color": Color.WHITE}
		lan.players._register_player.rpc_id(from, lan.player_name, lan.player_color)
	else:
		var ip := _remote_ip(from)
		if _pin_blocked(ip):
			lan._lan_log("auth REJECTED %d — IP %s blacklisted (too many PIN failures)" % [from, ip])
			lan._set_status("Player %d rejected (IP blacklisted)" % from)
			auth_result.rpc_id(from, false)
			await get_tree().create_timer(0.5).timeout
			multiplayer.multiplayer_peer.disconnect_peer(from)
			return
		lan._lan_log("auth FAIL from %d — wrong PIN" % from)
		lan._set_status("Player %d rejected (wrong PIN)" % from)
		auth_result.rpc_id(from, false)
		if ip != "" and _on_pin_fail(ip):
			lan._lan_log("PIN brute-force — disconnecting %d (%s)" % [from, ip])
			await get_tree().create_timer(0.5).timeout
			multiplayer.multiplayer_peer.disconnect_peer(from)

## Réponse du serveur (hôte) à la tentative d'authentification du client.
@rpc("any_peer", "reliable")
func auth_result(ok: bool) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from != 1:
		return
	_auth_request_sent_msec = 0
	if ok:
		lan._lan_log("auth OK — announcing and sending avatar")
		_announce_self()
	else:
		lan._lan_log("auth REJECTED by host")
		lan._set_status("Authentication rejected by host (wrong PIN)")
		lan._disconnect_session()

func _on_connection_failed() -> void:
	if _should_attempt_reconnect():
		_begin_reconnect()
	elif lan.session_online:
		var rejected := _auth_sent
		lan._disconnect_session()
		if rejected:
			# La poignée de main TLS a abouti (certificat accepté) et le mot de passe est parti : c'est le serveur qui
			# a refusé — mauvais mot de passe, ou verrouillage temporaire après plusieurs échecs.
			lan._set_status("Authentication refused by the server — wrong password (12+ characters, not the LAN PIN), or temporarily locked out after repeated failures.")
		else:
			lan._set_status("Connection failed — server unreachable, or its TLS certificate is not valid for this name (the name must match the certificate).")
	elif _invite_cert != "":
		lan._disconnect_session()
		lan._set_status("Connection failed — host unreachable (it must forward UDP %d and TCP %d, or have UPnP), or the host is not the one of this invitation code (certificate mismatch). Ask for a fresh code." % [LanManager.PORT, LanManager.LEVEL_TCP_PORT])
	else:
		lan._disconnect_session()
		var tls_hint := " TLS était activé sur le Join — si l'hôte ne chiffre pas, retentez sans TLS." if _last_join_encrypted else ""
		lan._set_status("Connection failed — IP unreachable. Check: same network, host firewall (UDP %d/%d open), router AP isolation.%s" % [LanManager.PORT, LanManager.DISCOVERY_PORT, tls_hint])

func _on_server_disconnected() -> void:
	if _should_attempt_reconnect():
		_begin_reconnect()
	else:
		lan._disconnect_session()
		lan._set_status("Disconnected from server")

# ── Reconnexion automatique (C2) ─────────────────────────────────────

func _should_attempt_reconnect() -> bool:
	if lan.is_host or not LanManager.session_active or _session_closed_received:
		return false
	return should_reconnect(_last_heartbeat_msec, Time.get_ticks_msec(),
		_session_closed_received, RECONNECT_WINDOW_MSEC, _reconnect_attempts)

## Heartbeat expiré côté client → on considère l'hôte injoignable. Garde-fous :
## pendant le join (transfert lourd, heartbeats non traités par le thread occupé)
## et pendant un reconnect déjà en cours, pas de nouveau déclenchement.
func _on_host_heartbeat_timeout() -> void:
	if lan._pending_join or _reconnecting:
		return
	lan._lan_log("heartbeat expired (%d ms without host heartbeat)" % HOST_HEARTBEAT_TIMEOUT_MSEC)
	_begin_reconnect()

func _begin_reconnect() -> void:
	if _reconnecting or _session_closed_received or _reconnect_ip == "":
		return
	_reconnecting = true
	_reconnect_attempts += 1
	if _reconnect_attempts >= RECONNECT_MAX_ATTEMPTS:
		_reconnecting = false
		_reconnect_ip = ""
		lan._disconnect_session()
		lan._set_status("Host unreachable — back to local game")
		return
	var delay := backoff_delay(_reconnect_attempts - 1)
	lan._set_status("Reconnecting… (%d/%d)" % [_reconnect_attempts, RECONNECT_MAX_ATTEMPTS])
	await get_tree().create_timer(delay).timeout
	if not LanManager.session_active and not _reconnecting:
		_reconnecting = false
		return
	# Heartbeat revenu pendant l'attente du backoff (la session s'est établie
	# entretemps, le réseau est vivant) → annuler le reconnect, on garde la
	# session au lieu de l'arracher (boucle de rejoin constatée en réel).
	if heartbeat_cancel_reconnect(not lan._pending_join, _last_heartbeat_msec, Time.get_ticks_msec(), HOST_HEARTBEAT_TIMEOUT_MSEC):
		lan._lan_log("reconnect cancelled — heartbeat resumed")
		_reconnecting = false
		return
	lan._disconnect_session(true)
	join_game(_reconnect_ip, _reconnect_pin, _last_join_encrypted)

func _on_peer_connected(id: int) -> void:
	if lan.is_host:
		lan._set_status("Player %d connected — waiting for PIN…" % id)
		# Timeouts ENet généreux : pendant un stream partagé (vidéo/audio), le
		# thread principal fait de l'encodage/décodage JPEG par frame ; un à-coup
		# de quelques secondes ne doit pas faire tomber la session (défaut ENet :
		# déconnexion après ~5 s sans ACK).
		_set_peer_timeout(id)
		if lan.online:
			return      # déjà authentifié par le moteur (_auth_callback) : aucune étape PIN par RPC
		_pending_auth[id] = true
		# PAS d'envoi de niveau/avatar ici : attendre la registration du pair
		# (voir _register_player). Les paquets de contrôle (snapshot roster,
		# broadcasts) doivent partir sur un tube VIDE — s'ils se disputent le
		# socket avec des mégaoctets de chunks, ils sont perdus dès le burst
		# initial et ne se récupèrent que par retransmissions ENet (~5-8 s).

# Timeouts ENet généreux (limit, min, max) pour résister aux à-coups du
# thread principal pendant un stream partagé. Défaut ENet (5000/30000 ms)
# coupe la session après ~5 s sans ACK, trop juste quand l'encodage/décodage
# JPEG vidéo monopolise le thread principal.
const ENET_THROTTLE_INTERVAL_MSEC := 5000   # valeurs par défaut d'ENet
const ENET_THROTTLE_ACCELERATION := 2
const ENET_TIMEOUT_LIMIT := 64
const ENET_TIMEOUT_MIN := 15000
const ENET_TIMEOUT_MAX := 90000

func _set_peer_timeout(id: int) -> void:
	var mp = multiplayer.multiplayer_peer
	if mp == null or not (mp is ENetMultiplayerPeer):
		return
	var peer = (mp as ENetMultiplayerPeer).get_peer(id)
	if peer == null:
		return
	peer.set_timeout(ENET_TIMEOUT_LIMIT, ENET_TIMEOUT_MIN, ENET_TIMEOUT_MAX)
	# Limiteur d'ENet (« packet throttle ») : il jette volontairement des paquets NON FIABLES dès que le temps
	# d'aller-retour varie, ce qui arrive en continu quand le thread principal du jeu a des à-coups (chargements,
	# captures). Mesuré : 15 à 30 % seulement des trames de voix arrivaient. Décélération 0 = jamais de rejet
	# volontaire ; le débit non fiable reste faible (voix ~24 kb/s, audio partagé), la vidéo passe en fiable.
	peer.throttle_configure(ENET_THROTTLE_INTERVAL_MSEC, ENET_THROTTLE_ACCELERATION, 0)

func _on_peer_disconnected(id: int) -> void:
	lan.chat.forget_peer(id)
	lan._peer_pos.erase(id)
	lan.voice.forget_peer(id)
	lan.players._avatar_blobs.erase(id)
	lan.players._avatar_send_queue.erase(id)
	_pending_auth.erase(id)
	# Diagnostique : la déconnexion survient pendant un partage vidéo. ENet
	# déconnecte quand une commande reliable (ping/ACK) reste non-acknowledgée
	# ≥15 s (timeout min) — soit un lien saturé, soit un thread principal
	# bloqué. Ce log permet de corréler avec les symptômes (lag → déconnexion).
	print("[lan] peer %d disconnected — state: video_stream=%s audio=%s nframes=%d" % [
		id,
		lan._has_streaming_window(),
		"on" if lan.audio_share._audio_active else "off",
		lan.audio_share._audio_send_count + lan.audio_share._audio_received_count,
	])
	if lan.is_host:
		lan._players.erase(id)
		lan.level_sync._msg_budget.erase(id)
		_admins.erase(id)
		_admin_fails.erase(id)
		lan.level_peer_left.emit(id)
		lan.players._remove_player.rpc(id)
		if lan.level_transfer._level_tcp_server != null:
			lan.level_transfer._level_tcp_server.revoke(id)
	else:
		lan.players._remove_player(id)
		if id == 1:
			lan.level_transfer._stop_level_tcp_rx()
	lan.window_share._last_texture_versions.erase(id)
	lan.window_share._last_applied_version.erase(id)
	lan.window_share._last_acked_version.erase(id)
	lan.video_share._video_last_sent.erase(id)
	lan.video_share._video_acked.erase(id)
	lan.video_share._video_config_sent.erase(id)
	lan.video_share._video_ack_pending.erase(id)
	# Purge exhaustive des slots par-peer (reconnexion → nouveau peer_id).
	lan.video_share._video_nack_last.erase(id)
	lan.video_share._video_configs.erase(id)
	lan.video_share._video_applied.erase(id)
	lan.video_share._video_chunks.erase(id)
	lan.window_share._frame_fingerprint_last.erase(id)
	lan.window_share._last_keyframe_msec.erase(id)
	lan.window_share._frame_enqueued_msec.erase(id)
	lan.window_share._last_cursor_pointer_send.erase(id)
	lan.window_share._last_cursor_image_send.erase(id)
	lan.players._avatar_receive_slots.erase(id)
	lan.window_share._remote_shared.erase(id)
	lan._set_status("Player %d disconnected" % id)
const ADMIN_MAX_FAILS := 3
const ADMIN_LOCKOUT_MSEC := 30000
var admin := false                         # client : suis-je admin sur ce serveur ?
var _admins: Dictionary = {}               # serveur : peer_id -> true
var _admin_fails: Dictionary = {}          # serveur : peer_id -> {count, until}

## Serveur : ce pair est-il admin ? Client : suis-je admin ? Hôte LAN classique : toujours.
func is_admin(peer: int = 0) -> bool:
	if lan.is_host:
		return true if not lan.dedicated else _admins.has(peer)
	return admin

## Client : demande les droits d'admin au serveur (la réponse arrive par admin_changed).
func request_admin(password: String) -> void:
	lan.level_sync.send_level_message("admin_login", password)

func _handle_admin_login(from: int, password: Variant) -> void:
	var now := Time.get_ticks_msec()
	var st: Dictionary = _admin_fails.get(from, {"count": 0, "until": 0})
	var ok := false
	if lan.admin_password != "" and password is String and now >= int(st["until"]):
		ok = String(password) == lan.admin_password
		if not ok:
			st["count"] = int(st["count"]) + 1
			if int(st["count"]) >= ADMIN_MAX_FAILS:
				st["count"] = 0
				st["until"] = now + ADMIN_LOCKOUT_MSEC
				lan._lan_log("admin: %d verrouillé 30 s (échecs répétés)" % from)
			_admin_fails[from] = st
	if ok:
		_admins[from] = true
		_admin_fails.erase(from)
		lan._lan_log("admin: %d est administrateur" % from)
	lan.level_sync.send_level_message_to(from, "admin_status", ok)
