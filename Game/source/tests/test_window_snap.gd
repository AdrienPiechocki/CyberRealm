extends Node
## Tests du collage (snap) entre fenêtres 3D et de la rotation Y associée
## (windows_3d.gd).
##
## Régression couverte : une fenêtre n'a AUCUNE orientation stockée (c'est un
## billboard, `global_basis = cam.global_basis` est réécrit à chaque frame de
## grab), donc « tourner sur l'axe Y » n'était pas représentable. Le yaw est
## devenu un offset stocké, appliqué par-dessus la base caméra.
##
## La géométrie est isolée dans des fonctions STATIC PURES (même parti pris que
## pinned_windows.zoom_region) : aucune dépendance à la scène, testable en
## headless sans caméra, sans compositeur et sans arbre 3D.

const Runner = preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

# Demi-dimensions de référence des fixtures : 1.0 x 0.5, avec un titre-bandeau
# de 0.06 -> demi-hauteur visuelle (0.5 + 0.06) / 2 = 0.28.
const HALF := Vector2(0.5, 0.28)
const TITLEBAR := 0.06
# Position de la caméra du monde de test : sert d'origine aux rayons de drag.
const CAM := Vector3(0.0, 1.5, 0.0)

var win3d: Node3D
var player: Node3D

# ── Géométrie pure ─────────────────────────────────────────────────────

func test_a_full_snap_costs_a_reasonable_number_of_mouse_pixels() -> Variant:
	## RÉGRESSION DU BUG RÉEL. Le drag était en 1:1 pixel-écran, ce qui est
	## arithmétiquement inutilisable ici : une fenêtre 1920x1080 fait 3.56 m de
	## large, soit PLUS D'UNE LARGEUR D'ÉCRAN de mouvement à 2 m. En 1:1 il
	## fallait 1253 px de souris, et la caméra tournait de 144° sur le trajet —
	## le joueur voyait le monde tourner pendant que la fenêtre rampait de
	## 3 mm par pixel. On ne pouvait donc pas percevoir le déplacement latéral.
	##
	## Ce test fixe un BUDGET : un collage complet doit coûter moins de 400 px.
	## On mesure contre la HAUTEUR DE VIEWPORT DU JEU (project.godot), pas
	## celle du runner headless (~1919 px) : le coût en pixels est inversement
	## proportionnel à cette hauteur, donc utiliser celle du runner donnerait
	## un nombre sans rapport avec ce que vit le joueur.
	var wpp: float = Windows3DScript.pixels_to_world(
		SPAWN_DEPTH, GAME_FOV, GAME_VIEWPORT_HEIGHT)
	var cost: float = REAL_SIZE.x / wpp
	return Runner.assert_true(cost < 400.0,
		"un collage complet doit coûter < 400 px de souris, or il en coûte %d"
		% int(cost))

func test_visual_half_extent_counts_the_titlebar() -> Variant:
	## La barre de titre (0.06 m) vit AU-DESSUS du quad et n'est ni dans la boîte
	## de collision ni dans l'occulteur. Utiliser mesh.size.y seul ferait
	## dépasser le bord haut de la fenêtre de 6 cm, donc les fenêtres se
	## chevaucheraient d'autant en se collant verticalement.
	var half: Vector2 = Windows3DScript.visual_half_extent(Vector2(1.0, 0.5))
	var res: Variant = Runner.assert_approx(half.x, 0.5, 0.0001,
		"la demi-largeur ne doit pas être affectée par le titre-bandeau")
	if _fail(res): return res
	res = Runner.assert_approx(half.y, (0.5 + TITLEBAR) * 0.5, 0.0001,
		"la demi-hauteur visuelle doit inclure le titre-bandeau")
	return res

func test_visual_center_is_shifted_up_by_half_the_titlebar() -> Variant:
	## Le centre affiché n'est pas le centre du quad : le bandeau est au-dessus.
	## Coller deux fenêtres par leurs centres visuels les aligne réellement.
	var center: Vector3 = Windows3DScript.visual_center(
		Vector3(1.0, 2.0, 3.0), Vector3.UP)
	var res: Variant = Runner.assert_approx(center.y, 2.0 + TITLEBAR * 0.5, 0.0001,
		"le centre visuel doit être décalé vers le haut d'un demi-bandeau")
	if _fail(res): return res
	res = Runner.assert_approx(center.x, 1.0, 0.0001, "l'axe X ne doit pas bouger")
	return res

func _build_world() -> Variant:
	win3d = Node3D.new()
	win3d.set_script(Windows3DScript)
	player = Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0.0, 1.5, 0.0)
	player.add_child(cam)
	get_tree().root.add_child(player)
	get_tree().root.add_child(win3d)
	win3d.setup(null, player)
	win3d.on_window_mapped(7, "A", "app")
	win3d.on_window_mapped(8, "B", "app")
	if not win3d.quads.has(7) or not win3d.quads.has(8):
		return "les quads 7 et 8 n'ont pas été créés"
	# Tailles et positions maîtrisées : le spawn les empile et les taille via le
	# ratio de texture, ce qui rendrait les assertions de collage inexacts.
	for id in [7, 8]:
		var quad: MeshInstance3D = win3d.quads[id]
		(quad.mesh as QuadMesh).size = Vector2(1.0, 0.5)
		quad.global_position = Vector3(0.0, 1.5, -40.0)
	# Les zones suivent la taille du mesh : appelé ici parce que le test change
	# la taille APRÈS on_window_mapped (comme le fait le jeu au premier frame).
	for id in [7, 8]:
		win3d._sync_snap_zones(win3d.quads[id])
	return true

func _teardown() -> void:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()

# Déplace la fenêtre 7 jusqu'à `target` via _update_move.
# move_depth est déduit de la cible et delta vaut 0.1, donc le poids de lerp est
# exactement 1.0 : la position finale est la cible SANS approximation.
# (lerp n'a pas de clamp : un delta supérieur extrapole au-delà de la cible.)
# Une frame de déplacement COMPLÈTE, telle que le jeu la vit : la surveillance
# s'allume, le serveur physique recense les recouvrements, le déplacement est
# calculé, puis une seconde frame — c'est sur celle-ci que le collage peut enfin
# être constaté, puisqu'il dépend du recouvrement calculé par la précédente.
# Un seul _update_move() ne prouverait rien : le premier appel d'une saisie
# réelle ne peut pas non plus déclencher de collage.
func _tick_move(ray_dir: Vector3) -> void:
	# La surveillance est allumée par _update_move elle-même, comme en jeu :
	# l'allumer ici à la main masquerait le fait que le chemin réel s'en
	# charge, et une régression qui l'oublierait passerait inaperçue.
	await get_tree().physics_frame
	win3d._update_move(CAM, ray_dir, 0.1)
	await get_tree().physics_frame
	win3d._update_move(CAM, ray_dir, 0.1)

func _drag_7_to(target: Vector3) -> void:
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = CAM.distance_to(target)
	await _tick_move((target - CAM).normalized())

# Place la fenêtre 8 (cible de collage) à une position et une base données.
func _place_8(at: Vector3) -> void:
	var quad8: MeshInstance3D = win3d.quads[8]
	quad8.global_position = at
	quad8.global_basis = Basis.IDENTITY

func test_the_release_allowance_is_the_zone_itself() -> Variant:
	## Le collage étant un point fixe, une fenêtre calée ne peut plus
	## s'éloigner de sa zone par elle-même : c'est le POINTEUR qui décide du
	## lâcher. La tolérance n'est donc pas un seuil arbitraire, c'est la zone.
	## Au repos, les zones sont coïncidentes : tout jeu est la somme des deux
	## demi-boîtes.
	var half := Vector2(0.5, 0.28)
	var t: float = Windows3DScript.SNAP_ZONE_THICKNESS
	var slack: Vector3 = (Windows3DScript.snap_zone_size(half, "left")
		+ Windows3DScript.snap_zone_size(half, "right")) * 0.5
	var res: Variant = Runner.assert_approx(slack.x, t, 0.0001,
		"le jeu sur l'axe du collage doit valoir une épaisseur de zone")
	if _fail(res): return res
	res = Runner.assert_true(
		Windows3DScript.zones_overlap_after_shift(half, "left", half, "right",
			Vector3(t * 0.9, 0.0, 0.0)),
		"un tirage sous l'épaisseur doit maintenir le collage")
	if _fail(res): return res
	res = Runner.assert_true(
		not Windows3DScript.zones_overlap_after_shift(half, "left", half, "right",
			Vector3(t * 1.1, 0.0, 0.0)),
		"un tirage au-delà de l'épaisseur doit lâcher le collage")
	if _fail(res): return res
	# Glisser le long de la voisine reste possible : sur l'axe parallèle au
	# raccord, le jeu vaut les deux dimensions visibles, pas l'épaisseur.
	res = Runner.assert_true(
		Windows3DScript.zones_overlap_after_shift(half, "left", half, "right",
			Vector3(0.0, half.y, 0.0)),
		"faire coulisser la fenêtre le long de sa voisine doit rester possible")
	return res

