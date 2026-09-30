extends Node
## Tests du zoom du PiP (pinned_windows.gd) : le recadrage de la texture
## épinglée en mode loupe (SUPER+SHIFT+P).
##
## Le calcul est isolé dans une fonction statique pure (zoom_region) : aucune
## dépendance au viewport, au compositeur ou à l'arbre de scène, donc
## testable en headless.

const Runner = preload("res://tests/runner.gd")
const Pins = preload("res://scripts/windows/pinned_windows.gd")
# Charge aussi player.gd : vérifie qu'il compile toujours dans le contexte du
# projet (autoloads disponibles), pas seulement en script isolé.
const PlayerScript = preload("res://scripts/player/player.gd")
# Menu radial : vérifie que l'entrée « ZOOM PIN » n'apparaît que lorsqu'un pin
# est actif. _build_items est une fonction pure sur _items, donc testable sans
# mettre le menu dans l'arbre.
const Radial = preload("res://scripts/ui/radial_menu.gd")

# Format du PiP : 640x360 -> 16/9.
const ASPECT := 640.0 / 360.0

func test_zoom_1_shows_whole_texture() -> Variant:
	## zoom = 1.0 : la fenêtre épinglée est entièrement visible. C'est
	## l'exact rendu d'aujourd'hui (letterbox STRETCH_KEEP_ASPECT_CENTERED),
	## la loupe ne doit rien changer à ce niveau.
	var r := Pins.zoom_region(Vector2(1920, 1080), 1.0, Vector2(0.5, 0.5), ASPECT)
	var res = Runner.assert_eq(r, Rect2(Vector2.ZERO, Vector2(1920, 1080)),
		"zoom 1.0 doit couvrir toute la texture")
	if _fail(res): return res
	return true

func test_zoom_2_halves_visible_region() -> Variant:
	## zoom = 2.0 : on ne voit plus que la moitié de la texture, centrée.
	var r := Pins.zoom_region(Vector2(1920, 1080), 2.0, Vector2(0.5, 0.5), ASPECT)
	var res = _assert_rect(r, Rect2(Vector2(480, 270), Vector2(960, 540)),
		"zoom 2.0 doit afficher le quart de la texture, centré")
	if _fail(res): return res
	return true

func test_region_keeps_pin_aspect() -> Variant:
	## Une texture carrée doit être recadrée au format du PiP (16/9), pas
	## étirée : la région garde le ratio de la boîte d'affichage.
	var r := Pins.zoom_region(Vector2(1000, 1000), 2.0, Vector2(0.5, 0.5), ASPECT)
	var res = _assert_approx_v(r.size, Vector2(500, 281.25),
		"la région doit être recadrée au ratio 16/9")
	if _fail(res): return res
	return true

func test_pan_zero_shows_top_left() -> Variant:
	## pan = (0,0) : la région est plaquée dans le coin haut-gauche.
	var r := Pins.zoom_region(Vector2(1920, 1080), 2.0, Vector2(0.0, 0.0), ASPECT)
	var res = _assert_approx_v(r.position, Vector2.ZERO,
		"pan (0,0) doit recadrer le coin haut-gauche")
	if _fail(res): return res
	return true

func test_pan_one_shows_bottom_right() -> Variant:
	## pan = (1,1) : la région est plaquée dans le coin bas-droit, sans
	## déborder de la texture.
	var r := Pins.zoom_region(Vector2(1920, 1080), 2.0, Vector2(1.0, 1.0), ASPECT)
	var res = _assert_approx_v(r.position, Vector2(960, 540),
		"pan (1,1) doit recadrer le coin bas-droit")
	if _fail(res): return res
	return true

func test_region_never_exceeds_texture() -> Variant:
	## Un pan hors bornes (souris qui part dans un coin) ne doit jamais faire
	## déborder la région hors de la texture, ni laisser de zone négative.
	var tex := Vector2(100, 100)
	var cases := [
		Vector2(5.0, -3.0), Vector2(-9.0, 0.5), Vector2(1.0, 1.0),
		Vector2(0.0, 0.0), Vector2(0.5, 0.5),
	]
	for z: float in [1.0, 2.0, 4.0, 12.0]:
		for p: Vector2 in cases:
			var r := Pins.zoom_region(tex, z, p, ASPECT)
			var res: Variant = _assert_approx_v(
				Vector2(maxf(r.position.x, 0.0), maxf(r.position.y, 0.0)),
				r.position, "position négative (zoom %f, pan %s)" % [z, p])
			if _fail(res): return res
			res = _assert_approx_v(
				Vector2(minf(r.position.x + r.size.x, tex.x),
					minf(r.position.y + r.size.y, tex.y)),
				r.position + r.size, "région hors texture (zoom %f, pan %s)" % [z, p])
			if _fail(res): return res
	return true

# ── Machine d'état du mode loupe ────────────────────────────────────────

