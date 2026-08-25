class_name LevelBaker
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
##
## Les scripts .gd situés sous res://user/ sont traités à part (voir
## prepare_user_scripts) : réécrits vers le miroir user://lan_mirror/… et
## transmis à part via un manifeste {chemin → source} que les pairs écrivent
## sur disque avant de charger le blob (UserScriptMirror).

const BAKE_TMP_PATH := "user://lan_bake.scn"

# Taille max des textures embarquées (0 = pas de limite). Positionné par
# l'appelant avant le bake (ex: avatar = 64, level = 0).
static var max_texture_size := 0
# Préserver les flags de format de surface (ARRAY_FORMAT_*) lors de la
# reconstruction des ArrayMesh. Nécessaire pour les FBX custom dont les
# meshs utilisent des attributs spécifiques (normales compressées, etc.).
# Désactivé pour les niveaux GLB où le timeout GPU est critique.
static var keep_surface_format := false

# Scripts utilisateur (res://user/**.gd) remappés pour le transfert LAN :
# script original → copie chargée depuis le miroir user://lan_mirror/….
# Rempli par prepare_user_scripts() AVANT le clonage ; consommé par _clone()
# et _embed() pendant le bake pour que le blob ne référence QUE le miroir
# (fichiers que UserScriptMirror.install() recrée chez les pairs).
static var _script_remap: Dictionary = {}
static var _ref_regex: RegEx = null

static func bake(root: Node3D) -> Dictionary:
	if root == null:
		return {}
	var player := root.get_node_or_null("Player") as Node3D
	var spawn := Vector3.ZERO
	var spawn_rotation := Vector3.ZERO
	var spawn_scale := Vector3.ONE
	if player != null:
		var stored = player.get("spawn_pos")
		spawn = stored if stored is Vector3 else player.position
		var r = player.get("spawn_rotation")
		spawn_rotation = r if r is Vector3 else player.rotation
		var s = player.get("spawn_scale")
		spawn_scale = s if s is Vector3 else player.scale
	# Scripts utilisateur : collecte + remappage vers le miroir AVANT le
	# clonage (_clone/_embed remplacent chaque script original par sa copie).
	var manifest := prepare_user_scripts(root)
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
	push_warning("LevelBaker: bake OK — %d KB (%d scripts user)" % [bytes.size() / 1024, manifest.size()])
	return {"bytes": bytes, "spawn": spawn, "spawn_rotation": spawn_rotation, "spawn_scale": spawn_scale, "scripts": manifest}

# ── Scripts utilisateur pour le LAN ──────────────────────────────────

## Collecte les scripts .gd sous res://user/ référencés par l'arbre — attachés
## aux nœuds ou cités entre eux via preload()/load()/extends (chemin littéral)
## — puis prépare le transfert :
## 1. réécrit leurs sources vers un lot miroir unique (res://user/… →
##    user://lan_mirror/<lot>/user/…),
## 2. écrit ces fichiers SUR CETTE MACHINE (les copies ci-dessous résolvent
##    leurs propres preload/extends depuis le disque au chargement),
## 3. charge chaque script depuis le miroir : la copie porte resource_path
##    miroir et remplace l'original dans le clonage (table _script_remap).
## Retourne le manifeste réseau {chemin_miroir → source réécrite} ; vide si
## aucun script utilisateur (rien à transmettre, comportement inchangé).
static func prepare_user_scripts(root: Node) -> Dictionary:
	_script_remap.clear()
	var found := {} # res://chemin -> Script attaché à un nœud de l'arbre
	_collect_scripts(root, found)
	# Sources complètes : objets attachés + dépendances transitives.
	var sources := {} # res://chemin -> source originale
	var scan_queue: Array = []
	for p in found:
		sources[p] = _script_source(found[p])
		scan_queue.append(p)
	while not scan_queue.is_empty():
		for r in _scan_refs(sources[scan_queue.pop_front()]):
			if sources.has(r):
				continue
			if not FileAccess.file_exists(r):
				push_warning("LevelBaker: script utilisateur référencé introuvable : %s" % r)
				continue
			sources[r] = FileAccess.get_file_as_string(r)
			scan_queue.append(r)
	for p in sources:
		if String(sources[p]).is_empty():
			push_warning("LevelBaker: source vide pour %s — build exporté avec des scripts compilés ? " % p
				+ "script_export_mode doit valoir 0 (Texte) pour le partage LAN.")
	if sources.is_empty():
		return {}
	var batch := UserScriptMirror.new_batch()
	var manifest := {}
	for p in sources:
		manifest[UserScriptMirror.mirror_path(p, batch)] = UserScriptMirror.rewritten_source(sources[p], batch)
	UserScriptMirror.install(manifest)
	# Copies chargées depuis le miroir (une définition par chemin, même si le
	# script est attaché à plusieurs nœuds) : resource_path = miroir → pack()
	# enregistre une ext_resource que les pairs résolvent après install().
	for p in found:
		var copy := load(UserScriptMirror.mirror_path(p, batch)) as Script
		if copy == null:
			push_warning("LevelBaker: copie miroir illisible pour %s — script non transmis" % p)
			continue
		_script_remap[found[p]] = copy
	return manifest

