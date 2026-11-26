extends Node
## Chat textuel et emotes entre joueurs.
##
## Module de LanManager (nœud enfant « Chat ») : le client envoie à l'hôte (ou au serveur dédié), qui valide —
## pair inscrit, texte nettoyé et borné, cadence limitée — puis diffuse à tous. Le nom et la couleur de l'auteur
## viennent du roster local de chaque machine : seul l'identifiant du pair circule. Autorisé en mode online (texte
## borné relayé par le serveur). Le serveur dédié écrit le chat dans son journal.

signal chat_received(from_id: int, text: String)
signal emote_received(from_id: int, emote: String)

const MAX_LEN := 280
const CHAT_BURST := 5            # messages…
const CHAT_WINDOW_MSEC := 5000   # …par fenêtre glissante, par pair
const EMOTE_GAP_MSEC := 1000     # une emote par seconde au plus, par pair

## Catalogue fixe : id -> [emoji, verbe affiché dans le chat].
const EMOTES := {
	"wave": ["👋", "waves"],
	"point": ["👉", "points"],
	"clap": ["👏", "claps"],
	"thumbsup": ["👍", "gives a thumbs up"],
	"laugh": ["😂", "laughs"],
	"dance": ["💃", "dances"],
	"sit": ["🪑", "sits down"],
	"shrug": ["🤷", "shrugs"],
}
## Emotes qui durent jusqu'à ce que le joueur bouge (les autres se jouent une fois).
const LOOPING_EMOTES := ["dance", "sit"]

var lan = null                   # LanManager (non typé : remplaçable par une doublure dans les tests)
var muted: Dictionary = {}       # peer_id -> true : sourdine locale (chat et emotes)

var _chat_times: Dictionary = {} # hôte : peer -> [horodatages ms]
var _emote_last: Dictionary = {} # hôte : peer -> horodatage ms

# ── API ────────────────────────────────────────────────────────────────

## Envoie une ligne saisie par le joueur : texte, ou commande « /emote ». Renvoie "" si envoyé, sinon un message
## d'erreur à afficher localement (commande inconnue, pas de session…).
func submit(line: String) -> String:
	if not lan.is_session_active():
		return "Not in a multiplayer session"
	var cmd := parse_command(line)
	if cmd.has("error"):
		return String(cmd["error"])
	if cmd.has("emote"):
		send_emote(String(cmd["emote"]))
		return ""
	if line.strip_edges().begins_with("//"):
		line = line.strip_edges().substr(1)     # « //texte » : message qui commence par « / »
	var text := clean_text(line)
	if text == "":
		return ""
	if lan.is_host:
		_host_chat(_local_id(), text)
	else:
		_chat_send.rpc_id(1, text)
	return ""

func send_emote(emote: String) -> void:
	if not EMOTES.has(emote) or not lan.is_session_active():
		return
	if lan.is_host:
		_host_emote(_local_id(), emote)
	else:
		_emote_send.rpc_id(1, emote)

func set_muted(peer_id: int, on: bool) -> void:
	if on:
		muted[peer_id] = true
	else:
		muted.erase(peer_id)

func is_muted(peer_id: int) -> bool:
	return muted.has(peer_id)

func player_name(peer_id: int) -> String:
	var e: Variant = lan._players.get(peer_id)
	return String(e.get("name", "Player %d" % peer_id)) if e is Dictionary else "Player %d" % peer_id

func player_color(peer_id: int) -> Color:
	var e: Variant = lan._players.get(peer_id)
	return Color(e.get("color", Color.WHITE)) if e is Dictionary else Color.WHITE

func _local_id() -> int:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return 1
	return multiplayer.get_unique_id()

# ── Réseau ─────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", 1)
func _chat_send(text: Variant) -> void:
	if lan.is_host and text is String:
		_host_chat(multiplayer.get_remote_sender_id(), text)

@rpc("authority", "call_remote", "reliable", 1)
func _chat_msg(from_id: int, text: Variant) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1 or not text is String:
		return
	var clean := clean_text(text)
	if clean != "":
		chat_received.emit(from_id, clean)

