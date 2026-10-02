extends Node3D

var PIN_SIZE: Vector2
# PIN_SIZE vaut viewport / pin_size_divisor. Le diviseur est réglable depuis
# pause_menu > Graphics entre 2 (pin grand) et 4 (pin petit).
const PIN_DIVISOR_MIN := 2.0
const PIN_DIVISOR_MAX := 4.0
const PIN_MARGIN := 8
# Épaisseur du cadre du PiP, de chaque côté. La bordure fait donc
# PIN_SIZE + PIN_BORDER * 2, et la texture est centrée dedans.
const PIN_BORDER := 2
# Rayon des coins arrondis (cadre uniquement : la texture n'est pas masquée).
const PIN_RADIUS := 4
# En dessous du layer focus (FOCUS_Z_BASE = 2000) : le PiP est caché quand
# une fenêtre est en mode focus.
const PIN_Z_BASE := 1900
# Au-dessus du layer focus (y compris ses popups, FOCUS_POPUP_Z = 2050) : le
# PiP reste visible pendant le mode focus. Choix via le menu pause.
const PIN_Z_ABOVE_FOCUS := 2100

# Loupe sur le PiP : zoom = 1.0 -> fenêtre entière visible (rendu actuel).
const ZOOM_MIN := 1.0
const ZOOM_MAX := 4.0
# Valeur de départ au PREMIER passage en loupe sur une fenêtre : 2x, centré.
# À 1x l'"agrandissement" est invisible (on verrait la même chose qu'avant) ;
# 2x centré donne immédiatement une lecture lisible du milieu de la fenêtre.
const ZOOM_FIRST := 2.0
# Pas de zoom par cran de molette.
const ZOOM_STEP := 0.15
# Vitesse de déplacement (recadrage) : pixels de région par pixel de souris.
const ZOOM_PAN_SPEED := 1.0
# Recadrage au stick droit, en pixels de région par seconde à pleine deflection.
# Le stick DROIT et non le gauche : le menu radial se navigue au stick gauche,
# et la caméra est gelée pendant la loupe — les deux sticks sont donc libres,
# mais seul le droit n'est jamais utilisé par un menu.
const ZOOM_STICK_SPEED := 700.0
# Zone morte du stick : sans elle, un stick au repos fait dériver le recadrage
# en permanence. Volontairement plus basse que celle du menu radial (0.5) :
# recadrer demande une précision de pointeur, pas une frappe directionnelle.
const ZOOM_STICK_DEADZONE := 0.2
# Maintien des touches de zoom (LB/RB par defaut), en crans par seconde. Aucun
# delai avant la rampe : la loupe doit repondre vite a la manette, donc le
# maintien enchaine des crans des le deuxieme frame. La separation entre
# « nouvelle pression » et « meme pression » reste le garde-fou, assure par le
# changement de direction dans _advance_scroll_hold.
const ZOOM_HOLD_RATE := 10.0
# Bordure bleue = mode loupe actif. Défaut seulement : la couleur effective
# vient de pins_border_color, réglable depuis pause_menu > Graphics.
const ZOOM_BORDER_COLOR := Color(0.29, 0.59, 1.0, 1.0)

## Émis quand le mode loupe est activé/désactivé. wayland_room s'en sert pour
## geler le joueur (souris capturée + caméra) sans que pinned_windows connaisse
## le joueur.
signal zoom_changed(active: bool)