static func _collect_scripts(n: Node, out: Dictionary) -> void:
	var s := n.get_script() as Script
	if s != null and UserScriptMirror.is_user_script_path(s.resource_path):
		out[s.resource_path] = s
	for c in n.get_children():
		_collect_scripts(c, out)

static func _script_source(s: Script) -> String:
	if not s.source_code.is_empty():
		return s.source_code
	if not s.resource_path.is_empty():
		return FileAccess.get_file_as_string(s.resource_path)
	return ""

## Références res://user/**.gd présentes dans une source : preload()/load()
## avec littéral, et extends "chemin". Les chemins construits dynamiquement ne
## sont pas détectés (limite documentée côté utilisateur).
static func _scan_refs(source: String) -> Array:
	if source.is_empty():
		return []
	if _ref_regex == null:
		_ref_regex = RegEx.new()
		_ref_regex.compile("(?:preload|load|extends)[ \\t]*\\(?[ \\t]*[\"'](res://[^\"']+\\.gd)[\"']")
	var out: Array = []
	for m in _ref_regex.search_all(source):
		var p := m.get_string(1)
		if UserScriptMirror.is_user_script_path(p):
			out.append(p)
	return out

static func _clone(orig: Node, exclude: Node, cache: Dictionary) -> Node:
	var node := ClassDB.instantiate(orig.get_class()) as Node
	if node == null:
		return null
	node.name = orig.name
	var script: Script = orig.get_script()
	if script != null:
		# Script utilisateur remappé : attacher la copie miroir (sinon le pack
		# enregistre une dépendance res://user/… absente chez les pairs).
		node.set_script(_script_remap.get(script, script))
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
		elif v is Dictionary:
			# Ex. AnimationPlayer.libraries (StringName -> AnimationLibrary) :
			# sans ce cas, la ressource garde son resource_path d'origine et
			# PackedScene.pack() l'enregistre en dépendance EXTERNE (ex.
			# res://user/assets/avatar/walk.tres) que le pair ne possède pas
			# → load() du blob reçu échoue en cascade.
			var dict: Dictionary = v.duplicate()
			for k in dict:
				if dict[k] is Resource:
					dict[k] = _embed(dict[k], cache)
			node.set(pname, dict)
		else:
			node.set(pname, v)
	for c in orig.get_children():
		if c == exclude:
			continue
		var sub := _clone(c, exclude, cache)
		if sub != null:
			node.add_child(sub)
	return node

