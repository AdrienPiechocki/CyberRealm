extends Node3D
## Résolution 3D adaptative : sur les GPU intégrés (Iris Xe…), le coût de
## shading à pleine résolution peut saturer le GPU même après occlusion
## culling. Quand les FPS chutent, on abaisse par paliers la résolution
## INTERNE du rendu 3D (scaling_3d_scale, upscale bilinéaire gratuit) et on
## remonte dès que la marge revient — indépendamment de la taille des
## fenêtres Wayland capturées, qui restent nettes côté compositeur.
##
## Désactivable avec CYBERREALM_ADAPTIVE_SCALE=0. Chaque changement est
## loggé ([scaler]) pour la traçabilité.

const MIN_LEVEL := 0      # pleine résolution
const MAX_LEVEL := 4      # = MIN_SCALE
const MAX_SCALE := 1.0
const STEP := 0.1
const MIN_SCALE := 0.6    # MAX_SCALE - MAX_LEVEL * STEP
const DOWN_FPS := 45.0    # sous ce seuil soutenu : descente d'un palier
const UP_FPS := 58.0      # au-dessus de ce seuil soutenu : montée d'un palier
const WINDOW_SEC := 2.0   # fenêtre de mesure des FPS
const GRACE_DOWN_SEC := 3.0 # délai min entre deux changements
const GRACE_UP_SEC := 8.0   # remontée plus prudente (anti-yo-yo)

var _enabled := true
var _level := MIN_LEVEL
var _accum := 0.0
var _frames := 0
var _cooldown := 0.0

func _ready() -> void:
	_enabled = OS.get_environment("CYBERREALM_ADAPTIVE_SCALE") != "0"
	if not _enabled:
		print("[scaler] désactivé (CYBERREALM_ADAPTIVE_SCALE=0)")

func _process(delta: float) -> void:
	if not _enabled:
		return
	_cooldown -= delta
	_accum += delta
	_frames += 1
	if _accum < WINDOW_SEC:
		return
	var fps := _frames / _accum
	_accum = 0.0
	_frames = 0
	if _cooldown > 0.0:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var cur: float = vp.scaling_3d_scale
	if fps < DOWN_FPS and _level < MAX_LEVEL:
		_level += 1
		_apply(vp, cur, fps)
		_cooldown = GRACE_DOWN_SEC
	elif fps > UP_FPS and _level > MIN_LEVEL:
		_level -= 1
		_apply(vp, cur, fps)
		_cooldown = GRACE_UP_SEC

func _apply(vp: Viewport, prev: float, fps: float) -> void:
	var next := MAX_SCALE - _level * STEP
	vp.scaling_3d_scale = next
	print("[scaler] FPS %.0f — résolution 3D %.2f → %.2f" % [fps, prev, next])
