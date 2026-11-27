extends Node
## CyberRealm Exec — drone de commandes IPC pour cyberrealm-exec.
## Poll un fichier de commande dans $XDG_RUNTIME_DIR à chaque frame,
## exécute la fonction correspondante et écrit la réponse en JSON.
##
## Protocole (même pattern que cyberrealm-capture-pending/choice) :
##   Requête  : $XDG_RUNTIME_DIR/cyberrealm-cmd
##              "<req_id> <commande> [args...]"
##   Réponse  : $XDG_RUNTIME_DIR/cyberrealm-cmd-resp
##              "<req_id> {json}"
##
## Commandes supportées :
##   launch <cmd>            Lancer une app
##   windows                 Lister les fenêtres
##   close <id>              Fermer une fenêtre
##   focus <id>              Focus plein écran
##   unfocus                 Sortir du focus
##   pin <id>                Toggle PiP
##   hide <id>               Toggle masquer
##   share <id>              Toggle partage screenshare
##   focus-mode              État du focus
##   layer-interact          Toggle mode interaction layer
##   keyboard-layout [l] [v] Get/set layout clavier
##   mem [n]                 Mémoire GPU : textures/buffers + n plus grosses textures
##   quit                    Quitter le jeu

var compositor: WlrCompositor
var win3d: Node
var focus: Node3D
var layers: Node3D
var pins: Node3D
var lan: Node
var player: Node

var _cmd_path := ""
var _resp_path := ""

