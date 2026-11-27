extends Node
## Annotations sur une fenêtre partagée (lot K).
##
## Module de LanManager (nœud enfant « Annotations »). Tout joueur qui voit une fenêtre PARTAGÉE (propriétaire
## compris) peut y dessiner. Un trait = {author, color, width, points: [(u, v)…], ended, ended_at} en
## coordonnées normalisées de la fenêtre : un redimensionnement garde l'alignement approximatif ; un défilement du
## contenu ne déplace pas les traits (limite connue).
##
## Réseau (fiable, canal 1, relayé par l'hôte) : _stroke_begin, _stroke_points (toutes les FLUSH_SEC), _stroke_end,
## _stroke_erase (ses propres traits), _annot_clear (propriétaire seulement). Bornes : MAX_POINTS par trait,
## MAX_STROKES par fenêtre, MAX_MSG_PER_SEC par pair. Tous les traits sont éphémères : effacés EPHEMERAL_SEC après
## la fin du trait (rien à transmettre à un arrivant). Tout disparaît à
## l'arrêt du partage ou à la fermeture de la fenêtre. Interdit en session par code d'invitation non approuvée (window_share_restricted).
## Le rendu est fait par scripts/windows/annotations_view.gd (signal strokes_changed).

signal strokes_changed(owner: int, wid: int)

const MAX_POINTS := 2000
const MAX_STROKES := 200
const MAX_MSG_PER_SEC := 40
const MAX_POINTS_PER_MSG := 256
const EPHEMERAL_SEC := 4.0
const FLUSH_SEC := 0.05
const MIN_WIDTH := 1.0
const MAX_WIDTH := 24.0

var lan = null
var win3d: Node = null                   # fenêtres locales (is_window_shared, quads)

var _windows: Dictionary = {}            # "owner:wid" -> {"author:sid": stroke}
var _budget: Dictionary = {}             # peer -> {t, n}
var _next_sid := 1
var _drawing: Dictionary = {}            # trait en cours (local) : {owner, wid, sid, sent}
var _flush_cd := 0.0

static func wkey(owner: int, wid: int) -> String:
	return "%d:%d" % [owner, wid]

func my_id() -> int:
	return multiplayer.get_unique_id() if is_inside_tree() and multiplayer.has_multiplayer_peer() else 1

func strokes(owner: int, wid: int) -> Dictionary:
	return _windows.get(wkey(owner, wid), {})

func _net_ok() -> bool:
	return is_inside_tree() and multiplayer.has_multiplayer_peer() and lan != null and lan.is_session_active() \
		and not lan.window_share_restricted()

## La fenêtre est-elle partagée (donc annotable) ? Locale : partage actif ; distante : contenu partagé.
func is_annotatable(owner: int, wid: int) -> bool:
	if lan == null or not lan.is_session_active() or lan.window_share_restricted():
		return false
	if owner == my_id():
		return win3d != null and win3d.has_method("is_window_shared") and win3d.is_window_shared(wid)
	return lan.has_method("is_remote_window_shared") and lan.is_remote_window_shared(owner, wid)

# ── Dessin local ────────────────────────────────────────────────────────

func begin_stroke(owner: int, wid: int, color: Color, width: float, uv: Vector2) -> void:
	if not is_annotatable(owner, wid):
		return
	end_stroke()
	var sid := _next_sid
	_next_sid += 1
	var me := my_id()
	var s := {"author": me, "color": color, "width": clampf(width, MIN_WIDTH, MAX_WIDTH),
		"points": PackedVector2Array([uv]), "ended": false, "ended_at": 0.0}
	if not _store(owner, wid, "%d:%d" % [me, sid], s):
		return
	_drawing = {"owner": owner, "wid": wid, "sid": sid, "sent": 1}
	if _net_ok():
		_stroke_begin.rpc(owner, wid, sid, color, s["width"], uv)
	strokes_changed.emit(owner, wid)

func add_point(uv: Vector2) -> void:
	if _drawing.is_empty():
		return
	var s: Dictionary = strokes(_drawing["owner"], _drawing["wid"]).get("%d:%d" % [my_id(), _drawing["sid"]], {})
	if s.is_empty() or (s["points"] as PackedVector2Array).size() >= MAX_POINTS:
		return
	var pts: PackedVector2Array = s["points"]
	if pts.size() > 0 and pts[pts.size() - 1].distance_to(uv) < 0.002:
		return                                    # point quasi identique : inutile
	pts.append(uv.clamp(Vector2.ZERO, Vector2.ONE))
	s["points"] = pts
	strokes_changed.emit(_drawing["owner"], _drawing["wid"])