func test_dragging_beside_a_window_snaps_flush_against_it() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	await _drag_7_to(Vector3(0.0, 1.5, -2.0) + Vector3(0.0999, 0.0, 0.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(snap.get("wid", -1), 8,
		"la fenêtre 7 doit se coller sur la fenêtre 8")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(String(snap.get("side", "")), "left",
		"en venant de la droite, la 7 doit se coller sur le côté gauche de la 8")
	if _fail(res):
		_teardown()
		return res
	# La cible du rayon n'était PAS le point de collage : la preuve que c'est
	# bien le snap qui a corrigé, et pas le rayon qui tombait juste.
	res = _assert_v((win3d.quads[7] as Node3D).global_position, Vector3(0.0, 1.5, -2.0),
		"la fenêtre doit être revenue exactement au bord de la 8")
	_teardown()
	return res

func test_dragging_under_a_window_stops_below_its_titlebar() -> Variant:
	## Même chose sur l'axe VERTICAL, seul côté où le titre-bandeau change le
	## résultat (il ajoute de la hauteur, pas de largeur). Le bord haut visible
	## de la fenêtre du bas doit s'arrêter sous la BARRE DE TITRE de celle du
	## dessus, pas sous son quad : sinon les deux images se chevauchent de 6 cm.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(0.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	# Cible brute 3 cm au-dessus du point de collage : c'est le SNAP qui doit
	# descendre la fenêtre jusqu'au bord, pas le rayon.
	await _drag_7_to(Vector3(0.0, 1.0, -2.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(String(snap.get("side", "")), "bottom",
		"en venant du dessous, la 7 doit se coller sous la 8")
	if _fail(res):
		_teardown()
		return res
	# 1.53 (centre visuel de la 8) - 0.56 (0.28 + 0.28 de demi-hauteurs
	# visuelles) - 0.03 (retour au quad sous son propre bandeau) = 0.94.
	res = _assert_v((win3d.quads[7] as Node3D).global_position, Vector3(0.0, 0.94, -2.0),
		"le haut visible de la 7 doit s'arrêter sous la barre de titre de la 8")
	_teardown()
	return res

func test_snap_ignores_a_small_depth_offset_and_makes_both_windows_coplanar() -> Variant:
	## RÉGRESSION : le collage ne doit pas être plat ET il doit corriger la
	## profondeur. Le drag 3D fige la fenêtre saisie sur une sphère de rayon
	## `move_depth` autour de la caméra, donc deux fenêtres voisines à l'écran
	## ne sont jamais exactement à la même profondeur — comparer des positions
	## 3D ne déclencherait le collage qu'une fois sur deux.
	##
	## Tolérance et correction sont les deux faces de la zone épaisse : 30 cm de
	## décalage rentrent dans l'épaisseur de 50 cm, donc le collage part, et le
	## calage — qui amène le centre de zone sur le centre de zone — laisse les
	## deux fenêtres COPLANAIRES. C'est ce qui rend le raccord exact au lieu
	## d'approximatif.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	# La 7 est 30 cm plus loin que la 8, mais à la même coordonnée X.
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -2.3)
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = 2.3
	# FORWARD, pas BACK : la fenêtre doit être amenée EN AVANT de la caméra,
	# là où la 8 se trouve.
	await _tick_move(Vector3.FORWARD)
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(snap.get("wid", -1), 8,
		"un décalage de profondeur sous l'épaisseur de zone doit snapper")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(String(snap.get("side", "")), "left",
		"la 7 doit se coller sur le côté gauche de la 8")
	if _fail(res):
		_teardown()
		return res
	# Le calage doit aussi RAMENER la fenêtre dans le plan de la cible : bord à
	# bord de 3D, sinon les deux images restent disjointes vues de biais.
	res = _assert_v((win3d.quads[7] as Node3D).global_position, Vector3(0.0, 1.5, -2.0),
		"le calage doit rendre les deux fenêtres coplanaires")
	_teardown()
	return res

func test_a_depth_gap_wider_than_the_zone_never_snaps() -> Variant:
	## Le corollaire, et il est volontaire : à 6 m l'une de l'autre en
	## profondeur, deux fenêtres ne sont PAS voisines en 3D. Les eer zones
	## sont attachées aux quads, donc elles ne se recouvrent pas, et le collage
	## ne part pas. Il le ferait si la détection reposait sur une distance —
	## le modèle VR impose qu'une fenêtre soit réellement à côté pour s'y
	## accrocher, sans téléportation à travers la pièce.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -8.0)
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = 8.0
	await _tick_move(Vector3.FORWARD)
	var res: Variant = Runner.assert_true(not win3d.snapped_to.has(7),
		"6 m de décalage en profondeur sont hors de portée des zones")
	_teardown()
	return res
func test_snap_is_exact_whatever_the_orientation_of_both_windows() -> Variant:
	## AVANT, le collage comparait des centres et des directions exprimés dans
	## le repère de la CIBLE : une voisine tournée de 45° rendait ce repère
	## faux, et la fenêtre se calait là où l'œil ne la voyait pas. Le test ne
	## pouvait vérifier qu'un cas particulier de base « périmée ».
	##
	## Les zones étant des ENFANTS des quads, la rotation est DÉJÀ dans la
	## géométrie : ce test tourne les deux fenêtres de 40° et exige le point de
	## calage exact, calculé à la main dans le repère tourné. C'est la propriété
	## qui rend le modèle VR correct, pas un cas particulier.
	var build: Variant = _build_world()
	if build != true:
		return build
	var yaw := deg_to_rad(40.0)
	var half := 0.5 # demi-largeur du quad de test
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = Basis(Vector3.UP, yaw)
	# La 7, elle, est LIBRE : elle suit donc la caméra, qui est droite. Seule
	# la voisine est tournée — et c'est bien la situation réelle, puisqu'une
	# fenêtre non collée n'a aucune raison de rester de travers.
	#
	# Calage attendu, À LA MAIN dans le repère tourné de la 8 : bord droit de
	# la 7 (donc +0.5 sur SON X droit, nonché) contre bord gauche de la 8
	# (donc -0.5 sur le X droit TOURNÉ de la 8). Les deux termes ne se
	# compensent pas, et le résultat n'est PAS (0.5, 1.5, -2) : c'est
	# exactement ce que l'ancien modèle, qui ignorait la rotation, produisait.
	# Les DEUX demi-largeurs se soustraient dans le MÊME repère tourné :
	# l'écart entre deux centres est une largeur de quad le long de l'axe
	# partagé. Soustraire la seconde en axes MONDE ne donnerait le bon résultat
	# que si les deux fenêtres étaient droites — d'où un attendu quidoubleait
	# puis triplait l'écart selon l'angle.
	var flush := Vector3(1.0, 1.5, -2.0) \
		- Vector3(half * 2.0, 0.0, 0.0).rotated(Vector3.UP, yaw)
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	# Cible brute 4 cm APRÈS le point de collage, le long du même axe : c'est
	# le SNAP qui doit ramener la fenêtre au bord exact, pas le viseur.
	await _drag_7_to(flush + Vector3(0.04, 0.0, 0.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(snap.get("wid", -1), 8,
		"deux fenêtres tournées de 40° doivent quand même se coller")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(String(snap.get("side", "")), "left",
		"le raccord doit se faire sur le côté gauche de la 8")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_position, flush,
		"le calage doit suivre la rotation des deux fenêtres")
	_teardown()
	return res
func test_dragging_beyond_the_zone_reach_does_not_snap() -> Variant:
	## Hors de portée des zones, AUCUN collage : sinon la fenêtre resterait
	## attachée dès qu'on la bouge d'un millimètre. La limite n'est plus un
	## seuil de distance mais l'épaisseur réelle de la zone (0.5 m) : 60 cm
	## d'écart entre bords met les centres de zone à 60 cm l'un de l'autre, donc
	## hors recouvrement.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	await _drag_7_to(Vector3(0.0, 1.5, -2.0) + Vector3(0.6, 0.0, 0.0))
	var res: Variant = Runner.assert_true(not win3d.snapped_to.has(7),
		"hors portée des zones, aucune fenêtre ne doit être collée")
	_teardown()
	return res
func test_a_window_never_snaps_to_itself() -> Variant:
	## Sans exclusion de soi-même, une fenêtre se colle à elle-même et se
	## téléporte vers son propre bord — même pire qu'un snap raté.
	##
	## Le test doit rendre cet auto-snap POSSIBLE, sinon il passe aussi bien avec
	## l'exclusion supprimée (faux vert) : avec la taille par défaut (1.0 x 0.5),
	## le côté haut/bas d'une fenêtre est à 0.56 m de son propre centre, bien
	## au-delà des 0.15 m de seuil. On rétrécit donc la fenêtre 7 jusqu'à ce que
	## son propre bord haut tombe à 0.11 m — sous le seuil — et on la place
	## exactement dessus. Si l'exclusion saute, elle se colle alors à elle-même.
	var build: Variant = _build_world()
	if build != true:
		return build
	# Demi-hauteur visuelle (0.05 + 0.06) / 2 = 0.055 ; côté haut de soi-même à
	# 2 * 0.055 = 0.11 m, soit sous les 0.15 m de SNAP_DISTANCE.
	(win3d.quads[7].mesh as QuadMesh).size = Vector2(0.1, 0.05)
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -2.0)
	# La 8 est loin : elle ne doit pas pouvoir servir de coupable à sa place.
	_place_8(Vector3(0.0, 1.5, -40.0))
	await _drag_7_to(Vector3(0.0, 1.5, -2.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_ne(int(snap.get("wid", -1)), 7,
		"une fenêtre ne doit jamais se coller à elle-même")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_true(snap.is_empty(),
		"sans autre fenêtre à portée, il ne doit y avoir aucun collage du tout")
	_teardown()
	return res

func _make_window_9() -> void:
	win3d.on_window_mapped(9, "C", "app")
	_resize(9, Vector2(1.0, 0.5))

# Deux appariements de zones pour la fenêtre 7, avec la 8 en premier. Les
#_RECORDEMENTS sont synthétiques : _choose_snap ne manipule que des identifiants
# et des orientations, jamais les Area3D elles-mêmes.
func _two_pairs() -> Array:
	return [
		{"our_wid": 7, "our_side": "top", "their_wid": 8, "their_side": "bottom"},
		{"our_wid": 7, "our_side": "top", "their_wid": 9, "their_side": "bottom"},
	]

func test_several_candidates_without_an_existing_link_do_not_snap() -> Variant:
	## Garde-fou central : deux voisins en même temps rendent la position
	## cible ambiguë, et le collage scintillerait d'une frame à l'autre entre
	## les deux. Sans lien EXISTANT entre les deux voisins, la règle des
	## 3 fenêtres n'a aucun groupe à analyser, donc aucun collage.
	var build: Variant = _build_world()
	if build != true:
		return build
	_make_window_9()
	win3d._store_basis(7, Basis.IDENTITY)
	win3d._store_basis(8, Basis(Vector3.UP, 0.4))
	win3d._store_basis(9, Basis(Vector3.UP, 0.9))
	var res: Variant = Runner.assert_true(win3d._choose_snap(_two_pairs()).is_empty(),
		"deux voisins sans lien entre eux ne doivent produire aucun collage")
	_teardown()
	return res

func test_the_three_window_rule_adopts_the_candidate_when_it_agrees_with_the_third() -> Variant:
	## A ≠ B, mais A == C : le groupe a une majorité qui porte sur A. La règle
	## impose alors d'aligner A sur B — c'est le SEUL cas où l'orientation
	## retenue n'est pas celle de B « par défaut », et donc celui qu'un
	## `adopt_basis_of` absent laisserait passer à côté.
	var build: Variant = _build_world()
	if build != true:
		return build
	_make_window_9()
	var basis_a := Basis(Vector3.UP, 0.4)
	win3d._store_basis(7, basis_a)
	win3d._store_basis(8, Basis(Vector3.UP, 0.9))
	win3d._store_basis(9, basis_a)
	# La 8 est DÉJÀ collée à la 9 : c'est le lien qui fait le groupe.
	win3d.snapped_to[8] = {"wid": 9, "side": "bottom", "our_side": "top"}
	var choice: Dictionary = win3d._choose_snap(_two_pairs())
	var res: Variant = Runner.assert_eq(int(choice.get("adopt_basis_of", -1)), 8,
		"A doit prendre l'orientation de B, seul B qui s'accorde avec C")
	if _fail(res):
		_teardown()
		return res
	win3d.active_window_id = 7
	win3d._set_snap(7, {"wid": 8, "side": "bottom", "our_side": "top",
		"adopt_basis_of": int(choice["adopt_basis_of"])})
	res = _assert_basis(win3d._stored_basis(7), Basis(Vector3.UP, 0.9),
		"l'orientation de la fenêtre saisie doit réellement avoir changé")
	_teardown()
	return res

func test_the_three_window_rule_keeps_the_driven_orientation_when_both_neighbours_agree() -> Variant:
	## A ≠ B et B == C : les deux voisins forment un bloc, et A n'en fait pas
	## partie. A garde donc SA rotation. C'est le cas que le défaut
	## `adopt_basis_of` absent trahissait : il adoptait B, c'est-à-dire
	## exactement l'inverse du verdict.
	var build: Variant = _build_world()
	if build != true:
		return build
	_make_window_9()
	var basis_a := Basis(Vector3.UP, 0.4)
	win3d._store_basis(7, basis_a)
	win3d._store_basis(8, Basis(Vector3.UP, 0.9))
	win3d._store_basis(9, Basis(Vector3.UP, 0.9))
	win3d.snapped_to[8] = {"wid": 9, "side": "bottom", "our_side": "top"}
	var choice: Dictionary = win3d._choose_snap(_two_pairs())
	var res: Variant = Runner.assert_eq(int(choice.get("adopt_basis_of", -1)), 7,
		"A doit conserver sa propre orientation quand B et C s'accordent")
	if _fail(res):
		_teardown()
		return res
	win3d.active_window_id = 7
	win3d._set_snap(7, {"wid": 8, "side": "bottom", "our_side": "top",
		"adopt_basis_of": int(choice["adopt_basis_of"])})
	res = _assert_basis(win3d._stored_basis(7), basis_a,
		"l'orientation de la fenêtre saisie doit être inchangée")
	_teardown()
	return res

func test_a_snap_holds_while_the_window_is_still_animating_towards_it() -> Variant:
	## RÉGRESSION DU BUG SIGNALÉ, et le test qui manquait.
	##
	## Tous les autres tests de snap font `_update_move(..., 0.1)`, soit un
	## poids de lerp de 10.0*0.1 = 1.0 : la fenêtre atteint sa position en UNE
	## frame, et n'a donc jamais d'état intermédiaire. En jeu le delta est
	## bien plus petit, la fenêtre met PLUSIEURS frames à rejoindre son point
	## de calage, et c'est là que ça casse.
	##
	## Le mécanisme : la fenêtre saisit est à cheval sur le bord de sa voisine.
	## On la fait tourner sur l'orientation de celle-ci — et les zones, qui
	## sont des enfants du quad, tournent avec. Pendant les frames où elle
	## n'est ENCORE ni à l'ancienne place ni à la nouvelle, ses zones ne
	## recouvrent plus la voisine. Le collage saute, la fenêtre repart face
	## caméra, et le cycle recommence : c'est le clignotement observé, et il
	## dure tant que le bouton est maintenu.
	##
	## On rejoue donc le régime réel : plusieurs frames, poids de lerp partial.
	var build: Variant = _build_world()
	if build != true:
		return build
	var turned := Basis(Vector3.UP, deg_to_rad(35.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	win3d.active_window_id = 7
	win3d.is_moving = true
	var flush := Vector3(1.0, 1.5, -2.0) \
		- Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(35.0))
	win3d.move_depth = CAM.distance_to(flush)
	var dir := (flush - CAM).normalized()
	# delta = 0.02 -> poids de lerp 0.2 : convergence en ~15 frames, comme en jeu.
	var saw_snap := false
	var early_flips := 0
	var early_prev := (win3d.quads[7] as Node3D).global_basis
	for _i in 60:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.02)
		var nb := (win3d.quads[7] as Node3D).global_basis
		if not nb.is_equal_approx(early_prev):
			early_flips += 1
		early_prev = nb
		if win3d.snapped_to.has(7) and not saw_snap:
			saw_snap = true
	var res: Variant = Runner.assert_true(saw_snap,
		"la fenêtre doit finir par se coller")
	if _fail(res):
		_teardown()
		return res
	# L'orientation ne doit basculer QU'UNE fois : au moment où le collage
	# s'établit. Toute autre bascule est le clignotement du bug.
	res = Runner.assert_true(early_flips <= 1,
		"l'orientation ne doit basculer qu'une fois (collage établi), vu %d fois"
			% early_flips)
	if _fail(res):
		_teardown()
		return res
	# On continue de tenir en BOUGANT, comme un joueur qui corrige son geste.
	# C'est là que le collage saute : la fenêtre suit le pointeur, se décolle,
	# perd le recouvrement, revient face caméra, et recommence.
	for _i in 40:
		await get_tree().physics_frame
		# Le pointeur dérive autour du point de calage : ±6 cm, dans le plan.
		var jitter := Vector3(
			sin(float(_i) * 0.7) * 0.06, 0.0, cos(float(_i) * 0.9) * 0.06)
		win3d._update_move(CAM, (flush + jitter - CAM).normalized(), 0.02)
	res = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"le collage doit TENIR pendant la convergence, pas clignoter")
	if _fail(res):
		_teardown()
		return res
	# ET surtout : pendant la convergence elle-même, l'orientation ne doit
	# JAMAIS revenir face caméra. On compte donc les bascules sur tout le
	# trajet, pas seulement une fois arrivé.
	var flips := 0
	var prev := (win3d.quads[7] as Node3D).global_basis
	for _i in 24:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.02)
		var now := (win3d.quads[7] as Node3D).global_basis
		if not now.is_equal_approx(prev):
			flips += 1
		prev = now
	res = Runner.assert_eq(flips, 0,
		"l'orientation ne doit plus osciller (retours face caméra)")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_position, flush,
		"la fenêtre doit se stabiliser au calage exact")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, turned,
		"et garder l'orientation de sa voisine")
	_teardown()
	return res

func test_a_snap_without_a_verdict_still_falls_back_to_the_neighbour() -> Variant:
	## La règle des 3 fenêtres ne tranche que sur un VERDICT EXPLICITE, et ce
	## verdict transite par `_find_snap`. Un collage à deux fenêtres n'a aucun
	## verdict à rendre : le repli doit alors adopter la voisine.
	##
	## Ce repli est le chemin le plus FRÉQUENT du jeu — le cas ordinaire d'une
	## fenêtre qu'on colle à une seule autre. S'il adoptait la fenêtre saisie
	## elle-même, elle garderait sa propre orientation en prétendant être
	## collée : le raccord ne serait jamais plat, et rien ne le signalerait.
	var build: Variant = _build_world()
	if build != true:
		return build
	var turned := Basis(Vector3.UP, deg_to_rad(35.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	win3d._store_basis(7, Basis(Vector3.UP, deg_to_rad(5.0)))
	# Lien réel, SANS verdict : c'est la forme qu'une liaison à deux fenêtres
	# prend quand personne n'a rendu de verdict.
	win3d.snapped_to[7] = {"wid": 8, "side": "left", "our_side": "right"}
	win3d.active_window_id = 7
	win3d._adopt_snap_basis(7, win3d.snapped_to[7])
	var res: Variant = _assert_basis(win3d._stored_basis(7), turned,
		"sans verdict, la fenêtre doit adopter sa voisine")
	_teardown()
	return res

func test_rotating_the_neighbour_carries_the_snapped_window() -> Variant:
	## TROU DE COUVERTURE. L'adoption de l'orientation ne se faisait qu'au
	## premier frame du collage (`entering`). Dès la frame suivante elle
	## disparaissait : si la voisine tournait ensuite, la fenêtre collée restait
	## à son ancien angle et le raccord n'était plus plat.
	##
	## Concrètement, c'est ce qui permettait au collage d'osciller : la base
	## retenue n'était plus celle de la voisine, les zones bougeaient, le
	## recouvrement sautait, et le cycle reprenait.
	var build: Variant = _build_world()
	if build != true:
		return build
	var turned := Basis(Vector3.UP, deg_to_rad(35.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	win3d.active_window_id = 7
	win3d.is_moving = true
	var flush := Vector3(1.0, 1.5, -2.0) \
		- Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(35.0))
	win3d.move_depth = CAM.distance_to(flush)
	var dir := (flush - CAM).normalized()
	for _i in 10:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.1)
		if win3d.snapped_to.has(7):
			break
	var res: Variant = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"la fenêtre doit être collée")
	if _fail(res):
		_teardown()
		return res
	# La voisine tourne de 15° de plus, EN COURS DE COLLAGE. La fenêtre collée
	# doit suivre : c'est la condition pour que le raccord reste plat.
	var spun := Basis(Vector3.UP, deg_to_rad(50.0))
	win3d._store_basis(8, spun)
	for _i in 4:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.1)
	res = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"le collage doit survivre à la rotation de la voisine")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, spun,
		"la fenêtre collée doit SUIVRE l'orientation de sa voisine")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_position,
		Vector3(1.0, 1.5, -2.0)
			- Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(50.0)),
		"et se recaler sur elle, bord à bord")
	_teardown()
	return res

