extends Node
## Grab, déplacement et redimensionnement des fenêtres (individuels et en groupe collé).
##
## Module de Windows3D (nœud enfant « Grab »), créé par la façade : l'état partagé vit dans la façade
## (`w3d`), l'état propre au module vit ici.

const Windows3D := preload("res://scripts/windows/windows_3d.gd")
var w3d: Windows3D = null

						 # pour rester cliquable via raycast) = redimensionnement diagonal
const MIN_SURFACE_SIZE = 500 # px, garde-fou anti-fenêtre-écrasée

# Redimensionnement: même principe de rayon à profondeur fixe, mais on
# garde aussi la base locale du quad et ses dimensions de départ pour
# convertir le déplacement du viseur (unités monde) en pixels de surface.
var resize_depth := 0.0
var resize_start_world := Vector3.ZERO
var resize_right_dir := Vector3.RIGHT
var resize_up_dir := Vector3.UP
var window_start_size := Vector2.ZERO # taille geometry (px) au moment du grab
var window_start_mesh_size := Vector2.ONE # taille quad (unités monde) au moment du grab
var window_start_local_pos := Vector3.ZERO # position locale du quad au moment du grab
var window_start_content_offset := Vector2.ZERO # offset geometry dans la surface au moment du grab
# Charnière du redimensionnement en cours : "" (plan), "yaw" (bord latéral
# partagé tiré) ou "pitch" (bord haut/bas partagé tiré). Le bord tiré peut alors
# bouger en PROFONDEUR, donc la fenêtre tirée pivote autour de son bord opposé
# (et sa voisine aussi, cf. _update_shared_edge). La profondeur se règle en
# regardant le long de l'axe du pivot (voir hinge_mode_for / RESIZE_DEPTH_GAIN).
var resize_hinge_mode := ""
var resize_start_basis := Basis.IDENTITY
var resize_start_pos := Vector3.ZERO
var _group_rel: Dictionary = {} # wid -> Transform3D relatif à la fenêtre saisie

# La fenêtre actuellement déplacée (grab menu), -1 si aucune.
func get_grabbed_window_id() -> int:
	return w3d.active_window_id if w3d.is_moving else -1

func is_window_grabbed(wid: int) -> bool:
	return w3d.is_moving and w3d.active_window_id == wid

func release_window_grab(wid: int) -> void:
	if not is_window_grabbed(wid):
		return
	w3d.is_moving = false
	w3d.active_window_id = -1
	_end_group_grab()
	w3d._set_window_occluder_active(wid, true)
	w3d.windows_state_changed.emit()

# Toggle grab depuis le menu fenêtres : reprend une fenêtre déjà en cours de
# déplacement (is_moving) ou lâche la prise et la pose à sa position actuelle.
## `at_spawn_distance` : la fenêtre saisie est amenée à SPAWN_DISTANCE du joueur
## (grab depuis le window_menu, où la fenêtre peut être loin ou hors de vue) au
## lieu de garder sa distance actuelle.
func toggle_grab_window(wid: int, at_spawn_distance := false) -> void:
	if is_window_grabbed(wid):
		release_window_grab(wid)
		return
	if not w3d.quads.has(wid) or not is_instance_valid(w3d.quads[wid]):
		return
	var quad: MeshInstance3D = w3d.quads[wid]
	var cam := w3d._camera()
	w3d.active_window_id = wid
	w3d.is_moving = true
	w3d._set_window_occluder_active(wid, false)
	w3d.move_depth = Windows3D.SPAWN_DISTANCE if at_spawn_distance else cam.global_position.distance_to(quad.global_position)
	w3d.windows_state_changed.emit()

func _release_resize_gesture(wid: int) -> void:
	w3d._set_window_occluder_active(wid, true)
	w3d.is_resizing = false
	_end_group_resize()
	w3d.resizing_edge = ""
	w3d.active_window_id = -1

