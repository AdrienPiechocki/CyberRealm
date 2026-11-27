extends RefCounted
## Tampon de lecture (gigue) d'un flux vidéo distant : chaque image décodée est affichée à son heure de capture
## chez l'émetteur + un retard constant, au lieu de l'être dès son arrivée.
##
## Sans lui, trois horloges à 60 Hz non synchronisées (boucle de l'émetteur, relais du serveur dédié, boucle du
## récepteur) faisaient arriver régulièrement deux images dans le même tick : la première était jetée, puis le tick
## suivant n'avait rien à afficher (saccade bien visible sur une vidéo). Le retard suit la gigue mesurée (min/max de
## « arrivée − capture » sur une fenêtre glissante, qui absorbe aussi la dérive d'horloge entre les machines) et peut
## être allongé par l'appelant pour rester calé sur le son de la fenêtre.

const WINDOW_MSEC := 3000      # fenêtre de mesure de la gigue
const MARGIN_MSEC := 6.0       # au-delà de la pire gigue vue
const MIN_DELAY_MSEC := 10.0
const MAX_DELAY_MSEC := 250.0
const DECAY_MSEC_PER_SEC := 30.0 # baisse du retard : progressive (quelques images un peu plus tôt, pas de saut)
const MAX_QUEUED := 10         # images RGBA en attente (1080p ≈ 8 Mo chacune)

var _samples: Array = []        # [[arrivée msec, arrivée − capture], ...]
var _base := INF                # min de (arrivée − capture) sur la fenêtre
var _jitter := 0.0              # max − min sur la fenêtre
var _delay := -1.0              # retard appliqué (msec) au-delà du chemin le plus rapide
var _last_tick := -1
var _queue: Array = []          # [[capture msec, seq, Image], ...] trié par seq
var dropped := 0                # images jetées (file pleine ou dépassées) : diagnostic

func reset() -> void:
	_samples.clear()
	_base = INF
	_jitter = 0.0
	_delay = -1.0
	_last_tick = -1
	_queue.clear()

## Image décodée à `now` (msec local) ; `t_capture` = heure de capture chez l'émetteur (son horloge).
func push(seq: int, t_capture: int, now: int, img: Image) -> void:
	_samples.append([now, float(now - t_capture)])
	while not _samples.is_empty() and now - int(_samples[0][0]) > WINDOW_MSEC:
		_samples.pop_front()
	var lo := INF
	var hi := -INF
	for s in _samples:
		lo = minf(lo, s[1])
		hi = maxf(hi, s[1])
	_base = lo
	_jitter = hi - lo
	var i := _queue.size()
	while i > 0 and int(_queue[i - 1][1]) > seq:
		i -= 1
	_queue.insert(i, [t_capture, seq, img])
	while _queue.size() > MAX_QUEUED:
		_queue.pop_front()
		dropped += 1

## Retard visé : gigue mesurée, ou `min_delay` (son de la fenêtre) s'il est plus grand.
func target_delay(min_delay: float) -> float:
	return clampf(maxf(_jitter + MARGIN_MSEC, min_delay), MIN_DELAY_MSEC, MAX_DELAY_MSEC)

func current_delay() -> float:
	return _delay

## Image à afficher à `now` (null si aucune n'est due). S'il en est dû plusieurs (récepteur plus lent que le flux),
## seule la plus récente est rendue.
func pop_due(now: int, min_delay: float = 0.0) -> Image:
	if _queue.is_empty():
		_last_tick = now
		return null
	var target := target_delay(min_delay)
	if _delay < 0.0 or target > _delay:
		_delay = target
	elif _last_tick >= 0:
		_delay = maxf(target, _delay - DECAY_MSEC_PER_SEC * float(now - _last_tick) / 1000.0)
	_last_tick = now
	var due: Image = null
	var n := 0
	while not _queue.is_empty() and float(_queue[0][0]) + _base + _delay <= float(now):
		due = _queue.pop_front()[2]
		n += 1
	if n > 1:
		dropped += n - 1
	return due

func queued() -> int:
	return _queue.size()
