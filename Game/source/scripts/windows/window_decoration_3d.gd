extends RefCounted
## Construction et recalage du décor 3D d'UNE fenêtre (cadre, barre, boutons).
##
## Tout est enfant du quad de CONTENU : le décor déborde donc du mesh sans
## qu'aucun code de position, de rotation ou de déplacement n'ait à le suivre.
##
## API statique : aucun état propre, tout passe par le quad.

const Decorations := preload("res://scripts/ui/window_decorations.gd")

# ORDRE DE DESSIN DU DÉCOR. Les quads du décor SE CHEVAUCHENT : les boutons
# sont posés SUR la bande de titre, qui fait toute la largeur de la fenêtre.
# Or tous sont en transparence ALPHA, et Godot trie les transparents du fond
# vers l'avant selon la distance du CENTRE de chaque objet à la caméra — le
# décalage Z de 1 mm n'entre pas dans ce tri. Bande et boutons se disputent
# donc l'ordre selon le côté où se trouve la caméra : le bouton disparaît quand
# on longe la fenêtre par l'autre bord. Le seul remède est de fixer l'ordre.
const PRIORITY_FRAME := 0
const PRIORITY_BAR := 1
const PRIORITY_OVERLAY := 2 # boutons et titre, posés sur la bande

# Pièces dont la bande médiane se RÉPÉTÈTE au lieu de s'étirer. Les quatre
# coins sont exclus : leur motif ne doit pas être coupé en plein milieu.
const TILED_PIECES := ["left", "right", "bottom", "top"]

const FRAME_DEPTH := 0.04
const BUTTON_DEPTH := 0.03
## Pièces du cadre dessinées. `piece` désigne la région du 9-patch, `edge` le
## côté tiré quand le joueur redimensionne par le cadre. Les coins hauts tirent
## « top » comme le fait déjà la barre de titre ; les coins bas tirent leur coin,
## comme la politique CORNER_MARGIN du contenu.
const FRAME_PIECES := [
	{"node": "FrameLeft", "piece": "left", "edge": "left"},
	{"node": "FrameRight", "piece": "right", "edge": "right"},
	{"node": "FrameBottom", "piece": "bottom", "edge": "bottom"},
	{"node": "CornerBL", "piece": "bottomleft", "edge": "bottomleft"},
	{"node": "CornerBR", "piece": "bottomright", "edge": "bottomright"},
	{"node": "CornerTL", "piece": "topleft", "edge": "top"},
	{"node": "CornerTR", "piece": "topright", "edge": "top"},
]
const BUTTON_ORDER := ["close", "maximize", "minimize"]

static func titlebar_metrics(s: float) -> Dictionary:
	return Decorations.world(Decorations.metrics(), s)

## Position et taille monde d'une pièce, dans le repère du quad. Les coins hauts
## font toute la hauteur de la barre : ce sont les coins du titre, pas de la
## simple bordure.
static func frame_piece_rect(piece: String, half: Vector2, t: float, b: float) -> Array:
	var hw := half.x
	var hh := half.y
	match piece:
		"left": return [Vector2(-hw - t * 0.5, 0.0), Vector2(t, hh * 2.0)]
		"right": return [Vector2(hw + t * 0.5, 0.0), Vector2(t, hh * 2.0)]
		"bottom": return [Vector2(0.0, -hh - t * 0.5), Vector2(hw * 2.0, t)]
		"bottomleft": return [Vector2(-hw - t * 0.5, -hh - t * 0.5), Vector2(t, t)]
		"bottomright": return [Vector2(hw + t * 0.5, -hh - t * 0.5), Vector2(t, t)]
		"topleft": return [Vector2(-hw - t * 0.5, hh + b * 0.5), Vector2(t, b)]
		"topright": return [Vector2(hw + t * 0.5, hh + b * 0.5), Vector2(t, b)]
	return [Vector2.ZERO, Vector2.ZERO]

