extends Node
## Tests du recadrage de la capture de zone (mode focus).
## La sélection de zone en mode focus (PrtSc) dessine un carré à l'écran et
## recadre la capture du viewport dessus. Le rectangle écran est converti en
## coordonnées d'image entières avec un clamp : les débords (sélection trop
## grande, hors écran) sont ramenés aux bornes de l'image, jamais négatifs.
## Le helper testé est zone_rect_to_int() (statique, focus_mode.gd).

const FocusModeScript := preload("res://scripts/windows/focus_mode.gd")

func _rect2i(rect: Rect2, img_size: Vector2i) -> Rect2i:
	return FocusModeScript.zone_rect_to_int(rect, img_size)

func test_zone_rect_inside_kept() -> Variant:
	var out := _rect2i(Rect2(10, 20, 300, 200), Vector2i(1920, 1080))
	if out.position != Vector2i(10, 20):
		return "position attendue 10,20 trouvée %s" % str(out.position)
	if out.size != Vector2i(300, 200):
		return "taille attendue 300,200 trouvée %s" % str(out.size)
	return true

func test_zone_rect_fractional_covers_touched_pixels() -> Variant:
	# floor(start) + ceil(end) : toute la surface touchée par la sélection est
	# incluse (pixel partiellement couvert compris).
	var out := _rect2i(Rect2(10.4, 20.6, 300, 200), Vector2i(1920, 1080))
	if out.position != Vector2i(10, 20):
		return "position attendue 10,20 (floor) trouvée %s" % str(out.position)
	if out.end != Vector2i(311, 221):
		return "fin attendue 311,221 (ceil) trouvée %s" % str(out.end)
	return true

func test_zone_rect_clamps_negative() -> Variant:
	var out := _rect2i(Rect2(-50, -30, 200, 150), Vector2i(640, 480))
	if out.position.x != 0 or out.position.y != 0:
		return "position négative non ramenée à zéro : %s" % str(out.position)
	# Le rect visible déborde de (-50,-30) à (150,120) : le clamp garde la
	# portion réellement à l'écran, la taille n'est pas décalée en aveugle.
	if out.end.x != 150 or out.end.y != 120:
		return "fin attendue 150,120 trouvée %s (portion visible seule)" % str(out.end)
	return true

func test_zone_rect_clamps_overflow() -> Variant:
	var out := _rect2i(Rect2(600, 400, 400, 300), Vector2i(640, 480))
	if out.end.x != 640 or out.end.y != 480:
		return "débord non clampé aux bornes : %s (end attendu 640,480)" % str(out.end)
	if out.position.x != 600 or out.position.y != 400:
		return "position d'origine modifiée par le clamp : %s" % str(out.position)
	return true

func test_zone_rect_empty_image_safe() -> Variant:
	var out := _rect2i(Rect2(-5, -5, 100, 100), Vector2i(0, 0))
	if out.size != Vector2i.ZERO:
		return "image vide : taille attendue 0,0 trouvée %s" % str(out.size)
	return true