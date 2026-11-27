extends Node3D

# Sélection de zone (PrtSc) : outil de capture rectangulaire sur l'écran.
# L'outil armé (zone_select_active) avale tout l'input ; un glisser du bouton
# gauche dessine la marquise, son relâchement émet zone_capture_selected
# (croppée depuis le viewport par wayland_room.gd) si la zone fait au moins
# ZONE_MIN_PX, sinon rien. Escape annule. Fonctionne aussi en focus distant.
signal zone_capture_selected(screen_rect: Rect2)
# Le joueur a pressé release_shortcuts pendant qu'une fenêtre capture les raccourcis
# (zwp_keyboard_shortcuts_inhibit_v1) : toplevel_bridge.gd les lui rend.
signal shortcuts_release_requested

var zone_select_active := false

const FOCUS_Z_BASE := 2000 # au-dessus des layer surfaces et de leurs popups
const FOCUS_POPUP_Z := FOCUS_Z_BASE + 50
const FOCUS_TITLEBAR_FG := Color(0.85, 0.88, 0.96)

# Écart (m) entre les fenêtres de la pile à la sortie du mode focus : chacune
# est posée STACK_Z_OFFSET devant la précédente, vers la caméra.
const STACK_Z_OFFSET := -0.1

# Recadre la texture de capture sur la zone de contenu réelle. Le buffer
# d'allocation (VkImage / offscreen) est arrondi au palier supérieur
# (round_up_capture_size, multiple de 64) alors que le signal ne reporte
# que la taille du contenu : sans recadrage, le UV [0,1] couvre la totalité
# de la texture (zone transparente incluse) et STRETCH_SCALE écrase l'image.
# TEXTURE = le TextureRect.texture (le contrôle ne dessine que s'il est
# renseigné) ; la texture de capture est réutilisée telle quelle.
const POPUP_CROP_SHADER_CODE = """
shader_type canvas_item;
uniform vec2 content_size = vec2(0.0, 0.0);
// Fenêtres probe-classées OPAQUES : normalise l'alpha comme le shader 3D.
// Les buffers de jeux portent un alpha < 1 aux UI semi-transparentes
// composées dans leur buffer (inventaires, menus...) que les bureaux réels
// neutralisent (formats RGBX). Sans ça, l'overlay focus révélerait
// l'environnement 3D derrière au lieu du contenu de l'app (le 3D masque le
// défaut en doublant l'alpha). Les fenêtres réellement translucides
// (occludeur suspendu, ex. Konsole) gardent leur alpha brut.
uniform bool opaque_mode = false;

void fragment() {
	vec2 ts = vec2(textureSize(TEXTURE, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	vec4 tex = texture(TEXTURE, mapped_uv);
	if (opaque_mode) {
		vec3 unmultiplied = tex.a > 0.01 ? tex.rgb / max(tex.a, 0.001) : tex.rgb;
		COLOR = vec4(unmultiplied, clamp(tex.a * 2.0, 0.0, 1.0));
	} else {
		COLOR = tex;
	}
}
"""

var popup_crop_shader: Shader

# Duck-typé volontairement (pas `WlrCompositor`) : le type statique résout
# les appels vers la table de méthodes NATIVES, ce qui rend impossible
# d'injecter un double dans les tests headless. Les effets de la règle
# plein écran (setter appelé, ou non, et seulement sur transition) sont
# justement ce qu'on doit pouvoir vérifier.
var compositor
var player: Node3D
var ui: CanvasLayer
var windows: Node3D

var focus_mode := false

# Pile des fenêtres focalisées : le DERNIER élément est la fenêtre active
# (celle qui reçoit l'input et dont l'overlay est au-dessus des autres).
var focus_stack: Array = []
# window_id (int) -> TextureRect plein écran affichant la fenêtre en overlay 2D.
var focus_rects: Dictionary = {}
# window_id (int) -> état propre à la fenêtre : original_size, mouse_captured,
# mouse_uv, surface_size, content_offset, content_size, ui_offset (décalage
# 2D de l'overlay accumulé par le déplacement).
var focus_states: Dictionary = {}
# La seule fenêtre de la pile passée en plein écran côté compositeur (la
# première entrée en focus). Les suivantes conservent leur taille d'origine.
var focus_fullscreen_id := -1
# window_id (int) -> true pour les fenêtres agrandies (maximize) à l'entrée en
# focus : leur taille d'origine (focus_states[id].original_size) est restaurée
# à la sortie. Miroir de pre_fullscreen_surface_sizes de windows_3d.gd.
var focus_maximized: Dictionary = {}
# popup_id (int) -> TextureRect overlay en mode focus. Seuls les popups de la
# fenêtre ACTIVE sont overlayés : les fenêtres du dessous sont couvertes par
# l'overlay actif et leurs popups sont recréés à la réactivation.
var focus_popup_rects: Dictionary = {}
# window_id (int) -> true pour les fenêtres ouvertes PENDANT le mode focus
# (ajoutées à la pile alors que focus_mode était déjà actif). Elles n'ont pas
# de taille d'origine fiable : on ne leur restaure rien à la sortie.
var focus_opened_during: Dictionary = {}

# Grab pointeur sur un popup (drag-and-drop) : tant qu'un bouton est enfoncé
# sur un popup, TOUS les événements (motion + boutons) partent vers CE popup,
# même si le curseur le quitte. Sans ça, un drag qui sort des bords d'un popup
# (menus/dropdowns petits) perd ses événements (relâchement inclus, qui part
# vers la fenêtre principale) → le drag-and-drop ne fonctionne pas.
var popup_drag_id: int = -1
var popup_buttons_down: int = 0

# Grab implicite fenêtre : dernière fenêtre ayant reçu un appui bouton. Tant
# qu'un bouton reste enfoncé, motion + boutons continuent d'être routés vers
# ELLE même si le curseur quitte sa zone affichée (contrat Wayland implicite :
# sans ça, un drag de sélection sauterait à la fenêtre du dessous dès que le
# curseur la quitte). Miroir de popup_drag_id pour les popups.
var window_press_id: int = -1
var window_press_buttons: int = 0

# Déplacement d'une fenêtre de la pile : l'overlay suit
# le curseur (décalage persistant dans l'état de la fenêtre, cf. ui_offset),
# tous les événements pointeur sont absorbés jusqu'au relâchement du bouton.
# La fenêtre plein écran (fond de pile) n'est pas déplaçable.
var window_move_id: int = -1

