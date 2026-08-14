extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".
##
## Orchestrateur : chaque sous-système vit dans un node enfant dédié —
##   Windows3D      -> quads 3D des fenêtres/popups, déplacement, resize
##   FocusMode      -> mode focus plein écran 2D
##   LayerSurfaces  -> overlays waybar/rofi + session lock
##   PinnedWindows  -> PiP des fenêtres épinglées
##   Effects        -> X-RAY + flash d'ouverture

@onready var compositor: WlrCompositor = $WlrCompositor
@onready var player = $Level/Player
@onready var ui: CanvasLayer = $Level/Player/UI
@onready var window_menu = $Level/Player/WindowMenuLayer/WindowMenu
@onready var capture_selector = $Level/Player/CaptureSelectorLayer/CaptureSelector
@onready var pause_menu = $Level/Player/PauseMenuLayer/PauseMenu

var win3d: Node3D
var focus: Node3D
var layers: Node3D
var pins: Node3D
var fx: Node3D
var presenter: Node3D # présente le viewport à l'output headless pour OBS

var _selector_waiting := false # choix envoyé à portal-wlr, en attente de consommation
var interact_mode_active := false

# Agent d'authentification polkit : polkitd n'accepte qu'un seul agent par
# session logind, donc le nôtre ne peut s'enregistrer que si l'agent KDE hôte
# (plasma-polkit-agent) est arrêté. On le coupe au lancement du jeu et on le
# relance à la sortie. L'adresse du bus D-Bus du host est capturée AVANT que
# launch_portals() remplace DBUS_SESSION_BUS_ADDRESS par le bus privé du jeu.
var _host_session_bus := ""
var _host_agent_stopped := false

# Niveaux : on charge d'abord le level custom de l'utilisateur s'il existe
# (res://user/level.tscn), sinon on retombe sur le level par défaut.
const DEFAULT_LEVEL_PATH := "res://scenes/level.tscn"
const CUSTOM_LEVEL_PATH := "res://user/level.tscn"

const POLKIT_AGENT_CANDIDATES := [
	"/usr/lib/polkit-kde-authentication-agent-1",
	"/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
]

# Drag-and-drop icon overlay
var drag_icon_rect: TextureRect
var drag_icon_size := Vector2.ZERO

# Dedup gestes pinch : le driver Wayland de Godot génère chaque update en
# double (deux InputEventMagnifyGesture identiques par événement wire — l'écart
# de 2^24 sur get_instance_id() entre les deux le confirme). Le second forward
# multiplierait pinch_scale deux fois dans le compositeur (zoom 2× trop vite),
# on ne garde donc que le premier de la paire (même facteur dans une courte
# fenêtre temporelle).
var _last_pinch_factor := 1.0
var _last_pinch_time_msec := -1
const PINCH_DEDUP_WINDOW_MS := 100

func _load_level() -> void:
	# Chargement du niveau custom (res://user/level.tscn) si présent, sinon le
	# niveau par défaut. Les assets du niveau custom doivent avoir été importés
	# par l'éditeur Godot (dossier res://user/) pour être chargés au runtime.
	var level_path := DEFAULT_LEVEL_PATH
	if ResourceLoader.exists(CUSTOM_LEVEL_PATH):
		level_path = CUSTOM_LEVEL_PATH
	var scene: PackedScene = load(level_path)
	if scene == null:
		push_error("Impossible de charger le niveau '%s'" % level_path)
		return
	var level := scene.instantiate()
	level.name = "Level"
	add_child(level)

