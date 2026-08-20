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
	# Sweep récursif : remplacer TOUTES les Texture2D (y celles cachées
	# dans les ArrayMesh / sub_resources) par des ImageTexture embarquées.
	_embed_all_textures(clone, cache)
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

# Clone l'arbre en nœuds frais (ClassDB.instantiate) : un `duplicate()` de
# Godot conserve les données d'instance des scènes enfants, et
# `PackedScene.pack()` réécrit alors chaque instance .fbx DEUX fois (une fois
# comme instance externe, une fois comme nœuds locaux). Des nœuds frais n'ont
# aucune donnée d'instance → `pack()` les écrit une seule fois, aplatis.
# Les enfants runtime (`owner == null`, ex. conteneur Players/avatars du LAN)
# et le sous-arbre Player (exclude) sont écartés.
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

# Duplique une ressource en profondeur et la met en cache : sa resource_path
# est alors vide → `pack()` l'embarque comme sub_resource (aucune référence
# externe résiduelle). Les scripts restent des références res:// (le client
# a le même code de jeu — les maps LAN ne doivent pas attacher de scripts
# custom).
static func _embed(r: Resource, cache: Dictionary) -> Resource:
	if r is Script:
		return r
	if cache.has(r):
		return cache[r]
	var dup := r.duplicate(true)
	cache[r] = dup
	return dup

# Sweep récursif sur TOUTES les propriétés de TOUTES les ressources du
# clone : remplace chaque Texture2D (CompressedTexture2D inclus) par une
# ImageTexture contenant les pixels embarqués. Sans ça, les textures GLB
# conservent leur resource_path d'origine et le client échoue au load().
static func _embed_all_textures(node: Node, cache: Dictionary) -> void:
	for p in node.get_property_list():
		var usage := int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname := String(p.get("name"))
		var v = node.get(pname)
		if v is Texture2D:
			node.set(pname, _convert_texture(v, cache))
		elif v is Array:
			var changed := false
			var arr: Array = v
			for i in arr.size():
				if arr[i] is Texture2D:
					arr[i] = _convert_texture(arr[i], cache)
					changed = true
			if changed:
				node.set(pname, arr)
		elif v is Resource:
			_embed_resource_textures(v, cache)
	# Récursion sur les enfants.
	for c in node.get_children():
		_embed_all_textures(c, cache)

# Traverse les propriétés d'une ressource pour remplacer les textures.
static func _embed_resource_textures(r: Resource, cache: Dictionary) -> void:
	if r == null or r is Script:
		return
	for p in r.get_property_list():
		var usage := int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname := String(p.get("name"))
		var v = r.get(pname)
		if v is Texture2D:
			r.set(pname, _convert_texture(v, cache))
		elif v is Array:
			var changed := false
			var arr: Array = v
			for i in arr.size():
				if arr[i] is Texture2D:
					arr[i] = _convert_texture(arr[i], cache)
					changed = true
			if changed:
				r.set(pname, arr)
		elif v is Resource:
			_embed_resource_textures(v, cache)

# Convertit une Texture2D (CompressedTexture2D, etc.) en ImageTexture
# embarquée. Le resource_path vidé garantit que pack() l'écrit en
# sub_resource (pas de référence externe).
static func _convert_texture(tex: Texture2D, cache: Dictionary) -> ImageTexture:
	if cache.has(tex):
		var cached = cache[tex]
		if cached is ImageTexture:
			return cached
	var img: Image = null
	if tex is CompressedTexture2D:
		img = tex.get_image()
	elif tex is ImageTexture:
		img = tex.get_image()
	if img == null:
		# Fallback : essaye de charger depuis le resource_path.
		if not tex.resource_path.is_empty():
			img = Image.load_from_file(tex.resource_path)
	if img == null:
		# Dernier recours : retourne la texture telle quelle.
		return tex as ImageTexture
	var emb := ImageTexture.create_from_image(img)
	# Forcer resource_path vide pour que pack() l'embarque.
	emb.resource_path = ""
	cache[tex] = emb
	return emb

# Tous les nœuds clonés viennent de la scène (les nœuds runtime ont été
# écartés par le filtre `owner == null`) → tous possédés par la racine.
static func _own_all(n: Node, root: Node) -> void:
	n.owner = root if n != root else null
	for c in n.get_children():
		_own_all(c, root)