# Barres de titre des fenêtres de la pile : window_id -> Panel. Pas de barre
# pour la fenêtre plein écran (non déplaçable, son contenu couvre l'écran).
# Hit-test manuel via _titlebar_at : les Controls sont en MOUSE_FILTER_IGNORE
# pour ne pas interférer avec la routing souris du mode focus.
var focus_title_bars: Dictionary = {}

# État brut du bouton gauche, suivi depuis le flux InputEventMouseButton :
# l'action Godot "left_click" est bindée sans modifieur ; le flux
# d'événements, lui, ne ment jamais. Utilisé en complément des polls action
# pour le démarrage/la fin du déplacement.
var _left_down := false
var _left_event_pressed := false
var _left_event_frame := -1

# Curseur custom de la fenêtre active dessiné en overlay 2D (TextureRect
# positionné sur le pointeur) : réplique le wl_pointer.set_cursor de
# l'application en focus pour les fenêtres X11 remontées via
# xwayland-satellite. Le curseur système est masqué (MOUSE_MODE_HIDDEN) pour
# éviter le double curseur ; sans image custom capturée on retombe sur le
# curseur système. cursor_overlay_serial = serial de la dernière image
# appliquée (-1 si aucune) ; on ne re-crée la texture que quand le client en
# pose une nouvelle (commits de la surface).
var cursor_overlay: TextureRect
var _hw_cursor_key := 0 # 0 = aucun curseur matériel appliqué

# Curseur du propriétaire affiché par-dessus le focus DISTANT (vue seule) :
# réplique la position et l'apparence du curseur du joueur qui possède la
# fenêtre, tant qu'il la survole. État reçu de lan_manager via
# set_remote_cursor_state (position ~30/s, image quand le client la change).
var remote_cursor_overlay: TextureRect
var remote_cursor_state: Dictionary = {}
var remote_cursor_fallback_tex: ImageTexture

# Focus d'une fenêtre DISTANTE (streamée par un autre joueur) : affichage plein
# écran VUE SEULE. Aucun input (clavier/souris) n'est forwardé, pas de kill.
# focus_stack est vide (aucune fenêtre du compositeur local), _active_id() et
# get_focus_window_id() renvoient donc -1.
var remote_focus := false
var remote_focus_peer := -1
var remote_focus_wid := -1
var remote_focus_rect: TextureRect = null
# Le focus n'occlude PAS le reste du jeu : l'occludeur reste invisible, la
# scène 3D derrière l'overlay continue d'être rendue. Mettre à true pour
# retrouver l'occlusion culling plein écran. La sonde alpha tourne dans les
# deux cas (elle règle aussi opaque_mode de l'overlay).
const FOCUS_OCCLUDES_WORLD := true

var _world_occluder: OccluderInstance3D

# Posé par wayland_room : Callable(clé: String, actif: bool). Enregistre/
# libère une demande de copie CPU des captures auprès du lan_manager.
var cpu_capture_notify: Callable = Callable()

var mouse_pos := Vector2.ZERO
var SPEED := 700.0
var _scroll_up_held := false
var _scroll_down_held := false
var virtual_keyboard: VirtualKeyboard

# ── Modules (nœuds enfants, créés dans _init : mêmes chemins de RPC chez le serveur et les clients) ──
const InputModule := preload("res://scripts/windows/focus/input.gd")
const OcclusionModule := preload("res://scripts/windows/focus/occlusion.gd")
const RemoteModule := preload("res://scripts/windows/focus/remote.gd")
const TitlebarModule := preload("res://scripts/windows/focus/titlebar.gd")
const PopupsModule := preload("res://scripts/windows/focus/popups.gd")
const ZoneSelectModule := preload("res://scripts/windows/focus/zone_select.gd")
var input: InputModule = null
var occlusion: OcclusionModule = null
var remote: RemoteModule = null
var remote_control: Node = null    # LAN/RemoteControl (posé par wayland_room) : contrôle d'une fenêtre distante
var titlebar: TitlebarModule = null
var popups: PopupsModule = null
var zone_select: ZoneSelectModule = null

func _init() -> void:
	input = InputModule.new()
	input.name = "Input"
	input.fm = self
	add_child(input)
	occlusion = OcclusionModule.new()
	occlusion.name = "Occlusion"
	occlusion.fm = self
	add_child(occlusion)
	remote = RemoteModule.new()
	remote.name = "Remote"
	remote.fm = self
	add_child(remote)
	titlebar = TitlebarModule.new()
	titlebar.name = "Titlebar"
	titlebar.fm = self
	add_child(titlebar)
	popups = PopupsModule.new()
	popups.name = "Popups"
	popups.fm = self
	add_child(popups)
	zone_select = ZoneSelectModule.new()
	zone_select.name = "ZoneSelect"
	zone_select.fm = self
	add_child(zone_select)

func _process(delta: float) -> void:
	if focus_mode:
		titlebar._sync_active_fullscreen()
		occlusion._update_world_occluder()
		occlusion._update_occluder_for_alpha(delta)
		var st = _state(_active_id())
		if st["mouse_captured"] and not st.get("is_game_overridden", false):
			st["is_game"] = true

func setup(compositor_ref, player_ref: Node3D, ui_ref: CanvasLayer, windows_ref: Node3D, keyboard: VirtualKeyboard) -> void:
	compositor = compositor_ref
	player = player_ref
	ui = ui_ref
	windows = windows_ref
	virtual_keyboard = keyboard
	mouse_pos = get_viewport().get_mouse_position()

	popup_crop_shader = Shader.new()
	popup_crop_shader.code = POPUP_CROP_SHADER_CODE

	cursor_overlay = TextureRect.new()
	cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cursor_overlay.z_index = FOCUS_POPUP_Z + 50
	cursor_overlay.visible = false
	ui.add_child(cursor_overlay)

	remote_cursor_overlay = TextureRect.new()
	remote_cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	remote_cursor_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	remote_cursor_overlay.z_index = FOCUS_POPUP_Z + 51
	remote_cursor_overlay.visible = false
	ui.add_child(remote_cursor_overlay)
	remote_cursor_fallback_tex = remote._make_remote_cursor_fallback()

func is_active() -> bool:
	return focus_mode

# Vrai si le mode focus affiche une fenêtre distante (vue seule, aucun input).
func is_remote() -> bool:
	return remote_focus

