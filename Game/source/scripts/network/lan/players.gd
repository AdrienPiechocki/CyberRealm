extends Node
## Joueurs : roster, infos (nom/couleur), spawn/despawn des avatars, synchro des transforms,
## choix, bake et transfert des avatars.
##
## Module de LanManager (nœud enfant « Players »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

# LEVEL_CHUNK_SIZE / LEVEL_CHUNKS_PER_TICK restent utilisés par le transfert d'avatars.
const LEVEL_CHUNK_SIZE := 24000
const LEVEL_CHUNKS_PER_TICK := 24

const CUSTOM_AVATAR_PATH := "res://user/avatar.tscn"
const DEFAULT_AVATAR_PATH := "res://scenes/avatar.tscn"

var _avatar_scene: PackedScene = null
var _avatar_blobs: Dictionary = {} # peer_id -> PackedByteArray (scène binaire)
const NAME_MAX_LEN := 24
# Scènes avatar décodées à l'avance : peer_id -> PackedScene. Le coût du
# load() (parse + ressources embarquées des avatars lourds, plusieurs
# secondes) est payé dès l'arrivée du blob — idéalement pendant l'écran de
# chargement — et non au spawn, où il faisait surgir l'avatar en retard.
var _avatar_scene_cache: Dictionary = {}
var _pending_avatar_loads: Dictionary = {} # peer_id -> path
# Avatars déjà envoyés à chaque pair cette session : une inscription
# re-diffuse tous les spawns, il ne faut pas renvoyer le blob à chaque fois.
var _avatar_sent_to: Dictionary = {}
# Blob de l'avatar LOCAL baké puis compressé, une fois par session : le bake
# (clone de scène + textures) coûte des secondes et ne doit JAMAIS tourner
# dans un handler réseau — sinon l'hôte gèle et les broadcasts partent en retard.
var _avatar_send_cache: PackedByteArray = PackedByteArray()
# Taille DÉCOMPRIMÉE du blob ci-dessus (nécessaire au decompress côté pair).
var _avatar_send_cache_raw_size := 0
# Manifeste de scripts utilisateur de l'avatar local (voir UserScriptMirror /
# LevelBaker.prepare_user_scripts) : envoyé aux pairs juste avant les chunks.
var _avatar_send_scripts_cache: Dictionary = {}
# Avatar choisi dans le menu LAN (res://…/avatar.tscn). Vide = mode auto :
# user/avatar.tscn si présent, sinon l'avatar par défaut.
var _selected_avatar_path := ""
# peer_id -> {pos, rot} : position à préserver lors du respawn d'un avatar
# (changement de couleur/avatar en cours de partie).
var _respawn_positions: Dictionary = {}
# Un avatar n'est visible que pour ces pairs (sinon corps fantôme au spawn
# pendant que le joueur charge encore le niveau).
var _arrived_peers: Dictionary = {}

# Avatar chunked transfer (même pattern que les niveaux).
var _avatar_send_queue: Dictionary = {} # peer_id -> {bytes, total, sent}

# Réception d'avatars : UN SLOT PAR ÉMETTEUR — les blobs circulent en
# parallèle sur le canal 1 (maille complète), un slot unique serait
# réinitialisé à chaque entrelacement de transferts.
var _avatar_receive_slots: Dictionary = {} # from_id -> {data, size, total, next}

# Met à jour la couleur locale et la diffuse si une session est en cours.
func update_local_color(color: Color) -> void:
	lan.player_color = color
	if not LanManager.session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not lan._players.has(my_id) or lan._pending_join:
		return
	lan._players[my_id]["color"] = color
	if lan.is_host:
		_broadcast_player_info()
	else:
		_update_player_info.rpc_id(1, my_id, lan.player_name, color)
	update_local_avatar()

func update_local_name(pname: String) -> void:
	lan.player_name = pname
	if not LanManager.session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not lan._players.has(my_id) or lan._pending_join:
		return
	lan._players[my_id]["name"] = pname
	if lan.is_host:
		_broadcast_player_info()
	else:
		_update_player_info.rpc_id(1, my_id, pname, lan._players[my_id].get("color", lan.player_color))

func update_local_avatar() -> void:
	if not LanManager.session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not lan._players.has(my_id) or lan._pending_join:
		return
	# Invalider le cache d'envoi pour rebake l'avatar avec le nouveau choix.
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	# Envoyer le nouvel avatar à tous les pairs connectés.
	for id in multiplayer.get_peers():
		if id == my_id:
			continue
		_avatar_sent_to.erase(id)
		_send_avatar_to(id)

