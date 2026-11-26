extends Node
## Annotations sur une fenêtre partagée (lot K) : rendu et outil de dessin. Données et réseau :
## scripts/network/lan/annotations.gd.
##
## Rendu : par fenêtre annotée, un SubViewport transparent (Line2D) créé à la première annotation et redessiné à la
## demande (UPDATE_ONCE), affiché par un quad superposé enfant du quad de la fenêtre (2 mm devant, sans écriture de
## profondeur, priorité juste au-dessus) et, en mode focus, par un TextureRect au-dessus de la fenêtre. On évite un
## uniform dans le shader de la fenêtre pour ne pas casser les shaders utilisateur (window_shaders.gd).
##
## Outil (mode annotation, action « annotate » ou menu radial) : clic gauche maintenu = stylo à la couleur du joueur,
## clic droit maintenu = gomme (ses propres traits). En 3D on vise au réticule ; en mode focus, à la souris. Pendant
## le mode, les clics ne vont plus à la fenêtre.

const VP_WIDTH := 1024
const PEN_WIDTH := 4.0            # unités : px pour une fenêtre de 1000 px de large

var annotations: Node = null      # LAN/Annotations
var lan = null
var win3d: Node = null
var focus: Node = null

var active := false               # mode annotation
var ephemeral_setting: Callable   # () -> bool : option « annotations éphémères »
var _views: Dictionary = {}       # "owner:wid" -> {vp, root, quad, rect}
var _target := ""                 # fenêtre en cours de dessin

func setup(p_annotations: Node, p_lan, p_win3d: Node, p_focus: Node) -> void:
	annotations = p_annotations
	lan = p_lan
	win3d = p_win3d
	focus = p_focus
	annotations.strokes_changed.connect(_on_strokes_changed)

func toggle() -> void:
	active = not active
	if not active:
		annotations.end_stroke()

# ── Fenêtres ───────────────────────────────────────────────────────────

func _quad_of(owner: int, wid: int) -> MeshInstance3D:
	if owner == annotations.my_id():
		var q: Variant = win3d.quads.get(wid)
		return q if q != null and is_instance_valid(q) else null
	var per: Dictionary = lan.window_share._remote_window_quads.get(owner, {})
	var rq: Variant = per.get(wid)
	return rq if rq != null and is_instance_valid(rq) else null

func _aspect(owner: int, wid: int) -> float:
	var q := _quad_of(owner, wid)
	if q != null and q.mesh is QuadMesh:
		var s: Vector2 = (q.mesh as QuadMesh).size
		if s.y > 0.0:
			return s.x / s.y
	return 16.0 / 9.0

## Fenêtre visée en mode focus : [owner, wid] ou [].
func _focus_target() -> Array:
	if focus == null or not focus.is_active():
		return []
	if focus.is_remote():
		return [focus.get_remote_peer(), focus.get_remote_wid()]
	var wid: int = focus.get_focus_window_id()
	return [annotations.my_id(), wid] if wid != -1 else []

# ── Outil ──────────────────────────────────────────────────────────────

## Mode 3D : rayon de visée. true si l'outil a consommé la visée (les clics ne vont pas à la fenêtre).
func handle_3d(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3, exclude: Array) -> bool:
	if not active:
		return false
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	params.exclude = exclude
	var hit := space.intersect_ray(params)
	var owner := -1
	var wid := -1
	var quad: MeshInstance3D = null
	if not hit.is_empty():
		var body: Node = hit.collider
		if body.has_meta("window_id"):
			owner = annotations.my_id()
			wid = int(body.get_meta("window_id"))
		elif body.has_meta("remote_window"):
			var info: Dictionary = body.get_meta("remote_window")
			owner = int(info.get("peer_id", -1))
			wid = int(info.get("wid", -1))
		quad = _quad_of(owner, wid) if wid != -1 else null
	if quad == null or not quad.mesh is QuadMesh:
		_apply_tool(-1, -1, Vector2.ZERO)
		return true
	var local: Vector3 = quad.global_transform.affine_inverse() * (hit.position as Vector3)
	var size: Vector2 = (quad.mesh as QuadMesh).size
	var uv := Vector2(local.x / size.x + 0.5, 0.5 - local.y / size.y)
	_apply_tool(owner, wid, uv)
	return true

## Mode focus : position de la souris. true si consommé.
func handle_focus(mouse_pos: Vector2) -> bool:
	if not active:
		return false
	var t := _focus_target()
	if t.is_empty():
		return true
	var uv := Vector2(-1, -1)
	if focus.is_remote():
		uv = focus.remote.screen_to_uv(mouse_pos)
	else:
		var rect: Control = focus.focus_rects.get(t[1])
		if rect != null and is_instance_valid(rect):
			var r := rect.get_global_rect()
			uv = (mouse_pos - r.position) / r.size
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		_apply_tool(-1, -1, Vector2.ZERO)
	else:
		_apply_tool(t[0], t[1], uv)
	return true

