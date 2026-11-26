extends Node
## Prise de contrôle d'une fenêtre partagée (lot J).
##
## Module de LanManager (nœud enfant « RemoteControl »). Un joueur qui regarde une fenêtre PARTAGÉE d'un autre
## demande le contrôle ; le propriétaire voit une demande explicite (scripts/ui/control_request.gd) et accepte ou
## refuse (refus automatique au bout de REQUEST_TIMEOUT_MSEC). Un seul invité par fenêtre. Le propriétaire reprend la
## main quand il veut (menu radial), en arrêtant le partage ou en fermant la fenêtre ; la déconnexion de l'invité le
## révoque aussi.
##
## Entrées de l'invité : pointeur en coordonnées NORMALISÉES (u, v) de la fenêtre (non fiable, canal 3, une fois par
## frame), boutons / molette / touches (fiables, canal 1). Chez le propriétaire elles vont DIRECTEMENT au compositeur,
## jamais par la carte des keybinds du jeu : ni raccourci du jeu ni bind personnalisé. Ctrl+Alt+F1…F12 (changement
## de VT) filtré. Bornes : MAX_POINTER_PER_SEC, MAX_INPUT_PER_SEC ; au-delà, ignoré. Interdit en session en ligne
## (online_restricted, comme les partages). Un seul seat : l'invité et le propriétaire partagent clavier et pointeur
## du compositeur (une touche de l'invité donne le focus clavier à la fenêtre contrôlée).

signal control_requested(peer: int, wid: int)              # propriétaire : afficher la demande
signal control_changed(owner: int, wid: int, active: bool)       # invité : contrôle accordé / refusé / retiré
signal guest_control_changed(guest: int, wid: int, active: bool) # propriétaire : un invité contrôle (plus) ma fenêtre

const REQUEST_TIMEOUT_MSEC := 15000
const MAX_POINTER_PER_SEC := 120
const MAX_INPUT_PER_SEC := 120            # boutons, molette et touches (appui + relâchement : 60 touches/s)
const BUTTONS := [0x110, 0x111, 0x112, 0x113, 0x114]      # BTN_LEFT, RIGHT, MIDDLE, SIDE, EXTRA
const MAX_AXIS := 1200.0
const VT_KEYS := [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12]

var lan = null                    # LanManager (non typé : doublure possible dans les tests)
var win3d: Node = null            # windows_3d (posé par wayland_room) : fenêtres partagées, quads

# ── Propriétaire ──
var _grants: Dictionary = {}      # wid -> peer
var _pending: Dictionary = {}     # wid -> {peer, t}
var _budget: Dictionary = {}      # peer -> {t, ptr, inp}
var _held: Dictionary = {}        # wid -> {"k:<code>:<loc>": [code, loc], "b:<button>": button}
var _mods: Dictionary = {}        # wid -> {ctrl, alt}
var _markers: Dictionary = {}     # wid -> [Node3D, Control|null] (pointeur de l'invité)

# ── Invité ──
var _controlling: Dictionary = {} # "peer:wid" -> true
var _requested: Dictionary = {}   # "peer:wid" -> t
var _pending_ptr: Dictionary = {} # "peer:wid" -> Vector2
var _down: Dictionary = {}        # "peer:wid" -> {"k:..": [code, loc], "b:..": button} (relâchés en sortie)

func _now() -> int:
	return Time.get_ticks_msec()

func _can_net() -> bool:
	return is_inside_tree() and multiplayer.has_multiplayer_peer() and lan != null and lan.is_session_active() \
		and not lan.online_restricted()

static func key_of(peer: int, wid: int) -> String:
	return "%d:%d" % [peer, wid]

# ════════════════════════════════════════════════════════════════════════
# Invité
# ════════════════════════════════════════════════════════════════════════

func is_controlling(peer: int, wid: int) -> bool:
	return _controlling.has(key_of(peer, wid))

func is_requested(peer: int, wid: int) -> bool:
	return _requested.has(key_of(peer, wid))

func request_control(peer: int, wid: int) -> bool:
	if not _can_net() or is_controlling(peer, wid) or is_requested(peer, wid):
		return false
	_requested[key_of(peer, wid)] = _now()
	_rc_request.rpc_id(peer, wid)
	return true

func release_control(peer: int, wid: int) -> void:
	var k := key_of(peer, wid)
	if not _controlling.has(k):
		return
	release_inputs(peer, wid)
	_controlling.erase(k)
	_pending_ptr.erase(k)
	if _can_net():
		_rc_release.rpc_id(peer, wid)
	control_changed.emit(peer, wid, false)

