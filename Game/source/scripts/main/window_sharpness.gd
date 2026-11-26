extends Node
## Netteté selon la distance (lot H, wp_fractional_scale_v1).
##
## Une fenêtre vue de près reçoit une échelle > 1 : le client rend plus de pixels pour la même taille logique et le
## texte devient net. Quatre fois par seconde, pour chaque fenêtre locale : hauteur projetée du quad à l'écran (px)
## / hauteur logique de la fenêtre, quantifiée sur LEVELS et bornée par l'option (General > Window sharpness).
## Une nouvelle échelle n'est appliquée qu'après STABLE_SEC de stabilité (chaque changement fait re-rendre le client
## en entier), sauf sous forte pression GPU où l'on redescend tout de suite.
## Toujours 1 : fenêtre cachée, épinglée (PiP), affichée par le mode focus (déjà au pixel près), derrière la caméra,
## et pendant un déplacement / redimensionnement (la conversion des tailles est figée au début du geste).
## Le compositeur ignore les fenêtres X11 (xwayland-satellite).

const LEVELS := [1.0, 1.25, 1.5, 2.0]
const TICK_SEC := 0.25
const STABLE_SEC := 1.0

var compositor: Object = null
var win3d: Node = null
var focus: Node = null
var pins: Node = null
var settings: Node = null           # pause_menu : get_window_sharpness_max()

var _cd := 0.0
var _pending: Dictionary = {}       # wid -> {scale, since}

func setup(p_compositor: Object, p_win3d: Node, p_focus: Node, p_pins: Node, p_settings: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	pins = p_pins
	settings = p_settings

func on_window_unmapped(id: int) -> void:
	_pending.erase(id)

func _process(delta: float) -> void:
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = TICK_SEC
	if compositor == null or win3d == null or not compositor.has_method("set_window_scale"):
		return
	var now := Time.get_ticks_msec() / 1000.0
	var max_scale := _max_scale()
	var pressure: int = int(compositor.get_capture_pressure()) if compositor.has_method("get_capture_pressure") else 0
	var cap := pressure_cap(max_scale, pressure)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var interacting: bool = win3d.has_method("is_window_interacting") and win3d.is_window_interacting()
	for wid in win3d.quads.keys():
		var quad: Node3D = win3d.quads[wid]
		if not is_instance_valid(quad):
			continue
		var current := float(compositor.get_window_scale(wid))
		if interacting and max_scale > 1.0:
			_pending.erase(wid)
			continue
		var target := 1.0
		var eligible := _eligible(wid, quad)
		if max_scale > 1.0 and eligible:
			target = quantize(desired_scale(cam, quad, wid, current), cap)
		if is_equal_approx(target, current):
			_pending.erase(wid)
			continue
		# Sous forte pression, option coupée, fenêtre cachée / épinglée / en mode focus : redescente immédiate.
		if target < current and (pressure >= 2 or max_scale <= 1.0 or not eligible):
			compositor.set_window_scale(wid, target)
			_pending.erase(wid)
			continue
		var p: Dictionary = _pending.get(wid, {})
		if p.is_empty() or not is_equal_approx(float(p["scale"]), target):
			_pending[wid] = {"scale": target, "since": now}
		elif now - float(p["since"]) >= STABLE_SEC:
			compositor.set_window_scale(wid, target)
			_pending.erase(wid)

func _max_scale() -> float:
	if settings != null and settings.has_method("get_window_sharpness_max"):
		return float(settings.get_window_sharpness_max())
	return 1.0

func _eligible(wid: int, quad: Node3D) -> bool:
	if not quad.is_visible_in_tree():
		return false
	if pins != null and pins.has_method("is_pinned") and pins.is_pinned(wid):
		return false
	if focus != null and focus.has_method("is_active") and focus.is_active():
		return false        # l'overlay 2D affiche la fenêtre au pixel près : rien à gagner
	return true

## Échelle voulue : pixels à l'écran par pixel logique (hauteur du quad projetée / hauteur logique).
func desired_scale(cam: Camera3D, quad: Node3D, wid: int, current: float) -> float:
	if cam == null or not (quad is MeshInstance3D) or not ((quad as MeshInstance3D).mesh is QuadMesh):
		return 1.0
	var h: float = ((quad as MeshInstance3D).mesh as QuadMesh).size.y
	var top: Vector3 = quad.global_transform * Vector3(0, h * 0.5, 0)
	var bottom: Vector3 = quad.global_transform * Vector3(0, -h * 0.5, 0)
	if cam.is_position_behind(top) or cam.is_position_behind(bottom):
		return 1.0
	var px_h := cam.unproject_position(top).distance_to(cam.unproject_position(bottom))
	var body: Node = quad.get_child(0) if quad.get_child_count() > 0 else null
	var surf: Vector2 = body.get_meta("surface_size", Vector2.ZERO) if body != null else Vector2.ZERO
	var logical_h := surf.y / maxf(current, 1.0)
	if logical_h < 1.0:
		return 1.0
	return px_h / logical_h

# ── Logique pure (testée) ──────────────────────────────────────────────

## Plus grand palier atteint (avec 10 % de tolérance), borné par `cap`.
static func quantize(desired: float, cap: float) -> float:
	var out := 1.0
	for l in LEVELS:
		if l <= cap + 0.001 and desired + 0.1 >= l:
			out = l
	return out

## Sous pression GPU les échelles redescendent d'abord : palier 1 -> 1.25 au plus, palier 2 -> 1.
static func pressure_cap(max_scale: float, pressure: int) -> float:
	if pressure >= 2:
		return 1.0
	if pressure == 1:
		return minf(max_scale, 1.25)
	return max_scale
