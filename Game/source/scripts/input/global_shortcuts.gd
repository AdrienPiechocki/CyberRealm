extends Node
## Raccourcis globaux — côté jeu du portail xdg « GlobalShortcuts ».
##
## CyberRealm reçoit chaque touche AVANT de la transmettre à une fenêtre : il est
## le seul à pouvoir offrir un vrai raccourci global (Wayland interdit aux
## applications de lire le clavier sans focus). Le protocole du portail est
## servi par compositors/portal-shortcuts/cyberrealm-portal-shortcuts ; ce nœud
## n'en est que la moitié « clavier » :
##
##   $XDG_RUNTIME_DIR/cyberrealm-shortcuts        (backend -> jeu) JSON des
##       déclencheurs actifs : [{"ref": 1, "trigger": "SHIFT+Tab", ...}]
##   $XDG_RUNTIME_DIR/cyberrealm-shortcut-events  (jeu -> backend) lignes
##       « A <ref> » (touche pressée) puis « D <ref> » (relâchée)
##
## La touche d'un raccourci reconnu est CONSOMMÉE : ni la fenêtre focalisée, ni le
## mode focus, ni les binds du jeu ne la voient (comportement d'un raccourci global).
## `try_event` est appelé depuis wayland_room.gd:_input, avant le mode focus.

const BACKEND_REL := "compositors/portal-shortcuts/cyberrealm-portal-shortcuts"
const POLL_SEC := 0.5
# Noms de modificateurs du protocole -> clés du dictionnaire de modificateurs.
const MOD_NAMES := {
	"SHIFT": "shift", "CTRL": "ctrl", "CONTROL": "ctrl", "ALT": "alt",
	"LOGO": "super", "SUPER": "super", "META": "super",
}
# Noms de keysyms xkb que Godot n'écrit pas pareil.
const KEY_ALIASES := {
	"return": "Enter", "iso_left_tab": "Tab", "prior": "PageUp", "next": "PageDown",
	"page_up": "PageUp", "page_down": "PageDown", "backspace": "BackSpace",
}

var _rt := ""
var _registry_path := ""
var _events_path := ""
var _registry_text := ""
var _entries: Array = []          # [{ref, code, mods}]
var _held: Dictionary = {}        # keycode -> ref (raccourcis dont la touche est enfoncée)
var _poll := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rt = OS.get_environment("XDG_RUNTIME_DIR")
	if _rt.is_empty():
		set_process(false)
		return
	_registry_path = _rt + "/cyberrealm-shortcuts"
	_events_path = _rt + "/cyberrealm-shortcut-events"

## À appeler AVANT compositor.launch_portals() : déclare le backend au xdg-desktop-portal
## privé du jeu. Les fichiers vivent dans $XDG_RUNTIME_DIR (rien n'est installé chez
## l'utilisateur) et sont trouvés grâce à XDG_DATA_DIRS.
func prepare() -> void:
	if _rt.is_empty():
		return
	for p: String in [_registry_path, _events_path]:   # restes d'une session précédente
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	var share := _rt + "/cyberrealm-portal/share"
	DirAccess.make_dir_recursive_absolute(share + "/xdg-desktop-portal/portals")
	_write(share + "/xdg-desktop-portal/portals/cyberrealm.portal",
		"[portal]\nDBusName=org.freedesktop.impl.portal.desktop.cyberrealm\n"
		+ "Interfaces=org.freedesktop.impl.portal.GlobalShortcuts;\nUseIn=dwl;wlr;\n")
	# « dwl:wlr » (set_portal_backend) : ce fichier prime sur wlr-portals.conf ; tout reste
	# chez wlr, sauf GlobalShortcuts qui va à notre backend.
	_write(share + "/xdg-desktop-portal/dwl-portals.conf",
		"[preferred]\ndefault=wlr\norg.freedesktop.impl.portal.GlobalShortcuts=cyberrealm\n")
	var dirs := OS.get_environment("XDG_DATA_DIRS")
	if dirs.is_empty():
		dirs = "/usr/local/share:/usr/share"
	if not dirs.begins_with(share + ":"):
		OS.set_environment("XDG_DATA_DIRS", share + ":" + dirs)

