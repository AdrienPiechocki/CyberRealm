extends PanelContainer
class_name GameMenu
## Classe de base pour tous les menus du jeu.
##
## Fournit automatiquement :
## - Consommation des events JoypadMotion + d-pad (on gère tout en _process).
## - Navigation UI par stick gauche OU d-pad avec répétition à cooldown.
## - Scroll dans les ScrollContainer visibles par stick droit Y.
## - Wrap-around : Up sur la première entrée → dernière, et inversement.
## - Navigation directe par grab_focus() (pas d'events synthétiques).

const DPAD_BUTTONS := [
	JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN,
	JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT,
]

var _stick_nav_cooldown := 0.0
var _stick_scroll_cooldown := 0.0

## Override dans les sous-classes pour bloquer le nav/scroll stick
## (ex: pendant une capture de touche dans le menu pause).
func _can_stick_input() -> bool:
	return true

func _process(delta: float) -> void:
	if not visible or not _can_stick_input():
		return
	# ── Scroll (stick droit Y) ──────────────────────────────────────
	if Input.is_action_pressed("scroll_up") or Input.is_action_pressed("scroll_down"):
		_stick_scroll_cooldown -= delta
		if _stick_scroll_cooldown <= 0.0:
			var amount := -40 if Input.is_action_pressed("scroll_up") else 40
			_scroll_visible_container(amount)
			_stick_scroll_cooldown = 0.08
	else:
		_stick_scroll_cooldown = 0.0
	# ── Navigation UI (stick + d-pad) ──────────────────────────────
	var action := _poll_nav_action()
	if action != "":
		_stick_nav_cooldown -= delta
		if _stick_nav_cooldown <= 0.0:
			_move_focus(action)
			_stick_nav_cooldown = 0.25
	else:
		_stick_nav_cooldown = 0.0

func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Consommer stick + d-pad pour gérer la nav dans _process (cooldown
	# uniforme, wrap-around, pas de double processing).
	if event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index in DPAD_BUTTONS:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ── Navigation ──────────────────────────────────────────────────────────────

func _poll_nav_action() -> String:
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP):
		return "ui_up"
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN):
		return "ui_down"
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT):
		return "ui_left"
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT):
		return "ui_right"
	var ui_vec := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if ui_vec == Vector2.ZERO:
		return ""
	if absf(ui_vec.x) > absf(ui_vec.y):
		return "ui_right" if ui_vec.x > 0 else "ui_left"
	return "ui_down" if ui_vec.y > 0 else "ui_up"

func _move_focus(action: String) -> void:
	var items := _get_focusable(action)
	if items.is_empty():
		return
	var current := get_viewport().gui_get_focus_owner()
	var idx := items.find(current)
	if idx < 0:
		# Pas de focus ou focus hors liste → premier élément.
		items[0].grab_focus()
		return
	var target: int
	match action:
		"ui_up":
			target = items.size() - 1 if idx == 0 else idx - 1
		"ui_down":
			target = 0 if idx >= items.size() - 1 else idx + 1
		"ui_left":
			target = items.size() - 1 if idx == 0 else idx - 1
		"ui_right":
			target = 0 if idx >= items.size() - 1 else idx + 1
		_:
			return
	items[target].grab_focus()

func _get_focusable(action: String) -> Array:
	var items: Array = []
	_collect_focusable(self, items)
	# Trier par axe principal : Y pour up/down, X pour left/right.
	if action in ["ui_up", "ui_down"]:
		items.sort_custom(func(a: Control, b: Control) -> bool:
			if absf(a.global_position.y - b.global_position.y) < 4.0:
				return a.global_position.x < b.global_position.x
			return a.global_position.y < b.global_position.y
		)
	else:
		items.sort_custom(func(a: Control, b: Control) -> bool:
			if absf(a.global_position.x - b.global_position.x) < 4.0:
				return a.global_position.y < b.global_position.y
			return a.global_position.x < b.global_position.x
		)
	return items

func _collect_focusable(node: Node, result: Array) -> void:
	for child in node.get_children():
		# Inclure uniquement les contrôles interactifs (pas les containers)
		# qui sont visibles et acceptent le focus.
		if child is Control and child.visible \
				and child.focus_mode != Control.FOCUS_NONE \
				and not child is Container:
			result.append(child)
		if child.get_child_count() > 0:
			_collect_focusable(child, result)

# ── Scroll ──────────────────────────────────────────────────────────────────

func _scroll_visible_container(amount: int) -> void:
	for child in _find_scroll_containers(self):
		if child.visible:
			child.scroll_vertical += amount
			break

func _find_scroll_containers(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if child is ScrollContainer:
			result.append(child)
		elif child.get_child_count() > 0:
			result.append_array(_find_scroll_containers(child))
	return result
