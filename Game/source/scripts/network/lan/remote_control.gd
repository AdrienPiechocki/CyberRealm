extends Node
## Prise de contrôle d'une fenêtre partagée (lot J).
##
## Module de LanManager (nœud enfant « RemoteControl »). Un joueur qui regarde une fenêtre PARTAGÉE d'un autre
## demande le contrôle ; le propriétaire voit une demande explicite (scripts/ui/control_request.gd) et accepte ou
## refuse (refus automatique au bout de REQUEST_TIMEOUT_MSEC ; les demandes suivantes attendent leur tour). Plusieurs
## invités peuvent avoir la main sur la même fenêtre. Le propriétaire la reprend quand il veut (menu radial), en
## arrêtant le partage ou en fermant la fenêtre ; la déconnexion d'un invité révoque son contrôle.
##
## Siège : le compositeur n'a qu'UN pointeur et qu'UN clavier. Par fenêtre, ils vont à CELUI QUI A FAIT LA DERNIÈRE
## ACTION (bouton, molette, touche, mouvement réel de la souris) — un invité ou le propriétaire (0). Quand le siège
## change de main, ce que l'ancien acteur tenait enfoncé est relâché (pas de glisser ni de touche coincés). Le viseur
## immobile du propriétaire posé sur la fenêtre ne reprend pas le pointeur à un invité (owner_motion).
##
## Entrées de l'invité : pointeur en coordonnées NORMALISÉES (u, v) de la fenêtre (non fiable, canal 3, une fois par
## frame), boutons / molette / touches (fiables, canal 1). Chez le propriétaire elles vont DIRECTEMENT au compositeur,
## jamais par la carte des keybinds du jeu : ni raccourci du jeu ni bind personnalisé. Ctrl+Alt+F1…F12 (changement
## de VT) filtré. Bornes : MAX_POINTER_PER_SEC, MAX_INPUT_PER_SEC ; au-delà, ignoré. Interdit en session par code d'invitation non approuvée
## (window_share_restricted, comme le partage de fenêtres). Un seul seat : l'invité et le propriétaire partagent clavier et pointeur
## du compositeur (une touche de l'invité donne le focus clavier à la fenêtre contrôlée).
##
## Fenêtre de jeu FPS : quand l'application verrouille le pointeur (zwp_pointer_constraints_v1, ex. caméra d'un FPS),
## le propriétaire le signale aux invités qui ont la main (fiable). L'invité capture alors sa souris et n'envoie plus
## que du mouvement RELATIF (somme par frame, non fiable, canal 3) ; le propriétaire le transmet par
## forward_pointer_relative_motion et jette tout mouvement absolu (le client le traduirait en saut de caméra).

signal control_requested(peer: int, wid: int)              # propriétaire : afficher la demande
signal control_changed(owner: int, wid: int, active: bool)       # invité : contrôle accordé / refusé / retiré
signal guest_control_changed(guest: int, wid: int, active: bool) # propriétaire : un invité contrôle (plus) ma fenêtre

const REQUEST_TIMEOUT_MSEC := 15000
const MAX_POINTER_PER_SEC := 250        # borne chez le propriétaire : l'invité en envoie ≤ POINTER_SEND_HZ + un par clic
const POINTER_SEND_HZ := 150            # cadence d'envoi du pointeur par l'invité, quel que soit son plafond FPS
const MAX_INPUT_PER_SEC := 120            # boutons, molette et touches (appui + relâchement : 60 touches/s)
const BUTTONS := [0x110, 0x111, 0x112, 0x113, 0x114]      # BTN_LEFT, RIGHT, MIDDLE, SIDE, EXTRA
const MAX_AXIS := 1200.0
const MAX_RELATIVE := 4000.0             # px par envoi (somme d'une frame de souris)
const VT_KEYS := [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12]

var lan = null                    # LanManager (non typé : doublure possible dans les tests)
var win3d: Node = null            # windows_3d (posé par wayland_room) : fenêtres partagées, quads