## À appeler APRÈS compositor.launch_portals() (le bus privé existe alors).
func start_backend(compositor: Object) -> void:
	var script := _find_backend()
	if script.is_empty():
		push_warning("global_shortcuts: %s introuvable — pas de raccourcis globaux" % BACKEND_REL)
		return
	compositor.launch_app("python3 '%s'" % script)

func _find_backend() -> String:
	var candidates: Array[String] = [
		OS.get_executable_path().get_base_dir() + "/../../" + BACKEND_REL,   # Game/build/ -> racine
		ProjectSettings.globalize_path("res://") + "../../" + BACKEND_REL,   # éditeur : Game/source/
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c.simplify_path()
	return ""

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()

func _process(delta: float) -> void:
	_poll += delta
	if _poll < POLL_SEC:
		return
	_poll = 0.0
	if not FileAccess.file_exists(_registry_path):
		if not _entries.is_empty():
			_entries.clear()
			_registry_text = ""
		return
	var f := FileAccess.open(_registry_path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	if text != _registry_text:     # le contenu, pas la date : deux écritures dans la même seconde
		_registry_text = text
		_load_registry(text)

func _load_registry(text: String) -> void:
	_entries.clear()
	var rows: Variant = JSON.parse_string(text)
	if not rows is Array:
		return
	for row in rows:
		if not row is Dictionary:
			continue
		var parsed := parse_trigger(str(row.get("trigger", "")))
		if parsed.is_empty():
			continue
		parsed["ref"] = int(row.get("ref", 0))
		_entries.append(parsed)

## « SHIFT+Tab » -> {code: KEY_TAB, mods: {shift: true, ...}} ; {} si inutilisable.
static func parse_trigger(trigger: String) -> Dictionary:
	var parts := trigger.split("+", false)
	if parts.is_empty():
		return {}
	var mods := {"shift": false, "ctrl": false, "alt": false, "super": false}
	for i in range(parts.size() - 1):
		var up := parts[i].strip_edges().to_upper()
		if MOD_NAMES.has(up):
			mods[MOD_NAMES[up]] = true
		# NUM / CAPS (verrous) : sans effet sur la correspondance
	var key := parts[parts.size() - 1].strip_edges()
	key = KEY_ALIASES.get(key.to_lower(), key)
	var code: int = OS.find_keycode_from_string(key)
	if code == KEY_NONE:
		return {}
	return {"code": code, "mods": mods}

## Vrai si la touche appartient à un raccourci global (elle est alors consommée).
func try_event(event: InputEvent) -> bool:
	var kev := event as InputEventKey
	if kev == null:
		return false
	var code: int = kev.keycode if kev.keycode != KEY_NONE else kev.physical_keycode
	if not kev.pressed:                                   # relâchement d'un raccourci tenu
		if _held.has(code):
			_send("D", _held[code])
			_held.erase(code)
			return true
		return false
	if _held.has(code):                                   # répétition clavier : consommée, pas ré-émise
		return true
	for e in _entries:
		if e["code"] == code and _mods_match(kev, e["mods"]):
			_held[code] = e["ref"]
			_send("A", e["ref"])
			return true
	return false

static func _mods_match(ev: InputEventKey, mods: Dictionary) -> bool:
	return ev.shift_pressed == mods["shift"] and ev.ctrl_pressed == mods["ctrl"] \
		and ev.alt_pressed == mods["alt"] and ev.meta_pressed == mods["super"]

func _send(kind: String, ref: int) -> void:
	var f := FileAccess.open(_events_path, FileAccess.READ_WRITE)   # créé par le backend
	if f == null:
		return
	f.seek_end()
	f.store_string("%s %d\n" % [kind, ref])
	f.close()