func end_stroke() -> void:
	if _drawing.is_empty():
		return
	_flush()
	var d := _drawing
	_drawing = {}
	var s: Dictionary = strokes(d["owner"], d["wid"]).get("%d:%d" % [my_id(), d["sid"]], {})
	if not s.is_empty():
		s["ended"] = true
		s["ended_at"] = _now()
	if _net_ok():
		_stroke_end.rpc(d["owner"], d["wid"], d["sid"])

func is_drawing() -> bool:
	return not _drawing.is_empty()

## Gomme : efface MES traits qui passent à moins de `radius` (en uv) du point.
func erase_near(owner: int, wid: int, uv: Vector2, radius := 0.02) -> void:
	var me := my_id()
	var hit: Array = []
	for k in strokes(owner, wid):
		var s: Dictionary = strokes(owner, wid)[k]
		if int(s["author"]) != me:
			continue
		for p in (s["points"] as PackedVector2Array):
			if p.distance_to(uv) <= radius:
				hit.append(int(String(k).split(":")[1]))
				break
	for sid in hit:
		_remove(owner, wid, "%d:%d" % [me, sid])
		if _net_ok():
			_stroke_erase.rpc(owner, wid, sid)
	if not hit.is_empty():
		strokes_changed.emit(owner, wid)

## Efface tout (propriétaire de la fenêtre seulement).
func clear(owner: int, wid: int) -> void:
	if owner != my_id():
		return
	_windows.erase(wkey(owner, wid))
	if _net_ok():
		_annot_clear.rpc(owner, wid)
	strokes_changed.emit(owner, wid)

func _flush() -> void:
	if _drawing.is_empty():
		return
	var s: Dictionary = strokes(_drawing["owner"], _drawing["wid"]).get("%d:%d" % [my_id(), _drawing["sid"]], {})
	if s.is_empty():
		return
	var pts: PackedVector2Array = s["points"]
	var sent: int = _drawing["sent"]
	while sent < pts.size():
		var chunk := pts.slice(sent, mini(sent + MAX_POINTS_PER_MSG, pts.size()))
		if _net_ok():
			_stroke_points.rpc(_drawing["owner"], _drawing["wid"], _drawing["sid"], chunk)
		sent += chunk.size()
	_drawing["sent"] = sent

# ── Stockage ────────────────────────────────────────────────────────────

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _store(owner: int, wid: int, key: String, s: Dictionary) -> bool:
	var k := wkey(owner, wid)
	var w: Dictionary = _windows.get(k, {})
	if w.size() >= MAX_STROKES and not w.has(key):
		return false
	w[key] = s
	_windows[k] = w
	return true

func _remove(owner: int, wid: int, key: String) -> void:
	var k := wkey(owner, wid)
	var w: Dictionary = _windows.get(k, {})
	w.erase(key)
	if w.is_empty():
		_windows.erase(k)

# ── Réseau ──────────────────────────────────────────────────────────────

## Garde commune : session non en ligne, cadence du pair, types de base.
func _accept(from: int, owner: Variant, wid: Variant) -> bool:
	if from <= 0 or lan == null or lan.window_share_restricted() or not (owner is int) or not (wid is int):
		return false
	var now := Time.get_ticks_msec()
	var b: Dictionary = _budget.get(from, {"t": now, "n": 0})
	if now - int(b["t"]) >= 1000:
		b = {"t": now, "n": 0}
	b["n"] = int(b["n"]) + 1
	_budget[from] = b
	return int(b["n"]) <= MAX_MSG_PER_SEC

@rpc("any_peer", "call_remote", "reliable", 1)
func _stroke_begin(owner: Variant, wid: Variant, sid: Variant, color: Variant, width: Variant, uv: Variant) -> void:
	_on_begin(multiplayer.get_remote_sender_id(), owner, wid, sid, color, width, uv)

