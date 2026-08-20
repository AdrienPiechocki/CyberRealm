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
		"quit":
			return _cmd_quit()
		_:
			return {"ok": false, "error": " commande inconnue: " + cmd}

# ── Commandes ──────────────────────────────────────────────────────

func _cmd_launch(cmd: String) -> Dictionary:
	if cmd.is_empty():
		return {"ok": false, "error": "aucune commande spécifiée"}
	compositor.launch_app(cmd)
	return {"ok": true, "output": cmd}

func _cmd_windows() -> Dictionary:
	var windows: Array = []
	if win3d != null and win3d.has_method("get_windows_state"):
		windows = win3d.get_windows_state()
	return {"ok": true, "output": windows}

func _cmd_close(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "id de fenêtre invalide: " + args}
	compositor.close_window(wid)
	return {"ok": true, "output": wid}

func _cmd_focus(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "id de fenêtre invalide: " + args}
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
		return {"ok": false, "error": "système PiP non disponible"}
	if pins.has_method("is_pinned") and pins.is_pinned(wid):
		pins.unpin(wid)
		return {"ok": true, "output": "unpinned"}
	var quads: Dictionary = win3d.quads
	if not quads.has(wid):
		return {"ok": false, "error": "fenêtre introuvable: " + args}
	pins.pin(wid, win3d.get_window_texture(wid))
	return {"ok": true, "output": "pinned"}

func _cmd_hide(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "id de fenêtre invalide: " + args}
	if win3d != null and win3d.has_method("toggle_hide"):
		win3d.toggle_hide(wid)
		return {"ok": true, "output": wid}
	return {"ok": false, "error": "système de fenêtres non disponible"}

func _cmd_share(args: String) -> Dictionary:
	var wid := args.to_int()
	if wid == 0 and args != "0":
		return {"ok": false, "error": "id de fenêtre invalide: " + args}
	if win3d == null:
		return {"ok": false, "error": "système de fenêtres non disponible"}
	if win3d.has_method("is_window_shared") and win3d.has_method("set_window_shared"):
		var current: bool = win3d.is_window_shared(wid)
		win3d.set_window_shared(wid, not current)
		return {"ok": true, "output": not current}
	return {"ok": false, "error": "méthode share non disponible"}

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
	return {"ok": false, "error": "layers non disponibles"}

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
