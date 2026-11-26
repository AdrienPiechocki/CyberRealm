extends Node
## Sélection de zone (capture d'une partie de fenêtre) en mode focus.
##
## Module de FocusMode (nœud enfant « ZoneSelect »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

## Mode focus : affiche une fenêtre en 2D plein écran (TextureRect) et route
## tout l'input clavier + souris vers elle, jusqu'à la sortie (même raccourci
## que l'entrée, ex. Super+F).
## Gère une PILE de fenêtres : une nouvelle fenêtre ouverte pendant le mode
## focus s'ajoute par-dessus la fenêtre active (auto via window_mapped, voir
## wayland_room.gd) ; la fermeture de la fenêtre active (kill) fait retomber
## le focus sur la précédente. Chaque fenêtre conserve son propre état (taille
## d'origine, position du curseur, pointer lock, popups).
## L'input pointeur va à la fenêtre SURVOLÉE de la pile (pas seulement à la
## fenêtre active) ; un appui bouton sur une fenêtre d'arrière-plan la remonte
## au sommet de la pile et l'active. Chaque fenêtre (sauf la plein écran) a
## une BARRE DE TITRE dessinée au-dessus de son contenu (décoration 2D façon
## windows_3d.gd) : clic-glisser dessus déplace la fenêtre sans modificateur ;
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const ZoneSelectMarqueeScript := preload("res://scripts/ui/zone_select_marquee.gd")
const ZONE_MIN_PX := 5.0
const ZONE_DIM_ALPHA := 0.3
var _zone_drag_start := Vector2.ZERO
var _zone_dragging := false
var _zone_rect := Rect2()
var _zone_dim: ColorRect
var _zone_marquee
var _zone_restore_capture := false

# ── Sélection de zone (PrtSc) ──────────────────────────────────────────

# Crée paresseusement l'overlay d'assombrissement + la marquise de sélection,
# posés au-dessus de tous les overlays du focus (z_index 3001/3002).
func _ensure_zone_overlays() -> void:
	if _zone_dim == null or not is_instance_valid(_zone_dim):
		_zone_dim = ColorRect.new()
		_zone_dim.color = Color(0.0, 0.0, 0.0, ZONE_DIM_ALPHA)
		_zone_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_zone_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		_zone_dim.z_index = 3001
		fm.ui.add_child(_zone_dim)
	if _zone_marquee == null or not is_instance_valid(_zone_marquee):
		_zone_marquee = ZoneSelectMarqueeScript.new()
		_zone_marquee.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_zone_marquee.set_anchors_preset(Control.PRESET_FULL_RECT)
		_zone_marquee.z_index = 3002
		fm.ui.add_child(_zone_marquee)

# Arme l'outil : assombrit l'écran, libère la souris si la fenêtre active
# était en pointer-lock (recapturée à la fin), remet à zéro l'état de
# drag fenêtre (les appuis du glisser seraient sinon retracés comme un
# déplacement de fenêtre à la sortie de l'outil).
func _start_zone_selection() -> void:
	if fm.zone_select_active:
		return
	fm.zone_select_active = true
	_zone_dragging = false
	_zone_rect = Rect2()
	_zone_restore_capture = false
	if fm.focus_mode and not fm.remote_focus and fm._active_id() != -1:
		var st := fm._state(fm._active_id())
		if st.get("mouse_captured", false):
			_zone_restore_capture = true
	fm.window_move_id = -1
	fm.window_press_id = -1
	fm.window_press_buttons = 0
	_ensure_zone_overlays()
	_zone_dim.visible = true
	_zone_marquee.visible = true
	_zone_marquee.set_select_rect(Rect2())
	if _zone_restore_capture:
		fm.input._hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# Termine la sélection. capture=true : émet la zone si >= ZONE_MIN_PX ;
# sinon annule (Escape, zone trop petite). Les overlays sont masqués AVANT
# l'émission : wayland_room capture le viewport après le render de la frame,
# la marquise n'apparaît donc pas dans le cliché.
func _end_zone_selection(capture: bool) -> void:
	var rect := _zone_rect
	_restore_capture_after_zone()
	fm.zone_select_active = false
	_zone_dragging = false
	if _zone_dim != null and is_instance_valid(_zone_dim):
		_zone_dim.visible = false
	if _zone_marquee != null and is_instance_valid(_zone_marquee):
		_zone_marquee.visible = false
	if capture and rect.size.x >= ZONE_MIN_PX and rect.size.y >= ZONE_MIN_PX:
		fm.zone_capture_selected.emit(rect)

func _cancel_zone_selection() -> void:
	_end_zone_selection(false)

func _restore_capture_after_zone() -> void:
	if not _zone_restore_capture:
		return
	_zone_restore_capture = false
	if fm.focus_mode and not fm.remote_focus and fm._active_id() != -1:
		if fm._state(fm._active_id()).get("mouse_captured", false):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	fm.input._hide_cursor_overlay()

# Polling de l'outil, appelé en tête de handle_focus_input tant qu'il est
# actif : glisser du bouton gauche = marquise, relâchement = capture.
func _handle_zone_selection() -> void:
	# La branche zone de handle_focus_input retourne tôt : sans réémission,
	# l'overlay du curseur custom resterait figé à sa dernière position
	# (« curseur gelé ») et le choix du point de départ se ferait à l'aveugle.
	# On repositionne le curseur chaque frame sur mouse_pos, à l'échelle de la
	# fenêtre focalisée — y compris pour une fenêtre FPS en pointer-lock, dont
	# le curseur capturé est alors re-découvert et suit la souris libérée.
	if not fm.remote_focus and fm._active_id() != -1:
		var zid := fm._active_id()
		var zst := fm._state(zid)
		var zdisp := fm._displayed_rect(zid)
		var zscale := Vector2.ONE
		if zdisp.size.x > 0.0 and zst["surface_size"].x > 0.0:
			zscale = zdisp.size / zst["surface_size"]
		fm.input._update_cursor_overlay(zid, fm.mouse_pos, zscale)
	fm.input._poll_left_button()
	if fm.input._left_press_this_frame():
		_zone_drag_start = fm.mouse_pos
		_zone_dragging = true
	if _zone_dragging:
		_zone_rect = Rect2(
			Vector2(minf(_zone_drag_start.x, fm.mouse_pos.x), minf(_zone_drag_start.y, fm.mouse_pos.y)),
			Vector2(absf(fm.mouse_pos.x - _zone_drag_start.x), absf(fm.mouse_pos.y - _zone_drag_start.y)))
		if _zone_marquee != null and is_instance_valid(_zone_marquee):
			_zone_marquee.set_select_rect(_zone_rect)
	if fm.input._left_release_this_frame() and _zone_dragging:
		_end_zone_selection(true)

# Convertit un rectangle écran (sélection de zone en mode focus) en rectangle
# entier de pixels de l'image capturée, clampé aux bornes de l'image : les
# coins sont arrondis et toute portion hors image est retranchée (une
# sélection débordant de l'écran doit capturer la partie visible, jamais un
# pixel hors du viewport).
static func zone_rect_to_int(rect: Rect2, img_size: Vector2i) -> Rect2i:
	var w := maxi(img_size.x, 0)
	var h := maxi(img_size.y, 0)
	var x0 := clampi(int(floor(rect.position.x)), 0, w)
	var y0 := clampi(int(floor(rect.position.y)), 0, h)
	var x1 := clampi(int(ceil(rect.end.x)), x0, w)
	var y1 := clampi(int(ceil(rect.end.y)), y0, h)
	return Rect2i(x0, y0, x1 - x0, y1 - y0)