func _add_manager(script: Script, node_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	node.set_script(script)
	add_child(node)
	return node

func _init() -> void:
	# Le niveau (level custom de l'utilisateur, sinon level par défaut) est
	# instancié en premier, avant les sous-systèmes.
	_load_level()

func _ready() -> void:
	# Capturé avant launch_portals() qui remplace DBUS_SESSION_BUS_ADDRESS par
	# le bus privé du jeu (sinon systemctl --user viserait le mauvais bus).
	_host_session_bus = OS.get_environment("DBUS_SESSION_BUS_ADDRESS")

	# Sous-systèmes, créés avant toute connexion de signal.
	win3d = _add_manager(preload("res://scripts/windows_3d.gd"), "Windows3D")
	focus = _add_manager(preload("res://scripts/focus_mode.gd"), "FocusMode")
	layers = _add_manager(preload("res://scripts/layer_surfaces.gd"), "LayerSurfaces")
	pins = _add_manager(preload("res://scripts/pinned_windows.gd"), "PinnedWindows")
	fx = _add_manager(preload("res://scripts/effects.gd"), "Effects")
	presenter = _add_manager(preload("res://scripts/present_manager.gd"), "PresentManager")

	win3d.setup(compositor, player)
	focus.setup(compositor, player, ui, win3d)
	layers.setup(compositor, player, ui, focus, pause_menu, window_menu)
	pins.setup(ui)
	fx.setup(win3d)
	presenter.setup(compositor)

	compositor.window_mapped.connect(_on_window_mapped)
	compositor.window_unmapped.connect(focus.on_window_unmapped)
	compositor.window_unmapped.connect(pins.on_window_unmapped)
	compositor.window_unmapped.connect(fx.on_window_unmapped)
	compositor.window_unmapped.connect(win3d.on_window_unmapped)
	compositor.window_decorations_changed.connect(win3d.on_window_decorations_changed)
	compositor.window_title_changed.connect(win3d.on_window_title_changed)
	compositor.window_texture_updated.connect(_on_window_texture_updated)
	compositor.popup_mapped.connect(_on_popup_mapped)
	compositor.popup_unmapped.connect(_on_popup_unmapped)
	compositor.popup_texture_updated.connect(_on_popup_texture_updated)
	compositor.pointer_lock_changed.connect(focus.on_pointer_lock_changed)
	compositor.drag_icon_updated.connect(_on_drag_icon_updated)
	compositor.drag_icon_removed.connect(_on_drag_icon_removed)
	compositor.layer_surface_mapped.connect(layers.on_layer_surface_mapped)
	compositor.layer_surface_unmapped.connect(layers.on_layer_surface_unmapped)
	compositor.layer_surface_texture_updated.connect(layers.on_layer_surface_texture_updated)
	compositor.layer_surface_layout_changed.connect(layers.on_layer_surface_layout_changed)
	compositor.layer_popup_mapped.connect(layers.on_layer_popup_mapped)
	compositor.session_lock_locked.connect(layers.on_session_lock_locked)
	compositor.session_lock_unlocked.connect(layers.on_session_lock_unlocked)
	compositor.session_lock_surface_texture_updated.connect(layers.on_session_lock_surface_texture_updated)
	win3d.window_created.connect(fx.on_window_created)

	compositor.start_headless()
	# Portails de capture pour OBS : xdg-desktop-portal (backend wlr) +
	# xdg-desktop-portal-wlr, dans la session du jeu (socket cyberrealm-0).
	# IMPORTANT : sans set_portal_backend, XDG_CURRENT_DESKTOP hérite de
	# "KDE" (le jeu est lancé depuis Plasma) → le xdg-desktop-portal privé
	# route ScreenCast vers le backend kde (xdg-desktop-portal-kde), qui
	# exige KWin sur le compositeur → échec "denied or cancelled by user".
	# "dwl:wlr" fait matcher wlr-portals.conf → backend wlr (vérifié).
	compositor.set_portal_backend("dwl:wlr")
	compositor.launch_portals()
	# Les layer surfaces sont ancrées à l'écran : le compositeur doit
	# connaître la taille du viewport pour le layout (arrange_layer_surfaces).
	compositor.set_output_size(int(get_viewport().get_visible_rect().size.x),
		int(get_viewport().get_visible_rect().size.y))
	# Layout clavier sauvegardé (menu pause) appliqué avant le lancement des apps.
	var kl: Dictionary = pause_menu.get_keyboard_layout()
	compositor.set_keyboard_layout(kl.get("layout", "fr"), kl.get("variant", ""))
	# Agent d'authentification polkit (menu pause) : stopper l'agent KDE hôte
	# puis lancer le nôtre dans la session du jeu (bus D-Bus privé) pour que
	# les demandes d'autorisation (pkexec...) affichent leur dialogue sur le
	# compositeur du jeu.
	var polkit_agent := _find_polkit_agent()
	if polkit_agent != "":
		_stop_host_polkit_agent()
	compositor.set_polkit_agent(polkit_agent)
	compositor.launch_app("xwayland-satellite :1")
	await get_tree().create_timer(0.2).timeout
	compositor.set_x11_display(":1")
	# Apps à lancer automatiquement au démarrage (configurées depuis le menu pause)
	for cmd in pause_menu.get_startup_apps():
		compositor.launch_app(cmd)
	# Setup du menu de navigation entre fenêtres
	window_menu.setup(compositor, _get_window_texture)
	window_menu.action_grab.connect(_on_window_menu_grab)
	window_menu.action_focus.connect(_on_window_menu_focus)
	window_menu.action_toggle_hide.connect(_on_window_menu_toggle_hide)
	window_menu.action_find.connect(_on_window_menu_find)
	window_menu.action_pin.connect(_on_window_menu_pin)
	window_menu.action_quit.connect(_on_window_menu_quit)
	window_menu.menu_closed.connect(_on_window_menu_closed)
	# Sélecteur de cible de capture OBS : ouvert quand portal-wlr signale une
	# nouvelle source « Screen Capture (PipeWire) » (cyberrealm-capture-pending).
	capture_selector.setup(compositor)
	capture_selector.target_chosen.connect(_on_capture_selector_chosen)
	capture_selector.selector_cancelled.connect(_on_capture_selector_cancelled)

	pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)
	pause_menu.app_launch_requested.connect(compositor.launch_app)
	pause_menu.quit_requested.connect(_on_quit_requested)
	pause_menu.keyboard_layout_changed.connect(compositor.set_keyboard_layout)
	pause_menu.polkit_agent_changed.connect(_on_polkit_agent_changed)
	pause_menu.pins_layer_changed.connect(_on_pins_layer_changed)
	pause_menu.pins_opacity_changed.connect(_on_pins_opacity_changed)
	# Appliquer la couche et la transparence des fenêtres épinglées sauvegardées
	pins.set_pins_above_focus(pause_menu.get_pins_above_focus())
	pins.set_pins_opacity(pause_menu.get_pins_opacity())

	# TextureRect pour l'icône de drag-and-drop
	drag_icon_rect = TextureRect.new()
	drag_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	drag_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_icon_rect.visible = false
	drag_icon_rect.z_index = 100
	ui.add_child(drag_icon_rect)