## Position X du centre de chaque bouton, dans l'ordre `BUTTON_ORDER`. Le
## premier élément de la liste est toujours le plus à l'EXTÉRIEUR du lot : à
## droite on part du bord droit et on avance vers la gauche, à l'inverse à
## gauche. Un même pas, un seul sens.
static func button_positions(count: int, alignment: String, btn: float, gap: float,
		margin: float, half_width: float) -> Array:
	var out: Array = []
	var at_right := alignment != "left"
	var x := (half_width - margin - btn * 0.5) if at_right \
		else (-half_width + margin + btn * 0.5)
	var step := -(btn + gap) if at_right else (btn + gap)
	for i in count:
		out.append(x)
		x += step
	return out

## Construit décor + barre sur un quad déjà porteur de son mesh et de son
## `surface_size`. Idempotent : un second appel ne recrée rien.
static func build(quad: MeshInstance3D, wid: int, title: String) -> void:
	var titlebar := quad.get_node_or_null("Titlebar") as MeshInstance3D
	if titlebar == null:
		titlebar = _build_titlebar(quad, wid)
	var label := titlebar.get_node_or_null("Label3D") as Label3D
	if label != null:
		label.text = title
	var deco := quad.get_node_or_null("Decoration") as Node3D
	if deco == null:
		deco = Node3D.new()
		deco.name = "Decoration"
		quad.add_child(deco)
	for spec: Dictionary in FRAME_PIECES:
		_make_frame_piece(deco, spec, wid)
	sync(quad)

static func _unshaded(priority: int = PRIORITY_FRAME) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = priority
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.texture_repeat = false
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return mat

static func _build_titlebar(quad: MeshInstance3D, wid: int) -> MeshInstance3D:
	var titlebar := MeshInstance3D.new()
	titlebar.name = "Titlebar"
	# Invisible tant que le client n'a pas confirmé SERVER_SIDE : c'est
	# `on_window_decorations_changed` qui décide, comme avant, quand le
	# compositeur cède les décorations au jeu.
	titlebar.visible = false
	titlebar.mesh = QuadMesh.new() # dimensionné par sync()
	titlebar.material_override = _unshaded(PRIORITY_BAR)
	titlebar.set_meta("titlebar_of", wid)
	titlebar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bar_body := StaticBody3D.new()
	bar_body.name = "BarBody"
	bar_body.collision_layer = 2
	bar_body.collision_mask = 2
	var bar_col := CollisionShape3D.new()
	bar_col.shape = BoxShape3D.new()
	bar_body.add_child(bar_col)
	bar_body.set_meta("titlebar_of", wid)
	titlebar.add_child(bar_body)
	for action: String in BUTTON_ORDER:
		_make_button(titlebar, wid, action)
	var label := Label3D.new()
	label.name = "Label3D"
	label.double_sided = true
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.outline_size = 0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.position = Vector3(0.0, 0.0, 0.001)
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	label.render_priority = PRIORITY_OVERLAY
	titlebar.add_child(label)
	quad.add_child(titlebar)
	return titlebar

static func _make_button(titlebar: MeshInstance3D, wid: int, action: String) -> void:
	var btn := StaticBody3D.new()
	btn.name = "Btn" + action.capitalize()
	btn.collision_layer = 2
	btn.collision_mask = 2
	var col := CollisionShape3D.new()
	col.shape = BoxShape3D.new()
	btn.add_child(col)
	var visual := MeshInstance3D.new()
	visual.mesh = QuadMesh.new()
	visual.material_override = _unshaded(PRIORITY_OVERLAY)
	visual.position = Vector3(0.0, 0.0, 0.001)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	btn.add_child(visual)
	# Meta INCHANGÉE : `process_raycast` et `_handle_titlebar_button` s'appuient
	# dessus pour fermer/réduire/agrandir.
	btn.set_meta("titlebar_button", {"wid": wid, "action": action})
	btn.set_meta("button_state", 0)
	titlebar.add_child(btn)

