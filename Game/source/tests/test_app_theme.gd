extends Node
## Tests du thème d'icônes des applications (écriture des fichiers de config).
const Runner = preload("res://tests/runner.gd")
const Icons = preload("res://scripts/ui/app_theme.gd")

func _tmp() -> String:
	var d := OS.get_environment("TMPDIR")
	if d == "":
		d = "/tmp"
	d += "/cyberrealm_icon_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(d)
	return d

func _rm(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_rm(dir + "/" + sub)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)

func test_set_ini_value_creates_replaces_and_preserves() -> Variant:
	var d := _tmp()
	var p := d + "/sub/x.ini"
	Icons.set_ini_value(p, "Icons", "Theme", "a")
	var r = Runner.assert_eq(FileAccess.get_file_as_string(p), "[Icons]\nTheme=a\n")
	if r != true:
		_rm(d)
		return r
	FileAccess.open(p, FileAccess.WRITE).store_string("[General]\nx=1\n\n[Icons]\nTheme=a\nother=2\n[Z]\nk=v\n")
	var changed: bool = Icons.set_ini_value(p, "Icons", "Theme", "b")
	var same: bool = Icons.set_ini_value(p, "Icons", "Theme", "b")
	Icons.set_ini_value(p, "Icons", "new", "n")
	var txt := FileAccess.get_file_as_string(p)
	_rm(d)
	if not changed or same:
		return "changed=%s same=%s" % [changed, same]
	return Runner.assert_eq(txt, "[General]\nx=1\n\n[Icons]\nTheme=b\nother=2\nnew=n\n[Z]\nk=v\n")

func test_apply_writes_kde_and_gtk() -> Variant:
	var d := _tmp()
	DirAccess.make_dir_recursive_absolute(d + "/icons/breeze-dark")
	Icons.apply("dark", d + "/cfg", [d + "/icons"])
	var kde := FileAccess.get_file_as_string(d + "/cfg/kdeglobals")
	var gtk := FileAccess.get_file_as_string(d + "/cfg/gtk-4.0/settings.ini")
	# thème clair demandé mais "breeze" absent : rien ne change
	Icons.apply("light", d + "/cfg", [d + "/icons"])
	var kde2 := FileAccess.get_file_as_string(d + "/cfg/kdeglobals")
	_rm(d)
	if kde != "[Icons]\nTheme=breeze-dark\n":
		return "kdeglobals: %s" % kde
	if gtk.contains("gtk-icon-theme-name") or not gtk.contains("gtk-application-prefer-dark-theme=true"):
		return "gtk4: %s" % gtk
	return Runner.assert_eq(kde2, kde)

func test_kde_colors_merge_scheme_and_accent() -> Variant:
	var d := _tmp()
	DirAccess.make_dir_recursive_absolute(d + "/schemes")
	FileAccess.open(d + "/schemes/BreezeDark.colors", FileAccess.WRITE).store_string(
		"[General]\nName=Breeze Dark\n\n[Colors:Selection]\nBackgroundNormal=1,2,3\nForegroundNormal=9,9,9\nDecorationFocus=4,5,6\n\n[Colors:View]\nBackgroundNormal=20,20,20\nDecorationFocus=4,5,6\n")
	FileAccess.open(d + "/cfg_pre", FileAccess.WRITE)
	DirAccess.make_dir_recursive_absolute(d + "/cfg")
	FileAccess.open(d + "/cfg/kdeglobals", FileAccess.WRITE).store_string("[Colors:View]\nBackgroundNormal=250,250,250\n[General]\nfoo=bar\n")
	Icons.apply_kde_colors("dark", Color(1, 0, 0), d + "/cfg", [d + "/schemes"])
	var txt := FileAccess.get_file_as_string(d + "/cfg/kdeglobals")
	_rm(d)
	for needle in ["BackgroundNormal=20,20,20", "[Colors:Selection]\nBackgroundNormal=255,0,0", "DecorationFocus=255,0,0",
			"ColorScheme=BreezeDark", "AccentColor=255,0,0", "foo=bar"]:
		if not txt.contains(needle):
			return "manque « %s » dans :\n%s" % [needle, txt]
	if txt.contains("250,250,250"):
		return "l'ancien fond n'a pas été remplacé"
	return true