func send_pointer(peer: int, wid: int, uv: Vector2) -> void:
	if is_controlling(peer, wid):
		_pending_ptr[key_of(peer, wid)] = uv.clamp(Vector2.ZERO, Vector2.ONE)

func send_button(peer: int, wid: int, button: int, pressed: bool) -> void:
	if not is_controlling(peer, wid) or not _can_net():
		return
	_flush_pointer(key_of(peer, wid))               # le clic part à la dernière position
	_track(key_of(peer, wid), "b:%d" % button, button, pressed)
	_rc_button.rpc_id(peer, wid, button, pressed)

func send_axis(peer: int, wid: int, dx: float, dy: float) -> void:
	if is_controlling(peer, wid) and _can_net():
		_flush_pointer(key_of(peer, wid))
		_rc_axis.rpc_id(peer, wid, dx, dy)

func send_key(peer: int, wid: int, code: int, location: int, pressed: bool) -> void:
	if not is_controlling(peer, wid) or not _can_net():
		return
	_track(key_of(peer, wid), "k:%d:%d" % [code, location], [code, location], pressed)
	_rc_key.rpc_id(peer, wid, code, location, pressed)

func _track(k: String, id: String, value: Variant, pressed: bool) -> void:
	var d: Dictionary = _down.get(k, {})
	if pressed:
		d[id] = value
	else:
		d.erase(id)
	_down[k] = d

## Relâche tout ce que l'invité tient enfoncé (sortie du mode focus, fin du contrôle).
func release_inputs(peer: int, wid: int) -> void:
	var k := key_of(peer, wid)
	var d: Dictionary = _down.get(k, {})
	_down.erase(k)
	if d.is_empty() or not _can_net():
		return
	for id in d:
		if String(id).begins_with("b:"):
			_rc_button.rpc_id(peer, wid, int(d[id]), false)
		else:
			_rc_key.rpc_id(peer, wid, int(d[id][0]), int(d[id][1]), false)

func _flush_pointer(k: String) -> void:
	if not _pending_ptr.has(k) or not _can_net():
		return
	var uv: Vector2 = _pending_ptr[k]
	_pending_ptr.erase(k)
	var p := k.split(":")
	_rc_pointer.rpc_id(int(p[0]), int(p[1]), uv.x, uv.y)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_answer(wid: Variant, granted: Variant) -> void:
	_on_answer(multiplayer.get_remote_sender_id(), wid, granted)

func _on_answer(from: int, wid: Variant, granted: Variant) -> void:
	if not (wid is int) or not (granted is bool):
		return
	var k := key_of(from, wid)
	if not _requested.has(k):
		return
	_requested.erase(k)
	if granted:
		_controlling[k] = true
	control_changed.emit(from, wid, granted)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_revoke(wid: Variant) -> void:
	_on_revoke(multiplayer.get_remote_sender_id(), wid)

func _on_revoke(from: int, wid: Variant) -> void:
	if not (wid is int):
		return
	var k := key_of(from, wid)
	_requested.erase(k)
	if _controlling.erase(k):
		_pending_ptr.erase(k)
		_down.erase(k)
		control_changed.emit(from, wid, false)

# ════════════════════════════════════════════════════════════════════════
# Propriétaire
# ════════════════════════════════════════════════════════════════════════

func controller_of(wid: int) -> int:
	return int(_grants.get(wid, -1))

func _is_shared(wid: int) -> bool:
	return win3d != null and win3d.has_method("is_window_shared") and win3d.is_window_shared(wid) \
		and win3d.quads.has(wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_request(wid: Variant) -> void:
	_on_request(multiplayer.get_remote_sender_id(), wid)

func _on_request(from: int, wid: Variant) -> void:
	if not (wid is int) or from <= 0 or lan == null or lan.online_restricted():
		return
	# Une demande à la fois (une seule boîte de dialogue), fenêtre partagée, pas déjà contrôlée.
	if not _is_shared(wid) or _grants.has(wid) or not _pending.is_empty():
		_send_answer(from, wid, false)
		return
	_pending[wid] = {"peer": from, "t": _now()}
	control_requested.emit(from, wid)

## Réponse du propriétaire (boîte de dialogue) ou refus automatique.
func answer(wid: int, accepted: bool) -> void:
	var p: Dictionary = _pending.get(wid, {})
	if p.is_empty():
		return
	_pending.erase(wid)
	var peer := int(p["peer"])
	var ok := accepted and _is_shared(wid) and not _grants.has(wid)
	if ok:
		_grants[wid] = peer
		_held[wid] = {}
		_mods[wid] = {"ctrl": false, "alt": false}
		guest_control_changed.emit(peer, wid, true)
	_send_answer(peer, wid, ok)

func _send_answer(peer: int, wid: int, ok: bool) -> void:
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		_rc_answer.rpc_id(peer, wid, ok)

## Le propriétaire reprend la main (ou fin du partage, fermeture, départ de l'invité).
func revoke(wid: int, notify := true) -> void:
	if not _grants.has(wid):
		return
	var peer := int(_grants[wid])
	_release_held(wid)
	_grants.erase(wid)
	_held.erase(wid)
	_mods.erase(wid)
	_remove_marker(wid)
	if notify and is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer):
		_rc_revoke.rpc_id(peer, wid)
	guest_control_changed.emit(peer, wid, false)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_release(wid: Variant) -> void:
	if wid is int and controller_of(wid) == multiplayer.get_remote_sender_id():
		revoke(wid, false)

