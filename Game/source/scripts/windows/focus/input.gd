extends Node
## Routage de l'input en mode focus : clavier (Maj, touches composées), souris, boutons, déplacement de
## fenêtre, curseur logiciel, raccourcis du compositeur.
##
## Module de FocusMode (nœud enfant « Input »), créé par la façade : l'état partagé vit dans la façade
## (`fm`), l'état propre au module vit ici.

const FocusMode := preload("res://scripts/windows/focus_mode.gd")
var fm: FocusMode = null

var window_move_last_pos := Vector2.ZERO

# Pointeur wayland : dernière cible (fenêtre OU popup) et dernière position
# envoyées au client. Un vrai desktop ne délivre wl_pointer.motion qu'en cas
# de MOUVEMENT ; handle_focus_input tournant chaque frame, sans trace on
# floodait le client de motions identiques à ~90/s. Des clients comme Steam
# re-testent leur hover de menu à CHAQUE motion reçue : ce flood redondant
# (pointeur immobile sur le bouton) leur fermait les popups en quelques
# frames. On skip donc toute motion dont la cible ET la position sont
# inchangées (entrées incluses : wlroots gère l'enter). Valeurs par défaut
# impossibles (-1, très loin) pour forcer l'envoi au démarrage.
var _last_sent_window_id := -1
var _last_sent_window_surf := Vector2(-1e9, -1e9)
var _last_sent_popup_id := -1
var _last_sent_popup_surf := Vector2(-1e9, -1e9)

# Sondage direct de l'état brut du bouton gauche (Input.is_mouse_button_
# pressed) avec détection de front : ni le cache d'actions ni la propagation
# d'événements ne peuvent le filtrer. C'est la source primaire pour le
# déplacement ; les actions et événements ne sont que des filets.
var _left_raw_prev := false
var _left_press_edge := false
var _left_release_edge := false
var cursor_overlay_tex: ImageTexture
var cursor_overlay_serial := -1
# Dédup par contenu : beaucoup d'applis rappellent set_cursor avec la même
# image (nouveau serial à chaque fois). Chaque set_custom_mouse_cursor alloue un
# shm côté Wayland ; on ne le rappelle donc que si l'image ou le hotspot change.
var _cursor_img_hash := 0
var _stick_scroll_cooldown := 0.0

# Renvoie true si la motion (cible, position) est identique à la dernière
# envoyée (dans l'epsilon) ET met à jour la trace. À appeler juste avant le
# forward motion pour éviter le flood des frames stationnaires (un vrai
# desktop ne délivre wl_pointer.motion qu'en cas de MOUVEMENT).
func _motion_is_duplicate(window_id: int, surf: Vector2, epsilon := 0.001) -> bool:
	var dup := window_id == _last_sent_window_id and surf.distance_to(_last_sent_window_surf) < epsilon
	_last_sent_window_id = window_id
	_last_sent_window_surf = surf
	return dup

# Idem pour les popups ; invalide aussi la trace fenêtre (changer de cible
# doit re-sync l'enter du client).
func _popup_motion_is_duplicate(popup_id: int, surf: Vector2, epsilon := 0.001) -> bool:
	var dup := popup_id == _last_sent_popup_id and surf.distance_to(_last_sent_popup_surf) < epsilon
	_last_sent_popup_id = popup_id
	_last_sent_popup_surf = surf
	_last_sent_window_id = -1
	return dup

# Appui/relâchement du bouton gauche pour la frame courante : front de l'état
# brut (source primaire, insensible aux modificateurs), complété par l'action
# Godot et les événements bruts au cas où le sondage passerait à côté.
func _poll_left_button() -> void:
	# Bind manette (X = clic gauche) ignoré quand la fenêtre active est un jeu
	# ET que la souris est capturée : la manette appartient alors au jeu.
	var now := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		or (not _gamepad_binds_disabled() and Input.is_joy_button_pressed(0, JOY_BUTTON_X))
	_left_press_edge = now and not _left_raw_prev
	_left_release_edge = (not now) and _left_raw_prev
	if _left_press_edge or _left_release_edge:
		fm._left_down = now
		fm._left_event_pressed = now
		fm._left_event_frame = Engine.get_process_frames()
	_left_raw_prev = now

func _left_press_this_frame() -> bool:
	return _left_press_edge \
		or _click_action_just_pressed("left_click") \
		or (fm._left_event_pressed and fm._left_event_frame == Engine.get_process_frames())

func _left_release_this_frame() -> bool:
	if _left_release_edge or _click_action_just_released("left_click"):
		return true
	return (not fm._left_down and fm._left_event_frame == Engine.get_process_frames())

# Démarre le déplacement : la fenêtre remonte au sommet et
# devient active ; ses popups (ancrés au rect parent à la création) sont
# masqués jusqu'à la fin du déplacement.
func _start_window_move(id: int, mouse_pos: Vector2) -> void:
	fm.window_move_id = id
	window_move_last_pos = mouse_pos
	fm._raise_window(id)
	fm._activate_window(id)
	fm.popups._clear_popup_overlays()
	_hide_cursor_overlay()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("focus-move: start id=", id, " pos=", mouse_pos)

