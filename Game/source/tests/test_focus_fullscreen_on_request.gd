extends Node
## Tests : le mode focus passe une fenêtre en plein ecran UNIQUEMENT
## si le client l'a demandee. Reaction en direct sur transition.

const Runner := preload("res://tests/runner.gd")
const FocusScript := preload("res://scripts/windows/focus_mode.gd")
const WindowsStub := preload("res://tests/fixtures/windows_stub.gd")
const CompStub := preload("res://tests/fixtures/focus_compositor_stub.gd")
const PlayerStub := preload("res://tests/fixtures/player_stub.gd")

var focus
var comp: Node
var winstub: Node3D
var ui: CanvasLayer
var player

func _setup() -> Variant:
	focus = Node3D.new()
	focus.set_script(FocusScript)
	get_tree().root.add_child(focus)
	comp = CompStub.new()
	winstub = WindowsStub.new()
	# setup() et enter_focus() ajoutent leurs TextureRect dans `ui` : un vrai
	# CanvasLayer est requis, `null` interromprait enter_focus avant la règle
	# fullscreen (et les tests passeraient pour la mauvaise raison).
	ui = CanvasLayer.new()
	get_tree().root.add_child(ui)
	# enter_focus écrit player.focus_mode_active à la première entrée : sans
	# player réel, la fonction s'interrompt AVANT _activate_window et les tests
	# passent pour la mauvaise raison.
	player = PlayerStub.new()
	get_tree().root.add_child(player)
	focus.setup(comp, player, ui, winstub, null)
	return true

func _teardown() -> void:
	if focus != null and is_instance_valid(focus):
		focus.free()
	focus = null
	if comp != null and is_instance_valid(comp):
		comp.free()
	comp = null
	if winstub != null and is_instance_valid(winstub):
		winstub.free()
	winstub = null
	if ui != null and is_instance_valid(ui):
		ui.free()
	ui = null
	if player != null and is_instance_valid(player):
		player.free()
	player = null

func _fail(r) -> bool:
	if r is String: return true
	if r != null and not bool(r): return true
	return false

## Entree en focus : fenêtre sans demande → focus_fullscreen_id reste -1
func test_entree_sans_demande_pas_de_fullscreen() -> Variant:
	if _setup() != true: return "setup"
	var id := 10
	winstub.ensure_quad(id, "App", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	focus.enter_focus(id)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, -1,
		"sans demande, aucune fenêtre ne doit être forcee en fullscreen")
	if _fail(r): return r
	r = Runner.assert_eq(comp.fullscreen_calls.size(), 0,
		"aucun appel set_window_fullscreen a l'entree sans demande")
	_teardown()
	return true

## Entree en focus : fenêtre avec demande → fullscreen applique
func test_entree_avec_demande_fullscreen() -> Variant:
	if _setup() != true: return "setup"
	var id := 11
	winstub.ensure_quad(id, "Video", "app", Vector2(1280, 720))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	focus.enter_focus(id)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, id,
		"avec demande, la fenêtre focusee devient fullscreen")
	if _fail(r): return r
	r = Runner.assert_true(comp.fullscreen_calls.size() >= 1,
		"set_window_fullscreen doit être appele a l'entree avec demande")
	if _fail(r): return r
	var first = comp.fullscreen_calls[0]
	r = Runner.assert_eq(first[0], id, "appel sur le bon id")
	if _fail(r): return r
	r = Runner.assert_eq(first[1], true, "appel avec true")
	if _fail(r): return r
	_teardown()
	return true

## Reaction en direct : demande survient PENDANT la session → bascule
func test_reaction_directe_demande_pendant_session() -> Variant:
	if _setup() != true: return "setup"
	var id := 20
	winstub.ensure_quad(id, "Player", "app", Vector2(640, 360))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	focus.enter_focus(id)
	var calls0 = comp.fullscreen_calls.size()
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	if focus.has_method("_process"):
		focus._process(0.016)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, id,
		"la demande en direct doit activer le fullscreen")
	if _fail(r): return r
	r = Runner.assert_true(comp.fullscreen_calls.size() > calls0,
		"transition demande → true doit appeler set_window_fullscreen")
	if _fail(r): return r
	_teardown()
	return true

