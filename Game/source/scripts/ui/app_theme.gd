extends RefCounted
## Thème des applications (icônes + couleurs Qt/KDE), déduit du thème clair/sombre choisi dans les
## paramètres. Aucun portail ne transmet un thème d'icônes : GTK, Qt/KDE (et
## LibreOffice, qui s'en sert pour son style d'icônes automatique) le lisent dans
## leurs fichiers de config, et la config de l'utilisateur prime sur tout ce que le
## jeu pourrait fournir par l'environnement. On l'écrit donc là où ils le lisent :
##   ~/.config/kdeglobals            [Icons] Theme
##   ~/.config/gtk-3.0/settings.ini   gtk-icon-theme-name, gtk-application-prefer-dark-theme (gtk-4.0 : préférence sombre seule)
## et, pour les couleurs des apps Qt/KDE, les sections [Colors:*] de kdeglobals.

const DARK_ICONS := "breeze-dark"
const LIGHT_ICONS := "breeze"
const ICON_DIRS := ["/usr/share/icons", "/usr/local/share/icons"]

## Nom du thème d'icônes pour un schéma ("dark" / "light"), "" si le thème
## n'est pas installé (on ne pointe jamais vers un thème absent).
static func icon_theme_for(scheme: String, icon_dirs: Array = ICON_DIRS) -> String:
	var name := LIGHT_ICONS if scheme == "light" else DARK_ICONS
	for d in icon_dirs:
		if DirAccess.dir_exists_absolute(String(d) + "/" + name):
			return name
	var home := OS.get_environment("HOME")
	if home != "" and DirAccess.dir_exists_absolute(home + "/.local/share/icons/" + name):
		return name
	return ""

## Écrit le thème d'icônes (et la préférence sombre GTK) sous `config_dir`
## (~/.config par défaut). Les fichiers ne sont réécrits que si une valeur change.
static func apply(scheme: String, config_dir := "", icon_dirs: Array = ICON_DIRS) -> void:
	if config_dir == "":
		config_dir = _default_config_dir()
	var icons := icon_theme_for(scheme, icon_dirs)
	if icons == "":
		return
	set_ini_value(config_dir + "/kdeglobals", "Icons", "Theme", icons)
	var prefer_dark := "true" if scheme != "light" else "false"
	# GTK3 : thème d'icônes + préférence sombre. GTK4 : préférence sombre seulement —
	# ses apps (GNOME/libadwaita, souvent flatpak) utilisent des noms d'icônes
	# Adwaita que Breeze n'a pas (entonnoir de filtre...) ; leur imposer Breeze
	# les prive d'icônes.
	var gtk3: String = config_dir + "/gtk-3.0/settings.ini"
	set_ini_value(gtk3, "Settings", "gtk-icon-theme-name", icons)
	set_ini_value(gtk3, "Settings", "gtk-application-prefer-dark-theme", prefer_dark)
	set_ini_value(config_dir + "/gtk-4.0/settings.ini", "Settings", "gtk-application-prefer-dark-theme", prefer_dark)

## Fixe section/key dans un fichier INI en conservant le reste tel quel.
## Crée fichier et dossier au besoin. Retourne true si le fichier a été modifié.
static func set_ini_value(path: String, section: String, key: String, value: String) -> bool:
	return set_ini_values(path, [[section, key, value]])

## Plusieurs [section, clé, valeur] en une seule lecture/écriture.
static func set_ini_values(path: String, entries: Array) -> bool:
	var lines: PackedStringArray = []
	if FileAccess.file_exists(path):
		lines = FileAccess.get_file_as_string(path).split("\n")
		if lines.size() > 0 and lines[lines.size() - 1] == "":
			lines.remove_at(lines.size() - 1)
	var changed := false
	for e in entries:
		if _set_in_lines(lines, String(e[0]), String(e[1]), String(e[2])):
			changed = true
	return _write_lines(path, lines) if changed else false