# Suit le curseur pendant un déplacement : delta → ui_offset de la fenêtre
# (persistant, réappliqué par _refresh_rect_layout). Fin au relâchement du
# bouton gauche.
func _update_window_move(mouse_pos: Vector2) -> void:
	if fm.window_move_id == -1 or not fm.focus_rects.has(fm.window_move_id):
		fm.window_move_id = -1
		return
	var st := fm._state(fm.window_move_id)
	st["ui_offset"] += mouse_pos - window_move_last_pos
	window_move_last_pos = mouse_pos
	fm._refresh_rect_layout(fm.window_move_id)
	# Fin au relâchement du bouton gauche (flux d'événements + action Godot).
	if _left_release_this_frame() or not fm._left_down:
		fm.window_move_id = -1
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("focus-move: end")
		fm.popups._refresh_popups()

# Forward les boutons souris vers une fenêtre (chemin commun aux modes
# souris visible et capturée).
func _forward_window_buttons(id: int, delta: float) -> void:
	# Scroll (gamepad buttons). Les boutons gamepad n'ont pas d'auto-repeat ;
	# le polling maintient le scroll continu quand le bouton est maintenu
	# (cooldown 80ms). Utilise l'état tracké manuellement (_scroll_up/down_held)
	# car set_input_as_handled() dans _input empêche Input.is_action_pressed()
	# de fonctionner correctement pour les boutons gamepad.
	# Fenêtre active = jeu ET souris capturée : binds manette désactivés (scroll compris).
	var game := _gamepad_binds_disabled()
	if game:
		fm._scroll_up_held = false
		fm._scroll_down_held = false
	var scroll_active := (not game) and (fm._scroll_up_held or fm._scroll_down_held \
		or Input.is_action_pressed("scroll_up") or Input.is_action_pressed("scroll_down"))
	if scroll_active:
		_stick_scroll_cooldown -= delta
		if _stick_scroll_cooldown <= 0.0:
			var amount := -120.0 if fm._scroll_up_held or Input.is_action_pressed("scroll_up") else 120.0
			fm.compositor.forward_pointer_axis(id, 0, amount)
			_stick_scroll_cooldown = 0.08
	else:
		_stick_scroll_cooldown = 0.0

	if _left_press_this_frame():
		fm.compositor.forward_pointer_button(id, 0x110, true)
	if _left_release_this_frame():
		fm.compositor.forward_pointer_button(id, 0x110, false)

	if _click_action_just_pressed("right_click"):
		fm.compositor.forward_pointer_button(id, 0x111, true)
	if _click_action_just_released("right_click"):
		fm.compositor.forward_pointer_button(id, 0x111, false)

	# Clic molette (BTN_MIDDLE) : forwardé comme les clics gauche/droit.
	if _click_action_just_pressed("middle_click"):
		fm.compositor.forward_pointer_button(id, 0x112, true)
	if _click_action_just_released("middle_click"):
		fm.compositor.forward_pointer_button(id, 0x112, false)

	if fm.in_game():
		return

# Dessine en overlay 2D le curseur posé par l'application en focus
# (wl_pointer.set_cursor). Le curseur système est masqué (MOUSE_MODE_HIDDEN)
# pour éviter un double curseur ; sans image custom capturée on retombe sur
# le curseur système.
func _update_cursor_overlay(window_id: int, mouse_pos: Vector2, display_scale: Vector2) -> void:
	var cursor_info: Dictionary = fm.compositor.get_window_cursor(window_id)
	if cursor_info.is_empty():
		_show_system_cursor()
		return
	# L'application a masqué son curseur OS (set_cursor NULL) et ne fournit
	# aucune image custom (ex. jeux Unity type Papers Please qui dessinent
	# leur propre curseur) : on masque l'overlay, sinon on afficherait la
	# flèche système PAR-DESSUS le curseur du jeu (double curseur).
	# L'image retenue a PRIORITÉ sur hidden : les jeux FPS (SDL) gardent leur
	# curseur capturé pendant le pointer lock sans renvoyer de surface ensuite
	# (rétention) — on continue d'afficher l'overlay dans ce cas.
	if cursor_info.get("hidden", false) and not cursor_info.has("image"):
		_hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		return
	var serial: int = cursor_info["serial"]
	if serial != cursor_overlay_serial:
		var img: Image = cursor_info["image"]
		if not img or img.is_empty():
			_show_system_cursor()
			return
		var h: int = hash([img.get_width(), img.get_height(), hash(img.get_data())])
		if cursor_overlay_tex == null or h != _cursor_img_hash:
			cursor_overlay_tex = ImageTexture.create_from_image(img)
			fm.cursor_overlay.texture = cursor_overlay_tex
			_cursor_img_hash = h
		cursor_overlay_serial = serial
	var hotspot := Vector2(cursor_info["hotspot_x"], cursor_info["hotspot_y"])
	var img_size := cursor_overlay_tex.get_size()
	if img_size.x <= 0.0 or img_size.y <= 0.0:
		_show_system_cursor()
		return
	# DisplayServer "kms" : pas de curseur matériel (cursor_set_custom_image est
	# un no-op) ; on passe toujours par l'overlay 2D.
	if DisplayServer.get_name() != "kms" \
			and absf(display_scale.x - 1.0) < 0.05 and absf(display_scale.y - 1.0) < 0.05 \
			and img_size.x <= 256.0 and img_size.y <= 256.0:
		var hw_key: int = hash([_cursor_img_hash, hotspot])
		if fm._hw_cursor_key != hw_key:
			Input.set_custom_mouse_cursor(cursor_overlay_tex, Input.CURSOR_ARROW, hotspot)
			fm._hw_cursor_key = hw_key
		fm.cursor_overlay.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	fm.cursor_overlay.size = img_size * display_scale
	fm.cursor_overlay.position = mouse_pos - hotspot * display_scale
	fm.cursor_overlay.visible = true