## Reaction en direct : annulation pendant session → retour taille naturelle
## L'annulation du fullscreen par la fenêtre ACTIVE ne doit PAS lui rendre une
## barre de titre : elle redevient une fenêtre de pile, pas la fenêtre active.
## Le bug : _apply_fullscreen_request(false) faisait _ensure_title_bar(id) sans
## vérifier si id est la fenêtre active.
func test_annulation_fullscreen_active_ne_rend_pas_de_barre() -> Variant:
	if _setup() != true: return "setup"
	var id := 22
	winstub.ensure_quad(id, "Player", "app", Vector2(640, 360))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	focus.enter_focus(id)
	# En fullscreen : pas de barre (déjà confirmé par test_entree_avec_demande)
	var r = Runner.assert_true(not _has_bar(id), "fullscreen = pas de barre")
	if _fail(r): return r
	# Annulation en cours de session
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	if focus.has_method("_process"):
		focus._process(0.016)
	r = Runner.assert_eq(focus.focus_fullscreen_id, -1,
		"le fullscreen doit être levé")
	if _fail(r): return r
	r = Runner.assert_true(not _has_bar(id),
		"après annulation, la fenêtre ACTIVE ne doit toujours pas avoir de barre")
	if _fail(r): return r
	_teardown()
	return true

## Le cycle complet : fenêtre de pile derrière, active sans barre, et chaque
## bascule de fullscreen préserve l'invariant (active sans barre, pile avec).
func test_invariant_barre_preserve_pendant_bascule_fullscreen() -> Variant:
	if _setup() != true: return "setup"
	var a := 30
	var b := 31
	winstub.ensure_quad(a, "Arriere", "app", Vector2(640, 360))
	winstub.ensure_quad(b, "Avant", "app", Vector2(640, 360))
	focus.enter_focus(a)
	focus.enter_focus(b)
	# b active sans barre, a en pile avec barre
	var r = Runner.assert_true(not _has_bar(b), "b active sans barre")
	if _fail(r): return r
	r = Runner.assert_true(_has_bar(a), "a en pile garde sa barre")
	if _fail(r): return r
	# b demande le fullscreen
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(b, true)
	if focus.has_method("_process"):
		focus._process(0.016)
	r = Runner.assert_eq(focus.focus_fullscreen_id, b, "b fullscreen")
	if _fail(r): return r
	r = Runner.assert_true(not _has_bar(b), "b fullscreen sans barre")
	if _fail(r): return r
	# b annule
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(b, false)
	if focus.has_method("_process"):
		focus._process(0.016)
	r = Runner.assert_eq(focus.focus_fullscreen_id, -1, "b plus fullscreen")
	if _fail(r): return r
	r = Runner.assert_true(not _has_bar(b), "b active toujours sans barre")
	if _fail(r): return r
	r = Runner.assert_true(_has_bar(a), "a en pile toujours avec barre")
	if _fail(r): return r
	_teardown()
	return true

func test_reaction_directe_annulation_pendant_session() -> Variant:
	if _setup() != true: return "setup"
	var id := 21
	winstub.ensure_quad(id, "Player", "app", Vector2(640, 360))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	focus.enter_focus(id)
	var calls0 = comp.fullscreen_calls.size()
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	if focus.has_method("_process"):
		focus._process(0.016)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, -1,
		"l'annulation doit retirer le fullscreen")
	if _fail(r): return r
	r = Runner.assert_true(comp.fullscreen_calls.size() > calls0,
		"transition true→false doit appeler set_window_fullscreen(false)")
	if _fail(r): return r
	var last = comp.fullscreen_calls[comp.fullscreen_calls.size()-1]
	r = Runner.assert_eq(last[0], id)
	if _fail(r): return r
	r = Runner.assert_eq(last[1], false)
	if _fail(r): return r
	_teardown()
	return true