# ── Dispatch des signaux compositeur vers les sous-systèmes ─────────

func _on_window_mapped(id: int, title: String, app_id: String) -> void:
	win3d.on_window_mapped(id, title, app_id)
	# Une nouvelle fenêtre ouverte pendant le mode focus s'ouvre aussi en
	# focus, par-dessus la/les fenêtre(s) précédente(s).
	if focus.is_active():
		focus.enter_focus(id)

func _on_window_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	win3d.on_texture_updated(id, texture, width, height)
	pins.on_window_texture_updated(id, texture)
	focus.on_window_texture_updated(id, texture, width, height)
	# Rafraîchir la preview du menu si ouvert
	if window_menu.visible:
		window_menu.refresh_preview()

func _on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	win3d.on_popup_mapped(id, parent_window_id, parent_popup_id, x, y, width, height)
	focus.on_popup_mapped(id, parent_window_id, parent_popup_id, x, y, width, height)

func _on_popup_unmapped(id: int) -> void:
	# Popup d'une layer surface: overlay 2D, pas de quad 3D.
	if layers.on_popup_unmapped(id):
		return
	win3d.on_popup_unmapped(id)
	focus.on_popup_unmapped(id)

func _on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	# Popup d'une layer surface: on met simplement à jour l'overlay 2D.
	if layers.on_popup_texture_updated(id, texture, width, height):
		return
	win3d.on_popup_texture_updated(id, texture, width, height)
	focus.on_popup_texture_updated(id, texture, width, height)