func _show_system_cursor() -> void:
	if fm._hw_cursor_key != 0:
		Input.set_custom_mouse_cursor(null)
		fm._hw_cursor_key = 0
	if fm.cursor_overlay and fm.cursor_overlay.visible:
		fm.cursor_overlay.visible = false
		cursor_overlay_serial = -1
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _hide_cursor_overlay() -> void:
	if fm.cursor_overlay:
		fm.cursor_overlay.visible = false
	cursor_overlay_serial = -1

# Routage souris/clavier du mode focus, appelé chaque frame par
# wayland_room.gd tant que le mode est actif. L'input pointeur va à la
# fenêtre SURVOLÉE de la pile — pas forcément la fenêtre active — tandis que
# le clavier reste sur l'active (set_window_keyboard_focus). Un appui bouton
# sur une fenêtre d'arrière-plan la remonte au sommet de la pile et
# l'active.
func handle_focus_input(delta: float) -> void:
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		var active_id_tmp := fm._active_id()
		var captured_tmp := false
		if active_id_tmp != -1 and fm.focus_rects.has(active_id_tmp):
			captured_tmp = fm._state(active_id_tmp)["mouse_captured"]
		print("handle_focus_input: delta=%.3f active=%d captured=%s scroll_up=%s scroll_down=%s" % [
			delta, active_id_tmp, captured_tmp, fm._scroll_up_held, fm._scroll_down_held])
	# Sélection de zone (PrtSc) : tant que l'outil est actif il pilote le
	# pointeur (drag = marquise), avant le chemin focus distant / fenêtre.
	if fm.zone_select_active:
		fm.zone_select._handle_zone_selection()
		return
	if fm.remote_focus:
		return
	var active_id := fm._active_id()
	if active_id == -1 or not fm.focus_rects.has(active_id):
		return
	# Le clavier virtuel est une surbrillance modale : aucun input focus-mode
	# (clics, pointer motion, window moves) ne doit être transféré au jeu tant
	# qu'il est actif. La position souris est toujours trackée via _input().
	if fm.virtual_keyboard.visible:
		return
	var st := fm._state(active_id)
	var surf_x: float
	var surf_y: float

	# Front du bouton gauche depuis l'état brut (une seule fois par frame,
	# avant les deux chemins : visible ET capturé utilisent ces bords).
	_poll_left_button()

	# Souris capturée (lock): forward UNIQUEMENT le relatif (via _input).
	# Ne PAS envoyer de wl_pointer.motion (absolu) ici : un client locké ne doit
	# recevoir que du relatif (contrat zwp_pointer_constraints_v1). L'absolu
	# par frame accumule mouse_uv, qui sature sur le clamp [0,1] : dès qu'elle
	# est saturée, chaque frame envoie un absolu avec un delta négatif (xrel =
	# P_max - last_x) que SDL3 (OpenMW) traduit en mouvement caméra → la caméra
	# "snap-back" constamment vers sa position d'origine. GLFW (Minecraft)
	# ignore l'absolu quand le pointeur est locké → insensible à ce bug.
	# Le focus pointeur est maintenu par le seat (enter persistant) et le
	# relatif est livré immédiatement par wlr_relative_pointer_manager_v1,
	# suivi d'un frame (cf. forward_pointer_relative_motion).
	if st["mouse_captured"]:
		var sp := fm._uv_to_surface(active_id, st)
		surf_x = sp.x
		surf_y = sp.y
		fm.compositor.set_window_pointer(active_id, surf_x, surf_y, true)
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("forward_buttons: id=%d scroll_up=%s scroll_down=%s" % [
				active_id, fm._scroll_up_held, fm._scroll_down_held])
		_forward_window_buttons(active_id, delta)
		return
	
	# Stick gauche = curseur : désactivé en jeu ET souris capturée.
	var v := Vector2.ZERO
	if not _gamepad_binds_disabled():
		v = Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)).limit_length(1.0)
	if v != Vector2.ZERO and not fm.virtual_keyboard.visible:
		fm.mouse_pos += v * v.length() * fm.SPEED * delta
		var vs := get_viewport().get_visible_rect().size
		fm.mouse_pos = fm.mouse_pos.clamp(Vector2.ONE, vs - Vector2.ONE)
		get_viewport().warp_mouse(fm.mouse_pos)
	
	# Déplacement de fenêtre en cours : le compositeur absorbe TOUS les
	# événements pointeur jusqu'au relâchement du bouton (l'overlay suit le
	# curseur), aucun motion/bouton/scroll ne part vers les clients.
	if fm.window_move_id != -1:
		_update_window_move(fm.mouse_pos)
		return

	var press_left := _left_press_this_frame()
	var release_left := _left_release_this_frame()
	var press_right := _click_action_just_pressed("right_click")
	var release_right := _click_action_just_released("right_click")
	var press_middle := _click_action_just_pressed("middle_click")
	var release_middle := _click_action_just_released("middle_click")

	# MAIS dès qu'un drag est ACTIF au niveau wlroots (wl_data_device), les
	# grabs implicites n'existent plus : wlroots route tout par la surface
	# sous le curseur (wl_data_device.enter) pour mettre à jour la cible de
	# drop. Figée sur une fenêtre/popup, la cible ne changerait jamais.
	if fm.compositor.is_drag_active():
		fm.popup_drag_id = -1
		fm.popup_buttons_down = 0
		fm.window_press_id = -1
		fm.window_press_buttons = 0

	# Résolution de la cible pointeur, par priorité décroissante : grab
	# implicite fenêtre (appui en cours, cf. window_press_id), grab implicite
	# popup (drag-and-drop popup, cf. popup_drag_id), popup de la fenêtre
	# active sous le curseur (les popups sont dessinés au-dessus de tous les
	# overlays), puis fenêtre survolée — la plus haute dont le CONTENU affiché
	# contient le curseur, qui peut donc être une fenêtre d'arrière-plan ;
	# fallback = fenêtre active (barres letterbox / hors contenu).
	var popup_target: Dictionary = {}
	var target_window := active_id
	if fm.window_press_id != -1:
		target_window = fm.window_press_id
	elif fm.popup_drag_id != -1 and fm.popup_buttons_down > 0 \
			and fm.focus_popup_rects.has(fm.popup_drag_id):
		popup_target = {"id": fm.popup_drag_id, "rect": fm.focus_popup_rects[fm.popup_drag_id]}
	else:
		popup_target = fm.popups._popup_at(fm.mouse_pos)
		if popup_target.is_empty():
			var hover_id := fm._window_at(fm.mouse_pos)
			if hover_id != -1:
				target_window = hover_id

	# Appui gauche sur une BARRE DE TITRE : déplacer la fenêtre SANS
	# modificateur (décoration 2D façon windows_3d.gd). Le clic est absorbé,
	# rien ne part vers les clients ; la fenêtre est remontée et activée par
	# _start_window_move. Les popups restent prioritaires : une zone de barre
	# recouverte par un menu doit capter le clic pour le menu, pas lancer un
	# déplacement.
	if press_left and popup_target.is_empty():
		var tb_id := fm.titlebar._titlebar_at(fm.mouse_pos)
		if tb_id != -1 and tb_id != fm.focus_fullscreen_id:
			_start_window_move(tb_id, fm.mouse_pos)
			return

	# Cible popup (menus, dropdowns...) : router mouvement + clics vers la
	# SURFACE du popup (forward_*_popup), pas vers la fenêtre. En mode focus
	# seuls les popups de la fenêtre active sont overlayés ; sans ce routage,
	# tout l'input partait vers la fenêtre aux coordonnées du popup et le menu
	# ne recevait ni hover ni clic (inutilisable dans GIMP par exemple, alors
	# que ça marche en 3D). Pendant un drag-and-drop (bouton enfoncé sur un
	# popup), on continue de router vers LE popup qui a reçu l'appui même hors
	# de ses bords : sinon le relâchement partirait vers la fenêtre et le drag
	# serait abandonné par l'application.
	if not popup_target.is_empty():
		fm.popups._forward_to_popup(popup_target, fm.mouse_pos)
		fm.compositor.set_window_pointer(active_id, 0, 0, false)
		# Le curseur custom doit continuer à SUIVRE le pointeur au-dessus d'un
		# popup : cette branche retourne tôt, et sans mise à jour explicite
		# l'overlay restait figé à sa dernière position (curseur « gelé »
		# visuellement dès l'entrée dans un menu). L'image reste celle de la
		# fenêtre propriétaire (le compositeur n'expose pas de curseur par
		# popup) ; l'échelle est celle du POPUP pour que le hotspot tombe juste
		# même si son facteur d'affichage diffère de celui de la fenêtre.
		var prect: TextureRect = popup_target["rect"]
		var pcontent: Vector2 = prect.get_meta("content_size", prect.size)
		var pscale := Vector2.ONE
		if pcontent.x > 0.0 and pcontent.y > 0.0:
			pscale = prect.get_global_rect().size / pcontent
		_update_cursor_overlay(active_id, fm.mouse_pos, pscale)
		return

	# Comptage du grab implicite fenêtre : le premier appui fige la cible et,
	# si c'est une fenêtre d'arrière-plan, la remonte au sommet de la pile et
	# l'active (clavier + popups) AVANT de lui forwarder l'appui ; côté
	# compositeur, forward_pointer_button active aussi le toplevel.
	# EXCEPTION fenêtre plein écran : cliquer dedans NE doit PAS la faire
	# passer devant les autres (elle reste le fond de pile) ni lui voler le
	# clavier ; l'appui reste forwardé normalement vers elle.
	if press_left or press_right or press_middle:
		if fm.window_press_id == -1:
			fm.window_press_id = target_window
			fm.window_press_buttons = 1
			if target_window != active_id and not fm._is_stack_base(target_window):
				fm._raise_window(target_window)
				fm._activate_window(target_window)
		else:
			fm.window_press_buttons += 1
	elif fm.window_press_id != -1 and (release_left or release_right or release_middle):
		fm.window_press_buttons -= 1
		if fm.window_press_buttons <= 0:
			fm.window_press_id = -1
			fm.window_press_buttons = 0

	# Position souris → UV du contenu de la fenêtre ciblée : mapping via la
	# zone réellement affichée par son TextureRect (fullscreen = plein
	# viewport, autres = KEEP_ASPECT_CENTERED), cohérente avec le rendu et
	# avec la conversion UV → surface.
	var tst := fm._state(target_window)
	var disp := fm._displayed_rect(target_window)
	if disp.size.x > 0.0 and disp.size.y > 0.0:
		tst["mouse_uv"] = Vector2(
			clampf((fm.mouse_pos.x - disp.position.x) / disp.size.x, 0.0, 1.0),
			clampf((fm.mouse_pos.y - disp.position.y) / disp.size.y, 0.0, 1.0)
		)
	else:
		tst["mouse_uv"] = Vector2(0.5, 0.5)

	# Adopter le curseur custom posé par l'application ciblée
	# (wl_pointer.set_cursor, remonté via xwayland-satellite pour les
	# fenêtres X11) : dessiné en overlay 2D sur le pointeur, sinon flèche
	# système par défaut. Uniquement dans le chemin souris visible : en
	# souris capturée (FPS) l'overlay est masqué par _hide_cursor_overlay.
	var display_scale := Vector2.ONE
	if disp.size.x > 0.0 and tst["surface_size"].x > 0.0:
		display_scale = disp.size / tst["surface_size"]
	_update_cursor_overlay(target_window, fm.mouse_pos, display_scale)

	var tsp := fm._uv_to_surface(target_window, tst)
	surf_x = tsp.x
	surf_y = tsp.y
	# Le motion redundant avant chaque frame d'axis envoie wl_pointer.motion
	# + frame INUTILEMENT au client (la souris est stationnaire). Le client
	# reçoit alors 2 frames par tick de scroll au lieu d'1, ce qui perturbe
	# le traitement du scroll côté client (Steam/SDL). On skip le motion
	# quand le scroll est actif — le focus pointeur est déjà établi.
	var scroll_active := fm._scroll_up_held or fm._scroll_down_held
	if not scroll_active:
		if not _motion_is_duplicate(target_window, Vector2(surf_x, surf_y)):
			fm.compositor.forward_pointer_motion(target_window, surf_x, surf_y)
	fm.compositor.set_window_pointer(target_window, surf_x, surf_y, true)
	_forward_window_buttons(target_window, delta)