static func _set_in_lines(lines: PackedStringArray, section: String, key: String, value: String) -> bool:
	var header := "[" + section + "]"
	var in_section := false
	var section_end := -1   # index où insérer la clé à la fin de la section
	for i in lines.size():
		var t := lines[i].strip_edges()
		if t.begins_with("["):
			if in_section:
				break
			in_section = (t == header)
			if in_section:
				section_end = i + 1
			continue
		if not in_section:
			continue
		if t != "":
			section_end = i + 1
		var eq := t.find("=")
		if eq != -1 and t.substr(0, eq).strip_edges() == key:
			if t.substr(eq + 1).strip_edges() == value:
				return false
			lines[i] = key + "=" + value
			return true
	if section_end == -1:
		lines.append(header)
		lines.append(key + "=" + value)
	else:
		lines.insert(section_end, key + "=" + value)
	return true

static func _write_lines(path: String, lines: PackedStringArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return true

# ── Couleurs KDE / Qt ────────────────────────────────────────────────
#
# Les apps Qt/KDE (platformtheme « kde ») lisent leurs couleurs dans les sections
# [Colors:*] de ~/.config/kdeglobals : changer le seul nom de schéma ne suffit pas,
# `plasma-apply-colorscheme` recopie le contenu du fichier .colors. On fait pareil
# avec BreezeDark / BreezeLight, puis on applique l'accent par-dessus. Dolphin &
# co surveillent kdeglobals et se recolorent en direct.

const SCHEME_DIRS := ["/usr/share/color-schemes", "/usr/local/share/color-schemes"]
const KDE_SCHEMES := {"dark": "BreezeDark", "light": "BreezeLight"}

static func _rgb(c: Color) -> String:
	return "%d,%d,%d" % [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0)]

## Lignes [section, clé, valeur] d'un fichier .colors : tout sauf [General] et [KDE]
## (sections Colors:*, ColorEffects:*, WM).
static func parse_colors_file(text: String) -> Array:
	var out: Array = []
	var section := ""
	for raw in text.split("\n"):
		var t := raw.strip_edges()
		if t.begins_with("[") and t.ends_with("]"):
			section = t.substr(1, t.length() - 2)
			continue
		var eq := t.find("=")
		if section == "" or eq == -1 or section == "General" or section == "KDE":
			continue
		out.append([section, t.substr(0, eq).strip_edges(), t.substr(eq + 1).strip_edges()])
	return out

## Applique schéma (Breeze sombre/clair) + accent à kdeglobals. Sans fichier .colors
## installé, seul l'accent est écrit.
static func apply_kde_colors(scheme: String, accent: Color, config_dir := "", scheme_dirs: Array = SCHEME_DIRS) -> void:
	if config_dir == "":
		config_dir = _default_config_dir()
	var name: String = KDE_SCHEMES["light" if scheme == "light" else "dark"]
	var entries: Array = []
	var dirs: Array = scheme_dirs.duplicate()
	var home := OS.get_environment("HOME")
	if home != "":
		dirs.append(home + "/.local/share/color-schemes")
	for d in dirs:
		var path: String = String(d) + "/" + name + ".colors"
		if FileAccess.file_exists(path):
			entries = parse_colors_file(FileAccess.get_file_as_string(path))
			entries.append(["General", "ColorScheme", name])
			break
	var rgb := _rgb(accent)
	# Texte lisible sur l'accent (luminance perçue).
	var lum := 0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b
	var on_accent := "35,38,39" if lum > 0.6 else "252,252,252"
	# L'accent prime sur le schéma : sélection, focus et survol.
	var overrides := {
		"Colors:Selection/BackgroundNormal": rgb,
		"Colors:Selection/ForegroundNormal": on_accent,
	}
	for sec in ["Button", "Complementary", "Header", "Selection", "Tooltip", "View", "Window"]:
		overrides["Colors:%s/DecorationFocus" % sec] = rgb
	var merged: Array = []
	for e in entries:
		var k: String = "%s/%s" % [e[0], e[1]]
		if overrides.has(k):
			continue
		merged.append(e)
	for k in overrides:
		var parts: PackedStringArray = k.split("/")
		merged.append([parts[0], parts[1], overrides[k]])
	merged.append(["General", "AccentColor", rgb])
	set_ini_values(config_dir + "/kdeglobals", merged)

static func _default_config_dir() -> String:
	var xdg := OS.get_environment("XDG_CONFIG_HOME")
	return xdg if xdg != "" else OS.get_environment("HOME") + "/.config"
