extends Node
## Tests de l'entrée « GRAB GROUP » du menu radial (fenêtre visée ET snappée).
##
## Le group grab existe déjà côté windows_3d (_start_group_grab, action
## grab_group) : ce qui manquait était l'entrée de l'anneau et son
## branchement. Deux pièces à verrouiller :
##  - can_group_grab : vrai seulement si le groupe aurait PLUS D'UNE fenêtre.
##    Sinon l'entrée ne ferait qu'un grab simple (le groupe inclut la fenêtre
##    saisie elle-même) ; et une voisine disparue ne doit pas laisser une
##    entrée morte dans l'anneau — or un unmapped n'efface que SA propre
##    entrée, la voisine garde la sienne (voir _erase_window_state) ;
##  - le radial : GRAB GROUP n'existe que dans le contexte « window », et
##    seulement si wayland_room a signalé un groupe saisissable.
##
## Aucune liaison n'est installée à la main : le collage vient d'un
## recouvrement RÉEL de zones (moteur physique), pas d'un dictionnaire écrit.

const Runner := preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")
const RadialMenu := preload("res://scripts/ui/radial_menu.gd")

const WID := 31
const NEI := 32
const MESH := Vector2(3.2, 2.0)

# Fenêtres de largeur 3.2 placées bord à bord : la moitié de WID est à x=1.6 et
# celle de NEI à x=3.2-1.6, donc leurs zones de bord sont centrées au MÊME point.
const FLUSH_X := 3.2

var win3d: Node3D
var player: Node3D

# Monde à une fenêtre seule, ou à deux fenêtres réellement collées.
func _build_world(with_neighbour: bool) -> Variant:
	win3d = Node3D.new()
	win3d.set_script(Windows3DScript)
	player = Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	player.add_child(cam)
	get_tree().root.add_child(player)
	get_tree().root.add_child(win3d)
	win3d.setup(null, player)
	win3d.on_window_mapped(WID, "Test Window", "app")
	(win3d.quads[WID].mesh as QuadMesh).size = MESH
	win3d.quads[WID].position = Vector3.ZERO
	if not with_neighbour:
		return true
	win3d.on_window_mapped(NEI, "Neighbour", "app")
	(win3d.quads[NEI].mesh as QuadMesh).size = MESH
	win3d.quads[NEI].position = Vector3(FLUSH_X, 0.0, 0.0)
	win3d.active_window_id = WID
	# Une seule fenêtre inventorie ses recouvrements : c'est ce que fait le
	# déplacement réel en tête de frame.
	win3d._sync_snap_monitoring(WID)
	# Le recouvrement de deux Area3D est un état du moteur physique : il
	# n'existe qu'après un pas de simulation.
	await get_tree().physics_frame
	await get_tree().physics_frame
	win3d._set_snap(WID, win3d._find_snap(Vector3.ZERO))
	if not win3d.snapped_to.has(WID):
		return "les deux fenêtres bord à bord ne se sont pas collées"
	return true

func _teardown(res: Variant) -> Variant:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()
	return res

func _fail(res: Variant) -> bool:
	return res is String and res != ""

func test_group_grab_is_unavailable_on_a_lone_window() -> Variant:
	## Un groupe d'une fenêtre est un grab ordinaire : l'entrée n'aurait rien
	## à proposer de plus que « GRAB ».
	var ctx: Variant = await _build_world(false)
	if _fail(ctx):
		return ctx
	if not win3d.has_method("can_group_grab"):
		return _teardown("windows_3d n'expose pas can_group_grab()")
	var res: Variant = Runner.assert_true(not win3d.can_group_grab(WID),
		"une fenêtre sans voisine ne doit pas proposer de grab de groupe")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(not win3d.can_group_grab(NEI),
		"une fenêtre inconnue ne doit pas proposer de grab de groupe")
	return _teardown(res)

func test_group_grab_is_available_on_a_snapped_window() -> Variant:
	var ctx: Variant = await _build_world(true)
	if _fail(ctx):
		return ctx
	if not win3d.has_method("can_group_grab"):
		return _teardown("windows_3d n'expose pas can_group_grab()")
	var res: Variant = Runner.assert_true(win3d.can_group_grab(WID),
		"une fenêtre réellement collée doit proposer le grab de groupe")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(win3d.can_group_grab(NEI),
		"la voisine d'un collage doit proposer le grab de groupe aussi")
	return _teardown(res)

func test_group_grab_is_unavailable_when_the_neighbour_is_gone() -> Variant:
	## Fermer la voisine efface SON entrée mais pas celle de WID, qui pointe
	## alors sur une fenêtre disparue : le groupe ne serait qu'un grab simple,
	## et l'anneau afficherait une entrée morte.
	var ctx: Variant = await _build_world(true)
	if _fail(ctx):
		return ctx
	if not win3d.has_method("can_group_grab"):
		return _teardown("windows_3d n'expose pas can_group_grab()")
	var gone: MeshInstance3D = win3d.quads[NEI]
	win3d._erase_window_state(NEI)
	gone.queue_free()
	win3d.quads.erase(NEI)
	var res: Variant = Runner.assert_true(win3d.snapped_to[WID].get("wid", -1) == NEI,
		"l'entrée de WID doit pointer sur la voisine disparue (état/authenticité)")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(not win3d.can_group_grab(WID),
		"une collab dont la voisine a disparu ne doit pas proposer le grab de groupe")
	return _teardown(res)

