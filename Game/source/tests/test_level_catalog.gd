extends Node
## Tests du catalogue de niveaux (menu World).
const Catalog = preload("res://scripts/main/level_catalog.gd")

func test_default_listed_first() -> Variant:
	var levels := Catalog.list_levels()
	if levels.is_empty():
		return "empty catalog"
	if String(levels[0]["path"]) != Catalog.DEFAULT_LEVEL_PATH:
		return "first entry: %s" % levels[0]["path"]
	if String(levels[0]["name"]) != "Default":
		return "default name: %s" % levels[0]["name"]
	return true

func test_entries_are_valid_and_unique() -> Variant:
	var paths := {}
	var names := {}
	for lv in Catalog.list_levels():
		var p := String(lv["path"])
		if not Catalog.is_valid_level_path(p):
			return "invalid path listed: %s" % p
		if p.ends_with(".remap"):
			return "remap suffix kept: %s" % p
		if paths.has(p) or names.has(lv["name"]):
			return "duplicate: %s" % p
		paths[p] = true
		names[lv["name"]] = true
	return true

func test_display_names() -> Variant:
	if Catalog.display_name("res://user/level.tscn") != "Custom":
		return "custom: %s" % Catalog.display_name("res://user/level.tscn")
	var n := Catalog.display_name("res://user/Levels/Morrowind/level.tscn")
	if n != "Morrowind":
		return "folder name: %s" % n
	return true

func test_path_validation() -> Variant:
	for bad in ["res://scenes/player.tscn", "res://user/avatar.tscn",
			"res://user/../scenes/level.tscn", "user://level.tscn", ""]:
		if Catalog.is_valid_level_path(bad):
			return "accepted: %s" % bad
	for good in [Catalog.DEFAULT_LEVEL_PATH, "res://user/level.tscn", "res://user/Levels/X/level.tscn"]:
		if not Catalog.is_valid_level_path(good):
			return "rejected: %s" % good
	return true

func test_startup_fallback() -> Variant:
	var fallback := Catalog.resolve_startup_level("")
	var expected := Catalog.first_custom_level()
	var levels := Catalog.list_levels()
	if levels.size() > 1 and expected == Catalog.DEFAULT_LEVEL_PATH:
		return "a custom level exists but the default is picked"
	if fallback != expected:
		return "fallback: %s" % fallback
	if Catalog.resolve_startup_level("res://user/Levels/Missing/level.tscn") != expected:
		return "missing saved level not ignored"
	if Catalog.resolve_startup_level("res://scenes/player.tscn") != expected:
		return "non-level scene accepted"
	if Catalog.resolve_startup_level(Catalog.DEFAULT_LEVEL_PATH) != Catalog.DEFAULT_LEVEL_PATH:
		return "saved default ignored"
	return true

func test_read_saved_level() -> Variant:
	var path := "user://test_level_catalog_settings.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"level_path": "res://user/level.tscn", "other": 1}))
	f.close()
	var got := Catalog.read_saved_level(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if got != "res://user/level.tscn":
		return "read: %s" % got
	if Catalog.read_saved_level("user://does_not_exist.json") != "":
		return "missing file should give empty"
	return true
