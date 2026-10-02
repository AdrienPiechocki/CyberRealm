extends RefCounted
## Construction et recalage du décor 3D d'UNE fenêtre (cadre, barre, boutons).
##
## Tout est enfant du quad de CONTENU : le décor déborde donc du mesh sans
## qu'aucun code de position, de rotation ou de déplacement n'ait à le suivre.
##
## API statique : aucun état propre, tout passe par le quad.

const Decorations := preload("res://scripts/ui/window_decorations.gd")

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

static func _unshaded() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Le SVG a des coins arrondis : sans alpha le cadre aurait des rectangles
	# opaques. ALPHA (et pas SCISSOR) pour garder un bord lissé.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

static func _build_titlebar(quad: MeshInstance3D, wid: int) -> MeshInstance3D:
	var titlebar := MeshInstance3D.new()
	titlebar.name = "Titlebar"
	# Invisible tant que le client n'a pas confirmé SERVER_SIDE : c'est
	# `on_window_decorations_changed` qui décide, comme avant, quand le
	# compositeur cède les décorations au jeu.
	titlebar.visible = false
	titlebar.mesh = QuadMesh.new() # dimensionné par sync()
	titlebar.material_override = _unshaded()
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
	visual.material_override = _unshaded()
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
	visual.material_override = _unshaded()
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
			_place(node, rect[0], rect[1], Decorations.border_piece(spec["piece"]))
	_sync_bar(quad, s, mesh, half)

static func _place(node: StaticBody3D, pos: Vector2, size: Vector2, atlas: Texture2D) -> void:
	node.position = Vector3(pos.x, pos.y, 0.0)
	var shape := (node.get_child(0) as CollisionShape3D).shape as BoxShape3D
	shape.size = Vector3(maxf(size.x, 0.001), maxf(size.y, 0.001), FRAME_DEPTH)
	var visual := node.get_child(1) as MeshInstance3D
	(visual.mesh as QuadMesh).size = size
	var mat := visual.material_override as StandardMaterial3D
	# `null` = cette pièce ne se dessine pas (texture absente) : le collider,
	# lui, reste — le redimensionnement ne dépend pas du visuel.
	mat.albedo_texture = atlas

static func _sync_bar(quad: MeshInstance3D, s: float, mesh: QuadMesh, half: Vector2) -> void:
	var titlebar := quad.get_node_or_null("Titlebar") as MeshInstance3D
	if titlebar == null or not is_instance_valid(titlebar):
		return
	var bar_h: float = Decorations.world(Decorations.metrics(), s)["titlebar"]
	(titlebar.mesh as QuadMesh).size = Vector2(mesh.size.x, bar_h)
	titlebar.position = Vector3(0.0, half.y + bar_h * 0.5, 0.0)
	(titlebar.material_override as StandardMaterial3D).albedo_texture = Decorations.border_piece("top")
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