var ui: CanvasLayer
var focus: Node3D
var compositor
var pinned_windows: Dictionary = {} # clé (int window_id local, ou String "r:peer:wid" distant) -> TextureRect
# True : la fenêtre épinglée s'affiche au-dessus du layer focus.
var pins_above_focus := false
# Pourcentage de transparence de la fenêtre épinglée (0 = opaque, 100 = invisible).
var pins_opacity := 0
# Coin de l'écran où est affichée la fenêtre épinglée.
# "top_left" | "top_right" | "bottom_left" | "bottom_right"
var pins_position := "top_left"
var _hover_tween: Tween
var _is_hovering := false
var _last_mouse_pos := Vector2(-1, -1)
var mouse_pos := Vector2.ZERO
var _layers: Node3D
var border_color := Color.TRANSPARENT
# Couleur CHOISIE pour la bordure de loupe, et diviseur CHOISI pour la taille.
# Distincts de border_color / PIN_SIZE, qui sont les valeurs EFFECTIVES :
# border_color vaut TRANSPARENT hors loupe, et PIN_SIZE est recalculé depuis le
# viewport. Confondre les deux ferait qu'un réglage hors loupe ne s'appliquerait
# qu'au redémarrage.
var pins_border_color := ZOOM_BORDER_COLOR
var pin_size_divisor := 3.0
var zooming := false
## Facteur de zoom courant du PiP (ZOOM_MIN..ZOOM_MAX), 1.0 = fenêtre entière.
var zoom_factor := ZOOM_MIN
## Décalage de recadrage normalisé (0..1 sur chaque axe) : indépendant de la
## résolution de la texture, donc stable quand la fenêtre épinglée se
## redimensionne.
var zoom_pan := Vector2(0.5, 0.5)
## Faux tant que l'utilisateur n'a jamais ouvert la loupe sur ce PiP : sert à
## n'appliquer ZOOM_FIRST qu'au PREMIER passage (ensuite sa valeur est
## conservée). Remis à faux quand le PiP est déposé — il n'y a qu'un seul PiP
## à la fois, une variable suffit donc.
var _zoom_initialized := false
# Direction courante du maintien des touches de zoom (-1 / 0 / +1). Un appui
# simple donne deja un cran via l'evenement : cette variable ne sert qu'a
# distinguer « nouvelle pression » de « meme pression », et c'est elle qui
# empeche de doubler ce premier cran.
var _scroll_hold_dir := 0.0
# Cache de l'état de priorité de capture appliqué au compositeur : la sync
# étant idempotente, la poll de _process ne coûte qu'une comparaison par frame.
var _capture_priority_id := -1

# Rectangle de la texture épinglée affiché par le PiP, en pixels de texture.
# Fonction pure : aucune dépendance au viewport, testable en headless.
#
# pan est normalisé (0..1 par axe) : indépendant de la résolution, donc le
# recadrage survit au redimensionnement de la fenêtre épinglée. La région est
# recadrée au ratio de la boîte (aspect) plutôt qu'étirée, puis bornée dans la
# texture — impossible de faire apparaître du vide, quel que soit le zoom.
static func zoom_region(tex_size: Vector2, zoom: float, pan: Vector2, aspect: float) -> Rect2:
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var z := clampf(zoom, ZOOM_MIN, ZOOM_MAX)
	var s := tex_size / z
	# Recadrage au ratio de la boîte : on rogne le côté le plus long. Si le
	# ratio est inconnu — PIN_SIZE pas encore calculée, donc 0/0 — on SAUTE
	# l'ajustement : sans ce garde-fou, s.y = s.x / 0 donnait un rect non fini,
	# affiché en texture cassée. L'agrandissement, lui, reste appliqué.
	if is_finite(aspect) and aspect > 0.0:
		if s.x / s.y > aspect:
			s.x = s.y * aspect
		else:
			s.y = s.x / aspect
	# Une texture plus petite que la région (petites fenêtres) reste entière.
	s = Vector2(minf(s.x, tex_size.x), minf(s.y, tex_size.y))
	var p := Vector2(clampf(pan.x, 0.0, 1.0), clampf(pan.y, 0.0, 1.0))
	var pos := Vector2(
		clampf(p.x * (tex_size.x - s.x), 0.0, maxf(tex_size.x - s.x, 0.0)),
		clampf(p.y * (tex_size.y - s.y), 0.0, maxf(tex_size.y - s.y, 0.0)))
	return Rect2(pos, s)

