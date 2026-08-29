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
@onready var radial_menu = $Level/Player/RadialMenuLayer/RadialMenu
@onready var keyboard: VirtualKeyboard = $Level/Player/KeyboardLayer/VirtualKeyboard
@onready var tutorial = $Level/Player/TutorialLayer/Tutorial

var win3d: Node3D
var focus: Node3D
var layers: Node3D
var pins: Node3D
var fx: Node3D
var presenter: Node3D # présente le viewport à l'output headless pour OBS
var lan: Node # multijoueur LAN (hôte/join, avatars)
var cmd: Node # drone de commandes IPC (cyberrealm-exec)
var interactor: Node3D # clic gauche sur les objets du niveau (scripts user)
var file_share: Node3D # drag & drop de fichiers sur un avatar → rsync LAN

const LEVEL_BAKER := preload("res://scripts/baking/level_baker.gd")
const OCCLUSION_BAKER := preload("res://scripts/baking/occlusion_baker.gd")
const COMMAND_NODE := preload("res://scripts/ipc/command_node.gd")

# Diagnostic rendu (CYBERREALM_RENDER_DEBUG=1) : FPS + draw calls + primitives
# + VRAM toutes les RENDER_DEBUG_PERIOD_SEC, pour comparer deux machines.
const RENDER_DEBUG_ENV := "CYBERREALM_RENDER_DEBUG"
const RENDER_DEBUG_PERIOD_SEC := 2.0
var _rdi_enabled := false
var _rdi_accum := 0.0
var _rdi_frames := 0

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

var _level_path := ""
var _menu_just_closed := false
# Vrai si le tuto a été lancé automatiquement au premier lancement : à sa
# fermeture on mémorise tutorial_seen dans les settings persistants.
var _tutorial_first_run := false
# Vrai tant que le niveau affiché est celui de l'hôte LAN (apply_host_level) :
# à la déconnexion, le joueur doit retrouver SON niveau personnel.
var _level_swapped := false
# Transform d'origine du Player dans le niveau personnel (capturé au boot,
# avant toute session LAN) : sert de spawn au retour après déconnexion.
var _local_spawn_transform := {}

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
	_level_path = level_path
	var scene: PackedScene = load(level_path)
	if scene == null:
		push_error("Unable to load the level '%s'" % level_path)
		return
	var level := scene.instantiate()
	level.name = "Level"
	add_child(level)

# Blob baked du niveau courant pour le LAN (LevelBaker) : meshes/matériaux/
# textures embarqués → le client peut charger la map même sans ses assets
# (maps custom `res://user/` jouables en LAN). Le Player est exclu du blob
# (chaque machine réutilise son joueur local) ; le spawn est transmis à part.
func _bake_level_for_lan() -> Dictionary:
	var level := get_node_or_null("Level") as Node3D
	if level == null:
		return {}
	return LEVEL_BAKER.bake(level)

# Applique le niveau de l'hôte (reçu via le LAN, sous forme de blob baked) :
# on instancie sa scène mais on RÉUTILISE le Player local (et son UI/menus) —
# tout le câblage du jeu (managers, signaux) référence ce node. Seul
# l'environnement change ; le joueur est repositionné au spawn de l'hôte
# (transmis explicitement — le blob baked exclut le Player).
func apply_host_level(scene: PackedScene, spawn_pos: Vector3 = Vector3.ZERO, spawn_rotation: Vector3 = Vector3.ZERO, spawn_scale: Vector3 = Vector3.ONE) -> bool:
	if _swap_level(scene, spawn_pos, spawn_rotation, spawn_scale, true):
		_level_swapped = true
		return true
	return false

# Retour au niveau personnel du joueur après une déconnexion LAN : même
# mécanique que apply_host_level, mais avec SA scène d'origine (_level_path)
# et SON spawn d'origine. No-op si aucun niveau hôte n'a été appliqué (hôte,
# connexion échouée avant transfert…) — le joueur est déjà chez lui.
func restore_local_level() -> bool:
	if not _level_swapped:
		return true
	var scene: PackedScene = load(_level_path)
	if scene == null:
		scene = load(DEFAULT_LEVEL_PATH)
	if scene == null:
		push_error("Unable to restore the personal level '%s'" % _level_path)
		return false
	var t: Dictionary = _local_spawn_transform
	if _swap_level(scene, t.get("pos", Vector3.ZERO), t.get("rot", Vector3.ZERO), t.get("scale", Vector3.ONE), false):
		_level_swapped = false
		return true
	return false