# ── Propriétaire ──
const OWNER := 0                  # siège tenu par le propriétaire
var _grants: Dictionary = {}      # wid -> {peer: true} (invités qui ont la main)
var _seat: Dictionary = {}        # wid -> acteur de la dernière action (OWNER ou un invité)
var _pending: Array = []          # demandes en attente, la première est affichée : [{wid, peer, t}]
var _budget: Dictionary = {}      # peer -> {t, ptr, inp}
var _held: Dictionary = {}        # wid -> {"k:<code>:<loc>": [code, loc], "b:<button>": button} (de l'invité au siège)
var _mods: Dictionary = {}        # wid -> {ctrl, alt}
var _markers: Dictionary = {}     # "wid:peer" -> [Node3D, Control|null] (pointeur de chaque invité)
var _kbd_wid := -1                # fenêtre qui a reçu le focus clavier en dernier (touches du propriétaire)
var _owner_moved_frame := -100    # dernière frame où la souris du propriétaire a réellement bougé
var _lock_sent: Dictionary = {}   # "wid:peer" -> état de verrouillage du pointeur annoncé à cet invité

# ── Invité ──
var _controlling: Dictionary = {} # "peer:wid" -> true
var _requested: Dictionary = {}   # "peer:wid" -> t
var _pending_ptr: Dictionary = {} # "peer:wid" -> Vector2
var _pending_rel: Dictionary = {} # "peer:wid" -> Vector2 (mouvement relatif pas encore envoyé)
var _locked: Dictionary = {}      # "peer:wid" -> true : l'application a verrouillé le pointeur (jeu FPS)
var _diag := {"ptr_tx": 0, "rel_tx": 0, "ptr_rx": 0, "rel_rx": 0, "drop": 0}
var _diag_last := 0
var _ptr_next_usec: Dictionary = {} # "peer:wid" -> heure du prochain envoi du pointeur (cadence POINTER_SEND_HZ)
var _down: Dictionary = {}        # "peer:wid" -> {"k:..": [code, loc], "b:..": button} (relâchés en sortie)

func _now() -> int:
	return Time.get_ticks_msec()

func _can_net() -> bool:
	return is_inside_tree() and multiplayer.has_multiplayer_peer() and lan != null and lan.is_session_active() \
		and not lan.window_share_restricted()

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
	_forget_guest(k)
	if _can_net():
		_rc_release.rpc_id(peer, wid)
	control_changed.emit(peer, wid, false)

## L'application de la fenêtre contrôlée a verrouillé le pointeur : n'envoyer que du relatif (send_relative).
func is_locked(peer: int, wid: int) -> bool:
	return _locked.has(key_of(peer, wid))

func send_relative(peer: int, wid: int, d: Vector2) -> void:
	if is_controlling(peer, wid) and is_locked(peer, wid):
		var k := key_of(peer, wid)
		_pending_rel[k] = (_pending_rel.get(k, Vector2.ZERO) as Vector2) + d

func send_pointer(peer: int, wid: int, uv: Vector2) -> void:
	if is_controlling(peer, wid):
		_pending_ptr[key_of(peer, wid)] = uv.clamp(Vector2.ZERO, Vector2.ONE)

func send_button(peer: int, wid: int, button: int, pressed: bool) -> void:
	if not is_controlling(peer, wid) or not _can_net():
		return
	_flush_pointer(key_of(peer, wid))               # le clic part à la dernière position
	_flush_relative(key_of(peer, wid))
	_track(key_of(peer, wid), "b:%d" % button, button, pressed)
	_rc_button.rpc_id(peer, wid, button, pressed)

func send_axis(peer: int, wid: int, dx: float, dy: float) -> void:
	if is_controlling(peer, wid) and _can_net():
		_flush_pointer(key_of(peer, wid))
		_flush_relative(key_of(peer, wid))
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
	_diag["ptr_tx"] += 1

func _flush_relative(k: String) -> void:
	if not _pending_rel.has(k) or not _can_net():
		return
	var d: Vector2 = _pending_rel[k]
	_pending_rel.erase(k)
	if d == Vector2.ZERO:
		return
	var p := k.split(":")
	_rc_relative.rpc_id(int(p[0]), int(p[1]), d.x, d.y)
	_diag["rel_tx"] += 1

## Oubli de l'état invité d'une fenêtre (fin du contrôle).
func _forget_guest(k: String) -> void:
	_pending_ptr.erase(k)
	_pending_rel.erase(k)
	_locked.erase(k)
	_ptr_next_usec.erase(k)

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
		_forget_guest(k)
		_down.erase(k)
		control_changed.emit(from, wid, false)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_lock(wid: Variant, locked: Variant) -> void:
	_on_lock(multiplayer.get_remote_sender_id(), wid, locked)