func get_remote_peer() -> int:
	return remote_focus_peer

func get_remote_wid() -> int:
	return remote_focus_wid

func get_focus_window_id() -> int:
	return _active_id()

func _active_id() -> int:
	return focus_stack[-1] if not focus_stack.is_empty() else -1

func _state(id: int) -> Dictionary:
	if not focus_states.has(id):
		focus_states[id] = {
		"original_size": Vector2.ONE,
		"mouse_captured": false,
		"is_game": false,
		"is_game_overridden": false,
		"mouse_uv": Vector2(0.5, 0.5),
		"surface_size": Vector2(1, 1),
		"content_offset": Vector2.ZERO,
		"content_size": Vector2(1, 1),
		"ui_offset": Vector2.ZERO,
	}
	return focus_states[id]

# Maximise la fenêtre : le client reçoit la taille du viewport, comme
# toggle_window_fullscreen(id, true) de windows_3d.gd. Pas d'xdg fullscreen :
# la fenêtre garde son statut de fenêtre normale (barre de titre, déplaçable).
func _maximize_window(id: int) -> void:
	if focus_opened_during.has(id):
		return
	var vp_size := get_viewport().get_visible_rect().size
	compositor.set_window_size(id, int(vp_size.x), int(vp_size.y))
	focus_maximized[id] = true

# Restaure la taille d'origine d'une fenêtre maximisée (no-op sinon).
func _restore_window_size(id: int) -> void:
	if not focus_maximized.has(id):
		return
	focus_maximized.erase(id)
	if focus_opened_during.has(id):
		return
	var orig: Vector2 = _state(id)["original_size"]
	compositor.set_window_size(id, int(orig.x), int(orig.y))

func enter_focus(id: int) -> void:
	if remote_focus:
		return
	if not windows.quads.has(id) or not is_instance_valid(windows.quads[id]):
		return
	if focus_stack.has(id):
		return
	var entering := not focus_mode
	if not entering:
		focus_opened_during[id] = true
	focus_mode = true
	focus_stack.append(id)
	# Le quad 3D garde sa taille pendant le focus (voir windows.focus_frozen).
	windows.focus_frozen[id] = true
	# L'overlay couvre la vue : activer l'occludeur plein écran pour que
	# l'occlusion culling retire la scène 3D derrière.
	occlusion._ensure_world_occluder()
	_world_occluder.visible = FOCUS_OCCLUDES_WORLD
	# Nouvelle fenêtre focus : relance une salve d'analyse de transparence.
	occlusion._reset_occluder_alpha_state()
	occlusion._start_alpha_probe()

	var info: Dictionary = windows.get_quad_info(id)
	var st := _state(id)
	st["mouse_captured"] = false
	st["mouse_uv"] = Vector2(0.5, 0.5)
	st["original_size"] = info.get("surface_size", Vector2(1, 1))

	# Passer en plein écran côté compositeur : seule la première fenêtre de la
	# pile l'est ; les suivantes conservent leur taille (leur overlay 2D plein
	# écran les affiche quand même à l'écran).
	if focus_fullscreen_id == -1:
		# Plein écran UNIQUEMENT si le client l'a demandé. Le getter lit
		# toplevel->requested.fullscreen : c'est la seule source fiable, y
		# compris quand la demande précède le premier commit du client (un
		# lecteur vidéo qui s'ouvre directement en plein écran), cas où le
		# compositeur n'émet aucun signal.
# À l'entrée, il n'y a pas de « courant » à préserver : la fenêtre
		# entre fresh, donc on applique directement l'état demandé. Le helper
		# pose focus_fullscreen_id et n'appelle le setter que si l'état
		# change — ici c'est toujours le premier poser, donc un appel.
		if compositor.is_window_fullscreen_requested(id):
			compositor.set_window_fullscreen(id, true)
			focus_fullscreen_id = id
			# Cadence de capture prioritaire (60/s) : l'image affichée plein
			# écran est bornée par la recapture de sa texture. Sans ça, un jeu
			# plein écran resterait bridé à la cadence "quads 3D".
			compositor.set_focus_capture_priority_window(id)
			titlebar._remove_title_bar(id)

	# Maximize : toute fenêtre qui n'est pas passée en plein écran xdg est
	# agrandie à la taille du viewport.
	if focus_fullscreen_id != id:
		_maximize_window(id)

	# TextureRect dédié à cette fenêtre : la première (plein écran) couvre
	# tout l'écran, les suivantes sont centrées à taille naturelle (la
	# fenêtre plein écran reste visible autour). L'overlay de la fenêtre
	# active porte le z le plus haut (FOCUS_Z_BASE + position dans la pile).
	var is_fullscreen := focus_fullscreen_id == id
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# IMPÉRATIF : par défaut (EXPAND_KEEP_SIZE) un TextureRect se prend sa
	# texture comme taille minimale. Or la texture de capture est arrondie au
	# multiple de 64 (ex. 1920x1088 pour un contenu 1918x1054) : sans ce flag,
	# l'overlay refusait de rétrécir sous la taille du BUFFER, débordait du
	# viewport et le contenu apparaissait décalé (jusqu'à hors écran à droite).
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_PASS
	rect.visible = true
	if is_fullscreen or focus_maximized.has(id):
		if is_fullscreen:
			rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		# Le buffer de capture est arrondi au multiple de 64 (1920x1088 pour
		# un contenu 1920x1080) : en KEEP_ASPECT_CENTERED sur ce buffer, le
		# fullscreen était légèrement dé-zoomé (fines barres latérales). On
		# croppe la zone de CONTENU avec le shader des popups et on l'étire
		# exactement sur le viewport (STRETCH_SCALE) : plus aucun bord perdu,
		# quelle que soit la taille réelle du contenu côté client.
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		var mat := ShaderMaterial.new()
		mat.shader = popup_crop_shader
		mat.set_shader_parameter("content_size", st["content_size"])
		rect.material = mat
	rect.z_index = FOCUS_Z_BASE + focus_stack.size()
	ui.add_child(rect)
	focus_rects[id] = rect
	occlusion._apply_focus_alpha_mode()

	# Récupérer la texture courante depuis le quad 3D
	rect.texture = info.get("texture")
	st["surface_size"] = info.get("surface_size", Vector2(1, 1))
	st["content_offset"] = info.get("content_offset", Vector2.ZERO)
	st["content_size"] = info.get("content_size", st["surface_size"])
	_refresh_rect_layout(id)
	# Barre de titre (déplacement par clic-glisser, sans modificateur).
	titlebar._ensure_title_bar(id)
	# Le premier layout a eu lieu avant la barre : le refaire pour que le
	# centrage de l'ensemble (barre + contenu) s'applique dès l'ouverture.
	_refresh_rect_layout(id)

	# Cacher le quad 3D, l'overlay 2D prend le relais
	# windows.set_quad_visible(id, false)

	# Bloquer le player à la première entrée en mode focus
	if entering:
		player.focus_mode_active = true

	_activate_window(id)

