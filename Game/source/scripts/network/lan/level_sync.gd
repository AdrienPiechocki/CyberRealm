extends Node
## Scripts du niveau <-> serveur : messages de niveau et synchro des transforms du décor.
##
## Module de LanManager (nœud enfant « LevelSync »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

const LEVEL_MSG_TOPIC_MAX := 48

## Client -> serveur.
func send_level_message(topic: String, data: Variant = null, reliable := true) -> void:
	if not LanManager.session_active or lan.is_host:
		return
	if reliable:
		_level_msg_up.rpc_id(1, topic, data)
	else:
		_level_msg_up_u.rpc_id(1, topic, data)

## Serveur -> tous les clients.
func broadcast_level_message(topic: String, data: Variant = null, reliable := true) -> void:
	if not LanManager.session_active or not lan.is_host:
		return
	if reliable:
		_level_msg_down.rpc(topic, data)
	else:
		_level_msg_down_u.rpc(topic, data)

## Serveur -> un client.
func send_level_message_to(peer: int, topic: String, data: Variant = null) -> void:
	if LanManager.session_active and lan.is_host:
		_level_msg_down.rpc_id(peer, topic, data)

@rpc("any_peer", "call_remote", "reliable", 1)
func _level_msg_up(topic: String, data: Variant) -> void:
	_accept_level_msg_up(topic, data)

@rpc("any_peer", "call_remote", "unreliable", 3)
func _level_msg_up_u(topic: String, data: Variant) -> void:
	_accept_level_msg_up(topic, data)

