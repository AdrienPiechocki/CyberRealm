extends Node3D
## Partage de fichiers par glisser-déposer sur un avatar distant (LAN).
##
## Flux : pendant un drag Wayland (Dolphin, Nautilus…), survoler l'avatar d'un
## joueur affiche une invite ; relâcher dessus envoie une offre RPC. Le pair
## voit un prompt modal et valide d'un simple clic : sa machine installe
## ALORS la clé publique ssh de l'expéditeur dans ~/.ssh/authorized_keys
## (ligne restreinte, taguée), ce qui permet à l'expéditeur de pousser les
## fichiers par rsync-over-ssh vers ~/CyberRealmRecu/. La ligne est retirée
## dès la fin du transfert (et un balayage supprime les lignes orphelines).
##
## Aucun secret ne transite sur le réseau : pas de mot de passe partagé,
## l'authentification est une clé publique éphémère, et les données voyagent
## chiffrées par ssh. Prérequis documentés dans user/README.md :
## - chaque machine : openssh (ssh-keygen/ssh) + rsync ;
## - destinataire : serveur ssh actif avec authentification par clé.

const DEST_DIR_NAME := "CyberRealmRecu" # ~/CyberRealmRecu chez le destinataire
const CHANNEL := 7 # canal fiable dédié au partage de fichiers
const OFFER_TIMEOUT_MSEC := 30000
const PROGRESS_INTERVAL_MSEC := 250 # throttle des RPC de progression
const DONE_VISIBLE_MSEC := 8000
const MAX_LIST_LINES := 12
const DROP_REACH := 8.0
const AK_TAG_PREFIX := "cr_" # préfixe des tags de lignes authorized_keys
const KEY_STALE_MSEC := 15 * 60 * 1000 # balayage des clés oubliées

var player: CharacterBody3D = null
var lan: Node = null
var compositor: WlrCompositor = null

# Clé ssh locale dédiée au jeu (générée à la demande via ssh-keygen).
var _key_pub := "" # ligne publique complète "ssh-ed25519 AAAA… commentaire"
var _key_path := ""

# Contacts LAN : peer_id → {"ip", "pubkey", "fp"} (mesh pair-à-pair,
# cf. _announce_contact).
var _contacts := {}
var _announced_to := {}
var _replied_to := {}

# Côté expéditeur.
var _next_offer_id := 1
var _pending_offers := {} # offer_id -> offre en attente de réponse

# Côté destinataire.
var _incoming := {} # offre reçue, modal ouverte (une seule à la fois)
var _incoming_msec := 0

# Un seul transfert actif à la fois (sens confondus) : simplifie l'UI et
# évite de saturer le lien. Les nouvelles offres sont refusées tant qu'un
# transfert tourne.
var _active_transfer := {} # offer_id -> {role: "send"/"recv", ...}
var _busy_until_msec := 0 # anti-spam offres refusées

# Survol pendant drag.
var _hover_peer := 0

# UI (construite dans setup).
var _hud_label: Label = null
var _modal_root: Control = null
var _modal_title: Label = null
var _modal_files: Label = null
var _modal_fp: Label = null
var _user_edit: LineEdit = null
var _prog_panel: PanelContainer = null
var _prog_title: Label = null
var _prog_bar: ProgressBar = null
var _prog_detail: Label = null
var _prog_done_msec := 0 # panneau terminal → masquage auto après délai
var _prog_hide_at_msec := 0 # flashs courts (messages éphémères)


func setup(p_player: CharacterBody3D, p_lan: Node, p_compositor: WlrCompositor) -> void:
	player = p_player
	lan = p_lan
	compositor = p_compositor
	_build_ui()
	if lan != null and lan.has_signal("players_changed"):
		lan.players_changed.connect(_on_roster_changed)
	# Filet de sécurité : lignes authorized_keys oubliées d'une session
	# précédente (crash, déconnexion pendant un transfert…).
	_sweep_stale_keys()


# ── Clé ssh locale ───────────────────────────────────────────────────────────