func test_zoom_refused_without_pin() -> Variant:
	## Sans fenêtre épinglée il n'y a rien à inspecter : la loupe ne doit pas
	## s'activer (elleCapture la souris et gèle le joueur).
	var pins = Pins.new()
	pins.toggle_zoom()
	var res: Variant = Runner.assert_true(not pins.zooming,
		"la loupe ne doit pas s'activer sans fenêtre épinglée")
	pins.free()
	if _fail(res): return res
	return true

func test_zoom_enters_with_pin() -> Variant:
	## Avec un PiP, la loupe s'active et repeint la bordure en bleu.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	var res: Variant = Runner.assert_true(pins.zooming, "la loupe doit s'activer")
	if _fail(res):
		pins.free()
		return res
	res = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_FIRST,
		"l'activation d'un PiP neuf démarre à 2x")
	if _fail(res):
		pins.free()
		return res
	res = Runner.assert_eq(pins.border_color, Pins.ZOOM_BORDER_COLOR,
		"la bordure doit virer au bleu")
	pins.free()
	if _fail(res): return res
	return true

func test_zoom_off_keeps_factor_and_pan() -> Variant:
	## Sortir du mode loupe ne doit PAS tout remettre à zéro : on garde le
	## niveau de zoom et le recadrage.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_factor = 3.0
	pins.zoom_pan = Vector2(0.0, 1.0)
	pins.toggle_zoom()
	var res: Variant = Runner.assert_true(not pins.zooming, "la loupe doit se fermer")
	if _fail(res):
		pins.free()
		return res
	res = Runner.assert_eq(pins.zoom_factor, 3.0, "le zoom doit être conservé")
	if _fail(res):
		pins.free()
		return res
	res = _assert_approx_v(pins.zoom_pan, Vector2(0.0, 1.0),
		"le recadrage doit être conservé")
	pins.free()
	if _fail(res): return res
	return true

func test_first_zoom_starts_at_2x_centered() -> Variant:
	## Première loupe sur une fenêtre : on démarre à 2x centré, pour que le
	## premier effet soit une vraie magnification lisible (à 1x on ne verrait
	## rien changer) et non un coin de l'image.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_FIRST,
		"le premier passage en loupe doit démarrer à 2x")
	if _fail(res):
		pins.free()
		return res
	res = _assert_approx_v(pins.zoom_pan, Vector2(0.5, 0.5), "et centré sur la fenêtre")
	pins.free()
	if _fail(res): return res
	return true

func test_reopening_zoom_resumes_where_you_stopped() -> Variant:
	## Cas d'usage complet : on zoome, on coupe, on relance -> on retrouve son
	## niveau et son recadrage.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_by_scroll(10.0)
	var factor: float = pins.zoom_factor
	pins.pan_by(Vector2(200, 0), Vector2(960, 540))
	var pan: Vector2 = pins.zoom_pan
	pins.toggle_zoom()
	pins.toggle_zoom()
	var res: Variant = Runner.assert_eq(pins.zoom_factor, factor,
		"la loupe doit rouvrir au même niveau")
	if _fail(res):
		pins.free()
		return res
	res = _assert_approx_v(pins.zoom_pan, pan, "la loupe doit rouvrir au même recadrage")
	pins.free()
	if _fail(res): return res
	return true

func test_unpin_resets_zoom_state() -> Variant:
	## Un dépot n'est PAS une simple bascule : la fenêtre épinglée disparait.
	## Le zoom revient au neutre, sinon un 4x traîne sur la prochaine fenêtre
	## épinglée sans rapport.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_by_scroll(10.0)
	pins.zoom_pan = Vector2(0.0, 1.0)
	pins.unpin(42)
	var res: Variant = Runner.assert_true(not pins.zooming,
		"déposer la fenêtre épinglée doit quitter la loupe")
	if _fail(res):
		pins.free()
		return res
	res = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_MIN, "le zoom doit repartir de 1.0")
	if _fail(res):
		pins.free()
		return res
	res = _assert_approx_v(pins.zoom_pan, Vector2(0.5, 0.5),
		"le recadrage doit être recentré")
	pins.free()
	if _fail(res): return res
	return true


func test_unpin_exits_zoom() -> Variant:
	## Déposer la fenêtre (ou la voir disparaître) doit couper la loupe :
	## sinon le joueur reste avec la souris capturée et les commandes gelées,
	## sans rien à inspecter.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.unpin(42)
	var res: Variant = Runner.assert_true(not pins.zooming,
		"déposer la fenêtre épinglée doit quitter la loupe")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_zoom_clamps_at_max() -> Variant:
	## La molette ne doit pas pouvoir zoomer au-delà de ZOOM_MAX.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	for i in 200:
		pins.zoom_by_scroll(1.0)
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_MAX,
		"le zoom doit être borné à ZOOM_MAX")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_zoom_clamps_at_min() -> Variant:
	## Symétriquement, dézoomer ne doit pas descendre sous 1.0 (le PiP ne peut
	## pas afficher plus que la fenêtre entière).
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_factor = 2.0
	for i in 200:
		pins.zoom_by_scroll(-1.0)
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_MIN,
		"le zoom doit être borné à ZOOM_MIN")
	pins.free()
	if _fail(res): return res
	return true