func _on_begin(from: int, owner: Variant, wid: Variant, sid: Variant, color: Variant, width: Variant, uv: Variant) -> void:
	if not _accept(from, owner, wid) or not (sid is int) or not (color is Color) or not (width is float) \
			or not (uv is Vector2):
		return
	if not is_annotatable(owner, wid):
		return
	var c: Color = color
	c.a = 1.0
	if _store(owner, wid, "%d:%d" % [from, sid], {"author": from, "color": c, "width": clampf(width, MIN_WIDTH, MAX_WIDTH),
			"points": PackedVector2Array([(uv as Vector2).clamp(Vector2.ZERO, Vector2.ONE)]), "ended": false, "ended_at": 0.0}):
		strokes_changed.emit(owner, wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _stroke_points(owner: Variant, wid: Variant, sid: Variant, pts: Variant) -> void:
	_on_points(multiplayer.get_remote_sender_id(), owner, wid, sid, pts)

func _on_points(from: int, owner: Variant, wid: Variant, sid: Variant, pts: Variant) -> void:
	if not _accept(from, owner, wid) or not (sid is int) or not (pts is PackedVector2Array):
		return
	if (pts as PackedVector2Array).size() > MAX_POINTS_PER_MSG:
		return
	var s: Dictionary = strokes(owner, wid).get("%d:%d" % [from, sid], {})
	if s.is_empty() or bool(s["ended"]):
		return
	var cur: PackedVector2Array = s["points"]
	for p in (pts as PackedVector2Array):
		if cur.size() >= MAX_POINTS:
			break
		cur.append(p.clamp(Vector2.ZERO, Vector2.ONE))
	s["points"] = cur
	strokes_changed.emit(owner, wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _stroke_end(owner: Variant, wid: Variant, sid: Variant) -> void:
	_on_end(multiplayer.get_remote_sender_id(), owner, wid, sid)

func _on_end(from: int, owner: Variant, wid: Variant, sid: Variant) -> void:
	if not _accept(from, owner, wid) or not (sid is int):
		return
	var s: Dictionary = strokes(owner, wid).get("%d:%d" % [from, sid], {})
	if not s.is_empty():
		s["ended"] = true
		s["ended_at"] = _now()

@rpc("any_peer", "call_remote", "reliable", 1)
func _stroke_erase(owner: Variant, wid: Variant, sid: Variant) -> void:
	_on_erase(multiplayer.get_remote_sender_id(), owner, wid, sid)

func _on_erase(from: int, owner: Variant, wid: Variant, sid: Variant) -> void:
	if not _accept(from, owner, wid) or not (sid is int):
		return
	if strokes(owner, wid).has("%d:%d" % [from, sid]):          # seulement SES traits (clé = émetteur)
		_remove(owner, wid, "%d:%d" % [from, sid])
		strokes_changed.emit(owner, wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _annot_clear(owner: Variant, wid: Variant) -> void:
	_on_clear(multiplayer.get_remote_sender_id(), owner, wid)

func _on_clear(from: int, owner: Variant, wid: Variant) -> void:
	if not _accept(from, owner, wid) or from != owner:            # le propriétaire seulement
		return
	if _windows.erase(wkey(owner, wid)):
		strokes_changed.emit(owner, wid)

# ── Boucle : envoi groupé, traits éphémères, fin de partage ────────────

func _process(delta: float) -> void:
	_flush_cd -= delta
	if _flush_cd <= 0.0:
		_flush_cd = FLUSH_SEC
		_flush()
	if _windows.is_empty():
		return
	var now := _now()
	for k in _windows.keys():
		var p := String(k).split(":")
		var owner := int(p[0])
		var wid := int(p[1])
		if not is_annotatable(owner, wid):
			_windows.erase(k)                     # partage arrêté, fenêtre fermée, session finie
			strokes_changed.emit(owner, wid)
			continue
		var changed := false
		var w: Dictionary = _windows[k]
		for sk in w.keys():
			var s: Dictionary = w[sk]
			if bool(s["ended"]) and now - float(s["ended_at"]) > EPHEMERAL_SEC:
				w.erase(sk)
				changed = true
		if w.is_empty():
			_windows.erase(k)
		if changed:
			strokes_changed.emit(owner, wid)

func reset() -> void:
	var keys := _windows.keys()
	_windows.clear()
	_drawing = {}
	for k in keys:
		var p := String(k).split(":")
		strokes_changed.emit(int(p[0]), int(p[1]))
