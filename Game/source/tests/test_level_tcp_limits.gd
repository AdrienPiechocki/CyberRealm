extends Node
## LevelTcp : limites par IP du serveur de transfert (quota de connexions
## simultanées, bannissement après trop de jetons rejetés, fenêtre glissante).

const Runner := preload("res://tests/runner.gd")

func test_reject_quota_bans_ip() -> Variant:
	var rej := {}
	for i in LevelTcp.MAX_REJECTS_PER_IP - 1:
		LevelTcp.Server._note_reject(rej, "1.2.3.4", 1000 + i)
	if LevelTcp.Server._is_banned(rej, "1.2.3.4", 2000):
		return "banni trop tôt (sous le quota)"
	LevelTcp.Server._note_reject(rej, "1.2.3.4", 1500)
	if not LevelTcp.Server._is_banned(rej, "1.2.3.4", 2000):
		return "non banni au quota"
	if LevelTcp.Server._is_banned(rej, "5.6.7.8", 2000):
		return "une autre IP ne doit pas être bannie"
	return true

func test_ban_expires_with_window() -> Variant:
	var rej := {}
	for i in LevelTcp.MAX_REJECTS_PER_IP:
		LevelTcp.Server._note_reject(rej, "1.2.3.4", 1000)
	if LevelTcp.Server._is_banned(rej, "1.2.3.4", 1000 + LevelTcp.REJECT_WINDOW_MSEC + 1):
		return "le bannissement devrait expirer avec la fenêtre"
	if rej.has("1.2.3.4"):
		return "l'entrée expirée devrait être purgée"
	return true

func test_count_for_ip() -> Variant:
	var conns := [{"ip": "a"}, {"ip": "a"}, {"ip": "b"}]
	return Runner.assert_eq(LevelTcp.Server._count_for_ip(conns, "a"), 2, "connexions de a")