# ── Binds custom et helpers d'entrée ─────────────────────────────────

# Vrai quand un overlay keyboard-interactive (rofi, waybar...) détient le
# focus clavier : les touches sont routées vers lui, aucun bind du jeu ne
# doit se déclencher.
func _keyboard_busy() -> bool:
	return layers.keyboard_busy()

# Détecte si l'événement correspond à un custom bind et lance sa commande.
# Renvoie true si l'événement a été consommé.
func _try_custom_bind(event: InputEvent) -> bool:
	if _keyboard_busy() or interact_mode_active:
		return false
	var binds: Array = pause_menu.get_custom_binds()
	for bind in binds:
		if not bind is Dictionary:
			continue
		var command: String = bind.get("command", "")
		if command == "":
			continue
		var matched := false
		if bind.get("type", "") == "mouse":
			if event is InputEventMouseButton and event.pressed:
				matched = event.button_index == int(bind.get("code", -1)) \
					and _event_matches_mods(event, bind.get("mods", {}))
		else:
			if event is InputEventKey and event.pressed and not event.echo:
				var kev := event as InputEventKey
				var code := kev.physical_keycode
				if code == 0:
					code = kev.keycode
				matched = code == int(bind.get("code", 0)) \
					and _event_matches_mods(kev, bind.get("mods", {}))
		if matched:
			compositor.launch_app(command)
			return true
	return false

# Vrai si les modificateurs de l'événement correspondent exactement à ceux du bind.
func _event_matches_mods(event: InputEvent, mods: Dictionary) -> bool:
	var ev := event as InputEventWithModifiers
	if ev == null:
		return mods.is_empty()
	return ev.ctrl_pressed == mods.get("ctrl", false) \
		and ev.shift_pressed == mods.get("shift", false) \
		and ev.alt_pressed == mods.get("alt", false) \
		and ev.meta_pressed == mods.get("super", false)

# En MOUSE_MODE_CAPTURED (souris FPS), get_mouse_position() reste figée à
# l'endroit où le curseur était au moment de la capture — pas au centre de
# l'écran. Le viseur est au centre du viewport : c'est donc ce centre qui
# doit guider le rayon, sinon les clics sont décalés d'autant.
func _aim_pos() -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return get_viewport().get_visible_rect().size / 2.0
	return get_viewport().get_mouse_position()

# Cast un rayon depuis la souris et renvoie l'id de la fenêtre touchée (-1 sinon).
func _raycast_window_id(mouse_pos: Vector2) -> int:
	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	var ray_origin = cam.project_ray_origin(mouse_pos)
	var ray_dir = cam.project_ray_normal(mouse_pos)
	var to = ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		var body: Node3D = hit.collider
		if body.has_meta("window_id"):
			return body.get_meta("window_id")
	return -1

# Pin/unpin d'une fenêtre en PiP (touche P ou menu fenêtres).
func _toggle_pin(wid: int) -> void:
	if pins.is_pinned(wid):
		pins.unpin(wid)
	else:
		if not win3d.quads.has(wid):
			return
		pins.pin(wid, win3d.get_window_texture(wid))

# ── Boucle principale ────────────────────────────────────────────────