## Diffuse l'info (nom + couleur) de TOUS les joueurs à tous les pairs.
## Appelé par l'hôte quand un joueur change son nom/couleur.
func _broadcast_player_info() -> void:
	for id in lan._players:
		var entry: Dictionary = lan._players[id]
		_update_player_info.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))

@rpc("any_peer", "reliable", "call_local")
func _update_player_info(target_id: int, pname: String, color: Color) -> void:
	pname = pname.substr(0, NAME_MAX_LEN)
	# Si target_id == 0, c'est une diffusion de TOUS les joueurs (snapshot).
	if target_id == 0:
		return
	var from := multiplayer.get_remote_sender_id()
	# L'hôte peut broadcaster ses propres joueurs (from = 0 = local call).
	# Un client ne peut modifier que son propre profil.
	if from != 0 and from != target_id and not lan.is_host:
		return
	if not lan._players.has(target_id):
		lan._players[target_id] = {"name": pname, "color": color}
	else:
		lan._players[target_id]["name"] = pname
		lan._players[target_id]["color"] = color
	# Mettre à jour l'avatar distant si déjà instancié.
	if LanManager._remote_players.has(target_id):
		var av: Node = LanManager._remote_players[target_id]
		if is_instance_valid(av) and av.has_method("setup"):
			av.setup(target_id, pname, color)
			if lan._level_stable and av.has_method("start_prewarm"):
				av.start_prewarm()
			if _arrived_peers.has(target_id) and av.has_method("set_arrived"):
				av.set_arrived(true)
	# Relayer aux autres pairs si c'est l'hôte qui reçoit la MàJ d'un client.
	if lan.is_host and from != 0:
		_relay_player_info.rpc(target_id, pname, color)
	lan._emit_players()

@rpc("authority", "reliable", "call_remote")
func _relay_player_info(target_id: int, pname: String, color: Color) -> void:
	if lan.is_host:
		return
	lan._players[target_id] = {"name": pname, "color": color}
	if LanManager._remote_players.has(target_id):
		var av: Node = LanManager._remote_players[target_id]
		if is_instance_valid(av) and av.has_method("setup"):
			av.setup(target_id, pname, color)
			if lan._level_stable and av.has_method("start_prewarm"):
				av.start_prewarm()
			if _arrived_peers.has(target_id) and av.has_method("set_arrived"):
				av.set_arrived(true)
	lan._emit_players()

# ── Spawn / despawn des avatars ──────────────────────────────────────

# Le client annonce son nom au serveur ; le serveur re-broadcaste le spawn
# de tous les joueurs connus pour que tout le monde (late-join compris)
# converge vers le même état.
@rpc("any_peer", "reliable")
func _register_player(pname: String, color: Color) -> void:
	pname = pname.substr(0, NAME_MAX_LEN)
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or not lan.is_host:
		return
	# Rejeter les registrations de pairs non authentifiés (PIN vérifié).
	if lan.session._pending_auth.has(from):
		lan._lan_log("registration rejected from %d — not authenticated yet" % from)
		return
	lan._players[from] = {"name": pname, "color": color}
	lan._set_status("Player %d (%s) joined" % [from, pname])
	lan._lan_log("registration received from %d — broadcasting spawns (roster=%d)" % [from, lan._players.size()])
	# Snapshot du roster envoyé IMMÉDIATEMENT au nouvel arrivant : minuscule,
	# il part devant les floods de chunks. Sans lui, le client ne connaît le
	# roster qu'aux broadcasts (souvent après l'application du niveau) et le
	# différé « attente des avatars » n'a rien à attendre.
	var snapshot: Array = []
	for id in lan._players:
		snapshot.append([id, String(lan._players[id].get("name", "")), Color(lan._players[id].get("color", Color.WHITE))])
	_roster_snapshot.rpc_id(from, snapshot)
	for id in lan._players:
		var entry: Dictionary = lan._players[id]
		_spawn_player.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	lan._emit_players()
	# Contrôle parti depuis un tube vide (snapshot + broadcasts ci-dessus) →
	# SEULEMENT MAINTENANT démarrer les transferts lourds vers ce pair.
	_session_info.rpc_id(from, lan.dedicated)
	lan.level_transfer._send_level_to(from)
	_send_avatar_to(from)