## Génère (une seule fois) la paire de clés ed25519 dédiée au jeu.
## ssh-keygen pose les permissions 600 lui-même ; on n'utilise jamais la clé
## pour autre chose que ce partage.
func ensure_local_keypair() -> bool:
	if not _key_pub.is_empty():
		return true
	var dir := OS.get_user_data_dir().path_join("ssh")
	var path := dir.path_join("cyberrealm_ed25519")
	var pub_path := path + ".pub"
	if not FileAccess.file_exists(pub_path):
		DirAccess.make_dir_recursive_absolute(dir)
		if OS.execute("ssh-keygen", ["-q", "-t", "ed25519", "-N", "",
				"-C", "cyberrealm-file-share", "-f", path]) != 0:
			return false
	var f := FileAccess.open(pub_path, FileAccess.READ)
	if f == null:
		return false
	var line := f.get_as_text().strip_edges()
	f.close()
	if line.is_empty() or line.count(" ") < 2:
		return false
	_key_pub = line
	_key_path = path
	return true


## Empreinte SHA256 du corps base64 d'une ligne de clé publique ssh
## ("ssh-ed25519 AAAA… commentaire" → "SHA256:<base64 sans padding>"),
## format identique à `ssh-keygen -lf`.
static func key_fingerprint(pub_line: String) -> String:
	var parts := pub_line.strip_edges().split(" ", false)
	if parts.size() < 2:
		return ""
	var raw := Marshalls.base64_to_raw(parts[1])
	if raw.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(raw)
	return "SHA256:" + Marshalls.raw_to_base64(ctx.finish()).trim_suffix("=")


# ── authorized_keys du destinataire ──────────────────────────────────────────

## Ligne inscrite pour un transfert : exécution réduite au strict nécessaire
## (pas de forwarding, pas de tty — rsync n'en a pas besoin) + tag de purge.
## `tag` inclut déjà le préfixe (ex. "cr_172451").
static func ak_line(pub_line: String, tag: String) -> String:
	const OPTS := "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty"
	return "%s %s #%s" % [OPTS, pub_line.strip_edges(), tag]


static func ak_file() -> String:
	var home := OS.get_environment("HOME")
	return home.path_join(".ssh").path_join("authorized_keys")


## Extrait le tag cyberrealm d'une ligne authorized_keys ("" si autre chose).
static func tag_of(line: String) -> String:
	if line.begins_with("#"):
		return ""
	var idx := line.rfind("#")
	if idx < 0:
		return ""
	var t := line.substr(idx + 1).strip_edges()
	return t if t.begins_with(AK_TAG_PREFIX) else ""


## Installe la ligne du transfert (réécriture complète : une seule ligne
## cyberrealm active à la fois, les lignes étrangères sont préservées).
## Crée ~/.ssh (700) et le fichier (600) si absents. Renvoie le tag posé,
## "" si échec.
func install_peer_key(pub_line: String) -> String:
	if pub_line.strip_edges().is_empty():
		return ""
	var tag := "%s%d" % [AK_TAG_PREFIX, Time.get_ticks_msec()]
	var ssh_dir := OS.get_environment("HOME").path_join(".ssh")
	DirAccess.make_dir_recursive_absolute(ssh_dir)
	OS.execute("chmod", ["700", ssh_dir])
	var path := ak_file()
	var kept: Array[String] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		for line in f.get_as_text().split("\n"):
			if tag_of(line).is_empty(): # retire toute ligne cyberrealm antérieure
				kept.append(line)
		f.close()
	while not kept.is_empty() and kept[kept.size() - 1].strip_edges().is_empty():
		kept.pop_back()
	kept.append(ak_line(pub_line, tag))
	var g := FileAccess.open(path, FileAccess.WRITE)
	if g == null:
		return ""
	g.store_string("\n".join(kept) + "\n")
	g.flush()
	OS.execute("chmod", ["600", path])
	return tag