# Remplace le niveau courant par `scene` en réutilisant le Player local, puis
# le repositionne au transform transmis. `use_scene_player_spawn` : si vrai et
# qu'aucun spawn n'est transmis, utiliser celui du Player embarqué dans la
# scène (comportement apply_host_level) ; sinon le transform passé fait foi.
func _swap_level(scene: PackedScene, spawn_pos: Vector3, spawn_rotation: Vector3, spawn_scale: Vector3, use_scene_player_spawn: bool) -> bool:
	if scene == null:
		return false
	var old_level := get_node_or_null("Level") as Node3D
	if old_level == null:
		return false
	var new_level := scene.instantiate()
	if new_level == null:
		return false
	var old_player := old_level.get_node_or_null("Player")
	var scene_player := new_level.get_node_or_null("Player")
	if use_scene_player_spawn and scene_player is Node3D and spawn_pos == Vector3.ZERO:
		spawn_pos = (scene_player as Node3D).position
		spawn_rotation = (scene_player as Node3D).rotation
		spawn_scale = (scene_player as Node3D).scale
	if old_player != null:
		if scene_player != null:
			new_level.remove_child(scene_player)
			scene_player.queue_free()
		old_player.get_parent().remove_child(old_player)
		new_level.add_child(old_player)
		# Le _ready() du Player se re-déclenche au re-parenting et ré-écrase
		# spawn_pos avec la position COURANTE : on re-pose explicitement le
		# spawn du niveau appliqué pour que les respawns l'utilisent.
		old_player.position = spawn_pos
		old_player.rotation = spawn_rotation
		old_player.scale = spawn_scale
		if "spawn_pos" in old_player:
			old_player.set("spawn_pos", spawn_pos)
		if "spawn_rotation" in old_player:
			old_player.set("spawn_rotation", spawn_rotation)
		if "spawn_scale" in old_player:
			old_player.set("spawn_scale", spawn_scale)
	# Bascule du manager LAN AVANT de libérer l'ancien niveau (les avatars
	# distants sont déplacés vers le nouveau conteneur).
	if lan:
		lan.on_level_swapped(new_level)
	for c in old_level.get_children():
		old_level.remove_child(c)
		c.queue_free()
	# Retirer l'ancien niveau de l'arbre AVANT d'ajouter le nouveau : sinon
	# add_child() renomme le nouveau (conflit de nom "Level") en "@Node3D@…"
	# et tout le $Level/… du jeu casse.
	remove_child(old_level)
	old_level.queue_free()
	new_level.name = "Level"
	add_child(new_level)
	# Niveau appliqué : son 1er rendu compile les shaders. Les avatars distants
	# restent invisibles jusqu'à ce que le niveau soit stable, puis sont
	# préchauffés hors viewport principal (évite un TDR au 1er rendu d'un
	# avatar skinné custom combiné aux captures Wayland).
	if lan:
		lan.mark_level_stable()
	# Occluders runtime pour la map appliquée (custom ou blob LAN) : réduit la
	# charge GPU en intérieur (l'occlusion culling ne dessine plus ce qui est
	# derrière les murs/gros volumes). No-op si la scène embarque déjà un
	# OccluderInstance3D baké dans l'éditeur.
	if OCCLUSION_BAKER.bake(new_level) > 0:
		print("[occ] occlusion culling generated for the applied level")
	return true

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
	# Spawn d'origine du joueur dans SON niveau (le Player._ready() vient de
	# le capturer) : référence pour restore_local_level() après une déconnexion
	# LAN. À capturer avant toute session, rien n'a encore bougé le joueur.
	_local_spawn_transform = {"pos": player.position, "rot": player.rotation, "scale": player.scale}
	# Occluders runtime pour le niveau de boot (custom ou défaut). Le niveau
	# est dans l'arbre : les transforms globaux sont valides.
	if OCCLUSION_BAKER.bake($Level as Node3D) > 0:
		print("[occ] occlusion culling generated for the boot level")

	# Diagnostic rendu : GPU + méthode de rendu une fois, puis stats
	# périodiques si CYBERREALM_RENDER_DEBUG=1.
	print("[render] GPU: %s — method: %s" % [
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method(),
	])
	_rdi_enabled = OS.get_environment(RENDER_DEBUG_ENV) == "1"

	# Plafond FPS surchargeable : le projet tourne à run/max_fps=60 (rendre
	# plus vite que l'écran ne sert qu'à chauffer). CYBERREALM_MAX_FPS=30
	# réduit encore l'utilisation GPU sans toucher au projet ; 0 = illimité.
	var max_fps_env := OS.get_environment("CYBERREALM_MAX_FPS")
	if max_fps_env != "":
		Engine.max_fps = int(max_fps_env)
		print("[render] max_fps = ", Engine.max_fps)

	# Capturé avant launch_portals() qui remplace DBUS_SESSION_BUS_ADDRESS par
	# le bus privé du jeu (sinon systemctl --user viserait le mauvais bus).
	_host_session_bus = OS.get_environment("DBUS_SESSION_BUS_ADDRESS")

	# Sous-systèmes, créés avant toute connexion de signal.
	win3d = _add_manager(preload("res://scripts/windows/windows_3d.gd"), "Windows3D")
	focus = _add_manager(preload("res://scripts/windows/focus_mode.gd"), "FocusMode")
	layers = _add_manager(preload("res://scripts/windows/layer_surfaces.gd"), "LayerSurfaces")
	pins = _add_manager(preload("res://scripts/windows/pinned_windows.gd"), "PinnedWindows")
	fx = _add_manager(preload("res://scripts/windows/effects.gd"), "Effects")
	presenter = _add_manager(preload("res://scripts/windows/present_manager.gd"), "PresentManager")

	win3d.setup(compositor, player)
	focus.setup(compositor, player, ui, win3d, keyboard)
	layers.setup(compositor, player, ui, focus, pause_menu, window_menu, keyboard)
	pins.setup(ui, focus, layers)
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
	# Purge un éventuel handshake de capture périmé : si le jeu ou portal-wlr
	# s'est terminé pendant l'attente d'un choix (cyberrealm-capture-pending),
	# le fichier reste dans $XDG_RUNTIME_DIR entre deux sessions. Sans purge,
	# _poll_capture_pending() ouvrirait le sélecteur au lancement suivant alors
	# qu'aucune source OBS ne demande de capture.
	_cleanup_stale_capture_files()
	# Purge les blobs LAN périmés dans user:// (app_userdata) : bakes de
	# niveau/avatar transférés lors de sessions précédentes. Les IDs de pair
	# étant aléatoires à chaque session, avatar_peer_<id>.scn n'est jamais
	# réutilisé et s'accumule sinon indéfiniment. Au démarrage, aucune session
	# LAN n'est active : ces fichiers sont forcément obsolètes.
	_cleanup_stale_bake_files()
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
	window_menu.setup(compositor, _get_window_texture, _get_window_shared, win3d.get_grabbed_window_id)
	window_menu.action_grab.connect(_on_window_menu_grab)
	window_menu.action_focus.connect(_on_window_menu_focus)
	window_menu.action_toggle_hide.connect(_on_window_menu_toggle_hide)
	window_menu.action_find.connect(_on_window_menu_find)
	window_menu.action_pin.connect(_on_window_menu_pin)
	window_menu.action_share.connect(_on_window_menu_share)
	window_menu.action_quit.connect(_on_window_menu_quit)
	window_menu.menu_closed.connect(_on_window_menu_closed)
	# Sélecteur de cible de capture OBS : ouvert quand portal-wlr signale une
	# nouvelle source « Screen Capture (PipeWire) » (cyberrealm-capture-pending).
	capture_selector.setup(compositor)
	capture_selector.target_chosen.connect(_on_capture_selector_chosen)
	capture_selector.selector_cancelled.connect(_on_capture_selector_cancelled)

	pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)
	pause_menu.visibility_changed.connect(_on_menu_visibility_changed)
	window_menu.visibility_changed.connect(_on_menu_visibility_changed)
	pause_menu.app_launch_requested.connect(compositor.launch_app)
	pause_menu.quit_requested.connect(_on_quit_requested)
	pause_menu.keyboard_layout_changed.connect(compositor.set_keyboard_layout)
	pause_menu.polkit_agent_changed.connect(_on_polkit_agent_changed)
	pause_menu.pins_layer_changed.connect(_on_pins_layer_changed)
	pause_menu.pins_opacity_changed.connect(_on_pins_opacity_changed)
	pause_menu.pins_position_changed.connect(_on_pins_position_changed)
	# Appliquer la couche, la transparence et la position des fenêtres épinglées
	pins.set_pins_above_focus(pause_menu.get_pins_above_focus())
	pins.set_pins_opacity(pause_menu.get_pins_opacity())
	pins.set_pins_position(pause_menu.get_pins_position())
	# Menu radial contextuel (B sur manette)
	radial_menu.radial_action.connect(_on_radial_action)
	# Clavier virtuel
	keyboard.setup(compositor, pause_menu, radial_menu)
	keyboard.keyboard_closed.connect(_on_keyboard_closed)
	pause_menu.setup_keyboard(keyboard)

	# Tutoriel de premier lancement : capture les menus réels et montre les
	# commandes. Se relance via pause_menu → Tutorial.
	tutorial.setup(pause_menu, radial_menu, window_menu)
	tutorial.closed.connect(_on_tutorial_closed)

	# Multijoueur LAN : l'hôte est serveur, chaque machine garde son propre
	# compositeur/bureau, seuls les avatars des joueurs sont partagés.
	lan = Node.new()
	lan.name = "LAN"
	lan.set_script(preload("res://scripts/network/lan_manager.gd"))
	add_child(lan)
	lan.setup($Level, pause_menu.get_lan_player_name(), pause_menu.get_lan_player_color())
	lan.level_bake_provider = _bake_level_for_lan
	lan.level_apply_requested.connect(apply_host_level)
	lan.local_level_restore_requested.connect(restore_local_level)
	pause_menu.lan_color_changed.connect(lan.update_local_color)
	pause_menu.lan_avatar_changed.connect(lan.set_selected_avatar)
	pause_menu.lan_name_changed.connect(lan.update_local_name)
	# Avatar choisi au menu LAN (persisté) : appliqué avant tout host/join.
	lan.set_selected_avatar(pause_menu.get_lan_avatar_path())
	pause_menu.lan_host_requested.connect(lan.host_game)
	pause_menu.lan_join_requested.connect(lan.join_game)
	pause_menu.lan_disconnect_requested.connect(lan.disconnect_session)
	pause_menu.lan_discover_requested.connect(lan.discover_games)
	pause_menu.tutorial_requested.connect(func(): tutorial.show_tutorial())
	pause_menu.lan_video_settings_changed.connect(lan.set_video_settings)
	lan.status_changed.connect(pause_menu.set_lan_status)
	lan.status_changed.connect(func(_text: String):
		pause_menu.set_lan_connected(lan.is_session_active())
	)
	lan.players_changed.connect(pause_menu.set_lan_players)
	lan.discovery_results.connect(pause_menu.set_lan_discovery_results)
	lan.pin_changed.connect(pause_menu.set_lan_pin)
	lan.windows_provider = win3d.get_windows_state
	lan.windows_moving_provider = win3d.is_window_interacting
	lan.window_image_provider = win3d.get_window_image
	lan.window_version_provider = win3d.get_window_texture_version
	lan.compositor = win3d.compositor
	lan.pins = pins
	lan.focus = focus
	# Le focus local réclame la copie CPU des captures le temps de sa salve
	# d'analyse de transparence (agrégé avec les besoins du partage LAN).
	focus.cpu_capture_notify = Callable(lan, "set_cpu_capture_consumer")
	lan.local_player = player
	win3d.windows_state_changed.connect(_on_windows_state_changed)

	# Drone de commandes IPC : cyberrealm-exec peut envoyer des commandes
	# au jeu en runtime (launch, windows, close, focus, etc.)
	cmd = COMMAND_NODE.new()
	cmd.name = "CommandNode"
	add_child(cmd)
	cmd.setup(compositor, win3d, focus, layers, pins, lan, player)

	# Interactions monde : clic gauche sur un objet du niveau portant un
	# script exposant interact() (convention documentée dans user/README.md).
	# Le relais RPC passe par ce node (même NodePath sur tous les pairs).
	interactor = Node3D.new()
	interactor.name = "Interactor"
	interactor.set_script(preload("res://scripts/interaction/world_interactor.gd"))
	add_child(interactor)
	interactor.setup(player, lan)

	# Partage de fichiers : drag & drop Wayland lâché sur un avatar → offre
	# rsync (prompt mot de passe SSH chez le destinataire, cf. README).
	file_share = Node3D.new()
	file_share.name = "FileShare"
	file_share.set_script(preload("res://scripts/network/file_share_manager.gd"))
	add_child(file_share)
	file_share.setup(player, lan, compositor)
	compositor.file_drop_received.connect(file_share.on_files_dropped)

	# TextureRect pour l'icône de drag-and-drop
	drag_icon_rect = TextureRect.new()
	drag_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	drag_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_icon_rect.visible = false
	drag_icon_rect.z_index = 100
	ui.add_child(drag_icon_rect)

	# Tutoriel au premier lancement (mémorisé via settings). Le await laisse
	# le viewport se rendre une première fois avant la capture des menus.
	if not pause_menu.get_tutorial_seen():
		_tutorial_first_run = true
		await get_tree().process_frame
		tutorial.show_tutorial()