func test_pan_moves_and_clamps() -> Variant:
	## Le mouvement souris décale le recadrage, borné à [0,1] : impossible de
	## faire sortir la région de la texture.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_factor = 2.0
	pins.zoom_pan = Vector2(0.0, 0.0)
	# 960x540 de région visible dans une texture 1920x1080 : le déplacement
	# maximal vaut donc 960 px en x et 540 en y. Un cran de 480x270 doit
	# avancer le recadrage de la moitié du parcours disponible.
	pins.pan_by(Vector2(480, 270), Vector2(960, 540))
	var res: Variant = _assert_approx_v(pins.zoom_pan, Vector2(0.5, 0.5),
		"le pan doit suivre le déplacement souris")
	if _fail(res):
		pins.free()
		return res
	pins.pan_by(Vector2(99999, 99999), Vector2(960, 540))
	res = _assert_approx_v(pins.zoom_pan, Vector2(1.0, 1.0),
		"le pan doit être borné à 1.0")
	if _fail(res):
		pins.free()
		return res
	pins.pan_by(Vector2(-99999, -99999), Vector2(960, 540))
	res = _assert_approx_v(pins.zoom_pan, Vector2(0.0, 0.0),
		"le pan doit être borné à 0.0")
	pins.free()
	if _fail(res): return res
	return true

func test_zoom_ignored_when_not_zooming() -> Variant:
	## Hors loupe, la molette et le mouvement souris appartiennent au jeu :
	## ils ne doivent pas toucher l'état du PiP.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.zoom_by_scroll(1.0)
	pins.pan_by(Vector2(500, 500), Vector2(960, 540))
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_MIN,
		"le zoom ne doit pas bouger hors loupe")
	if _fail(res):
		pins.free()
		return res
	res = _assert_approx_v(pins.zoom_pan, Vector2(0.5, 0.5),
		"le pan ne doit pas bouger hors loupe")
	pins.free()
	if _fail(res): return res
	return true

func test_player_freezes_on_zoom_both_halves() -> Variant:
	## Garde-fou : le drapeau pin_zoom_active doit être honoré aux DEUX points
	## de player.gd, sinon le joueur se met à marcher / tourner la caméra en
	## déplaçant le loupe. _physics_process (liste de gel) coupe le
	## déplacement, _input coupe la visée. Un flag posé à un seul endroit
	## disparaît silencieusement.
	var src := FileAccess.get_file_as_string("res://scripts/player/player.gd")
	if src.is_empty():
		return "scripts/player/player.gd introuvable"
	var body := src.substr(src.find("func _physics_process"),
		src.find("func _input") - src.find("func _physics_process"))
	if not body.contains("pin_zoom_active"):
		return "_physics_process doit geler le déplacement pendant la loupe"
	var input := src.substr(src.find("func _input"))
	if not input.contains("pin_zoom_active"):
		return "_input doit geler la visée pendant la loupe"
	return true

func test_room_gates_world_interaction_while_zooming() -> Variant:
	## Pendant la loupe, wayland_room ne doit plus router l'input vers le monde
	## (process_raycast_scroll de grab, handle_focus_input) : la molette
	## appartient au PiP, pas à la fenêtre 3D ou au client Wayland en focus.
	var src := FileAccess.get_file_as_string("res://scripts/main/wayland_room.gd")
	if src.is_empty():
		return "scripts/main/wayland_room.gd introuvable"
	if not src.contains("pins.zooming"):
		return "wayland_room doit tenir compte de pins.zooming pour couper l'input monde"
	if not src.contains("pins.zoom_changed"):
		return "wayland_room doit raccorder pins.zoom_changed pour geler le joueur"
	return true

func test_zoom_fills_pin_box_without_letterbox() -> Variant:
	## Intégration : le recadrage doit réellement atterrir sur le PiP, remplir
	## la boîte 640x360 et ne pas rester letterboxé.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var tr: TextureRect = ctx["pip"]
	var atlas: AtlasTexture = ctx["atlas"]
	var tex: Texture2D = ctx["tex"]

	# Hors loupe : la région couvre toute la texture et le letterbox d'origine
	# est conservé — le PiP doit rendre exactement comme avant la loupe.
	var res: Variant = Runner.assert_eq(atlas.region, Rect2(Vector2.ZERO, tex.get_size()),
		"hors loupe, la région doit couvrir toute la texture")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_eq(tr.stretch_mode, TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
		"hors loupe, le letterbox d'origine doit être conservé")
	if _fail(res): return _cleanup(ctx, res)

	pins.toggle_zoom()
	pins.zoom_by_scroll(3.0)
	res = Runner.assert_true(atlas.region.size.x < tex.get_size().x,
		"la région doit être plus petite que la texture")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_approx(atlas.region.size.x / atlas.region.size.y, ASPECT, 0.01,
		"la région doit garder le ratio de la boîte")
	if _fail(res): return _cleanup(ctx, res)
	# La région ayant déjà le bon ratio, STRETCH_SCALE remplit la boîte
	# exactement ; STRETCH_KEEP_ASPECT_CENTERED afficherait de fines bandes
	# noires, ce qui n'a pas de sens pour une loupe.
	res = Runner.assert_eq(tr.stretch_mode, TextureRect.STRETCH_SCALE,
		"en loupe, la région doit remplir la boîte (STRETCH_SCALE)")
	return _cleanup(ctx, res)