## Retire toutes les lignes portant ce tag. Renvoie true si le fichier a
## été modifié.
func remove_peer_key(tag: String) -> bool:
	if tag.is_empty():
		return false
	var path := ak_file()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var kept: Array[String] = []
	var changed := false
	for line in f.get_as_text().split("\n"):
		if tag_of(line) == tag:
			changed = true
			continue
		kept.append(line)
	f.close()
	if not changed:
		return false
	while not kept.is_empty() and kept[kept.size() - 1].strip_edges().is_empty():
		kept.pop_back()
	var g := FileAccess.open(path, FileAccess.WRITE)
	if g == null:
		return false
	g.store_string("\n".join(kept) + ("\n" if not kept.is_empty() else ""))
	g.flush()
	return true


## Supprime les lignes de transferts trop vieux (orphelins d'une session
## morte). Appelé au démarrage, avant chaque acceptation et en fin de session.
func _sweep_stale_keys() -> void:
	var path := ak_file()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var now := Time.get_ticks_msec()
	var removed_any := false
	for line in f.get_as_text().split("\n"):
		var tag := tag_of(line)
		if tag.is_empty():
			continue
		var born := int(tag.trim_prefix(AK_TAG_PREFIX))
		if born <= 0 or now - born > KEY_STALE_MSEC:
			removed_any = remove_peer_key(tag) or removed_any
	f.close()
	if removed_any:
		push_warning("FileShare: lignes authorized_keys expirées nettoyées")


# ── Survol / cible du drop ────────────────────────────────────────────────────

## Appelé chaque frame depuis wayland_room._process avec le rayon caméra
## (après win3d.process_raycast). Détecte l'avatar visé pendant un drag.
func update_drag(ray_origin: Vector3, ray_dir: Vector3) -> void:
	var dragging := compositor != null and compositor.is_drag_active()
	var target := 0
	if dragging and lan != null and lan.is_session_active():
		target = _resolve_avatar_peer(ray_origin, ray_dir)
	_hover_peer = target
	if _hud_label != null:
		_hud_label.visible = target != 0
		if target != 0:
			_hud_label.text = "Lâchez pour envoyer à %s" % _peer_name(target)


func _resolve_avatar_peer(ray_origin: Vector3, ray_dir: Vector3) -> int:
	if player == null or not is_instance_valid(player):
		return 0
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin, ray_origin + ray_dir * DROP_REACH)
	query.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not hit.has("collider"):
		return 0
	var container: Node3D = lan.get_players_container()
	if container == null or not is_instance_valid(container):
		return 0
	# Remontée hiérarchique : l'avatar est un enfant direct du conteneur
	# « Players », nommé str(peer_id).
	var n: Node = hit["collider"]
	for _i in 8:
		if n == null or not is_instance_valid(n):
			return 0
		if n.get_parent() == container:
			var pid := int(n.name)
			if pid == multiplayer.get_unique_id():
				return 0 # son propre avatar n'est pas une cible
			if _contacts.has(pid):
				return pid
			return 0 # pas de contact pour ce pair → inenvoyable
		n = n.get_parent()
	return 0


func _peer_name(pid: int) -> String:
	for e in lan.get_players_roster():
		if int(e.get("id", 0)) == pid:
			return String(e.get("name", str(pid)))
	return str(pid)


# ── Drop reçu du compositeur ─────────────────────────────────────────────────

## Connecté à WlrCompositor.file_drop_received : fichiers lâchés sur le monde
## 3D. S'il y a un avatar sous le curseur → offre de transfert.
func on_files_dropped(paths: PackedStringArray) -> void:
	var files := PackedStringArray()
	var total := 0
	for p in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			files.append(p)
			total += int(f.get_len())
	if files.is_empty():
		return
	if lan == null or not lan.is_session_active() or _hover_peer == 0 \
			or not ensure_local_keypair():
		_flash_status("Drop ignoré : aucun joueur visé ou session inactive")
		return
	if not _can_start_transfer():
		_flash_status("Transfert impossible : déjà occupé")
		return
	var oid := _next_offer_id
	_next_offer_id += 1
	var names := PackedStringArray()
	for p in files:
		names.append(p.get_file())
	_pending_offers[oid] = {
		"peer": _hover_peer, "files": files, "names": names,
		"total": total, "msec": Time.get_ticks_msec(),
	}
	_show_progress("Offre vers %s — en attente…" % _peer_name(_hover_peer), -1, "")
	_offer_files.rpc_id(_hover_peer, oid, names, total)


