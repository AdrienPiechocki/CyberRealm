extends RefCounted
## Décorations 3D des fenêtres : métriques, textures et rechargement.
##
## Principe identique à `ui/style.css` + `ui_theme.gd` : un fichier par défaut
## dans `res://`, une surcharge `user://` fusionnée clé par clé, et un poll du
## mtime qui recharge tout quand un fichier change sur le disque.
##
## API STATIQUE, pas d'autoload : `windows_3d.gd` est préchargé par plusieurs
## tests lancés via `godot --headless --script`, où les autoloads n'existent pas.

const RES_DIR := "res://ui/decorations"
const USER_DIR := "user://"
const RES_JSON := "res://ui/decorations/decorations.json"
const USER_JSON := "user://decorations.json"
const POLL_SECONDS := 0.5
const ASSETS := ["border", "minimize", "maximize", "restore", "close"]
## Godot évalue le `Label3D` avec un pixel_size de 0,005 : c'est notre repli
## tant que la fenêtre n'a pas reçu sa première texture (donc son ratio px).
const FALLBACK_PX_SCALE := 0.005

static var _metrics: Dictionary = {}
static var _loaded := false

static func default_metrics() -> Dictionary:
	return {
		"titlebar_height": 20.0,
		"border_size": 10.0,
		"label_size": 10.0,
		"label_color": Color(0.859, 0.882, 0.941),
		"button_size": 11.0,
		"button_gap": 4.0,
		"button_margin": 7.0,
		"button_alignment": "right",
		"button_states": 3.0,
	}

static func metrics() -> Dictionary:
	if not _loaded:
		reload()
	return _metrics

## Retire `// …` et `/* … */` SANS toucher aux littéraux de chaîne. Un chemin
## comme "res://ui/decorations/close.svg" contient `//` : un stripper naïf
## effacerait le reste de la ligne et le JSON deviendrait invalide.
static func strip_comments(text: String) -> String:
	var out := ""
	var i := 0
	var n := text.length()
	var in_string := false
	while i < n:
		var ch := text[i]
		if in_string:
			out += ch
			if ch == "\\" and i + 1 < n:
				out += text[i + 1]
				i += 2
				continue
			if ch == "\"":
				in_string = false
			i += 1
			continue
		if ch == "\"":
			in_string = true
			out += ch
			i += 1
			continue
		if ch == "/" and i + 1 < n:
			var nxt := text[i + 1]
			if nxt == "/":
				while i < n and text[i] != "\n":
					i += 1
				continue
			if nxt == "*":
				i += 2
				while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
					i += 1
				i += 2
				continue
		out += ch
		i += 1
	return out

static func strip_trailing_commas(text: String) -> String:
	var out := ""
	var i := 0
	var n := text.length()
	var in_string := false
	while i < n:
		var ch := text[i]
		if in_string:
			out += ch
			if ch == "\\" and i + 1 < n:
				out += text[i + 1]
				i += 2
				continue
			if ch == "\"":
				in_string = false
			i += 1
			continue
		if ch == "\"":
			in_string = true
			out += ch
			i += 1
			continue
		if ch == ",":
			var j := i + 1
			while j < n and " \t\n\r".contains(text[j]):
				j += 1
			if j < n and (text[j] == "}" or text[j] == "]"):
				i += 1
				continue
		out += ch
		i += 1
	return out

## Fusionne `text` dans `m`, clé par clé : une clé absente ou illisible garde sa
## valeur courante. Renvoie "" ou un message d'erreur.
static func parse_config(text: String, m: Dictionary, source := "") -> String:
	if text.strip_edges() == "":
		return ""
	var parsed: Variant = JSON.parse_string(strip_trailing_commas(strip_comments(text)))
	if not (parsed is Dictionary):
		var msg := "JSON illisible — métriques par défaut conservées"
		push_warning("WindowDecorations(%s): %s" % [source, msg])
		return msg
	var src: Dictionary = parsed
	for key: String in m.keys():
		if not src.has(key):
			continue
		var current: Variant = m[key]
		var value: Variant = src[key]
		# Une clé présente mais illisible garde le défaut : `str(7)` aurait
		# promu un nombre à "7" dans une métrique de texte, silencieusement.
		var usable := true
		if current is Color:
			usable = _is_hex_color(value)
		elif current is String:
			usable = value is String
		else:
			usable = _is_positive_number(value)
		if not usable:
			_reject(key, value, source)
			continue
		if current is Color:
			# `current` est le repli : un hex illisible ne peut pas virer au noir.
			m[key] = Color.from_string(_hex(value), current)
		elif current is String:
			m[key] = value as String
		else:
			m[key] = _number(value)
	return ""

## Une métrique de texte ne peut pas être portée par un nombre : on refuse au
## lieu de convertir, sinon la faute de frappe reste invisible jusqu'au rendu.
static func _reject(key: String, value: Variant, source: String) -> void:
	push_warning("WindowDecorations(%s): %s illisible (%s), défaut conservé"
		% [source, key, str(value)])

static func _is_positive_number(value: Variant) -> bool:
	if value is float or value is int:
		return float(value) > 0.0
	if value is String:
		return (value as String).strip_edges().to_float() > 0.0
	return false

static func _is_hex_color(value: Variant) -> bool:
	if not (value is String):
		return false
	var hex := (value as String).strip_edges().lstrip("#")
	return (hex.length() == 6 or hex.length() == 8) and hex.is_valid_hex_number(false)

## Les deux prédicats ci-dessus portent toute la politique de repli ; ces deux
## convertisseurs ne font que lire une valeur déjà validée.
static func _hex(value: Variant) -> String:
	return "#" + (value as String).strip_edges().lstrip("#")

static func _number(value: Variant) -> float:
	if value is float or value is int:
		return float(value)
	return (value as String).strip_edges().to_float()

## Ne charge que les MÉTRIQUES. Le plan d'origine appelait ici `current_mtimes()`
## et `_load_asset()`, introduits plus tard : GDScript rejette l'appel d'une
## statique inconnue à la compilation, donc le fichier ne se chargeait pas du
## tout et aucun test ne pouvait passer. `reload()` est élargi ensuite aux
## textures et aux mtimes.
static func reload() -> void:
	_metrics = default_metrics()
	parse_config(FileAccess.get_file_as_string(RES_JSON), _metrics, RES_JSON)
	# Le fichier utilisateur est fusionné APRÈS : il gagne clé par clé, et un
	# fichier cassé laisse le défaut du jeu intact au lieu de tout effacer.
	parse_config(FileAccess.get_file_as_string(USER_JSON), _metrics, USER_JSON)
	_loaded = true