## Transforme une deflection de stick en vecteur de recadrage normalisé, en
## [0..1] : rien sous la zone morte, et surtout SANS SAUT au franchissement —
## on retranche la zone morte puis on renormalise, sinon le recadrage bondirait
## dès que le stick frôle le seuil. La direction du stick est conservee, seule
## l'amplitude est réétalée. Isolé en statique car la manette n'est pas
## simulable en headless : c'est la partie qui mérite un test, le reste n'est
## qu'une lecture d'axes.
static func stick_pan_vector(raw: Vector2, deadzone: float) -> Vector2:
	var mag := raw.length()
	# deadzone >= 1 rendrait le retranchement impossible (division par zéro) :
	# on borne, et un stick au repos n'a rien à donner de toute façon.
	var dz := clampf(deadzone, 0.0, 0.99)
	if mag <= dz or mag <= 0.0:
		return Vector2.ZERO
	return raw / mag * clampf((mag - dz) / (1.0 - dz), 0.0, 1.0)

func setup(ui_ref: CanvasLayer, focus_ref: Node3D, layers: Node3D, compositor_ref = null) -> void:
	_layers = layers
	_sync_pin_size()
	mouse_pos = _layers._cursor_pos
	ui = ui_ref
	focus = focus_ref
	compositor = compositor_ref
	if ui != null and ui.get_viewport() != null:
		ui.get_viewport().size_changed.connect(_sync_pin_size)

## Le PiP EST-il réellement affiché à l'écran ? Une priorité de capture payée
## pour une image invisible est du gaspillage GPU — et ça aggrave la pression
## qui dégrade justement la cadence des autres. Trois raisons de ne pas l'être :
##   - pas de fenêtre épinglée ;
##   - le mode focus : le PiP est sous l'overlay plein écran (PIN_Z_BASE <
##     FOCUS_Z_BASE) SAUF si pins_above_focus est activé ;
##   - opacité 100 %.
## Le voile de hover (_set_hovering) est volontairement absent : il est
## transitoire et le joueur regarde de toute façon la fenêtre 3D à ce moment-là.
func _pip_visible() -> bool:
	if pinned_windows.is_empty() or pins_opacity >= 100:
		return false
	return not (focus.focus_mode and not pins_above_focus)

## Aligne la priorité de capture du compositeur sur la visibilité réelle du
## PiP. Idempotente : seule la transition appelle le compositeur.
func _sync_capture_priority() -> void:
	if compositor == null or not is_instance_valid(compositor):
		return
	# Un pin DISTANT est le flux d'un autre joueur : il n'y a pas de surface
	# wlr locale à capturer, la priorité serait un no-op. Sa clé est une
	# String, pas un int — le typage du test le garantit.
	var key = _pip_key()
	var want: int = int(key) if key is int and _pip_visible() else -1
	if want == _capture_priority_id:
		return
	compositor.set_pin_capture_priority_window(want, want >= 0)
	_capture_priority_id = want

func _pin_z_index() -> int:
	return PIN_Z_ABOVE_FOCUS if pins_above_focus else PIN_Z_BASE

func _pin_alpha() -> float:
	return 1.0 - float(pins_opacity) / 100.0

## Géométrie d'un pin, en un seul endroit. La taille est une FONCTION de
## PIN_SIZE : _add_pin et set_pins_size_divisor passent donc tous deux par ici,
## sinon les deux se désynchronisent au premier réglage de taille (le cadre
## garderait l'ancienne taille pendant que la texture prend la nouvelle).
func _resize_pin(border: Control) -> void:
	if not is_instance_valid(border):
		return
	var pip := border.get_child(0) as TextureRect
	if pip != null:
		pip.size = PIN_SIZE
	border.size = PIN_SIZE + Vector2(PIN_BORDER, PIN_BORDER) * 2.0
	border.position = _pin_position()

