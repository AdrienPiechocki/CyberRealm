extends Node
## Ordre de dessin des fenêtres : tri par plans, de la plus lointaine à la plus proche.
##
## Module de Windows3D (nœud enfant « Sorting »), créé par la façade : l'état partagé vit dans la façade
## (`w3d`), l'état propre au module vit ici.

const Windows3D := preload("res://scripts/windows/windows_3d.gd")
var w3d: Windows3D = null

# Ordre de dessin des fenêtres. Godot trie les transparents par la distance du
# CENTRE de chaque objet à la caméra : pour deux fenêtres qui se chevauchent
# (surtout décalées ou de tailles différentes), la plus éloignée peut avoir le
# centre le plus proche, et passe alors PAR-DESSUS l'autre. On remplace donc la
# clé de tri de chaque pièce d'une fenêtre par la distance de la caméra au PLAN
# de la fenêtre (sorting_offset = distance du centre − distance au plan ; la clé
# effective est distance − offset). Toutes les pièces d'une fenêtre partagent
# ainsi la même clé ; leur ordre interne reste fixé par render_priority.
func _update_window_sorting() -> void:
	var cam := w3d._camera()
	if cam == null:
		return
	# Position INTERPOLÉE : avec physics_interpolation, global_position d'une
	# caméra portée par le joueur est celle du dernier tick physique, pas celle
	# du rendu. L'écart (jusqu'à un tick de déplacement, soit des centimètres en
	# marchant) faussait sorting_offset — recalculé par rapport à la distance
	# que le moteur mesurera avec la position rendue — et inversait l'ordre de
	# deux fenêtres proches dès qu'on s'éloignait.
	var cp := cam.get_global_transform_interpolated().origin
	# render_priority prime sur le tri par distance : sans base par fenêtre, le
	# décor (priorité 1-2) d'une fenêtre ARRIÈRE se dessinait par-dessus le
	# contenu (priorité 0) d'une fenêtre DEVANT. Chaque fenêtre reçoit donc une
	# plage de priorités propre, croissante du fond vers l'avant.
	var order: Array = []
	for id: int in w3d.quads.keys():
		var quad: MeshInstance3D = w3d.quads[id]
		if not is_instance_valid(quad) or not quad.visible:
			continue
		var n := quad.global_basis.z.normalized()
		order.append([absf((cp - quad.global_position).dot(n)), quad, id])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	order = _order_far_to_near(order, cp)
	# Les fenêtres OPAQUES écrivent la profondeur : dessinées en premier, le test
	# de profondeur règle seul leur occlusion avec n'importe quelle fenêtre, même
	# interpénétrée ou inclinée, quel que soit le côté d'où l'on regarde. Les
	# translucides (sans écriture de profondeur) passent ensuite, du fond vers
	# l'avant : elles se testent contre les opaques, et le tri ne sert plus
	# qu'entre translucides. Partition stable.
	var opaque_first: Array = []
	var translucent: Array = []
	for e: Array in order:
		if w3d._alpha_translucent.get(e[2], false):
			translucent.append(e)
		else:
			opaque_first.append(e)
	order = opaque_first + translucent
	for i in order.size():
		var base := mini(i * WINDOW_PRIORITY_SPAN, WINDOW_PRIORITY_MAX)
		_apply_sort_key(order[i][1], cp, order[i][0], base)

