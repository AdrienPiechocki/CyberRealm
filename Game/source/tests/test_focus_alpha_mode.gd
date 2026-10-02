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

# ── Fuite du consommateur de copie CPU ───────────────────────────────
# La salve d'alpha enregistre un consommateur CPU (focus_mode.gd
# _start_alpha_probe -> cpu_capture_notify("focus", true)). Ce
# consommateur force cap_surface.cpp:953 (DMA_BUF_SYNC + memcpy) sur CHAQUE
# capture du focus : 14-30 ms observes en 1920x1080 sur le thread principal.
# Il doit donc être relâche, quoi qu'il arrive.
#
# Le piege : _update_occluder_for_alpha decrementait son compte a rebours
# APRES les gardes (remote_focus / focus_fullscreen_id / quads). Or
# focus_fullscreen_id n'est pose que si le CLIENT demande le plein ecran xdg
# (is_window_fullscreen_requested) : une fenetre simplement maximisee le
# laisse a -1. La garde tripait donc a chaque frame, le compte a rebours
# n'avancait pas, et la salve ne se terminait JAMAIS — la copie CPU
# restait demandee jusqu'a la sortie du focus.

const WindowsStub := preload("res://tests/fixtures/windows_stub.gd")

var _cpu_calls: Array = []

func _recorder(key: String, active: bool) -> void:
	_cpu_calls.append([key, active])

## Reproduit un focus sur une fenetre MAXIMISEE (pas de demande plein ecran
## xdg) et fait tourner _process comme en jeu. Doit rendre le consommateur.
func _run_maximized_focus(frames: int) -> bool:
	focus = Node3D.new()
	focus.set_script(FocusScript)
	get_tree().root.add_child(focus)
	var windows := WindowsStub.new()
	get_tree().root.add_child(windows)
	focus.windows = windows
	focus.cpu_capture_notify = Callable(self, "_recorder")
	windows.ensure_quad(7, "Konsole", "org.konsole", Vector2(1920, 1080))
	# Maximise, PAS fullscreen xdg : focus_fullscreen_id reste -1.
	focus.focus_mode = true
	focus.focus_fullscreen_id = -1
	focus.focus_rects[7] = TextureRect.new()
	_cpu_calls.clear()
	focus._start_alpha_probe()
	for _i in frames:
		focus._update_occluder_for_alpha(0.016)
	var released := false
	for c in _cpu_calls:
		if c[0] == "focus" and c[1] == false:
			released = true
	windows.queue_free()
	return released

func test_maximized_focus_releases_cpu_capture_consumer() -> Variant:
	# 6 frames a 60 Hz : au-dela du delai de 2 s du test suivant, et
	# suffisant pour prouver que la salve ne leak pas.
	if not _run_maximized_focus(6):
		_teardown()
		return "focus maximise : la salve d'alpha doit relâcher le consommateur CPU (il force une copie synchrone de 14-30 ms par capture)"
	_teardown()
	return true

func test_cpu_consumer_is_released_within_probe_timeout() -> Variant:
	# Meme a 4 Hz (le pire cas), la salve doit avoir rendu la main bien
	# avant ALPHA_PROBE_TIMEOUT (2 s) : c'est la borne qui garantit qu'aucun
	# focus ne peut immobiliser la copie CPU.
	if not _run_maximized_focus(8):
		_teardown()
		return "la copie CPU ne doit jamais rester demandee au-dela du delai de salve"
	_teardown()
	return true