# Le client apprend s'il joue sur un serveur dédié (autorité serveur sur la physique du décor).
@rpc("authority", "call_remote", "reliable", 1)
func _session_info(is_dedicated: bool) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	lan.session_dedicated = is_dedicated

# Roster complet envoyé par l'hôte dès la registration du client : peuplé
# AVANT tout transfert lourd, il permet au différé de niveau de connaître
# les avatars attendus.
@rpc("any_peer", "call_remote", "reliable")
func _roster_snapshot(entries: Array) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	for e in entries:
		if e.size() < 3:
			continue
		var pid := int(e[0])
		if pid == multiplayer.get_unique_id() or lan._players.has(pid):
			continue
		lan._players[pid] = {"name": String(e[1]), "color": e[2]}
	lan._lan_log("host roster snapshot — %s (blobs=%s)" % [str(lan._players.keys()), str(_avatar_blobs.keys())])
	lan._emit_players()
	# Si le niveau est déjà différé et que le snapshot révèle de nouveaux
	# joueurs, étendre l'attente (même deadline).
	if not lan.level_transfer._deferred_level.is_empty():
		var waiting: Array = lan.level_transfer._deferred_level["waiting"]
		for pid in lan._players:
			pid = int(pid)
			if pid == multiplayer.get_unique_id():
				continue
			if not _avatar_blobs.has(pid) and not waiting.has(pid):
				waiting.append(pid)
		waiting.sort()
		lan.level_transfer._deferred_level["waiting"] = waiting