func exit_focus() -> void:
	if not focus_mode:
		return

	# Focus distant (vue seule) : pas de fenêtre du compositeur à restaurer.
	if remote_focus:
		# Fenêtre sous contrôle : relâcher ce que l'invité tient enfoncé chez le propriétaire.
		if remote_control != null:
			remote_control.release_inputs(remote_focus_peer, remote_focus_wid)
		if remote_focus_rect != null and is_instance_valid(remote_focus_rect):
			remote_focus_rect.queue_free()
		remote_focus_rect = null
		_reset_focus_ui()
		return

	compositor.release_all_keys()

	# Fenêtres que le client va redimensionner (retour à leur taille d'origine) :
	# leur quad suivra la prochaine texture. Les autres sont recalées tout de
	# suite sur leur surface actuelle.
	var resized_back := {}
	for rid in focus_stack:
		if focus_opened_during.has(rid):
			continue
		if rid == focus_fullscreen_id or focus_maximized.has(rid):
			resized_back[rid] = true
	for rid in focus_stack:
		windows.release_focus_frozen(rid, not resized_back.has(rid))

	# Restaurer la fenêtre passée en plein écran (seule la première de la pile
	# l'était) et réafficher les quads 3D de toute la pile. Les fenêtres déjà
	# fermées (kill) ne sont plus dans quads et sont ignorées.
	if focus_fullscreen_id != -1 and windows.quads.has(focus_fullscreen_id) \
		and is_instance_valid(windows.quads[focus_fullscreen_id]):
		compositor.set_window_fullscreen(focus_fullscreen_id, false)
		if not focus_opened_during.has(focus_fullscreen_id):
			var st := _state(focus_fullscreen_id)
			compositor.set_window_size(focus_fullscreen_id, int(st["original_size"].x), int(st["original_size"].y))
	# Fenêtres maximisées à l'entrée en focus : taille d'origine.
	for mid in focus_maximized.keys():
		if windows.quads.has(mid) and is_instance_valid(windows.quads[mid]):
			_restore_window_size(mid)
	focus_maximized.clear()
	focus_opened_during.clear()
	# Réafficher les quads 3D en les empilant l'un devant l'autre : la
	# première fenêtre garde sa position, chacune des suivantes est posée
	# STACK_Z_OFFSET devant la précédente (le long de la normale du quad,
	# vers la caméra). Les fenêtres déjà fermées (kill) ne sont plus dans
	# quads et sont ignorées.
	var stack_index := 0
	var first_quad: MeshInstance3D = null
	var first_id := -1
	for id in focus_stack:
		if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
			var quad: MeshInstance3D = windows.quads[id]
			if first_quad != null:
				# Passe par windows : l'orientation stockée est ce que la
				# rotation au collage relit. Ne recopier que global_basis
				# laisserait l'état derrière, et la fenêtre se replacerait au
				# prochain cran de rotation.
				windows.copy_window_basis(first_id, id)
				quad.global_position = first_quad.global_position \
					- first_quad.global_basis.z.normalized() * STACK_Z_OFFSET * stack_index
			else:
				first_quad = quad
				first_id = id
			windows.set_quad_visible(id, true)
			stack_index += 1

	_reset_focus_ui()

func on_window_unmapped(id: int) -> void:
	if not focus_mode or not focus_stack.has(id):
		return
	var was_active := id == _active_id()
	# Même protection qu'à la sortie du focus, inconditionnelle : la fenêtre
	# tuée disparaît (quad, occludeur) et le buffer d'occlusion garde sa
	# silhouette ; si l'occludeur monde est déjà masqué (sonde de translucidité)
	# _hide_world_occluder ne suspendrait rien.
	occlusion._suspend_occlusion_after_focus()
	focus_stack.erase(id)
	windows.focus_frozen.erase(id)
	titlebar._remove_title_bar(id)
	if focus_rects.has(id):
		if is_instance_valid(focus_rects[id]):
			occlusion._hide_world_occluder()
			await get_tree().physics_frame
			focus_rects[id].queue_free()
		focus_rects.erase(id)
	focus_states.erase(id)
	focus_maximized.erase(id)
	focus_opened_during.erase(id)
	if window_move_id == id:
		window_move_id = -1
	if window_press_id == id:
		window_press_id = -1
		window_press_buttons = 0
	# Si la fenêtre plein écran quitte la pile, on ne promeut le nouveau
	# sommet QUE s'il a lui-même demandé le plein écran. L'ancien invariant
	# (« le mode focus garde toujours exactement une fenêtre plein écran ») est
	# abandonné : le mode focus n'impose plus le plein écran à personne.
	if focus_fullscreen_id == id:
		focus_fullscreen_id = -1
		# `id` vient d'être retiré de la pile : le nouveau sommet est
		# focus_stack[0]. On ne le promeut en plein écran que s'il l'a
		# demandé lui-même. L'ancien invariant (« le mode focus garde
		# toujours exactement une fenêtre plein écran ») est abandonné : le
		# mode focus n'impose plus le plein écran à personne.
		if not focus_stack.is_empty():
			titlebar._apply_fullscreen_request(focus_stack[0],
				compositor.is_window_fullscreen_requested(focus_stack[0]))
	if focus_stack.is_empty():
		# Plus aucune fenêtre dans la pile : sortir du mode focus
		compositor.release_all_keys()
		_reset_focus_ui()
	elif was_active:
		# La fenêtre active s'est fermée : retomber sur la précédente
		var next_active := _active_id()
		# Elle perd sa barre en devenant active (_activate_window), mais elle
		# est maintenant la fenêtre DE PILE du nouveau focus : si elle reste
		# seule derrière la nouvelle active, elle doit garder son titre.
		# Une fenêtre fullscreen n'en a pas (non déplaçable).
		if focus_fullscreen_id != next_active:
			titlebar._ensure_title_bar(next_active)
		_activate_window(next_active)

