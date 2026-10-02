extends Node
## Tests du réglage « disable snapping » (fenêtre GENERAL → Disable Window
## Snapping), qui coupe la détection de collage de windows_3d.gd.
##
## Le collage n'a qu'un seul point d'entrée de détection, _find_snap, et son
## état vit dans snapped_to. Deux comportements à verrouiller :
##  - couper le collage empêche les NOUVEAUX raccords : deux zones qui se
##    recouvrent ne sont plus appariées ;
##  - couper le collage n'arrache pas un collage DÉJÀ établi : il se poursuit et
##    reste lâchable par la distance du pointeur.
##
## Aucune liaison n'est installée à la main : les fenêtres sont réellement
## placées bord à bord et les recouvrements viennent du moteur physique. Un
## graphe de collage écrit à la main ne prouverait que le dictionnaire.

const Runner := preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")
const PauseMenu := preload("res://scripts/ui/pause_menu.gd")

const WID := 21
const NEI := 22
const MESH := Vector2(3.2, 2.0)

var win3d: Node3D
var player: Node3D

# Deux fenêtres de largeur 3.2 flush l'une contre l'autre : la moitié de WID est
# à x=1.6 et celle de NEI à x=3.2-1.6, donc leurs zones de bord sont centrées au
# MÊME point et se recouvrent. Distance de lâcher : 5.0, bien au-delà du seuil.
const FLUSH_X := 3.2
const FAR_AWAY := Vector3(5.0, 0.0, 0.0)

func _place_flush_pair() -> Variant:
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
	win3d.on_window_mapped(NEI, "Neighbour", "app")
	for wid in [WID, NEI]:
		if not win3d.quads.has(wid):
			return "le quad de la fenêtre %d n'a pas été créé" % wid
		(win3d.quads[wid].mesh as QuadMesh).size = MESH
	win3d.quads[WID].position = Vector3.ZERO
	win3d.quads[NEI].position = Vector3(FLUSH_X, 0.0, 0.0)
	win3d.active_window_id = WID
	# Une seule fenêtre inventorie ses recouvrements : c'est ce que fait le
	# déplacement réel en tête de frame.
	win3d._sync_snap_monitoring(WID)
	# Le recouvrement de deux Area3D est un état du moteur physique : il
	# n'existe qu'après un pas de simulation.
	await get_tree().physics_frame
	await get_tree().physics_frame
	return true

func _teardown(res: Variant) -> Variant:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()
	return res

func _fail(res: Variant) -> bool:
	return res is String and res != ""

func test_new_snap_is_refused_while_snapping_is_disabled() -> Variant:
	var ctx: Variant = await _place_flush_pair()
	if _fail(ctx):
		return ctx
	# Garde-fou du harnais : sans recouvrement réel des zones, la position des
	# quads ne produirait aucun collage et la suite ne prouverait rien.
	var snap: Dictionary = win3d._find_snap(Vector3.ZERO)
	var res: Variant = Runner.assert_eq(int(snap.get("wid", -1)), NEI,
		"deux fenêtres bord à bord doivent se coller quand le collage est actif")
	if _fail(res):
		return _teardown(res)
	if not win3d.has_method("set_snapping_enabled"):
		return _teardown("windows_3d n'expose pas set_snapping_enabled()")
	win3d.set_snapping_enabled(false)
	res = Runner.assert_true(win3d._find_snap(Vector3.ZERO).is_empty(),
		"le collage coupé doit refuser un nouveau raccord entre zones jointives")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(not win3d.snapped_to.has(WID),
		"aucune liaison ne doit être enregistrée tant que le collage est coupé")
	return _teardown(res)

func test_established_snap_survives_disabling() -> Variant:
	var ctx: Variant = await _place_flush_pair()
	if _fail(ctx):
		return ctx
	if not win3d.has_method("set_snapping_enabled"):
		return _teardown("windows_3d n'expose pas set_snapping_enabled()")
	# Collage établi par le vrai chemin : ce que renvoie la détection, écrit par
	# _set_snap.
	win3d._set_snap(WID, win3d._find_snap(Vector3.ZERO))
	var res: Variant = Runner.assert_true(win3d.snapped_to.has(WID),
		"le collage doit s'établir avant la coupure, sinon le test ne prouve rien")
	if _fail(res):
		return _teardown(res)
	win3d.set_snapping_enabled(false)
	res = Runner.assert_true(not win3d._find_snap(Vector3.ZERO).is_empty(),
		"couper la détection ne doit pas arracher un collage déjà établi")
	if _fail(res):
		return _teardown(res)
	res = Runner.assert_true(win3d._find_snap(FAR_AWAY).is_empty(),
		"un collage établi doit rester lâchable en tirant le pointeur au loin")
	return _teardown(res)

func test_snapping_setting_is_off_by_default() -> Variant:
	## Le réglage par défaut vaut « collage actif » : un défaut inversé
	## désactiverait le collage pour tout le monde, silencieusement, et
	## settings.json ne contient pas encore la clé.
	var menu := PanelContainer.new()
	menu.set_script(PauseMenu)
	if not menu.has_method("is_snapping_disabled"):
		menu.free()
		return "pause_menu n'expose pas is_snapping_disabled()"
	var res: Variant = Runner.assert_true(not menu.is_snapping_disabled(),
		"sans réglage enregistré, le collage doit rester actif")
	if _fail(res):
		menu.free()
		return res
	menu._settings["snapping_disabled"] = true
	res = Runner.assert_true(menu.is_snapping_disabled(),
		"le réglage enregistré doit être reflété au menu")
	menu.free()
	return res