# Lance un redimensionnement sur le côté `edge` de la fenêtre `wid`, d'après la
# position de la fenêtre et le point visé par le rayon caméra au moment du clic.
#
# Les deux entrées passent par ici : le drag d'un bord de la fenêtre et le drag
# de sa barre de titre (côté "top"). L'état de départ est identique dans les
# deux cas, donc il n'est figé qu'une fois — sans quoi les deux sites
# divergeaient dès qu'un champ de plus était ajouté.
#
# `edge` ne contient jamais "left"/"right" pour un drag de barre de titre : le
# pivot en profondeur n'a de sens que sur un bord PARTAGÉ, où le bord commun
# bouge pour les deux fenêtres. Le mode est donc déduit du voisinage, pas du
# côté tiré seul (voir hinge_mode_for).
func _start_resize(wid: int, quad: MeshInstance3D, ray_origin: Vector3,
		ray_dir: Vector3, edge: String) -> void:
	if not w3d.quads.has(wid) or not is_instance_valid(quad):
		return
	var body: StaticBody3D = quad.get_child(0)
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var content_offset: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var content_size: Vector2 = body.get_meta("content_size", win_size)
	if content_size.x <= 0 or content_size.y <= 0:
		content_offset = Vector2.ZERO

	w3d.active_window_id = wid
	w3d.resizing_edge = edge
	w3d.is_resizing = true
	# Même détachement d'occluder que toggle_grab_window : le quad réécrit sa
	# transform à chaque frame du drag, ce qui reconstruction Embree à chaque
	# frame. Le réattache se fait au relâchement.
	w3d._set_window_occluder_active(wid, false)
	resize_depth = w3d._camera().global_position.distance_to(quad.global_position)
	resize_start_world = ray_origin + ray_dir * resize_depth
	resize_right_dir = quad.global_transform.basis.x.normalized()
	resize_up_dir = quad.global_transform.basis.y.normalized()
	window_start_size = win_size
	window_start_content_offset = content_offset
	window_start_mesh_size = (quad.mesh as QuadMesh).size
	window_start_local_pos = quad.position
	resize_start_basis = quad.global_basis
	resize_start_pos = quad.global_position
	_begin_group_resize(wid, edge)
	# Charnière : uniquement si le bord TIRÉ est partagé avec une voisine. Un
	# coin dont le côté latéral est partagé reste en lacet ; un coin partagé par
	# le haut ou le bas seulement passe en tangage ; sans voisin, le resize est
	# plan, barre de titre comprise (le regard vertical y est la hauteur).
	# Charnière désactivée (RESIZE_HINGE_ENABLED) : un bord partagé ne se déplace
	# que sur l'axe des fenêtres liées, jamais en profondeur ni en pivotant.
	resize_hinge_mode = hinge_mode_for(edge, _shared_sides()) if RESIZE_HINGE_ENABLED else ""

# La fenêtre suit le viseur le long du rayon caméra, à profondeur figée
# (distance capturée au moment du grab) - fonctionne même si la souris ne
# se déplace jamais à l'écran (mode capturé), puisque seule l'orientation
# de la caméra entre ici en jeu.
func _update_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if w3d.active_window_id == -1 or not w3d.quads.has(w3d.active_window_id):
		return
	var quad: MeshInstance3D = w3d.quads[w3d.active_window_id]
	var cam: Camera3D = w3d._camera()
	w3d.snap._sync_snap_monitoring(w3d.active_window_id)
	# Plus de translation latérale à la souris pendant le grab 3D.
	# Son décalage était cumulé SANS borne et réinjecté dans target_pos AVANT
	# la recherche de snap : le point visé s'éloignait donc progressivement des
	# zones, le collage sautait, la fenêtre repartait face caméra, et le
	# décalage continuait de croître tant que le bouton restait enfoncé. C'était
	# l'un des deux moteurs de l'oscillation observée en jeu. Le snap ajuste
	# déjà la position : la translation était redondante ET destructrice.
	var target_pos = ray_origin + ray_dir * w3d.move_depth
	# Collage : la position visée est corrigée vers le bord d'une fenêtre
	# voisine AVANT le lerp, sinon la fenêtre ne s'accroche jamais
	# (le lerp la ramène vers le point brut à chaque frame).
	var snap := w3d.snap._find_snap(target_pos)
	var was_snapped := w3d.snapped_to.has(w3d.active_window_id)
	# L'orientation AVANT la position, et non l'inverse.
	#
	# Les zones sont des ENFANTS du quad : écrire la base de la voisine les
	# DÉPLACE. Caler d'abord, tourner ensuite, donnait un point de collage
	# immédiatement périmé — les zones sortaient de la voisine, le collage
	# sautait, la fenêtre repassait face caméra, et le cycle se refermait à la
	# frame suivante. On reste alors collé sans jamais tenir : la fenêtre
	# oscille tant qu'on la tient.
	# L'orientation n'est adoptée qu'UNE fois, à l'entrée dans le collage (dans
	# _set_snap). La réécrire à chaque frame annulait le scroll de rotation.
	w3d.snap._set_snap(w3d.active_window_id, snap)
	if not snap.is_empty():
		# Recalculé APRÈS le changement d'orientation : _find_snap a raisonné
		# sur les zones telles qu'elles étaient AVANT, donc sur une base qui
		# n'est plus celle du quad. Le recalcul se fait dans le repère final,
		# et le calage reste exact bord à bord.
		target_pos = w3d.snap._snap_flush_position(w3d.active_window_id, snap)
	# Déplacement fluide
	quad.global_position = quad.global_position.lerp(
		target_pos,
		10.0 * delta
	)
	# Les fenêtres collées SUR celle-ci ne la suivent pas : leur liaison meurt
	# dès qu'elle s'en écarte (sinon, ressaisies, elles sauteraient vers elle).
	w3d.snap._drop_stale_links_to(w3d.active_window_id)

	# Orientation : deux régimes, et c'est le COLLAGE qui les sépare.
	#
	# LIBRE : la fenêtre suit la caméra. Elle reste face au joueur pendant
	# qu'il la déplace, et suit sa tête s'il regarde ailleurs — sans cela on la
	# manipule de biais et on ne lit plus ce qu'elle affiche. On écrit
	# l'ÉTAT STOCKÉ aussi, sinon la rotation au collage relirait plus tard une
	# base périmée et la fenêtre se replacerait d'un coup.
	#
	# COLLÉE : au contraire, elle fige l'orientation de sa voisine (écrite par
	# _adopt_neighbour_basis). La suivre ici anéantirait la rotation au
	# collage à la frame suivante, et le raccord VR ne serait plus plat.
	#
	# `was_snapped` — l'état de la frame PRÉCÉDENTE — et non celui calculé
	# plus haut. Dès qu'une fenêtre est ENGAGÉE dans un collage, son
	# orientation lui appartient : la laisser repartir face caméra pendant
	# une frame suffirait à faire perdre le recouvrement que le collage vient
	# d'établir, et la fenêtre clignoterait entre les deux orientations pour
	# toute la durée du grab. Le recouvrement est mesuré sur la pose
	# précédente, donc l'orientation ne doit l'être qu'une fois le collage
	# réel : c'est le tout premier frame, où elle n'était pas encore engagée.
	if snap.is_empty() and not was_snapped:
		w3d.snap._store_basis(w3d.active_window_id, cam.global_transform.basis)

