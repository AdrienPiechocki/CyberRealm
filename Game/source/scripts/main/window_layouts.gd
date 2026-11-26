extends Node
## Disposition des fenêtres retrouvée d'une session à l'autre.
##
## Quand une fenêtre apparaît, si une disposition enregistrée lui correspond sur ce niveau (même app_id, titre le plus
## proche), elle reprend sa place (position, orientation, taille monde et taille en pixels si le joueur l'avait
## redimensionnée) et son état (cachée, épinglée, force_game). Les fenêtres vivantes sont relevées toutes les
## POLL_INTERVAL secondes et à leur fermeture ; le fichier est réécrit au plus toutes les SAVE_DEBOUNCE secondes.
##
## Données : user://window_layouts.json = { "<clé de niveau>": [entrée, …] }, au plus MAX_ENTRIES entrées par
## niveau (les plus anciennes, d'après last_seen, sont retirées). La clé de niveau est celle des waypoints : sur un
## niveau reçu d'un hôte LAN elle est vide et la fonction est inactive. Ignorées : fenêtres sans app_id, boîtes de
## dialogue (fenêtre parente).
##
## Reprise de session : les applications encore ouvertes quand le jeu s'arrête sont relancées au démarrage suivant
## (restore_session), avec leur ligne de commande et leur dossier courant (Flatpak : `flatpak run <id>`), une fois
## par processus (Firefox et ses deux fenêtres = un seul lancement). La liste est reconstruite à chaque écriture du
## fichier et figée par freeze_session() juste avant que le jeu ne ferme les apps en quittant. Les apps déjà
## présentes dans les « startup apps » (même exécutable) ne sont pas relancées une seconde fois.
##
## Créé par wayland_room.gd, qui lui branche window_created (après la création du quad), window_unmapped (AVANT les
## autres gestionnaires, pour relever l'état épinglé / focus avant qu'il ne soit défait) et window_texture_updated.

const SAVE_PATH := "user://window_layouts.json"
const MAX_ENTRIES := 64
const SAVE_DEBOUNCE := 2.0
const POLL_INTERVAL := 2.0

var compositor: Object = null
var win3d: Node = null
var focus: Node = null
var pins: Node = null
var level_key := Callable()    # -> String ("" = disposition indisponible)
var enabled := Callable()      # -> bool (option du menu pause)
var reopen := Callable()       # -> bool : relancer les apps de la session précédente (option du menu pause)
var save_path := SAVE_PATH

var _data: Dictionary = {}     # clé de niveau -> Array[Dictionary]
var _consumed: Dictionary = {} # uid -> true : entrées déjà attribuées pendant cette session
var _live: Dictionary = {}     # window_id -> {"key": clé de niveau, "uid": uid de l'entrée}
var _pending_pin: Dictionary = {} # window_id -> true : à épingler dès la première image
var _session: Array = []       # [{pid, cmd, bin, app_id}] : apps ouvertes (dernière écriture / session précédente)
var _frozen := false           # le jeu quitte : la liste de session n'est plus reconstruite
var _dirty := false
var _save_cd := 0.0
var _poll_cd := 0.0