func test_texture_update_refreshes_zoom_region() -> Variant:
	## La fenêtre épinglée peut être redimensionnée par le client : la région
	## doit être recalculée sur la nouvelle texture, sinon le recadrage garde
	## des pixels d'une taille de texture périmée (image étirée ou vide).
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var atlas: AtlasTexture = ctx["atlas"]
	pins.toggle_zoom()
	pins.zoom_by_scroll(4.0)
	var before: Vector2 = atlas.region.size

	# Nouvelle texture, deux fois plus petite.
	var img := Image.create(960, 540, false, Image.FORMAT_RGBA8)
	pins.on_window_texture_updated(1, ImageTexture.create_from_image(img))
	var res: Variant = Runner.assert_true(atlas.region.size.x < before.x,
		"la région doit suivre la nouvelle taille de texture")
	return _cleanup(ctx, res)

func test_pip_is_centered_in_border() -> Variant:
	## La bordure fait PIN_SIZE + 4 (2 px de cadre de chaque côté) : la texture
	## doit être centrée dedans, pas collée en haut-gauche et pas étirée sur
	## toute la bordure. Le PanelContainer dimensionne l'enfant sur son rect de
	## contenu, donc c'est la marge interne du StyleBox qui centre.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var border: Control = ctx["border"]
	var sb := border.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return _cleanup(ctx, "la bordure doit porter un StyleBoxFlat")
	var res: Variant = Runner.assert_approx(sb.content_margin_left, Pins.PIN_BORDER, 0.01,
		"la marge interne doit valoir la moitié du cadre")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_approx(sb.content_margin_top, Pins.PIN_BORDER, 0.01,
		"marge interne haut")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_approx(sb.content_margin_right, Pins.PIN_BORDER, 0.01,
		"marge interne droite")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_approx(sb.content_margin_bottom, Pins.PIN_BORDER, 0.01,
		"marge interne bas")
	if _fail(res): return _cleanup(ctx, res)
	# La marge interne est symétrique et vaut la moitié du cadre : le
	# PanelContainer en déduit un rect de contenu centré, donc la texture
	# (640x360) se retrouve centrée dans la bordure (644x364) au lieu d'être
	# collée en haut-gauche et étirée dessus. On vérifie l'arithmétique plutôt
	# que le rect réel : celui-ci n'est posé qu'au prochain tri de layout, que
	# le runner synchrone ne peut pas attendre.
	var inner := border.size - Vector2(
		sb.content_margin_left + sb.content_margin_right,
		sb.content_margin_top + sb.content_margin_bottom)
	# PIN_SIZE est une variable d'instance (calculée sur le viewport), pas une
	# constante : on la lit sur l'instance vivante, pas via la classe.
	var pip_size: Vector2 = (ctx["pins"] as Node).PIN_SIZE
	res = _assert_approx_v(inner, pip_size,
		"le rect de contenu doit valoir la taille du PiP")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_approx(border.size.x, pip_size.x + Pins.PIN_BORDER * 2.0, 0.01,
		"la bordure doit faire PIN_SIZE + 2 * PIN_BORDER")
	return _cleanup(ctx, res)

func test_border_corners_are_rounded() -> Variant:
	## Coins arrondis sur la bordure ET sur la texture : un cadre arrondi sous
	## une texture carrée se voit immédiatement (les coins de l'image depassent
	## le cadre). Le masque doit donc etre applique a la texture.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var border: Control = ctx["border"]
	var tr: TextureRect = ctx["pip"]
	var sb := border.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return _cleanup(ctx, "la bordure doit porter un StyleBoxFlat")
	var res: Variant = Runner.assert_true(sb.corner_radius_top_left > 0
			and sb.corner_radius_top_right > 0
			and sb.corner_radius_bottom_left > 0
			and sb.corner_radius_bottom_right > 0,
		"les quatre coins de la bordure doivent etre arrondis")
	if _fail(res): return _cleanup(ctx, res)
	var mat := tr.material as ShaderMaterial
	if mat == null:
		return _cleanup(ctx, "la texture doit porter un masque de coins arrondis")
	var shader := mat.shader
	if shader == null:
		return _cleanup(ctx, "le masque doit avoir un shader")
	res = Runner.assert_true((shader.code as String).contains("radius"),
		"le shader doit arrondir les coins via un rayon")
	return _cleanup(ctx, res)

