extends Node3D
## Bouton cliquable d'un objet du bureau (lot L) : interact() appelle on_press(player_id).

var on_press: Callable
var prompt := "Left click"
var _label: Label3D
var _mat: StandardMaterial3D

func build(text: String, size: Vector2, p_on_press: Callable, p_prompt: String) -> void:
	on_press = p_on_press
	prompt = p_prompt
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size.x, size.y, 0.01)
	mi.mesh = box
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.16, 0.18, 0.24)
	mi.material_override = _mat
	add_child(mi)
	_label = Label3D.new()
	_label.text = text
	_label.font_size = 40
	_label.pixel_size = 0.0008
	_label.position = Vector3(0, 0, 0.008)
	add_child(_label)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, 0.02)
	col.shape = shape
	body.add_child(col)
	add_child(body)

func set_text(t: String) -> void:
	if _label != null:
		_label.text = t

func interact(player_id: int) -> void:
	if on_press.is_valid():
		on_press.call(player_id)

func get_interact_prompt() -> String:
	return prompt

func interact_focus(aimed: bool) -> void:
	if _mat != null:
		_mat.albedo_color = Color(0.28, 0.32, 0.45) if aimed else Color(0.16, 0.18, 0.24)
