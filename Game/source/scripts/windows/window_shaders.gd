extends RefCounted
## Shaders personnalisés des fenêtres : transitions d'ouverture / fermeture et
## bordures.
##
## Trois fichiers optionnels, cherchés dans `user://` PUIS dans
## `res://ui/decorations/` (même principe que les SVG du décor) :
##   window_open.gdshader    transition d'ouverture
##   window_close.gdshader   transition de fermeture
##   window_border.gdshader  cadre (bordures + bande de titre)
## Absent = comportement historique (pas d'animation, matériau standard).
## Chaque fichier est un shader `spatial`. Les uniforms ci-dessous sont remplis
## automatiquement SI le shader les déclare (voir user/README.md).
##
## API statique, sans autoload (cf. window_decorations.gd).

const Decorations := preload("res://scripts/ui/window_decorations.gd")

const KINDS := {
	"open": "window_open.gdshader",
	"close": "window_close.gdshader",
	"border": "window_border.gdshader",
}

static var _cache: Dictionary = {} # path -> {"mtime": int, "shader": Shader}

## Chemin retenu pour un type ("open" | "close" | "border"), "" si aucun.
static func path_for(kind: String) -> String:
	var file: String = KINDS.get(kind, "")
	if file == "":
		return ""
	var user_path := "user://" + file
	if FileAccess.file_exists(user_path):
		return user_path
	var res_path := Decorations.RES_DIR + "/" + file
	if FileAccess.file_exists(res_path):
		return res_path
	return ""

## mtime de chaque shader retenu : fusionné dans la surveillance du décor, donc
## éditer un fichier recharge à chaud.
static func mtimes() -> Dictionary:
	var out: Dictionary = {}
	for kind: String in KINDS:
		var p := path_for(kind)
		if p != "":
			out[p] = FileAccess.get_modified_time(p)
	return out

## Shader compilé pour ce type, ou null (absent, illisible, ou pas `spatial`).
static func get_shader(kind: String) -> Shader:
	var path := path_for(kind)
	if path == "":
		return null
	var mtime := FileAccess.get_modified_time(path)
	var hit: Dictionary = _cache.get(path, {})
	if hit.get("mtime", -1) == mtime:
		return hit["shader"]
	var code := FileAccess.get_file_as_string(path)
	var shader: Shader = null
	if code.strip_edges() == "":
		push_warning("WindowShaders: %s est vide — ignoré" % path)
	else:
		shader = Shader.new()
		shader.code = code
		if shader.get_mode() != Shader.MODE_SPATIAL:
			push_warning("WindowShaders: %s doit être un shader_type spatial — ignoré" % path)
			shader = null
	_cache[path] = {"mtime": mtime, "shader": shader}
	return shader

## Nouveau ShaderMaterial du shader de ce type, ou null.
static func make_material(kind: String, priority: int = 0) -> ShaderMaterial:
	var shader := get_shader(kind)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = priority
	return mat

static func has_uniform(mat: ShaderMaterial, name: String) -> bool:
	if mat == null or mat.shader == null:
		return false
	for u: Dictionary in mat.shader.get_shader_uniform_list():
		if u["name"] == name:
			return true
	return false

## Pose un uniform seulement s'il est déclaré (évite le bruit pour les shaders
## qui n'utilisent qu'une partie du contrat).
static func set_param(mat: ShaderMaterial, name: String, value: Variant) -> void:
	if has_uniform(mat, name):
		mat.set_shader_parameter(name, value)

# ── Transitions ───────────────────────────────────────────────────────────
const TRANSITION_META := "_transition_orig" # sur chaque pièce : matériau d'origine
const ACTIVE_META := "_transition_active" # sur le quad : une transition est en cours