func _process(delta: float) -> void:
	fx.process(delta)

	# La présentation du viewport vers l'output headless (capture OBS) et la
	# synchro du curseur sont gérées par PresentManager :
	# elles doivent continuer de tourner pendant que le menu pause gèle
	# l'arbre, sinon la capture se figerait sur la dernière frame.

	# Suivi de l'icône de drag-and-drop
	if drag_icon_rect and drag_icon_rect.visible:
		var mouse_pos := get_viewport().get_mouse_position()
		drag_icon_rect.position = mouse_pos - drag_icon_size / 2.0

	# Session verrouillée : tout le pointeur part vers la surface de
	# verrouillage (le curseur y est visible), rien ne va au jeu.
	if layers.is_locked():
		layers.handle_locked_input()
		return

	# Sélecteur de cible de capture OBS : quand portal-wlr écrit
	# cyberrealm-capture-pending (une source PipeWire ajoutée dans OBS), on
	# ouvre le sélecteur pour choisir l'écran ou une fenêtre.
	_poll_capture_pending()

	if capture_selector.visible:
		return

	if Input.is_action_just_pressed("window_menu", true) and not interact_mode_active and not focus.is_active() and not layers.keyboard_busy():
		window_menu.toggle_menu()

	# Tab : bascule le mode "interaction layer" — libère la souris pour
	# survoler/cliquer waybar, quickshell ou les overlays non interactifs
	# (sinon elle est capturée et fait tourner la caméra FPS).
	if Input.is_action_just_pressed("layer_interact", true) and not interact_mode_active and not focus.is_active() and not layers.keyboard_busy():
		layers.toggle_layer_interact()

	if window_menu.visible or capture_selector.visible:
		return

	# Mode focus: le raccourci focus (ex. Super+F) pour sortir, kill_window
	# pour fermer la fenêtre, sinon router les inputs souris/clavier.
	# is_action_just_pressed(exact=true) : seul le bind exact (modifieurs
	# compris) déclenche la sortie — F seul, Ctrl+F... vont à la fenêtre.
	if focus.is_active():
		if Input.is_action_just_pressed("focus_window", true):
			focus.exit_focus()
			return
		if Input.is_action_just_pressed("kill_window", true):
			compositor.close_window(focus.get_focus_window_id())
			return
		focus.handle_focus_input()
		return

	# Layer surfaces (waybar/rofi): quand la souris est visible et survole
	# une layer surface ou son popup, on forward l'input vers elle et on
	# laisse le raycast 3D de côté (les overlays 2D passent devant la scène).
	if not pause_menu.visible and layers.handle_layer_pointer(get_viewport().get_mouse_position()):
		return

	# Clavier occupé par un overlay keyboard-interactive (rofi, waybar...):
	# les touches partent vers l'overlay, les binds du jeu (focus, pin,
	# interact_mode, grab...) ne doivent pas se déclencher.
	if layers.keyboard_busy():
		return

	# F en visant une fenêtre → entrer en mode focus
	if Input.is_action_just_pressed("focus_window", true) and not interact_mode_active:
		var wid := _raycast_window_id(get_viewport().get_mouse_position())
		if wid != -1:
			focus.enter_focus(wid)
			return

	# P en visant une fenêtre → pin/unpin PiP
	if Input.is_action_just_pressed("pin_window", true) and not interact_mode_active:
		var wid := _raycast_window_id(get_viewport().get_mouse_position())
		if wid != -1:
			_toggle_pin(wid)
			return

	# K en visant une fenêtre → demander sa fermeture (close)
	if Input.is_action_just_pressed("kill_window", true) and not interact_mode_active:
		var wid := _raycast_window_id(_aim_pos())
		if wid != -1:
			compositor.close_window(wid)
			return

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	# (le clic molette sert au client en mode focus, pas au toggle du mode interaction).
	if Input.is_action_just_pressed("interact_mode", true) and not focus.is_active():
		if interact_mode_active:
			compositor.release_all_keys()
		interact_mode_active = not interact_mode_active
		player.interact_mode_active = not player.interact_mode_active

	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	var mouse_pos := _aim_pos()
	var ray_origin := cam.project_ray_origin(mouse_pos)
	var ray_dir := cam.project_ray_normal(mouse_pos)
	win3d.process_raycast(ray_origin, ray_dir, delta, interact_mode_active)

