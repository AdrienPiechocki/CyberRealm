extends Node
## Shaders personnalisés des fenêtres : exemples livrés valides, résolution
## user:// > res://, transition appliquée puis restaurée.

const WindowShaders := preload("res://scripts/windows/window_shaders.gd")

func _load_example(name: String) -> Shader:
	var s := Shader.new()
	s.code = FileAccess.get_file_as_string("res://ui/decorations/examples/" + name)
	return s

func test_examples_are_spatial() -> Variant:
	for n: String in ["window_open.gdshader", "window_close.gdshader", "window_border.gdshader"]:
		var s := _load_example(n)
		if s.code == "":
			return n + " introuvable"
		if s.get_mode() != Shader.MODE_SPATIAL:
			return n + " n'est pas spatial"
	return true

func test_no_shader_means_no_transition() -> Variant:
	if WindowShaders.path_for("bogus") != "":
		return "type inconnu"
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.material_override = ShaderMaterial.new()
	var user_present := WindowShaders.path_for("open") != ""
	var mats: Array = WindowShaders.begin_transition(quad, "open")
	quad.free()
	if not user_present and not mats.is_empty():
		return "transition sans shader"
	return true

func test_transition_swaps_and_restores() -> Variant:
	var path := "user://window_open.gdshader"
	if FileAccess.file_exists(path):
		return true # ne pas écraser le fichier du joueur
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string("res://ui/decorations/examples/window_open.gdshader"))
	f.close()
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	var orig := ShaderMaterial.new()
	quad.material_override = orig
	var mats: Array = WindowShaders.begin_transition(quad, "open")
	var swapped: bool = quad.material_override != orig and mats.size() == 1
	WindowShaders.end_transition(quad)
	var restored: bool = quad.material_override == orig
	quad.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if not swapped:
		return "matériau non remplacé"
	if not restored:
		return "matériau non restauré"
	return true