func _on_lock(from: int, wid: Variant, locked: Variant) -> void:
	if not (wid is int) or not (locked is bool) or not is_controlling(from, wid):
		return
	var k := key_of(from, wid)
	print("[rc] pointeur %s par l'application (fenêtre %d de %d)" % ["verrouillé" if locked else "libéré", wid, from])
	if locked:
		_locked[k] = true
		_pending_ptr.erase(k)            # plus d'absolu vers un client verrouillé
	else:
		_locked.erase(k)
		_pending_rel.erase(k)

# ════════════════════════════════════════════════════════════════════════
# Propriétaire
# ════════════════════════════════════════════════════════════════════════

## Un invité qui a la main sur `wid` (celui qui tient le siège s'il y en a un), -1 sinon.
func controller_of(wid: int) -> int:
	var seat := int(_seat.get(wid, OWNER))
	if seat != OWNER:
		return seat
	var g: Dictionary = _grants.get(wid, {})
	return int(g.keys()[0]) if not g.is_empty() else -1

func controllers_of(wid: int) -> Array:
	return (_grants.get(wid, {}) as Dictionary).keys()

func has_control(wid: int, peer: int) -> bool:
	return (_grants.get(wid, {}) as Dictionary).has(peer)

## Acteur qui tient le siège de `wid` (OWNER = le propriétaire).
func seat_of(wid: int) -> int:
	return int(_seat.get(wid, OWNER))

## Le siège de `wid` passe à `actor` : ce que l'acteur précédent (invité) tenait enfoncé est relâché.
func _take_seat(wid: int, actor: int) -> void:
	if int(_seat.get(wid, OWNER)) == actor:
		return
	_release_held(wid)
	_mods[wid] = {"ctrl": false, "alt": false}
	_seat[wid] = actor

# ── Entrées du propriétaire (windows_3d/pointer.gd, focus/input.gd, wayland_room.gd) ──

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).relative != Vector2.ZERO:
		_owner_moved_frame = Engine.get_process_frames()

## Le propriétaire clique / fait défiler sur `wid` : il prend le siège.
func owner_action(wid: int) -> void:
	_kbd_wid = wid
	if _grants.has(wid):
		_take_seat(wid, OWNER)

## Mouvement du pointeur du propriétaire sur `wid` : true s'il doit être transmis. Un vrai mouvement de souris prend
## le siège ; un viseur immobile (le pointeur 3D est retransmis à chaque frame) ne le reprend pas à un invité.
func owner_motion(wid: int) -> bool:
	if not _grants.has(wid):
		return true
	if Engine.get_process_frames() - _owner_moved_frame <= 1:
		_take_seat(wid, OWNER)
		return true
	return int(_seat.get(wid, OWNER)) == OWNER

## Touche du propriétaire : elle va à la fenêtre qui a le focus clavier, qui revient au propriétaire.
func owner_key() -> void:
	if _grants.has(_kbd_wid):
		_take_seat(_kbd_wid, OWNER)