func test_the_three_window_verdict_survives_the_crossing_of_find_snap() -> Variant:
	## TROU DE COUVERTURE RÉEL. Tous les tests de la règle des 3 fenêtres
	## appelaient _choose_snap() DIRECTEMENT, et passaient ensuite le verdict à
	## la main à _set_snap(). Personne ne vérifiait donc que ce verdict
	## SURVIT à _find_snap() — la seule porte que le code réel emprunte.
	##
	## Il en perdait une copie : _find_snap() reconstruisait son dictionnaire
	## de retour et n'y reportait ni `adopt_basis_of` ni les zones. La règle
	## des 3 fenêtres se retrouvait donc neutralisée en jeu — le cas
	## « A garde sa rotation quand B et C s'accordent » basculait silencieusement
	## sur son exact contraire — et aucun test ne le voyait.
	##
	## Ici le verdict est récupéré par _find_snap(), sur un VRAI recouvrement
	## de zones, et c'est lui qui décide de l'orientation finale.
	var build: Variant = _build_world()
	if build != true:
		return build
	_make_window_9()
	# Trois fenêtres réellement voisines : la 7 arrive par le haut de la 8, et
	# la 9 est déjà collée sous la 8. Les zones se recouvrent donc pour de vrai.
	var basis_b := Basis(Vector3.UP, deg_to_rad(30.0))
	var basis_a := Basis(Vector3.UP, deg_to_rad(5.0))
	win3d._store_basis(7, basis_a)
	win3d._store_basis(8, basis_b)
	win3d._store_basis(9, basis_b)
	win3d.snapped_to[8] = {"wid": 9, "side": "bottom", "our_side": "top"}
	# La 8 pose sur la 9, et la 7 arrive par le HAUT de la 8. Il faut que les
	# zones de la 7 recouvrent la 8 ET la 9 : sinon il n'y a qu'un seul
	# candidat, la règle des 3 fenêtres ne s'applique pas, et le test
	# vérifierait autre chose. D'où la 7 descendue d'une largeur, à cheval sur
	# les deux voisines.
	var up := Vector3(0.0, 1.0, 0.0).rotated(Vector3.UP, deg_to_rad(30.0))
	var c9 := Vector3(0.0, 1.5, -2.0)
	(win3d.quads[9] as Node3D).global_basis = basis_b
	(win3d.quads[9] as Node3D).global_position = c9
	(win3d.quads[8] as Node3D).global_basis = basis_b
	(win3d.quads[8] as Node3D).global_position = c9 + up * 0.6
	(win3d.quads[7] as Node3D).global_basis = basis_a
	(win3d.quads[7] as Node3D).global_position = c9 + up * 1.05
	win3d.active_window_id = 7
	win3d._sync_snap_monitoring(7)
	await get_tree().physics_frame
	var snap: Variant = win3d._find_snap((win3d.quads[7] as Node3D).global_position)
	var res: Variant = Runner.assert_true(not snap.is_empty(),
		"les deux zones doivent réellement se recouvrir")
	if _fail(res):
		_teardown()
		return res
	# LE POINT : le verdict de la règle des 3 fenêtres est-il encore là ?
	# B == C (toutes deux à 30°), A est différente (5°) : le verdict est
	# « A garde la sienne », soit 7. Si la copie se perdait, le défaut
	# ramènerait `wid` = 8, et la 7 adopterait B — l'inverse exact.
	res = Runner.assert_eq(int(snap.get("adopt_basis_of", -1)), 7,
		"le verdict 3 fenêtres doit survivre au passage par _find_snap")
	if _fail(res):
		_teardown()
		return res
	# La zone visée est celle EN FACE de la nôtre. La 7 est le membre le plus
	# haut de la pile, donc sa voisine par le bas est la 8 — et le centre de
	# cette zone est le milieu de l'arête entre les deux quads.
	# La zone visée est le HAUT visible du quad d'en dessous. Elle est
	# centrée sur le bord VISIBLE (quad + bandeau de titre de 6 cm), pas sur le
	# bord du quad : d'où le demi-hauteur fourni par le code lui-même plutôt
	# qu'un 0.5 en dur, qui masquerait justement cette différence de 3 cm.
	# La zone visée est le HAUT visible du quad visé, sur son Y LOCAL incliné.
	var target: MeshInstance3D = win3d.quads[int(snap.get("wid", -1))]
	var half_y: float = Windows3DScript.visual_half_extent(
		(target.mesh as QuadMesh).size).y
	var expect_edge: Vector3 = target.global_position \
		+ (target.global_basis * Vector3(0.0, half_y, 0.0))
	res = _assert_v((snap["their_area"] as Area3D).global_transform.origin,
		expect_edge,
		"la zone visée doit être l'arête visible haute du quad visé")
	if _fail(res):
		_teardown()
		return res
	# Puis l'orientation réellement appliquée. Ici B == C, donc A GARDE la
	# sienne : c'est précisément le cas que la copie perdue inversait.
	win3d._adopt_snap_basis(7, snap)
	res = _assert_basis(win3d._stored_basis(7), basis_a,
		"B et C s'accordant, A doit garder SA rotation")
	_teardown()
	return res