# Rend la souris à la fenêtre focalisée après un overlay interactif (layer) qui l'avait libérée :
# capturée si le client a verrouillé le pointeur (pointer constraints), visible sinon.
func restore_pointer_after_layer() -> void:
	if focus_mode and remote_focus:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if remote.locked() else Input.MOUSE_MODE_HIDDEN
		return
	if not focus_mode or _active_id() == -1:
		return
	if _state(_active_id()).get("mouse_captured", false):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func on_pointer_lock_changed(window_id: int, locked: bool) -> void:
	# Un jeu a demandé le pointer lock (zwp_pointer_constraints_v1::lock_pointer)
	if not focus_mode or window_id != _active_id():
		return
	var st := _state(window_id)
	if locked:
		st["mouse_captured"] = true
		input._hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		st["mouse_captured"] = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func on_window_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not focus_mode or not focus_rects.has(id):
		return
	focus_rects[id].texture = texture
	# Utiliser la taille réelle de la texture (pas width/height qui
	# sont la taille du contenu). Dans le path Vulkan, le VkImage est
	# alloué plus grand que le contenu (round_up_capture_size) — le
	# UV est calculé depuis tex.get_size(), donc la conversion
	# UV → surface doit utiliser la même base.
	var st := _state(id)
	st["surface_size"] = texture.get_size()
	# Type explicite : `compositor` est duck-typé, l'inférence := échoue.
	var geo: Dictionary = compositor.get_window_geometry(id)
	st["content_offset"] = Vector2(geo["x"], geo["y"])
	st["content_size"] = Vector2(geo["width"], geo["height"])
	# Fenêtre plein écran : le shader de crop doit suivre la géométrie du
	# client (resize en fullscreen) pour que le contenu remplisse toujours
	# exactement le viewport.
	if id == focus_fullscreen_id or focus_maximized.has(id):
		var fmat := focus_rects[id].material as ShaderMaterial
		if fmat:
			fmat.set_shader_parameter("content_size", st["content_size"])
			fmat.set_shader_parameter("opaque_mode", windows.get_window_translucent(id) != 1)
	# Nouvelle fenêtre / resize : ajuster la taille de l'overlay des fenêtres
	# non plein écran à la nouvelle taille de surface.
	_refresh_rect_layout(id)

# UV de l'overlay -> coordonnées surface du client. Une fenêtre maximisée
# affiche son CONTENU étiré (crop shader) : l'UV [0,1] couvre content_size, pas
# le buffer arrondi au multiple de 64 (surface_size).
func _uv_to_surface(id: int, st: Dictionary) -> Vector2:
	var uv: Vector2 = st["mouse_uv"]
	if focus_maximized.has(id):
		var cs: Vector2 = st["content_size"]
		if cs.x > 0.0 and cs.y > 0.0:
			return uv * cs + (st["content_offset"] as Vector2)
	return uv * (st["surface_size"] as Vector2) + (st["content_offset"] as Vector2)

func _nonfullscreen_display_size(surface_size: Vector2, viewport_size: Vector2) -> Vector2:
	if surface_size.x <= 0.0 or surface_size.y <= 0.0:
		return Vector2.ZERO
	var scale := minf(
		viewport_size.x / surface_size.x,
		viewport_size.y / surface_size.y)
	scale = minf(scale, 1.0)
	return surface_size * scale

func _refresh_rect_layout(id: int) -> void:
	var rect: TextureRect = focus_rects.get(id)
	if not rect or id == focus_fullscreen_id:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	# Fenêtre maximisée : le contenu (crop shader + STRETCH_SCALE) couvre tout
	# le viewport, sans letterbox ni centrage ; seul ui_offset (déplacement)
	# s'applique.
	if focus_maximized.has(id):
		rect.size = viewport_size
		rect.position = _state(id)["ui_offset"]
		titlebar._sync_title_bar(id)
		return
	# La barre de titre occupe de la hauteur au-dessus du contenu : une grande
	# fenêtre doit tenir (barre + contenu) dans le viewport, sinon l'ensemble,
	# centré, déborde en haut de l'écran.
	var fit_size := viewport_size
	if focus_title_bars.has(id):
		fit_size.y = maxf(viewport_size.y - TitlebarModule.titlebar_h(), 1.0)
	# Taille logique à l'écran : une texture capturée à l'échelle > 1 (netteté) ne doit pas grossir la fenêtre.
	var display_size := _nonfullscreen_display_size(
		(_state(id)["surface_size"] as Vector2) / windows.window_capture_scale(id) if windows != null and windows.has_method("window_capture_scale") else _state(id)["surface_size"],
		fit_size)
	rect.size = display_size
	# Centrage fin sur le CONTENU VISIBLE (pas le buffer) : compense le
	# padding d'arrondi 64 et les offsets de géométrie (CSD). Calculé SANS
	# ui_offset : c'est le centrage automatique de référence.
	rect.position = (viewport_size - display_size) / 2.0
	var base_content := _displayed_content_rect(id)
	if base_content.size.x > 0.0 and base_content.size.y > 0.0:
		rect.position += Vector2(
			(viewport_size.x - base_content.size.x) * 0.5 - base_content.position.x,
			(viewport_size.y - base_content.size.y) * 0.5 - base_content.position.y)
	# Décalage d'une demi-hauteur de barre pour tenir compte de la barre de
	# titre au-dessus du contenu et centrer l'ENSEMBLE (barre+contenu) plutôt
	# que le seul contenu.
	# Conditionné à la présence effective d'une barre : la fenêtre ACTIVE n'en
	# a pas, et sans cette garde elle serait décalée d'une demi-barre.
	if focus_title_bars.has(id):
		rect.position.y += TitlebarModule.titlebar_h() * 0.5
	# ui_offset = décalage accumulé par le drag barre de titre ;
	# appliqué APRÈS le centrage sinon chaque rafraîchissement (texture,
	# frames du drag) recentrerait la fenêtre et annulerait le déplacement.
	rect.position += _state(id)["ui_offset"]
	# La barre de titre suit son contenu (position, taille, titre).
	titlebar._sync_title_bar(id)
	# Diagnostic centrage : marges gauche/droite calculées côté overlay ET
	# zone du contenu visible dans le buffer (padding d'arrondi 64 inclus).
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		var cst := _state(id)
		var final_content := _displayed_content_rect(id)
		print("focus-layout: id=", id,
			" vp=", viewport_size,
			" disp=", display_size,
			" pos=", rect.position,
			" mg=", final_content.position.x,
			" md=", viewport_size.x - final_content.end.x,
			" surf=", cst.get("surface_size", Vector2.ZERO),
			" coff=", cst.get("content_offset", Vector2.ZERO),
			" csize=", cst.get("content_size", Vector2.ZERO))