func setup(p_compositor: Object, p_win3d: Node, p_focus: Node, p_pins: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	pins = p_pins
	_load()

func _process(delta: float) -> void:
	_poll_cd -= delta
	if _poll_cd <= 0.0:
		_poll_cd = POLL_INTERVAL
		for id in _live.keys():
			_snapshot(int(id))
	if _dirty:
		_save_cd -= delta
		if _save_cd <= 0.0:
			save_now()

func _exit_tree() -> void:
	for id in _live.keys():
		_snapshot(int(id))
	if _dirty:
		save_now()

func _active() -> bool:
	return (not enabled.is_valid() or bool(enabled.call())) and _key() != ""

func _key() -> String:
	return String(level_key.call()) if level_key.is_valid() else ""

# ── Cycle de vie des fenêtres ──────────────────────────────────────────

func on_window_created(id: int, _quad: Node) -> void:
	var app_id := String(win3d.window_app_ids.get(id, ""))
	if app_id == "" or compositor.get_window_parent_id(id) != -1:
		return
	# Disposition inactive (option coupée, niveau d'hôte LAN) : la fenêtre est quand même suivie pour la
	# reprise de session, sans entrée de disposition (uid vide).
	if not _active():
		_live[id] = {"key": "", "uid": ""}
		_resolve_launch(id)
		_mark_dirty()
		return
	var key := _key()
	var entries: Array = _data.get(key, [])
	var title := String(win3d.window_titles.get(id, ""))
	var idx := match_entry(entries, app_id, title, _consumed)
	var entry: Dictionary
	if idx == -1:
		entry = {"uid": _new_uid(), "app_id": app_id, "title": title}
		entries.append(entry)
		_data[key] = entries
	else:
		entry = entries[idx]
		_apply(id, entry)
	_consumed[entry["uid"]] = true
	_live[id] = {"key": key, "uid": entry["uid"]}
	_resolve_launch(id)
	_mark_dirty()

func on_window_unmapped(id: int) -> void:
	if _live.has(id):
		_snapshot(id)
		if not _frozen:
			_live.erase(id)
			_mark_dirty()
	_pending_pin.erase(id)

func on_window_texture_updated(id: int, texture: Texture2D, _w: int, _h: int) -> void:
	if _pending_pin.has(id) and texture != null:
		_pending_pin.erase(id)
		if not pins.is_pinned(id):
			pins.pin(id, texture)

func _apply(id: int, entry: Dictionary) -> void:
	var xform: Variant = array_to_transform(entry.get("transform", []))
	if xform != null:
		win3d.apply_saved_layout(id, xform, array_to_vec2(entry.get("size", [])), bool(entry.get("user_sized", false)))
	if bool(entry.get("user_sized", false)):
		var px := array_to_vec2(entry.get("surface_size", []))
		if px.x >= 1.0 and px.y >= 1.0:
			compositor.set_window_size(id, int(px.x), int(px.y))
	if bool(entry.get("hidden", false)):
		win3d.toggle_hide(id)
	var fg := int(entry.get("force_game", -1))
	if fg != -1:
		focus.set_force_game(id, fg == 1)
	if bool(entry.get("pinned", false)):
		_pending_pin[id] = true

## Relève l'état d'une fenêtre vivante. Ignorée pendant le mode focus (la fenêtre est figée / plein écran) et
## pendant un déplacement ou un redimensionnement : son entrée garde le dernier état stable.
func _snapshot(id: int) -> void:
	var live: Dictionary = _live.get(id, {})
	if live.is_empty():
		return
	if not live.has("cmd"):
		_resolve_launch(id)      # X11 : le PID réel n'est parfois connu qu'après le map
	if focus.is_active() and focus.focus_stack.has(id):
		return
	if bool(win3d.get("is_moving")) or bool(win3d.get("is_resizing")):
		return
	var lay: Dictionary = win3d.get_window_layout(id)
	if lay.is_empty():
		return
	var entry := _find(String(live["key"]), String(live["uid"]))
	if entry.is_empty():
		return
	var fresh := {
		"transform": transform_to_array(lay["transform"]),
		"size": vec2_to_array(lay["size"]),
		"user_sized": bool(lay["user_sized"]),
		"surface_size": vec2_to_array(lay["surface_size"]),
		"hidden": bool(lay["hidden"]),
		"pinned": bool(pins.is_pinned(id)),
		"force_game": int(focus.get_force_game(id)),
		"title": String(win3d.window_titles.get(id, entry.get("title", ""))),
	}
	var changed := false
	for k in fresh:
		if entry.get(k) != fresh[k]:
			entry[k] = fresh[k]
			changed = true
	if changed:
		entry["last_seen"] = int(Time.get_unix_time_from_system())
		_mark_dirty()

func _find(key: String, uid: String) -> Dictionary:
	for e in _data.get(key, []):
		if String(e.get("uid", "")) == uid:
			return e
	return {}

func _mark_dirty() -> void:
	if not _dirty:
		_save_cd = SAVE_DEBOUNCE
	_dirty = true

# ── Reprise de session ─────────────────────────────────────────────────

## Retient comment relancer l'application de la fenêtre (une fois connu son PID).
func _resolve_launch(id: int) -> void:
	var live: Dictionary = _live.get(id, {})
	if live.is_empty() or live.has("cmd"):
		return
	var pid := int(compositor.get_window_pid(id))
	if pid <= 0:
		return
	var info: Dictionary = compositor.get_process_info(pid)
	if not launchable(info, OS.get_executable_path()):
		return
	live["pid"] = pid
	live["cmd"] = build_command(info)
	live["bin"] = launch_bin(info)

func _session_from_live() -> Array:
	var out: Array = []
	var seen := {}
	for id in _live:
		var live: Dictionary = _live[id]
		if not live.has("cmd") or seen.has(live["pid"]):
			continue
		seen[live["pid"]] = true
		out.append({"pid": live["pid"], "cmd": live["cmd"], "bin": live["bin"],
			"app_id": String(win3d.window_app_ids.get(id, ""))})
	return out

## Le jeu quitte : fige la liste des apps ouvertes AVANT que shutdown_apps() ne les ferme, et l'écrit.
func freeze_session() -> void:
	for id in _live.keys():
		_snapshot(int(id))
	_session = _session_from_live()
	_frozen = true
	save_now()

## Démarrage : relance les apps ouvertes à la fin de la session précédente (sauf celles des startup apps).
## Renvoie les commandes lancées.
func restore_session(startup_commands: Array) -> Array:
	if reopen.is_valid() and not bool(reopen.call()):
		return []
	var cmds := session_commands(_session, startup_commands)
	for cmd in cmds:
		compositor.launch_app(cmd)
	if not cmds.is_empty():
		print("window_layouts: reprise de session, %d app(s) relancée(s)" % cmds.size())
	return cmds

# ── Persistance ────────────────────────────────────────────────────────

func save_now() -> void:
	_dirty = false
	if not _frozen:
		_session = _session_from_live()
	var out := {}
	for key in _data:
		var kept := trim_entries(_data[key], MAX_ENTRIES)
		# Entrées jamais relevées (fenêtre fermée avant le premier relevé) : rien à retrouver.
		kept = kept.filter(func(e): return e.has("transform"))
		if not kept.is_empty():
			out[key] = kept
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("window_layouts: impossible d'écrire %s" % save_path)
		return
	f.store_string(JSON.stringify({"version": 2, "levels": out, "session": _session}, "\t"))

func _load() -> void:
	_data = {}
	if not FileAccess.file_exists(save_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if not parsed is Dictionary:
		push_warning("window_layouts: %s illisible, ignoré" % save_path)
		return
	# Version 2 : {version, levels, session} ; version 1 : directement les niveaux.
	if parsed.has("levels") and parsed["levels"] is Dictionary:
		var sess: Variant = parsed.get("session", [])
		if sess is Array:
			_session = (sess as Array).filter(func(e): return e is Dictionary and e.get("cmd") is String)
		parsed = parsed["levels"]
	for key in parsed:
		if parsed[key] is Array:
			var entries: Array = []
			for e in parsed[key]:
				if e is Dictionary and e.has("app_id"):
					if not e.has("uid"):
						e["uid"] = _new_uid()
					entries.append(e)
			_data[String(key)] = entries

func _new_uid() -> String:
	return "%x%x" % [Time.get_ticks_usec(), randi()]

# ── Logique pure (testée) ──────────────────────────────────────────────

## Index de l'entrée à attribuer à une nouvelle fenêtre, -1 si aucune. Parmi les entrées du même app_id pas encore
## attribuées : titre identique, sinon titre inclus dans l'autre, sinon n'importe laquelle ; à égalité, la plus récente.
static func match_entry(entries: Array, app_id: String, title: String, consumed: Dictionary) -> int:
	var best := -1
	var best_score := -1
	var best_seen := -1
	for i in entries.size():
		var e: Dictionary = entries[i]
		if String(e.get("app_id", "")) != app_id or consumed.has(e.get("uid", "")):
			continue
		var t := String(e.get("title", ""))
		var score := 1
		if t == title:
			score = 3
		elif t != "" and title != "" and (t.contains(title) or title.contains(t)):
			score = 2
		var seen := int(e.get("last_seen", 0))
		if score > best_score or (score == best_score and seen > best_seen):
			best = i
			best_score = score
			best_seen = seen
	return best

## Les `max_entries` entrées les plus récentes (last_seen décroissant).
static func trim_entries(entries: Array, max_entries: int) -> Array:
	var sorted := entries.duplicate()
	sorted.sort_custom(func(a, b): return int(a.get("last_seen", 0)) > int(b.get("last_seen", 0)))
	return sorted.slice(0, max_entries)

static func transform_to_array(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z]

## Transform3D, ou null si le tableau est invalide.
static func array_to_transform(a: Variant) -> Variant:
	if not a is Array or (a as Array).size() != 12:
		return null
	for v in a:
		if not (v is float or v is int):
			return null
	var b := Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8]))
	if is_zero_approx(b.determinant()):
		return null
	return Transform3D(b, Vector3(a[9], a[10], a[11]))