func test_rounded_corners_survive_zoom() -> Variant:
	## Le masque ne doit pas disparaitre en loupe (changement de stretch_mode
	## et de region) ni au changement de texture.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var tr: TextureRect = ctx["pip"]
	var mat := tr.material as ShaderMaterial
	pins.toggle_zoom()
	pins.zoom_by_scroll(3.0)
	var res: Variant = Runner.assert_true(tr.material == mat,
		"le masque doit rester en loupe")
	if _fail(res): return _cleanup(ctx, res)
	var img := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
	pins.on_window_texture_updated(1, ImageTexture.create_from_image(img))
	res = Runner.assert_true(tr.material == mat,
		"le masque doit survivre au changement de texture")
	return _cleanup(ctx, res)

func test_later_zoom_keeps_user_value() -> Variant:
	## Le 2x est une INITIALISATION, pas une valeur imposée : une fois le
	## zoom choisi par l'utilisateur, les bascules suivantes ne doivent plus y
	## toucher, sinon on ne pourrait jamais revenir à 1x.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_by_scroll(20.0)
	pins.toggle_zoom()
	pins.toggle_zoom()
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_MAX,
		"une fois choisi, le zoom de l'utilisateur est conservé")
	pins.free()
	if _fail(res): return res
	return true

func test_unpin_resets_first_zoom() -> Variant:
	## Une fenêtre épinglée différente est un PiP différent : son premier
	## passage en loupe repart de 2x, pas du zoom laissé sur l'autre.
	var pins = Pins.new()
	pins.pinned_windows[42] = null
	pins.toggle_zoom()
	pins.zoom_by_scroll(20.0)
	pins.unpin(42)
	pins.pinned_windows[43] = null
	pins.toggle_zoom()
	var res: Variant = Runner.assert_eq(pins.zoom_factor, Pins.ZOOM_FIRST,
		"un nouveau PiP repart de 2x à son premier passage en loupe")
	pins.free()
	if _fail(res): return res
	return true

func test_zoom_view_persists_after_leaving_zoom_mode() -> Variant:
	## Le zoom est une propriété de la fenêtre épinglée, pas du mode : en
	## sortant du mode loupe le PiP doit RESTER agrandi, pas revenir à la
	## fenêtre entière. C'est tout l'intérêt de quitter la loupe sans perdre son
	## inspection (on continue de marcher avec le PiP agrandi).
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var tr: TextureRect = ctx["pip"]
	var atlas: AtlasTexture = ctx["atlas"]
	var tex: Texture2D = ctx["tex"]
	pins.toggle_zoom()
	var zoomed := atlas.region.size
	var res: Variant = Runner.assert_true(zoomed.x < tex.get_size().x,
		"la loupe doit agrandir la vue")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_eq(tr.stretch_mode, TextureRect.STRETCH_SCALE,
		"la vue agrandie doit rester en STRETCH_SCALE")
	if _fail(res): return _cleanup(ctx, res)
	pins.toggle_zoom()
	res = _assert_approx_v(atlas.region.size, zoomed,
		"la vue doit rester agrandie en sortant du mode loupe")
	return _cleanup(ctx, res)

func test_new_pin_starts_unzoomed() -> Variant:
	## Avant tout passage en loupe, le PiP rend la fenêtre entière letterboxée
	## — le comportement d'origine, inchangé.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var tr: TextureRect = ctx["pip"]
	var atlas: AtlasTexture = ctx["atlas"]
	var tex: Texture2D = ctx["tex"]
	var res: Variant = Runner.assert_eq(atlas.region, Rect2(Vector2.ZERO, tex.get_size()),
		"un PiP neuf doit afficher la fenêtre entière")
	if _fail(res): return _cleanup(ctx, res)
	res = Runner.assert_eq(tr.stretch_mode, TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
		"un PiP neuf doit rester letterboxé")
	return _cleanup(ctx, res)

func test_zoom_region_survives_unknown_box_ratio() -> Variant:
	## Si le PiP n'est pas encore dimensionné (PIN_SIZE encore nul avant
	## setup()), le ratio de la boîte vaut 0/0. Sans garde-fou, l'ajustement
	## de ratio produirait un rect non fini — affiché en texture cassée. On doit
	## donc sauter l'ajustement et TOUT DE MÊME agrandir.
	var r := Pins.zoom_region(Vector2(1920, 1080), 2.0, Vector2(0.5, 0.5), NAN)
	var res: Variant = Runner.assert_true(is_finite(r.size.x) and is_finite(r.size.y),
		"un ratio de boîte inconnu ne doit pas produire un rect NaN")
	if _fail(res): return res
	res = Runner.assert_true(r.size.x < 1920.0 and r.size.y < 1080.0,
		"l'agrandissement doit rester appliqué même sans ratio")
	return res

func test_zoom_region_rejects_empty_texture() -> Variant:
	## Une texture inexistante (0x0) ne doit pas non plus remonter de ratio
	## indéfini : on renvoie un rect vide, que l'appelant sait ignorer.
	var r := Pins.zoom_region(Vector2.ZERO, 2.0, Vector2(0.5, 0.5), ASPECT)
	var res: Variant = Runner.assert_eq(r, Rect2(Vector2.ZERO, Vector2.ZERO),
		"une texture vide doit donner un rect vide")
	return res