# Chaque pair saute son propre peer_id (il a déjà son joueur local).
@rpc("any_peer", "reliable", "call_local")
func _spawn_player(peer_id: int, pname: String, color: Color) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return      # seul le serveur annonce des joueurs
	pname = pname.substr(0, NAME_MAX_LEN)
	if peer_id == multiplayer.get_unique_id() or lan.dedicated:
		return      # (serveur dédié : pas de rendu, le roster vient de _register_player)
	if LanManager._remote_players.has(peer_id):
		LanManager._remote_players[peer_id].setup(peer_id, pname, color)
		if lan._level_stable and LanManager._remote_players[peer_id].has_method("start_prewarm"):
			LanManager._remote_players[peer_id].start_prewarm()
		if _arrived_peers.has(peer_id) and LanManager._remote_players[peer_id].has_method("set_arrived"):
			LanManager._remote_players[peer_id].set_arrived(true)
		return
	# Le client découvre le roster via ce broadcast (_register_player ne
	# tourne que chez l'hôte) — nécessaire au différé de niveau comme à
	# l'affichage des joueurs.
	if not lan._players.has(peer_id):
		lan._players[peer_id] = {"name": pname, "color": color}
		lan._lan_log("roster += %d (n=%d, blobs=%s)" % [peer_id, lan._players.size(), str(_avatar_blobs.keys())])
	# Échange d'avatars en maille complète : si je n'ai pas encore envoyé le
	# mien à CE pair, je le lui envoie (une inscription re-diffuse tous les
	# spawns ; _send_avatar_to marque lui-même _avatar_sent_to, et le blob
	# est déjà baké/compressé en cache → envoi quasi gratuit).
	if LanManager.session_active and not _avatar_sent_to.has(peer_id):
		_send_avatar_to(peer_id)
	var scene := _avatar_scene
	# Utiliser l'avatar reçu du peer si disponible (scène décodée à l'arrivée
	# du blob → spawn instantané ; sinon décodage à la volée).
	if _avatar_scene_cache.has(peer_id):
		scene = _avatar_scene_cache[peer_id]
	elif _avatar_blobs.has(peer_id) and not _pending_avatar_loads.has(peer_id):
		var tmp := "user://avatar_peer_%d.scn" % peer_id
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_avatar_blobs[peer_id])
			f.close()
			var loaded: PackedScene = ResourceLoader.load(tmp, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
			if loaded != null and lan.online_restricted() and not LanManager.SessionModule.avatar_scene_safe(loaded):
				loaded = null       # avatar d'un autre joueur contenant du code : on garde l'avatar par défaut
			if loaded != null:
				scene = loaded
				_avatar_scene_cache[peer_id] = loaded
	var avatar := scene.instantiate()
	avatar.name = str(peer_id)
	avatar.setup(peer_id, pname, color)
	avatar.local_player = lan.local_player
	# Utiliser la position préservée (respawn après changement d'avatar/couleur)
	# sinon le spawn par défaut.
	if _respawn_positions.has(peer_id):
		var rp: Dictionary = _respawn_positions[peer_id]
		avatar.position = rp.get("pos", lan._spawn_position())
		avatar.rotation = rp.get("rot", lan._spawn_rotation())
		_respawn_positions.erase(peer_id)
	else:
		avatar.position = lan._spawn_position()
		avatar.rotation = lan._spawn_rotation()
	avatar.scale = lan._spawn_scale()
	# Invisible jusqu'à la première synchro de transform du pair : tant
	# qu'il charge le niveau (_pending_join) il n'en émet aucune, et on ne
	# veut pas d'un corps fantôme planté au spawn côté des autres joueurs.
	avatar.set_arrived(_arrived_peers.has(peer_id))
	_add_drop_target(avatar)
	lan._players_container.add_child(avatar)
	LanManager._remote_players[peer_id] = avatar
	if lan._level_stable:
		avatar.start_prewarm()
	lan._emit_players()


# ── Avatar personnel pour la vue libre ──────────────────────────────

## Instancie l'avatar LOCAL (celui diffusé en LAN : le modèle choisi dans le
## menu LAN quand il l'est, sinon user/avatar.tscn, sinon l'avatar par défaut ;
## nom et couleur du joueur) à la position/rotation du corps du joueur, pour
## qu'il soit visible depuis la caméra détachée — y compris en solo, où le
## joueur local ne voit jamais son propre corps d'habitude. Réalise le prewarm
## GPU (celui-ci anticipe le TDR) puis force _arrived pour rendre l'avatar
## visible. Retourne le nœud ou null (scène indisponible).
func spawn_freecam_avatar(player: Node3D) -> Node:
	# La sélection du menu LAN n'alimente PAS _avatar_scene (qui reste le
	# défaut/custom) : c'est _selected_avatar_path que _bake_avatar consomme.
	var scene := _avatar_scene
	if _selected_avatar_path != "" and ResourceLoader.exists(_selected_avatar_path):
		var sel := load(_selected_avatar_path) as PackedScene
		if sel != null:
			scene = sel
	if scene == null:
		return null
	var av := scene.instantiate()
	av.name = "FreeCamAvatar"
	av.scale = lan._spawn_scale()
	av.setup(0, lan.player_name, lan.player_color)
	av.follow_parent = true
	player.add_child(av)
	av._prev_pos = av.global_position
	av.start_prewarm()
	av.set_arrived(true)
	return av


## Les avatars distants sont purement visuels (Node3D, « pas de collision »
## cf. avatar.gd) : sans collider, aucun raycast ne peut les toucher — le
## ciblage du drag & drop de fichiers (et toute visée monde) les traverse.
## On ajoute un corps cinématique capsule au spawn. Layer 2 : le joueur
## local (mask 1) continue de traverser les autres joueurs, mais les
## raycasts (mask par défaut = tout) les voient.
func _add_drop_target(avatar: Node3D) -> void:
	if avatar == null or not is_instance_valid(avatar):
		return
	if avatar.has_node("DropTarget"):
		return
	var body := AnimatableBody3D.new()
	body.name = "DropTarget"
	# sync_to_physics=true fige le corps dans le serveur physique à sa
	# transform de création : le mouvement du parent n'est jamais propagé et
	# les raycasts touchent une position obsolète. false = le collider suit
	# l'avatar (aucune mécanique de plateforme n'est attendue ici).
	body.sync_to_physics = false
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.5, 0)
	body.add_child(cs)
	avatar.add_child(body)


# Le niveau vient d'être appliqué (client : fin de apply_host_level ; l'hôte
# est stable dès host_game). Quelques frames de latence pour laisser le
# nouveau niveau compiler ses variants de shaders (le 1er rendu du SubViewport
# du prewarm ne doit pas s'empiler dessus), puis tous les avatars distants
# sont préchauffés hors viewport principal. Appelé sans await par le jeu :
# le début est synchrone (_level_stable = true), la suite est différée.
func mark_level_stable() -> void:
	if lan._level_stable:
		return
	lan._level_stable = true
	# Le niveau (hôte ou local restauré) est appliqué : le client peut
	# maintenant entrer dans la session s'il chargait encore la map.
	lan.session._finalize_join()
	for _f in 5:
		await get_tree().process_frame
	for id in LanManager._remote_players:
		var av: Node = LanManager._remote_players[id]
		if is_instance_valid(av) and av.has_method("start_prewarm"):
			av.start_prewarm()