func _apply_tool(owner: int, wid: int, uv: Vector2) -> void:
	var key := "%d:%d" % [owner, wid]
	var pen := Input.is_action_pressed("left_click")
	var eraser := Input.is_action_pressed("right_click")
	if annotations.is_drawing() and (not pen or key != _target or wid == -1):
		annotations.end_stroke()
		_target = ""
	if wid == -1 or not annotations.is_annotatable(owner, wid):
		return
	if pen:
		if not annotations.is_drawing():
			annotations.begin_stroke(owner, wid, lan.player_color, PEN_WIDTH, uv)
			_target = key
		else:
			annotations.add_point(uv)
	elif eraser:
		annotations.erase_near(owner, wid, uv)

# ── Rendu ──────────────────────────────────────────────────────────────

func _on_strokes_changed(owner: int, wid: int) -> void:
	var key := "%d:%d" % [owner, wid]
	var list: Dictionary = annotations.strokes(owner, wid)
	if list.is_empty():
		_drop_view(key)
		return
	var v := _ensure_view(key, owner, wid)
	if v.is_empty():
		return
	var vp: SubViewport = v["vp"]
	var root: Node2D = v["root"]
	for c in root.get_children():
		c.queue_free()
	var scale := Vector2(vp.size)
	var px_per_unit := float(vp.size.x) / 1000.0
	for sk in list:
		var s: Dictionary = list[sk]
		var line := Line2D.new()
		line.default_color = s["color"]
		line.width = float(s["width"]) * px_per_unit
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		line.end_cap_mode = Line2D.LINE_CAP_ROUND
		line.antialiased = true
		var pts := PackedVector2Array()
		for p in (s["points"] as PackedVector2Array):
			pts.append(p * scale)
		if pts.size() == 1:
			pts.append(pts[0] + Vector2(0.5, 0.5))     # point isolé : visible
		line.points = pts
		root.add_child(line)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

func _ensure_view(key: String, owner: int, wid: int) -> Dictionary:
	var v: Dictionary = _views.get(key, {})
	var quad := _quad_of(owner, wid)
	if v.is_empty():
		var vp := SubViewport.new()
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		vp.size = Vector2i(VP_WIDTH, maxi(1, int(VP_WIDTH / _aspect(owner, wid))))
		add_child(vp)
		var root := Node2D.new()
		vp.add_child(root)
		v = {"vp": vp, "root": root, "quad": null, "rect": null, "owner": owner, "wid": wid}
		_views[key] = v
	_attach(v, quad)
	return v

## Quad superposé (3D) et overlay du mode focus, recréés si la fenêtre ou la vue focus ont changé.
func _attach(v: Dictionary, quad: MeshInstance3D) -> void:
	var vp: SubViewport = v["vp"]
	if quad != null and (v["quad"] == null or not is_instance_valid(v["quad"]) or v["quad"].get_parent() != quad):
		if v["quad"] != null and is_instance_valid(v["quad"]):
			v["quad"].queue_free()
		var o := MeshInstance3D.new()
		o.mesh = QuadMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 1
		mat.albedo_texture = vp.get_texture()
		o.material_override = mat
		o.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		o.position = Vector3(0, 0, 0.002)
		quad.add_child(o)
		v["quad"] = o
	if v["quad"] != null and is_instance_valid(v["quad"]) and quad != null and quad.mesh is QuadMesh:
		(v["quad"].mesh as QuadMesh).size = (quad.mesh as QuadMesh).size
	# Mode focus sur cette fenêtre : overlay 2D au-dessus de l'image.
	var t := _focus_target()
	var host: Control = null
	if not t.is_empty() and int(t[0]) == int(v["owner"]) and int(t[1]) == int(v["wid"]):
		host = focus.remote_focus_rect if focus.is_remote() else focus.focus_rects.get(t[1])
	if host != null and is_instance_valid(host):
		if v["rect"] == null or not is_instance_valid(v["rect"]) or v["rect"].get_parent() != host:
			var r := TextureRect.new()
			r.texture = vp.get_texture()
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.set_anchors_preset(Control.PRESET_FULL_RECT)
			r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if focus.is_remote() else TextureRect.STRETCH_SCALE
			host.add_child(r)
			v["rect"] = r
	elif v["rect"] != null and is_instance_valid(v["rect"]):
		v["rect"].queue_free()
		v["rect"] = null

func _drop_view(key: String) -> void:
	var v: Dictionary = _views.get(key, {})
	if v.is_empty():
		return
	for n in [v["quad"], v["rect"], v["vp"]]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_views.erase(key)

## Suivi des vues : quad recréé (fenêtre distante re-synchronisée), entrée / sortie du mode focus.
func _process(_delta: float) -> void:
	if ephemeral_setting.is_valid():
		annotations.ephemeral = bool(ephemeral_setting.call())
	if active and (lan == null or not lan.is_session_active() or lan.online_restricted()):
		toggle()                  # plus de session : fin du mode
	for key in _views.keys():
		var v: Dictionary = _views[key]
		_attach(v, _quad_of(int(v["owner"]), int(v["wid"])))