# ── Redimensionnement synchronisé du groupe collé ────────────────────────
#
# Redimensionner une fenêtre déplace son bord, donc les fenêtres collées de ce
# côté doivent suivre (et celles qui leur sont collées derrière elles) : le
# groupe se translate comme un bloc. On ne translate que le long de la normale
# du bord — le décalage latéral entre voisines est conservé.
#
# Une entrée par fenêtre directement collée à la redimensionnée :
# {side (côté de la redimensionnée), zone_start, members: [{wid, pos}]}.
var _resize_links: Array = []

# Voisines directes d'une fenêtre dans le graphe de collage (les deux sens).
func _snap_neighbours(wid: int) -> Array:
	var out: Array = []
	var own: Dictionary = w3d.snapped_to.get(wid, {})
	if not own.is_empty():
		out.append({"wid": int(own.get("wid", -1)), "side": str(own.get("our_side", ""))})
	for other in w3d.snapped_to:
		var sn: Dictionary = w3d.snapped_to[other]
		if other != wid and int(sn.get("wid", -1)) == wid:
			out.append({"wid": int(other), "side": str(sn.get("side", ""))})
	return out

# Toutes les fenêtres atteignables depuis `start` sans repasser par `visited`.
func _collect_group(start: int, visited: Dictionary) -> Array:
	var members: Array = []
	var queue: Array = [start]
	visited[start] = true
	while not queue.is_empty():
		var w: int = queue.pop_front()
		members.append(w)
		for n in _snap_neighbours(w):
			var nw := int(n["wid"])
			if nw != -1 and w3d.quads.has(nw) and not visited.has(nw):
				visited[nw] = true
				queue.append(nw)
	return members

# `edge` non vide (drag d'un bord) : la voisine collée sur ce bord le PARTAGE.
# Le bord commun bouge pour les deux fenêtres, mais leurs bords EXTÉRIEURS (le
# bord opposé de la tirée, le bord lointain de la voisine) restent en place :
# chacune pivote autour du sien pour garder le contact avec le bord commun. Les
# voisines des autres côtés, et tout le groupe lors d'un maximize (`edge`
# vide), sont simplement translatées avec leur zone de collage.
func _begin_group_resize(wid: int, edge: String = "") -> void:
	_resize_links.clear()
	w3d._resize_shared.clear()
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null:
		return
	var visited := {wid: true}
	for link in _snap_neighbours(wid):
		var nw := int(link["wid"])
		if nw == -1 or not w3d.quads.has(nw) or visited.has(nw):
			continue
		var side: String = link["side"]
		var area := quad.get_node_or_null(w3d.snap._zone_path(side)) as Area3D
		if area == null:
			continue
		if edge != "" and edge.contains(side):
			var nq: MeshInstance3D = w3d.quads[nw]
			var nbody: StaticBody3D = nq.get_child(0)
			visited[nw] = true
			w3d._set_window_occluder_active(nw, false)
			# Zones de la voisine : `near` touche notre bord, `far` est son bord
			# opposé (reste en place pendant tout le drag). `near_delta` = écart initial entre
			# sa zone proche et la nôtre (nul tant que rien n'a décalé les deux
			# fenêtres), conservé pendant tout le drag pour ne pas recentrer la
			# voisine.
			var near_zone := nq.get_node_or_null(w3d.snap._zone_path(_opposite_side(side))) as Area3D
			var far_zone := nq.get_node_or_null(w3d.snap._zone_path(side)) as Area3D
			if near_zone == null or far_zone == null:
				continue
			w3d._resize_shared.append({
				"side": side, "wid": nw,
				"near_delta": near_zone.global_transform.origin - area.global_transform.origin,
				"far": far_zone.global_transform.origin,
				"basis": nq.global_basis,
				"mesh": (nq.mesh as QuadMesh).size,
				"px": nbody.get_meta("surface_size", Vector2(1, 1)),
				"offset": nbody.get_meta("content_offset", Vector2.ZERO),
				"pos": nq.global_position,
			})
			continue
		var members: Array = []
		for m in _collect_group(nw, visited):
			var q: MeshInstance3D = w3d.quads[m]
			if is_instance_valid(q):
				members.append({"wid": m, "pos": q.global_position})
		_resize_links.append({
			"kind": "translate",
			"side": side,
			"zone_start": area.global_transform.origin,
			"members": members,
		})

