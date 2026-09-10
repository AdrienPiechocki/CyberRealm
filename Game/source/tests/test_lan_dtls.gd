extends Node
## Le DTLS doit être réellement chargeable AU RUNTIME (import-independant) :
## "load() as CryptoKey/X509Certificate" echoue sans .import genere par l'editeur,
## ce qui desactive silencieusement le chiffrement chez l'hote et fait rater la
## handshake d'un client qui, lui, a la case TLS cochee ("Connection Failed").

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func test_host_dtls_options_runtime_loadable():
	var inst: Node = LANManager.new()
	var opts = inst._load_dtls_options()
	inst.free()
	return Runner.assert_eq(opts != null, true, "host _load_dtls_options(): cle+cert chargeables via load() runtime (lan_key.pem/lan_cert.crt presents)")

func test_client_dtls_options_runtime_loadable():
	var inst: Node = LANManager.new()
	var opts = inst._dtls_client_options()
	inst.free()
	var ok: bool = opts != null
	if not ok:
		return Runner.assert_eq(true, false, "client _dtls_client_options(): cert chargeable via load() runtime")
	return Runner.assert_eq(opts.is_unsafe_client(), true, "client DTLS = chiffrement seul (client_unsafe), sans validation d'IP")