# ── Contacts (mesh clé publique + IP) ────────────────────────────────────────

func _on_roster_changed(roster: Array) -> void:
	if roster.is_empty():
		_contacts.clear()
		_announced_to.clear()
		_replied_to.clear()
		_sweep_stale_keys()
		return
	var me := multiplayer.get_unique_id()
	var present := {}
	for e in roster:
		var pid := int(e.get("id", 0))
		present[pid] = true
		if pid == me or _contacts.has(pid) or _announced_to.has(pid):
			continue
		_announced_to[pid] = true
		_announce_contact.rpc_id(pid, _local_ip(), _key_pub, key_fingerprint(_key_pub))
	# Pairs partis : purger contacts (un retour futur re-annoncera).
	for pid in _contacts.keys():
		if not present.has(pid):
			_contacts.erase(pid)
	for pid in _announced_to.keys():
		if not present.has(int(pid)):
			_announced_to.erase(pid)
			_replied_to.erase(pid)


@rpc("any_peer", "call_remote", "reliable", CHANNEL)
func _announce_contact(ip: String, pubkey: String, fingerprint: String) -> void:
	_apply_contact(multiplayer.get_remote_sender_id(), ip, pubkey, fingerprint)


func _apply_contact(sender: int, ip: String, pubkey: String, fingerprint: String) -> void:
	if sender == 0 or sender == multiplayer.get_unique_id() or ip.is_empty():
		return
	_contacts[sender] = {"ip": ip, "pubkey": pubkey, "fp": fingerprint}
	# Réponse une seule fois par session : complète le maillage sans boucle.
	if not _replied_to.has(sender):
		_replied_to[sender] = true
		ensure_local_keypair()
		_announce_contact.rpc_id(sender, _local_ip(), _key_pub, key_fingerprint(_key_pub))


func _local_ip() -> String:
	if lan != null and lan.has_method("_local_ip"):
		return String(lan.call("_local_ip"))
	return ""


# ── Protocole d'offre ────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", CHANNEL)
func _offer_files(offer_id: int, names: PackedStringArray, total_bytes: int) -> void:
	_apply_offer(multiplayer.get_remote_sender_id(), offer_id, names, total_bytes)


func _apply_offer(sender: int, offer_id: int, names: PackedStringArray, total_bytes: int) -> void:
	if sender == 0 or sender == multiplayer.get_unique_id():
		return
	if lan == null or not lan.is_session_active() or not _contacts.has(sender):
		return
	_sweep_stale_keys()
	# Déjà un prompt ouvert / transfert en cours / cooldown : refus immédiat.
	if not _incoming.is_empty() or not _active_transfer.is_empty() \
			or Time.get_ticks_msec() < _busy_until_msec:
		_offer_answer.rpc_id(sender, offer_id, false, "")
		return
	var contact: Dictionary = _contacts[sender]
	if String(contact.get("pubkey", "")).is_empty():
		# Pair sans clé annoncée (builds hétérogènes) : refus propre.
		_offer_answer.rpc_id(sender, offer_id, false, "")
		return
	_incoming = {
		"id": offer_id, "peer": sender, "names": names.duplicate(), "total": total_bytes,
	}
	_incoming_msec = Time.get_ticks_msec()
	_open_modal()


@rpc("any_peer", "call_remote", "reliable", CHANNEL)
func _offer_answer(offer_id: int, accepted: bool, username: String) -> void:
	_apply_answer(multiplayer.get_remote_sender_id(), offer_id, accepted, username)


## Côté expéditeur : réponse du destinataire. `username` est le login ssh chez
## lui ; la clé publique locale a déjà été installée dans son authorized_keys.
func _apply_answer(sender: int, offer_id: int, accepted: bool, username: String) -> void:
	if not _pending_offers.has(offer_id):
		return
	var offer: Dictionary = _pending_offers[offer_id]
	if int(offer["peer"]) != sender:
		return # réponse usurpée : ignorer silencieusement
	_pending_offers.erase(offer_id)
	if not accepted:
		_show_progress("%s a refusé l'envoi" % _peer_name(sender), 100, "Refusé")
		_prog_done_msec = Time.get_ticks_msec()
		_busy_until_msec = Time.get_ticks_msec() + 1500
		return
	username = _clean_credential(username)
	if username.is_empty():
		_show_progress("Réponse invalide — envoi annulé", 100, "Erreur")
		_prog_done_msec = Time.get_ticks_msec()
		_busy_until_msec = Time.get_ticks_msec() + 1500
		_transfer_done.rpc_id(sender, offer_id, false, "Identifiants invalides côté expéditeur")
		return
	_start_rsync(offer_id, offer, sender, username)