func _end_group_resize() -> void:
	resize_hinge_mode = ""
	for r in w3d._resize_shared:
		w3d._set_window_occluder_active(int(r["wid"]), true)
	w3d._resize_shared.clear()
	_resize_links.clear()
	w3d.windows_state_changed.emit()

# Côtés de la fenêtre redimensionnée qui portent une voisine collée ET
# partagent le bord tiré (donc une entrée par _resize_shared).
func _shared_sides() -> Array:
	var out: Array = []
	for r in w3d._resize_shared:
		out.append(str(r["side"]))
	return out

# Croissance MAX (monde) de la fenêtre tirée sur l'axe horizontal ou vertical :
# la voisine ne doit pas passer sous MIN_SURFACE_SIZE.
func _shared_growth_limit(horizontal: bool) -> float:
	var limit := INF
	for r in w3d._resize_shared:
		var side: String = r["side"]
		if (side == "left" or side == "right") != horizontal:
			continue
		var mesh: Vector2 = r["mesh"]
		var px: Vector2 = r["px"]
		var m := mesh.x if horizontal else mesh.y
		var p := px.x if horizontal else px.y
		limit = min(limit, max(m * (1.0 - MIN_SURFACE_SIZE / max(p, 1.0)), 0.0))
	return limit

func _opposite_side(side: String) -> String:
	match side:
		"left": return "right"
		"right": return "left"
		"top": return "bottom"
		"bottom": return "top"
	return ""

# Redimensionne ET fait pivoter la voisine qui PARTAGE le bord tiré (la fenêtre
# tirée est déjà à jour : voir _update_resize).
#
# Le bord commun suit le viseur, y compris en profondeur. Le bord LOINTAIN de la
# voisine ne bouge pas : c'est son pivot, comme le bord opposé de la tirée.
#
#  - bord PROCHE = zone de la tirée (déplacée) + écart initial ;
#  - bord LOINTAIN = fixe ;
#  - orientation : rotation autour de l'axe du bord (vertical pour un collage
#    latéral) qui aligne l'axe de largeur sur « proche -> lointain ». Avec des
#    rotations égales (fenêtres coplanaires) l'angle est nul : on retrouve le
#    simple redimensionnement ;
#  - taille sur l'axe du collage = distance entre les deux bords (mesh,
#    collision et surface côté client, à densité de pixels constante), jamais
#    sous MIN_SURFACE_SIZE ;
#  - centre déduit de la position de sa zone proche, comme au collage.
func _update_shared_edge(_d_x: float, _d_y: float) -> void:
	var xq: MeshInstance3D = w3d.quads.get(w3d.active_window_id, null)
	if xq == null:
		return
	for r in w3d._resize_shared:
		var nw := int(r["wid"])
		var nq: MeshInstance3D = w3d.quads.get(nw, null)
		if nq == null or not is_instance_valid(nq):
			continue
		var side: String = r["side"]
		var xz := xq.get_node_or_null(w3d.snap._zone_path(side)) as Area3D
		if xz == null:
			continue
		var near_side := _opposite_side(side)
		var horizontal := side == "left" or side == "right"
		var b0: Basis = r["basis"]
		var near_pt: Vector3 = xz.global_transform.origin + Vector3(r["near_delta"])
		var far_pt: Vector3 = r["far"]
		# Sens proche -> lointain dans le repère DE DÉPART de la voisine, et
		# axe du bord autour duquel elle pivote (hauteur pour un collage latéral,
		# largeur pour un collage vertical).
		var dir_old: Vector3
		match side:
			"right": dir_old = b0.x
			"left": dir_old = -b0.x
			"top": dir_old = b0.y
			_: dir_old = -b0.y
		dir_old = dir_old.normalized()
		var axis := (b0.y if horizontal else b0.x).normalized()
		var want := far_pt - near_pt
		want -= axis * want.dot(axis)
		var span := want.length()
		var nb := b0
		if span > 0.001:
			var angle := dir_old.signed_angle_to(want / span, axis)
			nb = Basis(axis, angle) * b0
		else:
			span = 0.001
		var mesh0: Vector2 = r["mesh"]
		var px0: Vector2 = r["px"]
		var off: Vector2 = r["offset"]
		var mesh1 := mesh0
		var px1 := px0
		if horizontal:
			# Jamais sous la taille minimale : le mesh et les pixels restent
			# cohérents quand le bord commun se rapproche trop du bord lointain.
			mesh1.x = max(span, mesh0.x * MIN_SURFACE_SIZE / max(px0.x, 1.0))
			px1.x = max(px0.x * mesh1.x / max(mesh0.x, 0.001), MIN_SURFACE_SIZE)
		else:
			# La zone haute/basse est portée par l'empreinte VISIBLE (mesh +
			# cadre + bandeau de titre). `deco` est calculé sur le mesh COURANT
			# de la voisine : c'est l'épaisseur telle qu'elle était avant le
			# drag, donc bien l'empreinte visible à retrancher du `span`.
			var deco := w3d.snap._deco_of(nq)
			mesh1.y = max(span - deco["titlebar"] - deco["border"], mesh0.y * MIN_SURFACE_SIZE / max(px0.y, 1.0))
			px1.y = max(px0.y * mesh1.y / max(mesh0.y, 0.001), MIN_SURFACE_SIZE)
		(nq.mesh as QuadMesh).size = mesh1
		var nbody: StaticBody3D = nq.get_child(0)
		nbody.set_meta("user_sized", true)
		var shape: BoxShape3D = (nbody.get_child(0) as CollisionShape3D).shape
		shape.size = Vector3(mesh1.x, mesh1.y, shape.size.z)
		# Orientation écrite dans l'ÉTAT STOCKÉ aussi : c'est lui que relisent
		# la rotation au scroll et la règle des 3 fenêtres.
		w3d.snap._store_basis(nw, nb)
		w3d._sync_decorations(nq)
		w3d.compositor.set_window_size(nw, int(px1.x) + int(off.x) * 2, int(px1.y) + int(off.y) * 2)
		w3d.fullscreen_windows[nw] = false
		var near_local := Windows3D.SnapModule.snap_zone_local_offset(Windows3D.SnapModule.visual_half_extent(mesh1, w3d.snap._deco_of(nq)), near_side)
		nq.global_position = near_pt - nb * near_local

