extends Node
## Tests du cycle session lock (ext-session-lock-v1) côté layer_surfaces.gd.
## Régression input : quand le lockscreen se ferme PENDANT que le mode focus
## est actif, l'état "interaction layer" posé au verrouillage (libération de
## la souris pour le lockscreen) restait bloqué — recapture_if_needed() se
## désiste tant que le focus est actif — et player.layer_pointer_active
## restait vrai après sortie du focus → pad_cursor_active → ZQSD coupé
## jusqu'à l'ouverture d'un menu (qui appelle deactivate_layer_interact).
## Le fix d'unlock retire cet état sauf si une vraie layer interactive (kb)
## est encore mappée.

const LayerSurfacesScript := preload("res://scripts/windows/layer_surfaces.gd")

var layers: Node3D
var ui: CanvasLayer
var fake_player: Node3D
var focus: Node3D
var pause_menu: Control
var window_menu: Control

# Compile un script minimal en mémoire (fakes autonomes du test).
static func _make_script(code: String) -> Script:
	var s := GDScript.new()
	s.source_code = code
	if s.reload() != OK:
		return null
	return s

# Construit layer_surfaces + fakes. Le focus factice est ACTIVÉ (is_active()
# -> true) pour reproduire "lockscreen déclenché pendant le mode focus" :
# recapture_if_needed() ne doit alors pas ramener la souris.
func _build_world() -> Variant:
	ui = CanvasLayer.new()
	get_tree().root.add_child(ui)

	var player_script := _make_script("extends Node3D\nvar layer_pointer_active := false")
	if player_script == null:
		return "échec compilation fake player"
	fake_player = Node3D.new()
	fake_player.set_script(player_script)
	get_tree().root.add_child(fake_player)

	var focus_script := _make_script("extends Node3D\nfunc is_active() -> bool:\n\treturn true")
	if focus_script == null:
		return "échec compilation fake focus"
	focus = Node3D.new()
	focus.set_script(focus_script)

	pause_menu = Control.new()
	pause_menu.visible = false
	get_tree().root.add_child(pause_menu)
	window_menu = Control.new()
	window_menu.visible = false
	get_tree().root.add_child(window_menu)

	layers = Node3D.new()
	layers.set_script(LayerSurfacesScript)
	get_tree().root.add_child(layers)
	layers.setup(null, fake_player, ui, focus, pause_menu, window_menu, null)
	return true

func _teardown() -> void:
	for n in [layers, fake_player, ui, pause_menu, window_menu]:
		if n != null and is_instance_valid(n):
			n.free()

func test_lock_unlock_while_focus_clears_layer_pointer() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	layers.on_session_lock_locked()
	if not layers.session_locked:
		return "session_locked devrait être vrai après on_session_lock_locked"
	if not layers.layer_interact_active:
		return "layer_interact_active devrait être vrai pendant le lock"
	if not fake_player.layer_pointer_active:
		return "layer_pointer_active devrait être vrai pendant le lock"
	# Le focus est actif : avant le fix, recapture_if_needed() se désistait et
	# l'état restait bloqué après unlock → ZQSD coupé.
	layers.on_session_lock_unlocked()
	if layers.session_locked:
		return "session_locked devrait être faux après on_session_lock_unlocked"
	if layers.layer_interact_active:
		return "layer_interact_active devrait être réinitialisé après unlock"
	if fake_player.layer_pointer_active:
		return "layer_pointer_active devrait être réinitialisé après unlock (focus actif)"
	_teardown()
	return true

func test_lock_unlock_keeps_real_interactive_layer_state() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	# Une vraie layer interactive (rofi, waybar menu, kb=1) est ouverte : son
	# état souris doit être préservé au déverrouillage.
	layers.on_layer_surface_mapped(3, "test-app", LayerSurfacesScript.LAYER_OVERLAY,
		1, 0, 0, 100, 100, 1)
	layers.on_session_lock_locked()
	layers.on_session_lock_unlocked()
	if not fake_player.layer_pointer_active:
		return "layer_pointer_active doit rester vrai : layer interactive présente"
	if layers.session_locked:
		return "session_locked devrait être faux après on_session_lock_unlocked"
	_teardown()
	return true