## Frame stable : aucun appel supplementaire sur frame stable
func test_zero_appel_sur_frame_stable() -> Variant:
	if _setup() != true: return "setup"
	var id := 30
	winstub.ensure_quad(id, "App", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	focus.enter_focus(id)
	var calls_after_enter = comp.fullscreen_calls.size()
	if focus.has_method("_process"):
		focus._process(0.016)
		focus._process(0.016)
		focus._process(0.016)
	var r = Runner.assert_eq(comp.fullscreen_calls.size(), calls_after_enter,
		"aucun appel sur frame stable")
	if _fail(r): return r
	_teardown()
	return true

## Le piège de la boucle : la demande arrive par le chemin live (_process),
## la bascule se fait UNE fois, puis les frames suivantes ne doivent plus
## rien envoyer. C'est le test qui protège du flood de configure par frame.
func test_idempotence_apres_bascale_live() -> Variant:
	if _setup() != true: return "setup"
	var id := 31
	winstub.ensure_quad(id, "App", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	focus.enter_focus(id)
	var calls_before = comp.fullscreen_calls.size()
	# La bascule live : une seule frame doit produire UN appel (true)
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, true)
	if focus.has_method("_process"):
		focus._process(0.016)
	var r = Runner.assert_eq(comp.fullscreen_calls.size(), calls_before + 1,
		"la bascule live doit produire exactement UN appel")
	if _fail(r): return r
	var calls_after_bascule = comp.fullscreen_calls.size()
	# Puis dix frames stables : plus rien
	if focus.has_method("_process"):
		for i in range(10):
			focus._process(0.016)
	r = Runner.assert_eq(comp.fullscreen_calls.size(), calls_after_bascule,
		"dix frames stables après bascule : aucun appel supplémentaire")
	if _fail(r): return r
	_teardown()
	return true

func _has_bar(id: int) -> bool:
	return focus.focus_title_bars.has(id) \
		and is_instance_valid(focus.focus_title_bars[id])

## La fenêtre ACTIVE n'affiche aucune barre de titre : elle est au premier
## plan, l'utilisateur interagit avec elle, une barre serait un leurre. Les
## fenêtres DERRIÈRE elle dans la pile gardent la leur.
func test_fenetre_active_sans_barre() -> Variant:
	if _setup() != true: return "setup"
	var id := 60
	winstub.ensure_quad(id, "Active", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	focus.enter_focus(id)
	var r = Runner.assert_true(not _has_bar(id),
		"la fenêtre active ne doit avoir aucune barre de titre")
	if _fail(r): return r
	_teardown()
	return true

## Une fenêtre qui n'est PAS active conserve sa barre : elle fait partie de
## la pile et doit rester identifiable/déplaçable.
func test_fenetre_de_pile_garde_sa_barre() -> Variant:
	if _setup() != true: return "setup"
	var a := 61
	var b := 62
	winstub.ensure_quad(a, "Arriere", "app", Vector2(800, 600))
	winstub.ensure_quad(b, "Active", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(a, false)
		comp.request_fullscreen(b, false)
	focus.enter_focus(a)
	focus.enter_focus(b)
	var r = Runner.assert_true(not _has_bar(b),
		"la fenêtre active (b) n'a pas de barre")
	if _fail(r): return r
	r = Runner.assert_true(_has_bar(a),
		"la fenêtre de pile (a) doit garder sa barre")
	if _fail(r): return r
	_teardown()
	return true

## Quand la fenêtre active quitte la pile, la suivante devient active et perd
## sa barre à son tour : il ne doit pas rester une barre orpheline sur
## l'ancienne active-now-inactive.
func test_pile_reste_sans_barre_apres_fermeture_active() -> Variant:
	if _setup() != true: return "setup"
	var a := 63
	var b := 64
	winstub.ensure_quad(a, "Arriere", "app", Vector2(800, 600))
	winstub.ensure_quad(b, "Active", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(a, false)
		comp.request_fullscreen(b, false)
	focus.enter_focus(a)
	focus.enter_focus(b)
	await focus.on_window_unmapped(b)
	var r = Runner.assert_true(not _has_bar(a),
		"la nouvelle active (a) doit avoir perdu sa barre")
	if _fail(r): return r
	_teardown()
	return true

## Le centrage compense d'une demi-hauteur de barre pour centrer barre+contenu.
## Sans barre (fenêtre active), ce décalage LA RENDRAIT trop basse. On mesure
## l'écart réel de position AVEC puis SANS barre sur la même fenêtre : il doit
## valoir exactement une demi-hauteur de barre. Si la garde était absente,
## le « sans barre » serait identique au « avec barre ».
func test_centrage_compense_seulement_si_barre() -> Variant:
	if _setup() != true: return "setup"
	var id := 65
	winstub.ensure_quad(id, "Active", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(id, false)
	focus.enter_focus(id)
	# Position de la fenêtre ACTIVE (sans barre, centrée sur son contenu seul)
	focus._refresh_rect_layout(id)
	var y_sans_barre: float = focus.focus_rects[id].position.y
	# On lui donne une barre et on relayout : le compensation doit la remonter
	# d'exactement une demi-hauteur de barre.
	focus._ensure_title_bar(id)
	focus._refresh_rect_layout(id)
	var y_avec_barre: float = focus.focus_rects[id].position.y
	# Le code ajoute la demi-hauteur (rect.position.y += titlebar_h * 0.5).
	var expected := y_sans_barre + FocusScript.titlebar_h() * 0.5
	var r = Runner.assert_approx(y_avec_barre, expected, 0.001,
		"avec barre, le contenu doit être remonté d'une demi-hauteur exacte")
	if _fail(r): return r
	# Et l'inverse : retirer la barre doit supprimer le décalage, pas le garder.
	focus._remove_title_bar(id)
	focus._refresh_rect_layout(id)
	var y_retour: float = focus.focus_rects[id].position.y
	r = Runner.assert_approx(y_retour, y_sans_barre, 0.001,
		"sans barre, le décalage doit disparaître (pas de fenêtre trop basse)")
	if _fail(r): return r
	_teardown()
	return true

## Promotion : fenêtre fullscreen quitte pile → nouveau sommet promu SEULEMENT s'il a demande
func test_promotion_respecte_demande() -> Variant:
	if _setup() != true: return "setup"
	var top := 40
	var next := 41
	winstub.ensure_quad(top, "Top", "app", Vector2(800, 600))
	winstub.ensure_quad(next, "Next", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(top, true)
		comp.request_fullscreen(next, false)
	focus.enter_focus(top)
	focus.enter_focus(next)
	if focus.has_method("on_window_unmapped"):
		await focus.on_window_unmapped(top)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, -1,
		"ne pas promouvoir un sommet qui n'a pas demande le fullscreen")
	if _fail(r): return r
	_teardown()
	return true

## Promotion inverse : nouveau sommet demande → promu
func test_promotion_si_sommet_demande() -> Variant:
	if _setup() != true: return "setup"
	var top := 50
	var next := 51
	winstub.ensure_quad(top, "Top", "app", Vector2(800, 600))
	winstub.ensure_quad(next, "Next", "app", Vector2(800, 600))
	if comp.has_method("request_fullscreen"):
		comp.request_fullscreen(top, true)
		comp.request_fullscreen(next, true)
	focus.enter_focus(top)
	focus.enter_focus(next)
	if focus.has_method("on_window_unmapped"):
		await focus.on_window_unmapped(top)
	var r = Runner.assert_eq(focus.focus_fullscreen_id, next,
		"promouvoir le sommet s'il a demande le fullscreen")
	if _fail(r): return r
	_teardown()
	return true
