extends Node
## Chat vocal : transport des trames OPUS entre joueurs.
##
## Module de LanManager (nœud enfant « Voice ») : le client envoie chaque trame de 20 ms à l'hôte (ou au serveur
## dédié) en non fiable sur le canal 3 (audio) ; l'hôte valide (taille, cadence, pair inscrit) puis la relaie à chaque
## autre joueur avec l'identifiant de l'émetteur. Le relais explicite (plutôt que celui de Godot) permet de valider
## et, plus tard, de filtrer par distance. Autorisé en mode online, sauf si le serveur est lancé avec --no-voice.
## Capture, décodage et restitution : scripts/main/voice_manager.gd (le serveur dédié ne fait que relayer).

signal voice_packet(from_id: int, seq: int, data: PackedByteArray)

const MAX_PACKET := 400          # octets (OPUS 24 kb/s : ~60 octets par trame de 20 ms)
const MAX_RATE := 60             # trames par seconde et par pair (50 attendues)

var lan = null                   # LanManager (non typé : doublure possible dans les tests)
var disabled := false            # serveur : relais coupé (--no-voice)

var _budget: Dictionary = {}     # hôte : peer -> {t, n}
# Diagnostic (CYBERREALM_VOICE_DEBUG=1) : trames envoyées / reçues par l'hôte / relayées / reçues, chaque seconde.
var _dbg := OS.get_environment("CYBERREALM_VOICE_DEBUG") == "1"
var _dbg_counts := {"sent": 0, "up": 0, "relayed": 0, "down": 0, "refused": 0}
var _dbg_t := 0

func _process(_delta: float) -> void:
	if not _dbg:
		return
	var now := Time.get_ticks_msec()
	if now - _dbg_t >= 1000:
		_dbg_t = now
		if _dbg_counts.values().any(func(v): return v > 0):
			print("[voice] ", _dbg_counts)
		for k in _dbg_counts:
			_dbg_counts[k] = 0

## Envoie une trame du joueur local.
func send(seq: int, data: PackedByteArray) -> void:
	if disabled or not lan.is_session_active() or data.size() > MAX_PACKET:
		return
	_dbg_counts["sent"] += 1
	if lan.is_host:
		_host_relay(_local_id(), seq, data)
	else:
		_voice_up.rpc_id(1, seq, data)

func _local_id() -> int:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return 1
	return multiplayer.get_unique_id()

@rpc("any_peer", "call_remote", "unreliable", 3)
func _voice_up(seq: Variant, data: Variant) -> void:
	if lan.is_host and seq is int and data is PackedByteArray:
		_dbg_counts["up"] += 1
		_host_relay(multiplayer.get_remote_sender_id(), seq, data)

@rpc("authority", "call_remote", "unreliable", 3)
func _voice_down(from_id: Variant, seq: Variant, data: Variant) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if from_id is int and seq is int and data is PackedByteArray and (data as PackedByteArray).size() <= MAX_PACKET:
		_dbg_counts["down"] += 1
		voice_packet.emit(from_id, seq, data)

## Hôte : valide puis relaie la trame à tous les autres joueurs (et la joue si l'hôte est lui-même joueur).
func _host_relay(from: int, seq: int, data: PackedByteArray) -> void:
	if disabled or data.is_empty() or data.size() > MAX_PACKET or not _registered(from) \
			or not budget_ok(_budget, from, Time.get_ticks_msec(), MAX_RATE):
		_dbg_counts["refused"] += 1
		return
	var me := _local_id()
	if from != me and not lan.dedicated:
		voice_packet.emit(from, seq, data)
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return
	for peer in multiplayer.get_peers():
		if peer != from:
			_dbg_counts["relayed"] += 1
			_voice_down.rpc_id(peer, from, seq, data)

func _registered(peer: int) -> bool:
	if peer == _local_id():
		return not lan.dedicated
	return peer > 0 and lan._players.has(peer) and not lan.session._pending_auth.has(peer)

func forget_peer(peer: int) -> void:
	_budget.erase(peer)

## Au plus `max_per_sec` événements par seconde (fenêtre fixe d'une seconde) pour ce pair.
static func budget_ok(budget: Dictionary, peer: int, now: int, max_per_sec: int) -> bool:
	var b: Dictionary = budget.get(peer, {"t": now, "n": 0})
	if now - int(b["t"]) >= 1000:
		b = {"t": now, "n": 0}
	b["n"] = int(b["n"]) + 1
	budget[peer] = b
	return int(b["n"]) <= max_per_sec