@rpc("any_peer", "call_remote", "reliable", 1)
func _emote_send(emote: Variant) -> void:
	if lan.is_host and emote is String:
		_host_emote(multiplayer.get_remote_sender_id(), emote)

@rpc("authority", "call_remote", "reliable", 1)
func _emote_msg(from_id: int, emote: Variant) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1 or not emote is String or not EMOTES.has(emote):
		return
	emote_received.emit(from_id, emote)

## Pair autorisé à parler : soi-même (hôte joueur) ou un pair inscrit (authentifié).
func _registered(peer: int) -> bool:
	if peer == _local_id():
		return not lan.dedicated
	return peer > 0 and lan._players.has(peer) and not lan.session._pending_auth.has(peer)

func _host_chat(from: int, raw: String) -> void:
	if not _registered(from):
		return
	var text := clean_text(raw)
	if text == "" or not rate_ok(_chat_times, from, Time.get_ticks_msec(), CHAT_BURST, CHAT_WINDOW_MSEC):
		return
	if lan.dedicated:
		print("[chat] %s: %s" % [player_name(from), text])
	else:
		chat_received.emit(from, text)
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		_chat_msg.rpc(from, text)

func _host_emote(from: int, emote: String) -> void:
	if not _registered(from) or not EMOTES.has(emote):
		return
	var now := Time.get_ticks_msec()
	if now - int(_emote_last.get(from, -EMOTE_GAP_MSEC)) < EMOTE_GAP_MSEC:
		return
	_emote_last[from] = now
	if lan.dedicated:
		print("[chat] * %s %s" % [player_name(from), EMOTES[emote][1]])
	else:
		emote_received.emit(from, emote)
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		_emote_msg.rpc(from, emote)

## Un pair parti : on oublie ses compteurs (un nouveau pair peut reprendre son identifiant).
func forget_peer(peer: int) -> void:
	_chat_times.erase(peer)
	_emote_last.erase(peer)
	muted.erase(peer)

# ── Logique pure (testée) ──────────────────────────────────────────────

## Texte affichable : caractères de contrôle retirés, blancs réduits à un espace, MAX_LEN caractères au plus.
static func clean_text(s: String) -> String:
	var out := ""
	var last_space := true
	for i in s.length():
		var c := s.unicode_at(i)
		var space := c == 32 or c == 9 or c == 10 or c == 13 or c == 0x3000 or c == 0xA0
		if space:
			if not last_space:
				out += " "
			last_space = true
			continue
		# Contrôles C0/C1, DEL, marques bidi (retournement du texte affiché), séparateurs de ligne.
		if c < 32 or c == 127 or (c >= 0x80 and c < 0xA0) or (c >= 0x202A and c <= 0x202E) \
				or (c >= 0x2066 and c <= 0x2069) or c == 0x2028 or c == 0x2029:
			continue
		out += String.chr(c)
		last_space = false
	out = out.strip_edges()
	if out.length() > MAX_LEN:
		out = out.substr(0, MAX_LEN).strip_edges()
	return out

## Cadence : au plus `burst` événements par `window_ms` pour ce pair. Enregistre l'événement s'il est accepté.
static func rate_ok(times: Dictionary, peer: int, now: int, burst: int, window_ms: int) -> bool:
	var recent: Array = (times.get(peer, []) as Array).filter(func(t): return now - int(t) < window_ms)
	if recent.size() >= burst:
		times[peer] = recent
		return false
	recent.append(now)
	times[peer] = recent
	return true

## Ligne commençant par « / » : {"emote": id} pour une emote connue, {"error": …} sinon. {} pour un texte normal
## (« // » permet d'écrire un message qui commence par « / »).
static func parse_command(line: String) -> Dictionary:
	var t := line.strip_edges()
	if not t.begins_with("/") or t.begins_with("//"):
		return {}
	var word := t.substr(1).split(" ", false)
	var name := String(word[0]).to_lower() if not word.is_empty() else ""
	if EMOTES.has(name):
		return {"emote": name}
	return {"error": "Unknown command. Emotes: /" + " /".join(PackedStringArray(EMOTES.keys()))}