static func _make_frame_piece(deco: Node3D, spec: Dictionary, wid: int) -> void:
	var node := deco.get_node_or_null(spec["node"]) as StaticBody3D
	if node != null:
		return
	node = StaticBody3D.new()
	node.name = spec["node"]
	node.collision_layer = 2
	node.collision_mask = 2
	var col := CollisionShape3D.new()
	col.shape = BoxShape3D.new()
	node.add_child(col)
	var visual := MeshInstance3D.new()
	visual.mesh = QuadMesh.new()
	visual.material_override = _unshaded(PRIORITY_FRAME)
	visual.position = Vector3(0.0, 0.0, 0.001)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(visual)
	node.set_meta("decoration_edge", spec["edge"])
	node.set_meta("window_of", wid)
	node.set_meta("border_piece", spec["piece"])
	deco.add_child(node)

## Recalage complet du décor sur la taille courante du contenu.
static func sync(quad: MeshInstance3D) -> void:
	var mesh := quad.mesh as QuadMesh
	if mesh == null:
		return
	var body := quad.get_child(0) as StaticBody3D
	var surface: Vector2 = Vector2.ZERO
	if body != null:
		surface = body.get_meta("surface_size", Vector2.ZERO)
	var s: float = Decorations.px_scale(surface, mesh.size)
	var d := Decorations.world(Decorations.metrics(), s)
	var half := mesh.size * 0.5
	var t: float = d["border"]
	var b: float = d["titlebar"]
	var deco := quad.get_node_or_null("Decoration") as Node3D
	if deco != null:
		for spec: Dictionary in FRAME_PIECES:
			var node := deco.get_node_or_null(spec["node"]) as StaticBody3D
			if node == null:
				continue
			var rect: Array = frame_piece_rect(spec["piece"], half, t, b)
			_place(node, rect[0], rect[1], Decorations.border_piece(spec["piece"]),
				spec["piece"], s)
	_sync_bar(quad, s, mesh, half)

## Les bords ne s'étirent pas : la bande médiane du SVG est RÉPÉTÉE à sa taille
## naturelle (1 px de texture = 1 px de contenu), faute de quoi une bande de
## 292 px étirée sur 1000 px déforme son motif d'un facteur 3.4.
## `AtlasTexture` ne sait pas répéter au-delà de sa région : un UV qui déborde
## reboucle sur tout l'atlas et afficherait les autres pièces. On assemble donc
## une grille de quads dans UN SEUL `ArrayMesh` — un seul draw call — chacun
## échantillonnant la bande entière, les UV 0..1 étant remappés sur la région par
## le matériau.
## Les quads sont répartis À L'ÉGALITÉ : le bord atteint toujours le coin, sans
## débordement ni trou visible, au prix d'une échelle variant de 1/N par motif.
## N grandit avec la fenêtre, donc l'écart à l'échelle naturelle décroît.
static func tiled_mesh(size: Vector2, band_px: Vector2, vertical: bool, s: float, uv_rect: Rect2) -> Mesh:
	var length := size.y if vertical else size.x
	var cross := size.x if vertical else size.y
	var n := 1
	var period := (band_px.y if vertical else band_px.x) * s
	if s > 0.0 and period > 0.0:
		n = maxi(1, roundi(length / period))
	var span := length / float(n)
	var c := cross * 0.5
	var start := -length * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var uu := [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]
	for i in n:
		var a0 := start + span * float(i)
		var a1 := a0 + span
		# Sommets et UV calqués sur ceux d'un `QuadMesh` vu de +Z, pour garder
		# l'orientation de la texture : `v` monte avec `y`.
		var xy: Array = [Vector2(-c, a0), Vector2(c, a0), Vector2(c, a1), Vector2(-c, a1)] \
			if vertical \
			else [Vector2(a0, -c), Vector2(a1, -c), Vector2(a1, c), Vector2(a0, c)]
		var base := verts.size()
		for j in 4:
			verts.append(Vector3(xy[j].x, xy[j].y, 0.0))
			norms.append(Vector3.FORWARD)
			uvs.append(uv_rect.position + uu[j] * uv_rect.size)
		idx.append(base + 0)
		idx.append(base + 1)
		idx.append(base + 2)
		idx.append(base + 0)
		idx.append(base + 2)
		idx.append(base + 3)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