# ── Dispatch des signaux compositeur vers les sous-systèmes ─────────

func _on_window_mapped(id: int, title: String, app_id: String) -> void:
	win3d.on_window_mapped(id, title, app_id)
	window_menu.on_window_opened(id)
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

# Une fenêtre locale a changé (ouverte, fermée, déplacée, redimensionnée,
# cachée, plein écran…) : prévient le LAN pour qu'il resynchronise les quads
# noirs que voient les autres joueurs.
func _on_windows_state_changed() -> void:
	if lan:
		lan.request_windows_sync()

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
	if focus.is_active():
		return focus.mouse_pos
	return layers._cursor_pos

# Cast un rayon depuis la souris et renvoie la fenêtre touchée : {"local": wid}
# pour une fenêtre du compositeur local, {"remote_peer": pid, "remote_wid":
# wid} pour une fenêtre d'un autre joueur (vue seule), {} sinon.
func _raycast_window_target(mouse_pos: Vector2) -> Dictionary:
	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	var ray_origin = cam.project_ray_origin(mouse_pos)
	var ray_dir = cam.project_ray_normal(mouse_pos)
	var to = ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return {}
	var body: Node3D = hit.collider
	if body.has_meta("window_id"):
		return {"local": body.get_meta("window_id")}
	if body.has_meta("remote_window"):
		var info: Dictionary = body.get_meta("remote_window")
		return {"remote_peer": int(info.get("peer_id", -1)), "remote_wid": int(info.get("wid", -1))}
	return {}