func test_a_window_being_dragged_faces_the_camera() -> Variant:
	## RÉGRESSION DU BUG SIGNALÉ : une fenêtre saisie SANS collage doit faire
	## face à la caméra. Sans cela on la voit de biais pendant tout le
	## déplacement — le texte devient illisible et on ne sais plus où l'on
	## vise. La caméra bouge pourtant pendant le drag (le joueur tourne la
	## tête en même temps qu'il déplace), donc figer l'orientation au grab ne
	## suffit pas : c'est la position DU VISEUR qui doit commander.
	var build: Variant = _build_world()
	if build != true:
		return build
	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	# Une caméra nettement inclinée : une base figée au grab ne peut pas y
	# ressembler par hasard.
	var turned := Basis(Vector3.UP, deg_to_rad(40.0)) * Basis(Vector3.RIGHT, deg_to_rad(20.0))
	cam.global_transform = Transform3D(turned, cam.global_position)
	# La 7 part d'une base qui ne ressemble à rien, pour que le test ne
	# passe pas par coïncidence.
	(win3d.quads[7] as Node3D).global_basis = Basis(Vector3.UP, deg_to_rad(175.0))
	win3d._store_basis(7, Basis(Vector3.UP, deg_to_rad(175.0)))
	# movement SANS voisine : aucune 8 dans le tas, donc aucun collage possible.
	(win3d.quads[8] as Node3D).global_position = Vector3(900.0, 1.5, -40.0)
	await _drag_7_to(Vector3(-0.5, 1.5, -2.0))
	var res: Variant = Runner.assert_true(win3d.snapped_to.is_empty(),
		"la fenêtre doit être dragged SANS collage, sinon le test ne prouve rien")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, turned,
		"la fenêtre saisie doit faire face à la caméra")
	if _fail(res):
		_teardown()
		return res
	# L'état stocké doit suivre la caméra : c'est lui que la rotation au
	# collage relit, un cran plus tard.
	res = _assert_basis(win3d._stored_basis(7), turned,
		"l'orientation stockée doit être celle de la caméra")
	_teardown()
	return res

func test_a_camera_turn_while_dragging_reorients_the_window() -> Variant:
	## Le joueur bouge la souris ET tourne la tête. La fenêtre doit suivre les
	## deux, donc se réorienter quand la caméra pivote en cours de route.
	var build: Variant = _build_world()
	if build != true:
		return build
	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	(win3d.quads[8] as Node3D).global_position = Vector3(900.0, 1.5, -40.0)
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = 2.0
	await get_tree().physics_frame
	win3d._update_move(CAM, Vector3(0.0, 0.0, -1.0), 0.1)
	var turned := Basis(Vector3.UP, deg_to_rad(55.0))
	cam.global_transform = Transform3D(turned, cam.global_position)
	win3d._update_move(CAM, Vector3(0.0, 0.0, -1.0), 0.1)
	var res: Variant = _assert_basis((win3d.quads[7] as Node3D).global_basis, turned,
		"la fenêtre doit suivre la rotation de caméra survenue pendant le drag")
	_teardown()
	return res

func test_a_snapped_window_keeps_the_neighbour_orientation() -> Variant:
	## CONTRE-TEST du précédent : une fois COLLÉE, la fenêtre ne doit PLUS
	## suivre la caméra, sinon le collage VR ne tient pas et la rotation au
	## collage est annulée à la frame suivante. Ce sont les deux comportements
	## opposés, décidés par le seul fait d'être collé ou non.
	var build: Variant = _build_world()
	if build != true:
		return build
	var cam: Camera3D = player.get_node("Camera3D") as Camera3D
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	await _drag_7_to(Vector3(0.0, 1.5, -2.0) + Vector3(0.0999, 0.0, 0.0))
	var res: Variant = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"la fenêtre doit être collée")
	if _fail(res):
		_teardown()
		return res
	# La caméra pivote après le collage : la fenêtre doit IMMOBILISER son
	# orientation et garder celle de sa voisine.
	var turned := Basis(Vector3.UP, deg_to_rad(50.0))
	cam.global_transform = Transform3D(turned, cam.global_position)
	win3d._update_move(CAM, Vector3(0.0, 0.0, -1.0), 0.1)
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, Basis.IDENTITY,
		"une fenêtre collée garde l'orientation de sa voisine, pas celle de la caméra")
	_teardown()
	return res