func _update_group_resize(wid: int) -> void:
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null or _resize_links.is_empty():
		return
	for link in _resize_links:
		if link["kind"] != "translate":
			continue
		var area := quad.get_node_or_null(w3d.snap._zone_path(link["side"])) as Area3D
		if area == null:
			continue
		var zb := area.global_transform.basis
		var side: String = link["side"]
		var normal := (zb.y if side == "top" or side == "bottom" else zb.x).normalized()
		var moved := area.global_transform.origin - Vector3(link["zone_start"])
		var shift := normal * moved.dot(normal)
		for m in link["members"]:
			var q: MeshInstance3D = w3d.quads.get(m["wid"], null)
			if q != null and is_instance_valid(q):
				q.global_position = Vector3(m["pos"]) + shift

# ── Redimensionnement (fonctions PURES) ─────────────────────────────────
#
# Un bord tiré grandit VERS L'EXTÉRIEUR : tirer le bord droit vers la droite
# agrandit, tirer le bord haut vers le haut agrandit aussi (et non l'inverse,
# qui est le piège de lecture quand on passe des px aux unités monde, y vers le
# haut). La largeur ne bouge que si le côté tiré est latéral, la hauteur que si
# le côté tiré est horizontal — d'où un bord haut qui ne touche QUE la hauteur,
# bord bas et largeur inchangés.

# Taille de surface après le déplacement `d` (unités monde, dans la base du
# quad) du côté `edge`, au ratio `px_per_unit` figé au grab.
static func resized_surface_size(start: Vector2, edge: String, d: Vector2,
		px_per_unit: Vector2) -> Vector2:
	var out := start
	if "right" in edge:
		out.x = start.x + d.x * px_per_unit.x
	elif "left" in edge:
		out.x = start.x - d.x * px_per_unit.x
	if "bottom" in edge:
		out.y = start.y - d.y * px_per_unit.y
	elif "top" in edge:
		out.y = start.y + d.y * px_per_unit.y
	return out

## Profondeur d'un bord partagé tiré, pilotée par le REGARD le long de l'axe du
## pivot : vertical en lacet, horizontal en tangage.
##
## En regardant plus HAUT (lacet) ou plus À DROITE (tangage) que là où le drag a
## commencé, le bord s'éloigne ; l'inverse le rapproche. L'écart du point visé,
## exprimé en mètres dans la base de la fenêtre au grab, est converti en mètres
## de profondeur avec ce gain. Mettre une valeur négative inverse le sens.
## Rien n'est lu pendant un drag de coin : le regard le long de l'axe du pivot
## y règle déjà l'autre dimension.
const RESIZE_DEPTH_GAIN := 1.0

## Autorise le pivot (lacet/tangage) d'un bord partagé tiré. Désactivé : le bord
## partagé reste dans le plan et ne glisse que le long de l'axe de collage
## (horizontal pour un collage latéral, vertical pour un collage haut/bas).
const RESIZE_HINGE_ENABLED := false

## Charnière d'un drag : "" (plan), "yaw" (bord latéral tiré) ou "pitch" (bord
## haut/bas tiré).
##
## Elle n'existe que si le bord TIRÉ est PARTAGÉ avec une voisine collée : le
## bord commun bouge pour les deux fenêtres, donc le pivot en profondeur est
## visible des deux côtés. Sans voisin, les quatre côtés restent plans — y
## compris les latéraux, dont le lacet n'aurait rien à partager.
##
## `shared_sides` : les côtés de CETTE fenêtre qui portent une voisine collée.
## Un coin dont les deux côtés sont partagés reste en lacet : c'est le seul mode
## où les deux fenêtres peuvent se suivre mutuellement.
static func hinge_mode_for(edge: String, shared_sides: Array) -> String:
	var lateral := false
	var vertical := false
	for s in shared_sides:
		var side := str(s)
		if side == "left" or side == "right":
			lateral = true
		elif side == "top" or side == "bottom":
			vertical = true
	if lateral and ("left" in edge or "right" in edge):
		return "yaw"
	if vertical and ("top" in edge or "bottom" in edge):
		return "pitch"
	return ""

