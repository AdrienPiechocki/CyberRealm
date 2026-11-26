extends Node
## Partie par Internet sans serveur dédié : code d'invitation et ouverture des ports (UPnP).
##
## Module de LanManager (nœud enfant « Invite »). En mode invitation, l'hôte :
##   - utilise SA propre identité DTLS (clé + certificat auto-signé générés une fois, user://certs/host_invite.*) au
##     lieu de la clé embarquée commune à tous les jeux ;
##   - tire un PIN long et aléatoire (le PIN LAN à 4 chiffres ne protège pas une machine exposée à Internet) ;
##   - ouvre UDP 7777 (jeu) et TCP 7778 (niveau) sur la box par UPnP (dans un thread), et lit son adresse publique ;
##   - publie un code « CR1-… » = adresse + PIN + certificat, à envoyer à ses amis.
## Le client qui colle le code épingle ce certificat (TLSOptions.client avec ce seul certificat de confiance) : un
## autre hôte, même s'il connaît l'adresse et le PIN, est refusé à la poignée de main DTLS.

signal invite_ready(code: String, status: String)

const CN := "CyberRealm host"
const PREFIX := "CR1-"
const PIN_LEN := 12
const KEY_PATH := "user://certs/host_invite.key"
const CERT_PATH := "user://certs/host_invite.crt"
const PIN_ALPHABET := "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # sans caractères ambigus

var lan = null                   # LanManager
var invite_code := ""
var use_upnp := true             # false : pas de découverte UPnP (essais locaux, ports déjà redirigés à la main)
var _upnp: UPNP = null
var _mapped: Array = []          # [port, proto] ouverts par UPnP (fermés en fin de session)
var _thread: Thread = null

# ── Identité de l'hôte ─────────────────────────────────────────────────

var _key: CryptoKey = null
var _cert: X509Certificate = null

## Clé et certificat propres à cette machine (générés au premier hébergement par invitation).
func identity() -> Array:
	if _key != null and _cert != null:
		return [_key, _cert]
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if FileAccess.file_exists(KEY_PATH) and FileAccess.file_exists(CERT_PATH) \
			and key.load(KEY_PATH) == OK and cert.load(CERT_PATH) == OK:
		_key = key
		_cert = cert
		return [_key, _cert]
	DirAccess.make_dir_recursive_absolute("user://certs")
	var c := Crypto.new()
	key = c.generate_rsa(2048)
	cert = c.generate_self_signed_certificate(key, "CN=%s,O=CyberRealm,C=FR" % CN, "20250101000000", "20450101000000")
	key.save(KEY_PATH)
	cert.save(CERT_PATH)
	_key = key
	_cert = cert
	return [_key, _cert]

func server_tls() -> TLSOptions:
	var id := identity()
	return TLSOptions.server(id[0], id[1])

static func random_pin() -> String:
	var c := Crypto.new()
	var bytes := c.generate_random_bytes(PIN_LEN)
	var out := ""
	for b in bytes:
		out += PIN_ALPHABET[b % PIN_ALPHABET.length()]
	return out

# ── Ports et code ──────────────────────────────────────────────────────

## Hôte en mode invitation : ouvre les ports et prépare le code (asynchrone : invite_ready).
func start_host(pin: String) -> void:
	invite_code = ""
	_finish_thread()
	_thread = Thread.new()
	_thread.start(_upnp_worker.bind(pin))