@rpc("any_peer", "reliable", "call_local")
func _remove_player(peer_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return      # seul le serveur retire des joueurs
	if LanManager._remote_players.has(peer_id):
		LanManager._remote_players[peer_id].queue_free()
		LanManager._remote_players.erase(peer_id)
	_arrived_peers.erase(peer_id)
	lan._players.erase(peer_id)
	_avatar_blobs.erase(peer_id)
	_avatar_scene_cache.erase(peer_id)
	lan.window_share._clear_remote_windows(peer_id)
	lan._emit_players()

func _queue_avatar_scene_load(path: String, peer_id: int) -> bool:
	if _pending_avatar_loads.has(peer_id) or not FileAccess.file_exists(path):
		return false
	_pending_avatar_loads[peer_id] = path
	ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_REPLACE)
	return true

# Décodage threadé terminé pour un peer : le spawn est décalé du handler RPC
# vers ici (le handler ne doit plus jamais bloquer le thread principal).
func _finish_avatar_decode(peer_id: int) -> void:
	if lan._players_container == null:
		return
	# Un spawn diffusé par l'hôte a pu créer l'avatar en version par défaut
	# pendant le décodage : remplacer par la scène décodée (même logique que
	# l'ancien chemin synchrone, qui recréait l'avatar à chaque blob).
	if LanManager._remote_players.has(peer_id):
		var old: Node = LanManager._remote_players[peer_id]
		if old is Node3D:
			_respawn_positions[peer_id] = {
				"pos": (old as Node3D).position, 
				"rot": (old as Node3D).rotation,
			}
		old.queue_free()
		LanManager._remote_players.erase(peer_id)
	var entry: Dictionary = lan._players.get(peer_id, {})
	_spawn_player(peer_id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	lan.level_transfer._maybe_flush_deferred_level()

# Pair du roster qui manque encore au niveau différé : pas de blob, OU blob
# présent mais décodage threadé toujours en cours — un décode en cours ne doit
# pas faire appliquer le niveau avant l'apparition de l'avatar concerné.
# Pur et statique pour être testable sans session (multiplayer absent).
static func _waiting_avatar_ids(players: Dictionary, blobs: Dictionary, pending_decodes: Dictionary, local_id: int) -> Array:
	var waiting: Array = []
	for id in players:
		id = int(id)
		if id == local_id:
			continue
		if not blobs.has(id) or pending_decodes.has(id):
			waiting.append(id)
	waiting.sort()
	return waiting

# ── Transfert des avatars custom ─────────────────────────────────────
# Chaque joueur envoie sa scène avatar (custom ou défaut) aux autres
# pour que chacun voie l'avatar réel de l'autre.

# ── Choix de l'avatar (menu LAN) ─────────────────────────────────────

## Liste tous les avatar.tscn présents dans le projet : scan récursif de
## res:// (DirAccess liste aussi le contenu du PCK exporté). Chaque entrée
## est {path, name} — name = nom du nœud racine de la scène. L'avatar par
## défaut est toujours listé en premier, les autres par ordre de chemin.
static func list_avatars() -> Array[Dictionary]:
	var found: Array = []
	_scan_avatars("res://", found)
	# Build exporté : les ressources texte sont converties en binaire et
	# remplacées par un fichier « *.remap » dans le PCK. Normalisation vers
	# le chemin logique, que ResourceLoader sait résoudre (remap inclus).
	for i in found.size():
		found[i] = String(found[i]).trim_suffix(".remap")
	found.erase(DEFAULT_AVATAR_PATH)
	found.sort()
	found.push_front(DEFAULT_AVATAR_PATH)
	# Dédoublonnage défensif (avatar.tscn ET avatar.tscn.remap vus ensemble).
	var uniq: Array = []
	for p in found:
		if not uniq.has(p):
			uniq.append(p)
	var out: Array[Dictionary] = []
	var seen := {}
	for p in uniq:
		var path := String(p)
		var nm := _avatar_display_name(path)
		if nm == "":
			continue
		# Homonymes (deux scènes dont la racine porte le même nom) :
		# suffixe numérique pour que le menu reste lisible.
		if seen.has(nm):
			seen[nm] = int(seen[nm]) + 1
			nm = "%s (%d)" % [nm, seen[nm]]
		else:
			seen[nm] = 1
		out.append({"path": path, "name": nm})
	return out

static func _scan_avatars(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not f.begins_with("."):
			var p := dir_path.path_join(f)
			if d.current_is_dir():
				_scan_avatars(p, out)
			# « .remap » : forme prise par les .tscn dans un PCK exporté.
			elif f == "avatar.tscn" or f == "avatar.tscn.remap":
				out.append(p)
		f = d.get_next()
	d.list_dir_end()

# Nom affiché : celui du nœud racine de la scène, lu depuis son SceneState
# (load() sans instantiate — les dépendances GLB restent en cache pour le
# bake ultérieur).
static func _avatar_display_name(path: String) -> String:
	var ps := load(path) as PackedScene
	if ps == null:
		return ""
	var st := ps.get_state()
	if st != null and st.get_node_count() > 0:
		return st.get_node_name(0)
	return ""

## Applique l'avatar choisi dans le menu LAN. "" (ou les chemins historiques)
## remet le mode auto. La scène est validée : elle doit charger et porter un
## script exposant setup() (celui d'avatar.gd), sinon on retombe en auto.
func set_selected_avatar(path: String) -> void:
	var old_path := _selected_avatar_path
	_selected_avatar_path = ""
	# La sélection effective change dans tous les cas (nouveau chemin ou
	# retour en auto) → le blob baké n'est plus valable.
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	if path.is_empty() or path == CUSTOM_AVATAR_PATH or path == DEFAULT_AVATAR_PATH:
		if LanManager.session_active and old_path != path:
			update_local_avatar()
		return
	if not ResourceLoader.exists(path):
		push_warning("LAN: selected avatar not found: %s" % path)
		return
	var ps := load(path) as PackedScene
	if ps == null:
		push_warning("LAN: avatar unreadable: %s" % path)
		return
	var inst := ps.instantiate()
	if inst == null or not inst.has_method("setup"):
		push_warning("LAN: scene without avatar script (missing setup): %s" % path)
		if inst != null:
			inst.free()
		return
	inst.free()
	_selected_avatar_path = path
	if LanManager.session_active and old_path != path:
		update_local_avatar()


func _bake_avatar() -> Dictionary:
	# Retour : {bytes, scripts} — bytes = blob binaire auto-suffisant,
	# scripts = manifeste UserScriptMirror (vide si aucun script utilisateur).
	# Scène à incarner : le choix du menu LAN s'il est valide, sinon le
	# comportement historique (custom user/avatar.tscn, sinon défaut).
	var src := _avatar_scene
	if _selected_avatar_path != "":
		var sel := load(_selected_avatar_path) as PackedScene
		if sel != null:
			src = sel
	if src == null:
		return {}
	# Deep-clone la scène pour embarquer les meshes/materials/textures
	# (sinon les references .fbx/.glb ne seront pas résolues côté peer).
	# Limiter les textures à 256 px pour éviter un crash Vulkan côté client.
	LevelBaker.max_texture_size = 256
	LevelBaker.keep_surface_format = true
	var root := src.instantiate() as Node3D
	if root == null:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	# Scripts utilisateur de l'avatar : collecte + remappage miroir AVANT le
	# clonage (_clone attache les copies miroir ; voir LevelBaker).
	var manifest := LevelBaker.prepare_user_scripts(root)
	var cache := {}
	var baked := LevelBaker._clone(root, null, cache) as Node3D
	if baked == null:
		root.queue_free()
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	baked.name = "Avatar"
	baked.owner = null
	LevelBaker._own_all(baked, baked)
	LevelBaker._relink(root, null, cache)
	LevelBaker._scrub_node(baked, "Avatar", cache, {})
	# Diagnostic : compter meshes / matériaux / textures dans le bake.
	var diag := {"meshes": 0, "mats": 0, "textures": 0, "verts": 0}
	_diag_count_res(baked, diag)
	push_warning("LAN: avatar bake diag — %s cache=%d" % [str(diag), cache.size()])
	var scene := PackedScene.new()
	if scene.pack(baked) != OK:
		baked.queue_free()
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	baked.queue_free()
	var tmp := "user://avatar_send.scn"
	if ResourceSaver.save(scene, tmp) != OK:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	var f := FileAccess.open(tmp, FileAccess.READ)
	if f == null:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	push_warning("LAN: avatar baked — %d KB (%d scripts user)" % [bytes.size() / 1024, manifest.size()])
	LevelBaker.max_texture_size = 0
	LevelBaker.keep_surface_format = false
	return {"bytes": bytes, "scripts": manifest}


func _diag_count_res(node: Node, diag: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			diag["meshes"] += 1
			if mi.mesh is ArrayMesh:
				var am := mi.mesh as ArrayMesh
				for s in am.get_surface_count():
					diag["verts"] += am.surface_get_array_len(s)
					var mat = am.surface_get_material(s)
					if mat != null:
						diag["mats"] += 1
						for p in mat.get_property_list():
							if mat.get(p["name"]) is Texture2D:
								diag["textures"] += 1
	if node is Label3D:
		pass
	for c in node.get_children():
		_diag_count_res(c, diag)

func _send_avatar_to(id: int) -> void:
	if lan.dedicated:
		return      # le serveur dédié n'a pas d'avatar
	# Bake + compression une seule fois par session (voir _avatar_send_cache).
	if _avatar_send_cache.is_empty():
		var t0 := Time.get_ticks_msec()
		var res: Dictionary = _bake_avatar()
		if res.is_empty():
			return
		var raw: PackedByteArray = res.get("bytes", PackedByteArray())
		if raw.is_empty():
			return
		_avatar_send_scripts_cache = res.get("scripts", {})
		var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
		if compressed.is_empty():
			compressed = raw
		_avatar_send_cache = compressed
		_avatar_send_cache_raw_size = raw.size()
		lan._lan_log("local avatar baked in %d ms — %d KB raw, %d KB compressed, %d scripts" % [
			Time.get_ticks_msec() - t0, raw.size() / 1024, compressed.size() / 1024,
			_avatar_send_scripts_cache.size()])
	var bytes := _avatar_send_cache
	# Marquage centralisé : tout envoi (connect, annonce, maille) compte.
	_avatar_sent_to[id] = true
	# Manifeste de scripts AVANT les chunks (même canal fiable → ordre garanti :
	# le miroir est peuplé quand le blob complet sera décodé).
	if not _avatar_send_scripts_cache.is_empty():
		_avatar_scripts.rpc_id(id, multiplayer.get_unique_id(), _avatar_send_scripts_cache)
	var total := ceili(float(bytes.size()) / float(LEVEL_CHUNK_SIZE))
	_avatar_send_queue[id] = {
		"bytes": bytes,
		"size": _avatar_send_cache_raw_size,
		"total": total,
		"sent": 0,
	}
	push_warning("LAN: sending avatar to peer %d — compressed %d KB, %d chunks" % [id, bytes.size() / 1024, total])

func _drain_avatar_send() -> void:
	if _avatar_send_queue.is_empty():
		return
	for id in _avatar_send_queue.keys():
		var entry: Dictionary = _avatar_send_queue[id]
		for i in LEVEL_CHUNKS_PER_TICK:
			var sent: int = int(entry["sent"])
			var total: int = int(entry["total"])
			if sent >= total:
				_avatar_send_queue.erase(id)
				break
			var bytes: PackedByteArray = entry["bytes"]
			var start := sent * LEVEL_CHUNK_SIZE
			var end := mini(start + LEVEL_CHUNK_SIZE, bytes.size())
			_avatar_recv_chunk.rpc_id(id, multiplayer.get_unique_id(), sent, total, entry["size"], bytes.slice(start, end))
			entry["sent"] = sent + 1

# Manifeste des scripts utilisateur d'un avatar (UserScriptMirror) : envoyé
# par chaque pair juste avant ses chunks, sur le même canal fiable (ordre
# garanti) — le miroir est peuplé quand le blob complet sera décodé.
@rpc("any_peer", "call_remote", "reliable", 1)
func _avatar_scripts(from_id: int, manifest: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != from_id:
		return
	if lan.dedicated or lan.online_restricted():
		return      # jamais de scripts venant d'un autre joueur sur un serveur / une session en ligne
	if manifest.is_empty() or not UserScriptMirror.valid(manifest):
		return
	var count := UserScriptMirror.install(manifest)
	lan._lan_log("avatar[%d] scripts — batch installed (%d files)" % [from_id, count])

# Canal ENet dédié (1) : l'avatar de l'hôte part juste après les chunks de
# niveau sur sa connexion — sans canal propre il resterait bloqué derrière
# tout le transfert (ordre fiable du canal 0).
@rpc("any_peer", "call_remote", "reliable", 1)
func _avatar_recv_chunk(from_id: int, index: int, total: int, uncompressed_size: int, chunk: PackedByteArray) -> void:
	if lan.dedicated or multiplayer.get_remote_sender_id() != from_id:
		return      # le serveur dédié ne décode aucun avatar ; l'émetteur annoncé doit être l'émetteur réel
	if total < 1 or uncompressed_size < 1 or chunk.is_empty() or index < 0 or index >= total:
		return
	# Nouveau transfert de cet émetteur : repart de zéro.
	var slot: Dictionary = _avatar_receive_slots.get(from_id, {})
	if slot.is_empty() or int(slot.get("total", -1)) != total or int(slot.get("size", -1)) != uncompressed_size:
		slot = {"data": PackedByteArray(), "size": uncompressed_size, "total": total, "next": 0}
		_avatar_receive_slots[from_id] = slot
		lan._lan_log("avatar[%d]: start (%d chunks)" % [from_id, total])
	if index < int(slot["next"]):
		return
	var data: PackedByteArray = slot["data"]
	data.append_array(chunk)
	slot["data"] = data
	slot["next"] = index + 1
	if index + 1 < total:
		return
	var raw: PackedByteArray = slot["data"]
	var recv_size: int = int(slot["size"])
	var recv_from: int = from_id
	_avatar_receive_slots.erase(from_id)
	var bytes := raw.decompress(recv_size, FileAccess.COMPRESSION_ZSTD)
	if bytes.is_empty() or bytes.size() != recv_size:
		push_warning("LAN: avatar decompress failed — received %d bytes, expected %d" % [bytes.size(), recv_size])
		return
	push_warning("LAN: avatar received from peer %d — %d KB" % [recv_from, bytes.size() / 1024])
	_avatar_blobs[recv_from] = bytes
	# Décodage threadé : le handler ne fait que mettre en file (le coût du
	# décodage est payé dans _poll_pending_scene_loads sans bloquer le thread
	# principal ni les ACK ENet). Invalider le cache précédent pour que la
	# nouvelle scène soit décodée (un avatar changé doit remplacer l'ancien).
	_avatar_scene_cache.erase(recv_from)
	if LanManager._remote_players.has(recv_from):
		var av: Node = LanManager._remote_players[recv_from]
		# Préserver la position pour le respawn : l'avatar va être détruit et
		# recréé, on ne veut pas le repositionner au spawn.
		if av is Node3D:
			_respawn_positions[recv_from] = {
				"pos": (av as Node3D).position,
				"rot": (av as Node3D).rotation,
			}
		av.queue_free()
		LanManager._remote_players.erase(recv_from)
	var tmp := "user://avatar_peer_%d.scn" % recv_from
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)
		f.close()
		_queue_avatar_scene_load(tmp, recv_from)

@rpc("any_peer", "reliable")
func _avatar_send_blob(from_id: int, blob: PackedByteArray) -> void:
	pass

# ── Sync des transformations ─────────────────────────────────────────

@rpc("any_peer", "unreliable")
func _sync_player_transform(pos: Vector3, yaw: float, pitch: float) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0:
		return
	# Avant le test d'avatar : le serveur dédié n'a pas d'avatars mais valide les distances (peer_within).
	lan.note_peer_position(from, pos)
	if not LanManager._remote_players.has(from):
		return
	_reveal_peer(from)
	LanManager._remote_players[from].apply_transform(pos, yaw, pitch)

## Première preuve de vie d'un pair. Il émet une synchro de transform à
## chaque frame physique dès qu'il est en session — et AUCUNE tant qu'il
## charge le niveau. Révéler ici = il apparaît quand il arrive vraiment.
func _reveal_peer(peer_id: int) -> void:
	if _arrived_peers.has(peer_id):
		return
	_arrived_peers[peer_id] = true
	var av: Node = LanManager._remote_players.get(peer_id)
	if av != null and is_instance_valid(av) and av.has_method("set_arrived"):
		av.set_arrived(true)