## Charnière : géométrie pure d'un drag en lacet ou en tangage.
##
## Le bord OPPOSÉ au bord tiré est le pivot et reste fixe ; le bord tiré suit le
## point visé dans le plan de la fenêtre, qui pivote pour pointer vers lui. Le
## composant du déplacement le long de l'axe du pivot (le vertical en lacet,
## l'horizontale en tangage) est retiré du plan — le pivot ne peut pas le suivre
## — et converti en profondeur (RESIZE_DEPTH_GAIN), sauf si le côté
## perpendiculaire est lui aussi tiré, auquel cas ce regard règle déjà cette
## dimension.
##
## Renvoie :
##  - basis : orientation de la fenêtre après rotation autour de l'axe du pivot ;
##  - delta : croissance (unités monde) à passer à resized_surface_size, seule
##    l'axe de la charnière est renseignée — le côté perpendiculaire reste à la
##    charge du delta projeté par l'appelant ;
##  - pivot : direction du bord opposé vers le bord tiré, au moment du grab
##    (signe compris) : c'est la position du pivot qui en découle ;
##  - out : la même direction dans la base tournée, du pivot vers le nouveau
##    centre.
static func resize_hinge(mode: String, edge: String, basis: Basis,
		mesh_size: Vector2, world_delta: Vector3) -> Dictionary:
	var x0 := basis.x.normalized()
	var y0 := basis.y.normalized()
	if mode == "":
		return {"basis": basis, "delta": Vector2.ZERO, "pivot": Vector3.ZERO, "out": Vector3.ZERO}
	var yaw := mode == "yaw"
	var axis := (y0 if yaw else x0).normalized()
	var sgn := 1.0 if (("right" in edge) if yaw else ("top" in edge)) else -1.0
	var extent: float = mesh_size.x if yaw else mesh_size.y
	var pivot := (x0 if yaw else y0) * sgn
	# Le côté perpendiculaire est-il aussi tiré ? (coin)
	var corner := (("top" in edge) or ("bottom" in edge)) if yaw \
		else (("left" in edge) or ("right" in edge))
	var along := world_delta.dot(axis)
	var depth := Vector3.ZERO
	if not corner:
		depth = -basis.z.normalized() * (along * RESIZE_DEPTH_GAIN)
	var target := pivot * extent + (world_delta - axis * along) + depth
	var nb := basis
	if target.length() > 0.001:
		nb = Basis(axis, pivot.signed_angle_to(target.normalized(), axis)) * basis
	var delta := Vector2.ZERO
	var growth := target.length() - extent
	if yaw:
		delta.x = sgn * growth
	else:
		delta.y = sgn * growth
	return {
		"basis": nb,
		"delta": delta,
		"pivot": pivot,
		"out": (nb.x.normalized() * sgn) if yaw else (nb.y.normalized() * sgn),
	}

