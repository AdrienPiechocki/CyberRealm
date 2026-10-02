extends Node
## Tests de la barre de titre du mode focus (focus_mode.gd). En mode focus les
## fenêtres sont dessinées en 2D par un TextureRect, donc la décoration 3D des
## MeshInstance3D n'est pas visible : la barre doit puiser sa bande « top » dans
## le MÊME loader SVG que la 3D, tuilée comme elle (cf. le correctif de rendu
## explicite + tuile des bords), et retomber sur l'aplat historique si l'asset
## manque.

const Runner := preload("res://tests/runner.gd")
const FocusScript := preload("res://scripts/windows/focus_mode.gd")
const Decorations := preload("res://scripts/ui/window_decorations.gd")
const WindowsStub := preload("res://tests/fixtures/windows_stub.gd")

var focus: Node3D

func _setup() -> Variant:
	focus = Node3D.new()
	focus.set_script(FocusScript)
	get_tree().root.add_child(focus)
	return true

func _teardown() -> void:
	if focus != null and is_instance_valid(focus):
		focus.free()
	focus = null

## Un stylebox n'est pas une valeur comparable : on compare ce qui compte
## pour le rendu, pas l'identite de l'objet.
## observé) : on compare ce qui compte pour le rendu, pas l'identité.
func _fail(r) -> bool:
	if r is String:
		return true
	if r != null and not bool(r):
		return true
	return false

func test_barre_utilise_la_bande_svg_du_haut() -> Variant:
	if _setup() != true:
		return "setup"
	var atlas: Texture2D = Decorations.border_piece("top")
	if atlas == null:
		# Pas d'asset dans cet environnement : le test de repli couvre ce cas.
		_teardown()
		return true
	var sb: StyleBox = FocusScript.titlebar_style(atlas)
	var r = Runner.assert_true(sb != null, "la bande doit produire un StyleBox")
	if _fail(r):
		return r
	r = Runner.assert_true(sb is StyleBoxTexture,
		"la barre doit utiliser la bande SVG, pas un aplat")
	if _fail(r):
		return r
	r = Runner.assert_eq((sb as StyleBoxTexture).texture, atlas,
		"le stylebox doit porter EXACTEMENT l'atlas renvoyé par le loader")
	if _fail(r):
		return r
	# Tuilage horizontal, et non étirement : la bande fait 292 px dans le SVG et
	# la barre peut faire 1000 px. Étirer déformerait le motif d'un facteur 3.4,
	# exactement le défaut corrigé en 3D.
	r = Runner.assert_eq((sb as StyleBoxTexture).axis_stretch_horizontal,
		StyleBoxTexture.AXIS_STRETCH_MODE_TILE,
		"la bande doit se RÉPÉTER en largeur, pas s'étirer")
	if _fail(r):
		return r
	# Garde-fou : si le tuilage repartait de l'atlas ENTIER, les coins et les
	# côtés du 9-patch réapparaîtraient au milieu de la barre. La tuile doit
	# donc faire la largeur de la BANDE, strictement plus étroite que le
	# border.svg complet.
	if atlas is AtlasTexture:
		var full: Texture2D = (atlas as AtlasTexture).atlas
		r = Runner.assert_true((sb as StyleBoxTexture).texture.get_size().x \
			< full.get_size().x,
			"la tuile doit être la bande seule, pas l'atlas complet")
		if _fail(r):
			return r
	_teardown()
	return true

func test_sans_asset_la_barre_retombe_sur_l_aplat() -> Variant:
	if _setup() != true:
		return "setup"
	# Texture absente (SVG manquant) : le repli historique doit tenir, sinon la
	# fenêtre se retrouve SANS barre en focus alors que le client n'a rien demandé.
	var sb: StyleBox = FocusScript.titlebar_style(null)
	var r = Runner.assert_true(sb is StyleBoxFlat,
		"sans asset, la barre doit rester un StyleBoxFlat")
	if _fail(r):
		return r
	r = Runner.assert_eq((sb as StyleBoxFlat).bg_color, FocusScript.FOCUS_TITLEBAR_BG,
		"et garder la couleur historique")
	if _fail(r):
		return r
	_teardown()
	return true

func test_la_bande_ne_recouvre_jamais_le_contenu() -> Variant:
	if _setup() != true:
		return "setup"
	# La barre se pose AU-DESSUS du contenu affiché ; sa hauteur vient de la
	# métrique `titlebar_height` du JSON, pas d'une constante codée en dur, sinon
	# la bande SVG (20 px) serait rognée ou étirée pour remplir 32 px.
	var r = Runner.assert_approx(FocusScript.titlebar_h(),
		float(Decorations.metrics().get("titlebar_height", 0.0)), 0.001,
		"la hauteur de barre doit suivre titlebar_height du JSON")
	if _fail(r):
		return r
	_teardown()
	return true

## Monte une fenêtre de la pile comme le fait `enter_focus` : overlay 2D sous
## un CanvasLayer, entrée dans `focus_stack`, et un stub de `windows` pour les
## tables dont `_sync_title_bar` a besoin.
func _mount_stack(id: int, tex_size: Vector2) -> Panel:
	focus.ui = CanvasLayer.new()
	get_tree().root.add_child(focus.ui)
	var rect := TextureRect.new()
	var img := Image.create_empty(int(tex_size.x), int(tex_size.y), false,
		Image.FORMAT_RGBA8)
	rect.texture = ImageTexture.create_from_image(img)
	rect.size = tex_size
	focus.ui.add_child(rect)
	focus.focus_rects[id] = rect
	focus.focus_stack = [id]
	focus.windows = WindowsStub.new()
	focus.windows.window_titles[id] = "Une fenetre"
	focus.windows.window_server_side[id] = true
	focus._ensure_title_bar(id)
	return focus.focus_title_bars[id] as Panel

func test_le_stylebox_suit_la_sync_pour_voir_un_asset_reedite() -> Variant:
	if _setup() != true:
		return "setup"
	var bar := _mount_stack(1, Vector2(400.0, 300.0))
	if _fail(Runner.assert_true(bar != null, "la barre doit etre creee")):
		return "la barre doit etre creee"
	if _fail(Runner.assert_true(bar.visible,
		"la barre doit etre visible pour une fenetre de la pile")):
		return "la barre doit etre visible"
	# Stylebar typiquement perime : on force un aplat, comme si le SVG avait ete
	# remplace (ou supprime) depuis la creation de la barre.
	bar.add_theme_stylebox_override("panel", StyleBoxFlat.new())
	focus._sync_title_bar(1)
	# Sans asset, le repli doit rester un StyleBoxFlat : le test accepte les
	# deux, il verifie surtout que la sync RAFRAICHIT le stylebox au lieu de
	# laisser un aplat perime en place indefiniment.
	var is_fresh := bar.get_theme_stylebox("panel") is StyleBoxTexture
	if Decorations.border_piece("top") == null:
		return true
	if _fail(Runner.assert_true(is_fresh,
		"la sync doit reappliquer le stylebox, pas laisser un aplat perime")):
		return "la sync doit reappliquer le stylebox"
	_teardown()
	return true
