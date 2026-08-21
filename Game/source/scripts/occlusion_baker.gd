class_name OcclusionBaker
extends RefCounted
## Génère au runtime un occludeur basé sur la GÉOMÉTRIE RÉELLE du niveau :
## maps custom `res://user/level.tscn` ET maps reçues en LAN (blob baked),
## qui ne peuvent pas être pré-bakées dans l'éditeur côté client.
##
## Pour chaque MeshInstance3D opaque, les triangles du mesh sont copiés
## (winding préservé → mêmes règles de visibilité que le rendu) dans UN
## ArrayOccluder3D monde. Contrairement à des boîtes englobantes, aucun
## volume fantôme : une arche, une porte ou un meuble ajouré ne masque que
## là où il y a de la matière. C'est le même principe que « Bake Occlusion »
## de l'éditeur, appliqué au chargement.
##
## Sécurités :
## - un niveau contenant déjà un OccluderInstance3D (bake éditeur manuel,
##   qualité supérieure) n'est jamais modifié ;
## - le sous-arbre Player est exclu (sinon sa capsule resterait en occluder
##   figé au spawn après que le joueur est parti) ;
## - transparences (vitres, feuillages alpha-scissor…) et meshes skinnés
##   exclus : leurs quads pleins masqueraient à tort ;
## - budget global de triangles : le rasterizer logiciel de l'occlusion a un
##   coût CPU par frame proportionnel au nombre de triangles occludeurs.
##
## Nécessite le réglage projet rendering/occlusion_culling/use_occlusion_culling
## (activé dans project.godot). Ne s'applique qu'au rendu Forward+/Mobile.

# Préfiltre débris : AABB minuscule = jamais un bon occludeur.
const MIN_DIMENSION := 0.05
# Budget global (CPU du rasterizer logiciel borné). Les candidats sont
# ajoutés par taille décroissante : les gros murs d'abord, la petite
# déco jamais (coupée par le budget bien avant).
const MAX_TOTAL_TRIANGLES := 120000
const CONTAINER_NAME := "AutoOcclusion"
const DEBUG_ENV := "CYBERREALM_OCC_DEBUG"

# Analyse le niveau et crée l'occludeur. Renvoie le nombre de meshes
# contributeurs. Appeler APRÈS l'entrée dans l'arbre (transforms globaux).
static func bake(root: Node3D) -> int:
	if root == null or not root.is_inside_tree():
		return 0
	# Respect d'un bake éditeur (ou d'une génération précédente) : ne rien
	# générer.
	if root.find_children("*", "OccluderInstance3D", true, false).size() > 0:
		_debug("occluders existants détectés — génération auto sautée")
		return 0
	# Le joueur ne doit JAMAIS devenir un occludeur figé.
	var exclude := root.get_node_or_null("Player")
	var to_level := root.global_transform.affine_inverse()
	var candidates: Array[Dictionary] = []
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if not is_instance_valid(mi) or not mi.visible or mi.mesh == null:
			continue
		if not mi.is_visible_in_tree():
			continue
		# Mesh skinné (personnage animé) : bouge, occludeur figé absurde.
		if mi.skin != null:
			continue
		if exclude != null and exclude.is_ancestor_of(mi):
			continue
		# Préfiltre rapide sur l'AABB monde avant lecture des triangles.
		var world_aabb: AABB = mi.global_transform * mi.get_aabb()
		var size := world_aabb.size
		if size.x < MIN_DIMENSION or size.y < MIN_DIMENSION or size.z < MIN_DIMENSION:
			continue
		candidates.append({"mi": mi, "volume": size.x * size.y * size.z})
	# Les plus gros d'abord (meilleurs occludeurs), puis budget.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["volume"]) > float(b["volume"]))
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var used := 0
	var contributors := 0
	for c: Dictionary in candidates:
		if used >= MAX_TOTAL_TRIANGLES:
			break
		var added := _append_mesh(c["mi"] as MeshInstance3D, to_level,
			verts, indices, used, MAX_TOTAL_TRIANGLES)
		if added > 0:
			used += added
			contributors += 1
	if indices.is_empty():
		return 0
	var occ_res := ArrayOccluder3D.new()
	occ_res.vertices = verts
	occ_res.indices = indices
	var occ := OccluderInstance3D.new()
	occ.name = CONTAINER_NAME
	occ.occluder = occ_res
	root.add_child(occ)
	# Indépendant du repère de la racine (qui peut être rotée/décalée en LAN) :
	# les sommets sont déjà en coordonnées monde.
	occ.global_transform = Transform3D.IDENTITY
	_debug("%d triangles occludeurs issus de %d meshes" % [indices.size() / 3, contributors])
	return contributors

# Copie les triangles opaques d'un mesh dans les buffers communs (repère
# niveau). Renvoie le nombre de triangles ajoutés, borné au budget restant.
static func _append_mesh(mi: MeshInstance3D, to_level: Transform3D,
		verts: PackedVector3Array, indices: PackedInt32Array,
		used: int, budget: int) -> int:
	var xf := to_level * mi.global_transform
	var added := 0
	for s in mi.mesh.get_surface_count():
		if used + added >= budget:
			break
		# Surface transparente → pas occludeuse (vitre, feuillage…).
		var mat := mi.get_active_material(s)
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			if bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED \
					or bm.albedo_color.a < 0.99:
				continue
		var arrays := mi.mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if sv.is_empty():
			continue
		# Index implicite pour les surfaces non indexées.
		var si: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if si.is_empty():
			si.resize(sv.size())
			for i in sv.size():
				si[i] = i
		# Ne jamais couper en plein triangle : multiple de 3 sommets d'index.
		var room := ((budget - used - added) / 3) * 3
		if room < 3:
			break
		if si.size() > room:
			si = si.slice(0, room)
		var base := verts.size()
		verts.resize(base + sv.size())
		for i in sv.size():
			verts[base + i] = xf * sv[i]
		for idx in si:
			indices.append(base + idx)
		added += si.size() / 3
	return added

static func _debug(msg: String) -> void:
	if OS.get_environment(DEBUG_ENV) == "1":
		print("[occ] ", msg)
