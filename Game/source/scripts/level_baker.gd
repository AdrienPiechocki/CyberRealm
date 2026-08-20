extends RefCounted
## Sérialise le niveau courant en une scène binaire AUTO-SUFFISANTE (blob)
## destinée au multijoueur LAN : tous les meshes/matériaux/textures sont
## dupliqués et embarqués, les instances de scènes externes (.fbx/.glb des
## assets custom de `res://user/`) sont aplaties en nœuds locaux, et le
## sous-arbre Player est exclu (le client réutilise son joueur local via
## wayland_room.apply_host_level).
##
## Le blob peut donc être chargé sur une machine dont le build ne contient PAS
## les assets de la map : les maps custom deviennent jouables en LAN sans
## builds identiques.

const BAKE_TMP_PATH := "user://lan_bake.scn"

static func bake(root: Node3D) -> Dictionary:
	if root == null:
		return {}
	var player := root.get_node_or_null("Player") as Node3D
	var spawn := Vector3.ZERO
	if player != null:
		var stored = player.get("spawn_pos")
		spawn = stored if stored is Vector3 else player.position
	var cache := {}
	var clone := _clone(root, player, cache) as Node3D
	if clone == null:
		return {}
	clone.name = "Level"
	clone.owner = null
	_own_all(clone, clone)
	var scene := PackedScene.new()
	if scene.pack(clone) != OK:
		push_error("LevelBaker: pack du niveau échoué")
		return {}
	if ResourceSaver.save(scene, BAKE_TMP_PATH) != OK:
		push_error("LevelBaker: save du niveau échoué")
		return {}
	var f := FileAccess.open(BAKE_TMP_PATH, FileAccess.READ)
	if f == null:
		push_error("LevelBaker: impossible de lire le bake temporaire")
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		push_error("LevelBaker: blob vide après lecture")
		return {}
	push_warning("LevelBaker: bake OK — %d KB" % [bytes.size() / 1024])
	return {"bytes": bytes, "spawn": spawn}

static func _clone(orig: Node, exclude: Node, cache: Dictionary) -> Node:
	var node := ClassDB.instantiate(orig.get_class()) as Node
	if node == null:
		return null
	node.name = orig.name
	var script: Script = orig.get_script()
	if script != null:
		node.set_script(script)
	for g in orig.get_groups():
		node.add_to_group(g)
	for p in orig.get_property_list():
		var usage := int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname := String(p.get("name"))
		if pname == "script" or pname == "owner":
			continue
		var v = orig.get(pname)
		if v is Resource:
			node.set(pname, _embed(v, cache))
		elif v is Array:
			var arr: Array = v.duplicate()
			for i in arr.size():
				if arr[i] is Resource:
					arr[i] = _embed(arr[i], cache)
			node.set(pname, arr)
		else:
			node.set(pname, v)
	for c in orig.get_children():
		if c == exclude or c.owner == null:
			continue
		var sub := _clone(c, exclude, cache)
		if sub != null:
			node.add_child(sub)
	return node

static func _embed(r: Resource, cache: Dictionary) -> Resource:
	if r is Script:
		return r
	if cache.has(r):
		return cache[r]
	if r is Mesh:
		return _embed_mesh(r, cache)
	if r is Material:
		return _embed_material(r, cache)
	# Les textures importées (CompressedTexture2D) portent un resource_path
	# vers un fichier que le client n'a PAS → ImageTexture embarquée.
	if r is Texture2D:
		var converted = _convert_texture(r, cache)
		return converted
	var dup := r.duplicate(true)
	cache[r] = dup
	return dup

# Reconstruit un Mesh surface par surface : chaque matériau est deep-clone
# et ses textures converties, garantissant aucune référence externe résiduelle.
static func _embed_mesh(r: Mesh, cache: Dictionary) -> Mesh:
	if cache.has(r):
		return cache[r]
	var new_mesh := ArrayMesh.new()
	var count := r.get_surface_count()
	for i in count:
		var arrays := r.surface_get_arrays(i)
		var mat := r.surface_get_material(i)
		var prim := r.surface_get_primitive_type(i)
		if mat != null:
			mat = _embed(mat, cache)
		new_mesh.add_surface_from_arrays(prim, arrays)
		new_mesh.surface_set_material(new_mesh.get_surface_count() - 1, mat)
	for i in r.get_blend_shape_count():
		new_mesh.add_blend_shape(r.get_blend_shape_name(i))
	new_mesh.custom_aabb = r.custom_aabb
	cache[r] = new_mesh
	return new_mesh

# Deep-clone un matériau et convertit toutes ses propriétés texture.
static func _embed_material(r: Material, cache: Dictionary) -> Material:
	if cache.has(r):
		return cache[r]
	var dup := r.duplicate(true) as Material
	if dup == null:
		cache[r] = r
		return r
	# Parcourir TOUTES les propriétés pour remplacer les textures.
	for p in dup.get_property_list():
		var pname := String(p.get("name"))
		var v = dup.get(pname)
		if v is Texture2D:
			dup.set(pname, _convert_texture(v, cache))
		elif v is Array:
			var changed := false
			for i in v.size():
				if v[i] is Texture2D:
					v[i] = _convert_texture(v[i], cache)
					changed = true
			if changed:
				dup.set(pname, v)
	cache[r] = dup
	return dup

# Convertit une Texture2D en ImageTexture embarquée.
static func _convert_texture(tex: Texture2D, cache: Dictionary) -> Texture2D:
	if cache.has(tex):
		return cache[tex]
	var img: Image = null
	if tex is CompressedTexture2D:
		img = tex.get_image()
	elif tex is ImageTexture:
		img = tex.get_image()
	if img == null and not tex.resource_path.is_empty():
		img = Image.load_from_file(tex.resource_path)
	if img != null:
		var emb := ImageTexture.create_from_image(img)
		emb.resource_path = ""
		cache[tex] = emb
		return emb
	# Fallback : retourner la texture originale (risque d'erreur côté client).
	cache[tex] = tex
	return tex

static func _own_all(n: Node, root: Node) -> void:
	n.owner = root if n != root else null
	for c in n.get_children():
		_own_all(c, root)