func test_mouse_drag_pans_through_the_real_input_path() -> Variant:
	## Couvre le câblage complet (evenement -> _handle_zoom_input ->
	## _current_region_size -> pan_by) et pas seulement pan_by appele a la
	## main. _current_region_size doit renvoyer EXACTEMENT la region du zoom
	## courant : c'est ce qui garantit que la souris et le stick recadrent a la
	## meme vitesse. Un quart de largeur de region = un quart de pan.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var tex: Texture2D = ctx["tex"]
	pins.toggle_zoom()
	pins.zoom_pan = Vector2.ZERO
	var region := Pins.zoom_region(tex.get_size(), pins.zoom_factor, pins.zoom_pan, ASPECT)
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(region.size.x * 0.25, 0.0)
	pins._input(ev)
	var res: Variant = Runner.assert_approx(pins.zoom_pan.x, 0.25, 0.01,
		"un quart de largeur de region doit avancer d'un quart de pan")
	return _cleanup(ctx, res)

# ── Maintien des touches de zoom (LB/RB) ───────────────────────────────

func test_scroll_hold_does_not_double_the_tap() -> Variant:
	## L'appui donne DEJA un cran via l'evenement (_handle_zoom_input). Le
	## maintien ne doit pas le redoubler : il arme un delai.
	var pins = Pins.new()
	var notches: float = pins._advance_scroll_hold(1.0, 0.016)
	var res: Variant = Runner.assert_approx(notches, 0.0, 0.0001,
		"le premier frame d'un maintien ne doit pas craner une seconde fois")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_hold_is_silent_during_the_delay() -> Variant:
	## Une pression longue doit d'abord donner UN cran et rien de plus pendant
	## le delai, sinon on ne peut pas s'arreter sur le bon niveau.
	var pins = Pins.new()
	pins._advance_scroll_hold(1.0, 0.016)
	var res: Variant = Runner.assert_approx(
		pins._advance_scroll_hold(1.0, Pins.ZOOM_HOLD_DELAY * 0.5), 0.0, 0.0001,
		"rien pendant le delai de maintien")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_hold_ramps_after_the_delay() -> Variant:
	## Passe le delai, le maintien cran en continu et PROPORTIONNELLEMENT au
	## temps ecoule (un zoom continu), pas en salve de crans.
	var pins = Pins.new()
	pins._advance_scroll_hold(1.0, 0.016)
	pins._advance_scroll_hold(1.0, Pins.ZOOM_HOLD_DELAY)
	var notches: float = pins._advance_scroll_hold(1.0, 0.5)
	var res: Variant = Runner.assert_approx(notches, Pins.ZOOM_HOLD_RATE * 0.5, 0.0001,
		"apres le delai, la rampe doit suivre ZOOM_HOLD_RATE")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_hold_direction_is_signed() -> Variant:
	## RB (scroll_down) doit DEZOOMER : les crans sont negatifs.
	var pins = Pins.new()
	pins._advance_scroll_hold(-1.0, 0.016)
	pins._advance_scroll_hold(-1.0, Pins.ZOOM_HOLD_DELAY)
	var notches: float = pins._advance_scroll_hold(-1.0, 0.5)
	var res: Variant = Runner.assert_approx(notches, -Pins.ZOOM_HOLD_RATE * 0.5, 0.0001,
		"scroll_down doit dezoomer (crans negatifs)")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_hold_release_rearms_the_delay() -> Variant:
	## Relacher puis reappliquer doit redonner UN cran puis rearmer le delai,
	## pas repartir en rampe immediate.
	var pins = Pins.new()
	pins._advance_scroll_hold(1.0, 0.016)
	pins._advance_scroll_hold(1.0, Pins.ZOOM_HOLD_DELAY)
	pins._advance_scroll_hold(1.0, 0.1)
	pins._advance_scroll_hold(0.0, 0.016)
	var res: Variant = Runner.assert_approx(pins._advance_scroll_hold(1.0, 0.016), 0.0, 0.0001,
		"un nouvel appui doit repartir du delai")
	pins.free()
	if _fail(res): return res
	return true

func test_scroll_hold_direction_change_rearms_the_delay() -> Variant:
	## Inverser LB/RB en cours de maintien ne doit pas craner dans la mauvaise
	## direction : on rearme aussi.
	var pins = Pins.new()
	pins._advance_scroll_hold(1.0, 0.016)
	pins._advance_scroll_hold(1.0, Pins.ZOOM_HOLD_DELAY)
	var res: Variant = Runner.assert_approx(pins._advance_scroll_hold(-1.0, 0.016), 0.0, 0.0001,
		"inverser le maintien doit rearmer le delai")
	pins.free()
	if _fail(res): return res
	return true

# ── Recadrage au stick ──────────────────────────────────────────────────