func _is_shared(wid: int) -> bool:
	return win3d != null and win3d.has_method("is_window_shared") and win3d.is_window_shared(wid) \
		and win3d.quads.has(wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_request(wid: Variant) -> void:
	_on_request(multiplayer.get_remote_sender_id(), wid)

func _on_request(from: int, wid: Variant) -> void:
	if not (wid is int) or from <= 0 or lan == null or lan.window_share_restricted():
		return
	# Fenêtre partagée, joueur qui n'a pas déjà la main ni de demande en attente. Une boîte de dialogue à la fois :
	# les demandes suivantes attendent leur tour.
	if not _is_shared(wid) or has_control(wid, from):
		_send_answer(from, wid, false)
		return
	for p in _pending:
		if int(p["wid"]) == wid and int(p["peer"]) == from:
			return
	_pending.append({"wid": wid, "peer": from, "t": _now()})
	if _pending.size() == 1:
		control_requested.emit(from, wid)

## La demande affichée (tête de la file) porte-t-elle sur `wid` ? (boîte de dialogue, scripts/ui/control_request.gd)
func is_pending(wid: int) -> bool:
	return not _pending.is_empty() and int(_pending[0]["wid"]) == wid

## Réponse du propriétaire (boîte de dialogue) ou refus automatique, pour la demande affichée.
func answer(wid: int, accepted: bool) -> void:
	if _pending.is_empty() or int(_pending[0]["wid"]) != wid:
		return
	var p: Dictionary = _pending.pop_front()
	var peer := int(p["peer"])
	var ok := accepted and _is_shared(wid) and not has_control(wid, peer)
	if ok:
		if not _grants.has(wid):
			_grants[wid] = {}
			_held[wid] = {}
			_mods[wid] = {"ctrl": false, "alt": false}
		(_grants[wid] as Dictionary)[peer] = true
		guest_control_changed.emit(peer, wid, true)
	_send_answer(peer, wid, ok)
	if not _pending.is_empty():
		_pending[0]["t"] = _now()
		control_requested.emit(int(_pending[0]["peer"]), int(_pending[0]["wid"]))

func _send_answer(peer: int, wid: int, ok: bool) -> void:
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		_rc_answer.rpc_id(peer, wid, ok)

## Le propriétaire reprend la main sur `wid` : tous les invités la perdent (ou fin du partage, fermeture).
func revoke(wid: int, notify := true) -> void:
	for peer in controllers_of(wid):
		revoke_peer(wid, int(peer), notify)

## Un invité perd la main sur `wid` (repris par le propriétaire, rendu par l'invité, départ).
func revoke_peer(wid: int, peer: int, notify := true) -> void:
	if not has_control(wid, peer):
		return
	if int(_seat.get(wid, OWNER)) == peer:
		_take_seat(wid, OWNER)
	(_grants[wid] as Dictionary).erase(peer)
	_lock_sent.erase(key_of(wid, peer))
	_remove_marker(wid, peer)
	if (_grants[wid] as Dictionary).is_empty():
		_grants.erase(wid)
		_seat.erase(wid)
		_held.erase(wid)
		_mods.erase(wid)
	if notify and is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer):
		_rc_revoke.rpc_id(peer, wid)
	guest_control_changed.emit(peer, wid, false)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_release(wid: Variant) -> void:
	if wid is int:
		revoke_peer(wid, multiplayer.get_remote_sender_id(), false)

func _allow(peer: int, kind: String) -> bool:
	var now := _now()
	var b: Dictionary = _budget.get(peer, {"t": now, "ptr": 0, "inp": 0})
	if now - int(b["t"]) >= 1000:
		b = {"t": now, "ptr": 0, "inp": 0}
	b[kind] = int(b[kind]) + 1
	_budget[peer] = b
	var ok := int(b[kind]) <= (MAX_POINTER_PER_SEC if kind == "ptr" else MAX_INPUT_PER_SEC)
	if not ok:
		_diag["drop"] += 1
	return ok

func _comp() -> Object:
	return lan.compositor if lan != null else null

@rpc("any_peer", "call_remote", "unreliable", 3)
func _rc_pointer(wid: Variant, u: Variant, v: Variant) -> void:
	_on_pointer(multiplayer.get_remote_sender_id(), wid, u, v)

func _on_pointer(from: int, wid: Variant, u: Variant, v: Variant) -> void:
	if not (wid is int) or not (u is float) or not (v is float) or not has_control(wid, from) or not _allow(from, "ptr"):
		return
	var uv := Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))
	var body := _body(wid)
	var comp := _comp()
	if body == null or comp == null:
		return
	if _window_locked(wid):
		return                          # message parti avant que l'invité apprenne le verrouillage
	_take_seat(wid, from)
	var ss: Vector2 = body.get_meta("surface_size", Vector2.ZERO)
	var co: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var p := uv * ss + co
	_diag["ptr_rx"] += 1
	comp.forward_pointer_motion(wid, p.x, p.y)
	_update_marker(wid, from, uv)

func _window_locked(wid: int) -> bool:
	var comp := _comp()
	return comp != null and comp.has_method("is_window_pointer_locked") and comp.is_window_pointer_locked(wid)

@rpc("any_peer", "call_remote", "unreliable", 3)
func _rc_relative(wid: Variant, dx: Variant, dy: Variant) -> void:
	_on_relative(multiplayer.get_remote_sender_id(), wid, dx, dy)