## Recalcule PIN_SIZE depuis le viewport courant et réajuste les pins déjà
## créés. PIN_SIZE est un facteur du viewport : un redimensionnement de fenêtre
## doit le RESCALER, pas seulement le repositionner — sinon un pin né en
## 1920x1080 garde 640x360 dans une fenêtre de 1280x720.
func _sync_pin_size() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	PIN_SIZE = vp.get_visible_rect().size / pin_size_divisor
	for key in pinned_windows:
		_resize_pin(pinned_windows[key])
	# Le ratio de la région dépend de PIN_SIZE, mais on ne réapplique le zoom
	# que si la loupe est ACTIVE : _apply_zoom() rebascule en texture pleine
	# sous ZOOM_MIN, donc l'appeler ici effacerait un zoom déjà choisi par
	# l'utilisateur, qui persiste justement hors loupe.
	if zooming:
		_apply_zoom()

## Diviseur de taille du pin (viewport / X), borné à [PIN_DIVISOR_MIN,
## PIN_DIVISOR_MAX]. Le clamp protège d'un settings.json corrompu et du slider
## lui-même, qui a les mêmes bornes.
func set_pins_size_divisor(divisor: float) -> void:
	var d := clampf(divisor, PIN_DIVISOR_MIN, PIN_DIVISOR_MAX)
	if is_equal_approx(d, pin_size_divisor):
		return
	pin_size_divisor = d
	_sync_pin_size()

## Couleur de la bordure de loupe. Ne touche PAS border_color : celle-ci reste
## TRANSPARENT hors loupe, donc la nouvelle couleur n'apparaîtra qu'au prochain
## set_zooming(true). _apply_border_color() est tout de même appelé pour qu'un
## changement fait EN loupe s'applique immédiatement.
func set_pins_border_color(color: Color) -> void:
	if color.is_equal_approx(pins_border_color):
		return
	pins_border_color = color
	_apply_border_color()

func _pin_position() -> Vector2:
	var size := Vector2(PIN_MARGIN, PIN_MARGIN)
	if ui != null and ui.get_viewport() != null:
		size = ui.get_viewport().get_visible_rect().size
	var px := PIN_SIZE.x + PIN_BORDER * 2.0 + PIN_MARGIN
	var py := PIN_SIZE.y + PIN_BORDER * 2.0 + PIN_MARGIN
	match pins_position:
		"top_right":
			return Vector2(size.x - px, PIN_MARGIN)
		"bottom_left":
			return Vector2(PIN_MARGIN, size.y - py)
		"bottom_right":
			return Vector2(size.x - px, size.y - py)
	return Vector2(PIN_MARGIN, PIN_MARGIN)

func _reposition_all() -> void:
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.position = _pin_position()

func is_pinned(id: int) -> bool:
	return pinned_windows.has(id)

## Un pin est-il vivant, sans savoir lequel ? C'est la seule question que pose
## le menu radial (qui n'a pas, et ne doit pas avoir, de référence vers ce
## script) pour décider d'afficher son entrée « ZOOM PIN ».
func has_pin() -> bool:
	return not pinned_windows.is_empty()

func pin(id: int, texture: Texture2D) -> void:
	_add_pin(id, texture)

# Clé de PiP unique pour une fenêtre distante (un wid local et un wid distant
# peuvent coïncider numériquement : on préfixe par le peer).
func _remote_key(peer_id: int, wid: int) -> String:
	return "r:%d:%d" % [peer_id, wid]

func is_pinned_remote(peer_id: int, wid: int) -> bool:
	return pinned_windows.has(_remote_key(peer_id, wid))

func pin_remote(peer_id: int, wid: int, texture: Texture2D) -> void:
	_add_pin(_remote_key(peer_id, wid), texture)

func unpin_remote(peer_id: int, wid: int) -> void:
	unpin(_remote_key(peer_id, wid))

# Retire tous les PiP des fenêtres d'un joueur distant (déconnexion, fin de
# session, plus aucune fenêtre partagée).
func unpin_peer(peer_id: int) -> void:
	var prefix := "r:%d:" % peer_id
	for key in pinned_windows.keys().duplicate():
		if key is String and key.begins_with(prefix):
			unpin(key)