# Pin/unpin d'une fenêtre en PiP (touche P ou menu fenêtres).
func _toggle_pin(wid: int) -> void:
	if pins.is_pinned(wid):
		pins.unpin(wid)
	else:
		if not win3d.quads.has(wid):
			return
		pins.pin(wid, win3d.get_window_texture(wid))

# Pin/unpin d'une fenêtre DISTANTE en PiP (vue seule, aucun input).
func _toggle_remote_pin(peer_id: int, wid: int) -> void:
	if pins.is_pinned_remote(peer_id, wid):
		pins.unpin_remote(peer_id, wid)
	else:
		var tex: Texture2D = lan.get_remote_window_texture(peer_id, wid)
		if tex != null:
			pins.pin_remote(peer_id, wid, tex)

# ── Boucle principale ────────────────────────────────────────────────

func _process(delta: float) -> void:
	fx.process(delta)

	# Diagnostic rendu périodique (comparaison entre machines).
	if _rdi_enabled:
		_rdi_accum += delta
		_rdi_frames += 1
		if _rdi_accum >= RENDER_DEBUG_PERIOD_SEC:
			print("[render] fps=%d draw_calls=%d prims=%d vram=%.0fMB scale3d=%.2f" % [
				int(_rdi_frames / _rdi_accum),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
				get_viewport().scaling_3d_scale,
			])
			_rdi_accum = 0.0
			_rdi_frames = 0

	# La présentation du viewport vers l'output headless (capture OBS) et la
	# synchro du curseur sont gérées par PresentManager :
	# elles doivent continuer de tourner pendant que le menu pause gèle
	# l'arbre, sinon la capture se figerait sur la dernière frame.

	# Suivi de l'icône de drag-and-drop. STRETCH_KEEP dessine la texture à sa
	# taille NATIVE (pas celle du rect) : centrer sur la texture réelle, sinon
	# l'icône est décalée de la moitié de l'écart. Sous souris capturée,
	# get_mouse_position() est figée : le curseur compositeur est alors piloté
	# par le viseur central (_aim_pos) — l'icône suit donc le réticule.
	if drag_icon_rect and drag_icon_rect.visible:
		var sz := drag_icon_size
		if drag_icon_rect.texture != null:
			sz = Vector2(drag_icon_rect.texture.get_width(),
				drag_icon_rect.texture.get_height())
		drag_icon_rect.position = _aim_pos() - sz / 2.0
		# Adapter le z-index si le mode focus change pendant un drag actif
		var target_z := 2100 if focus.is_active() else 100
		if drag_icon_rect.z_index != target_z:
			drag_icon_rect.z_index = target_z

	# Session verrouillée : tout le pointeur part vers la surface de
	# verrouillage (le curseur y est visible), rien ne va au jeu.
	if layers.is_locked():
		player.session_locked = true
		# Forcer la souris visible pendant le lock : si un event ou un autre
		# mode a remis la souris en CAPTURED entre-temps, le lockscreen ne
		# recevrait aucun input pointeur.
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		layers.handle_locked_input()
		layers.handle_layer_pointer(delta)
		return
	player.session_locked = false

	# Sélecteur de cible de capture OBS : quand portal-wlr écrit
	# cyberrealm-capture-pending (une source PipeWire ajoutée dans OBS), on
	# ouvre le sélecteur pour choisir l'écran ou une fenêtre.
	_poll_capture_pending()

	if capture_selector.visible:
		return

	# Tutoriel ouvert : le monde est gelé pendant les pages d'onboarding.
	if tutorial.is_visible_open():
		return

	# Menu pause ouvert : aucun input ne doit aller au monde — ni clics
	# forwardés aux fenêtres, ni binds, ni raycast. Seul le menu pause est
	# interactif (sa souris/clavier sont gérés par le Control lui-même).
	if pause_menu.visible:
		return

	# Prompt de partage de fichiers (drag & drop sur un avatar) : modal,
	# le monde est gelé comme pour le menu pause.
	if file_share != null and file_share.is_modal_open():
		return

	# Map de l'hôte en cours de réception (join LAN pas encore finalisé) :
	# geler le joueur local — il n'est pas encore entré dans la session.
	# (`lan` est créé après un await dans _ready() : null pendant les
	# premières frames.)
	if lan != null:
		player.input_locked = lan.is_waiting_for_host_map()
	if player.input_locked:
		return


	# Menu radial (B sur manette) : toggle ouverture/fermeture
	if Input.is_action_just_pressed("radial_menu", true):
		if radial_menu.visible:
			radial_menu.hide_menu()
		elif not _menu_just_closed \
				and not focus.in_game() \
				and not window_menu.visible and not pause_menu.visible:
			var ctx := _determine_radial_context()
			radial_menu.show_menu(ctx)

	_menu_just_closed = false
	# Menu radial ouvert : geler le monde
	if radial_menu.visible:
		return

	if Input.is_action_just_pressed("window_menu", true) and not interact_mode_active and not focus.is_active() and not layers.keyboard_busy():
		layers.deactivate_layer_interact()
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
		# Kill : seulement pour une fenêtre LOCALE en focus. Le focus d'une
		# fenêtre distante est vue seule : pas de fermeture possible.
		if not focus.is_remote() and Input.is_action_just_pressed("kill_window", true):
			compositor.close_window(focus.get_focus_window_id())
			return
		focus.handle_focus_input(delta)
		return

	# Layer surfaces (waybar/rofi): quand la souris est visible et survole
	# une layer surface ou son popup, on forward l'input vers elle et on
	# laisse le raycast 3D de côté (les overlays 2D passent devant la scène).
	if not pause_menu.visible and layers.handle_layer_pointer(delta):
		return

	# Clavier occupé par un overlay keyboard-interactive (rofi, waybar...):
	# les touches partent vers l'overlay, les binds du jeu (focus, pin,
	# interact_mode, grab...) ne doivent pas se déclencher.
	if layers.keyboard_busy():
		return

	# F en visant une fenêtre → entrer en mode focus. Le rayon part de la
	# position réelle du viseur (_aim_pos), pas de get_mouse_position() :
	# en mode capturé celle-ci reste figée à l'endroit de la capture.
	# Une fenêtre DISTANTE entre aussi en focus mais en VUE SEULE (aucun
	# input forwardé, pas de kill).
	if Input.is_action_just_pressed("focus_window", true) and not interact_mode_active:
		layers.deactivate_layer_interact()
		var target := _raycast_window_target(_aim_pos())
		if target.has("local"):
			focus.enter_focus(target["local"])
			return
		if target.has("remote_peer"):
			focus.enter_remote_focus(target["remote_peer"], target["remote_wid"],
				lan.get_remote_window_texture(target["remote_peer"], target["remote_wid"]))
			return

	# P en visant une fenêtre → pin/unpin PiP
	if Input.is_action_just_pressed("pin_window", true) and not interact_mode_active:
		var target := _raycast_window_target(_aim_pos())
		if target.has("local"):
			_toggle_pin(target["local"])
			return
		if target.has("remote_peer"):
			_toggle_remote_pin(target["remote_peer"], target["remote_wid"])
			return

	# K en visant une fenêtre LOCALE → demander sa fermeture (close). Les
	# fenêtres distantes ne sont pas fermables (aucune interaction).
	if Input.is_action_just_pressed("kill_window", true) and not interact_mode_active:
		var target := _raycast_window_target(_aim_pos())
		if target.has("local"):
			compositor.close_window(target["local"])
			return

	# H en visant une fenêtre LOCALE → masquer/afficher (HIDE/SHOW)
	if Input.is_action_just_pressed("hide_window", true) and not interact_mode_active:
		var target := _raycast_window_target(_aim_pos())
		if target.has("local"):
			win3d.toggle_hide(target["local"])
			return

	# S en visant une fenêtre LOCALE → basculer le partage screenshare
	# (visibilité chez les autres joueurs, aucune interaction distante).
	if Input.is_action_just_pressed("share_window", true) and not interact_mode_active:
		var target := _raycast_window_target(_aim_pos())
		if target.has("local"):
			win3d.set_window_shared(target["local"], not win3d.is_window_shared(target["local"]))
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
	# Interaction monde (clic gauche sur un objet scripté du niveau) : même
	# rayon, évalué APRÈS le système de fenêtres — un clic qui touche une
	# surface Wayland lui appartient et n'interagit jamais avec le monde.
	if interactor != null:
		interactor.update_aim(ray_origin, ray_dir)
	# Cible de drop pendant un drag Wayland (même rayon caméra).
	if file_share != null:
		file_share.update_drag(ray_origin, ray_dir)
	

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
	if layers.is_locked():
		if event is InputEventKey:
			layers.forward_keyboard_event(event)
			return
		elif event is InputEventJoypadButton:
			layers.forward_gamepad_event(event)
			return

	# Une layer surface keyboard-interactive (rofi, waybar menu) détient le
	# focus clavier : forward vers elle, quel que soit le mode de la souris.
	if layers.keyboard_busy() and not capture_selector.visible:
		if event is InputEventKey:
			layers.forward_keyboard_event(event)
			return
		elif event is InputEventJoypadButton:
			layers.forward_gamepad_event(event)
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
		print("[gesture] magnify received factor=", mg.factor, " hovered=", win3d.is_in_window, " focus=", focus.is_active())
		compositor.forward_pointer_pinch(mg.factor, 0.0, 0.0)
		get_viewport().set_input_as_handled()
		return

	# En mode focus, forward le clavier et tracker la souris capturée.
	# Le focus DISTANT (vue seule) consomme aussi tout l'input (via
	# handle_input_event) pour que rien ne fuie vers les binds du jeu.
	if focus.is_active() and not capture_selector.visible \
			and (focus.is_remote() or focus.get_focus_window_id() != -1):
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
	# Au-dessus des overlays focus (z>=2000) quand le mode focus est actif
	drag_icon_rect.z_index = 2100 if focus.is_active() else 100