# Touches mortes AZERTY (^ et ¨) : Godot compose lui-même la séquence dans sa
# couche X11 et avale l'appui de la touche morte PUIS le relâchement de la
# lettre — seul l'appui "composé" arrive (ex. ê, phys=KEY_E). Le client ne
# reçoit donc ni le dead key (→ pas d'accent) ni le relâchement (→ lettre
# "coincée", auto-repeat en boucle). On reconstruit la séquence complète côté
# client : ^ down (evdev 26), lettre down, lettre up, ^ up. Le client (keymap
# fr) compose alors l'accent et son état clavier reste sain.
# Le dead key ^ (evdev 26) est dead_circumflex sans Shift, dead_diaeresis avec
# Shift : le résultat composé dépend du Shift tenu AU moment de l'appui de ^.
# Le flag shift_pressed de l'événement composé reflète, lui, l'état de la
# touche de base (e) : il peut être false pour un ë (Shift relâché avant e).
# On pilote donc l'état Shift du client en 3 phases : (1) Shift = celui du
# dead key, (2) Shift = celui de la lettre, (3) état réel (celui de la lettre)
# maintenu à la fin — ce qui restaure aussi le relâchement avalé par l'IM.
const COMPOSED_CIRCUMFLEX := {
	0xE2: true, 0xE4: true, 0xC2: true, 0xC4: true, # â ä Â Ä
	0xEA: true, 0xEB: true, 0xCA: true, 0xCB: true, # ê ë Ê Ë
	0xEE: true, 0xEF: true, 0xCE: true, 0xCF: true, # î ï Î Ï
	0xF4: true, 0xF6: true, 0xD4: true, 0xD6: true, # ô ö Ô Ö
	0xFB: true, 0xFC: true, 0xDB: true, 0xDC: true, # û ü Û Ü
	0xFF: true, 0x9F: true,                         # ÿ Ÿ
}