func _add_pin(key, texture: Texture2D) -> void:
	# Si la fenêtre est déjà épinglée, on ne fait rien
	if pinned_windows.has(key):
		return

	# Si une AUTRE fenêtre est déjà épinglée, on la retire d'abord
	unpin_all()

	var pip := TextureRect.new()
	# Le PiP ne porte jamais la texture brute mais un AtlasTexture : c'est ce
	# qui permet de recadrer la loupe (region) sans toucher à l'arbre de
	# nœuds. Hors loupe, la région vaut la texture entière — le rendu est donc
	# identique à un TextureRect simple. filter_clip évite que l'échantillonnage
	# déborde sur les pixels voisins au bord du recadrage.
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(Vector2.ZERO, texture.get_size() if texture != null else Vector2.ZERO)
	atlas.filter_clip = true
	pip.texture = atlas
	pip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Bordure
	var border := PanelContainer.new()
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = border_color
	# Marge interne = épaisseur du cadre : le PanelContainer dimensionne
	# l'enfant sur son rect de contenu, la texture se retrouve donc centrée
	# dans la bordure au lieu d'être collée en haut-gauche et étirée.
	bg.content_margin_left = PIN_BORDER
	bg.content_margin_right = PIN_BORDER
	bg.content_margin_top = PIN_BORDER
	bg.content_margin_bottom = PIN_BORDER
	bg.corner_radius_top_left = PIN_RADIUS
	bg.corner_radius_top_right = PIN_RADIUS
	bg.corner_radius_bottom_left = PIN_RADIUS
	bg.corner_radius_bottom_right = PIN_RADIUS
	border.add_theme_stylebox_override("panel", bg)
	border.add_child(pip)
	border.z_index = _pin_z_index()

	_resize_pin(border)
	pip.set_meta("window_id", key)
	ui.add_child(border)
	pinned_windows[key] = border

func unpin(key) -> void:
	if not pinned_windows.has(key):
		return
	var pip: Control = pinned_windows[key]
	if is_instance_valid(pip):
		pip.queue_free()
	pinned_windows.erase(key)
	if pinned_windows.is_empty():
		_is_hovering = false
		if _hover_tween:
			_hover_tween.kill()
			_hover_tween = null
		# Plus rien à inspecter : on ne doit pas rester en loupe (souris
		# capturée et joueur gelé) avec un PiP vide. Le niveau de zoom, lui, est
		# remis au neutre : la prochaine fenêtre épinglée est sans rapport avec
		# celle-ci et ne doit pas hériter d'un 4x (une simple bascule, elle,
		# conserve le zoom et le recadrage).
		zoom_factor = ZOOM_MIN
	zoom_pan = Vector2(0.5, 0.5)
	_zoom_initialized = false
	# Un bouton encore enfonce ne doit pas relancer la rampe a la reouverture
	# de la loupe : on repart d'un maintien neuf.
	_scroll_hold_dir = 0.0
	set_zooming(false)


## Retire toutes les fenêtres épinglées (pour garantir 1 seule fenêtre max)
func unpin_all() -> void:
	for current_id in pinned_windows.keys():
		unpin(current_id)

func on_window_unmapped(id: int) -> void:
	unpin(id)

# Met à jour la couche d'affichage des fenêtres épinglées par rapport au layer
# focus (réglage du menu pause) : s'applique immédiatement aux PiP existants.
func set_pins_above_focus(above: bool) -> void:
	if pins_above_focus == above:
		return
	pins_above_focus = above
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.z_index = _pin_z_index()

# Applique la transparence (0-100 %) aux PiP existants.
func set_pins_opacity(percent: int) -> void:
	percent = clampi(percent, 0, 100)
	if pins_opacity == percent:
		return
	pins_opacity = percent
	var alpha := _pin_alpha()
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.modulate.a = alpha

# Déplace la fenêtre épinglée dans le coin choisi (s'applique immédiatement).
func set_pins_position(position: String) -> void:
	if not position in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		return
	if pins_position == position:
		return
	pins_position = position
	_reposition_all()

