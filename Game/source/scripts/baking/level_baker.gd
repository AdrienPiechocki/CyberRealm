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

const ASSET_EXTS := ["json", "txt", "csv", "tres", "gdshader", "gdshaderinc", "bin", "dat", "raw",
	"glb", "gltf", "png", "jpg", "jpeg", "webp"]
const REWRITE_EXTS := ["tres", "gdshader", "gdshaderinc"]  # texte contenant des res://user/
const MAX_ASSET_BYTES := 256 * 1024 * 1024
const PACK_MAGIC := "CRPK"

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

static var _asset_files: Dictionary = {}  # res://… -> true
static var _batch := ""
static var _asset_ref_re: RegEx = null

static func bake(root: Node3D) -> Dictionary:
	if root == null:
		return {}
	var player := root.find_child("Player", true, false) as Node3D
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
	_relink(root, player, cache)
	_scrub_node(clone, "Level", cache, {})
	var scene := PackedScene.new()
	if scene.pack(clone) != OK:
		push_error("LevelBaker: packing the level failed")
		clone.free()
		return {}
	if ResourceSaver.save(scene, BAKE_TMP_PATH) != OK:
		push_error("LevelBaker: saving the level failed")
		clone.free()
		return {}
	clone.free()
	for dep in ResourceLoader.get_dependencies(BAKE_TMP_PATH):
		if not String(dep).contains("lan_mirror"):
			push_warning("LevelBaker: EXTERNAL DEP — " + String(dep))
	var f := FileAccess.open(BAKE_TMP_PATH, FileAccess.READ)
	if f == null:
		push_error("LevelBaker: failed to read the temporary bake")
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		push_error("LevelBaker: empty blob after reading")
		return {}
	var assets := _collect_assets()
	push_warning("LevelBaker: bake OK — %d KB (%d user scripts)" % [bytes.size() / 1024, manifest.size()])
	return {"bytes": bytes, "spawn": spawn, "spawn_rotation": spawn_rotation, "spawn_scale": spawn_scale, "scripts": manifest, "assets": assets}


static func _put_u32(a: PackedByteArray, v: int) -> void:
	var o := a.size()
	a.resize(o + 4)
	a.encode_u32(o, v)

static func pack_payload(assets: Dictionary, scn: PackedByteArray) -> PackedByteArray:
	if assets.is_empty():
		return scn  # format historique, aucune copie
	var out := PACK_MAGIC.to_ascii_buffer()
	_put_u32(out, assets.size())
	for p in assets:
		var pb := String(p).to_utf8_buffer()
		var d: PackedByteArray = assets[p]
		_put_u32(out, pb.size())
		out.append_array(pb)
		_put_u32(out, d.size())
		out.append_array(d)
	out.append_array(scn)
	return out

static func is_packed(payload: PackedByteArray) -> bool:
	return payload.size() > 8 and payload.slice(0, 4).get_string_from_ascii() == PACK_MAGIC

static func unpack_payload(payload: PackedByteArray) -> Dictionary:
	var pos := 4
	var n := payload.decode_u32(pos)
	pos += 4
	var assets := {}
	var total := 0
	if n > 4096:
		return {"ok": false}
	for i in n:
		if pos + 4 > payload.size():
			return {"ok": false}
		var pl := payload.decode_u32(pos)
		pos += 4
		if pl == 0 or pl > 1024 or pos + pl + 4 > payload.size():
			return {"ok": false}
		var path := payload.slice(pos, pos + pl).get_string_from_utf8()
		pos += pl
		var dl := payload.decode_u32(pos)
		pos += 4
		total += dl
		if total > MAX_ASSET_BYTES or pos + dl > payload.size() \
				or not path.begins_with(UserScriptMirror.MIRROR_ROOT + "/") or ".." in path:
			return {"ok": false}
		assets[path] = payload.slice(pos, pos + dl)
		pos += dl
	return {"ok": true, "assets": assets, "offset": pos}

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
	_asset_files.clear()
	_batch = UserScriptMirror.new_batch()
	var classes := UserScriptMirror.scan_classes()
	var found := {} # res://chemin -> Script attaché à un nœud de l'arbre
	_collect_scripts(root, found)
	var sources := {} # res://chemin -> source originale
	var scan_queue: Array = []
	for p in found:
		sources[p] = _script_source(found[p])
		scan_queue.append(p)
	while not scan_queue.is_empty():
		for r in _scan_refs(sources[scan_queue.pop_front()], classes):
			if sources.has(r):
				continue
			if not FileAccess.file_exists(r):
				push_warning("LevelBaker: referenced user script not found: %s" % r)
				continue
			sources[r] = FileAccess.get_file_as_string(r)
			scan_queue.append(r)
	for p in sources:
		if String(sources[p]).is_empty():
			push_warning("LevelBaker: empty source for %s — exported build with compiled scripts? " % p
				+ "script_export_mode must be 0 (Text) for LAN sharing.")
	for p in sources:
		for a in _scan_asset_refs(sources[p]):
			_register_asset(a)
	if sources.is_empty():
		return {}
	var batch := _batch
	var manifest := {}
	for p in sources:
		manifest[UserScriptMirror.mirror_path(p, batch)] = \
			UserScriptMirror.rewritten_source(sources[p], batch, p, classes)
	UserScriptMirror.install(manifest)
	for p in found:
		var copy := load(UserScriptMirror.mirror_path(p, batch)) as Script
		if copy == null:
			push_warning("LevelBaker: unreadable mirror copy for %s — script not transmitted" % p)
			continue
		_script_remap[found[p]] = copy
	return manifest

