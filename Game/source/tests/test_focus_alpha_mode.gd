extends Node
## Tests du mode alpha des overlays focus (focus_mode.gd) : une fenêtre
## probe-classée OPAQUE (occludeur actif) doit être affichée en opaque_mode
## (alpha normalisé façon 3D), sinon l'UI semi-transparente composée dans le
## buffer (inventaires de jeux, menus...) porte un alpha réel < 1 qui révélerait
## l'environnement 3D derrière l'overlay au lieu du contenu de l'app. Une
## fenêtre réellement translucide (occludeur suspendu, ex. Konsole) garde son
## alpha brut.

const FocusScript := preload("res://scripts/windows/focus_mode.gd")

var focus: Node3D

func _setup() -> Variant:
	focus = Node3D.new()
	focus.set_script(FocusScript)
	get_tree().root.add_child(focus)
	return true

func _teardown() -> void:
	if focus != null and is_instance_valid(focus):
		focus.free()

func _make_overlay() -> TextureRect:
	var rect := TextureRect.new()
	var shader := Shader.new()
	shader.code = FocusScript.POPUP_CROP_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	rect.material = mat
	focus.focus_rects[1] = rect
	focus.focus_fullscreen_id = 1
	return rect

func test_opaque_mode_reflects_occluder_suspended() -> Variant:
	if _setup() != true:
		return "setup"
	var rect := _make_overlay()
	focus._occluder_suspended = false
	focus._apply_focus_alpha_mode()
	if rect.material.get_shader_parameter("opaque_mode") != true:
		return "fenêtre probe-opaque → opaque_mode devrait être vrai"
	focus._occluder_suspended = true
	focus._apply_focus_alpha_mode()
	if rect.material.get_shader_parameter("opaque_mode") != false:
		return "fenêtre translucide (occludeur suspendu) → opaque_mode devrait être faux"
	_teardown()
	return true

func test_focus_window_alpha_mode() -> Variant:
	if _setup() != true:
		return "setup"
	focus._occluder_suspended = false
	if focus._focus_window_alpha_mode() != true:
		return "alpha mode devrait être opaque tant que l'occludeur n'est pas suspendu"
	focus._occluder_suspended = true
	if focus._focus_window_alpha_mode() != false:
		return "alpha mode devrait être brut quand l'occludeur est suspendu"
	_teardown()
	return true

func test_shader_has_opaque_mode_branch() -> Variant:
	var code: String = FocusScript.POPUP_CROP_SHADER_CODE
	if not code.contains("opaque_mode"):
		return "POPUP_CROP_SHADER_CODE devrait gérer opaque_mode sinon le fix disparaît silencieusement"
	_teardown()
	return true