func setup(p_compositor: WlrCompositor, p_win3d: Node, p_focus: Node3D,
		p_layers: Node3D, p_pins: Node3D, p_lan: Node, p_player: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	layers = p_layers
	pins = p_pins
	lan = p_lan
	player = p_player
	var rt: String = OS.get_environment("XDG_RUNTIME_DIR")
	if rt.is_empty():
		return
	_cmd_path = rt + "/cyberrealm-cmd"
	_resp_path = rt + "/cyberrealm-cmd-resp"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func _process(_delta: float) -> void:
	if _cmd_path.is_empty():
		return
	if not FileAccess.file_exists(_cmd_path):
		return
	var f := FileAccess.open(_cmd_path, FileAccess.READ)
	if f == null:
		return
	var line := f.get_line().strip_edges()
	f.close()
	DirAccess.remove_absolute(_cmd_path)
	if line.is_empty():
		return
	# Parsing : "<req_id> <commande> [args...]"
	var space := line.find(" ")
	if space == -1:
		return
	var req_id := line.substr(0, space)
	var rest := line.substr(space + 1).strip_edges()
	var cmd_space := rest.find(" ")
	var cmd: String
	var args := ""
	if cmd_space == -1:
		cmd = rest
	else:
		cmd = rest.substr(0, cmd_space)
		args = rest.substr(cmd_space + 1).strip_edges()
	var result := _dispatch(cmd, args)
	_write_response(req_id, JSON.stringify(result))

func _write_response(req_id: String, json: String) -> void:
	var f := FileAccess.open(_resp_path, FileAccess.WRITE)
	if f:
		f.store_string(req_id + " " + json + "\n")
		f.close()

func _dispatch(cmd: String, args: String) -> Dictionary:
	match cmd:
		"launch":
			return _cmd_launch(args)
		"windows":
			return _cmd_windows()
		"close":
			return _cmd_close(args)
		"focus":
			return _cmd_focus(args)
		"unfocus":
			return _cmd_unfocus()
		"pin":
			return _cmd_pin(args)
		"hide":
			return _cmd_hide(args)
		"share":
			return _cmd_share(args)
		"focus-mode":
			return _cmd_focus_mode()
		"layer-interact":
			return _cmd_layer_interact()
		"keyboard-layout":
			return _cmd_keyboard_layout(args)
		"overlay-bind":
			return _cmd_overlay_bind(args)
		"mem":
			return _cmd_mem(args)
		"quit":
			return _cmd_quit()
		_:
			return {"ok": false, "error": " unknown command: " + cmd}

# ── Commandes ──────────────────────────────────────────────────────

static func _mem_tex_format(t: Texture2D) -> int:
	if t.has_method("get_format"):
		return int(t.call("get_format"))
	return -1

# Taille GPU estimée : RGB8 est stocké en RGBA8 côté GPU ; × 4/3 pour les mipmaps.
static func _mem_tex_bytes(t: Texture2D) -> int:
	var px := float(t.get_width() * t.get_height())
	var bpp := 4.0
	match _mem_tex_format(t):
		Image.FORMAT_L8, Image.FORMAT_R8: bpp = 1.0
		Image.FORMAT_LA8, Image.FORMAT_RG8: bpp = 2.0
		Image.FORMAT_RGBAH: bpp = 8.0
		Image.FORMAT_RGBAF: bpp = 16.0
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R, Image.FORMAT_ETC2_RGB8: bpp = 0.5
		Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_RG, Image.FORMAT_BPTC_RGBA, \
				Image.FORMAT_BPTC_RGBF, Image.FORMAT_BPTC_RGBFU, Image.FORMAT_ETC2_RGBA8, Image.FORMAT_ASTC_4x4: bpp = 1.0
	return int(px * bpp * 4.0 / 3.0)

func _mem_collect(n: Node, texs: Dictionary, seen: Dictionary) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		_mem_collect_res(gi.material_override, texs, seen)
		_mem_collect_res(gi.material_overlay, texs, seen)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			for i in mi.get_surface_override_material_count():
				_mem_collect_res(mi.get_surface_override_material(i), texs, seen)
			_mem_collect_res(mi.mesh, texs, seen)
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			_mem_collect_res((n as MultiMeshInstance3D).multimesh.mesh, texs, seen)
	elif n is WorldEnvironment:
		_mem_collect_res((n as WorldEnvironment).environment, texs, seen)
	for c in n.get_children():
		_mem_collect(c, texs, seen)

func _mem_collect_res(r: Resource, texs: Dictionary, seen: Dictionary) -> void:
	if r == null or seen.has(r):
		return
	seen[r] = true
	if r is Texture2D:
		texs[r] = true
		return
	if r is Mesh:
		for i in (r as Mesh).get_surface_count():
			_mem_collect_res((r as Mesh).surface_get_material(i), texs, seen)
		return
	if r is ShaderMaterial:
		var sm := r as ShaderMaterial
		if sm.shader != null:
			for u in sm.shader.get_shader_uniform_list():
				var v = sm.get_shader_parameter(u["name"])
				if v is Resource:
					_mem_collect_res(v, texs, seen)
		_mem_collect_res(sm.next_pass, texs, seen)
		return
	for p in r.get_property_list():
		if p["usage"] & PROPERTY_USAGE_STORAGE and p["type"] == TYPE_OBJECT:
			var v = r.get(p["name"])
			if v is Resource:
				_mem_collect_res(v, texs, seen)

# Diagnostic mémoire GPU : totaux du RenderingDevice (allocations VMA), puis
# textures regroupées par origine (dossier du resource_path, « (embarquée) »
# pour celles des blobs/ImageTexture) et les n plus grosses. Sert à comparer
# avec la GTT/Shmem mesurée côté pilote (fdinfo, /proc/meminfo).
func _cmd_mem(args: String) -> Dictionary:
	var top_n := int(args) if args.is_valid_int() else 15
	var mb := func(b: float) -> String: return "%.0f MB" % (b / 1048576.0)
	var lines: Array[String] = []
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		lines.append("RD total=%s textures=%s buffers=%s" % [
			mb.call(rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)),
			mb.call(rd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES)),
			mb.call(rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS))])
	lines.append("RS video=%s texture=%s buffer=%s" % [
		mb.call(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)),
		mb.call(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)),
		mb.call(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED))])
	lines.append("static=%s objects=%d resources=%d nodes=%d" % [
		mb.call(OS.get_static_memory_usage()),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	# Textures référencées par la scène (matériaux des GeometryInstance3D et
	# des meshes), taille GPU estimée d'après le format (mipmaps comprises).
	var texs := {}
	_mem_collect(get_tree().root, texs, {})
	var groups := {}
	var total := 0
	var rows: Array = []
	for t: Texture2D in texs:
		var b := _mem_tex_bytes(t)
		total += b
		var path := t.resource_path
		var key := "(embarquée)"
		if path.contains("::"):
			key = path.get_slice("::", 0) + " (sous-ressource)"
		elif not path.is_empty():
			key = path.get_base_dir()
		var g: Dictionary = groups.get(key, {"bytes": 0, "n": 0})
		g["bytes"] = int(g["bytes"]) + b
		g["n"] = int(g["n"]) + 1
		groups[key] = g
		rows.append([b, t])
	lines.append("textures de la scène : %d, ~%s" % [texs.size(), mb.call(total)])
	var keys := groups.keys()
	keys.sort_custom(func(x, y): return int(groups[x]["bytes"]) > int(groups[y]["bytes"]))
	for k in keys.slice(0, top_n):
		lines.append("  %8s  %5d tex  %s" % [mb.call(groups[k]["bytes"]), int(groups[k]["n"]), k])
	rows.sort_custom(func(x, y): return int(x[0]) > int(y[0]))
	lines.append("plus grosses :")
	for r in rows.slice(0, top_n):
		var t: Texture2D = r[1]
		lines.append("  %8s  %dx%d %s fmt=%d  %s" % [mb.call(r[0]), t.get_width(), t.get_height(),
			t.get_class(), _mem_tex_format(t), t.resource_path.right(80)])
	return {"ok": true, "output": "\n".join(lines)}

func _cmd_launch(cmd: String) -> Dictionary:
	if cmd.is_empty():
		return {"ok": false, "error": "no command specified"}
	compositor.launch_app(cmd)
	return {"ok": true, "output": cmd}

func _cmd_windows() -> Dictionary:
	var windows: Array = []
	if win3d != null and win3d.has_method("get_windows_state"):
		windows = win3d.get_windows_state()
	# Mode focus : où la fenêtre est AFFICHÉE (x, y, width, height en pixels du viewport,
	# remplaçant la taille du contenu). Les clients (overlay de Ludodex) s'y calent quand elle
	# ne remplit pas l'écran. Hors focus (fenêtres 3D), pas de x/y : aucune position à l'écran.
	if focus != null and focus.has_method("get_displayed_content_rect"):
		for w in windows:
			var r: Rect2 = focus.get_displayed_content_rect(int(w.get("wid", -1)))
			if r.size.x > 0.0 and r.size.y > 0.0:
				w["x"] = roundi(r.position.x)
				w["y"] = roundi(r.position.y)
				w["width"] = roundi(r.size.x)
				w["height"] = roundi(r.size.y)
	# « covered » : la fenêtre n'est pas visible à l'écran. En mode focus, elle l'est si elle n'est
	# pas dans la pile ou si une fenêtre d'un autre processus, plus haut dans la pile, la recouvre
	# en partie (> 2 %). Hors focus, une fenêtre 3D n'est jamais « recouverte » : l'overlay est
	# dessiné SUR son quad (voir layer_surfaces.gd) et suit la fenêtre.
	var in_focus: bool = focus != null and focus.has_method("is_active") and focus.is_active() \
			and "focus_stack" in focus
	var stack: Array = focus.focus_stack if in_focus else []
	var vp := get_viewport().get_visible_rect().size
	for w in windows:
		var wid: int = int(w.get("wid", -1))
		if not in_focus and win3d != null and win3d.has_method("get_quad_info"):
			# Rectangle « virtuel » de l'overlay en 3D : la taille du contenu, ramenée à l'écran
			# en gardant le ratio, en (0, 0). Le client y règle la taille de sa surface, qui est
			# ensuite plaquée sur le quad de la fenêtre.
			var cs: Vector2 = win3d.get_quad_info(wid).get("content_size", Vector2.ZERO)
			if cs.x > 1.0 and cs.y > 1.0:
				var k := minf(1.0, minf(vp.x / cs.x, vp.y / cs.y))
				w["x"] = 0
				w["y"] = 0
				w["width"] = maxi(1, roundi(cs.x * k))
				w["height"] = maxi(1, roundi(cs.y * k))
		var idx := stack.find(wid)
		var covered := in_focus and idx < 0
		if not covered and in_focus and w.has("x"):
			var mine := Rect2(w["x"], w["y"], w["width"], w["height"])
			var area := mine.size.x * mine.size.y
			for other in windows:
				var oi := stack.find(int(other.get("wid", -1)))
				if oi > idx and other.has("x") and int(other.get("pid", -1)) != int(w.get("pid", -2)) \
						and not other.get("hidden", false):
					var o := Rect2(other["x"], other["y"], other["width"], other["height"])
					var inter := mine.intersection(o)
					if inter.size.x * inter.size.y * 50.0 > area:
						covered = true
						break
		w["covered"] = covered
	return {"ok": true, "output": windows}

# Fenêtre sur laquelle l'overlay de Ludodex (layer ludodex-overlay) est dessiné quand elle est
# en mode 3D. Appelé par l'overlay lui-même, qui sait quelle fenêtre est son jeu.
func _cmd_overlay_bind(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "invalid window id: " + args}
	if layers == null or not layers.has_method("bind_overlay"):
		return {"ok": false, "error": "layer surfaces unavailable"}
	layers.bind_overlay(wid)
	return {"ok": true, "output": wid}

func _cmd_close(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "invalid window id: " + args}
	compositor.close_window(wid)
	return {"ok": true, "output": wid}

func _cmd_focus(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "invalid window id: " + args}
	if focus != null and focus.has_method("enter_focus"):
		focus.enter_focus(wid)
	return {"ok": true, "output": wid}

func _cmd_unfocus() -> Dictionary:
	if focus != null and focus.has_method("exit_focus"):
		focus.exit_focus()
	return {"ok": true, "output": ""}

func _cmd_pin(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "id de fenêtre invalide: " + args}
	if pins == null or win3d == null:
		return {"ok": false, "error": "PiP system unavailable"}
	if pins.has_method("is_pinned") and pins.is_pinned(wid):
		pins.unpin(wid)
		return {"ok": true, "output": "unpinned"}
	var quads: Dictionary = win3d.quads
	if not quads.has(wid):
		return {"ok": false, "error": "window not found: " + args}
	pins.pin(wid, win3d.get_window_texture(wid))
	return {"ok": true, "output": "pinned"}

func _cmd_hide(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "invalid window id: " + args}
	if win3d != null and win3d.has_method("toggle_hide"):
		win3d.toggle_hide(wid)
		return {"ok": true, "output": wid}
	return {"ok": false, "error": "window system unavailable"}

func _cmd_share(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "invalid window id: " + args}
	if win3d == null:
		return {"ok": false, "error": "window system unavailable"}
	if win3d.has_method("is_window_shared") and win3d.has_method("set_window_shared"):
		var current: bool = win3d.is_window_shared(wid)
		win3d.set_window_shared(wid, not current)
		return {"ok": true, "output": not current}
	return {"ok": false, "error": "share method unavailable"}

func _cmd_focus_mode() -> Dictionary:
	var active := false
	if focus != null and focus.has_method("is_active"):
		active = focus.is_active()
	var focused_id := -1
	if focus != null and focus.has_method("get_focus_window_id"):
		focused_id = focus.get_focus_window_id()
	return {"ok": true, "output": {"active": active, "window_id": focused_id}}

func _cmd_layer_interact() -> Dictionary:
	if layers != null and layers.has_method("toggle_layer_interact"):
		layers.toggle_layer_interact()
		return {"ok": true, "output": "toggled"}
	return {"ok": false, "error": "layers unavailable"}

func _cmd_keyboard_layout(args: String) -> Dictionary:
	var parts := args.split(" ")
	if parts.size() >= 2:
		var layout := parts[0]
		var variant := parts[1]
		compositor.set_keyboard_layout(layout, variant)
		return {"ok": true, "output": {"layout": layout, "variant": variant}}
	elif parts.size() == 1 and not parts[0].is_empty():
		compositor.set_keyboard_layout(parts[0], "")
		return {"ok": true, "output": {"layout": parts[0], "variant": ""}}
	else:
		var cl := compositor.get_keyboard_layout() if compositor.has_method("get_keyboard_layout") else ""
		return {"ok": true, "output": cl}

func _cmd_quit() -> Dictionary:
	compositor.shutdown_apps()
	get_tree().quit()
	return {"ok": true, "output": "quit"}
