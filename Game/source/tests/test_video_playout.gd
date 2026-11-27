extends Node
## Tampon de lecture vidéo (video_playout.gd) : cadence régulière malgré des arrivées groupées.

const Runner = preload("res://tests/runner.gd")
const VideoPlayout := preload("res://scripts/network/lan/video_playout.gd")

func _img() -> Image:
	return Image.create(2, 2, false, Image.FORMAT_RGBA8)

## Frames capturées toutes les 33 ms, arrivées par paires (gigue du relais) ; rendu à 60 ips.
## Renvoie le nombre d'images affichées et le nombre de ticks avec plusieurs images dues.
func _simulate(po: VideoPlayout, frames: int) -> Dictionary:
	var arrivals := {}
	for i in frames:
		var cap := i * 33
		var arrive := cap + 20 + (33 if i % 2 == 0 else 0) # la paire arrive en même temps
		arrivals[i] = arrive
	var shown := 0
	var next := 0
	var dropped_before := po.dropped
	var tick := 0
	while tick < frames * 33 + 400:
		while next < frames and int(arrivals[next]) <= tick:
			po.push(next, next * 33, tick, _img())
			next += 1
		if po.pop_due(tick) != null:
			shown += 1
		tick += 16
	return {"shown": shown, "dropped": po.dropped - dropped_before}

func test_bursty_arrivals_show_every_frame():
	var po := VideoPlayout.new()
	var r := _simulate(po, 120)
	# Avant : une image de chaque paire jetée (~60/120). Le tampon absorbe la gigue une fois mesurée.
	return Runner.assert_true(int(r["dropped"]) <= 2, "images perdues : %d (affichées %d)" % [r["dropped"], r["shown"]])

func test_delay_follows_jitter():
	var po := VideoPlayout.new()
	_simulate(po, 60)
	var d := po.current_delay()
	return Runner.assert_true(d >= 33.0 and d <= 60.0, "retard %.1f ms pour 33 ms de gigue" % d)

func test_audio_delay_extends_playout():
	var po := VideoPlayout.new()
	po.push(0, 1000, 1010, _img())
	# Sans son : due après ~MIN_DELAY ; avec 120 ms de son en attente : pas avant.
	var early = po.pop_due(1030, 120.0)
	var late = po.pop_due(1131, 120.0)
	return Runner.assert_true(early == null and late != null, "image calée sur le retard du son")

## Prise de contrôle : le retard calé sur le son retombe d'un coup sur la gigue, pas à 30 ms/s.
func test_snap_delay_drops_audio_wait():
	var po := VideoPlayout.new()
	po.push(0, 1000, 1010, _img())
	po.pop_due(1200, 150.0)
	var before := po.current_delay()
	po.push(1, 1016, 1026, _img())
	po.snap_delay()
	var shown = po.pop_due(1240, 0.0)
	var r: Variant = Runner.assert_true(before >= 150.0 and shown != null, "image due tout de suite après le passage")
	if r is String: return r
	return Runner.assert_true(po.current_delay() < 50.0, "retard ramené à la gigue")

## Sous contrôle, la pire gigue n'est plus attendue : retard borné, l'image en retard passe tout de suite.
func test_controlled_caps_delay():
	var po := VideoPlayout.new()
	po.controlled = true
	po.push(0, 1000, 1010, _img())
	po.push(1, 1016, 1226, _img())                   # 200 ms de gigue
	var shown = po.pop_due(1230)
	return Runner.assert_true(shown != null and po.current_delay() <= VideoPlayout.CONTROLLED_MAX_DELAY_MSEC,
		"retard borné sous contrôle")

func test_queue_is_bounded():
	var po := VideoPlayout.new()
	for i in 30:
		po.push(i, i * 16, 0, _img())
	return Runner.assert_eq(po.queued(), VideoPlayout.MAX_QUEUED, "file bornée")

func test_reorder_by_seq():
	var po := VideoPlayout.new()
	po.push(1, 16, 100, _img())
	var first := _img()
	po.push(0, 0, 100, first)
	return Runner.assert_true(po.pop_due(200) != first, "la plus récente due est rendue, dans l'ordre des seq")