func on_window_texture_updated(id: int, texture: Texture2D) -> void:
	# On remplace la texture SOURCE de l'AtlasTexture, pas texture : le
	# recadrage de la loupe doit survivre aux frames (la texture est
	# réassignée à chaque frame pour une fenêtre vivante).
	var atlas := _pip_atlas(id)
	if atlas == null:
		return
	atlas.atlas = texture
	_apply_zoom()

# Mise à jour de la texture d'une fenêtre distante épinglée (appelé par
# lan_manager à chaque frame streamée reçue).
func on_remote_texture_updated(peer_id: int, wid: int, texture: Texture2D) -> void:
	var atlas := _pip_atlas(_remote_key(peer_id, wid))
	if atlas == null:
		return
	atlas.atlas = texture
	_apply_zoom()

func _process(delta: float) -> void:
	# AVANT le test « aucun pin » : c'est précisément au dépôt du DERNIER pin
	# que la priorité doit être révoquée, et un early-return la laisserait
	# fuiter (60/s payées pour une image disparue, jusqu'à la fin de session).
	# Le mode focus n'émet aucun signal : son entrée/sortie n'est pas
	# observable d'ici, et c'est pourtant elle qui décide de la visibilité du
	# PiP (pins_above_focus). On réévalue donc ici — c'est déjà là que
	# focus.focus_mode est lu chaque frame pour le survol. Idempotent, donc
	# une frame stable ne coûte qu'une comparaison.
	_sync_capture_priority()

	if pinned_windows.is_empty():
		return

	# Mode loupe : la caméra est gelée, donc le raycast de visée est statique et
	# toucherait la fenêtre épinglée en permanence — le voile du hover
	# effacerait la loupe qu'on est en train d'utiliser. Le recadrage, lui, se
	# fait ici au stick : une souris capturée est un ENVENTEMENT (delta), donc
	# impossible à pollonner, alors qu'un stick est un ETAT lisible chaque frame.
	if zooming:
		_set_hovering(false)
		_stick_pan(delta)
		_hold_zoom(delta)
		return

	# Hover = visée (rayon caméra sur la fenêtre 3D épinglée), quel que soit
	# le mode souris ; en MOUSE_MODE_VISIBLE, survoler le PiP lui-même compte
	# aussi.
	var hovering := _look_hover()

	var pointer_free = Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
		or focus.focus_fullscreen_id != -1 \
		or (focus.focus_mode and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN)
		
	if focus.focus_fullscreen_id in pinned_windows:
		hovering = true
	elif not hovering and pointer_free:
		if focus.focus_mode:
			mouse_pos = focus.mouse_pos
		else:
			mouse_pos = _layers._cursor_pos
		if mouse_pos == _last_mouse_pos:
			return
		_last_mouse_pos = mouse_pos
		for key in pinned_windows:
			var pip: Control = pinned_windows[key]
			if is_instance_valid(pip) and pip.get_global_rect().has_point(mouse_pos):
				hovering = true
				break
	_set_hovering(hovering)

# Transition d'état commune : voile le PiP quand on vise sa fenêtre 3D, le
# restaure sinon.
func _set_hovering(hovering: bool) -> void:
	if hovering == _is_hovering:
		return
	_is_hovering = hovering
	if _hover_tween:
		_hover_tween.kill()
	var target_alpha := 0.0 if hovering else _pin_alpha()
	_hover_tween = create_tween()
	for key in pinned_windows:
		var pip: Control = pinned_windows[key]
		if is_instance_valid(pip):
			_hover_tween.tween_property(pip, "modulate:a", target_alpha, 0.15)

# True si le rayon caméra touche la fenêtre 3D correspondant
# au PiP épinglé — quad de contenu local ("window_id"), barre de titre locale
# ("titlebar_of") ou quad distant ("remote_window", quads noirs LAN).
func _look_hover() -> bool:
	if pinned_windows.is_empty():
		return false
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var origin := cam.global_position 
	var dir := -cam.global_transform.basis.z
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is Node):
		return false
	if collider.has_meta("window_id"):
		return pinned_windows.has(int(collider.get_meta("window_id")))
	if collider.has_meta("titlebar_of"):
		return pinned_windows.has(int(collider.get_meta("titlebar_of")))
	if collider.has_meta("remote_window"):
		var rw: Dictionary = collider.get_meta("remote_window")
		return pinned_windows.has(_remote_key(int(rw.get("peer_id", -1)), int(rw.get("wid", -1))))
	return false