## Position (repère du quad de contenu) d'un nœud du décor : somme des offsets
## locaux jusqu'au quad. Les pièces ne sont jamais tournées.
static func offset_in_quad(node: Node3D, quad: Node3D) -> Vector2:
	var p := Vector2.ZERO
	var n: Node = node
	while n != null and n != quad:
		if n is Node3D:
			p += Vector2((n as Node3D).position.x, (n as Node3D).position.y)
		n = n.get_parent()
	return p

static func _parts(quad: Node) -> Array:
	var out: Array = []
	var stack: Array = [quad]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D and (n as MeshInstance3D).material_override != null:
			out.append(n)
	return out

## Remplace les matériaux du quad (contenu + décor) par le shader de transition.
## Renvoie les ShaderMaterial créés, ou [] si aucun shader (rien n'est changé).
static func begin_transition(quad: MeshInstance3D, kind: String) -> Array:
	if get_shader(kind) == null or quad.has_meta(ACTIVE_META):
		return []
	var mesh := quad.mesh as QuadMesh
	var half := mesh.size * 0.5 if mesh != null else Vector2.ONE
	var mats: Array = []
	var origs: Array = []
	for part: MeshInstance3D in _parts(quad):
		var orig: Material = part.material_override
		var mat := make_material(kind, orig.render_priority)
		var is_content := part == quad
		set_param(mat, "is_decoration", not is_content)
		set_param(mat, "part_offset", Vector2.ZERO if is_content else offset_in_quad(part, quad))
		set_param(mat, "window_half_size", half)
		set_param(mat, "progress", 0.0)
		# Contenu : on reprend la texture et le mode d'alpha du matériau d'origine.
		# Décor : la texture albédo du StandardMaterial / `border_texture`.
		if orig is ShaderMaterial:
			var sm := orig as ShaderMaterial
			for pname: String in ["window_texture", "content_size", "opaque_mode"]:
				set_param(mat, pname, sm.get_shader_parameter(pname))
			if sm.get_shader_parameter("window_texture") == null:
				set_param(mat, "window_texture", sm.get_shader_parameter("border_texture"))
		elif orig is StandardMaterial3D:
			set_param(mat, "window_texture", (orig as StandardMaterial3D).albedo_texture)
			set_param(mat, "opaque_mode", false)
		part.material_override = mat
		part.set_meta(TRANSITION_META, orig)
		mats.append(mat)
		origs.append(part)
	quad.set_meta(ACTIVE_META, true)
	# Le titre est un Label3D hors du contrat shader : caché le temps de l'effet.
	var label := quad.get_node_or_null("Titlebar/Label3D") as Label3D
	if label != null:
		label.set_meta(TRANSITION_META, label.visible)
		label.visible = false
	return mats

static func set_progress(mats: Array, progress: float, closing: bool) -> void:
	for mat: ShaderMaterial in mats:
		mat.set_shader_parameter("progress", progress)
		set_param(mat, "closing", closing)

## Rend les matériaux d'origine. Le contenu a pu recevoir une nouvelle texture
## pendant l'effet (sur le matériau de transition) : on la reporte.
static func end_transition(quad: MeshInstance3D) -> void:
	if not quad.has_meta(ACTIVE_META):
		return
	for part: MeshInstance3D in _parts(quad):
		if not part.has_meta(TRANSITION_META):
			continue
		var orig: Material = part.get_meta(TRANSITION_META)
		var cur := part.material_override as ShaderMaterial
		if part == quad and cur != null and orig is ShaderMaterial:
			for pname: String in ["window_texture", "content_size"]:
				var v: Variant = cur.get_shader_parameter(pname)
				if v != null:
					(orig as ShaderMaterial).set_shader_parameter(pname, v)
		part.material_override = orig
		part.remove_meta(TRANSITION_META)
	quad.remove_meta(ACTIVE_META)
	var label := quad.get_node_or_null("Titlebar/Label3D") as Label3D
	if label != null and label.has_meta(TRANSITION_META):
		label.visible = bool(label.get_meta(TRANSITION_META))
		label.remove_meta(TRANSITION_META)