## Caractères de contrôle interdits (le login part en argv d'un process local).
static func _clean_credential(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		out += ch if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127 else ""
	return out


# ── Transfert côté expéditeur ────────────────────────────────────────────────

## rsync-over-ssh authentifié par NOTRE clé privée (le destinataire a installé
## notre clé publique). BatchMode : jamais de prompt interactif suspendu ;
## IdentitiesOnly : uniquement la clé du jeu ; known_hosts isolé dans le
## dossier utilisateur (TOFU : première connexion = confiance initiale).
## Le shell ne voit JAMAIS les données : tout passe en argv après le script
## (exec "$@"), seuls les chemins temporaires locaux sont interpolés.
static func build_rsync_argv(files: PackedStringArray, username: String,
		key_path: String, host: String, prog_path: String, err_path: String,
		known_hosts_path: String) -> PackedStringArray:
	var script := 'exec "$@" >"%s" 2>"%s"' % [prog_path, err_path]
	var ssh_opts := "ssh -i \"%s\" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\"%s\" -o ConnectTimeout=10"
	ssh_opts = ssh_opts % [key_path, known_hosts_path]
	var argv := PackedStringArray(["sh", "-c", script, "sh",
		"rsync", "-az", "--info=progress2", "--partial", "--timeout=30",
		"-e", ssh_opts,
		"--"])
	for f in files:
		argv.append(f)
	argv.append("%s@%s:%s/" % [username, host, DEST_DIR_NAME])
	return argv


static func missing_binaries() -> String:
	for b in ["rsync", "ssh", "ssh-keygen"]:
		if OS.execute("sh", ["-c", "command -v " + b]) != 0:
			return b
	return ""


func _start_rsync(offer_id: int, offer: Dictionary, peer: int, username: String) -> void:
	var missing := missing_binaries()
	if not missing.is_empty():
		_show_progress("Outil manquant : %s (voir README)" % missing, 100, "Erreur")
		_prog_done_msec = Time.get_ticks_msec()
		_transfer_done.rpc_id(peer, offer_id, false,
			"Expéditeur : outil manquant (%s)" % missing)
		return
	var tmp_dir := OS.get_user_data_dir().path_join("file_share_%d" % offer_id)
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var prog_path := tmp_dir.path_join("progress")
	var err_path := tmp_dir.path_join("stderr")
	var kh_path := OS.get_user_data_dir().path_join("known_hosts")
	var argv := build_rsync_argv(offer["files"], username, _key_path,
		String(_contacts[peer]["ip"]), prog_path, err_path, kh_path)
	var pid := OS.create_process(argv[0], argv.slice(1))
	if pid <= 0:
		_show_progress("Impossible de lancer rsync", 100, "Erreur")
		_prog_done_msec = Time.get_ticks_msec()
		_transfer_done.rpc_id(peer, offer_id, false, "rsync n'a pas pu démarrer")
		return
	_active_transfer = {
		"role": "send", "pid": pid, "total": int(offer["total"]),
		"last_pct": -1, "last_emit_msec": 0, "prog_path": prog_path,
		"err_path": err_path, "tmp_dir": tmp_dir,
		"peer": peer, "id": offer_id, "tag": "",
	}
	_show_progress("Envoi vers %s…" % _peer_name(peer), 0, "")


## Lecture du fichier de progression (mises à jour \r-séparées de
## --info=progress2). Renvoie le dernier pourcentage trouvé.
static func parse_progress(data: String) -> int:
	var pct := -1
	var idx := data.rfind("%")
	while idx > 0:
		var i := idx - 1
		var digits := ""
		while i >= 0 and data[i] >= "0" and data[i] <= "9":
			digits = data[i] + digits
			i -= 1
		if not digits.is_empty():
			pct = clampi(int(digits), 0, 100)
			break
		idx = data.rfind("%", idx - 1)
	return pct


func _poll_send() -> void:
	var t := _active_transfer
	if t.is_empty() or String(t["role"]) != "send":
		return
	var now := Time.get_ticks_msec()
	if not OS.is_process_running(int(t["pid"])):
		var code := OS.get_process_exit_code(int(t["pid"]))
		var err_tail := _read_tail(String(t["err_path"]))
		if code == 0:
			_finish_send(true, "")
		else:
			_finish_send(false, "rsync a échoué (code %d)%s" % [code, _err_hint(err_tail)])
		return
	var pct := parse_progress(_read_tail(String(t["prog_path"])))
	if pct < 0 or pct == int(t["last_pct"]) or now - int(t["last_emit_msec"]) < PROGRESS_INTERVAL_MSEC:
		return
	t["last_pct"] = pct
	t["last_emit_msec"] = now
	_show_progress("Envoi vers %s…" % _peer_name(int(t["peer"])), pct, "")


func _finish_send(ok: bool, message: String) -> void:
	var t := _active_transfer
	_active_transfer = {}
	var peer := int(t["peer"])
	var oid := int(t["id"])
	var tag := String(t["tag"])
	var dir_path := String(t["tmp_dir"])
	DirAccess.remove_absolute(String(t["prog_path"]))
	DirAccess.remove_absolute(String(t["err_path"]))
	DirAccess.remove_absolute(dir_path)
	if ok:
		_show_progress("Envoyé à %s ✔" % _peer_name(peer), 100, "Terminé")
	else:
		_show_progress("Échec de l'envoi vers %s" % _peer_name(peer), 100, message)
	_prog_done_msec = Time.get_ticks_msec()
	_busy_until_msec = Time.get_ticks_msec() + 1500
	_transfer_done.rpc_id(peer, oid, ok, message)


static func _read_tail(path: String, max_bytes := 4096) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var len_ := int(f.get_length())
	if len_ > max_bytes:
		f.seek(len_ - max_bytes)
	return f.get_as_text()


## Message d'erreur court à partir de la fin de stderr rsync/ssh.
static func _err_hint(err_tail: String) -> String:
	if err_tail.contains("Permission denied"):
		return ", clé refusée par le serveur ssh"
	if err_tail.contains("Connection refused"):
		return ", serveur ssh injoignable"
	if err_tail.contains("Host key verification failed"):
		return ", clé d'hôte ssh modifiée"
	return ""


# ── Réception ────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "unreliable", CHANNEL)
func _transfer_progress(offer_id: int, pct: int) -> void:
	_apply_progress(multiplayer.get_remote_sender_id(), offer_id, pct)


func _apply_progress(sender: int, offer_id: int, pct: int) -> void:
	var t := _active_transfer
	if t.is_empty() or String(t["role"]) != "recv":
		return
	if int(t["peer"]) != sender or int(t["id"]) != offer_id:
		return
	_show_progress("Réception de %s…" % _peer_name(sender), pct, "")


@rpc("any_peer", "call_remote", "reliable", CHANNEL)
func _transfer_done(offer_id: int, ok: bool, message: String) -> void:
	_apply_done(multiplayer.get_remote_sender_id(), offer_id, ok, message)


## Fin de transfert côté destinataire : retirer immédiatement la ligne
## authorized_keys posée à l'acceptation (le tag est local : jamais transmis).
func _apply_done(sender: int, offer_id: int, ok: bool, message: String) -> void:
	var t := _active_transfer
	if t.is_empty() or String(t["role"]) != "recv":
		return
	if int(t["peer"]) != sender or int(t["id"]) != offer_id:
		return
	remove_peer_key(String(t["tag"]))
	_active_transfer = {}
	_busy_until_msec = Time.get_ticks_msec() + 1500
	if ok:
		_show_progress("Reçu de %s ✔ → ~/%s" % [_peer_name(sender), DEST_DIR_NAME], 100, "Terminé")
	else:
		_show_progress("Échec de la réception de %s" % _peer_name(sender), 100, message)
	_prog_done_msec = Time.get_ticks_msec()


## Validation par le destinataire : installer la clé publique de l'expéditeur
## (ligne restreinte + tag) puis répondre. Son mot de passe n'est JAMAIS
## demandé ni transmis — c'est sa clé publique qui autorise la connexion.
func _accept_offer() -> void:
	if _incoming.is_empty():
		return
	var offer: Dictionary = _incoming
	var username := _clean_credential(_user_edit.text)
	if username.is_empty():
		_flash_status("Nom d'utilisateur requis")
		_incoming_msec = Time.get_ticks_msec()
		return
	var contact: Dictionary = _contacts[int(offer["peer"])]
	var tag := install_peer_key(String(contact["pubkey"]))
	if tag.is_empty():
		_flash_status("Impossible d'écrire ~/.ssh/authorized_keys")
		_incoming_msec = Time.get_ticks_msec()
		return
	_incoming = {}
	var oid := int(offer["id"])
	var home := OS.get_environment("HOME")
	if not home.is_empty():
		DirAccess.make_dir_recursive_absolute(home.path_join(DEST_DIR_NAME))
	_close_modal()
	_active_transfer = {"role": "recv", "peer": int(offer["peer"]), "id": oid, "tag": tag}
	_show_progress("Réception de %s…" % _peer_name(int(offer["peer"])), 0, "")
	_offer_answer.rpc_id(int(offer["peer"]), oid, true, username)


func _refuse_offer(notify := true) -> void:
	if _incoming.is_empty():
		return
	var offer: Dictionary = _incoming
	_incoming = {}
	_close_modal()
	_busy_until_msec = Time.get_ticks_msec() + 1500
	if notify:
		_offer_answer.rpc_id(int(offer["peer"]), int(offer["id"]), false, "")


# ── Boucle & timeouts ────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	# Offres expirées côté expéditeur.
	for oid in _pending_offers.keys():
		if now - int(_pending_offers[oid]["msec"]) > OFFER_TIMEOUT_MSEC:
			var offer: Dictionary = _pending_offers[oid]
			_pending_offers.erase(oid)
			_show_progress("%s n'a pas répondu" % _peer_name(int(offer["peer"])), 100, "Expiré")
			_prog_done_msec = now
	# Offre entrante non traitée → refus automatique.
	if not _incoming.is_empty() and now - _incoming_msec > OFFER_TIMEOUT_MSEC:
		_refuse_offer()
	_poll_send()
	# Masquage auto du panneau : terminal après délai, flashs plus brefs.
	if _prog_panel != null and _prog_panel.visible:
		var deadline := 0
		if _prog_hide_at_msec > 0:
			deadline = _prog_hide_at_msec
		elif _prog_done_msec > 0:
			deadline = _prog_done_msec + DONE_VISIBLE_MSEC
		if deadline > 0 and now >= deadline:
			_prog_panel.visible = false
			_prog_done_msec = 0
			_prog_hide_at_msec = 0


func _can_start_transfer() -> bool:
	return _pending_offers.is_empty() and _incoming.is_empty() and _active_transfer.is_empty()


func is_modal_open() -> bool:
	return not _incoming.is_empty()


func _flash_status(text: String) -> void:
	_show_progress(text, -1, "")
	_prog_hide_at_msec = Time.get_ticks_msec() + 2500 # visible brièvement


func _unhandled_input(event: InputEvent) -> void:
	if _incoming.is_empty():
		return
	if event.is_action_pressed("ui_cancel"):
		_refuse_offer()
		get_viewport().set_input_as_handled()


# ── UI ───────────────────────────────────────────────────────────────────────

const MODAL_LAYER := 95


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = MODAL_LAYER
	add_child(layer)

	_hud_label = Label.new()
	_hud_label.anchor_left = 0.0
	_hud_label.anchor_right = 1.0
	_hud_label.anchor_top = 0.08
	_hud_label.anchor_bottom = 0.08
	_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_label.visible = false
	layer.add_child(_hud_label)

	_modal_root = Control.new()
	_modal_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_root.visible = false
	layer.add_child(_modal_root)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.set(m, 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_modal_title = Label.new()
	_modal_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_modal_title)

	_modal_files = Label.new()
	_modal_files.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_modal_files.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_modal_files)

	_modal_fp = Label.new()
	_modal_fp.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_modal_fp.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_modal_fp)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	vbox.add_child(grid)

	grid.add_child(_make_form_label("Votre utilisateur (SSH)"))
	_user_edit = LineEdit.new()
	_user_edit.custom_minimum_size = Vector2(220, 0)
	_user_edit.text = OS.get_environment("USER")
	_user_edit.text_submitted.connect(func(_t: String) -> void: _accept_offer())
	grid.add_child(_user_edit)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)

	var refuse := Button.new()
	refuse.text = "Refuser"
	refuse.pressed.connect(func() -> void: _refuse_offer())
	buttons.add_child(refuse)

	var accept := Button.new()
	accept.text = "Accepter"
	accept.pressed.connect(func() -> void: _accept_offer())
	buttons.add_child(accept)

	# Panneau de progression non-modal (bas de l'écran), partagé par les deux
	# rôles (expéditeur / destinataire).
	_prog_panel = PanelContainer.new()
	_prog_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prog_panel.visible = false
	_prog_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_prog_panel)
	var pv := VBoxContainer.new()
	_prog_panel.add_child(pv)
	_prog_title = Label.new()
	pv.add_child(_prog_title)
	_prog_bar = ProgressBar.new()
	_prog_bar.custom_minimum_size = Vector2(320, 14)
	_prog_bar.show_percentage = false
	pv.add_child(_prog_bar)
	_prog_detail = Label.new()
	_prog_detail.add_theme_font_size_override("font_size", 12)
	pv.add_child(_prog_detail)