func _allow(peer: int, kind: String) -> bool:
	var now := _now()
	var b: Dictionary = _budget.get(peer, {"t": now, "ptr": 0, "inp": 0})
	if now - int(b["t"]) >= 1000:
		b = {"t": now, "ptr": 0, "inp": 0}
	b[kind] = int(b[kind]) + 1
	_budget[peer] = b
	return int(b[kind]) <= (MAX_POINTER_PER_SEC if kind == "ptr" else MAX_INPUT_PER_SEC)

func _comp() -> Object:
	return lan.compositor if lan != null else null

@rpc("any_peer", "call_remote", "unreliable", 3)
func _rc_pointer(wid: Variant, u: Variant, v: Variant) -> void:
	_on_pointer(multiplayer.get_remote_sender_id(), wid, u, v)

func _on_pointer(from: int, wid: Variant, u: Variant, v: Variant) -> void:
	if not (wid is int) or not (u is float) or not (v is float) or controller_of(wid) != from or not _allow(from, "ptr"):
		return
	var uv := Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))
	var body := _body(wid)
	var comp := _comp()
	if body == null or comp == null:
		return
	var ss: Vector2 = body.get_meta("surface_size", Vector2.ZERO)
	var co: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var p := uv * ss + co
	comp.forward_pointer_motion(wid, p.x, p.y)
	_update_marker(wid, from, uv)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_button(wid: Variant, button: Variant, pressed: Variant) -> void:
	_on_button(multiplayer.get_remote_sender_id(), wid, button, pressed)

func _on_button(from: int, wid: Variant, button: Variant, pressed: Variant) -> void:
	if not (wid is int) or not (button is int) or not (pressed is bool) or controller_of(wid) != from:
		return
	if not BUTTONS.has(button) or not _allow(from, "inp"):
		return
	var held: Dictionary = _held.get(wid, {})
	var id := "b:%d" % button
	if pressed:
		held[id] = button
	elif not held.erase(id):
		return                          # relâchement orphelin
	_comp().forward_pointer_button(wid, button, pressed)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_axis(wid: Variant, dx: Variant, dy: Variant) -> void:
	_on_axis(multiplayer.get_remote_sender_id(), wid, dx, dy)

func _on_axis(from: int, wid: Variant, dx: Variant, dy: Variant) -> void:
	if not (wid is int) or not (dx is float) or not (dy is float) or controller_of(wid) != from or not _allow(from, "inp"):
		return
	_comp().forward_pointer_axis(wid, clampf(dx, -MAX_AXIS, MAX_AXIS), clampf(dy, -MAX_AXIS, MAX_AXIS))

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_key(wid: Variant, code: Variant, location: Variant, pressed: Variant) -> void:
	_on_key(multiplayer.get_remote_sender_id(), wid, code, location, pressed)

func _on_key(from: int, wid: Variant, code: Variant, location: Variant, pressed: Variant) -> void:
	if not (wid is int) or not (code is int) or not (location is int) or not (pressed is bool):
		return
	if controller_of(wid) != from or location < 0 or location > 3 or not _allow(from, "inp"):
		return
	var mods: Dictionary = _mods.get(wid, {"ctrl": false, "alt": false})
	if code == KEY_CTRL:
		mods["ctrl"] = pressed
	elif code == KEY_ALT:
		mods["alt"] = pressed
	_mods[wid] = mods
	if pressed and is_vt_switch(code, mods):
		return                          # changement de console : jamais depuis un invité
	var held: Dictionary = _held.get(wid, {})
	var id := "k:%d:%d" % [code, location]
	if pressed:
		held[id] = [code, location]
	elif not held.erase(id):
		return
	var comp := _comp()
	if pressed and comp.has_method("set_window_keyboard_focus"):
		comp.set_window_keyboard_focus(wid)    # un seul seat : la touche de l'invité va à la fenêtre contrôlée
	comp.forward_keyboard_key(code, location, pressed)

