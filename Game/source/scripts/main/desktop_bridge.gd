extends Node
## Pont avec le bureau (lot L) : lecteurs multimédia (MPRIS) et notifications, pour les objets du monde.
##
## Lance compositors/desktop-bridge/cyberrealm-desktop-bridge (Python + PyGObject) APRÈS launch_portals(), pour
## qu'il hérite du bus D-Bus privé du jeu ; le bus de l'hôte lui est passé en argument (vide sous KMS). Échange en
## lignes JSON sur stdin / stdout (OS.execute_with_pipe non bloquant), aucun polling D-Bus côté jeu.
##
## Nœud enfant de wayland_room (survit aux changements de niveau), groupe « desktop_bridge » : les objets du niveau
## le trouvent par get_tree().get_first_node_in_group("desktop_bridge"). API pour les objets (voir user/README.md) :
##   signal media_changed(player: Dictionary)   — {id, bus, name, identity, status, title, artist, album, art,
##                                                  length (µs), position (µs), position_at (ms), can_next…}
##   signal media_removed(id: String)
##   signal notification_received(n: Dictionary) — {id, bus, app, summary, body, actions, actionable, time}
##   signal notification_closed(bus: String, id: int)
##   func players() -> Array ; func current_player() -> Dictionary ; func notifications() -> Array
##   func media_command(player_id: String, cmd: String, offset_us := 0) ; func notification_action(n, action)
## Sur un serveur dédié, ce nœud n'existe pas : les objets restent inertes.

signal media_changed(player: Dictionary)
signal media_removed(id: String)
signal notification_received(n: Dictionary)
signal notification_closed(bus: String, id: int)

const BRIDGE_REL := "compositors/desktop-bridge/cyberrealm-desktop-bridge"
const MAX_NOTIFICATIONS := 20
const MAX_LINE := 65536

var _proc: Dictionary = {}
var _buf := ""
var _players: Dictionary = {}          # id -> état
var _last_active := ""                 # dernier lecteur passé en lecture
var _notifications: Array = []         # plus récente en premier
var running := false
## () -> "full" | "app" | "count" : contenu des notifications affiché dans le monde (option General).
var privacy: Callable

func _ready() -> void:
	add_to_group("desktop_bridge")
	process_mode = Node.PROCESS_MODE_ALWAYS

static func find_script() -> String:
	for p in [OS.get_executable_path().get_base_dir() + "/../../" + BRIDGE_REL,
			ProjectSettings.globalize_path("res://") + "../../" + BRIDGE_REL]:
		if FileAccess.file_exists(p):
			return p.simplify_path()
	return ""

## host_bus : adresse du bus de session de l'hôte capturée avant launch_portals() (vide sous KMS).
func start(host_bus: String) -> void:
	var script := find_script()
	if script == "":
		push_warning("desktop_bridge: %s introuvable — objets du bureau inertes" % BRIDGE_REL)
		return
	var args := PackedStringArray(["-I", script])
	if host_bus != "":
		args.append("--host-bus=" + host_bus)
	_proc = OS.execute_with_pipe("python3", args, false)
	running = not _proc.is_empty()
	if not running:
		push_warning("desktop_bridge: lancement impossible (python3 / PyGObject ?)")

func _exit_tree() -> void:
	stop()

func stop() -> void:
	if _proc.is_empty():
		return
	var pid := int(_proc.get("pid", -1))
	var io: FileAccess = _proc.get("stdio")
	if io != null:
		io.close()                     # stdin fermé : le pont s'arrête de lui-même
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	_proc = {}
	running = false

func _process(_delta: float) -> void:
	if _proc.is_empty():
		return
	var io: FileAccess = _proc["stdio"]
	var chunk := io.get_buffer(16384)
	if chunk.is_empty():
		return
	_buf += chunk.get_string_from_utf8()
	while true:
		var i := _buf.find("\n")
		if i < 0:
			if _buf.length() > MAX_LINE:
				_buf = ""            # ligne démesurée : jetée
			break
		var line := _buf.substr(0, i)
		_buf = _buf.substr(i + 1)
		var v: Variant = JSON.parse_string(line)
		if v is Dictionary:
			handle_event(v)

## Un événement du pont (public pour les tests).
func handle_event(e: Dictionary) -> void:
	match String(e.get("type", "")):
		"media":
			var id := "%s:%s" % [e.get("bus", ""), e.get("name", "")]
			var p := e.duplicate()
			p["id"] = id
			p["position_at"] = Time.get_ticks_msec()
			var was: String = String(_players.get(id, {}).get("status", ""))
			_players[id] = p
			if String(p.get("status", "")) == "Playing" and was != "Playing":
				_last_active = id
			media_changed.emit(p)
		"media_removed":
			var id := "%s:%s" % [e.get("bus", ""), e.get("name", "")]
			_players.erase(id)
			if _last_active == id:
				_last_active = ""
			media_removed.emit(id)
		"notification":
			var n := e.duplicate()
			n["time"] = Time.get_unix_time_from_system()
			# Remplacement (même id sur le même bus) : l'ancienne disparaît.
			_notifications = _notifications.filter(func(o): return not (o["bus"] == n["bus"] and int(o["id"]) == int(n["id"])))
			_notifications.push_front(n)
			if _notifications.size() > MAX_NOTIFICATIONS:
				_notifications.resize(MAX_NOTIFICATIONS)
			notification_received.emit(n)
		"notification_closed":
			notification_closed.emit(String(e.get("bus", "")), int(e.get("id", 0)))

func players() -> Array:
	return _players.values()

## Lecteur à afficher : celui en lecture (le dernier lancé), sinon le dernier actif, sinon un lecteur du jeu.
func current_player() -> Dictionary:
	var playing: Array = _players.values().filter(func(p): return p.get("status") == "Playing")
	if _players.has(_last_active) and _players[_last_active].get("status") == "Playing":
		return _players[_last_active]
	if not playing.is_empty():
		return playing[0]
	if _players.has(_last_active):
		return _players[_last_active]
	for p in _players.values():
		if p.get("bus") == "game":
			return p
	return _players.values()[0] if not _players.is_empty() else {}

## Position estimée (µs) : la dernière connue + le temps écoulé si le lecteur joue.
static func estimated_position(p: Dictionary) -> int:
	var pos := int(p.get("position", 0))
	if p.get("status") == "Playing":
		pos += (Time.get_ticks_msec() - int(p.get("position_at", Time.get_ticks_msec()))) * 1000
	var length := int(p.get("length", 0))
	return mini(pos, length) if length > 0 else pos

func notifications() -> Array:
	return _notifications

func _send(obj: Dictionary) -> void:
	if _proc.is_empty():
		return
	var io: FileAccess = _proc["stdio"]
	io.store_string(JSON.stringify(obj) + "\n")
	io.flush()

func media_command(player_id: String, cmd: String, offset_us := 0) -> void:
	var p: Dictionary = _players.get(player_id, {})
	if p.is_empty() or not cmd in ["play_pause", "next", "previous", "seek"]:
		return
	_send({"cmd": "media", "bus": p["bus"], "name": p["name"], "action": cmd, "offset": offset_us})

## Action d'une notification (« default » par défaut) ; seulement celles servies par le pont (bus du jeu).
func notification_action(n: Dictionary, action := "default") -> void:
	if not bool(n.get("actionable", false)):
		return
	_send({"cmd": "notification_action", "id": int(n["id"]), "action": action})