func on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	if not focus_mode or remote_focus:
		return
	popups._create_popup_overlay(id, parent_window_id, parent_popup_id, x, y, width, height)

func on_popup_unmapped(id: int) -> void:
	if popup_drag_id == id:
		popup_drag_id = -1
		popup_buttons_down = 0
	if focus_popup_rects.has(id):
		if is_instance_valid(focus_popup_rects[id]):
			focus_popup_rects[id].queue_free()
		focus_popup_rects.erase(id)

func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if remote_focus or not focus_popup_rects.has(id) or not is_instance_valid(focus_popup_rects[id]):
		return
	var popup_tex_rect: TextureRect = focus_popup_rects[id]
	# texture = propriété du TextureRect : sans elle le contrôle ne dessine
	# pas ; le shader échantillonne ce TEXTURE avec le recadrage.
	popup_tex_rect.texture = texture
	var mat: ShaderMaterial = popup_tex_rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("content_size", Vector2(width, height))
	popup_tex_rect.set_meta("content_size", Vector2(width, height))
	# Recalculer la taille avec le scale du parent
	if windows.popup_parent_info.has(id):
		var info = windows.popup_parent_info[id]
		var layout := popups._compute_popup_layout(info.parent_window_id, info.parent_popup_id)
		if layout.is_empty():
			return
		var popup_scale: Vector2 = layout["scale"]
		var popup_offset: Vector2 = layout["offset"]
		# width/height (signal) = taille du contenu réel, à la différence de
		# info.width/height qui vient de popup_mapped (géométrie logique).
		popup_tex_rect.size = Vector2(width, height) * popup_scale
		popup_tex_rect.position = popup_offset + Vector2(info.x, info.y) * popup_scale

func _compute_focus_displayed_info(window_id: int = -1) -> Dictionary:
	var wid := window_id if window_id != -1 else _active_id()
	if wid == -1 or not focus_rects.has(wid):
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var rect: TextureRect = focus_rects[wid]
	if focus_maximized.has(wid):
		var mcs: Vector2 = _state(wid)["content_size"]
		var mgr := rect.get_global_rect()
		if mcs.x > 0.0 and mcs.y > 0.0:
			return {"offset": mgr.position, "size": mgr.size,
				"scale": Vector2(mgr.size.x / mcs.x, mgr.size.y / mcs.y)}
	var tex := rect.texture
	if not tex:
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var tex_size := tex.get_size()
	var tex_rect := rect.get_global_rect()
	var aspect = tex_size.x / max(tex_size.y, 1.0)
	var rect_aspect = tex_rect.size.x / max(tex_rect.size.y, 1.0)
	var displayed_size: Vector2
	if aspect > rect_aspect:
		displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
	else:
		displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
	var offset := tex_rect.position + (tex_rect.size - displayed_size) / 2.0
	var scale := Vector2(displayed_size.x / max(tex_size.x, 1), displayed_size.y / max(tex_size.y, 1))
	return {"offset": offset, "size": displayed_size, "scale": scale}


# Rend la fenêtre courante de la pile la fenêtre active : met à jour le focus
# clavier 3D, l'état de la souris et les popups overlayés (seuls ceux de la
# fenêtre active sont affichés).
func _activate_window(id: int) -> void:
	var previous_active: int = windows.focused_window_id
	windows.focused_window_id = id
	# L'ancienne active redevient une fenêtre de PILE ordinaire : elle doit
	# reprendre sa barre de titre (elle l'avait perdue en devenant active).
	# Elle est exclue si elle est la fenêtre fullscreen (non déplaçable).
	if previous_active >= 0 and previous_active != id \
			and previous_active != focus_fullscreen_id:
		titlebar._ensure_title_bar(previous_active)
	
	if focus_opened_during.has(id):
		titlebar._ensure_title_bar(id)
	else:
		titlebar._remove_title_bar(id)
	# Donner le focus clavier du seat à la fenêtre : les touches forwardées
	# par forward_keyboard_key partent vers la surface qui détient le focus
	# clavier (pas vers un window_id). Sans ça, une nouvelle fenêtre active de
	# la pile recevrait la souris mais pas le clavier (l'enter clavier du
	# compositeur reste sur l'ancienne fenêtre).
	compositor.set_window_keyboard_focus(id)
	var st := _state(id)
	# Restaurer l'état souris de la fenêtre redevenue active. Pas de warp :
	# le curseur reste là où l'utilisateur l'a laissé quand la fenêtre active
	# change (la souris était déjà visible, seul l'état du pointeur du client
	# est restauré ci-dessous).
	input._hide_cursor_overlay()
	if st["mouse_captured"]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Cadence de capture prioritaire (60/s) : pas seulement pour le plein
	# écran xdg. Une fenêtre MAXIMISÉE est affichée plein écran elle aussi ;
	# sans priorité elle reste à la cadence "quads 3D" (lag). Si une fenêtre
	# fullscreen existe, elle garde la priorité posée à son entrée.
	if focus_fullscreen_id == -1:
		compositor.set_focus_capture_priority_window(id)
	# Rafraîchir les popups overlayés
	popups._refresh_popups()