func _on_relative(from: int, wid: Variant, dx: Variant, dy: Variant) -> void:
	if not (wid is int) or not (dx is float) or not (dy is float) or not has_control(wid, from) or not _allow(from, "ptr"):
		return
	if not _window_locked(wid) or _body(wid) == null:
		return                          # déverrouillé entre-temps : l'invité repasse à l'absolu
	_take_seat(wid, from)
	_diag["rel_rx"] += 1
	var x := clampf(dx, -MAX_RELATIVE, MAX_RELATIVE)
	var y := clampf(dy, -MAX_RELATIVE, MAX_RELATIVE)
	_comp().forward_pointer_relative_motion(wid, x, y, x, y)

## Propriétaire : annonce aux invités qui ont la main le verrouillage du pointeur de chaque fenêtre (jeu FPS).
func _sync_locks() -> void:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return
	for wid in _grants:
		var locked := _window_locked(wid)
		for peer in controllers_of(wid):
			var lk := key_of(wid, int(peer))
			if bool(_lock_sent.get(lk, false)) != locked:
				_lock_sent[lk] = locked
				print("[rc] fenêtre %d : pointeur %s, annoncé à %d" % [wid, "verrouillé" if locked else "libéré", int(peer)])
				_rc_lock.rpc_id(int(peer), wid, locked)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_button(wid: Variant, button: Variant, pressed: Variant) -> void:
	_on_button(multiplayer.get_remote_sender_id(), wid, button, pressed)

func _on_button(from: int, wid: Variant, button: Variant, pressed: Variant) -> void:
	if not (wid is int) or not (button is int) or not (pressed is bool) or not has_control(wid, from):
		return
	if not BUTTONS.has(button) or not _allow(from, "inp"):
		return
	if not pressed and int(_seat.get(wid, OWNER)) != from:
		return                          # relâchement d'un bouton déjà relâché quand le siège a changé de main
	_take_seat(wid, from)
	var held: Dictionary = _held.get(wid, {})
	var id := "b:%d" % button
	if pressed:
		held[id] = button
	elif not held.erase(id):
		return                          # relâchement orphelin
	if pressed:
		_focus_keyboard(wid)            # clic = focus, comme un clic local : Pointer Lock (Firefox), SDL l'exigent
	_comp().forward_pointer_button(wid, button, pressed)

## Le focus clavier du seat (et l'activation de la fenêtre) va à `wid`, sauf s'il y est déjà : un menu déroulant
## de la fenêtre (popup) qui l'a garde son focus.
func _focus_keyboard(wid: int) -> void:
	_kbd_wid = wid
	var comp := _comp()
	if comp == null or not comp.has_method("set_window_keyboard_focus"):
		return
	if comp.has_method("get_keyboard_focus_window_id") and comp.get_keyboard_focus_window_id() == wid:
		return
	comp.set_window_keyboard_focus(wid)

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_axis(wid: Variant, dx: Variant, dy: Variant) -> void:
	_on_axis(multiplayer.get_remote_sender_id(), wid, dx, dy)

func _on_axis(from: int, wid: Variant, dx: Variant, dy: Variant) -> void:
	if not (wid is int) or not (dx is float) or not (dy is float) or not has_control(wid, from) or not _allow(from, "inp"):
		return
	_take_seat(wid, from)
	_comp().forward_pointer_axis(wid, clampf(dx, -MAX_AXIS, MAX_AXIS), clampf(dy, -MAX_AXIS, MAX_AXIS))

@rpc("any_peer", "call_remote", "reliable", 1)
func _rc_key(wid: Variant, code: Variant, location: Variant, pressed: Variant) -> void:
	_on_key(multiplayer.get_remote_sender_id(), wid, code, location, pressed)

func _on_key(from: int, wid: Variant, code: Variant, location: Variant, pressed: Variant) -> void:
	if not (wid is int) or not (code is int) or not (location is int) or not (pressed is bool):
		return
	if not has_control(wid, from) or location < 0 or location > 3 or not _allow(from, "inp"):
		return
	if not pressed and int(_seat.get(wid, OWNER)) != from:
		return                          # touche déjà relâchée quand le siège a changé de main
	_take_seat(wid, from)
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
	if pressed:
		_focus_keyboard(wid)            # un seul seat : la touche de l'invité va à la fenêtre contrôlée
	_comp().forward_keyboard_key(code, location, pressed)

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
	var mk := key_of(wid, peer)
	var m: Array = _markers.get(mk, [])
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
	_markers[mk] = m