func test_stick_pan_is_dead_at_rest() -> Variant:
	## Un stick au repos ne doit surtout pas faire dériver le recadrage en
	## permanence : c'est le défaut classique du polled input.
	var res: Variant = Runner.assert_eq(Pins.stick_pan_vector(Vector2.ZERO, 0.2), Vector2.ZERO,
		"stick au repos = aucun mouvement")
	if _fail(res): return res
	res = Runner.assert_eq(Pins.stick_pan_vector(Vector2(0.05, 0.0), 0.2), Vector2.ZERO,
		"stick sous la zone morte = aucun mouvement")
	return res

func test_stick_pan_does_not_jump_at_deadzone_edge() -> Variant:
	## Juste au-dessus de la zone morte le mouvement doit être quasi nul. Si on
	## ne retrancheait pas la zone morte avant de renormaliser, le recadrage
	## bondirait de ~0.2 d'un coup dès que le stick frôle le seuil.
	var res: Variant = Runner.assert_true(Pins.stick_pan_vector(Vector2(0.21, 0.0), 0.2).length() < 0.02,
		"pas de saut au franchissement de la zone morte")
	return res

func test_stick_pan_reaches_full_speed() -> Variant:
	## Pleine deflection doit atteindre 1.0 : la zone morte ne doit rogner que
	## le début de course, pas l'amplitude utile.
	var res: Variant = Runner.assert_approx(Pins.stick_pan_vector(Vector2(1.0, 0.0), 0.2).length(),
		1.0, 0.01, "pleine déflexion doit atteindre 1.0")
	return res

func test_stick_pan_keeps_stick_direction() -> Variant:
	## Le recadrage doit suivre le doigt : on ne garde que l'amplitude, jamais la
	## direction. Un Y positif (stick vers le bas) doit rester vers le bas.
	var v := Pins.stick_pan_vector(Vector2(0.6, 0.8), 0.2)
	var res: Variant = _assert_approx_v(v.normalized(), Vector2(0.6, 0.8).normalized(),
		"la direction du stick doit être conservée")
	return res

func test_stick_pan_survives_absurd_deadzone() -> Variant:
	## Une zone morte >= 1 rendrait le retranchement impossible (division par
	## zéro). Elle est bornée à 0.99 : le contrat est « aucune valeur non finie,
	## amplitude dans [0..1] », PAS « inerte » — une zone morte aberrante doit
	## dégrader en « pas de zone morte » plutôt qu'en « recadrage mort », sinon
	## une mauvaise constante couperait la loupe au stick en silence.
	for dz in [1.0, 5.0, -1.0]:
		var v := Pins.stick_pan_vector(Vector2(1.0, 1.0), dz)
		var res: Variant = Runner.assert_true(is_finite(v.x) and is_finite(v.y),
			"zone morte %f ne doit pas produire de NaN" % dz)
		if _fail(res): return res
		res = Runner.assert_true(v.length() <= 1.0 + 0.001,
			"l'amplitude doit rester bornée à 1 (zone morte %f)" % dz)
		if _fail(res): return res
	return true

# ── Intégration manette : entrée « ZOOM PIN » du menu radial ──────────────

func test_has_pin_tracks_pin_state() -> Variant:
	## has_pin() est la forme « un pin est-il vivant » dont le menu radial a
	## besoin : le radial ne connaît pas pinned_windows et ne doit pas le
	## connaître, il ne demande qu'un booléen. On passe par le vrai pin()/
	## unpin() (donc un vrai PiP) pour couvrir l'API publique.
	var ctx: Variant = _make_pin()
	if ctx is String: return ctx
	var pins: Node3D = ctx["pins"]
	var res: Variant = Runner.assert_true(pins.has_pin(),
		"un PiP créé compte comme pin actif")
	if _fail(res): return _cleanup(ctx, res)
	pins.unpin(1)
	res = Runner.assert_true(not pins.has_pin(),
		"un pin retiré ne compte plus")
	return _cleanup(ctx, res)

func test_zoom_pin_item_hidden_without_pin() -> Variant:
	## Sans pin actif, ZOOM PIN n'a rien à basculer : il ne doit pas
	## apparaître, sinon le menu radial propose une action morte.
	for context in ["window", "fps"]:
		var items := _radial_items(false, context)
		var res: Variant = Runner.assert_eq(_count_action(items, "pin_zoom"), 0,
			"ZOOM PIN doit être absent du contexte « %s » sans pin" % context)
		if _fail(res): return res
	return true

func test_zoom_pin_item_shown_when_pin_active() -> Variant:
	## Avec un pin actif, ZOOM PIN apparaît UNE fois, en dernier : le
	## recalcul des angles de l'anneau ne décale donc pas les entrées
	## existantes quand un pin est ajouté ou retiré.
	for context in ["window", "fps"]:
		var items := _radial_items(true, context)
		var res: Variant = Runner.assert_eq(_count_action(items, "pin_zoom"), 1,
			"ZOOM PIN doit apparaître dans le contexte « %s »" % context)
		if _fail(res): return res
		res = Runner.assert_eq(items[-1].label, "ZOOM PIN",
			"ZOOM PIN doit être la dernière entrée (contexte « %s »)" % context)
		if _fail(res): return res
	return true