# Zone écran réellement occupée par le CONTENU d'un overlay.
# Fenêtre plein écran (STRETCH_SCALE + crop shader) : le contenu couvre la
# totalité du viewport → le rect affiché est le viewport lui-même.
# Autres fenêtres (STRETCH_KEEP_ASPECT_CENTERED) : seules les barres
# letterbox autour du contenu sont « traversantes » (cliquables vers la
# fenêtre du dessous).
# Rect vide si la fenêtre n'a pas d'overlay ou pas encore de texture.
func _displayed_rect(id: int) -> Rect2:
	var rect: TextureRect = focus_rects.get(id)
	if rect == null or not is_instance_valid(rect):
		return Rect2()
	var crect := rect.get_global_rect()
	if crect.size.x <= 0.0 or crect.size.y <= 0.0:
		return Rect2()
	# La fenêtre plein écran utilise STRETCH_SCALE + crop shader : le contenu
	# remplit tout le viewport, pas de barres letterbox. Retourner le rect
	# complet évite que les bords de l'écran soient hors de la zone affichée
	# (bug : clics droite non routés car _displayed_rect calcule un rect plus
	# étroit via KEEP_ASPECT_CENTERED sur le buffer arrondi au multiple de 64).
	if id == focus_fullscreen_id or focus_maximized.has(id):
		return crect
	var tex := rect.texture
	if tex == null:
		return Rect2()
	var tex_size := tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Rect2()
	var aspect := tex_size.x / maxf(tex_size.y, 1.0)
	var rect_aspect := crect.size.x / maxf(crect.size.y, 0.001)
	var displayed: Vector2
	if aspect > rect_aspect:
		displayed = Vector2(crect.size.x, crect.size.x / aspect)
	else:
		displayed = Vector2(crect.size.y * aspect, crect.size.y)
	return Rect2(crect.position + (crect.size - displayed) / 2.0, displayed)

# Fenêtre la plus au-dessus de la pile dont le contenu affiché contient pos,
# -1 si aucune (barres letterbox / hors contenu). Itération du sommet vers
# le fond : l'occlusion visuelle des overlays détermine la fenêtre touchée.
func _window_at(pos: Vector2) -> int:
	for i in range(focus_stack.size() - 1, -1, -1):
		var id: int = focus_stack[i]
		if _displayed_rect(id).has_point(pos):
			return id
	return -1

# Positionne la barre au-dessus du contenu AFFICHÉ (pas du TextureRect : en
# KEEP_ASPECT_CENTERED les barres letterbox ne doivent pas porter la déco).
# Appelée à chaque _refresh_rect_layout : la barre suit le contenu, y compris
# pendant un déplacement (ui_offset) et un resize.
# Zone écran du CONTENU VISIBLE d'un overlay : sous-zone de _displayed_rect
# correspondant à la géométrie réelle du client (content_offset/content_size)
# dans le buffer capturé. Le buffer est arrondi au multiple de 64 (côté
# Vulkan), donc il inclut un padding transparent à droite/bas : sans ce
# recadrage, la barre de titre dépassait la fenêtre visible sur la droite.
# Retombe sur _displayed_rect si la géométrie n'est pas connue/fiable.
func _displayed_content_rect(id: int) -> Rect2:
	var disp := _displayed_rect(id)
	if disp.size.x <= 0.0 or disp.size.y <= 0.0:
		return Rect2()
	# Maximisée : l'overlay affiche déjà exactement le contenu (crop shader).
	if focus_maximized.has(id):
		return disp
	var st := _state(id)
	var surf: Vector2 = st.get("surface_size", Vector2.ZERO)
	var coff: Vector2 = st.get("content_offset", Vector2.ZERO)
	var csize: Vector2 = st.get("content_size", Vector2.ZERO)
	if surf.x <= 0.0 or surf.y <= 0.0 \
			or csize.x <= 0.0 or csize.y <= 0.0 \
			or csize.x > surf.x or csize.y > surf.y:
		return disp
	return Rect2(
		disp.position + Vector2(coff.x / surf.x, coff.y / surf.y) * disp.size,
		Vector2(csize.x / surf.x, csize.y / surf.y) * disp.size
	)

# Zone du CONTENU de la fenêtre `id` à l'écran (coordonnées du viewport, = celles des layer
# surfaces), pour les clients qui se calent sur la fenêtre (overlay de Ludodex).
# Rect vide hors mode focus ou si la fenêtre n'a pas d'overlay.
func get_displayed_content_rect(id: int) -> Rect2:
	if not focus_mode or remote_focus:
		return Rect2()
	return _displayed_content_rect(id)

# Passe une fenêtre au sommet de la pile SANS l'activer : réordonne la pile
# et réaligne les z_index des overlays (FOCUS_Z_BASE + rang dans la pile,
# cf. enter_focus).
func _raise_window(id: int) -> void:
	if id < 0 or not focus_stack.has(id):
		return
	focus_stack.erase(id)
	windows.focus_frozen.erase(id)
	focus_stack.append(id)
	for i in focus_stack.size():
		var wid: int = focus_stack[i]
		if focus_rects.has(wid) and is_instance_valid(focus_rects[wid]):
			focus_rects[wid].z_index = FOCUS_Z_BASE + i + 1
		var bar: Panel = focus_title_bars.get(wid)
		if bar != null and is_instance_valid(bar):
			bar.z_index = FOCUS_Z_BASE + i + 1

func _reset_focus_ui() -> void:
	# Une sélection de zone en cours est annulée : la sortie du mode focus
	# doit remettre l'écran (et le pointer-lock) dans son état normal.
	if zone_select_active:
		zone_select._cancel_zone_selection()
	# Sortie du mode focus : la scène 3D redevient visible, retirer
	# l'occludeur plein écran.
	if _world_occluder != null and is_instance_valid(_world_occluder):
		occlusion._hide_world_occluder()
	occlusion._reset_occluder_alpha_state()
	popups._clear_popup_overlays()
	popup_drag_id = -1
	popup_buttons_down = 0
	window_move_id = -1
	window_press_id = -1
	window_press_buttons = 0
	for bar_id in focus_title_bars.keys():
		titlebar._remove_title_bar(bar_id)
	_left_down = false
	_left_event_pressed = false
	_left_event_frame = -1
	for id in focus_rects:
		if is_instance_valid(focus_rects[id]):
			focus_rects[id].queue_free()
	focus_rects.clear()
	focus_states.clear()
	focus_maximized.clear()
	for fid in focus_stack:
		windows.focus_frozen.erase(fid)
	focus_stack.clear()
	focus_fullscreen_id = -1
	focus_mode = false
	# Plus aucune fenêtre plein écran en focus : révoquer la priorité de
	# capture (la fenêtre repasse à la cadence "quads 3D").
	compositor.set_focus_capture_priority_window(-1)
	remote_focus = false
	remote_focus_peer = -1
	remote_focus_wid = -1
	remote_focus_rect = null
	remote_cursor_state.clear()
	remote._hide_remote_cursor()
	# Restaurer le curseur système (l'overlay custom de la fenêtre focalisée
	# ne doit pas survivre à la sortie du mode focus).
	input._hide_cursor_overlay()
	Input.set_custom_mouse_cursor(null)
	_hw_cursor_key = 0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.focus_mode_active = false