# Ordre de dessin FOND → AVANT de fenêtres éventuellement inclinées. La distance
# au plan ne suffit pas : pour deux plans non parallèles elle dépend de la
# position du joueur et inverse l'ordre alors que l'une est réellement devant
# l'autre. On compare donc les fenêtres deux à deux : A est devant B si les
# quatre coins de B sont de l'autre côté du plan de A que la caméra (ou
# l'inverse). Les paires qui s'interpénètrent ou sont coplanaires n'imposent
# rien : elles gardent l'ordre par distance au plan (`order`, déjà trié).
# Tri topologique stable ; en cas de cycle, on retombe sur l'ordre initial.
func _order_far_to_near(order: Array, cp: Vector3) -> Array:
	var n := order.size()
	if n < 2:
		return order
	var corners: Array = []
	var normals: Array = []
	var sides: Array = []
	for e: Array in order:
		var q: MeshInstance3D = e[1]
		var half := Vector2(1.0, 1.0)
		if q.mesh is QuadMesh:
			half = (q.mesh as QuadMesh).size * 0.5
		var t := q.global_transform
		corners.append([t * Vector3(-half.x, -half.y, 0.0), t * Vector3(half.x, -half.y, 0.0),
			t * Vector3(half.x, half.y, 0.0), t * Vector3(-half.x, half.y, 0.0)])
		var nn := t.basis.z.normalized()
		normals.append(nn)
		sides.append(1.0 if (cp - t.origin).dot(nn) >= 0.0 else -1.0)
	# before[i] : indices à dessiner AVANT i (plus loin que i).
	var before: Array = []
	var indeg: Array = []
	for i in n:
		before.append([])
		indeg.append(0)
	for i in range(n):
		for j in range(i + 1, n):
			var r := _in_front(order, corners, normals, sides, i, j)
			if r == 0:
				continue
			# r > 0 : i devant j → j d'abord.
			var far_i := j if r > 0 else i
			var near_i := i if r > 0 else j
			(before[near_i] as Array).append(far_i)
	for i in n:
		indeg[i] = (before[i] as Array).size()
	var done: Array = []
	done.resize(n)
	done.fill(false)
	var out: Array = []
	while out.size() < n:
		var pick := -1
		for i in n:
			if not done[i] and indeg[i] == 0:
				pick = i
				break
		if pick == -1:
			for i in n:
				if not done[i]:
					pick = i
					break
		done[pick] = true
		out.append(order[pick])
		for i in n:
			if not done[i] and (before[i] as Array).has(pick):
				indeg[i] -= 1
	return out

## +1 : fenêtre i devant j ; -1 : j devant i ; 0 : indécidable.
func _in_front(_order: Array, corners: Array, normals: Array, sides: Array,
		i: int, j: int) -> int:
	var a := _side_test(corners, normals, sides, i, j) # j derrière le plan de i ?
	var b := _side_test(corners, normals, sides, j, i)
	var r := 0
	if a != 0:
		r += a
	if b != 0:
		r -= b
	return clampi(r, -1, 1) if (a == 0 or b == 0 or a != b) else 0

## +1 : `j` est entièrement derrière le plan de `i` (côté opposé à la caméra) ;
## -1 : entièrement devant ; 0 : les deux côtés (interpénétration) ou coplanaire.
## Les coins posés SUR le plan comptent pour neutres : deux fenêtres collées
## par un bord (le cas courant) en partagent, et exiger quatre coins stricts
## rendait la paire indécidable — l'ordre retombait alors sur la distance au
## plan, qui s'inverse selon la position du joueur.
func _side_test(corners: Array, normals: Array, sides: Array, i: int, j: int) -> int:
	var o: Vector3 = (corners[i] as Array)[0]
	var nn: Vector3 = normals[i]
	var sd: float = sides[i]
	var behind := 0
	var front := 0
	for c: Vector3 in (corners[j] as Array):
		var d := (c - o).dot(nn) * sd
		if d < -SORT_PLANE_EPS:
			behind += 1
		elif d > SORT_PLANE_EPS:
			front += 1
	if behind > 0 and front == 0:
		return 1
	if front > 0 and behind == 0:
		return -1
	return 0

const SORT_PLANE_EPS := 0.02 # m

const WINDOW_PRIORITY_SPAN := 4 # décor 0..2 + popups (1) + marge
const WINDOW_PRIORITY_MAX := 100 # reste sous les overlays (flash/x-ray : 127)

func _apply_sort_key(node: Node, cp: Vector3, plane_d: float, base: int) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.sorting_offset = cp.distance_to(mi.global_position) - plane_d
		var mat := mi.material_override
		# Matériau d'effet de transition : priorité propre, on n'y touche pas.
		if mat != null and not mi.has_meta(Windows3D.WindowShaders.TRANSITION_META):
			if not mat.has_meta(&"_prio0"):
				mat.set_meta(&"_prio0", mat.render_priority)
			var want: int = int(mat.get_meta(&"_prio0")) + base
			if mat.render_priority != want:
				mat.render_priority = want
	elif node is Label3D:
		var lb := node as Label3D
		if not lb.has_meta(&"_prio0"):
			lb.set_meta(&"_prio0", Vector2i(lb.render_priority, lb.outline_render_priority))
		var p0: Vector2i = lb.get_meta(&"_prio0")
		lb.render_priority = p0.x + base
		lb.outline_render_priority = p0.y + base
	for c in node.get_children():
		# Les popups (enfants du quad) héritent de la même clé : leur
		# render_priority (1) les garde devant le contenu.
		_apply_sort_key(c, cp, plane_d, base)