# Compositions qui proviennent de dead_diaeresis (¨) : nécessitent Shift sur la
# touche morte ^. Les autres proviennent de dead_circumflex (^, sans Shift).
const COMPOSED_DIAERESIS := {
	0xE4: true, 0xC4: true, # ä Ä
	0xEB: true, 0xCB: true, # ë Ë
	0xEF: true, 0xCF: true, # ï Ï
	0xF6: true, 0xD6: true, # ö Ö
	0xFC: true, 0xDC: true, # ü Ü
	0xFF: true, 0x9F: true, # ÿ Ÿ
}

# Double-appui de la touche morte (^^ -> ^, ¨¨ -> ¨) : X11 compose l'accent
# seul. Il faut forwarder la touche morte DEUX fois pour que l'IM du client
# (qui compose déjà les lettres accentuées) produise le caractère littéral —
# un seul forward laisserait le dead key en attente côté client et l'INJURE à
# la lettre suivante. Valeur : true si le double-appui nécessite Shift
# (dead_diaeresis pour ¨), false sinon (dead_circumflex pour ^).
const COMPOSED_DEADKEY := {
	0x5E: false, # ^ (asciicircum)
	0xA8: true,  # ¨ (diaeresis)
}

func _is_shift_key(code: int) -> bool:
	return code == KEY_SHIFT