static func _scan_asset_refs(text: String) -> Array:
	if _asset_ref_re == null:
		_asset_ref_re = RegEx.create_from_string("[\"'](res://user/[^\"'\\n]*)[\"']")
	var out: Array = []
	for m in _asset_ref_re.search_all(text):
		out.append(m.get_string(1))
	return out

## true si `path` (fichier ou dossier « …/ ») sera transmis → à remapper.
static func _register_asset(path: String) -> bool:
	if not path.begins_with(UserScriptMirror.RES_PREFIX):
		return false
	if path.ends_with("/") or (path.get_extension().is_empty() and DirAccess.open(path) != null):
		_add_asset_dir(path.trim_suffix("/") + "/")
		return true
	if path.get_extension().to_lower() not in ASSET_EXTS or not FileAccess.file_exists(path):
		return false
	_asset_files[path] = true
	return true

static func _add_asset_dir(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not f.begins_with("."):
			var p := dir.path_join(f)
			if d.current_is_dir():
				_add_asset_dir(p + "/")
			else:
				_register_asset(p)
		f = d.get_next()
	d.list_dir_end()

## {chemin_miroir -> octets} : fermeture transitive via les fichiers texte.
static func _collect_assets() -> Dictionary:
	var out := {}
	var seen := {}
	var total := 0
	while true:
		var todo: Array = []
		for p in _asset_files:
			if not seen.has(p):
				todo.append(p)
		if todo.is_empty():
			break
		for p: String in todo:
			seen[p] = true
			var data := FileAccess.get_file_as_bytes(p)
			if data.is_empty():
				push_warning("LevelBaker: asset unreadable/empty — %s (export filter?)" % p)
				continue
			total += data.size()
			if total > MAX_ASSET_BYTES:
				push_warning("LevelBaker: assets cap reached (%d MB) — %s skipped" % [MAX_ASSET_BYTES >> 20, p])
				return out
			var ext := p.get_extension().to_lower()
			if ext in REWRITE_EXTS:
				var text := data.get_string_from_utf8()
				for r in _scan_asset_refs(text):
					_register_asset(r)
				data = UserScriptMirror.rewrite_paths(text, _batch, ext).to_utf8_buffer()
			out[UserScriptMirror.mirror_path(p, _batch)] = data
	push_warning("LevelBaker: %d asset files, %d KB" % [out.size(), total / 1024])
	return out

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
static func _scan_refs(source: String, classes := {}) -> Array:
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
	for n in classes:
		if UserScriptMirror.uses_class(source, n):
			out.append(classes[n])
	return out

static func _clone(orig: Node, exclude: Node, cache: Dictionary) -> Node:
	var node := ClassDB.instantiate(orig.get_class()) as Node
	if node == null:
		return null
	node.name = orig.name
	for m in orig.get_meta_list():
		node.set_meta(m, orig.get_meta(m))
	cache[orig] = node   # table orig -> clone
	var skip_runtime: bool = orig.get_meta("lan_skip_children", false)
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
		if v is Node:
			continue
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
		elif v is String or v is StringName:
			var s := String(v)
			if s.begins_with(UserScriptMirror.RES_PREFIX) and _register_asset(s):
				node.set(pname, UserScriptMirror.mirror_path(s, _batch))
			else:
				node.set(pname, v)
		else:
			node.set(pname, v)
	for c in orig.get_children():
		if skip_runtime and c.owner == null:
			continue
		if c == exclude:
			# Placeholder au même endroit : même classe + même script (exports
			# typés valides), jamais ses enfants. Remplacé par le Player local.
			var ph := ClassDB.instantiate(c.get_class()) as Node
			ph.name = c.name
			var ps: Script = c.get_script()
			if ps != null:
				ph.set_script(_script_remap.get(ps, ps))
			if c is Node3D:
				(ph as Node3D).transform = (c as Node3D).transform
			node.add_child(ph)
			cache[c] = ph
			continue
		var sub := _clone(c, exclude, cache)
		if sub != null:
			node.add_child(sub)
	return node

static func _relink(orig: Node, exclude: Node, cache: Dictionary) -> void:
	if orig == exclude or not cache.has(orig):
		return
	var clone: Node = cache[orig]
	if orig.get_script() != null:
		for p in orig.get_property_list():
			if int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE == 0:
				continue
			var pname := String(p.get("name"))
			if pname == "script" or pname == "owner":
				continue
			var v = orig.get(pname)
			if v is Node:
				clone.set(pname, cache.get(v, null))   # null si exclu (Player)
			elif v is Array:
				var arr: Array = v.duplicate()
				var has_node := false
				for i in arr.size():
					if arr[i] is Node:
						arr[i] = cache.get(arr[i], null)
						has_node = true
				if has_node:
					clone.set(pname, arr)
	for c in orig.get_children():
		_relink(c, exclude, cache)

static var _inc_re: RegEx = null

static func _inline_includes(code: String, depth := 0) -> String:
	if _inc_re == null:
		_inc_re = RegEx.create_from_string("(?m)^[ \\t]*#include[ \\t]+\"(res://user/[^\"]+)\"[ \\t]*$")
	if depth > 8:
		return code
	var out := ""
	var last := 0
	for m in _inc_re.search_all(code):
		out += code.substr(last, m.get_start() - last)
		out += _inline_includes(FileAccess.get_file_as_string(m.get_string(1)), depth + 1)
		last = m.get_end()
	return out + code.substr(last)

static func _embed(r: Resource, cache: Dictionary) -> Resource:
	if r is Script:
		# Scripts cités comme ressources (var exportée typée, etc.) : même
		# remappage que les scripts de nœuds.
		return _script_remap.get(r, r)
	if r is Shader and not r is VisualShader:
		if cache.has(r):
			return cache[r]
		var s := Shader.new()
		s.code = _inline_includes((r as Shader).code)
		cache[r] = s
		return s
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
	# Créée par compute au runtime : le script la recrée chez le pair.
	if tex.get_class() == "Texture2DRD":
		cache[tex] = null
		return null
	var img: Image = null
	# NoiseTexture2D : on la garde procédurale (quelques Ko, régénérée au load).
	if not tex is NoiseTexture2D:
		img = tex.get_image()
		if img == null and tex.resource_path.get_extension() in ["png", "jpg", "jpeg", "webp", "exr", "hdr", "tga", "bmp"]:
			img = Image.load_from_file(tex.resource_path)
	if img != null and not img.is_empty():
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
	# Fallback embarqué : duplicata sans chemin + ressources imbriquées (noise…).
	var dup := tex.duplicate(true) as Texture2D
	if dup == null:
		cache[tex] = null
		return null
	dup.resource_path = ""
	cache[tex] = dup
	_embed_nested(dup, cache)
	return dup

static func _own_all(n: Node, root: Node) -> void:
	n.owner = root if n != root else null
	for c in n.get_children():
		_own_all(c, root)

static func _is_ext(r: Resource) -> bool:
	return not r.resource_path.is_empty() and not "::" in r.resource_path

static func _scrub_node(n: Node, path: String, cache: Dictionary, seen: Dictionary) -> void:
	_scrub_obj(n, path, cache, seen)
	for c in n.get_children():
		_scrub_node(c, path + "/" + String(c.name), cache, seen)

static func _scrub_obj(o: Object, trail: String, cache: Dictionary, seen: Dictionary) -> void:
	for p in o.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname := String(p.get("name"))
		if pname == "script" or pname == "owner":
			continue
		var v = o.get(pname)
		if not (v is Resource or v is Array or v is Dictionary):
			continue
		var nv = _fix_value(v, trail + "." + pname, cache, seen)
		if not is_same(nv, v):
			o.set(pname, nv)

static func _fix_value(v: Variant, trail: String, cache: Dictionary, seen: Dictionary) -> Variant:
	if v is Resource:
		var r := v as Resource
		if r is Script:
			return r
		if _is_ext(r):
			push_warning("LevelBaker: EXTERNAL REF %s (%s) @ %s" % [r.resource_path, r.get_class(), trail])
			return _embed(r, cache)
		if not (r is Mesh or r is Texture or r is Image) and not seen.has(r):
			seen[r] = true
			_scrub_obj(r, trail, cache, seen)
		return r
	if v is Array:
		var arr: Array = v.duplicate()
		var changed := false
		for i in arr.size():
			if arr[i] is Resource:
				var nv = _fix_value(arr[i], trail + "[%d]" % i, cache, seen)
				if not is_same(nv, arr[i]):
					arr[i] = nv
					changed = true
		return arr if changed else v
	if v is Dictionary:
		var dict: Dictionary = v.duplicate()
		var changed := false
		for k in dict:
			if dict[k] is Resource:
				var nv = _fix_value(dict[k], trail + "[%s]" % str(k), cache, seen)
				if not is_same(nv, dict[k]):
					dict[k] = nv
					changed = true
		return dict if changed else v
	return v