## Pastilles d'un invité sur `wid` (peer = -1 : de tous les invités).
func _remove_marker(wid: int, peer := -1) -> void:
	for mk in _markers.keys():
		var p := String(mk).split(":")
		if int(p[0]) != wid or (peer != -1 and int(p[1]) != peer):
			continue
		for n in _markers[mk]:
			if n != null and is_instance_valid(n):
				n.queue_free()
		_markers.erase(mk)

# ── Boucle : envoi du pointeur, fins de contrôle, délais ───────────────

func _process(_delta: float) -> void:
	# Une position par frame, mais pas plus de POINTER_SEND_HZ : à 144-240 ips, un envoi par frame dépassait la borne
	# du propriétaire, qui jetait la fin de chaque seconde (pointeur figé par à-coups).
	# Cadence moyenne exacte (pas d'envoi une frame sur deux à 165 ips), sans rafale après une pause.
	var usec := Time.get_ticks_usec()
	var step := 1000000 / POINTER_SEND_HZ
	var keys: Array = _pending_ptr.keys()
	for k in _pending_rel.keys():
		if not keys.has(k):
			keys.append(k)
	for k in keys:
		var due := int(_ptr_next_usec.get(k, 0))
		if usec >= due:
			_ptr_next_usec[k] = maxi(due + step, usec - step)
			_flush_pointer(k)
			_flush_relative(k)
	var now := _now()
	_sync_locks()
	_log_diag(now)
	# Propriétaire : demande affichée sans réponse = refus (la suivante s'affiche).
	if not _pending.is_empty() and now - int(_pending[0]["t"]) > REQUEST_TIMEOUT_MSEC:
		answer(int(_pending[0]["wid"]), false)
	# Propriétaire : fin de partage, fenêtre fermée, invité parti, session finie.
	var peers: Array = multiplayer.get_peers() if is_inside_tree() and multiplayer.has_multiplayer_peer() else []
	for wid in _grants.keys():
		var gone_all: bool = not _is_shared(wid) or lan == null or not lan.is_session_active() \
				or lan.window_share_restricted()
		for peer in controllers_of(wid):
			if gone_all or not peers.has(int(peer)):
				revoke_peer(wid, int(peer), peers.has(int(peer)))
	# Invité : demandes sans réponse oubliées, propriétaire parti.
	for k in _requested.keys():
		if now - int(_requested[k]) > REQUEST_TIMEOUT_MSEC + 5000:
			_requested.erase(k)
	for k in _controlling.keys():
		var owner := int(String(k).split(":")[0])
		if not peers.has(owner):
			_controlling.erase(k)
			_forget_guest(k)
			_down.erase(k)
			var p := String(k).split(":")
			control_changed.emit(int(p[0]), int(p[1]), false)

## Une ligne / 2 s tant que du pointeur circule : envoyés (invité), appliqués et jetés par la borne (propriétaire).
func _log_diag(now: int) -> void:
	if now - _diag_last < 2000:
		return
	var secs := maxf(float(now - _diag_last) / 1000.0, 0.001)
	_diag_last = now
	var total := 0
	for v in _diag.values():
		total += int(v)
	if total > 0:
		print("[rc] diag: invité ptr=%.0f/s rel=%.0f/s verrouillé=%s | propriétaire ptr=%.0f/s rel=%.0f/s jetés=%d" % [
			_diag["ptr_tx"] / secs, _diag["rel_tx"] / secs, str(_locked.keys()),
			_diag["ptr_rx"] / secs, _diag["rel_rx"] / secs, _diag["drop"]])
	for k in _diag:
		_diag[k] = 0

## Fin de session : tout oublier.
func reset() -> void:
	for wid in _grants.keys():
		revoke(wid, false)
	_pending.clear()
	_seat.clear()
	_controlling.clear()
	_requested.clear()
	_pending_ptr.clear()
	_pending_rel.clear()
	_locked.clear()
	_lock_sent.clear()
	_ptr_next_usec.clear()
	_down.clear()
	_budget.clear()