# État Shift côté client (ce que le compositeur a forwardé). L'IM (XIM /
# XFilterEvent) avale le relâchement du Shift tenu pendant une touche morte :
# Godot ne l'émet jamais → on doit corriger (heal) l'état du client dès qu'un
# événement non-shifté arrive. (Les deux Shift physiques sont reportés comme
# KEY_SHIFT, seule la location diffère ; le client ne voit que le modifieur.)
var _client_shift := false

const CLICK_ACTIONS := ["left_click", "right_click", "middle_click"]
# action -> true si l'appui en cours vient d'un bouton manette reçu alors que
# les binds manette étaient désactivés : l'appui ET son relâchement sont ignorés.
var _joy_click_blocked: Dictionary = {}
# action -> frame du relâchement manette d'un appui bloqué.
var _joy_click_release_frame: Dictionary = {}

func in_game() -> bool:
	if remote_focus:
		return remote.in_game()
	var st := _state(_active_id())
	if st["is_game"]:
		return true
	return false

## Toggle force_game (action remapable) : inverse is_game sur la fenêtre focus
## et bloque l'auto-set pointer-lock (is_game_overridden) pour que le reset
## tienne tant que la session de focus reste active. Retourne le nouvel état
## de is_game (true si la fenêtre est traitée comme un jeu).
## Marque force_game d'une fenêtre : -1 = jamais forcée, 0 = forcée « pas un jeu », 1 = forcée « jeu ».
func get_force_game(id: int) -> int:
	var st: Dictionary = focus_states.get(id, {})
	if not bool(st.get("is_game_overridden", false)):
		return -1
	return 1 if bool(st.get("is_game", false)) else 0

## Repose une marque force_game (fenêtre retrouvée d'une session précédente).
func set_force_game(id: int, is_game: bool) -> void:
	var st := _state(id)
	st["is_game_overridden"] = true
	st["is_game"] = is_game

func toggle_force_game() -> bool:
	if remote_focus:
		return remote.toggle_game()
	var id := _active_id()
	if id == -1:
		return false
	var st := _state(id)
	st["is_game_overridden"] = true
	st["is_game"] = not st["is_game"]
	return st["is_game"]

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = event.position
	if event is InputEventJoypadButton:
		var jpb := event as InputEventJoypadButton
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			if jpb.button_index == JOY_BUTTON_LEFT_SHOULDER or jpb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
				print("scroll_input: btn=%d pressed=%s in_game=%s" % [
					jpb.button_index, jpb.pressed, in_game()])
		# Actions de clic déclenchées par un bouton manette (ex. Y = right_click) :
		# Input.is_action_* ne distingue pas le périphérique, on mémorise donc
		# ici l'origine manette pour pouvoir les ignorer (voir
		# _click_action_just_pressed / _click_action_just_released).
		for a in CLICK_ACTIONS:
			if jpb.is_action(a):
				if jpb.pressed:
					_joy_click_blocked[a] = input._gamepad_binds_disabled()
				elif _joy_click_blocked.get(a, false):
					_joy_click_blocked[a] = false
					_joy_click_release_frame[a] = Engine.get_process_frames()
		# Fenêtre active = jeu ET souris capturée : binds manette désactivés (pas
		# de tracking du scroll, l'événement est consommé).
		if input._gamepad_binds_disabled():
			_scroll_up_held = false
			_scroll_down_held = false
			if jpb.pressed:
				get_viewport().set_input_as_handled()
			return
		if jpb.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_scroll_up_held = jpb.pressed
		elif jpb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_scroll_down_held = jpb.pressed

# Fenêtre de FOND de pile : celle qui a ouvert le mode focus (plein écran xdg
# ou maximisée). Elle ne passe jamais au-dessus des fenêtres ouvertes PENDANT
# le focus : un clic dedans est forwardé normalement, mais ne la remonte pas
# et ne lui vole pas le clavier.
func _is_stack_base(id: int) -> bool:
	return id == focus_fullscreen_id \
		or (focus_maximized.has(id) and not focus_opened_during.has(id))

# ── Relais vers les modules (API publique inchangée) ─────────────────

func enter_remote_focus(peer_id: int, wid: int, texture: Texture2D) -> void:
	remote.enter_remote_focus(peer_id, wid, texture)

func handle_focus_input(delta: float) -> void:
	input.handle_focus_input(delta)

## Mode annotation actif (posé par annotations_view.gd) : pointeur du jeu au lieu de celui de la fenêtre.
var annotating := false:
	set(on):
		if on == annotating:
			return
		annotating = on
		if not on and remote_cursor_overlay != null:
			remote._hide_remote_cursor()
			remote._update_remote_cursor()     # focus distant : curseur du propriétaire (ou d'invité) de retour

func handle_annotation_pointer(delta: float) -> void:
	input.handle_annotation_pointer(delta)

func handle_input_event(event: InputEvent) -> bool:
	return input.handle_input_event(event)

func handle_peer_removed(peer_id: int) -> void:
	remote.handle_peer_removed(peer_id)

func handle_remote_window_removed(peer_id: int, wid: int) -> void:
	remote.handle_remote_window_removed(peer_id, wid)

func on_remote_texture_updated(peer_id: int, wid: int, texture: Texture2D) -> void:
	remote.on_remote_texture_updated(peer_id, wid, texture)

func _prepare_key_forward(key_event: InputEventKey, code: int) -> void:
	input._prepare_key_forward(key_event, code)

func set_remote_cursor_state(peer_id: int, wid: int, state) -> void:
	remote.set_remote_cursor_state(peer_id, wid, state)

func _try_reconstruct_composed_key(event: InputEventKey) -> bool:
	return input._try_reconstruct_composed_key(event)

static func zone_rect_to_int(rect: Rect2, img_size: Vector2i) -> Rect2i:
	return ZoneSelectModule.zone_rect_to_int(rect, img_size)

static func titlebar_h() -> float:
	return TitlebarModule.titlebar_h()

static func titlebar_style(atlas: Texture2D) -> StyleBox:
	return TitlebarModule.titlebar_style(atlas)

static func titlebar_fg() -> Color:
	return TitlebarModule.titlebar_fg()
