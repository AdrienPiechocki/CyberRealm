extends CanvasLayer
## Curseur logiciel pour le DisplayServer "kms" : sans compositeur hôte,
## personne ne dessine le pointeur. Inactif sous Wayland/X11.

var _arrow: Node2D

func _ready() -> void:
	if DisplayServer.get_name() != "kms":
		# queue_free() est différé à la fin de la frame : _process tournerait
		# encore une fois avec _arrow nul (erreur à chaque lancement hors KMS).
		set_process(false)
		queue_free()
		return
	# Sans fenêtre hôte, les popups (menus déroulants, sélecteur de couleur) sont des
	# sous-fenêtres INTÉGRÉES, dessinées par Godot sur une couche de canvas à 1024
	# (Viewport::SUBWINDOW_CANVAS_LAYER) : le curseur doit être au-dessus, sinon il
	# passe dessous.
	layer = 1025
	process_mode = Node.PROCESS_MODE_ALWAYS
	_arrow = _CursorShape.new()
	add_child(_arrow)

func _process(_delta: float) -> void:
	_arrow.visible = Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	if _arrow.visible:
		_arrow.position = get_viewport().get_mouse_position()

class _CursorShape extends Node2D:
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 17), Vector2(4, 13), Vector2(7, 20),
		Vector2(10, 19), Vector2(7, 12), Vector2(12, 12)])

	func _draw() -> void:
		draw_colored_polygon(points, Color.WHITE)
		draw_polyline(points + PackedVector2Array([points[0]]), Color.BLACK, 1.5, true)
