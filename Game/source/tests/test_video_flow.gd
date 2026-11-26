extends Node
## Fenêtre de flow control du partage vidéo (video_share.gd) : adaptée à l'aller-retour mesuré.

const Runner = preload("res://tests/runner.gd")
const VideoShare := preload("res://scripts/network/lan/video_share.gd")

func test_lan_rtt_keeps_default_window():
	return Runner.assert_eq(VideoShare.max_ahead_for(20.0, 60), VideoShare.VIDEO_MAX_AHEAD, "LAN : fenêtre par défaut")

func test_no_measure_keeps_default_window():
	return Runner.assert_eq(VideoShare.max_ahead_for(-1.0, 60), VideoShare.VIDEO_MAX_AHEAD, "sans mesure : défaut")

func test_internet_rtt_widens_window():
	# 150 ms à 60 ips : 9 frames par aller-retour, ×1,5 + 2 = 16 ; jamais de saut de P-frame en régime normal.
	return Runner.assert_eq(VideoShare.max_ahead_for(150.0, 60), 16, "en ligne : 1,5 × aller-retour + 2")

func test_window_capped_to_half_a_second():
	return Runner.assert_eq(VideoShare.max_ahead_for(2000.0, 60), 30, "lien saturé : au plus 0,5 s de vidéo en vol")