func _on_drag_icon_removed() -> void:
	drag_icon_rect.visible = false
	drag_icon_rect.texture = null
	drag_icon_rect.z_index = 100

# ── Window menu helpers ──────────────────────────────────────────────

func _get_window_texture(wid: int) -> Texture2D:
	return win3d.get_window_texture(wid)

func _get_window_shared(wid: int) -> bool:
	return win3d.is_window_shared(wid)

func _on_window_menu_grab(wid: int) -> void:
	# Toggle ON/OFF : grab ON → fermer le menu pour déplacer la fenêtre à la
	# caméra ; grab OFF → relâcher la prise, le menu reste ouvert.
	win3d.toggle_grab_window(wid)
	window_menu.hide_menu()

func _on_window_menu_focus(wid: int) -> void:
	focus.enter_focus(wid)
	window_menu.hide_menu()

func _on_window_menu_toggle_hide(wid: int) -> void:
	win3d.toggle_hide(wid)
	window_menu.hide_menu()

func _on_window_menu_find(wid: int) -> void:
	fx.toggle_find(wid)
	window_menu.hide_menu()

func _on_window_menu_pin(wid: int) -> void:
	_toggle_pin(wid)
	window_menu.hide_menu()

func _on_window_menu_share(wid: int) -> void:
	# Partage « screenshare » : on ne fait que basculer la visibilité du quad
	# chez les autres joueurs — aucune interaction distante possible.
	win3d.set_window_shared(wid, not win3d.is_window_shared(wid))
	window_menu.hide_menu()

