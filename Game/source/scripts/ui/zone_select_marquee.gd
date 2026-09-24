extends Control
## Marquise de sélection de zone (PrtSc en mode focus) : fill semi-transparent
## + bordure blanche dessinées en _draw(). Le rectangle est fourni par
## set_select_rect() ; un rectangle vide (ou de taille nulle) n'affiche rien.
## Control non interactif (MOUSE_FILTER_IGNORE) : le routage de l'input reste
## à la charge de focus_mode.gd.

const FILL_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const BORDER_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const BORDER_WIDTH := 2.0

var _sel_rect := Rect2()

func set_select_rect(rect: Rect2) -> void:
	_sel_rect = rect
	queue_redraw()

func get_select_rect() -> Rect2:
	return _sel_rect

func _draw() -> void:
	if not has_point_positive():
		return
	draw_rect(_sel_rect, FILL_COLOR)
	# Bordure bornée à la moitié de la plus petite dimension : un carré trop
	# fin (drag de 2 px) ne peut pas recevoir une bordure de 2 px entière.
	# Bordure bornée à la moitié de la plus petite dimension : un carré trop
	# fin (drag de 2 px) ne peut pas recevoir une bordure de 2 px entière.
	var w: float = minf(BORDER_WIDTH, minf(_sel_rect.size.x, _sel_rect.size.y) * 0.5)
	draw_rect(_sel_rect, BORDER_COLOR, false, w)

func has_point_positive() -> bool:
	return _sel_rect.size.x > 0.0 and _sel_rect.size.y > 0.0