## Taille en pixels de la bande source d'une pièce, lue dans la région de
## l'AtlasTexture. Zéro si la texture est absente : le caller saute alors la
## grille et garde le quad nu.
static func band_px_of(atlas: Texture2D) -> Vector2:
	if atlas is AtlasTexture:
		return (atlas as AtlasTexture).region.size
	return Vector2.ZERO

static func _place(node: StaticBody3D, pos: Vector2, size: Vector2, atlas: Texture2D,
		piece: String, s: float) -> void:
	node.position = Vector3(pos.x, pos.y, 0.0)
	var shape := (node.get_child(0) as CollisionShape3D).shape as BoxShape3D
	shape.size = Vector3(maxf(size.x, 0.001), maxf(size.y, 0.001), FRAME_DEPTH)
	var visual := node.get_child(1) as MeshInstance3D
	var band := band_px_of(atlas)
	var uv := atlas_uv_rect(atlas)
	if TILED_PIECES.has(piece) and band.x > 0.0 and band.y > 0.0:
		visual.mesh = tiled_mesh(size, band, piece == "left" or piece == "right", s, uv)
	else:
		visual.mesh = quad_uv_mesh(size, uv)
	(visual.material_override as StandardMaterial3D).albedo_texture = tiled_albedo(atlas)

static func _sync_bar(quad: MeshInstance3D, s: float, mesh: QuadMesh, half: Vector2) -> void:
	var titlebar := quad.get_node_or_null("Titlebar") as MeshInstance3D
	if titlebar == null or not is_instance_valid(titlebar):
		return
	var bar_h: float = Decorations.world(Decorations.metrics(), s)["titlebar"]
	var bar_size := Vector2(mesh.size.x, bar_h)
	var top_atlas := Decorations.border_piece("top")
	var top_band := band_px_of(top_atlas)
	var has_top := top_band.x > 0.0 and top_band.y > 0.0
	if has_top:
		titlebar.mesh = tiled_mesh(bar_size, top_band, false, s, atlas_uv_rect(top_atlas))
	else:
		var q := QuadMesh.new()
		q.size = bar_size
		titlebar.mesh = q
	(titlebar.material_override as StandardMaterial3D).albedo_texture = \
		tiled_albedo(top_atlas) if has_top else top_atlas
	if top_band.x <= 0.0 or top_band.y <= 0.0:
		(titlebar.mesh as QuadMesh).size = bar_size
	titlebar.position = Vector3(0.0, half.y + bar_h * 0.5, 0.001)
	(titlebar.material_override as StandardMaterial3D).albedo_texture = top_atlas
	var bar_body := titlebar.get_node_or_null("BarBody") as StaticBody3D
	if bar_body != null:
		((bar_body.get_child(0) as CollisionShape3D).shape as BoxShape3D).size = \
			Vector3(mesh.size.x, bar_h, 0.02)
	_sync_buttons(titlebar, Decorations.world(Decorations.metrics(), s), half.x)
	# Typographie relue ici, et pas à la construction : `sync` est aussi le chemin
	# du rechargement à chaud, donc éditer `label_size` ou `label_color` dans le
	# JSON change le titre sans redémarrer.
	var label := titlebar.get_node_or_null("Label3D") as Label3D
	if label != null:
		var m: Dictionary = Decorations.metrics()
		label.font_size = int(m.get("label_size", 10.0))
		label.modulate = m.get("label_color", Color.WHITE) as Color