func _input(event: InputEvent) -> void:
	# Tout input (même celui du joueur qui ne vise aucune surface : WASD,
	# caméra) réarme le timer d'inactivité du compositeur — sans ça, les
	# clients abonnés à ext-idle-notify-v1 verraient la session passer idle
	# pendant que le joueur se balade dans la pièce.
	# Les events de souris "warped" (Input.warp_mouse / changement de mode de
	# capture) sont synthétiques : générés par notre propre gestion de souris
	# (ex. l'overlay fade-to-lock). Ils ne représentent pas une activité
	# utilisateur réelle et annuleraient le lock d'inactivité.
	if not OS.has_feature("editor") and not (event is InputEventMouseMotion and event.warped):
		compositor.notify_activity()
	if event is InputEventKey and OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("key _input: code=", event.physical_keycode, " unicode=", event.unicode,
			" shift=", event.shift_pressed, " pressed=", event.pressed)

	if pause_menu.visible:
		return

	# Session verrouillée : tout le clavier part vers le lockscreen (le
	# champ password de quickshell), aucun bind du jeu ne doit répondre.
	if layers.is_locked() and event is InputEventKey:
		layers.forward_keyboard_event(event)
		return

	# Une layer surface keyboard-interactive (rofi, waybar menu) détient le
	# focus clavier : forward vers elle, quel que soit le mode de la souris.
	if event is InputEventKey and layers.keyboard_busy() and not capture_selector.visible:
		layers.forward_keyboard_event(event)
		return

	# Gestes touchpad (pinch → zoom). Godot forwarde InputEventMagnifyGesture
	# (factor incrémental) ; le compositeur maintient l'état du geste et route
	# via le focus pointeur du seat (fenêtre survolée en 3D, fenêtre active en
	# mode focus). Sans focus, wlroots ignore le geste.
	if event is InputEventMagnifyGesture and not window_menu.visible and not capture_selector.visible:
		var mg := event as InputEventMagnifyGesture
		var now := Time.get_ticks_msec()
		# Ignorer le second événement de la paire (doublon du driver Wayland).
		if mg.factor == _last_pinch_factor and _last_pinch_time_msec != -1 \
				and now - _last_pinch_time_msec < PINCH_DEDUP_WINDOW_MS:
			get_viewport().set_input_as_handled()
			return
		_last_pinch_factor = mg.factor
		_last_pinch_time_msec = now
		print("[gesture] magnify recu factor=", mg.factor, " hovered=", win3d.is_in_window, " focus=", focus.is_active())
		compositor.forward_pointer_pinch(mg.factor, 0.0, 0.0)
		get_viewport().set_input_as_handled()
		return

	# En mode focus, forward le clavier et tracker la souris capturée
	if focus.is_active() and focus.get_focus_window_id() != -1 and not capture_selector.visible:
		if focus.handle_input_event(event):
			return

	# Custom binds: une touche enregistrée lance une commande/app.
	if not interact_mode_active and not layers.keyboard_busy() and not window_menu.visible and not capture_selector.visible:
		if _try_custom_bind(event):
			get_viewport().set_input_as_handled()
			return

	if win3d.focused_window_id == -1 or not interact_mode_active:
		return

	if event is InputEventKey:
		var key_event := event as InputEventKey
		# Ignorer les échos de répétition clavier Godot : chaque DOWN/UP doit
		# arriver apparié à xkbcommon, sinon un modificateur peut rester
		# "coincé" (état xkb désynchronisé tant qu'on ne recharge pas le keymap).
		if key_event.echo:
			return
		var code = key_event.physical_keycode
		if code == 0:
			code = key_event.keycode
		# Touches mortes AZERTY : Godot compose l'accent et avale la touche
		# morte + le relâchement de la lettre — reconstruire la séquence pour
		# le client (voir focus_mode._try_reconstruct_composed_key).
		if focus._try_reconstruct_composed_key(key_event):
			get_viewport().set_input_as_handled()
			return
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key interact: code=", code, " unicode=", key_event.unicode,
				" shift=", key_event.shift_pressed, " pressed=", key_event.pressed,
				" client_shift=", focus._client_shift)
		# Heal : rétablit l'état Shift du client si son relâchement a été avalé
		# par l'IM lors d'une touche morte.
		focus._prepare_key_forward(key_event, code)

		# Chevrons AZERTY : la touche ISO (physique KEY_QUOTELEFT/96) donne '<'
		# non-shifté et '>' shifté — même touche evdev 86, le Shift est forwardé
		# à part. Remap par code physique (pas par unicode, nul au relâchement)
		# pour que l'UP parte avec le MÊME evdev que le DOWN : sinon la touche
		# reste enfoncée côté client (auto-repeat en boucle) et les appuis
		# suivants sont bloqués par le garde-fou pressed_keys.
		if key_event.unicode == 60 or key_event.unicode == 62 or code == KEY_QUOTELEFT:
			code = KEY_LESS

		compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
		get_viewport().set_input_as_handled()