func _upnp_worker(pin: String) -> void:
	var status := ""
	var addr := ""
	var u := UPNP.new()
	var err := u.discover(2000, 2, "InternetGatewayDevice") if use_upnp else UPNP.UPNP_RESULT_NO_GATEWAY
	if err == UPNP.UPNP_RESULT_SUCCESS and u.get_gateway() != null and u.get_gateway().is_valid_gateway():
		var mapped: Array = []
		for m in [[LanManager.PORT, "UDP"], [LanManager.LEVEL_TCP_PORT, "TCP"]]:
			if u.add_port_mapping(m[0], m[0], "CyberRealm", m[1], 0) == UPNP.UPNP_RESULT_SUCCESS:
				mapped.append(m)
		addr = u.query_external_address()
		status = "Ports opened by UPnP (UDP %d, TCP %d)" % [LanManager.PORT, LanManager.LEVEL_TCP_PORT] \
				if mapped.size() == 2 else "UPnP: some ports could not be opened — forward UDP %d and TCP %d on your router" % [LanManager.PORT, LanManager.LEVEL_TCP_PORT]
		_set_mapped.call_deferred(u, mapped)
	else:
		status = "UPnP unavailable — forward UDP %d and TCP %d to this machine on your router" % [LanManager.PORT, LanManager.LEVEL_TCP_PORT]
	if addr == "":
		addr = String(lan._local_ip()) if lan != null else "127.0.0.1"
		status += " (public address unknown: the code contains your local address, replace it if needed)"
	var code := encode_invite(addr, pin, identity()[1].save_to_string())
	_publish.call_deferred(code, status)

func _set_mapped(u: UPNP, mapped: Array) -> void:
	_upnp = u
	_mapped = mapped

func _publish(code: String, status: String) -> void:
	_finish_thread()
	invite_code = code
	lan._lan_log("invite: " + status)
	invite_ready.emit(code, status)

## Fin de session : ferme les ports ouverts par UPnP.
func stop_host() -> void:
	invite_code = ""
	if _upnp == null or _mapped.is_empty():
		return
	var u := _upnp
	var mapped := _mapped
	_upnp = null
	_mapped = []
	_finish_thread()
	_thread = Thread.new()
	_thread.start(func():
		for m in mapped:
			u.delete_port_mapping(m[0], m[1]))

func _finish_thread() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null

func _exit_tree() -> void:
	stop_host()
	_finish_thread()

## TLS du client pour un code donné : seul le certificat de l'hôte est accepté.
static func client_tls(cert_pem: String) -> TLSOptions:
	var cert := X509Certificate.new()
	if cert.load_from_string(cert_pem) != OK:
		return null
	return TLSOptions.client(cert, CN)

# ── Codage du code (logique pure, testée) ──────────────────────────────

static func encode_invite(addr: String, pin: String, cert_pem: String) -> String:
	var raw := var_to_bytes({"a": addr, "p": pin, "c": cert_pem})
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var b64 := Marshalls.raw_to_base64(var_to_bytes([raw.size(), packed]))
	return PREFIX + b64.replace("+", "-").replace("/", "_").replace("=", "")

## {addr, pin, cert} ou {} si le code est invalide.
static func decode_invite(code: String) -> Dictionary:
	var c := code.strip_edges()
	if not c.begins_with(PREFIX) or c.length() > 8192:
		return {}
	var b64 := c.substr(PREFIX.length()).replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	if b64.length() < 8 or not RegEx.create_from_string("^[A-Za-z0-9+/]+=*$").search(b64):
		return {}
	var outer_raw := Marshalls.base64_to_raw(b64)
	if outer_raw.size() < 8:
		return {}
	var outer: Variant = bytes_to_var(outer_raw)       # jamais d'objets
	if not (outer is Array) or outer.size() != 2 or not (outer[0] is int) or not (outer[1] is PackedByteArray):
		return {}
	if outer[0] <= 0 or outer[0] > 65536:
		return {}
	var inner := (outer[1] as PackedByteArray).decompress(outer[0], FileAccess.COMPRESSION_ZSTD)
	if inner.size() < 8:
		return {}
	var v: Variant = bytes_to_var(inner)
	if not (v is Dictionary) or not (v.get("a") is String) or not (v.get("p") is String) or not (v.get("c") is String):
		return {}
	if String(v["a"]) == "" or String(v["a"]).length() > 255 or String(v["p"]).length() > 64:
		return {}
	return {"addr": v["a"], "pin": v["p"], "cert": v["c"]}