func _update_resize(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if w3d.active_window_id == -1 or not w3d.quads.has(w3d.active_window_id):
		return
	var quad: MeshInstance3D = w3d.quads[w3d.active_window_id]
	var mesh: QuadMesh = quad.mesh

	# Delta du viseur (unités monde) projeté sur la même profondeur figée
	# qu'au moment du grab, puis exprimé dans la base locale du quad.
	var cur_world := ray_origin + ray_dir * resize_depth
	var world_delta := cur_world - resize_start_world
	var local_dx := world_delta.dot(resize_right_dir)
	var local_dy := world_delta.dot(resize_up_dir)

	# Charnière (bord tiré PARTAGÉ) : le bord commun suit le point visé, en
	# lacet comme en tangage, et le bord opposé reste fixe. La rotation, la
	# croissance et la profondeur sont calculées par resize_hinge ; le côté
	# perpendiculaire d'un coin reste sur le delta projeté ci-dessus.
	var hinge := {}
	if resize_hinge_mode != "":
		hinge = resize_hinge(resize_hinge_mode, w3d.resizing_edge, resize_start_basis,
			window_start_mesh_size, world_delta)
		local_dx = (hinge["delta"] as Vector2).x
		local_dy = (hinge["delta"] as Vector2).y

	# Ratio pixels de surface / unité monde, figé au grab (le mesh ne
	# change pas de taille pendant le drag, seul window_texture_updated
	# le fera une fois le client redessiné à la nouvelle taille).
	var px_per_unit_x: float = window_start_size.x / max(window_start_mesh_size.x, 0.001)
	var px_per_unit_y: float = window_start_size.y / max(window_start_mesh_size.y, 0.001)

	var new_size := resized_surface_size(window_start_size, w3d.resizing_edge,
		Vector2(local_dx, local_dy),
		Vector2(px_per_unit_x, px_per_unit_y))
	var new_w := new_size.x
	var new_h := new_size.y

	# La voisine qui partage le bord tiré rétrécit d'autant : la croissance est
	# bornée pour qu'elle ne passe pas sous la taille minimale. Un bord HAUT
	# partagé tire la voisine par son bord bas, donc la borne vaut aussi pour
	# "top".
	if "left" in w3d.resizing_edge or "right" in w3d.resizing_edge:
		new_w = min(new_w, window_start_size.x + _shared_growth_limit(true) * px_per_unit_x)
	if "bottom" in w3d.resizing_edge or "top" in w3d.resizing_edge:
		new_h = min(new_h, window_start_size.y + _shared_growth_limit(false) * px_per_unit_y)
	new_w = max(new_w, MIN_SURFACE_SIZE)
	new_h = max(new_h, MIN_SURFACE_SIZE)

	# set_window_size envoie les dimensions de la SURFACE (buffer) au client
	# Wayland, pas la geometry. Les ombres CSD sont typiquement symétriques,
	# donc surface = geometry + 2 * content_offset.
	var surface_w := int(new_w) + int(window_start_content_offset.x) * 2
	var surface_h := int(new_h) + int(window_start_content_offset.y) * 2
	w3d.compositor.set_window_size(w3d.active_window_id, surface_w, surface_h)
	w3d.fullscreen_windows[w3d.active_window_id] = false
	# Met à jour la taille du mesh ET la position en même temps pour que
	# le bord fixe reste immobile pendant le drag. Sans cette mise à jour,
	# seul le position changeait → le bord "fixe" dérivait car le mesh
	# gardait l'ancienne taille (causant le tearing visible pendant le
	# resize).
	var new_mesh_w: float = window_start_mesh_size.x * (new_w / max(window_start_size.x, 1.0))
	var new_mesh_h: float = window_start_mesh_size.y * (new_h / max(window_start_size.y, 1.0))
	mesh.size = Vector2(new_mesh_w, new_mesh_h)

	# La CollisionShape3D doit suivre la même taille que le mesh.
	var body: StaticBody3D = quad.get_child(0)
	# Une fenêtre redimensionnée à la main garde sa taille monde : on_texture_updated
	# ne doit plus la recalculer d'après les pixels (voir user_sized là-bas).
	body.set_meta("user_sized", true)
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(new_mesh_w, new_mesh_h, shape.size.z)
	w3d._sync_decorations(quad)

	# Repositionne le bord fixe: le shift compense exactement la moitié
	# du delta taille, de sorte que le bord opposé ne bouge pas.
	var delta_w_world: float = (new_mesh_w - window_start_mesh_size.x) / 2.0
	var delta_h_world: float = (new_mesh_h - window_start_mesh_size.y) / 2.0
	if resize_hinge_mode != "":
		# Bord FIXE = bord opposé au bord tiré, au départ du drag. La fenêtre
		# pivote autour de lui (axe = celui du bord) vers le point visé, puis son
		# centre se déduit de ce bord fixe, de sa nouvelle taille et de son nouvel
		# angle. Le côté perpendiculaire (coin) se cale sur le delta plan, comme
		# en mode plan, mais dans la base de DÉPART : le bord fixe ne doit pas
		# dériver.
		var pivot: Vector3 = hinge["pivot"]
		var out_dir: Vector3 = hinge["out"]
		var yaw := resize_hinge_mode == "yaw"
		var up0 := resize_start_basis.y.normalized()
		var x0 := resize_start_basis.x.normalized()
		var far_pt := resize_start_pos - pivot * ((window_start_mesh_size.x if yaw
				else window_start_mesh_size.y) * 0.5)
		var new_extent: float = new_mesh_w if yaw else new_mesh_h
		# Orientation écrite dans l'ÉTAT STOCKÉ aussi : c'est lui que relisent
		# la rotation au scroll et la règle des 3 fenêtres.
		w3d.snap._store_basis(w3d.active_window_id, hinge["basis"])
		var perp_shift := Vector3.ZERO
		if yaw:
			if "top" in w3d.resizing_edge:
				perp_shift += up0 * delta_h_world
			elif "bottom" in w3d.resizing_edge:
				perp_shift -= up0 * delta_h_world
		else:
			if "left" in w3d.resizing_edge:
				perp_shift -= x0 * delta_w_world
			elif "right" in w3d.resizing_edge:
				perp_shift += x0 * delta_w_world
		quad.global_position = far_pt + out_dir * (new_extent * 0.5) + perp_shift
	else:
		var shift := Vector3.ZERO
		if "left" in w3d.resizing_edge:
			shift -= resize_right_dir * delta_w_world
		elif "right" in w3d.resizing_edge:
			shift += resize_right_dir * delta_w_world
		if "top" in w3d.resizing_edge:
			shift += resize_up_dir * delta_h_world
		elif "bottom" in w3d.resizing_edge:
			shift -= resize_up_dir * delta_h_world
		quad.position = window_start_local_pos + shift
	_update_group_resize(w3d.active_window_id)
	_update_shared_edge(new_mesh_w - window_start_mesh_size.x,
		new_mesh_h - window_start_mesh_size.y)


# Un grab de groupe vaut-il quelque chose depuis cette fenêtre ? Elle a au
# moins une voisine collée ET encore là : le groupe inclut la fenêtre saisie
# elle-même (_start_group_grab), donc sans voisine ce serait un grab ordinaire.
#
# Une voisine disparue ne compte pas — et le cas est réel : un unmapped
# n'efface que SA propre entrée (voir _erase_window_state), la voisine garde la
# sienne et pointerait sur une fenêtre qui n'existe plus.
func can_group_grab(wid: int) -> bool:
	if not w3d.quads.has(wid):
		return false
	for link in _snap_neighbours(wid):
		if w3d.quads.has(int(link["wid"])):
			return true
	return false

# Bascule le grab de groupe sur `wid` : le menu radial est le seul point
# d'entrée à même de l'INTERROMPRE. L'action Maj+G, elle, ne fait que le
# démarrer, le moteur du grab le terminant au relâchement physique de la touche
# (cf. _update_move). Un grab amorcé depuis l'anneau n'a aucun appui derrière
# lui : sans cette seconde validation, la fenêtre resterait accrochée au viseur
# pour toujours — « pas de relâchement d'action » ne veut pas dire « pas de fin ».
func toggle_group_grab(wid: int) -> void:
	if is_group_grabbed(wid):
		release_window_grab(wid)
		return
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null or not is_instance_valid(quad):
		return
	_start_group_grab(wid, quad)

# Le groupe est-il en train d'être saisi, sur CETTE fenêtre ? _group_grab vaut
# pour tout grab de groupe, y compris celui d'une autre fenêtre : c'est
# l'identifiant de la fenêtre saisie qui fait foi, sinon l'anneau proposerait
# « DROP GROUP » devant une fenêtre qui n'a rien à voir avec la saisie en cours.
func is_group_grabbed(wid: int) -> bool:
	return w3d._group_grab and is_window_grabbed(wid)

func _start_group_grab(wid: int, quad: MeshInstance3D) -> void:
	w3d.active_window_id = wid
	w3d.is_moving = true
	w3d.move_depth = w3d._camera().global_position.distance_to(quad.global_position)
	_group_rel.clear()
	var inv := quad.global_transform.affine_inverse()
	for m in _collect_group(wid, {}):
		var q: MeshInstance3D = w3d.quads.get(m, null)
		if q == null or not is_instance_valid(q):
			continue
		w3d._set_window_occluder_active(m, false)
		if m != wid:
			_group_rel[m] = inv * q.global_transform
	# Groupe de 1 => grab normal (billboard + snap)
	w3d._group_grab = not _group_rel.is_empty()
	w3d._grab_action = "grab_group"
	w3d.windows_state_changed.emit()

func _update_group_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	var quad: MeshInstance3D = w3d.quads.get(w3d.active_window_id, null)
	if quad == null or not is_instance_valid(quad):
		return
	var target := ray_origin + ray_dir * w3d.move_depth
	quad.global_position = quad.global_position.lerp(target, 10.0 * delta)
	# La fenêtre visée fait face au joueur (état stocké inclus, comme _update_move)
	w3d.snap._store_basis(w3d.active_window_id, w3d._camera().global_transform.basis)
	var t := quad.global_transform
	for m in _group_rel:
		var q: MeshInstance3D = w3d.quads.get(m, null)
		if q != null and is_instance_valid(q):
			var mt: Transform3D = t * (_group_rel[m] as Transform3D)
			q.global_transform = mt
			w3d._window_basis[m] = mt.basis

func _end_group_grab() -> void:
	for m in _group_rel:
		w3d._set_window_occluder_active(int(m), true)
	_group_rel.clear()
	w3d._group_grab = false
	w3d._grab_action = "grab"

func apply_motion_to_resize(motion: Transform3D) -> void:
	if not w3d.is_resizing or w3d.active_window_id == -1 or not w3d.quads.has(w3d.active_window_id):
		return
	var quad: MeshInstance3D = w3d.quads[w3d.active_window_id]
	if not is_instance_valid(quad):
		return
	var parent := quad.get_parent() as Node3D
	var parent_trans := parent.global_transform if parent else Transform3D.IDENTITY
	var pinv := parent_trans.affine_inverse()
	var local_motion := pinv * motion * parent_trans

	resize_start_world = local_motion * resize_start_world
	resize_right_dir = (local_motion.basis * resize_right_dir).normalized()
	resize_up_dir = (local_motion.basis * resize_up_dir).normalized()
	window_start_local_pos = local_motion * window_start_local_pos
	resize_start_basis = local_motion.basis * resize_start_basis
	resize_start_pos = local_motion * resize_start_pos

	for r in w3d._resize_shared:
		if r.has("far"):
			r["far"] = local_motion * Vector3(r["far"])
		if r.has("basis"):
			r["basis"] = local_motion.basis * (r["basis"] as Basis)
		if r.has("pos"):
			r["pos"] = local_motion * Vector3(r["pos"])
		if r.has("near_delta"):
			r["near_delta"] = motion.basis * Vector3(r["near_delta"])

	for link in _resize_links:
		if link.has("zone_start"):
			link["zone_start"] = local_motion * link["zone_start"]
		if link.has("members"):
			for m in link["members"]:
				if m.has("pos"):
					m["pos"] = local_motion * Vector3(m["pos"])