static func _sync_buttons(titlebar: MeshInstance3D, d: Dictionary, half_width: float) -> void:
	var xs := button_positions(BUTTON_ORDER.size(), str(d["alignment"]),
		float(d["button"]), float(d["gap"]), float(d["margin"]), half_width)
	var size: float = d["button"]
	for i in BUTTON_ORDER.size():
		var action: String = BUTTON_ORDER[i]
		var btn := titlebar.get_node_or_null("Btn" + action.capitalize()) as StaticBody3D
		if btn == null:
			continue
		btn.position = Vector3(xs[i], 0.0, 0.001)
		((btn.get_child(0) as CollisionShape3D).shape as BoxShape3D).size = \
			Vector3(size, size, BUTTON_DEPTH)
		((btn.get_child(1) as MeshInstance3D).mesh as QuadMesh).size = Vector2(size, size)
		# L'état appliqué est relu sur la meta : un bouton survolé au moment du
		# resync ne doit pas retomber à l'inactif sous le curseur.
		_paint_button(btn, action, int(btn.get_meta("button_state", 0)))

static func _paint_button(btn: StaticBody3D, action: String, state: int) -> void:
	var atlas := Decorations.button_atlas(action, state)
	if atlas == null:
		return
	var visual := btn.get_child(1) as MeshInstance3D
	if visual == null:
		return
	(visual.material_override as StandardMaterial3D).albedo_texture = atlas

## Applique l'état d'un bouton (0 inactif, 1 survolé, 2 pressé). Le `restore`
## remplace le `maximize` en plein écran.
static func set_button_state(body: StaticBody3D, action: String, state: int, fullscreen: bool) -> void:
	var asset := action
	if action == "maximize" and fullscreen:
		asset = "restore"
	var atlas := Decorations.button_atlas(asset, state)
	if atlas == null:
		return
	var visual := body.get_child(1) as MeshInstance3D
	if visual == null:
		return
	(visual.material_override as StandardMaterial3D).albedo_texture = atlas

static func set_frame_visible(quad: MeshInstance3D, on: bool) -> void:
	var deco := quad.get_node_or_null("Decoration") as Node3D
	if deco == null:
		return
	deco.visible = on
	# Un cadre caché ne doit pas non plus rester attrapable : un client CSD
	# dessine le sien, dans SON contenu, et nos poignées seraient fantômes.
	for spec: Dictionary in FRAME_PIECES:
		var node := deco.get_node_or_null(spec["node"]) as StaticBody3D
		if node == null:
			continue
		node.visible = on
		for shape_node in node.get_children():
			if shape_node is CollisionShape3D:
				shape_node.disabled = not on
				
## Région de l'atlas en UV normalisés (0..1 sur la texture de base).
static func atlas_uv_rect(atlas: Texture2D) -> Rect2:
	var at := atlas as AtlasTexture
	if at == null or at.atlas == null:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var tex_size := Vector2(at.atlas.get_size())
	return Rect2(at.region.position / tex_size, at.region.size / tex_size)

## Texture réellement assignée au matériau d'une pièce tilée.
static func tiled_albedo(atlas: Texture2D) -> Texture2D:
	var at := atlas as AtlasTexture
	return at.atlas if at != null and at.atlas != null else atlas

## Quad simple dont les UV pointent la région de l'atlas (orientation QuadMesh : v=0 en haut).
static func quad_uv_mesh(size: Vector2, uv_rect: Rect2) -> Mesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var p := uv_rect.position
	var e := uv_rect.end
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-hx, -hy, 0.0), Vector3(hx, -hy, 0.0),
		Vector3(hx, hy, 0.0), Vector3(-hx, hy, 0.0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(p.x, e.y), Vector2(e.x, e.y), Vector2(e.x, p.y), Vector2(p.x, p.y)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
