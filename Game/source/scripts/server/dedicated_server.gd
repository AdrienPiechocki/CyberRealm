extends Node
## Serveur dédié CyberRealm (headless) : héberge une session sans joueur local, p. ex. sur un Raspberry Pi.
##
## Il réutilise tel quel le protocole LAN (lan_manager) : PIN, DTLS, transfert du niveau, relais des joueurs. Il
## n'instancie ni compositeur Wayland ni joueur ni fenêtre — il sert un NIVEAU PRÉBAKÉ (blob) produit par le jeu :
##
##   1. Sur une machine de jeu :  godot --headless --path Game/source --script scripts/tools/export_level_blob.gd \\
##          -- [res://user/level.tscn] [level.crblob]
##   2. Sur le serveur :          godot --headless --path Game/source scenes/dedicated_server.tscn \\
##          -- --blob=level.crblob [--pin=1234] [--name=Serveur] [--max-players=8] [--no-dtls]
##
## Les clients rejoignent par IP:PIN comme pour un hôte LAN. Arrêt : SIGINT/SIGTERM (Ctrl+C).

const LanScript := preload("res://scripts/network/lan_manager.gd")

var lan: Node = null

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
	lan.forced_pin = String(args.get("pin", ""))
	lan.max_players = int(args.get("max-players", 8))
	lan.encryption_enabled = not args.has("no-dtls")
	var level := _instantiate_level(blob)
	if level == null:
		get_tree().quit(5)
		return
	add_child(level)
	lan.setup(level, String(args.get("name", "CyberRealm Server")), Color.WHITE)
	lan.level_bake_provider = func() -> Dictionary: return blob
	lan.status_changed.connect(func(t: String): print("[server] ", t))
	lan.players_changed.connect(func(roster: Array): print("[server] players: ", roster.size()))
	if not lan.host_game():
		push_error("dedicated_server: host_game() a échoué (port déjà utilisé ?)")
		get_tree().quit(4)
		return
	print("[server] PIN: ", lan.get_pin(), " — UDP %d (+%d découverte), TCP %d" % [
			lan.PORT, lan.DISCOVERY_PORT, lan.LEVEL_TCP_PORT])


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


static func _strip_scripts(n: Node) -> void:
	if n.get_script() != null and not n.has_meta("net_server"):
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