func test_holding_a_snap_does_not_make_it_oscillate() -> Variant:
	## RÉGRESSION DU BUG SIGNALÉ : en gardant le bouton, la fenêtre oscillait
	## sans fin — elle se tournait pour se coller, revenait à son angle
	## précédent, et repartait.
	##
	## La cause est un ORDRE D'OPÉRATIONS. Les zones sont des ENFANTS du quad :
	## adopter l'orientation de la voisine les DÉPLACE. Or le calage était
	## calculé AVANT ce déplacement, donc il ne valait plus une fois la base
	## écrite. Les zones sortaient alors de la voisine, le collage sautait, la
	## fenêtre repassait face caméra, et le cycle se refermait à la frame
	## suivante.
	##
	## On MAINTIENT donc le grab plusieurs frames de suite : un collage qui
	## tient doit rester tenu. La voisine est tournée et la caméra non, sinon
	## les deux bases seraient confondues et le test ne prouverait rien.
	var build: Variant = _build_world()
	if build != true:
		return build
	var turned := Basis(Vector3.UP, deg_to_rad(35.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	win3d.active_window_id = 7
	win3d.is_moving = true
	# Point de calage attendu, à la main : le calage se fait dans le repère
	# TOURNÉ de la voisine, donc les deux moitiés ne se compensent pas.
	# Point de calage attendu, À LA MAIN : les deux demi-largeurs dans le
	# repère TOURNÉ de la voisine. Les soustraire en axes monde donnerait un
	# écart faux, et le test passerait ou échouerait selon l'angle au lieu de
	# vérifier la géométrie.
	var flush := Vector3(1.0, 1.5, -2.0) \
		- Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(35.0))
	win3d.move_depth = CAM.distance_to(flush)
	var dir := (flush - CAM).normalized()
	# Avance jusqu'à ce que le collage se forme.
	for _i in 10:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.1)
		if win3d.snapped_to.has(7):
			break
	var res: Variant = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"la fenêtre doit se coller à sa voisine")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, turned,
		"la fenêtre collée doit avoir pris l'orientation de sa voisine")
	if _fail(res):
		_teardown()
		return res
	# LE TEST : on garde le bouton. Le collage doit TENIR, et la fenêtre rester
	# au calage exact, frame après frame.
	for _i in 8:
		await get_tree().physics_frame
		win3d._update_move(CAM, dir, 0.1)
	res = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"le collage doit TENIR tant que le grab est maintenu")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis((win3d.quads[7] as Node3D).global_basis, turned,
		"et l'orientation ne doit pas osciller d'une frame à l'autre")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_position, flush,
		"la fenêtre doit rester au calage exact")
	_teardown()
	return res

func test_a_snap_records_which_side_of_each_window_meets() -> Variant:
	## `side` et `our_side` sont DEUX côtés distincts et tous deux indispensables :
	## le raccord se lit sur la cible, le pivot de rotation se lit sur nous.
	## Confondre les deux ne casse pas le collage — qui reste au bon endroit —
	## mais fait tourner la fenêtre autour du mauvais bord, sans un seul signe
	## visible tant que la fenêtre est droite. Il faut donc le vérifier sur un
	## collage RÉELLEMENT produit par les zones.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	await _drag_7_to(Vector3(0.0, 1.5, -2.0) + Vector3(0.0999, 0.0, 0.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(String(snap.get("side", "")), "left",
		"la 7 entre par le côté gauche de la 8")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(String(snap.get("our_side", "")), "right",
		"et c'est le côté DROIT de la 7 qui touche")
	if _fail(res):
		_teardown()
		return res
	# Le pivot de rotation doit donc être le centre de la zone droite de la 7.
	res = _assert_v((win3d._snap_pivot_area(7)).global_transform.origin,
		Vector3(0.5, 1.5, -2.0),
		"le pivot doit être la zone du côté de la fenêtre saisie")
	_teardown()
	return res

func test_a_plain_snap_inherits_the_neighbour_orientation() -> Variant:
	## Cas le plus courant de tous : une seule voisine, aucun arbitrage. La
	## fenêtre saisie doit adopter l'orientation de la cible — c'est le modèle
	## VR, et sans cela deux fenêtres « collées » bord à bord se traversent
	## visuellement dès qu'on les regarde de biais.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	# La 8 est tournée, la 7 est droite : sans héritage, elles ne sont pas d'accord.
	var turned := Basis(Vector3.UP, deg_to_rad(25.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	win3d._store_basis(7, Basis.IDENTITY)
	# Cible calculée dans le repère tourné de la 8, comme le ferait le joueur.
	var right := Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(25.0))
	await _drag_7_to(Vector3(1.0, 1.5, -2.0) - right * 1.0 + right * 0.05)
	var res: Variant = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"la fenêtre doit d'abord se coller")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis(win3d._stored_basis(7), turned,
		"une fenêtre collée doit prendre l'orientation de sa voisine")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_basis.x.normalized(), right,
		"l'orientation doit être réellement appliquée au quad")
	_teardown()
	return res

func test_monitoring_follows_the_grabbed_window() -> Variant:
	## Inventorier les recouvrements coûte du temps physique : seules les
	## zones de la fenêtre SAISIE doivent surveiller. Une zone restée allumée
	## après le relâchement continuerait de remplir sa liste de recouvrements
	## pour rien, et le travail se cumule à chaque fenêtre mappée.
	var build: Variant = _build_world()
	if build != true:
		return build
	var res: Variant = Runner.assert_true(not _any_zone_monitoring(),
		"aucune fenêtre ne doit surveiller ses zones tant qu'aucune n'est saisie")
	if _fail(res):
		_teardown()
		return res
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = 2.0
	win3d._update_move(CAM, Vector3(0.0, 0.0, -1.0), 0.1)
	res = Runner.assert_eq(_monitoring_wids(), [7],
		"seules les zones de la fenêtre saisie doivent surveiller")
	if _fail(res):
		_teardown()
		return res
	# Relâchement : c'est process_raycast, appelé toutes les frames, qui éteint.
	# `active_window_id` reste volontairement PEUPLÉ : c'est le cas réel du
	# drag de contenu, qui garde l'identifiant après le relâchement. Ne tester
	# que le cas « identifiant remis à -1 » laisserait passer une surveillance
	# qui ne s'éteint jamais.
	win3d.is_moving = false
	win3d.process_raycast(CAM, Vector3(0.0, 0.0, -1.0), 0.1, false)
	res = Runner.assert_true(not _any_zone_monitoring(),
		"le relâchement doit éteindre la surveillance")
	_teardown()
	return res

func test_snap_zones_live_on_their_own_collision_layer() -> Variant:
	## Les zones ne doivent pas être atteignables par le raycast de pointage,
	## qui ne cherche que les corps de fenêtre (couche 2). Si elles partageaient
	## cette couche, un jour où ce rayon toucherait les Area3D, on saisirait
	## une zone au lieu de la fenêtre.
	var build: Variant = _build_world()
	if build != true:
		return build
	var body_layer: int = (win3d.quads[7].get_child(0) as StaticBody3D).collision_layer
	var res: Variant = Runner.assert_eq(body_layer, 2,
		"le corps de fenêtre doit rester sur la couche de pointage")
	if _fail(res):
		_teardown()
		return res
	for side in ["left", "right", "top", "bottom"]:
		var zone := win3d.quads[7].get_node_or_null(
			"Snap%s" % side.capitalize()) as Area3D
		res = Runner.assert_true(zone != null, "la zone %s doit exister" % side)
		if _fail(res):
			_teardown()
			return res
		res = Runner.assert_eq(zone.collision_layer, Windows3DScript.SNAP_ZONE_LAYER,
			"la zone %s doit être sur la couche de collage" % side)
		if _fail(res):
			_teardown()
			return res
		res = Runner.assert_eq(zone.collision_layer & body_layer, 0,
			"la zone %s ne doit pas être sur la couche de pointage" % side)
		if _fail(res):
			_teardown()
			return res
	_teardown()
	return res

func _any_zone_monitoring() -> bool:
	for wid in [7, 8]:
		for side in ["left", "right", "top", "bottom"]:
			var area := win3d.quads[wid].get_node_or_null(
				"Snap%s" % side.capitalize()) as Area3D
			if area != null and area.monitoring:
				return true
	return false

func _monitoring_wids() -> Array:
	var out: Array = []
	for wid in [7, 8]:
		for side in ["left", "right", "top", "bottom"]:
			var area := win3d.quads[wid].get_node_or_null(
				"Snap%s" % side.capitalize()) as Area3D
			if area != null and area.monitoring:
				out.append(wid)
				break
	return out

func test_the_three_window_rule_stays_inert_when_the_driven_window_already_matches() -> Variant:
	## A == B : le raccord est déjà plat, la règle n'a rien à décider.
	var build: Variant = _build_world()
	if build != true:
		return build
	_make_window_9()
	var basis_a := Basis(Vector3.UP, 0.4)
	win3d._store_basis(7, basis_a)
	win3d._store_basis(8, basis_a)
	win3d._store_basis(9, Basis(Vector3.UP, 0.9))
	win3d.snapped_to[8] = {"wid": 9, "side": "bottom", "our_side": "top"}
	var res: Variant = Runner.assert_eq(
		int(win3d._choose_snap(_two_pairs()).get("adopt_basis_of", -1)), 8,
		"quand A et B s'accordent déjà, aucune rotation ne doit être imposée")
	_teardown()
	return res