# Aligne l'état Shift du client sur p_down (envoie DOWN/UP seulement si l'état
# diffère, pour ne pas désynchroniser xkbcommon côté client).
func _set_client_shift(down: bool) -> void:
	if fm._client_shift == down:
		return
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("key client_shift -> down=", down)
	fm.compositor.forward_keyboard_key(KEY_SHIFT, 0, down)
	fm._client_shift = down

# À appeler avant chaque forward_keyboard_key : si le client croit encore que
# Shift est enfoncé alors que l'événement courant n'est pas shifté, c'est que
# le relâchement a été avalé par l'IM lors d'une touche morte → le rétablir
# (sinon Shift reste "coincé" côté client, majuscules/raccourcis cassés). Deux
# cas de heal :
#   - un événement NON shifté arrive (lettre, Super…) → Shift coincé relâché ;
#   - un NOUVEL appui de Shift arrive alors que le client croit déjà Shift
#     enfoncé → le Shift précédent est coincé, il faut le relâcher AVANT de
#     forwarder le nouvel appui (sinon les deux s'empilent et Shift reste
#     bloqué pour les séquences ¨ suivantes).
# Le relâchement normal de Shift (l'événement lui-même) n'est pas healé : il
# est forwardé et met à jour l'état. L'état est ensuite répercuté sur ce
# forward.
func _prepare_key_forward(key_event: InputEventKey, code: int) -> void:
	if fm._client_shift and code == KEY_SHIFT and key_event.pressed:
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key heal shift-up (re-press Shift)")
		fm.compositor.forward_keyboard_key(KEY_SHIFT, 0, false)
		fm._client_shift = false
	if fm._client_shift and not key_event.shift_pressed and code != KEY_SHIFT:
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key heal shift-up (release swallowed by IM)")
		fm.compositor.forward_keyboard_key(KEY_SHIFT, 0, false)
		fm._client_shift = false
	# Cas miroir : l'événement est shifté mais le client n'a pas Shift enfoncé.
	# Après une touche morte, l'appui de Shift suivant est avalé par l'IM (le
	# relâchement l'a déjà été via les heals ci-dessus) → Shift semble "bloqué"
	# côté client pour la lettre suivante. On re-presse Shift AVANT le forward.
	if not fm._client_shift and key_event.shift_pressed and code != KEY_SHIFT:
		_set_client_shift(true)
	if code == KEY_SHIFT:
		fm._client_shift = key_event.pressed

# Reconstruit la séquence touche morte + lettre pour un événement composé par
# Godot (touche morte avalée). Retourne true si l'événement a été géré.
func _try_reconstruct_composed_key(event: InputEventKey) -> bool:
	if not event.pressed:
		return false
	# Double-tap de la touche morte : l'accent seul a été composé (^^ -> ^,
	# ¨¨ -> ¨). On rejoue la touche morte deux fois pour que l'IM du client
	# compose le caractère littéral (aucun keycode ne produit ^/¨ directement
	# sur la keymap fr : 26 est toujours un dead key).
	if COMPOSED_DEADKEY.has(event.unicode):
		var needs_shift: bool = COMPOSED_DEADKEY[event.unicode]
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key deadkey: unicode=", event.unicode, " needs_shift=", needs_shift,
				" shift_pressed=", event.shift_pressed)
		_set_client_shift(needs_shift)
		fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
		fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
		fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
		fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
		_set_client_shift(event.shift_pressed)
		return true
	if not COMPOSED_CIRCUMFLEX.has(event.unicode):
		return false
	var phys := event.physical_keycode
	if phys == 0:
		return false
	var needs_shift := COMPOSED_DIAERESIS.has(event.unicode)
	var letter_shift := event.shift_pressed
	if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
		print("key reconstruct: unicode=", event.unicode, " phys=", phys,
			" needs_shift=", needs_shift, " letter_shift=", letter_shift)
	# Phase 1 : Shift du dead key (determine dead_circumflex vs dead_diaeresis).
	_set_client_shift(needs_shift)
	# KEY_BRACKETLEFT (91) → evdev 26 (touche AZERTY '^'), cf. GODOT_TO_EVDEV.
	fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, true)
	# Phase 2 : Shift réel de la lettre (bas-de-casse vs majuscule), qui reste
	# l'état final (il correspond à la réalité physique après la séquence).
	_set_client_shift(letter_shift)
	fm.compositor.forward_keyboard_key(phys, 0, true)
	fm.compositor.forward_keyboard_key(phys, 0, false)
	fm.compositor.forward_keyboard_key(KEY_BRACKETLEFT, 0, false)
	return true