func test_group_grab_toggles_off() -> Variant:
	## Un grab de groupe amorcé par le radial n'a aucun appui physique derrière
	## lui : c'est l'anneau qui doit pouvoir le LÂCHER, sinon la fenêtre reste
	## accrochée au viseur pour toujours (aucun relâchement d'action ne peut
	## survenir).
	var ctx: Variant = await _build_world(true)
	if _fail(ctx):
		return ctx
	if not win3d.has_method("is_group_grabbed") or not win3d.has_method("toggle_group_grab"):
		return _teardown("windows_3d n'expose pas le basculement du grab de groupe")
	win3d.toggle_group_grab(WID)
	var res: Variant = Runner.assert_true(win3d.is_group_grabbed(WID),
		"la première validation doit saisir le groupe")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_eq(win3d._group_rel.size(), 1,
		"la voisine doit rejoindre le groupe")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(win3d._group_rel.has(NEI),
		"le groupe doit porter la voisine collée")
	if _fail(res):
		return _teardown(res)
	# Seconde validation, cible redevenue visible derrière le menu : on relaisse.
	win3d.toggle_group_grab(WID)
	res = Runner.assert_true(not win3d.is_group_grabbed(WID),
		"la seconde validation doit relâcher le groupe")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(not win3d.is_window_grabbed(WID),
		"plus aucune fenêtre ne doit rester saisie après le relâchement")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(win3d._group_rel.is_empty(),
		"le groupe doit être vidé, sinon les voisins restent détachés du monde")
	return _teardown(res)

func test_radial_offers_group_grab_only_for_a_grabbable_window() -> Variant:
	var menu := PanelContainer.new()
	menu.set_script(RadialMenu)
	if not _has_var(menu, "group_grab_available"):
		menu.free()
		return "radial_menu n'expose pas group_grab_available"
	menu.group_grab_available = false
	menu.show_menu("window")
	var res: Variant = Runner.assert_eq(_group_grab_items(menu).size(), 0,
		"sans groupe saisissable, l'anneau ne doit pas proposer GRAB GROUP")
	if _fail(res):
		menu.free()
		return res
	menu.group_grab_available = true
	menu.show_menu("window")
	res = Runner.assert_eq(_group_grab_items(menu).size(), 1,
		"une fenêtre visée et collée doit proposer GRAB GROUP")
	if _fail(res):
		menu.free()
		return res
	# Le contexte « fps » ne vise aucune fenêtre : l'entrée y serait morte.
	menu.show_menu("fps")
	res = Runner.assert_eq(_group_grab_items(menu).size(), 0,
		"hors d'un contexte « window », GRAB GROUP n'a pas sa place")
	menu.free()
	return res

func test_radial_renames_group_grab_while_it_is_grabbing() -> Variant:
	## Sans renommage, l'anneau proposerait « GRAB GROUP » pendant le grab :
	## le joueur ne verrait pas que c'est l'action de lâcher.
	var menu := PanelContainer.new()
	menu.set_script(RadialMenu)
	if not _has_var(menu, "group_grab_available") or not _has_var(menu, "group_grab_active"):
		menu.free()
		return "radial_menu n'expose pas group_grab_active"
	menu.group_grab_available = true
	menu.group_grab_active = false
	menu.show_menu("window")
	var res: Variant = Runner.assert_eq(_group_grab_labels(menu), ["GRAB GROUP"],
		"hors grab, l'entrée doit se lire GRAB GROUP")
	if _fail(res):
		menu.free()
		return res
	menu.group_grab_active = true
	menu.show_menu("window")
	res = Runner.assert_eq(_group_grab_labels(menu), ["DROP GROUP"],
		"pendant le grab, l'entrée doit devenir la libération")
	menu.free()
	return res

# Les entrées du radial qui lancent un grab de groupe.
func _group_grab_items(menu: Node) -> Array:
	var out: Array = []
	for item in menu._items:
		if str(item.get("action", "")) == "grab_group":
			out.append(item)
	return out

# Une variable de script exposée par get_property_list(), pas une propriété
# native : « x in noeud » ne la verrait pas.
func _has_var(node: Object, var_name: String) -> bool:
	for p in node.get_property_list():
		if str(p.get("name", "")) == var_name:
			return true
	return false

# Les libellés des entrées de grab de groupe.
func _group_grab_labels(menu: Node) -> Array:
	var out: Array = []
	for item in _group_grab_items(menu):
		out.append(str(item.get("label", "")))
	return out