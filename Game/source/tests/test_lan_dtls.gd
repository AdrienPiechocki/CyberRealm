extends Node
## Le DTLS doit être réellement chargeable AU RUNTIME, INDEPENDAMMENT du
## packaging : Godot exclut les clés privées (CryptoKey) du pck exporté même
## en all_resources → on embarque la paire en constantes PEM (script) et on la
## matérialise dans user://. Ces tests valident ce chemin (aucune dépendance à
## res://certs/, qui disparaît à l'export).

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func test_host_dtls_options_runtime_loadable():
	var inst: Node = LANManager.new()
	var opts = inst._load_dtls_options()
	inst.free()
	return Runner.assert_eq(opts != null, true, "host _load_dtls_options(): paire embarquée fonctionnelle (clé+cert via user://)")

func test_client_dtls_options_runtime_loadable():
	var inst: Node = LANManager.new()
	var opts = inst._dtls_client_options()
	inst.free()
	var ok: bool = opts != null
	if not ok:
		return Runner.assert_eq(true, false, "client _dtls_client_options(): cert embarqué fonctionnel")
	return Runner.assert_eq(opts.is_unsafe_client(), true, "client DTLS = chiffrement seul (client_unsafe), sans validation d'IP")