# ── Drag-and-drop ────────────────────────────────────────────────────

func _on_drag_icon_updated(texture: Texture2D, width: int, height: int) -> void:
	drag_icon_rect.texture = texture
	drag_icon_size = Vector2(width, height)
	drag_icon_rect.visible = true
	drag_icon_rect.pivot_offset = drag_icon_size / 2.0

func _on_drag_icon_removed() -> void:
	drag_icon_rect.visible = false
	drag_icon_rect.texture = null

# ── Window menu helpers ──────────────────────────────────────────────

func _get_window_texture(wid: int) -> Texture2D:
	return win3d.get_window_texture(wid)

func _on_window_menu_grab(wid: int) -> void:
	# Fermer le menu, sélectionner la fenêtre et initier le grab
	window_menu.hide_menu()
	win3d.grab_window_from_menu(wid)

func _on_window_menu_focus(wid: int) -> void:
	window_menu.hide_menu()
	focus.enter_focus(wid)

func _on_window_menu_toggle_hide(wid: int) -> void:
	win3d.toggle_hide(wid)
	if window_menu.visible:
		window_menu.refresh_preview()

func _on_window_menu_find(wid: int) -> void:
	window_menu.hide_menu()
	fx.toggle_find(wid)

func _on_window_menu_pin(wid: int) -> void:
	_toggle_pin(wid)
	window_menu.hide_menu()

func _on_window_menu_quit(wid: int) -> void:
	compositor.close_window(wid)

func _on_window_menu_closed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ── Sélecteur de capture OBS ─────────────────────────────────────────

func _poll_capture_pending() -> void:
	var rt := OS.get_environment("XDG_RUNTIME_DIR")
	if rt.is_empty():
		return
	var pending := rt + "/cyberrealm-capture-pending"
	if _selector_waiting:
		# Un choix a été envoyé à portal-wlr : ne pas rouvrir le sélecteur
		# tant qu'il n'a pas consommé le fichier pending.
		if not FileAccess.file_exists(pending):
			_selector_waiting = false
		return
	if FileAccess.file_exists(pending) and not capture_selector.visible:
		capture_selector.open_selector()

func _on_capture_selector_chosen(choice: String) -> void:
	_write_capture_choice(choice)
	_selector_waiting = true
	capture_selector.close_selector()

func _on_capture_selector_cancelled() -> void:
	_write_capture_choice("cancel")
	_selector_waiting = true
	capture_selector.close_selector()

# Écrit le choix du joueur pour xdg-desktop-portal-wlr : "screen", un app_id
# ou un titre de fenêtre, ou "cancel" pour annuler (portal-wlr retombe alors
# sur la première fenêtre, sinon l'écran).
func _write_capture_choice(choice: String) -> void:
	var rt := OS.get_environment("XDG_RUNTIME_DIR")
	if rt.is_empty():
		return
	var f := FileAccess.open(rt + "/cyberrealm-capture-choice", FileAccess.WRITE)
	if f:
		f.store_string(choice + "\n")
		f.close()

