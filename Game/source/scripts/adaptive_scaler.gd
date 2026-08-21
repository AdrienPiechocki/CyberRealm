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
const MAX_LEVEL := 5      # = MIN_SCALE
const MAX_SCALE := 1.0
const STEP := 0.1
const MIN_SCALE := 0.5    # MAX_SCALE - MAX_LEVEL * STEP
# Seuils RELATIFS au PLAFOND de FPS effectif : min(refresh écran, max_fps).
# La vsync ET Engine.max_fps bornent les FPS mesurés ; comparer au seul
# refresh rend les seuils aveugles dès qu'un limiteur plafonne plus bas
# (max_fps=60 sur écran 165 Hz : 60 fps lus, zéro info de saturation →
# descente jusqu'en bas). Sous 90 % du plafond soutenu : descente d'un
# palier ; au-dessus de 97 % : montée. Avec un plafond à 60 : descente
# < 54, montée > 58.2 — le scaler maintient alors le cap de 60 fps à la
# meilleure résolution possible, sans zone morte.
const DOWN_RATIO := 0.90
const UP_RATIO := 0.97
const DEFAULT_REFRESH := 60.0 # secours si le refresh rate est indisponible
const STARTUP_GRACE_SEC := 5.0 # ignore les hoquets de démarrage (compil shaders…)
const WINDOW_SEC := 2.0   # fenêtre de mesure des FPS
const GRACE_DOWN_SEC := 3.0 # délai min entre deux changements
const GRACE_UP_SEC := 8.0   # remontée plus prudente (anti-yo-yo)

var _enabled := true
var _down_fps := DEFAULT_REFRESH * DOWN_RATIO
var _up_fps := DEFAULT_REFRESH * UP_RATIO
var _level := MIN_LEVEL
var _accum := 0.0
var _frames := 0
var _cooldown := 0.0

func _ready() -> void:
	_enabled = OS.get_environment("CYBERREALM_ADAPTIVE_SCALE") != "0"
	if not _enabled:
		print("[scaler] désactivé (CYBERREALM_ADAPTIVE_SCALE=0)")
		return
	# Refresh de l'écran portant la fenêtre (-1/0 = indisponible, ex. headless).
	var refresh := DisplayServer.screen_get_refresh_rate()
	if refresh <= 0.0:
		refresh = DEFAULT_REFRESH
	# Plafond effectif des FPS mesurés : la vsync (refresh) ET Engine.max_fps
	# (posé par wayland_room avant la création de ce node) bornent tous les
	# deux les FPS lus ; le plus bas des deux gagne.
	var ceiling := refresh
	if Engine.max_fps > 0:
		ceiling = minf(ceiling, float(Engine.max_fps))
	_down_fps = ceiling * DOWN_RATIO
	_up_fps = ceiling * UP_RATIO
	# Grâce de démarrage : les premières secondes voient des hoquets (compil
	# shaders, bake occlusion, captures qui démarrent) — ne pas en déduire
	# une saturation.
	_cooldown = STARTUP_GRACE_SEC
	print("[scaler] écran=%.0f Hz max_fps=%d — plafond %.0f fps, seuils descente<%.1f montée>%.1f" % [
		refresh, Engine.max_fps, ceiling, _down_fps, _up_fps])

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
	if fps < _down_fps and _level < MAX_LEVEL:
		_level += 1
		_apply(vp, cur, fps)
		_cooldown = GRACE_DOWN_SEC
	elif fps > _up_fps and _level > MIN_LEVEL:
		_level -= 1
		_apply(vp, cur, fps)
		_cooldown = GRACE_UP_SEC

func _apply(vp: Viewport, prev: float, fps: float) -> void:
	var next := MAX_SCALE - _level * STEP
	vp.scaling_3d_scale = next
	print("[scaler] FPS %.0f — résolution 3D %.2f → %.2f" % [fps, prev, next])
