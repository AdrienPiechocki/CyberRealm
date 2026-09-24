extends Node
## Tests du comportement de l'occluder pendant le grab de fenêtre
## (windows_3d.gd).
## Régression CPU : pendant un grab/drag/resize la fenêtre est déplacée (et
## rotatée au grab billboard) à chaque frame. Le moteur reconstruit alors toute
## la scène Embree à chaque frame (raycast_occlusion_cull.cpp) ; le fix
## DÉTACHE le base de l'occluder (occ.occluder = null) pendant le déplacement
## et le réattache au lâcher.
## Toutes les entrées de déplacement partagent le même helper
## _set_window_occluder_active : toggle_grab_window (menu + radial),
## process_raycast (Super+G en visant une fenêtre), resize et les deux drags
## move_2d (tranche du contenu + barre de titre 3D).

const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

var win3d: Node3D
var player: Node3D

# Construit le monde de test : Windows3D + Player/Camera3D + une fenêtre mappée.
# Renvoie true (ok) ou un message d'erreur.
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
	win3d.on_window_mapped(7, "Test Window", "app")
	if not win3d.quads.has(7):
		return "le quad de la fenêtre 7 n'a pas été créé"
	return true

# Renvoie l'OccluderInstance3D de la fenêtre 7, ou un message d'erreur.
func _as_occluder() -> Variant:
	var quad: Node3D = win3d.quads[7]
	if not is_instance_valid(quad):
		return "quad 7 invalide"
	var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
	if occ == null:
		return "Occluder manquant sur le quad 7"
	return occ

# Vérifie que l'occluder de la fenêtre 7 (ne) participe (pas) à l'occlusion
# culling. "Participation" = le base occluder est attaché (occ.occluder !=
# null, non détaché pendant un grab) ET l'instance est visible dans l'arbre
# (combine la visibilité du quad parent, cas du hide). Un occluder "participant"
# alimente le buffer d'occlusion ; pendant un grab il doit être DÉTACHÉ
# (occ.occluder == null), car le simple masquage ne suffit pas à arrêter la
# reconstruction Embree déclenchée par les changements de transform par frame.
func _assert_occluder(what: String, expected: bool) -> Variant:
	var occ: Variant = _as_occluder()
	if not (occ is OccluderInstance3D):
		return occ
	var occ_node := occ as OccluderInstance3D
	var participates: bool = occ_node.occluder != null and occ_node.is_visible_in_tree()
	if participates != expected:
		return "occluder %s: attendu participants=%s, trouvé=%s (occluder=%s)" % [
			what, str(expected), str(participates), str(occ_node.occluder)]
	return true

func _teardown() -> void:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()

func test_occluder_hidden_while_grabbed() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	var ok: Variant = _assert_occluder("hors grab", true)
	if ok != true:
		return ok
	win3d.toggle_grab_window(7)
	if not win3d.is_moving:
		return "is_moving devrait être actif après toggle_grab_window"
	ok = _assert_occluder("pendant le grab", false)
	if ok != true:
		return ok
	win3d.release_window_grab(7)
	if win3d.is_moving:
		return "is_moving devrait être inactif après release_window_grab"
	ok = _assert_occluder("après le grab", true)
	if ok != true:
		return ok
	_teardown()
	return true

func test_toggle_grab_restores_occluder() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	# Toggle du menu fenêtres : un second appel (relâcher) doit passer par
	# release_window_grab et remettre l'occluder en place.
	win3d.toggle_grab_window(7)
	if not win3d.is_moving:
		return "is_moving devrait être actif après le 1er toggle"
	win3d.toggle_grab_window(7)
	if win3d.is_moving:
		return "is_moving devrait être inactif après le 2nd toggle"
	var ok: Variant = _assert_occluder("après double toggle", true)
	if ok != true:
		return ok
	_teardown()
	return true

func test_grab_then_hide_keeps_occluder_hidden() -> Variant:
	var build: Variant = _build_world()
	if build != true:
		return build
	win3d.toggle_grab_window(7)
	win3d.release_window_grab(7)
	win3d.toggle_hide(7)
	var ok: Variant = _assert_occluder("fenêtre cachée", false)
	if ok != true:
		return ok
	# Repasser une fenêtre cachée visible : l'occluder doit suivre, pas être
	# réactivé par un grab ultérieur fantôme.
	win3d.toggle_hide(7)
	ok = _assert_occluder("fenêtre re-visible", true)
	if ok != true:
		return ok
	_teardown()
	return true