extends RefCounted
## Catalogue des niveaux jouables : le niveau par défaut + tous les fichiers
## `level.tscn` trouvés sous res://user/ (ex. res://user/Levels/Morrowind/level.tscn,
## ou l'ancien emplacement unique res://user/level.tscn).
##
## Le nom affiché vient du DOSSIER du fichier (jamais d'un load() : un niveau
## comme Morrowind pèse des centaines de Mo, le menu ne doit rien charger) :
##   res://scenes/level.tscn               -> « Default »
##   res://user/level.tscn                 -> « Custom »
##   res://user/Levels/Morrowind/level.tscn -> « Morrowind »

const DEFAULT_LEVEL_PATH := "res://scenes/level.tscn"
const CUSTOM_LEVEL_PATH := "res://user/level.tscn"
const USER_ROOT := "res://user"
const LEVEL_FILE := "level.tscn"
## Clé du réglage persistant (user://settings.json, partagé avec le menu pause).
const SETTING_KEY := "level_path"

## [{path, name}] — défaut en premier, puis les niveaux custom par chemin.
static func list_levels() -> Array[Dictionary]:
	var found: Array = []
	_scan(USER_ROOT, found)
	# Build exporté : les .tscn deviennent « *.remap » dans le PCK.
	for i in found.size():
		found[i] = String(found[i]).trim_suffix(".remap")
	found.sort()
	var paths: Array = [DEFAULT_LEVEL_PATH]
	for p in found:
		if not paths.has(p):
			paths.append(p)
	var out: Array[Dictionary] = []
	var seen := {}
	for p in paths:
		var path := String(p)
		var nm := display_name(path)
		if seen.has(nm):
			seen[nm] = int(seen[nm]) + 1
			nm = "%s (%d)" % [nm, seen[nm]]
		else:
			seen[nm] = 1
		out.append({"path": path, "name": nm})
	return out

static func display_name(path: String) -> String:
	if path == DEFAULT_LEVEL_PATH:
		return "Default"
	var dir := path.get_base_dir()
	if dir == USER_ROOT:
		return "Custom"
	return dir.get_file()

## Niveau à charger au démarrage : le choix persisté s'il existe toujours,
## sinon res://user/level.tscn (ancien emplacement), sinon le premier niveau
## custom du catalogue (un niveau custom prime sur le défaut), sinon le défaut.
static func resolve_startup_level(saved_path: String) -> String:
	if saved_path != "" and is_valid_level_path(saved_path) and ResourceLoader.exists(saved_path):
		return saved_path
	return first_custom_level()

## Niveau custom « auto » : res://user/level.tscn s'il existe, sinon le premier
## level.tscn de res://user/ par ordre de chemin, sinon le niveau par défaut.
static func first_custom_level() -> String:
	if ResourceLoader.exists(CUSTOM_LEVEL_PATH):
		return CUSTOM_LEVEL_PATH
	for lv in list_levels():
		if String(lv["path"]) != DEFAULT_LEVEL_PATH:
			return String(lv["path"])
	return DEFAULT_LEVEL_PATH

## Seuls les chemins du catalogue sont acceptés (pas de scène arbitraire).
static func is_valid_level_path(path: String) -> bool:
	if path == DEFAULT_LEVEL_PATH:
		return true
	return path.begins_with(USER_ROOT + "/") and path.get_file() == LEVEL_FILE \
			and not path.contains("..")

## Lit le choix persisté directement dans user://settings.json : le niveau est
## chargé dans WaylandRoom._init(), avant que le menu pause n'existe.
static func read_saved_level(settings_path: String) -> String:
	if not FileAccess.file_exists(settings_path):
		return ""
	var f := FileAccess.open(settings_path, FileAccess.READ)
	if f == null:
		return ""
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return String((parsed as Dictionary).get(SETTING_KEY, ""))
	return ""

static func _scan(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not f.begins_with("."):
			var p := dir_path.path_join(f)
			if d.current_is_dir():
				_scan(p, out)
			elif f == LEVEL_FILE or f == LEVEL_FILE + ".remap":
				out.append(p)
		f = d.get_next()
	d.list_dir_end()