static func _embed(r: Resource, cache: Dictionary) -> Resource:
	if r is Script:
		# Scripts cités comme ressources (var exportée typée, etc.) : même
		# remappage que les scripts de nœuds.
		return _script_remap.get(r, r)
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
	if dup != null:
		dup.resource_path = ""
		# duplicate(true) ne duplique PAS les ressources cachées dans des
		# conteneurs internes non exposés en propriétés (ex. AnimationLibrary
		# : ses Animations importées d'un GLB « Save to File » portent encore
		# leur resource_path → dépendance externe au pack, fichier absent chez
		# le pair). Balayage récursif : tout ce qui traîne est embed à son tour.
		_embed_nested(dup, cache)
	return dup

# Embed récursivement les ressources référencées par une ressource dupliquée :
# propriétés directes, éléments de Array et valeurs de Dictionary. Les scripts
# sont exclus (identiques dans tous les builds).
static func _embed_nested(res: Resource, cache: Dictionary) -> void:
	for p in res.get_property_list():
		var pname := String(p.get("name"))
		if pname == "script":
			continue
		var v = res.get(pname)
		if v is Resource:
			res.set(pname, _embed(v, cache))
		elif v is Array:
			var changed := false
			for i in v.size():
				if v[i] is Resource:
					v[i] = _embed(v[i], cache)
					changed = true
			if changed:
				res.set(pname, v)
		elif v is Dictionary:
			var changed := false
			for k in v:
				if v[k] is Resource:
					v[k] = _embed(v[k], cache)
					changed = true
			if changed:
				res.set(pname, v)

# Reconstruit un Mesh surface par surface : chaque matériau est deep-clone
# et ses textures converties, garantissant aucune référence externe résiduelle.
static func _embed_mesh(r: Mesh, cache: Dictionary) -> Mesh:
	if cache.has(r):
		return cache[r]
	# Les meshs primitifs (CapsuleMesh, BoxMesh…) n'ont pas de
	# surface_get_arrays() : on duplique et on embed les matériaux manuellement.
	if r is PrimitiveMesh:
		var dup := r.duplicate(true) as PrimitiveMesh
		dup.resource_path = ""
		var mat = dup.surface_get_material(0)
		if mat != null:
			dup.surface_set_material(0, _embed(mat, cache))
		cache[r] = dup
		return dup
	if r is ArrayMesh == false:
		var dup := r.duplicate(true) as Mesh
		dup.resource_path = ""
		cache[r] = dup
		return dup
	# Quand keep_surface_format est actif (avatars FBX custom), dupliquer
	# le mesh tel quel pour préserver exactement les attributs GPU (tangentes
	# compressées, format d'index, etc.) — la reconstruction surface par
	# surface via add_surface_from_arrays peut produire un mesh subtilement
	# invalide qui crash au premier rendu.
	if keep_surface_format:
		var dup := r.duplicate(true) as ArrayMesh
		dup.resource_path = ""
		for i in dup.get_surface_count():
			var mat = dup.surface_get_material(i)
			if mat != null:
				dup.surface_set_material(i, _embed(mat, cache))
		cache[r] = dup
		return dup
	var new_mesh := ArrayMesh.new()
	var count := r.get_surface_count()
	for i in count:
		var arrays := r.surface_get_arrays(i)
		var mat := r.surface_get_material(i)
		var prim = r.surface_get_primitive_type(i)
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
	dup.resource_path = ""
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
		if max_texture_size > 0:
			var w := img.get_width()
			var h := img.get_height()
			if w > max_texture_size or h > max_texture_size:
				var ratio := minf(float(max_texture_size) / w, float(max_texture_size) / h)
				img.resize(int(w * ratio), int(h * ratio), Image.INTERPOLATE_BILINEAR)
		var emb := ImageTexture.create_from_image(img)
		emb.resource_path = ""
		cache[tex] = emb
		return emb
	# Fallback : retourner la texture originale (risque d'erreur côté client).
	push_warning("LevelBaker: texture fallback non convertie — %s (%s)" % [tex.resource_path, tex.get_class()])
	cache[tex] = tex
	return tex

static func _own_all(n: Node, root: Node) -> void:
	n.owner = root if n != root else null
	for c in n.get_children():
		_own_all(c, root)
