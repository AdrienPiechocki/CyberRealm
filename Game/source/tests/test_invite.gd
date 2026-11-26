extends Node
## Tests du code d'invitation (scripts/network/lan/invite.gd).

const Runner = preload("res://tests/runner.gd")
const Invite = preload("res://scripts/network/lan/invite.gd")

const PEM := "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"

func test_invite_round_trip():
	var code := Invite.encode_invite("203.0.113.7", "abcDEF234xyz", PEM)
	var r: Variant = Runner.assert_true(code.begins_with("CR1-") and not code.contains("+") and not code.contains("/") and not code.contains("="),
		"préfixe et base64 sûre pour un copier-coller")
	if r is String: return r
	return Runner.assert_eq(Invite.decode_invite("  " + code + "\n"), {"addr": "203.0.113.7", "pin": "abcDEF234xyz", "cert": PEM}, "décodage")

func test_invalid_codes_rejected():
	for bad in ["", "CR1-", "CR1-!!!!", "XYZ-abcd", "CR1-" + Marshalls.raw_to_base64(var_to_bytes([999999, PackedByteArray()]))]:
		if not Invite.decode_invite(bad).is_empty():
			return "code invalide accepté : " + bad
	var huge := Invite.encode_invite("x".repeat(300), "p", PEM)
	return Runner.assert_true(Invite.decode_invite(huge).is_empty(), "adresse trop longue refusée")

func test_random_pin():
	var a := Invite.random_pin()
	var b := Invite.random_pin()
	var r: Variant = Runner.assert_eq(a.length(), Invite.PIN_LEN, "longueur")
	if r is String: return r
	for ch in a:
		if not Invite.PIN_ALPHABET.contains(ch):
			return "caractère hors alphabet : " + ch
	return Runner.assert_true(a != b, "tirages différents")

const LANManager = preload("res://scripts/network/lan_manager.gd")

func test_invite_sessions_restricted_unless_trusted():
	var lan: Node = LANManager.new()
	var r: Variant = Runner.assert_true(not lan.online_restricted(), "LAN classique : pas de restriction")
	if r is String: lan.free(); return r
	lan.is_host = true
	lan.invite_mode = true
	r = Runner.assert_true(lan.online_restricted(), "hôte par invitation : restreint")
	if r is String: lan.free(); return r
	lan.is_host = false
	lan.invite_mode = false
	lan.session._invite_cert = PEM
	r = Runner.assert_true(lan.online_restricted(), "client par invitation : restreint")
	if r is String: lan.free(); return r
	lan.invite_trusted = true
	r = Runner.assert_true(not lan.online_restricted(), "invités de confiance : comme en LAN")
	lan.free()
	return r

func test_online_server_shares_windows_but_not_files():
	var lan: Node = LANManager.new()
	lan.session_online = true
	var r: Variant = Runner.assert_true(lan.online_restricted(), "serveur online : partage de fichiers coupé")
	if r is String: lan.free(); return r
	r = Runner.assert_true(not lan.window_share_restricted(), "serveur online : fenêtres, annotations, contrôle actifs")
	if r is String: lan.free(); return r
	lan.session_online = false
	lan.session._invite_cert = PEM
	r = Runner.assert_true(lan.window_share_restricted(), "client par invitation non approuvé : fenêtres coupées")
	if r is String: lan.free(); return r
	lan.invite_trusted = true
	r = Runner.assert_true(not lan.window_share_restricted(), "invités de confiance : fenêtres visibles")
	lan.free()
	return r
