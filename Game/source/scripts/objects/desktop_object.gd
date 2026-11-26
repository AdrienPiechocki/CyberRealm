extends Node3D
## Base des objets reliés au bureau (lot L, scenes/objects/) : panneau, textes, boutons cliquables.
##
## Chaque machine affiche SES données (MPRIS, notifications, état du système) ; rien n'est diffusé. interact() est
## appelé sur toutes les machines par le relais réseau (world_interactor.gd) : on n'agit que pour le joueur local.

const DesktopButton := preload("res://scripts/objects/desktop_button.gd")

func bridge() -> Node:
	return get_tree().get_first_node_in_group("desktop_bridge") if is_inside_tree() else null

func is_local_player(player_id: int) -> bool:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return true
	return player_id == multiplayer.get_unique_id()

## Panneau sombre (boîte plate) de `size` mètres, face avant vers +Z.
func make_panel(size: Vector2, color := Color(0.06, 0.07, 0.09)) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size.x, size.y, 0.02)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	mi.material_override = mat
	add_child(mi)
	return mi

## Collider plat couvrant le panneau (clic sur l'objet entier).
func make_body(size: Vector2) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, 0.03)
	col.shape = shape
	body.add_child(col)
	add_child(body)
	return body

func make_label(text: String, pos: Vector2, font_size := 32, color := Color(0.9, 0.92, 0.95), width := 0.0) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font_size
	l.pixel_size = 0.0008
	l.modulate = color
	l.outline_size = 0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.position = Vector3(pos.x, pos.y, 0.012)
	if width > 0.0:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.width = width / l.pixel_size
	add_child(l)
	return l

## Barre horizontale (fond + remplissage) ; renvoie le remplissage, dont set_bar() règle la longueur.
func make_bar(pos: Vector2, size: Vector2, color: Color) -> MeshInstance3D:
	var bg := MeshInstance3D.new()
	var bgm := BoxMesh.new()
	bgm.size = Vector3(size.x, size.y, 0.004)
	bg.mesh = bgm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.18, 0.19, 0.22)
	bg.material_override = bmat
	bg.position = Vector3(pos.x + size.x / 2.0, pos.y, 0.012)
	add_child(bg)
	var fill := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(size.x, size.y, 0.006)
	fill.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = color
	fmat.emission_enabled = true
	fmat.emission = color * 0.4
	fill.material_override = fmat
	fill.set_meta("bar_x", pos.x)
	fill.set_meta("bar_w", size.x)
	fill.position = Vector3(pos.x, pos.y, 0.014)
	add_child(fill)
	set_bar(fill, 0.0)
	return fill

static func set_bar(fill: MeshInstance3D, ratio: float) -> void:
	var w: float = fill.get_meta("bar_w")
	var r := clampf(ratio, 0.0, 1.0)
	fill.scale = Vector3(maxf(r, 0.001), 1, 1)
	fill.position.x = float(fill.get_meta("bar_x")) + w * r / 2.0

func make_button(text: String, pos: Vector2, size: Vector2, on_press: Callable, prompt: String) -> Node3D:
	var b: Node3D = DesktopButton.new()
	b.position = Vector3(pos.x, pos.y, 0.02)
	add_child(b)
	b.build(text, size, on_press, prompt)
	return b