func _on_window_menu_quit(wid: int) -> void:
	compositor.close_window(wid)

func _on_window_menu_closed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_keyboard_closed() -> void:
	if not layers.layer_interact_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ── Menu radial contextuel ────────────────────────────────────────

func _determine_radial_context() -> String:
	if focus.is_active():
		return "focus"
	var target := _raycast_window_target(_aim_pos())
	if target.has("local") or target.has("remote_peer"):
		return "window"
	return "fps"

func _on_radial_action(action: String) -> void:
	match action:
		"window_menu":
			window_menu.show_menu()
		"layer_interact":
			layers.toggle_layer_interact()
		"interact":
			_on_radial_action("keyboard")
			if interact_mode_active:
				compositor.release_all_keys()
			interact_mode_active = not interact_mode_active
			player.interact_mode_active = not player.interact_mode_active
		"grab":
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				win3d.toggle_grab_window(target["local"])
		"focus":
			interact_mode_active = false
			player.interact_mode_active = false
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				layers.deactivate_layer_interact()
				focus.enter_focus(target["local"])
			elif target.has("remote_peer"):
				layers.deactivate_layer_interact()
				focus.enter_remote_focus(target["remote_peer"], target["remote_wid"],
					lan.get_remote_window_texture(target["remote_peer"], target["remote_wid"]))
		"kill":
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				compositor.close_window(target["local"])
		"pin":
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				_toggle_pin(target["local"])
			elif target.has("remote_peer"):
				_toggle_remote_pin(target["remote_peer"], target["remote_wid"])
		"share":
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				win3d.set_window_shared(target["local"], not win3d.is_window_shared(target["local"]))
		"hide":
			var target := _raycast_window_target(_aim_pos())
			if target.has("local"):
				win3d.toggle_hide(target["local"])
		"exit_focus":
			keyboard.hide_menu()
			focus.exit_focus()
		"kill_focused":
			keyboard.hide_menu()
			if focus.is_active() and not focus.is_remote():
				compositor.close_window(focus.get_focus_window_id())
		"keyboard":
			keyboard.toggle_menu()
		"binds":
			var binds: Array = pause_menu.get_custom_binds()
			if binds.size() > 0:
				radial_menu.show_menu("binds", -1, binds)
		_:
			if action.begins_with("bind:"):
				var cmd := action.substr(5)
				if not cmd.is_empty():
					compositor.launch_app(cmd)