# ── Agent polkit ────────────────────────────────────────────────────

# Retourne le chemin de l'agent à lancer dans le jeu : réglage sauvegardé
# (menu pause) s'il existe, sinon détection automatique, sinon "" (agent
# système = dialogue sur le host).
func _find_polkit_agent() -> String:
	var configured: String = pause_menu.get_polkit_agent().strip_edges()
	if configured != "" and FileAccess.file_exists(configured):
		return configured
	for candidate in POLKIT_AGENT_CANDIDATES:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""

# systemctl --user ciblant le bus D-Bus du host (le jeu a remplacé
# DBUS_SESSION_BUS_ADDRESS par son bus privé après launch_portals()).
func _host_systemctl(args: PackedStringArray) -> int:
	if _host_session_bus.is_empty():
		var full_args := PackedStringArray(["--user"])
		full_args.append_array(args)
		return OS.execute("systemctl", full_args, [], true)
	var cmd := "DBUS_SESSION_BUS_ADDRESS='%s' systemctl --user %s" \
		% [_host_session_bus, " ".join(args)]
	return OS.execute("sh", ["-c", cmd], [], true)

func _stop_host_polkit_agent() -> void:
	if _host_agent_stopped:
		return
	# systemctl --user stop est synchrone : à son retour l'agent KDE a quitté
	# et polkitd a libéré l'enregistrement d'agent de la session logind.
	if _host_systemctl(PackedStringArray(["stop", "plasma-polkit-agent.service"])) != 0:
		# Fallback si le service n'existe pas (autre distribution).
		OS.execute("pkill", ["-f", "polkit-kde-authentication-agent-1"], [], true)
	_host_agent_stopped = true

func _restore_host_polkit_agent() -> void:
	if not _host_agent_stopped:
		return
	_host_systemctl(PackedStringArray(["start", "plasma-polkit-agent.service"]))
	_host_agent_stopped = false

func _on_polkit_agent_changed(path: String) -> void:
	if path.strip_edges() != "":
		_stop_host_polkit_agent()
	compositor.set_polkit_agent(path)

func _on_pins_layer_changed(above: bool) -> void:
	pins.set_pins_above_focus(above)

func _on_pins_opacity_changed(percent: int) -> void:
	pins.set_pins_opacity(percent)

# ── Cycle de vie ─────────────────────────────────────────────────────

func _on_quit_requested() -> void:
	# Ferme d'abord toutes les apps lancées dans le jeu (SIGTERM + grâce +
	# SIGKILL) puis quitte Godot ; le destructeur de WlrCompositor termine
	# xwayland-satellite et le bus D-Bus privé.
	compositor.shutdown_apps()
	# L'agent polkit du jeu vient d'être tué par shutdown_apps() : relancer
	# l'agent KDE hôte (dans le sens inverse, sa ré-inscription échouerait
	# tant que l'agent du jeu est encore enregistré).
	_restore_host_polkit_agent()
	get_tree().quit()

func _notification(what: int) -> void:
	# Fermeture de la fenêtre hors menu pause : même shutdown propre.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		compositor.shutdown_apps()
		_restore_host_polkit_agent()

func _on_pause_menu_visibility_changed() -> void:
	if pause_menu.visible:
		# Toujours libérer les touches enfoncées à l'ouverture du menu : le
		# relâchement réel serait ignoré par _input (retour tôt) et laisserait
		# une touche coincée côté xkbcommon. Inconditionnel : des touches
		# peuvent être enfoncées en mode focus ou via une layer surface aussi.
		compositor.release_all_keys()
		if interact_mode_active:
			interact_mode_active = false
			player.interact_mode_active = false
		if focus.is_active():
			focus.exit_focus()