## Une app relançable : un argv, et ni le satellite XWayland (PID non résolu) ni le jeu lui-même.
static func launchable(info: Dictionary, game_exe: String) -> bool:
	var argv: Variant = info.get("argv", PackedStringArray())
	if not (argv is PackedStringArray or argv is Array) or argv.is_empty():
		return false
	if String(info.get("comm", "")).begins_with("xwayland-satel"):
		return false
	return String(info.get("exe", "")) != game_exe

static func shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

## Commande shell qui relance l'app dans son dossier courant (Flatpak : par son identifiant).
static func build_command(info: Dictionary) -> String:
	var run := ""
	var flatpak := String(info.get("flatpak_id", ""))
	if flatpak != "":
		run = "flatpak run " + shell_quote(flatpak)
	else:
		var parts: Array = []
		for a in info.get("argv", []):
			parts.append(shell_quote(String(a)))
		run = " ".join(parts)
	var cwd := String(info.get("cwd", ""))
	if cwd != "":
		return "cd %s 2>/dev/null; exec %s" % [shell_quote(cwd), run]
	return "exec " + run

## Nom de l'exécutable (pour ne pas doubler une startup app).
static func launch_bin(info: Dictionary) -> String:
	var flatpak := String(info.get("flatpak_id", ""))
	if flatpak != "":
		return flatpak
	var argv: Variant = info.get("argv", [])
	return String(argv[0]).get_file() if not argv.is_empty() else ""

## Commandes à relancer : une par processus de la session, sauf les exécutables déjà lancés comme startup apps.
static func session_commands(session: Array, startup_commands: Array) -> Array:
	var startup_bins := {}
	for c in startup_commands:
		var first := String(c).strip_edges().split(" ", false)
		if not first.is_empty():
			startup_bins[first[0].get_file()] = true
		if String(c).strip_edges().begins_with("flatpak run "):
			var p := String(c).strip_edges().split(" ", false)
			if p.size() >= 3:
				startup_bins[p[2]] = true
	var out: Array = []
	var seen_pid := {}
	for e in session:
		var pid: Variant = e.get("pid", -1)
		if seen_pid.has(pid) or startup_bins.has(String(e.get("bin", ""))):
			continue
		seen_pid[pid] = true
		out.append(String(e["cmd"]))
	return out

static func vec2_to_array(v: Vector2) -> Array:
	return [v.x, v.y]

static func array_to_vec2(a: Variant) -> Vector2:
	if a is Array and (a as Array).size() == 2 and (a[0] is float or a[0] is int) and (a[1] is float or a[1] is int):
		return Vector2(a[0], a[1])
	return Vector2.ZERO