func test_window_radial_unchanged_without_pin() -> Variant:
	## Non-régression : le contexte « window » garde exactement ses 10 entrées
	## d'origine tant qu'aucun pin n'est actif. Si ce nombre bouge, l'anneau
	## change pour tout le monde, y compris ceux qui n'utilisent jamais le pin.
	var items := _radial_items(false, "window")
	var res: Variant = Runner.assert_eq(items.size(), 10,
		"le contexte « window » doit garder ses 10 entrées sans pin")
	if _fail(res): return res
	return true

func test_zoom_pin_item_absent_from_focus_and_binds() -> Variant:
	## Meme avec un pin actif, ZOOM PIN n'a rien à faire dans « focus » (on est
	## deja en plein ecran sur la fenetre) ni dans « binds » (liste de
	## raccourcis, pas d'actions de fenetre).
	var focus_items := _radial_items(true, "focus")
	var res: Variant = Runner.assert_eq(_count_action(focus_items, "pin_zoom"), 0,
		"ZOOM PIN ne doit pas polluer le contexte « focus »")
	if _fail(res): return res
	var menu := Radial.new()
	menu.pin_active = true
	menu._build_items("binds", -1, [{"command": "ping", "code": 80, "type": "key"}])
	var binds_items: Array = menu._items.duplicate(true)
	menu.free()
	res = Runner.assert_eq(_count_action(binds_items, "pin_zoom"), 0,
		"ZOOM PIN ne doit pas polluer le contexte « binds »")
	return res

# ── Helpers ─────────────────────────────────────────────────────────────

## Construit la liste d'entrées du radial pour un contexte et un état de pin
## donnés. Le menu n'est jamais ajouté à l'arbre : _build_items ne touche que
## _items, on évite ainsi _ready (UITheme, SystemFont) sans avoir à le Dispose.
func _radial_items(pin_active: bool, context: String) -> Array:
	var menu := Radial.new()
	menu.pin_active = pin_active
	menu._build_items(context, -1, [])
	var items: Array = menu._items.duplicate(true)
	menu.free()
	return items

func _count_action(items: Array, action: String) -> int:
	var n := 0
	for entry in items:
		if String(entry.get("action", "")) == action:
			n += 1
	return n

## Runner.assert_* renvoie true en cas de succès, un String porte-message
## sinon. `res != true` ne compile pas de façon fiable ici : GDScript restreint
## `res` à String dès qu'on le réaffecte depuis une assertion.
func _fail(res: Variant) -> bool:
	return res is String

# Construit un pins avec un vrai PiP (CanvasLayer + TextureRect 1920x1080).
func _make_pin() -> Variant:
	var ui := CanvasLayer.new()
	get_tree().root.add_child(ui)
	var pins = Pins.new()
	get_tree().root.add_child(pins)
	pins.ui = ui
	# PIN_SIZE est calculée dans setup() depuis le viewport — que le runner
	# synchrone ne fournit pas (il vaut 1920x1920 en headless, pas 16/9). On
	# impose donc la taille réelle du PiP, sinon aspect = 0/0 = NaN et le
	# recadrage produit un rect non fini : les assertions de ratio et de
	# centrage deviendraient insensées (et passeraient à vide).
	pins.PIN_SIZE = Vector2(640, 360)
	# _process lit focus.focus_fullscreen_id : un Factice evite le bruit sans
	# reproduire tout le mode focus.
	var focus_stub := Node3D.new()
	focus_stub.set_script(Pins)
	pins.focus = focus_stub
	var img := Image.create(1920, 1080, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	pins.pin(1, tex)
	if not pins.pinned_windows.has(1):
		return "le PiP n'a pas été créé"
	var tr := (pins.pinned_windows[1] as Control).get_child(0) as TextureRect
	if tr == null:
		return "le PiP n'a pas de TextureRect"
	var atlas := tr.texture as AtlasTexture
	if atlas == null:
		return "le TextureRect du PiP doit porter un AtlasTexture (recadrage)"
	return {"pins": pins, "pip": tr, "border": pins.pinned_windows[1],
		"atlas": atlas, "tex": tex, "ui": ui, "focus": focus_stub}

func _cleanup(ctx, res) -> Variant:
	(ctx["focus"] as Node).free()
	(ctx["pins"] as Node).free()
	(ctx["ui"] as Node).free()
	return res

func _assert_approx_v(got: Vector2, want: Vector2, msg: String) -> Variant:
	var res: Variant = Runner.assert_approx(got.x, want.x, 0.01, msg + " (x)")
	if _fail(res): return res
	res = Runner.assert_approx(got.y, want.y, 0.01, msg + " (y)")
	if _fail(res): return res
	return true

func _assert_rect(got: Rect2, want: Rect2, msg: String) -> Variant:
	var res: Variant = _assert_approx_v(got.position, want.position, msg + " position")
	if _fail(res): return res
	res = _assert_approx_v(got.size, want.size, msg + " taille")
	if _fail(res): return res
	return true
