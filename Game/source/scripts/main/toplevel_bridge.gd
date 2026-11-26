extends Node
## Pont entre le jeu et deux protocoles Wayland du compositeur :
##
## - zwlr_foreign_toplevel_management_v1 (barres de tâches lancées dans le jeu, ex. module wlr/taskbar de waybar) :
##   exécute les requêtes de la barre (activer, minimiser, plein écran, fermer) et lui renvoie l'état réel des
##   fenêtres (cachée = minimized, en mode focus = fullscreen).
## - zwp_keyboard_shortcuts_inhibit_v1 (VM, bureau à distance…) : désigne au compositeur la seule fenêtre qui peut
##   capturer les raccourcis — celle du mode focus, si l'option du menu pause l'autorise —, prévient le joueur, et
##   gère l'échappatoire (action release_shortcuts, Super+Shift+Échap par défaut).
##
## Créé par wayland_room.gd ; process() est appelé à chaque frame, avant tout retour anticipé de son _process.

var compositor: Object = null
var win3d: Node = null
var focus: Node = null
var fx: Node = null
var pause_menu: Node = null
## Callable() -> bool : le jeu peut-il ouvrir le mode focus maintenant (pas en vue libre, pas de menu…) ?
var can_enter_focus := Callable()

var _released_wid := -1          # fenêtre dont le joueur a repris les raccourcis (jusqu'au prochain focus)
var _fullscreen_ids: Dictionary = {}  # wid -> true : fenêtres annoncées « fullscreen » à la barre
var _toast: Label = null
var _toast_tween: Tween = null

func setup(p_compositor: Object, p_win3d: Node, p_focus: Node, p_fx: Node, p_pause_menu: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	fx = p_fx
	pause_menu = p_pause_menu
	compositor.toplevel_request.connect(_on_toplevel_request)
	compositor.shortcuts_inhibit_changed.connect(_on_shortcuts_inhibit_changed)
	win3d.window_hidden_changed.connect(func(id: int, hidden: bool): compositor.set_toplevel_minimized(id, hidden))
	focus.shortcuts_release_requested.connect(release_shortcuts)
	_build_toast()

func process() -> void:
	_sync_fullscreen_states()
	_sync_shortcuts_inhibit_window()

## Les raccourcis du jeu sont-ils capturés par une fenêtre (VM…) en ce moment ?
func shortcuts_inhibited() -> bool:
	return compositor != null and compositor.is_shortcuts_inhibited()

## Échappatoire : le joueur reprend ses raccourcis pour la fenêtre en focus (jusqu'à ce qu'il en sorte).
func release_shortcuts() -> void:
	if focus.is_active():
		_released_wid = focus.get_focus_window_id()
	compositor.set_shortcuts_inhibit_window(-1)
	_show_toast("Shortcuts released")

# ── Raccourcis : fenêtre autorisée ──────────────────────────────────────

static func inhibit_candidate(allowed: bool, focus_active: bool, remote: bool, focus_wid: int) -> int:
	return focus_wid if allowed and focus_active and not remote else -1

## Fenêtre autorisée à capturer les raccourcis, compte tenu d'une reprise manuelle (`released`).
## Renvoie [fenêtre autorisée, nouvelle valeur de released].
static func inhibit_window(candidate: int, released: int) -> Array:
	if candidate != released:
		released = -1        # le joueur a quitté / changé de fenêtre : la reprise ne vaut plus
	return [candidate if candidate != released else -1, released]

func _sync_shortcuts_inhibit_window() -> void:
	var allowed: bool = pause_menu.is_shortcut_inhibit_allowed()
	var cand := inhibit_candidate(allowed, focus.is_active(), focus.is_remote(), focus.get_focus_window_id())
	var r := inhibit_window(cand, _released_wid)
	_released_wid = int(r[1])
	compositor.set_shortcuts_inhibit_window(int(r[0]))

func _on_shortcuts_inhibit_changed(window_id: int, active: bool) -> void:
	if not active:
		return
	var key := _action_text("release_shortcuts")
	var title := String(win3d.window_titles.get(window_id, "This window"))
	_show_toast("%s captures your shortcuts — %s to take them back" % [title, key])

# ── Barre de tâches ─────────────────────────────────────────────────────

func _sync_fullscreen_states() -> void:
	var now: Dictionary = {}
	if focus.is_active() and not focus.is_remote():
		for id in focus.focus_stack:
			now[int(id)] = true
	for id in _fullscreen_ids:
		if not now.has(id):
			compositor.set_toplevel_fullscreen(id, false)
	for id in now:
		if not _fullscreen_ids.has(id):
			compositor.set_toplevel_fullscreen(id, true)
	_fullscreen_ids = now

func _is_hidden(id: int) -> bool:
	var q = win3d.quads.get(id)
	return q != null and is_instance_valid(q) and not q.visible

func _in_focus(id: int) -> bool:
	return focus.is_active() and not focus.is_remote() and focus.focus_stack.has(id)

func _on_toplevel_request(id: int, action: String, value: bool) -> void:
	if not win3d.quads.has(id):
		return
	match action:
		"activate":
			if _is_hidden(id):
				win3d.toggle_hide(id)
			# En mode focus le monde 3D est masqué : amener la fenêtre dans le focus.
			if focus.is_active() and not focus.is_remote():
				if not _in_focus(id) and _focus_allowed():
					focus.enter_focus(id)
			else:
				fx.flash_window(id)
			compositor.set_window_keyboard_focus(id)
		"minimize":
			if value and _in_focus(id):
				focus.exit_focus()
			if value != _is_hidden(id):
				win3d.toggle_hide(id)
		"fullscreen", "maximize":
			if value:
				if not _in_focus(id) and _focus_allowed():
					if _is_hidden(id):
						win3d.toggle_hide(id)
					focus.enter_focus(id)
			elif _in_focus(id):
				focus.exit_focus()
		"close":
			compositor.close_window(id)

func _focus_allowed() -> bool:
	return not can_enter_focus.is_valid() or bool(can_enter_focus.call())

# ── Bandeau d'information ───────────────────────────────────────────────

func _build_toast() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2200            # au-dessus des overlays du mode focus
	add_child(layer)
	_toast = Label.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.offset_top = 40.0
	_toast.add_theme_font_size_override("font_size", 20)
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.modulate.a = 0.0
	layer.add_child(_toast)

func _show_toast(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	if not is_inside_tree():
		return
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(4.0)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.6)

static func _action_text(action: String) -> String:
	if not InputMap.has_action(action):
		return action
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return (ev as InputEventKey).as_text().replace(" (Physical)", "").replace("Meta", "Super")
	return action