# Bascule du mode loupe (SUPER+SHIFT+P). Sans fenêtre épinglée il n'y a rien à
# inspecter : l'activation est refusée.
func toggle_zoom() -> void:
	set_zooming(not zooming)

# Transition d'état du mode loupe. La souris reste capturée dans les deux sens
# (c'est déjà le mode FPS par défaut) : la molette et le mouvement souris
# passent de la caméra du joueur au recadrage du PiP. wayland_room gèle le
# joueur via le signal zoom_changed.
func set_zooming(active: bool) -> void:
	if zooming == active:
		return
	if active and pinned_windows.is_empty():
		return
	zooming = active
	if zooming and not _zoom_initialized:
		# Premier passage en loupe sur ce PiP : on démarre agrandi et centré.
		_zoom_initialized = true
		zoom_factor = ZOOM_FIRST
		zoom_pan = Vector2(0.5, 0.5)
	border_color = pins_border_color if zooming else Color.TRANSPARENT
	_last_mouse_pos = Vector2(-1, -1)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_border_color()
	_apply_zoom()
	zoom_changed.emit(zooming)

# Pousse zoom_factor / zoom_pan sur les PiP existants.
func _apply_zoom() -> void:
	var aspect := PIN_SIZE.x / PIN_SIZE.y
	for key in pinned_windows:
		var pip := _pip_atlas(key)
		var tr := _pip_rect(key)
		if pip == null or tr == null:
			continue
		if zoom_factor <= ZOOM_MIN:
			# Fenêtre entière, letterboxée : le rendu d'origine. Attention, on ne
			# teste PAS `zooming` ici : l'agrandissement est une propriété du PiP,
			# il reste affiché en sortant du mode loupe (seul l'interactif —
			# bordure bleue, souris capturée, molette, recadrage — s'arrête).
			pip.region = Rect2(Vector2.ZERO, _atlas_size(pip))
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			continue
		pip.region = zoom_region(_atlas_size(pip), zoom_factor, zoom_pan, aspect)
		# La région a déjà le ratio de la boîte : STRETCH_SCALE la remplit
		# exactement, sans bandes noires.
		tr.stretch_mode = TextureRect.STRETCH_SCALE

func _atlas_size(atlas: AtlasTexture) -> Vector2:
	return atlas.atlas.get_size() if atlas.atlas != null else Vector2.ZERO

# AtlasTexture de recadrage d'un PiP (null si la clé n'a pas de PiP valide).
func _pip_atlas(key) -> AtlasTexture:
	var tr := _pip_rect(key)
	return tr.texture as AtlasTexture if tr != null else null

# TextureRect d'un PiP.
func _pip_rect(key) -> TextureRect:
	var pip: Control = pinned_windows.get(key)
	if not is_instance_valid(pip) or pip.get_child_count() == 0:
		return null
	return pip.get_child(0) as TextureRect

# Repaint la bordure de tous les PiP (changement de couleur en loupe).
func _apply_border_color() -> void:
	for key in pinned_windows:
		var pip: Control = pinned_windows[key]
		if not is_instance_valid(pip):
			continue
		var sb := pip.get_theme_stylebox("panel") as StyleBoxFlat
		if sb != null:
			sb.bg_color = border_color