# Gère un InputEvent en mode focus (clavier + tracking souris capturée).
# Renvoie true si l'événement a été consommé (toujours le cas en mode focus).
func handle_input_event(event: InputEvent) -> bool:
	# Sélection de zone (PrtSc) : priorité absolue. Tant qu'elle est active
	# tout l'input est avalé (rien ne part aux fenêtres) ; Escape annule.
	# Fonctionne aussi en focus distant (vue seule).
	if fm.zone_select_active:
		if event is InputEventKey:
			var zkey := event as InputEventKey
			if not zkey.echo and (zkey.keycode == KEY_ESCAPE or zkey.physical_keycode == KEY_ESCAPE):
				fm.zone_select._cancel_zone_selection()
		return true
	# PrtSc en mode focus : armer l'outil de sélection au lieu de forwarder la
	# touche au client. Fonctionne sur le bind remapable "screenshot".
	if event is InputEventKey and not _shortcuts_inhibited():
		var skey := event as InputEventKey
		if not skey.echo and InputMap.event_is_action(skey, "screenshot", true):
			fm.zone_select._start_zone_selection()
			return true
	# Focus distant (vue seule) : tout est consommé, rien n'est forwardé
	# (focus_stack est vide pour le focus distant).
	if fm.remote_focus:
		return true
	if not fm.focus_mode or fm.focus_stack.is_empty():
		return false
	var active_id := fm._active_id()
	var st := fm._state(active_id)
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# Échos de répétition Godot : les consommer sans les forwarder, sinon
		# xkbcommon reçoit des DOWN non appariés → modificateur "coincé".
		if key_event.echo:
			return true
		# Raccourcis clavier gérés par le jeu lui-même (le raccourci focus
		# pour sortir, la touche de fermeture de la fenêtre) : les consommer
		# SANS les forwarder au client. Sinon la touche est tapée dans la
		# fenêtre avant que l'action (exit_focus / close_window) ne s'exécute
		# dans _process. _is_compositor_shortcut ne matche que le bind exact
		# (modifieurs compris) ET uniquement l'appui : le relâchement est
		# forwardé (dropé comme orphelin par le garde-fou du compositeur si
		# nécessaire), pour ne jamais laisser une touche enfoncée côté client.
		# Une fenêtre capture les raccourcis (VM, bureau à distance) : tout lui
		# part, sauf l'échappatoire release_shortcuts qui rend la main au jeu.
		if _shortcuts_inhibited():
			if key_event.pressed and InputMap.event_is_action(key_event, "release_shortcuts", true):
				fm.shortcuts_release_requested.emit()
				return true
		elif _is_compositor_shortcut(key_event):
			return true
		var code = key_event.physical_keycode
		if code == 0:
			code = key_event.keycode
		# Touches mortes : Godot a composé l'accent lui-même (voir
		# _try_reconstruct_composed_key) — reconstruire la séquence pour le
		# client (incluant la gestion du Shift, cf. _set_client_shift) et ne
		# pas forwarder l'événement composé tel quel. Doit précéder le heal :
		# le flag shift_pressed d'un événement composé reflète la lettre, pas
		# la touche morte.
		if _try_reconstruct_composed_key(key_event):
			return true
		# Heal : rétablit l'état Shift du client si son relâchement a été avalé
		# par l'IM lors d'une touche morte.
		_prepare_key_forward(key_event, code)
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("key focus_mode: phys=", key_event.physical_keycode,
				" code=", key_event.keycode, " unicode=", key_event.unicode,
				" loc=", key_event.location, " pressed=", key_event.pressed)
		# Chevrons AZERTY : la touche ISO (physique KEY_QUOTELEFT/96) donne '<'
		# non-shifté et '>' shifté — même touche evdev 86, le Shift est forwardé
		# à part. Remap par code physique (pas par unicode, nul au relâchement)
		# pour que l'UP parte avec le MÊME evdev que le DOWN : sinon la touche
		# reste enfoncée côté client (auto-repeat en boucle) et les appuis
		# suivants sont bloqués par le garde-fou pressed_keys.
		if key_event.unicode == 60 or key_event.unicode == 62 or code == KEY_QUOTELEFT:
			code = KEY_LESS
		fm.compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
	elif event is InputEventMouseButton:
		# Suivi brut du bouton gauche (voir _left_down) + log de diagnostic :
		# les clics ne sont pas forwardés depuis ce chemin (le routage pointeur
		# est fait par polling dans handle_focus_input), on consomme seulement.
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			fm._left_down = mb.pressed
			fm._left_event_pressed = mb.pressed
			fm._left_event_frame = Engine.get_process_frames()
		# Scroll wheel : forward direct au compositeur (pas de cooldown).
		# Les ticks souris sont ponctuels (1 frame) ; le polling dans
		# _forward_window_buttons rate les ticks rapides à cause du cooldown
		# conçu pour le stick gamepad. Si le curseur survole un popup de la
		# fenêtre active, son contenu reçoit la molette (ex: menu déroulant),
		# sinon c'est la fenêtre active qui scroll.
		if (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN) and mb.pressed:
			var delta := -120.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 120.0
			var popup_hit := fm.popups._popup_at(mb.position)
			if not popup_hit.is_empty():
				fm.popups._forward_to_popup(popup_hit, mb.position)
				var content_size: Vector2 = popup_hit.rect.get_meta("content_size", popup_hit.rect.size)
				if content_size.x > 0.0 and content_size.y > 0.0:
					fm.compositor.forward_pointer_axis_popup(int(popup_hit.id), 0, delta)
			else:
				var target := fm._active_id()
				if target != -1:
					fm.compositor.forward_pointer_axis(target, 0, delta)
		if OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1":
			print("mouse _input: btn=", mb.button_index, " pressed=", mb.pressed,
				" meta=", mb.meta_pressed, " pos=", mb.position)
	elif st["mouse_captured"] and event is InputEventMouseMotion:
		# Tracker la position UV + forward le mouvement relatif au client
		var viewport_size := get_viewport().get_visible_rect().size
		var tex_size: Vector2 = st["surface_size"]
		if tex_size.x <= 0 or tex_size.y <= 0:
			tex_size = viewport_size
		var scale := minf(viewport_size.x / tex_size.x, viewport_size.y / tex_size.y)
		var displayed_size := tex_size * scale
		st["mouse_uv"].x += event.relative.x / displayed_size.x
		st["mouse_uv"].y += event.relative.y / displayed_size.y
		st["mouse_uv"].x = clampf(st["mouse_uv"].x, 0.0, 1.0)
		st["mouse_uv"].y = clampf(st["mouse_uv"].y, 0.0, 1.0)
		fm.compositor.forward_pointer_relative_motion(
			active_id,
			event.relative.x, event.relative.y,
			event.relative.x, event.relative.y)
	return true

