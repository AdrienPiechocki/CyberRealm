extends Node3D
## Stub de `windows_3d.gd` pour les tests du mode focus.
## `focus_mode.gd` lit `windows.quads`, `windows.get_quad_info`, `windows.get_window_image`.

var window_titles: Dictionary = {}
var window_server_side: Dictionary = {}
var quads: Dictionary = {}

func ensure_quad(id: int, title: String, app_id: String, size: Vector2) -> void:
	window_titles[id] = title
	window_server_side[id] = app_id
	# Créer un noeud factice pour représenter le quad
	var q := Node3D.new()
	add_child(q)
	quads[id] = q

func get_quad_info(id: int) -> Dictionary:
	return {
		"surface_size": Vector2(800, 600),
		"content_size": Vector2(800, 600),
		"frame_size": Vector2(800, 600),
		"visible_half_extent": Vector2(400, 300),
		"visual_center": Vector3(0, 0, 0),
		"is_popup": false,
	}

func get_window_image(_id: int) -> Image:
	return Image.new()

func set_fullscreen_quad(_id: int, _fs: bool) -> void:
	pass