func test_dragging_out_of_reach_releases_the_snap() -> Variant:
	## Symétrique obligatoire de l'accrochage : une fois les zones séparées,
	## le collage doit TOMBER. Sans quoi la fenêtre resterait attachée à sa
	## voisine pour le reste de la session, et le moindre déplacement la
	## téléporterait le long du calage.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	await _drag_7_to(Vector3(0.0, 1.5, -2.0))
	var res: Variant = Runner.assert_true(win3d.snapped_to.has(7),
		"la fenêtre doit d'abord être collée")
	if _fail(res):
		_teardown()
		return res
	# 60 cm d'écart : les centres de zone sortent de l'épaisseur de 50 cm.
	await _drag_7_to(Vector3(0.0, 1.5, -2.0) + Vector3(0.6, 0.0, 0.0))
	res = Runner.assert_true(not win3d.snapped_to.has(7),
		"hors portée des zones, le collage doit se défaire")
	_teardown()
	return res

# ── Rotation ───────────────────────────────────────────────────────────

func test_scroll_only_rotates_while_snapped() -> Variant:
	## Règle centrale : le scroll garde son sens de push/pull tant que rien n'est
	## collé. Sans cette condition, on perd le push/pull existant.
	var build: Variant = _build_world()
	if build != true:
		return build
	win3d.active_window_id = 7
	var res: Variant = Runner.assert_true(not win3d._scroll_rotates(),
		"hors collage, le scroll ne doit pas tourner")
	if _fail(res):
		_teardown()
		return res
	win3d.snapped_to[7] = {"wid": 8, "side": "left"}
	res = Runner.assert_true(win3d._scroll_rotates(),
		"une fenêtre collée doit pouvoir pivoter au scroll")
	_teardown()
	return res

func test_rotating_accumulates_around_the_snap_zone() -> Variant:
	## L'orientation est figée, donc les crans s'ACCUMULENT dans la base stockée
	## : on veut pouvoir dépasser 45°, pas seulement osciller entre 0 et 15°.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -2.0)
	win3d.snapped_to[7] = {"wid": 8, "side": "left", "our_side": "right"}
	win3d.active_window_id = 7
	var start: Basis = win3d._stored_basis(7)
	win3d._rotate_snapped(1.0)
	win3d._rotate_snapped(1.0)
	win3d._rotate_snapped(1.0)
	var res: Variant = _assert_basis(win3d._stored_basis(7),
		start.rotated(Vector3.UP, 3.0 * Windows3DScript.SNAP_YAW_STEP),
		"trois crans doivent accumuler trois pas de rotation")
	if _fail(res):
		_teardown()
		return res
	win3d._rotate_snapped(-1.0)
	res = _assert_basis(win3d._stored_basis(7),
		start.rotated(Vector3.UP, 2.0 * Windows3DScript.SNAP_YAW_STEP),
		"un cran inverse doit annuler le dernier cran")
	_teardown()
	return res

func test_the_orientation_stays_fixed_while_the_window_is_driven() -> Variant:
	## PROPRIÉTÉ CENTRALE DU MODÈLE VR : une fenêtre collée garde son
	## orientation pendant qu'on la déplace. Avant, chaque frame de drag
	## réécrivait `global_basis = base caméra`, ce qui annulerait d'un coup
	## l'héritage de la voisine — et surtout ferait disparaître tout écart de
	## rotation dès que la fenêtre bougeait, donc le collage ne tient plus.
	##
	## C'est le contre-test exact de `test_a_window_being_dragged_faces_the_
	## camera` : les deux comportements sont opposés, et c'est le seul fait
	## d'être collé qui les départage.
	var build: Variant = _build_world()
	if build != true:
		return build
	# Vraie voisine tournée, pour que l'orientation à conserver soit DISTINCTE
	# de celle de la caméra : un simple dragged libre ne prouverait rien.
	var turned := Basis(Vector3.UP, deg_to_rad(30.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = turned
	win3d._store_basis(8, turned)
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	# Collage RÉELLEMENT produit par les zones. Écrire snapped_to à la main
	# ne suffirait pas : _set_snap efface une liaison qui n'est plus confirmée
	# par un recouvrement, et le test chromat alors l'absence de collage —
	# ce qui le ferait échouer pour la mauvaise raison.
	var flush := Vector3(1.0, 1.5, -2.0) \
		- Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(30.0))
	await _drag_7_to(flush)
	var res: Variant = Runner.assert_eq(win3d.snapped_to.get(7, {}).get("wid", -1), 8,
		"la fenêtre doit être collée à sa voisine tournée")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis(win3d.quads[7].global_basis, turned,
		"une fenêtre collée doit reprendre l'orientation de sa voisine")
	if _fail(res):
		_teardown()
		return res
	# La caméra est tournée à 90° : si le drag réécrivait encore la base
	# caméra, la fenêtre suivrait et le raccord VR ne serait plus plat.
	var cam := player.get_node("Camera3D") as Camera3D
	cam.global_basis = Basis(Vector3.UP, PI * 0.5)
	win3d._update_move(CAM, Vector3(0.0, 0.0, -1.0), 0.1)
	res = _assert_basis(win3d.quads[7].global_basis, turned,
		"le drag ne doit pas réécrire l'orientation d'une fenêtre collée")
	_teardown()
	return res

func test_the_stored_orientation_is_cleared_when_a_window_is_unmapped() -> Variant:
	## Sans ce nettoyage, un wid réutilisé par le compositeur hériterait de
	## l'orientation d'une fenêtre partie, et repartirait de travers.
	var build: Variant = _build_world()
	if build != true:
		return build
	win3d._store_basis(7, Basis(Vector3.UP, 0.9))
	win3d.snapped_to[7] = {"wid": 8, "side": "left", "our_side": "right"}
	win3d._erase_window_state(7)
	var res: Variant = Runner.assert_true(not win3d._window_basis.has(7),
		"l'orientation stockée doit disparaître avec la fenêtre")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_true(not win3d.snapped_to.has(7),
		"l'état de collage doit disparaître avec la fenêtre")
	_teardown()
	return res
func test_rotation_pivots_on_the_snap_zone_and_leaves_it_in_place() -> Variant:
	## La rotation ne doit pas se faire autour du CENTRE de la fenêtre, ni
	## autour d'un point reconstruit à partir d'un cadre : elle se fait autour
	## de l'ORIGINE DE LA ZONE DE COLLAGE. Et comme la zone est un ENFANT du
	## quad, tourner autour d'elle la laisse rigoureusement sur place — c'est
	## ce qui garantit que le recouvrement, donc le collage, survit à la
	## rotation. La fenêtre orbite comme une porte sur son gond.
	var build: Variant = _build_world()
	if build != true:
		return build
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -2.0)
	win3d.snapped_to[7] = {"wid": 8, "side": "left", "our_side": "right"}
	win3d.active_window_id = 7
	var zone: Area3D = win3d._snap_pivot_area(7)
	var res: Variant = Runner.assert_true(zone != null,
		"la zone du côté de collage doit exister")
	if _fail(res):
		_teardown()
		return res
	# Le pivot est le centre de la zone droite, donc le milieu de l'arête de
	# liaison vue du QUAD : (0.5, 1.5, -2).
	var pivot: Vector3 = zone.global_transform.origin
	res = _assert_v(pivot, Vector3(0.5, 1.5, -2.0),
		"le pivot doit être le centre de la zone du côté collé")
	if _fail(res):
		_teardown()
		return res
	# 1. La zone, et donc la liaison, ne bouge pas d'un millimètre.
	win3d._rotate_snapped(1.0)
	res = _assert_v(zone.global_transform.origin, pivot,
		"la zone de collage doit rester fixe pendant la rotation")
	if _fail(res):
		_teardown()
		return res
	# 2. La fenêtre a bien orbité autour de ce point, et pas sur elle-même.
	var after: Vector3 = _visual_center_of(win3d.quads[7])
	res = _assert_v(after, Vector3(0.0170371, 1.53, -1.8705905),
		"le centre doit orbiter de 15° autour de la zone")
	if _fail(res):
		_teardown()
		return res
	# 3. Le rayon de l'orbite est celui de la zone, pas celui du centre.
	var radius: float = (after - pivot).length()
	res = Runner.assert_approx(radius, 0.5009, 0.0001,
		"le centre doit tourner à rayon constant depuis la zone")
	if _fail(res):
		_teardown()
		return res
	# 4. Un second cran continue l'orbite autour du MÊME point.
	win3d._rotate_snapped(1.0)
	res = _assert_v(zone.global_transform.origin, pivot,
		"un second cran doit orbiter autour du MÊME point")
	if _fail(res):
		_teardown()
		return res
	# 5. La fenêtre voisine n'a pas bougé non plus.
	res = _assert_v((win3d.quads[8] as Node3D).global_position, Vector3(1.0, 1.5, -2.0),
		"la fenêtre voisine ne doit pas bouger")
	_teardown()
	return res

