extends Node
## Serveur dédié CyberRealm (headless) : héberge une session sans joueur local, p. ex. sur un Raspberry Pi.
##
## Il réutilise tel quel le protocole LAN (lan_manager) : PIN, DTLS, transfert du niveau, relais des joueurs. Il
## n'instancie ni compositeur Wayland ni joueur ni fenêtre — il sert un NIVEAU PRÉBAKÉ (blob) produit par le jeu :
##
##   1. Sur une machine de jeu :  godot --headless --path Game/source --script scripts/tools/export_level_blob.gd \\
##          -- [res://user/Levels/<Nom>/level.tscn] [level.crblob]
##   2. Sur le serveur :          godot --headless --path Game/source scenes/dedicated_server.tscn \\
##          -- --blob=level.crblob [--pin=1234] [--name=Serveur] [--max-players=8] [--no-dtls] [--no-voice]
##             [--state=fichier]  (état du monde, défaut : <blob>.state ; --state= vide : pas de persistance)
##   Online (Internet) : ... -- --online --tls-cert=fullchain.pem --tls-key=privkey.pem  (mot de passe >= 12 caractères,
##   de préférence via CYBERREALM_PASSWORD) — voir docs/dedicated-server.md.
##   Admin : variable d'environnement CYBERREALM_ADMIN_PASSWORD (ou --admin-password=…, visible dans `ps`).
##
## Les clients rejoignent par IP:PIN comme pour un hôte LAN. Arrêt : SIGINT/SIGTERM (Ctrl+C).

const LanScript := preload("res://scripts/network/lan_manager.gd")

var lan: Node = null

# ── Persistance du monde ────────────────────────────────────────────────
# L'état du décor (objets déplacés, cassés… : l'instantané de level_sync.gd) est écrit dans `state_path` dès qu'il
# change, au plus toutes les SAVE_INTERVAL secondes, et rechargé au démarrage AVANT l'ouverture du port. Godot
# headless meurt sans notification sur SIGTERM : un arrêt du service perd au plus les SAVE_INTERVAL dernières
# secondes. Le fichier porte l'empreinte du blob : un autre niveau (blob réexporté) l'invalide (renommé en .old).
# Un admin peut réinitialiser le monde (message « admin_reset_world ») : état effacé, joueurs prévenus, puis le
# processus quitte avec RESET_EXIT_CODE et systemd le relance à neuf (Restart=on-failure).
const SAVE_INTERVAL := 10.0
const STATE_VERSION := 1
const RESET_EXIT_CODE := 75
var state_path := ""
var _blob_sha := ""
var _last_state := PackedByteArray()
var _save_cd := SAVE_INTERVAL

func _ready() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var blob_path: String = args.get("blob", "")
	if blob_path == "":
		push_error("dedicated_server: --blob=<fichier> manquant (voir scripts/tools/export_level_blob.gd)")
		get_tree().quit(2)
		return
	var blob := _load_blob(blob_path)
	if blob.is_empty():
		get_tree().quit(3)
		return

	# LAN créé AVANT le niveau : ses scripts (interiors.gd…) le retrouvent pour savoir qu'ils tournent sur un serveur.
	lan = Node.new()
	lan.name = "LAN"
	lan.set_script(LanScript)
	add_child(lan)
	lan.dedicated = true
	# Mot de passe / PIN : de préférence par l'environnement (un argument est visible dans `ps`).
	lan.forced_pin = String(args.get("pin", OS.get_environment("CYBERREALM_PASSWORD")))
	lan.online = args.has("online")
	lan.tls_cert_path = String(args.get("tls-cert", ""))
	lan.tls_key_path = String(args.get("tls-key", ""))
	lan.max_players = int(args.get("max-players", 8))
	lan.encryption_enabled = not args.has("no-dtls")
	# Chat vocal : relayé par défaut (y compris en online) ; --no-voice coupe le relais.
	lan.voice.disabled = args.has("no-voice")
	# Mot de passe admin : de préférence par l'environnement (un argument de ligne de commande est visible dans `ps`).
	lan.admin_password = String(args.get("admin-password", OS.get_environment("CYBERREALM_ADMIN_PASSWORD")))
	var level := _instantiate_level(blob)
	if level == null:
		get_tree().quit(5)
		return
	add_child(level)
	lan.setup(level, String(args.get("name", "CyberRealm Server")), Color.WHITE)
	# État sauvegardé : appliqué une fois les scripts du niveau prêts (objets créés à leur _ready), AVANT host_game :
	# aucun joueur ne voit le monde d'origine.
	state_path = String(args.get("state", blob_path + ".state")) if args.get("state", null) != true else ""
	_blob_sha = _sha256_hex(blob["bytes"])
	for _i in 2:
		await get_tree().physics_frame
	_load_state()
	lan.world_reset_requested.connect(_reset_world)
	lan.level_bake_provider = func() -> Dictionary: return blob
	lan.status_changed.connect(func(t: String): print("[server] ", t))
	lan.players_changed.connect(func(roster: Array): print("[server] players: ", roster.size()))
	if not lan.host_game():
		push_error("dedicated_server: host_game() a échoué (port déjà utilisé ?)")
		get_tree().quit(4)
		return
	if lan.online:
		print("[server] MODE ONLINE : TLS réel, authentification moteur, découverte désactivée — UDP %d, TCP %d" % [lan.PORT, lan.LEVEL_TCP_PORT])
		print("[server] mot de passe défini (%d caractères) ; admin : %s" % [lan.get_pin().length(),
				"mot de passe défini" if lan.admin_password != "" else "désactivé"])
	else:
		print("[server] admin : ", "mot de passe défini" if lan.admin_password != "" else "désactivé (pas de mot de passe)")
		print("[server] PIN: ", lan.get_pin(), " — UDP %d (+%d découverte), TCP %d" % [
				lan.PORT, lan.DISCOVERY_PORT, lan.LEVEL_TCP_PORT])


