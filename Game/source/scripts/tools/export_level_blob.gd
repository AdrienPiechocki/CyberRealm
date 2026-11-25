extends SceneTree
## Exporte un niveau en blob prébaké pour le serveur dédié (même format que celui que l'hôte LAN envoie).
##
##   godot --headless --path Game/source --script scripts/tools/export_level_blob.gd -- [niveau.tscn] [sortie.crblob]
##
## Défaut : res://user/level.tscn s'il existe, sinon res://scenes/level.tscn ; sortie : level.crblob.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var level_path := String(args[0]) if args.size() > 0 else (
			"res://user/level.tscn" if ResourceLoader.exists("res://user/level.tscn") else "res://scenes/level.tscn")
	var out_path := String(args[1]) if args.size() > 1 else "level.crblob"
	await process_frame
	var scene := load(level_path) as PackedScene
	if scene == null:
		push_error("export_level_blob: niveau introuvable : " + level_path)
		quit(2)
		return
	var level := scene.instantiate() as Node3D
	level.name = "Level"
	root.add_child(level)
	# Laisse le niveau finir sa mise en place (scripts _ready, intérieurs…) avant de le baker.
	for i in 5:
		await process_frame
	var blob := LevelBaker.bake(level)
	if blob.is_empty():
		push_error("export_level_blob: le bake a échoué")
		quit(3)
		return
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("export_level_blob: impossible d'écrire " + out_path)
		quit(4)
		return
	f.store_var(blob)
	f.close()
	print("[blob] %s -> %s (%d Ko, %d scripts)" % [level_path, out_path,
			int((blob["bytes"] as PackedByteArray).size() / 1024), (blob.get("scripts", {}) as Dictionary).size()])
	quit(0)