func _make_form_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _open_modal() -> void:
	var offer: Dictionary = _incoming
	_modal_title.text = "%s veut vous envoyer %d fichier(s) (%s)\nAutoriser sa clé SSH temporaire ?" % [
		_peer_name(int(offer["peer"])), offer["names"].size(), human_size(int(offer["total"])),
	]
	var lines: Array[String] = []
	for n in offer["names"]:
		lines.append(str(n))
	_modal_files.text = _truncate_list(lines)
	var fp := String(_contacts[int(offer["peer"])]["fp"])
	_modal_fp.text = ("Clé de l'expéditeur : %s…" % fp.substr(0, 24)) if not fp.is_empty() else ""
	_modal_fp.visible = not _modal_fp.text.is_empty()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_modal_root.visible = true
	_user_edit.caret_column = _user_edit.text.length()
	_user_edit.grab_focus()


func _close_modal() -> void:
	_modal_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


static func _truncate_list(names: Array[String]) -> String:
	var shown := names.slice(0, mini(names.size(), MAX_LIST_LINES))
	var text := "• " + "\n• ".join(shown)
	if names.size() > MAX_LIST_LINES:
		text += "\n… et %d autre(s)" % (names.size() - MAX_LIST_LINES)
	return text


static func human_size(nbytes: int) -> String:
	var units := ["o", "Kio", "Mio", "Gio"]
	var v := float(maxi(nbytes, 0))
	var u := 0
	while v >= 1024.0 and u < units.size() - 1:
		v /= 1024.0
		u += 1
	if u > 0:
		return "%.1f %s" % [v, units[u]]
	return "%d %s" % [int(v), units[u]]


func _show_progress(title: String, pct: int, detail: String) -> void:
	_prog_title.text = title
	if pct >= 0:
		_prog_bar.visible = true
		_prog_bar.value = pct
	else:
		_prog_bar.visible = false
	_prog_detail.text = detail
	_prog_detail.visible = not detail.is_empty()
	_prog_panel.reset_size()
	# Centré horizontalement, au-dessus du bas de l'écran.
	var vp := get_viewport().get_visible_rect().size
	_prog_panel.position = Vector2((vp.x - _prog_panel.size.x) / 2.0,
		vp.y - _prog_panel.size.y - 64.0)
	_prog_panel.visible = true