# Borne la forme d'un message de niveau (jamais confiance au réseau) : profondeur, tailles, types simples.
static func _msg_ok(v: Variant, depth := 0) -> bool:
	if depth > 3:
		return false
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR:
			return true
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v).length() <= 256
		TYPE_ARRAY:
			if (v as Array).size() > 32:
				return false
			for e in v:
				if not _msg_ok(e, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			if (v as Dictionary).size() > 16:
				return false
			for k in v:
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					return false
				if not _msg_ok(v[k], depth + 1):
					return false
			return true
		TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION:
			return true
	return false

var _msg_budget: Dictionary = {}            # peer -> {t, n} : cadence max des messages de niveau

func _accept_level_msg_up(topic: String, data: Variant) -> void:
	if not lan.is_host or topic.length() > LEVEL_MSG_TOPIC_MAX or not _msg_ok(data):
		return
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or lan.session._pending_auth.has(from) or not lan._players.has(from):
		return      # seuls les pairs inscrits (PIN vérifié) parlent au niveau
	var now := Time.get_ticks_msec()
	var b: Dictionary = _msg_budget.get(from, {"t": now, "n": 0})
	if now - int(b["t"]) >= 1000:
		b = {"t": now, "n": 0}
	b["n"] = int(b["n"]) + 1
	_msg_budget[from] = b
	if int(b["n"]) > 120:
		return      # > 120 messages / s : ignoré
	if topic == "admin_login":
		lan.session._handle_admin_login(from, data)
		return
	if topic == "level_ready":
		send_snapshot_to(from)        # un client vient de charger le niveau : état courant du décor
		return
	lan.level_message.emit(topic, data, from)

@rpc("authority", "call_remote", "reliable", 1)
func _level_msg_down(topic: String, data: Variant) -> void:
	_accept_level_msg_down(topic, data)

@rpc("authority", "call_remote", "unreliable", 3)
func _level_msg_down_u(topic: String, data: Variant) -> void:
	_accept_level_msg_down(topic, data)

func _accept_level_msg_down(topic: String, data: Variant) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1 or topic.length() > LEVEL_MSG_TOPIC_MAX:
		return
	if topic == "admin_status":
		lan.session.admin = data == true
		lan.admin_changed.emit(lan.session.admin)
		return
	lan.level_message.emit(topic, data, 1)

## Serveur : ajoute / retire un Node3D (mesh d'un objet en mouvement) de la synchro de transformations. Côté client,
## un nœud n'est mis à jour que s'il porte la méta « lan_sync_dynamic » (voir _resolve_dynamic_sync).
func register_level_sync(n: Node3D) -> void:
	if lan.is_host and lan._level_root != null and n.is_inside_tree():
		_level_sync_by_path[str(lan._level_root.get_path_to(n))] = n

func unregister_level_sync(n: Node3D) -> void:
	if lan.is_host and lan._level_root != null and n.is_inside_tree():
		_level_sync_by_path.erase(str(lan._level_root.get_path_to(n)))

func _resolve_dynamic_sync(path: String) -> Node3D:
	if lan._level_root == null:
		return null
	var n := lan._level_root.get_node_or_null(NodePath(path)) as Node3D
	if n != null and n.has_meta("lan_sync_dynamic"):
		_level_sync_by_path[path] = n
		return n
	return null

const LEVEL_SYNC_GAP := 0.05
var _level_sync_by_path: Dictionary = {}  # chemin relatif -> Node3D
var _level_sync_target: Dictionary = {}   # chemin -> Transform3D (client)
var _level_sync_snapped: Dictionary = {}
var _level_sync_timer := 0.0

func _refresh_level_sync() -> void:
	_level_sync_by_path.clear()
	_level_sync_target.clear()
	_level_sync_snapped.clear()
	if lan._level_root != null:
		_scan_sync(lan._level_root)

func _scan_sync(n: Node) -> void:
	if n is Node3D and n.has_meta("lan_sync"):
		_level_sync_by_path[str(lan._level_root.get_path_to(n))] = n
	if LanManager.session_active and not lan.is_host and n.has_meta("lan_host_only"):
		n.process_mode = Node.PROCESS_MODE_DISABLED
	for c in n.get_children():
		_scan_sync(c)

# Hôte : émet. Client : applique en lissé.
func _sync_level_state(delta: float) -> void:
	_dbg_sync(delta)
	if lan.is_host:
		_level_sync_timer += delta
		if _level_sync_timer < LEVEL_SYNC_GAP or _level_sync_by_path.is_empty():
			return
		_level_sync_timer = 0.0
		var state: Array = []
		for path in _level_sync_by_path:
			var n: Node3D = _level_sync_by_path[path]
			if is_instance_valid(n):
				state.append([path, n.transform])
		_level_sync.rpc(state)
		return
	if _level_sync_target.is_empty():
		return
	var t := 1.0 - exp(-delta * 12.0)
	for path in _level_sync_target:
		var n := _level_sync_by_path.get(path) as Node3D
		if n == null:
			n = _resolve_dynamic_sync(String(path))
		if n == null or not is_instance_valid(n):
			continue
		var target: Transform3D = _level_sync_target[path]
		if not _level_sync_snapped.has(path) or n.position.distance_to(target.origin) > 20.0:
			n.transform = target
			_level_sync_snapped[path] = true
		else:
			n.transform = n.transform.interpolate_with(target, t)

@rpc("authority", "unreliable_ordered", "call_remote", 7)
func _level_sync(state: Array) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	for e in state:
		if e is Array and e.size() == 2 and e[1] is Transform3D:
			_level_sync_target[String(e[0])] = e[1]

var _dbg_t := 0.0
func _dbg_sync(delta: float) -> void:
	_dbg_t += delta
	if _dbg_t < 2.0:
		return
	_dbg_t = 0.0
	for path in _level_sync_by_path:
		var n: Node3D = _level_sync_by_path[path]
		print("[sync %s] %s pos=%s | targets=%d" % ["host" if lan.is_host else "client", path, n.position.snappedf(0.1), _level_sync_target.size()])

# ── Instantané de l'état du niveau (arrivants, persistance) ─────────────
# Un joueur qui rejoint reçoit le niveau tel qu'il a été exporté (blob) ; les objets déplacés ou cassés depuis sont
# rattrapés par un INSTANTANÉ, demandé par le client (message « level_ready ») une fois le niveau chargé :
#   - partie « sync » : transformations de tous les nœuds synchronisés (lan_sync + objets dynamiques enregistrés) ;
#   - une partie par nœud du groupe « net_snapshot » du niveau : ce que renvoie son net_snapshot() côté serveur,
#     appliqué par son net_apply_snapshot(entrées) côté client (chemin du nœud relatif à la racine du niveau).
# Transport : _level_snapshot (fiable, canal 6), en morceaux de SNAPSHOT_CHUNK entrées, validé (pas _msg_ok, trop
# étroit pour un instantané). Le même format sert à la persistance du serveur dédié (dedicated_server.gd).

const SNAPSHOT_CHUNK := 256
const SNAPSHOT_MAX_ENTRIES := 8192
const SNAPSHOT_MAX_CHUNKS := 64
const SNAPSHOT_GROUP := "net_snapshot"

var _snap_rx: Dictionary = {}               # client : partie -> entrées reçues
var _snap_rx_count := 0

## Serveur : instantané courant {partie: [entrées]}.
func build_snapshot() -> Dictionary:
	var parts := {}
	if lan._level_root == null:
		return parts
	var sync: Array = []
	for path in _level_sync_by_path:
		var n: Node3D = _level_sync_by_path[path]
		if is_instance_valid(n):
			sync.append([String(path), n.transform])
	parts["sync"] = sync
	for n in get_tree().get_nodes_in_group(SNAPSHOT_GROUP) if is_inside_tree() else []:
		if lan._level_root.is_ancestor_of(n) and n.has_method("net_snapshot"):
			var entries: Variant = n.call("net_snapshot")
			if entries is Array:
				parts[str(lan._level_root.get_path_to(n))] = entries
	return parts

## Applique un instantané au niveau local (client à l'arrivée, ou serveur qui recharge son état sauvegardé).
func apply_snapshot(parts: Dictionary) -> void:
	if lan._level_root == null:
		return
	for part in parts:
		var entries: Array = parts[part]
		if part == "sync":
			for e in entries:
				if not (e is Array and e.size() == 2 and e[0] is String and e[1] is Transform3D):
					continue
				var n := lan._level_root.get_node_or_null(NodePath(e[0])) as Node3D
				if n == null:
					continue
				if lan.is_host:
					n.transform = e[1]
				else:
					_level_sync_target[String(e[0])] = e[1]
					_level_sync_snapped.erase(String(e[0]))     # premier placement sans lissage
			continue
		if not snapshot_part_ok(String(part)):
			continue
		var node := lan._level_root.get_node_or_null(NodePath(part))
		if node != null and node.has_method("net_apply_snapshot"):
			node.call("net_apply_snapshot", entries)

func send_snapshot_to(peer: int) -> void:
	if not lan.is_host or not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return
	var parts := build_snapshot()
	var sent := 0
	for part in parts:
		var chunks := chunk_entries(parts[part], SNAPSHOT_CHUNK)
		for i in chunks.size():
			_level_snapshot.rpc_id(peer, String(part), i, chunks.size(), chunks[i])
			sent += (chunks[i] as Array).size()
	lan._lan_log("level snapshot sent to %d (%d entries, %d parts)" % [peer, sent, parts.size()])

@rpc("authority", "call_remote", "reliable", 6)
func _level_snapshot(part: Variant, index: Variant, total: Variant, data: Variant) -> void:
	_receive_snapshot_chunk(multiplayer.get_remote_sender_id(), part, index, total, data)

## Corps de la réception, isolé pour les tests (émetteur explicite).
func _receive_snapshot_chunk(sender: int, part: Variant, index: Variant, total: Variant, data: Variant) -> void:
	if lan.is_host or sender != 1:
		return
	if not (part is String and index is int and total is int and data is Array):
		return
	if not snapshot_part_ok(part) or total < 1 or total > SNAPSHOT_MAX_CHUNKS or index < 0 or index >= total \
			or (data as Array).size() > SNAPSHOT_CHUNK:
		return
	if _snap_rx_count + (data as Array).size() > SNAPSHOT_MAX_ENTRIES:
		return
	for e in data:
		if not snapshot_entry_ok(e):
			return
	if index == 0:
		_snap_rx[part] = []
	if not _snap_rx.has(part):
		return       # morceau orphelin (le premier a été refusé)
	(_snap_rx[part] as Array).append_array(data)
	_snap_rx_count += (data as Array).size()
	if index == total - 1:
		apply_snapshot({part: _snap_rx[part]})
		_snap_rx.erase(part)

## Client : demande l'instantané au serveur (niveau chargé).
func request_snapshot() -> void:
	_snap_rx.clear()
	_snap_rx_count = 0
	send_level_message("level_ready")

# ── Logique pure (testée) ──────────────────────────────────────────────

static func chunk_entries(entries: Array, size: int) -> Array:
	var out: Array = []
	var i := 0
	while i < entries.size():
		out.append(entries.slice(i, i + size))
		i += size
	if out.is_empty():
		out.append([])      # partie vide : un morceau quand même (le client la vide de son côté)
	return out

## Partie d'instantané acceptable : « sync » ou un chemin relatif SOUS la racine du niveau (jamais « .. »).
static func snapshot_part_ok(part: String) -> bool:
	if part == "sync":
		return true
	return part != "" and part.length() <= 256 and not part.begins_with("/") and not part.contains("..")

## Entrée d'instantané : tableau de valeurs simples (profondeur 2), chaînes courtes.
static func snapshot_entry_ok(v: Variant, depth := 0) -> bool:
	if depth > 2:
		return false
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR3, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION:
			return true
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v).length() <= 256
		TYPE_ARRAY:
			if (v as Array).size() > 16:
				return false
			for e in v:
				if not snapshot_entry_ok(e, depth + 1):
					return false
			return true
	return false

