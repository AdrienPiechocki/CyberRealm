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

## Rectangles SOURCE des 8 pièces du 9-patch, en pixels de texture. Les marges
## sont les métriques (`border_size` / `titlebar_height`), pas une mesure de la
## texture : l'auteur redimensionne donc le 9-patch sans toucher au code.
static func border_source_rects(tex_size: Vector2, m: Dictionary) -> Dictionary:
	var t := float(m.get("border_size", 10.0))
	var b := float(m.get("titlebar_height", 20.0))
	var w := tex_size.x
	var h := tex_size.y
	return {
		"topleft": _clamp_rect(Rect2(0.0, 0.0, t, b), w, h),
		"top": _clamp_rect(Rect2(t, 0.0, w - 2.0 * t, b), w, h),
		"topright": _clamp_rect(Rect2(w - t, 0.0, t, b), w, h),
		"left": _clamp_rect(Rect2(0.0, b, t, h - b - t), w, h),
		"right": _clamp_rect(Rect2(w - t, b, t, h - b - t), w, h),
		"bottomleft": _clamp_rect(Rect2(0.0, h - t, t, t), w, h),
		"bottom": _clamp_rect(Rect2(t, h - t, w - 2.0 * t, t), w, h),
		"bottomright": _clamp_rect(Rect2(w - t, h - t, t, t), w, h),
	}

## Recadre un rect dans la texture. Une découpe impossible (texture plus
## petite que les marges) ressort en `Rect2()` : taille nulle = « ne pas
## dessiner », jamais une UV hors texture.
static func _clamp_rect(r: Rect2, w: float, h: float) -> Rect2:
	var x0 := clampf(r.position.x, 0.0, w)
	var y0 := clampf(r.position.y, 0.0, h)
	var x1 := clampf(r.position.x + r.size.x, 0.0, w)
	var y1 := clampf(r.position.y + r.size.y, 0.0, h)
	var out := Rect2(x0, y0, x1 - x0, y1 - y0)
	if out.size.x <= 0.0 or out.size.y <= 0.0:
		return Rect2()
	return out

## Un `Rect2` par état de bouton. La cellule est CARRÉE et vaut la hauteur de la
## texture ; le pas est dérivé, donc un strip collé comme un strip espacé
## donnent le même résultat. `states <= 1` : une seule région, réutilisée.
static func button_state_rects(tex_size: Vector2, states: float) -> Array:
	var out: Array = []
	var cell := tex_size.y
	if cell <= 0.0 or tex_size.x <= 0.0:
		return out
	var count := int(states)
	if count <= 1:
		out.append(Rect2(0.0, 0.0, tex_size.x, cell))
		return out
	var pitch := (tex_size.x - cell) / float(count - 1)
	for i in count:
		out.append(Rect2(float(i) * pitch, 0.0, cell, cell))
	return out

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