static func is_vt_switch(code: int, mods: Dictionary) -> bool:
	return VT_KEYS.has(code) and bool(mods.get("ctrl", false)) and bool(mods.get("alt", false))

func _release_held(wid: int) -> void:
	var held: Dictionary = _held.get(wid, {})
	var comp := _comp()
	if comp == null:
		return
	for id in held:
		if String(id).begins_with("b:"):
			comp.forward_pointer_button(wid, int(held[id]), false)
		else:
			comp.forward_keyboard_key(int(held[id][0]), int(held[id][1]), false)
	_held[wid] = {}

func _body(wid: int) -> Node:
	if win3d == null or not win3d.quads.has(wid) or not is_instance_valid(win3d.quads[wid]):
		return null
	var q: Node = win3d.quads[wid]
	return q.get_child(0) if q.get_child_count() > 0 else null

# ── Pointeur de l'invité chez le propriétaire ──────────────────────────
# Pastille à la couleur du joueur : sur le quad 3D et, si la fenêtre est affichée par le mode focus, sur son overlay.

func _peer_color(peer: int) -> Color:
	var info: Variant = lan._players.get(peer, {}) if lan != null else {}
	return info.get("color", Color(1, 0.6, 0.1)) if info is Dictionary else Color(1, 0.6, 0.1)

func _update_marker(wid: int, peer: int, uv: Vector2) -> void:
	if win3d == null or not win3d.quads.has(wid):
		return
	var quad: MeshInstance3D = win3d.quads[wid]
	var m: Array = _markers.get(wid, [])
	if m.is_empty() or not is_instance_valid(m[0]):
		var dot := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.012
		mesh.height = 0.024
		dot.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = _peer_color(peer)
		mat.no_depth_test = true
		dot.material_override = mat
		quad.add_child(dot)
		m = [dot, null]
	var size: Vector2 = (quad.mesh as QuadMesh).size if quad.mesh is QuadMesh else Vector2.ONE
	(m[0] as Node3D).position = Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.01)
	# Overlay du mode focus (TextureRect de la fenêtre).
	var rect: Control = null
	if lan != null and lan.focus != null and "focus_rects" in lan.focus:
		rect = lan.focus.focus_rects.get(wid)
	if rect != null and is_instance_valid(rect):
		if m[1] == null or not is_instance_valid(m[1]):
			var c := ColorRect.new()
			c.color = _peer_color(peer)
			c.size = Vector2(10, 10)
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rect.add_child(c)
			m[1] = c
		(m[1] as Control).position = uv * rect.size - Vector2(5, 5)
	_markers[wid] = m

func _remove_marker(wid: int) -> void:
	for n in _markers.get(wid, []):
		if n != null and is_instance_valid(n):
			n.queue_free()
	_markers.erase(wid)

# ── Boucle : envoi du pointeur, fins de contrôle, délais ───────────────

func _process(_delta: float) -> void:
	for k in _pending_ptr.keys():
		_flush_pointer(k)
	var now := _now()
	# Propriétaire : demande sans réponse = refus.
	for wid in _pending.keys():
		if now - int(_pending[wid]["t"]) > REQUEST_TIMEOUT_MSEC:
			answer(wid, false)
	# Propriétaire : fin de partage, fenêtre fermée, invité parti, session finie.
	var peers: Array = multiplayer.get_peers() if is_inside_tree() and multiplayer.has_multiplayer_peer() else []
	for wid in _grants.keys():
		if not _is_shared(wid) or not peers.has(int(_grants[wid])) or lan == null or not lan.is_session_active() \
				or lan.online_restricted():
			revoke(wid, peers.has(int(_grants[wid])))
	# Invité : demandes sans réponse oubliées, propriétaire parti.
	for k in _requested.keys():
		if now - int(_requested[k]) > REQUEST_TIMEOUT_MSEC + 5000:
			_requested.erase(k)
	for k in _controlling.keys():
		var owner := int(String(k).split(":")[0])
		if not peers.has(owner):
			_controlling.erase(k)
			_down.erase(k)
			var p := String(k).split(":")
			control_changed.emit(int(p[0]), int(p[1]), false)

## Fin de session : tout oublier.
func reset() -> void:
	for wid in _grants.keys():
		revoke(wid, false)
	_pending.clear()
	_controlling.clear()
	_requested.clear()
	_pending_ptr.clear()
	_down.clear()
	_budget.clear()
