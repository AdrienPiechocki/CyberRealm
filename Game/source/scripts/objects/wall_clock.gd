extends "res://scripts/objects/desktop_object.gd"
## Horloge murale (lot L) : l'heure réelle de la machine du joueur.

const SIZE := Vector2(0.5, 0.2)

var _time: Label3D
var _date: Label3D
var _last := ""

func _ready() -> void:
	make_panel(SIZE)
	_time = make_label("", Vector2(0, 0.075), 120, Color(0.85, 0.95, 1))
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_date = make_label("", Vector2(0, -0.045), 28, Color(0.6, 0.65, 0.75))
	_date.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _process(_delta: float) -> void:
	var t := Time.get_time_string_from_system()
	if t == _last:
		return
	_last = t
	_time.text = t.substr(0, 5)
	_date.text = Time.get_date_string_from_system()