# Molette : un cran = un palier de zoom, borné à [ZOOM_MIN, ZOOM_MAX].
func zoom_by_scroll(steps: float) -> void:
	if not zooming:
		return
	zoom_factor = clampf(zoom_factor + steps * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
	_apply_zoom()

# Mouvement souris (relatif, la souris étant capturée) : déplace le recadrage.
# _region_size est la taille de la région courante en pixels de texture — le
# déplacement est converti en fraction normalisée pour rester indépendant de
# la résolution de la fenêtre.
func pan_by(relative: Vector2, _region_size: Vector2) -> void:
	if not zooming:
		return
	if _region_size.x > 0.0 and _region_size.y > 0.0:
		zoom_pan += relative * ZOOM_PAN_SPEED / _region_size
	zoom_pan = Vector2(clampf(zoom_pan.x, 0.0, 1.0), clampf(zoom_pan.y, 0.0, 1.0))
	_apply_zoom()

## Recadrage au stick droit. L'axe Y du stick est positif vers le bas, comme
## l'Y d'une souris : stick vers le bas -> zoom_pan.y monte -> la vue descend.
## Aucune inversion, donc.
func _stick_pan(delta: float) -> void:
	var raw := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	var dir := stick_pan_vector(raw, ZOOM_STICK_DEADZONE)
	if dir == Vector2.ZERO:
		return
	pan_by(dir * ZOOM_STICK_SPEED * delta, _current_region_size())

## Maintien des touches de zoom. On interroge les ACTIONS et non les indices de
## bouton : LB/RB y sont lies par defaut, mais un remappage continue de
## fonctionner sans toucher a ce code (meme approche que focus_mode.gd, qui
## combine les deux).
func _hold_zoom(delta: float) -> void:
	var dir := 0.0
	if Input.is_action_pressed("scroll_up"):
		dir += 1.0
	if Input.is_action_pressed("scroll_down"):
		dir -= 1.0
	var notches := _advance_scroll_hold(dir, delta)
	if not is_zero_approx(notches):
		zoom_by_scroll(notches)

## Avance le maintien et renvoie le nombre de crans a appliquer (-1/0/+1 en
## entree, crans fractionnaires en sortie : le zoom devient continu au lieu de
## sauter de 0.15 en 0.15). Pas de delai : la rampe demarre des le deuxieme
## frame. Ce qui evite de doubler le cran deja donne par l'evenement d'appui,
## c'est le changement de direction — seule la meme direction prolonge. Separe
## de la lecture des boutons pour etre testable sans manette.
func _advance_scroll_hold(dir: float, delta: float) -> float:
	if is_zero_approx(dir):
		_scroll_hold_dir = 0.0
		return 0.0
	if not is_equal_approx(dir, _scroll_hold_dir):
		_scroll_hold_dir = dir
		return 0.0
	return dir * ZOOM_HOLD_RATE * delta


## Taille de la région actuellement visible, pour convertir un décalage en
## pixels en déplacement de recadrage normalisé. Partagée par la souris (_input)
## et le stick (_process) : les deux doivent convertir à l'identique, sinon le
## même geste nedonnerait pas le même résultat selon l'appareil.
func _current_region_size() -> Vector2:
	var tr := _pip_rect(_pip_key())
	if tr == null:
		return Vector2.ZERO
	var atlas := tr.texture as AtlasTexture
	if atlas == null:
		return Vector2.ZERO
	return zoom_region(_atlas_size(atlas), zoom_factor, zoom_pan,
		PIN_SIZE.x / PIN_SIZE.y).size

func _input(event: InputEvent) -> void:
	if zooming:
		_handle_zoom_input(event)
		return
	if event is InputEventMouseMotion:
		mouse_pos = event.position

# Input du mode loupe : tout est consommé pour que ni la caméra du joueur ni la
# fenêtre 3D (ou le client Wayland en focus) ne réagissent au même événement.
func _handle_zoom_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		set_zooming(false)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("scroll_up", true) and !(event is InputEventJoypadButton):
		zoom_by_scroll(1.0)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("scroll_down", true) and !(event is InputEventJoypadButton):
		zoom_by_scroll(-1.0)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		pan_by((event as InputEventMouseMotion).relative, _current_region_size())
		get_viewport().set_input_as_handled()

# Clé du PiP courant (il n'y en a qu'un d'actif à la fois).
func _pip_key():
	return pinned_windows.keys()[0] if not pinned_windows.is_empty() else null