# True si l'événement clavier correspond à un raccourci géré par le jeu
# (et non par le client) pendant le mode focus : la touche ne doit pas
# être forwardée. Les actions sont celles vérifiées dans _process de
# wayland_room.gd (sortie de focus, fermeture de la fenêtre).
# On utilise exact_match=true : seules les touches correspondant au bind
# exact (modifieurs compris, ex. Super+F) sont consommées. F seul — et
# ses combinaisons Ctrl/Shift/Alt+F — partent donc normalement vers le
# client, même si le raccourci focus utilise le modifieur Super.
# Seul l'APPUI est consommé : le relâchement est toujours forwardé. Si on
# avalait aussi le keyup, un F dont l'appui a déjà été forwardé (tapé dans
# la fenêtre) et qui est relâché pendant que Super est encore enfoncé serait
# perdu → la touche resterait enfoncée côté client (auto-repeat en boucle).
## Une fenêtre a-t-elle capturé les raccourcis du jeu (zwp_keyboard_shortcuts_inhibit_v1) ?
func _shortcuts_inhibited() -> bool:
	return fm.compositor != null and fm.compositor.has_method("is_shortcuts_inhibited") \
			and fm.compositor.is_shortcuts_inhibited()

func _is_compositor_shortcut(event: InputEventKey) -> bool:
	if not event.pressed:
		return false
	for action in ["focus_window", "kill_window", "force_game"]:
		if InputMap.event_is_action(event, action, true):
			return true
	return false

## True quand les binds manette du mode focus doivent être ignorés : la
## fenêtre active est un jeu ET la souris est capturée (pointer lock).
func _gamepad_binds_disabled() -> bool:
	return fm.in_game() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

func _click_action_just_pressed(action: String) -> bool:
	if not Input.is_action_just_pressed(action):
		return false
	if fm._joy_click_blocked.get(action, false):
		return false
	# Appui + relâchement manette dans la même frame : toujours bloqué.
	return fm._joy_click_release_frame.get(action, -1) != Engine.get_process_frames()

func _click_action_just_released(action: String) -> bool:
	if not Input.is_action_just_released(action):
		return false
	if fm._joy_click_blocked.get(action, false):
		return false
	return fm._joy_click_release_frame.get(action, -1) != Engine.get_process_frames()