func test_rotation_turns_around_the_zone_axis_not_the_world_up() -> Variant:
	## Une zone ATTACHÉE à une fenêtre inclinée a son axe Y local incliné avec
	## elle : tourner autour de l'axe du monde, lui, ferait pivoter la fenêtre
	## dans le mauvais plan et la décollerait de sa voisine. Or toutes les
	## rotations se font sur des fenêtres droites, où les deux axes
	## confondent — il faut donc une fenêtre INCLINÉE pour que le test distingue
	## vraiment les deux.
	var build: Variant = _build_world()
	if build != true:
		return build
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(30.0))
	_place_8(Vector3(1.0, 1.5, -2.0))
	(win3d.quads[8] as Node3D).global_basis = tilt
	(win3d.quads[7] as Node3D).global_basis = tilt
	win3d._store_basis(7, tilt)
	win3d._store_basis(8, tilt)
	win3d.snapped_to[7] = {"wid": 8, "side": "left", "our_side": "right"}
	win3d.active_window_id = 7
	var zone: Area3D = win3d._snap_pivot_area(7)
	var axis: Vector3 = zone.global_transform.basis.y.normalized()
	var res: Variant = Runner.assert_approx(axis.dot(Vector3.UP), 1.0, 0.5,
		"la zone doit être réellement inclinée, sinon le test ne prouve rien")
	if _fail(res):
		_teardown()
		return res
	win3d._rotate_snapped(1.0)
	var got: Variant = _assert_basis(win3d._stored_basis(7),
		tilt.rotated(axis, Windows3DScript.SNAP_YAW_STEP),
		"la rotation doit suivre l'axe Y de la zone")
	if _fail(got):
		_teardown()
		return got
	# Et l'inverse doit échouer : c'est ce qui prouve que le test discrimine.
	var wrong: Variant = _assert_basis(win3d._stored_basis(7),
		tilt.rotated(Vector3.UP, Windows3DScript.SNAP_YAW_STEP),
		"rotation autour de l'axe du monde")
	if _fail(wrong) == false:
		_teardown()
		return "tourner autour de l'axe du monde donnerait le même résultat : le test ne prouve rien"
	_teardown()
	return true

func test_copying_a_basis_carries_the_stored_orientation() -> Variant:
	## La sortie du mode focus recopie l'orientation de la première fenêtre sur
	## les autres. Recopier `global_basis` seul ne suffit pas : c'est l'état
	## STOCKÉ que la rotation au collage relit, et s'il n'est pas recopié la
	## fenêtre se replace d'un coup au cran de rotation suivant (pop visible).
	var build: Variant = _build_world()
	if build != true:
		return build
	var turned := Basis(Vector3.UP, PI * 0.5)
	win3d._store_basis(8, turned)
	win3d.copy_window_basis(8, 7)
	var res: Variant = _assert_v((win3d.quads[7] as Node3D).global_basis.x.normalized(),
		Vector3(0.0, 0.0, -1.0),
		"la base copiée doit être reprise telle quelle")
	if _fail(res):
		_teardown()
		return res
	res = _assert_basis(win3d._stored_basis(7), turned,
		"l'état stocké doit suivre, sinon il saute au cran de rotation suivant")
	_teardown()
	return res

# ── Helpers ────────────────────────────────────────────────────────────

func _fail(res: Variant) -> bool:
	return res is String and res != ""

# Comparaison de bases avec une tolérance : les rotations enchaînées
# accumulent l'erreur de virgule flottante, et une égalité stricte ferait
# échouer le test pour une rien.
func _assert_basis(got: Basis, expected: Basis, msg: String) -> Variant:
	for axis in ["x", "y", "z"]:
		var res: Variant = _assert_v(got[axis].normalized(),
			expected[axis].normalized(), msg)
		if _fail(res):
			return res
	return true

func _visual_center_of(quad: Node3D) -> Vector3:
	return Windows3DScript.visual_center(quad.global_position,
		quad.global_basis.y.normalized())

func _half_extent_of(quad: Node3D) -> Vector2:
	return Windows3DScript.visual_half_extent((quad.mesh as QuadMesh).size)

# Milieu de l'arête `edge` ("left"/"right") du QUAD, en coordonnées monde.
func _contact_edge_midpoint(quad: Node3D, edge: String) -> Vector3:
	var sign_x := 1.0 if edge == "right" else -1.0
	return _visual_center_of(quad) \
		+ quad.global_basis.x.normalized() * _half_extent_of(quad).x * sign_x

func _assert_v(got: Vector3, want: Vector3, msg: String) -> Variant:
	if (got - want).length() > 0.0001:
		return "%s: attendu %s, trouvé %s" % [msg, str(want), str(got)]
	return true

# ── Atteignabilité du collage ───────────────────────────────────────────
# Ces tests encodent le bug qui a survécu à 176 tests verts : le collage
# n'était pas faux, il était INATTEIGNABLE. Ils utilisent la taille de fenêtre
# réelle (1920x1080 -> 3.56 x 2.0 m) et le rayon de drag réel (2.0 m), pas les
# petites fixtures de 1.0 x 0.5 qui, elles, rentraient dans la sphère.

const REAL_SIZE := Vector2(3.56, 2.0)
const SPAWN_DEPTH := 2.0
# Redimensionne une fenêtre ET ses zones, exactement comme le jeu le fait : le
# jeu passe par _sync_titlebar(), qui appelle _sync_snap_zones(). Sans cette
# synchronisation, les zones garderaient les dimensions de la fixture et le
# collage se ferait sur une taille que le joueur ne voit pas.
func _resize(id: int, size: Vector2) -> void:
	(win3d.quads[id] as MeshInstance3D).mesh.size = size
	win3d._sync_snap_zones(win3d.quads[id])

# Valeurs REELLES du jeu (project.godot + Camera3D par défaut), pour que le
# budget en pixels soit bien celui que vit le joueur.
const GAME_VIEWPORT_HEIGHT := 1080.0
const GAME_FOV := 75.0

func test_the_drag_sphere_alone_cannot_reach_a_flush_snap() -> Variant:
	## Devenir bord à bord impose 3.56 m d'écart latéral entre centres (1.78 +
	## 1.78), alors que la sphère de drag a un rayon de move_depth = 2.0 m.
	## L'écart minimal réel est donc 1.56 m pour un seuil de 0.15 m : le
	## collage latéral est arithmétiquement IMPOSSIBLE, et aucun raffinement du
	## calcul de distance ni du cadre utilisé n'y peut rien.
	var build: Variant = _build_world()
	if build != true:
		return build
	for id in [7, 8]:
		_resize(id, REAL_SIZE)
	_place_8(CAM + Vector3(0.0, 0.0, -SPAWN_DEPTH))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	# Viseur figé comme en MOUSE_MODE_CAPTURED, sans aucun delta souris.
	win3d.active_window_id = 7
	win3d.is_moving = true
	win3d.move_depth = SPAWN_DEPTH
	# Deux frames complètes, comme le jeu : un seul appel ne peut pas voir de
	# recouvrement, le serveur physique n'en ayant pas encore calculé.
	await _tick_move(Vector3(0.0, 0.0, -1.0))
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_true(snap.is_empty(),
		"sur la sphère seule, le collage latéral doit rester inatteignable")
	_teardown()
	return res

