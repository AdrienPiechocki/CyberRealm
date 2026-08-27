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
			_stick_nav_cooldown = 0.12
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
	var ui_vec = round(Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)))
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
	if current == null or items.find(current) < 0:
		items[0].grab_focus()
		return
	# Slider : left/right ajuste la valeur au lieu de naviguer.
	if current is HSlider and action in ["ui_left", "ui_right"]:
		var sl := current as HSlider
		var step: float = sl.step if sl.step > 0 else 1.0
		if action == "ui_right":
			sl.value = minf(sl.value + step, sl.max_value)
		else:
			sl.value = maxf(sl.value - step, sl.min_value)
		return
	var cp := current.global_position + current.size * 0.5

	if action in ["ui_up", "ui_down"]:
		# Navigation verticale : chercher le plus proche sur l'axe Y,
		# puis le plus proche horizontalement en cas d'égalité.
		var candidates: Array = []
		for item in items:
			if item == current:
				continue
			var iy = item.global_position.y + item.size.y * 0.5
			var dy = iy - cp.y
			if action == "ui_up" and dy < -2.0:
				candidates.append(item)
			elif action == "ui_down" and dy > 2.0:
				candidates.append(item)
		if candidates.is_empty():
			# Wrap-around : prendre l'élément le plus éloigné dans la direction.
			var best_item: Control = null
			var best_main := -1.0
			for item in items:
				if item == current:
					continue
				var iy = item.global_position.y + item.size.y * 0.5
				var dy = iy - cp.y
				var main := absf(dy)
				if main > best_main:
					best_main = main
					best_item = item
			if best_item:
				best_item.grab_focus()
		else:
			# Trier par distance Y, puis par distance X en cas d'égalité.
			candidates.sort_custom(func(a: Control, b: Control) -> bool:
				var ay := absf((a.global_position.y + a.size.y * 0.5) - cp.y)
				var by := absf((b.global_position.y + b.size.y * 0.5) - cp.y)
				if absf(ay - by) < 2.0:
					var ax := absf((a.global_position.x + a.size.x * 0.5) - cp.x)
					var bx := absf((b.global_position.x + b.size.x * 0.5) - cp.x)
					return ax < bx
				return ay < by
			)
			candidates[0].grab_focus()
	else:
		# Navigation horizontale : chercher d'abord sur la même ligne
		# (Y proche), sinon le plus proche sur l'axe X.
		var same_row: Array = []
		var any: Array = []
		for item in items:
			if item == current:
				continue
			var ix = item.global_position.x + item.size.x * 0.5
			var iy = item.global_position.y + item.size.y * 0.5
			var dx = ix - cp.x
			var dy = iy - cp.y
			if action == "ui_left" and dx < -2.0:
				any.append(item)
				if absf(dy) < current.size.y * 0.6:
					same_row.append(item)
			elif action == "ui_right" and dx > 2.0:
				any.append(item)
				if absf(dy) < current.size.y * 0.6:
					same_row.append(item)
		var candidates := same_row if not same_row.is_empty() else any
		if candidates.is_empty():
			# Wrap-around
			var best_item: Control = null
			var best_main := -1.0
			for item in items:
				if item == current:
					continue
				var ix = item.global_position.x + item.size.x * 0.5
				var dx = ix - cp.x
				var main := absf(dx)
				if main > best_main:
					best_main = main
					best_item = item
			if best_item:
				best_item.grab_focus()
		else:
			candidates.sort_custom(func(a: Control, b: Control) -> bool:
				var ax := absf((a.global_position.x + a.size.x * 0.5) - cp.x)
				var bx := absf((b.global_position.x + b.size.x * 0.5) - cp.x)
				if absf(ax - bx) < 2.0:
					var ay := absf((a.global_position.y + a.size.y * 0.5) - cp.y)
					var by := absf((b.global_position.y + b.size.y * 0.5) - cp.y)
					return ay < by
				return ax < bx
			)
			candidates[0].grab_focus()

func _get_focusable(action: String) -> Array:
	var items: Array = []
	_collect_focusable(self, items)
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