func _process(delta: float) -> void:
	if state_path == "" or lan == null:
		return
	_save_cd -= delta
	if _save_cd <= 0.0:
		_save_cd = SAVE_INTERVAL
		_save_state()

func _save_state() -> void:
	var parts: Dictionary = lan.level_sync.build_snapshot()
	var bytes := var_to_bytes({"version": STATE_VERSION, "blob": _blob_sha, "parts": parts})
	if bytes == _last_state:
		return
	var tmp := state_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("dedicated_server: état non enregistré (%s)" % error_string(FileAccess.get_open_error()))
		return
	f.store_buffer(bytes)
	f.close()
	DirAccess.rename_absolute(tmp, state_path)       # remplacement atomique : jamais de fichier à moitié écrit
	_last_state = bytes

func _load_state() -> void:
	if state_path == "" or not FileAccess.file_exists(state_path):
		print("[server] monde neuf (pas d'état enregistré)")
		return
	var v: Variant = bytes_to_var(FileAccess.get_file_as_bytes(state_path))    # jamais d'objets (bytes_to_var)
	if not (v is Dictionary) or int(v.get("version", 0)) != STATE_VERSION or not (v.get("parts") is Dictionary):
		push_warning("dedicated_server: état illisible, ignoré : " + state_path)
		DirAccess.rename_absolute(state_path, state_path + ".old")
		return
	if String(v.get("blob", "")) != _blob_sha:
		print("[server] l'état enregistré correspond à un autre niveau : ignoré (renommé en .old)")
		DirAccess.rename_absolute(state_path, state_path + ".old")
		return
	var parts: Dictionary = v["parts"]
	for part in parts:
		if not (parts[part] is Array) or not lan.level_sync.snapshot_part_ok(String(part)):
			parts.erase(part)
	lan.level_sync.apply_snapshot(parts, true)
	_last_state = FileAccess.get_file_as_bytes(state_path)
	var n := 0
	for part in parts:
		n += (parts[part] as Array).size()
	print("[server] état du monde rechargé (%d entrées)" % n)

## Admin : remise à zéro du monde. Les joueurs sont prévenus, puis le serveur redémarre (systemd).
func _reset_world(by_peer: int) -> void:
	print("[server] monde réinitialisé par l'admin (pair %d) — redémarrage" % by_peer)
	if state_path != "" and FileAccess.file_exists(state_path):
		DirAccess.remove_absolute(state_path)
	state_path = ""                                   # plus d'enregistrement d'ici l'arrêt
	lan.broadcast_level_message("world_reset", null)
	await get_tree().create_timer(1.0).timeout        # le message part avant la fermeture
	lan.disconnect_session()
	get_tree().quit(RESET_EXIT_CODE)

static func _sha256_hex(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if lan != null and is_instance_valid(lan) and lan.get("session_active") == true:
			lan.disconnect_session()


## Instancie le niveau du blob POUR LA SIMULATION : scripts utilisateur et assets installés comme chez un client,
## puis tous les scripts retirés sauf ceux des nœuds marqués `net_server` (la physique du décor) — ni météo, ni
## cycle jour/nuit, ni fenêtres sur un serveur. Le Player embarqué est supprimé.
func _instantiate_level(blob: Dictionary) -> Node3D:
	var manifest: Dictionary = blob.get("scripts", {})
	if not manifest.is_empty() and UserScriptMirror.valid(manifest):
		UserScriptMirror.install(manifest)
	var assets: Dictionary = blob.get("assets", {})
	for p in assets:
		UserScriptMirror.write_bytes(String(p), assets[p])
	var path := "user://dedicated_level.scn"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("dedicated_server: impossible d'écrire " + path)
		return null
	f.store_buffer(blob["bytes"])
	f.close()
	var t0 := Time.get_ticks_msec()
	var scene := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if scene == null:
		push_error("dedicated_server: niveau illisible")
		return null
	var level := scene.instantiate() as Node3D
	if level == null:
		return null
	var player := level.find_child("Player", true, false)
	if player != null:
		player.get_parent().remove_child(player)
		player.free()
	_strip_scripts(level)
	print("[server] niveau instancié en %d ms" % (Time.get_ticks_msec() - t0))
	return level


# Le retrait d'un script efface aussi ses variables exportées : on les garde dans la méta « script_props » pour que
# les scripts conservés (ex. options du niveau) puissent lire l'état initial du niveau (heure, brume, nuages…).
static func _strip_scripts(n: Node) -> void:
	if n.get_script() != null and not n.has_meta("net_server"):
		var props := {}
		for p in n.get_property_list():
			var usage := int(p.get("usage", 0))
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_STORAGE:
				props[String(p["name"])] = n.get(String(p["name"]))
		n.set_meta("script_props", props)
		n.set_script(null)
	for c in n.get_children():
		_strip_scripts(c)


static func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	for a in argv:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else true
	return out


## Lit un blob écrit par export_level_blob.gd : {bytes, spawn, spawn_rotation, spawn_scale, scripts, assets}.
static func _load_blob(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("dedicated_server: impossible de lire %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var v: Variant = f.get_var()
	f.close()
	if not (v is Dictionary) or not (v as Dictionary).has("bytes"):
		push_error("dedicated_server: %s n'est pas un blob de niveau valide" % path)
		return {}
	print("[server] niveau chargé : %s (%d Ko)" % [path, int((v["bytes"] as PackedByteArray).size() / 1024)])
	return v