func test_a_flush_snap_is_reachable_with_a_real_size_window() -> Variant:
	## Même montage, avec une VRAIE taille de fenêtre. La fenêtre est amenée
	## 8 cm APRÈS le bord de la voisine : c'est le SNAP qui doit la ramener au
	## bord exact, pas le viseur. Ce test échoue si le drag redevient un simple
	## suivi du viseur.
	##
	## La voisine est placée à une profondeur telle que son bord reste
	## atteignable par le rayon, qui ne va pas plus loin que move_depth.
	var build: Variant = _build_world()
	if build != true:
		return build
	for id in [7, 8]:
		_resize(id, REAL_SIZE)
	var depth := 4.0
	win3d.move_depth = depth
	_place_8(Vector3(0.0, 1.5, -depth))
	(win3d.quads[7] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	win3d.active_window_id = 7
	win3d.is_moving = true
	# La fenêtre est AU-DELÀ du bord (8 cm), et le viseur pointe franchement le
	# bord lui-même : seul le SNAP peut la ramener au bord exact.
	var dir := (Vector3(REAL_SIZE.x, 1.5, -depth) - CAM).normalized()
	var beyond := Vector3(REAL_SIZE.x + 0.08, 1.5, -depth)
	(win3d.quads[7] as Node3D).global_position = beyond
	win3d.move_depth = beyond.distance_to(CAM)
	await _tick_move(dir)
	var snap: Dictionary = win3d.snapped_to.get(7, {})
	var res: Variant = Runner.assert_eq(snap.get("wid", -1), 8,
		"avec une vraie taille, le collage doit devenir atteignable")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(String(snap.get("side", "")), "right",
		"la fenêtre déplacée à droite doit se coller à droite de la voisine")
	if _fail(res):
		_teardown()
		return res
	res = _assert_v((win3d.quads[7] as Node3D).global_position,
		Vector3(REAL_SIZE.x, 1.5, -depth),
		"la fenêtre doit revenir exactement au bord de la voisine")
	_teardown()
	return res
func test_mouse_motion_is_only_collected_while_a_window_is_held() -> Variant:
	## Le delta n'est lu que pendant une prise : en dehors, il doit impacter
	##neither le déplacement ni la caméra.
	var build: Variant = _build_world()
	if build != true:
		return build
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(12.0, -5.0)
	win3d._input(ev)
	var res: Variant = Runner.assert_eq(win3d.move_mouse_delta, Vector2.ZERO,
		"hors grab, le delta souris ne doit rien impacter")
	if _fail(res):
		_teardown()
		return res
	win3d.is_moving = true
	win3d._input(ev)
	win3d._input(ev)
	res = Runner.assert_eq(win3d.move_mouse_delta, Vector2(24.0, -10.0),
		"pendant un grab, deux mouvements doivent cumuler")
	_teardown()
	return res

# ── Géométrie de la translation de vue ──────────────────────────────────

func test_pixels_to_world_scales_with_depth_and_fov() -> Variant:
	## Un pixel d'écran doit valoir le même déplacement monde quelle que soit la
	## profondeur du drag : sinon le glisser bondit quand on pousse la fenêtre
	## au loin, alors qu'à l'écran le geste est identique.
	##
	## Les valeurs sont ABSOLUES (la tangente du fov à l'écran), pas relatives :
	## une comparaison relative passerait avec un pas monde nul, ce qui est
	## précisément le cas dégénéré qu'il faut attraper.
	var wpp: float = Windows3DScript.pixels_to_world(2.0, 75.0, 1000.0)
	var exact := 2.0 * 2.0 * tan(deg_to_rad(75.0) * 0.5) / 1000.0 * Windows3DScript.VIEW_DRAG_GAIN
	var res: Variant = Runner.assert_approx(wpp, exact, 0.000001,
		"le pas monde doit valoir la tangente du fov rapportée à la hauteur")
	if _fail(res): return res
	res = Runner.assert_approx(
		Windows3DScript.pixels_to_world(4.0, 75.0, 1000.0), exact * 2.0, 0.000001,
		"doubler la profondeur doit doubler le pas monde")
	if _fail(res): return res
	res = Runner.assert_approx(
		Windows3DScript.pixels_to_world(2.0, 75.0, 2000.0), exact * 0.5, 0.000001,
		"doubler la hauteur d'écran doit halver le pas monde")
	if _fail(res): return res
	res = Runner.assert_eq(Windows3DScript.pixels_to_world(0.0, 75.0, 1000.0), 0.0,
		"une profondeur nulle ne doit pas produire un pas infini")
	if _fail(res): return res
	return Runner.assert_eq(Windows3DScript.pixels_to_world(2.0, 75.0, 0.0), 0.0,
		"une hauteur d'écran nulle ne doit pas produire un pas infini")

func test_snap_zone_is_centred_on_the_window_edge() -> Variant:
	## La zone doit être une dalle CENTRÉE sur le bord, pas une dalle posée à
	## l'extérieur. C'est ce qui fait que deux zones opposées se recouvrent
	## quand on APPROCHE, et pas seulement quand on a DÉPASSÉ : avec des
	## dalles extérieures, il faudrait avoir déjà traversé la position flush,
	## donc 3.56 m plus loin que la portée du drag.
	var res: Variant = _assert_v(
		Windows3DScript.snap_zone_local_offset(HALF, "left"),
		Vector3(-HALF.x, 0.0, 0.0),
		"la zone gauche est centrée sur le bord gauche")
	if _fail(res): return res
	res = _assert_v(
		Windows3DScript.snap_zone_local_offset(HALF, "right"),
		Vector3(HALF.x, 0.0, 0.0),
		"la zone droite est centrée sur le bord droit")
	if _fail(res): return res
	res = _assert_v(
		Windows3DScript.snap_zone_local_offset(HALF, "top"),
		Vector3(0.0, HALF.y, 0.0),
		"la zone haute est centrée sur le bord haut VISIBLE (quad + bandeau)")
	if _fail(res): return res
	return _assert_v(
		Windows3DScript.snap_zone_local_offset(HALF, "bottom"),
		Vector3(0.0, -HALF.y, 0.0),
		"la zone basse est centrée sur le bord bas")

func test_snap_zone_size_spans_the_edge_and_is_thick_enough_to_catch() -> Variant:
	## Une zone trop fine serait inatteignable au pixel près ; une zone trop
	## épaisse créerait des recouvrements entre fenêtres simplement voisines.
	## L'épaisseur est donc bornée des deux côtés.
	var t: float = Windows3DScript.SNAP_ZONE_THICKNESS
	var res: Variant = Runner.assert_true(t >= 0.3 and t <= 0.6,
		"l'épaisseur de zone doit rester entre 0.3 et 0.6 m, or elle vaut %f" % t)
	if _fail(res): return res
	# L'épaisseur de capture est portée par l'axe du collage, PAS par Z :
	# une zone latérale s'épaissit en X, une zone horizontale en Y.
	var lateral: Vector3 = Windows3DScript.snap_zone_size(HALF, "left")
	res = Runner.assert_approx(lateral.x, t, 0.0001,
		"une zone latérale doit être épaisse en X")
	if _fail(res): return res
	res = Runner.assert_approx(lateral.y, HALF.y * 2.0, 0.0001,
		"une zone latérale doit couvrir toute la hauteur de la fenêtre")
	if _fail(res): return res
	var horizontal: Vector3 = Windows3DScript.snap_zone_size(HALF, "top")
	res = Runner.assert_approx(horizontal.y, t, 0.0001,
		"une zone horizontale doit être épaisse en Y")
	if _fail(res): return res
	return Runner.assert_approx(horizontal.x, HALF.x * 2.0, 0.0001,
		"une zone horizontale doit couvrir toute la largeur de la fenêtre")

func test_sides_are_opposites_only_when_they_face_each_other() -> Variant:
	## Seuls des côtés réellement opposés ET face à face peuvent produire un
	## collage. Deux zones du même côté, ou deux zones perpendiculaires, ne
	## doivent jamais s'apparier.
	var res: Variant = Runner.assert_true(Windows3DScript.is_opposite_side("left", "right"),
		"gauche/droite sont opposés")
	if _fail(res): return res
	res = Runner.assert_true(Windows3DScript.is_opposite_side("top", "bottom"),
		"haut/bas sont opposés")
	if _fail(res): return res
	res = Runner.assert_true(Windows3DScript.is_opposite_side("right", "left"),
		"l'ordre des arguments ne doit pas changer le résultat")
	if _fail(res): return res
	res = Runner.assert_true(Windows3DScript.is_opposite_side("left", "left") == false,
		"un côté n'est pas opposé à lui-même")
	if _fail(res): return res
	res = Runner.assert_true(Windows3DScript.is_opposite_side("left", "top") == false,
		"deux côtés perpendiculaires ne sont pas opposés")
	if _fail(res): return res
	return Runner.assert_true(Windows3DScript.is_opposite_side("left", "nimp") == false,
		"un côté inconnu ne doit jamais être opposé à quoi que ce soit")

func test_view_drag_delta_follows_the_camera_frame() -> Variant:
	## La translation se fait dans le DROIT de la caméra, pas dans celui du
	## monde : c'est ce qui rend le collage atteignable à n'importe quelle
	## orientation de caméra. L'axe Y souris est inversé (comme partout).
	var yaw := Basis(Vector3.UP, PI * 0.5)
	var res: Variant = _assert_v(
		Windows3DScript.view_drag_delta(yaw.x.normalized(), yaw.y.normalized(),
			Vector2(100.0, 0.0), 0.01), Vector3(0.0, 0.0, -1.0),
		"100 px à droite d'une caméra tournée de 90° valent 1 m vers l'avant")
	if _fail(res): return res
	return _assert_v(
		Windows3DScript.view_drag_delta(Vector3.RIGHT, Vector3.UP,
			Vector2(0.0, 100.0), 0.01), Vector3(0.0, -1.0, 0.0),
		"100 px vers le bas doivent faire descendre la fenêtre")

func test_the_view_offset_does_not_leak_into_the_next_grab() -> Variant:
	## Le décalage cumulé est propre à UNE prise : sans reset, la fenêtre
	## repartirait offsetée de tout le geste précédent au grab suivant.
	var build: Variant = _build_world()
	if build != true:
		return build
	win3d._reset_view_drag()
	win3d.move_view_offset = Vector3(5.0, 0.0, 0.0)
	win3d.move_mouse_delta = Vector2(3.0, 4.0)
	win3d._reset_view_drag()
	var res: Variant = Runner.assert_eq(win3d.move_view_offset, Vector3.ZERO,
		"un nouveau grab doit repartir d'un décalage nul")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(win3d.move_mouse_delta, Vector2.ZERO,
		"le delta en attente doit être jeté au relâchement")
	_teardown()
	return res

func test_the_titlebar_drag_translates_in_the_view_plane_too() -> Variant:
	## Le drag par barre de titre (_update_move_2d) était lui aussi cloué au
	## rayon caméra, donc sans la translation il resterait inatteignable : les
	## deux gestes doivent partager le même mécanisme.
	var build: Variant = _build_world()
	if build != true:
		return build
	(win3d.quads[8] as Node3D).global_position = Vector3(0.0, 1.5, -40.0)
	win3d.active_window_id = 7
	win3d.is_moving_2d = true
	win3d.move_depth = 2.0
	win3d.move_2d_plane = Plane(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.5, -2.0))
	win3d.move_2d_offset = Vector3.ZERO
	var cam := player.get_node("Camera3D") as Camera3D
	var vp_h: float = get_viewport().get_visible_rect().size.y
	var wpp: float = Windows3DScript.pixels_to_world(2.0, cam.fov, vp_h)
	win3d.move_mouse_delta = Vector2(3.0 / wpp, 0.0)
	# delta = 1/15 : le poids du lerp vaut exactement 1.0 (lerp ne clampe pas),
	# donc la position finale est la cible SANS approximation.
	win3d._update_move_2d(CAM, Vector3(0.0, 0.0, -1.0), 1.0 / 15.0)
	# On vérifie la POSITION de la fenêtre, pas move_view_offset : ce dernier
	# serait calculé même si le drag ignorait la translation (test vacuous).
	var res: Variant = _assert_v((win3d.quads[7] as Node3D).global_position,
		Vector3(3.0, 1.5, -2.0),
		"le drag par barre de titre doit suivre la translation de vue")
	_teardown()
	return res

func test_grabbing_a_window_clears_the_previous_gesture() -> Variant:
	## Le reset doit être câblé sur le VRAI point d'entrée du grab (le menu
	## fenêtres), pas seulement sur des appels directs au helper.
	var build: Variant = _build_world()
	if build != true:
		return build
	win3d.move_view_offset = Vector3(4.0, 0.0, 0.0)
	win3d.move_mouse_delta = Vector2(7.0, 8.0)
	win3d.toggle_grab_window(7)
	var res: Variant = Runner.assert_eq(win3d.move_view_offset, Vector3.ZERO,
		"prendre une fenêtre doit effacer le geste précédent")
	if _fail(res):
		_teardown()
		return res
	res = Runner.assert_eq(win3d.move_mouse_delta, Vector2.ZERO,
		"le delta en attente doit être effacé au grab")
	_teardown()
	return res