# ── Sélecteur de capture OBS ─────────────────────────────────────────

# Supprime les fichiers du handshake de capture (pending + choice) laissés par
# une session précédente. Appelé au démarrage, avant launch_portals() : aucune
# source OBS ne peut être en cours de capture à ce moment, les fichiers sont
# donc forcément périmés.
func _cleanup_stale_capture_files() -> void:
	var rt := OS.get_environment("XDG_RUNTIME_DIR")
	if rt.is_empty():
		return
	for name: String in ["cyberrealm-capture-pending", "cyberrealm-capture-choice"]:
		var path := rt + "/" + name
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_selector_waiting = false

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

# Fichiers de transfert LAN écrits dans user:// par LevelBaker/lan_manager :
# lan_bake.scn (hôte, niveau baké), lan_level.scn (client, niveau reçu),
# avatar_send.scn (hôte, avatar baké) et avatar_peer_<id>.scn (client, un
# avatar reçu par pair). Purge au démarrage : aucune session LAN n'est active,
# les IDs de pair (aléatoires) ne seront jamais réutilisés.
func _cleanup_stale_bake_files() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	for name: String in ["lan_bake.scn", "lan_level.scn", "avatar_send.scn"]:
		if dir.file_exists(name):
			dir.remove(name)
	for f in dir.get_files():
		if f.begins_with("avatar_peer_") and f.ends_with(".scn"):
			dir.remove(f)

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

func _on_pins_position_changed(position: String) -> void:
	pins.set_pins_position(position)

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
		# Le menu pause reprend la souris : quitter le mode interaction layer.
		layers.deactivate_layer_interact()
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

func _on_menu_visibility_changed() -> void:
	if not window_menu.visible and not pause_menu.visible:
		_menu_just_closed = true

# Fermeture du tutoriel (bouton Close ou Esc). Au premier lancement
# (déclenché automatiquement), on mémorise tutorial_seen pour ne plus
# le rejouer au démarrage.
func _on_tutorial_closed() -> void:
	if _tutorial_first_run:
		_tutorial_first_run = false
		pause_menu.set_tutorial_seen(true)
	_menu_just_closed = true
