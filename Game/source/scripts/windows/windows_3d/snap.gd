extends Node
## Collage des fenêtres (zones, paires, rotation du groupe) et stockage de l'orientation ;
## géométrie de collage (fonctions pures).
##
## Module de Windows3D (nœud enfant « Snap »), créé par la façade : l'état partagé vit dans la façade
## (`w3d`), l'état propre au module vit ici.

const Windows3D := preload("res://scripts/windows/windows_3d.gd")
var w3d: Windows3D = null

# Couche physique dédiée aux zones de collage. Distincte de la couche 2
# (corps des fenêtres, utilisée par le raycast de pointage) pour qu'une zone
# ne soit JAMAIS touchée par le raycast du grab : attraper la zone au lieu du
# corps ferait rater la saisie. Bit 3 = valeur 8.
const SNAP_ZONE_LAYER := 8
# Les zones sont des Area3D enfants du quad. `monitorable` reste toujours
# vrai (elles doivent pouvoir être détectées) ; `monitoring` n'est activé que
# sur les 4 zones de la fenêtre SAISIE, ce qui limite le coût physique à un
# seul inventaire de recouvrement par frame.
const SNAP_ZONE_NAME := "Snap"

# ── Collage (snap) entre fenêtres ───────────────────────────────────────
#
# Modèle : une Area3D par côté de fenêtre (4 zones), enfant du quad — donc
# position, rotation et taille suivent gratuitement, sans code par frame.
# Deux zones de côtés OPPOSÉS qui se recouvrent => la fenêtre saisie se cale
# bord à bord sur la voisine, en héritant de son orientation (modèle VR :
# l'orientation est fixe, la fenêtre ne se réoriente plus vers la caméra).
#
# Les zones sont CENTRÉES sur le bord, jamais posées à l'extérieur : c'est ce
# qui fait qu'elles se recouvrent quand on APPROCHE, et pas seulement quand on
# a déjà dépassé la position flush.
#
# Épaisseur de la dalle : borne BASSE parce qu'une zone trop fine serait
# inatteignable au pixel près, borne HAUTE parce qu'une zone trop épaisse
# recouvrirait les fenêtres simplement voisines et produirait des collages
# parasites (le garde-fou « >2 candidats » ne couvre pas ce cas).
const SNAP_ZONE_THICKNESS := 0.3 # m
# Ordre FIXE d'évaluation des côtés : à égalité de recouvrement, le premier
# candidat l'emporte. Sans cet ordre stable, le collage dépendrait de
# l'ordre d'itération et scintillerait d'une frame à l'autre.
const SNAP_SIDES := ["left", "right", "top", "bottom"]
# Vitesse de rotation d'une fenêtre collée quand on tient une GÂCHETTE de
# manette (rad/s), et non le cran de la molette. Un quart de tour par seconde :
# assez vif pour un aller-retour entre deux angles, assez lent pour s'arrêter
# sur un angle précis.
const SNAP_ROTATE_RATE := deg_to_rad(90.0) # rad/s
# Distance (m) dont le pointeur doit s'éloigner du point où le collage a eu
# lieu pour décoller la fenêtre. Mesurée sur le POINTEUR et non sur la fenêtre :
# la rotation au scroll déplace la fenêtre, jamais le pointeur.
const SNAP_RELEASE_DISTANCE := 0.5

# Collage coupé (réglage pause_menu > GENERAL > Disable Window Snapping).
# Ne coupe que la DÉTECTION : un collage déjà établi se poursuit exactement
# comme si le pointeur s'en éloignait — la coupure est faite APRÈS la branche
# « déjà collée » de _find_snap, jamais avant.
var snapping_enabled := true

# Fenêtre dont les zones de collage sont en surveillance (monitoring actif).
var _snap_monitoring_wid := -1
# Couple (cible:côté:côté) qu'on vient de décoller : interdit de recoller tant
# que les zones se recouvrent encore, sinon la fenêtre recolle aussitôt.
var _snap_lockout := ""

# ── Collage (snap) et rotation ─────────────────────────────────────────

# Coupe ou rétablit la détection de collage (réglage GENERAL). Idempotent :
# le menu est rebranché à chaque changement, et le réglage survit au redémarrage.
func set_snapping_enabled(on: bool) -> void:
	snapping_enabled = on

# Colle la fenêtre SAISIE sur une voisine, si deux zones opposées se
# recouvrent.
#
# `raw_target` n'intervient que pour le LÂCHER : la position de calage se
# déduit du monde et jamais du pointeur, sinon une fenêtre collée cesserait
# d'être collée dès que la souris bouge. Voir zones_overlap_after_shift.
func _find_snap(raw_target: Vector3) -> Dictionary:
	var wid := w3d.active_window_id
	if wid == -1:
		return {}
	# Déjà collée : le collage se TIENT, il ne se redécide pas. Le refaire à
	# chaque frame depuis les recouvrements physiques bouclait : coller ->
	# adopter la rotation de la voisine -> les zones bougent, le recouvrement
	# disparaît -> décoller -> repasser face caméra -> recoller...
	var held: Dictionary = w3d.snapped_to.get(wid, {})
	if not held.is_empty():
		return _hold_snap(held, raw_target)

	# Collage coupé : plus aucun nouveau raccord. La coupure est ICI, après la
	# branche « déjà collée » — un collage établi n'a plus besoin d'être
	# redécidé, il tient sur les transformations de ses deux zones, et il doit
	# pouvoir se poursuivre (puis être lâché à la distance) même avec le
	# collage désactivé.
	if not snapping_enabled:
		return {}

	var pairs := _snap_zone_pairs(wid)
	if _snap_lockout != "":
		var still_overlapping := false
		var kept: Array = []
		for p in pairs:
			if _pair_key(int(p["their_wid"]), p["their_side"], p["our_side"]) == _snap_lockout:
				still_overlapping = true
			else:
				kept.append(p)
		if not still_overlapping:
			_snap_lockout = ""
		pairs = kept

	var choice := _choose_snap(pairs)
	if choice.is_empty():
		return {}
	var our_area: Area3D = choice.get("our_area", null)
	var their_area: Area3D = choice.get("their_area", null)
	if our_area == null or their_area == null:
		return {}
	# Position de calage dans la base FINALE (celle qui sera adoptée), et non
	# celle des zones actuelles : sinon elle change dès que la rotation est
	# recopiée.
	var their_wid := int(choice["their_wid"])
	var source := int(choice.get("adopt_basis_of", their_wid))
	var flush := their_area.global_transform.origin \
		- _stored_basis(source) * our_area.position
	return {
		"wid": their_wid,
		"side": str(choice["their_side"]),
		"our_side": str(choice["our_side"]),
		"position": flush,
		"anchor": raw_target,
		"adopt_basis_of": source,
		"our_area": our_area,
		"their_area": their_area,
	}

# Tient un collage en cours, ou le rompt si le pointeur s'est assez éloigné de
# l'endroit où il a eu lieu (ou si une des fenêtres a disparu).
func _hold_snap(held: Dictionary, raw_target: Vector3) -> Dictionary:
	var our_area = held.get("our_area", null)
	var their_area = held.get("their_area", null)
	var their_wid := int(held.get("wid", -1))
	var valid: bool = is_instance_valid(our_area) and is_instance_valid(their_area) \
		and w3d.quads.has(their_wid) and w3d.quads[their_wid].visible
	if not valid:
		return {}
	var anchor: Vector3 = held.get("anchor", raw_target)
	if raw_target.distance_to(anchor) > SNAP_RELEASE_DISTANCE:
		_snap_lockout = _pair_key(their_wid, str(held.get("side", "")),
			str(held.get("our_side", "")))
		return {}
	var snap := held.duplicate()
	snap["position"] = _flush_position(our_area, their_area)
	return snap

func _pair_key(their_wid: int, their_side: String, our_side: String) -> String:
	return "%d:%s:%s" % [their_wid, their_side, our_side]

# Calage bord à bord, REJOUÉ après l'adoption d'orientation.
#
# _find_snap a raisonné sur les zones telles qu'elles étaient avant que la base
# ne change : or la zone est un enfant du quad, donc la base écrite l'a
# déplacée. Le `position` calculé à ce moment-là décrit une position qui n'est
# plus la bonne. On le refait donc ici, sur les zones définitives.
func _snap_flush_position(wid: int, snap: Dictionary) -> Vector3:
	var our_area: Area3D = snap.get("our_area", null)
	var their_area: Area3D = snap.get("their_area", null)
	if our_area == null or their_area == null \
			or not is_instance_valid(our_area) or not is_instance_valid(their_area):
		return Vector3(snap.get("position", Vector3.ZERO))
	return _flush_position(our_area, their_area)

# Demi-dimensions visibles du quad d'une fenêtre, ou Zéro si elle a disparu.
func _visual_half(wid: int) -> Vector2:
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null or not is_instance_valid(quad):
		return Vector2.ZERO
	var mesh := quad.mesh as QuadMesh
	return visual_half_extent(mesh.size, _deco_of(quad)) if mesh != null else Vector2.ZERO

# Métriques de la fenêtre exprimées en unités MONDE : c'est le seul endroit où
# le ratio px/unité est calculé pour le décor.
func _deco_of(quad: MeshInstance3D) -> Dictionary:
	var mesh := quad.mesh as QuadMesh
	if mesh == null:
		return Windows3D.Decorations.world(Windows3D.Decorations.metrics(), Windows3D.Decorations.FALLBACK_PX_SCALE)
	var body := quad.get_child(0) as StaticBody3D
	var surface: Vector2 = body.get_meta("surface_size", Vector2.ZERO) if body != null else Vector2.ZERO
	return Windows3D.Decorations.world(Windows3D.Decorations.metrics(), Windows3D.Decorations.px_scale(surface, mesh.size))

# Position du quad collé bord à bord, déduite du seul couple de zones.
#
# La zone est un ENFANT du quad, à l'offset local `position` : le quad est donc
# exactement `centre_de_notre_zone - base * offset`. Imposer que notre zone
# arrive sur LEUR zone revient à mettre le quad à
# `centre_de_leur_zone - base * offset` : les deux centres de zone
# coïncident, donc les deux bords aussi puisque les zones sont opposées.
func _flush_position(our_area: Area3D, their_area: Area3D) -> Vector3:
	return their_area.global_transform.origin \
		- our_area.global_transform.basis * our_area.position

# Liste les appariements de zones qui se recouvrent entre la fenêtre saisie et
# les autres, sous la forme
# {our_wid, our_side, our_area, their_wid, their_side, their_area}.
#
# Seuls des côtés RÉELLEMENT OPPOSÉS sont appariés : deux zones perpendiculaires
# se touchent bien souvent sans que les fenêtres soient voisines, et les
# apparier ferait coller une fenêtre contre le FLANC d'une autre. Les fenêtres
# cachées sont ignorées — elles ne sont ni visibles ni cliquables, et collées
# derrière une autre elles produiraient des liaisons invisibles.
func _snap_zone_pairs(moving_wid: int) -> Array:
	var pairs: Array = []
	var moving_quad: MeshInstance3D = w3d.quads.get(moving_wid, null)
	if moving_quad == null or not is_instance_valid(moving_quad):
		return pairs
	var our_zones := _zones_of(moving_quad)
	for other_wid in w3d.quads:
		if other_wid == moving_wid:
			continue
		var other_quad: MeshInstance3D = w3d.quads[other_wid]
		if not is_instance_valid(other_quad) or not other_quad.visible:
			continue
		var their_zones := _zones_of(other_quad)
		for our_pair in our_zones:
			var our_area: Area3D = our_pair["area"]
			if our_area == null:
				continue
			for their_pair in their_zones:
				if not is_opposite_side(our_pair["side"], their_pair["side"]):
					continue
				var their_area: Area3D = their_pair["area"]
				if their_area == null:
					continue
				if not our_area.overlaps_area(their_area):
					continue
				pairs.append({
					"our_wid": moving_wid,
					"our_side": our_pair["side"],
					"our_area": our_area,
					"their_wid": other_wid,
					"their_side": their_pair["side"],
					"their_area": their_area,
				})
	return pairs

# Chemin de la zone d'un côté, à l'intérieur du quad. Un seul endroit décide
# du nom : les cinq accès qui suivent (création, sync, surveillance, appariement,
# pivot de rotation) ne peuvent alors pas diverger.
func _zone_path(side: String) -> String:
	return "%s%s" % [SNAP_ZONE_NAME, side.capitalize()]

# Crée les 4 zones de collage d'une fenêtre. Enfant du quad, donc la rotation
# de la fenêtre entraîne ses zones : c'est ce qui rend le collage exact
# quelle que soit l'orientation, sans le moindre calcul de distance.
func _build_snap_zones(quad: MeshInstance3D) -> void:
	for side in SNAP_SIDES:
		var area := Area3D.new()
		area.name = _zone_path(side)
		# Couche dédiée : le raycast de pointage (couche 2) ne peut pas
		# attraper une zone, sinon le grab viserait la zone au lieu du corps.
		area.collision_layer = SNAP_ZONE_LAYER
		area.collision_mask = SNAP_ZONE_LAYER
		# Détectable par les autres, mais on n'inventorie QUE les recouvrements
		# de la fenêtre saisie : monitoring reste sinon éteint.
		area.monitorable = true
		area.monitoring = false
		var col := CollisionShape3D.new()
		col.shape = BoxShape3D.new()
		area.add_child(col)
		quad.add_child(area)
	_sync_snap_zones(quad)

# Recale les 4 zones sur la taille et la position courantes du quad. Appelé à
# la création puis à chaque changement de taille (le même hook que la barre de
# titre), donc resize / fullscreen / ratio de texture sont couverts.
func _sync_snap_zones(quad: MeshInstance3D) -> void:
	var mesh: QuadMesh = quad.mesh
	if mesh == null:
		return
	var half := visual_half_extent(mesh.size, _deco_of(quad))
	for side in SNAP_SIDES:
		var area := quad.get_node_or_null(_zone_path(side)) as Area3D
		if area == null:
			continue
		var col := area.get_child(0) as CollisionShape3D
		if col == null:
			continue
		var size := snap_zone_size(half, side)
		var box := col.shape as BoxShape3D
		if box != null:
			box.size = size
		area.position = snap_zone_local_offset(half, side)

# N'active l'inventaire de recouvrements que sur la fenêtre saisie : une seule
# Area3D surveille à la fois, le coût physique reste donc marginal.
func _set_snap_monitoring(wid: int, on: bool) -> void:
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null or not is_instance_valid(quad):
		return
	for side in SNAP_SIDES:
		var area := quad.get_node_or_null(_zone_path(side)) as Area3D
		if area != null:
			area.monitoring = on

# Bascule la surveillance sur la fenêtre saisie et coupe celle de la précédente.
# Appelé en tête de chaque frame de déplacement, donc un simple point d'appel
# suffit : inutile de’actionner les six sites de grab et de relâchement à la
# main, et impossible d'en oublier un.
func _sync_snap_monitoring(wid: int) -> void:
	if wid == _snap_monitoring_wid:
		return
	_snap_lockout = ""
	if _snap_monitoring_wid > -1:
		_set_snap_monitoring(_snap_monitoring_wid, false)
	_snap_monitoring_wid = -1
	if wid > -1 and w3d.quads.has(wid) and is_instance_valid(w3d.quads[wid]):
		_set_snap_monitoring(wid, true)
		_snap_monitoring_wid = wid

# Les zones d'un CÔTÉ, dans l'ordre de SNAP_SIDES.
func _zones_of(quad: Node3D) -> Array:
	var out: Array = []
	for side in SNAP_SIDES:
		var area := quad.get_node_or_null(_zone_path(side)) as Area3D
		if area != null:
			out.append({"side": side, "area": area})
	return out

# Choix du collage parmi les appariements recensés.
#
# Règle « plus de 2 candidats => PAS DE SNAP » : au-delà d'un seul
# appariement, la position cible devient ambiguë et le collage
# scintillerait d'une frame à l'autre entre deux voisins. La règle des
# 3 fenêtres est la seule exception, et elle est décidée plus bas.
#
# Renvoie {} si aucun collage, sinon
# {our_wid, our_side, our_area, their_wid, their_side, their_area}, plus
# `adopt_basis_of` quand la règle des 3 fenêtres a tranché.
func _choose_snap(pairs: Array) -> Dictionary:
	if pairs.is_empty():
		return {}
	# Collage déjà établi et toujours recouvert : on le CONSERVE tel quel. Les
	# règles ci-dessous ne s'évaluent qu'à l'entrée ; les rejouer pendant le
	# scroll (la base de A change à chaque cran) ferait sauter le collage.
	var first: Dictionary = _current_pair(pairs)
	if first.is_empty():
		# Plus de 2 zones qui se recouvrent => PAS DE SNAP.
		if pairs.size() > 2:
			return {}
		first = pairs[0]
		if pairs.size() == 2:
			first = _resolve_three_windows(pairs)
			if first.is_empty():
				return {}
	var choice := {
		"our_wid": first["our_wid"],
		"our_side": first["our_side"],
		"our_area": first.get("our_area", null),
		"their_wid": first["their_wid"],
		"their_side": first["their_side"],
		"their_area": first.get("their_area", null),
	}
	if first.has("adopt_basis_of"):
		choice["adopt_basis_of"] = first["adopt_basis_of"]
	return choice

# Le couple correspondant au collage en cours, s'il est toujours dans `pairs`.
func _current_pair(pairs: Array) -> Dictionary:
	var cur: Dictionary = w3d.snapped_to.get(w3d.active_window_id, {})
	if cur.is_empty():
		return {}
	for p in pairs:
		if int(p["their_wid"]) == int(cur.get("wid", -1)) \
				and p["their_side"] == cur.get("side", "") \
				and p["our_side"] == cur.get("our_side", ""):
			return p
	return {}

# Règle des 3 fenêtres. Notre fenêtre recouvre exactement 2 fenêtres du groupe :
# A (pairs[0]) et B (pairs[1]). C est la fenêtre qui fait le lien entre A et B.
#   rot(A) == rot(B)                      -> on prend rot(A)
#   rot(A) != rot(B) et rot(A) == rot(C)  -> on prend rot(B)
#   rot(A) != rot(B) et rot(B) == rot(C)  -> on prend rot(A)
# On se cale sur la fenêtre dont on prend la rotation (adopt_basis_of).
# Pas de lien A-C-B, ou trois rotations distinctes : pas de snap.
func _resolve_three_windows(pairs: Array) -> Dictionary:
	var pa: Dictionary = pairs[0]
	var pb: Dictionary = pairs[1]
	var a: int = pa["their_wid"]
	var b: int = pb["their_wid"]
	var res: Dictionary
	if a == b:
		# Deux zones de la même voisine : une seule fenêtre cible.
		res = pa.duplicate()
		res["adopt_basis_of"] = a
		return res
	var c := _linking_window(a, b)
	if c == -1:
		return {}
	var basis_a := _stored_basis(a)
	var basis_b := _stored_basis(b)
	var basis_c := _stored_basis(c)
	if basis_a.is_equal_approx(basis_b):
		res = pa.duplicate()
		res["adopt_basis_of"] = a
	elif basis_a.is_equal_approx(basis_c):
		res = pb.duplicate()
		res["adopt_basis_of"] = b
	elif basis_b.is_equal_approx(basis_c):
		res = pa.duplicate()
		res["adopt_basis_of"] = a
	else:
		return {}
	return res

# Fenêtre collée à la fois à `a` et à `b` (le maillon du groupe), ou -1.
func _linking_window(a: int, b: int) -> int:
	for c in w3d.quads:
		if c == a or c == b:
			continue
		if _are_snapped(c, a) and _are_snapped(c, b):
			return c
	return -1

# Deux fenêtres sont collées si l'une est la partenaire de l'autre.
func _are_snapped(x: int, y: int) -> bool:
	return _snapped_partner_of(x) == y or _snapped_partner_of(y) == x

# Fenêtre déjà collée à `wid`, ou -1. Sert à retrouver C dans la règle des
# 3 fenêtres.
func _snapped_partner_of(wid: int) -> int:
	var snap: Dictionary = w3d.snapped_to.get(wid, {})
	if snap.is_empty():
		return -1
	return int(snap.get("wid", -1))

# Enregistre (ou efface) l'état de collage d'une fenêtre et n'émet le changement
# d'état réseau QUE sur transition : un emit par frame enverrait 60 fois/sec un
# état identique.
func _set_snap(wid: int, snap: Dictionary) -> void:
	var before: Dictionary = w3d.snapped_to.get(wid, {})
	if before.is_empty() and snap.is_empty():
		return
	if not before.is_empty() and not snap.is_empty():
		if before.get("wid", -1) == snap.get("wid", -1) \
				and before.get("side", "") == snap.get("side", "") \
				and before.get("our_side", "") == snap.get("our_side", ""):
			return
	# Nouvelle liaison (ou rupture) : c'est le SEUL moment où l'orientation
	# doit être réécrite. Tant que la liaison tient, la base reste figée —
	# sinon le scroll n'aurait aucun effet et la règle des 3 fenêtres serait
	# réévaluée sur une base qui change à chaque frame.
	if snap.is_empty():
		w3d.snapped_to.erase(wid)
	else:
		# Entrée OU changement de voisine : dans les deux cas c'est une nouvelle
		# liaison, donc la fenêtre reprend l'orientation décidée par le collage.
		w3d.snapped_to[wid] = snap
		_adopt_neighbour_basis(wid, snap)
	w3d.windows_state_changed.emit()

# La fenêtre saisie prend l'orientation de sa voisine — le modèle VR : deux
# fenêtres collées ont la même orientation, sinon le raccord n'est pas plat.
func _adopt_neighbour_basis(wid: int, snap: Dictionary) -> void:
	var source := int(snap.get("adopt_basis_of", -1))
	if source == -1:
		source = int(snap.get("wid", -1))
	if source == -1 or source == wid or not w3d.quads.has(source):
		return
	_store_basis(wid, _stored_basis(source))

# Le scroll ne pivote QUE si la fenêtre est collée : sinon il garde son sens
# de push/pull (move_depth), qui n'a pas le droit de disparaître.
func _scroll_rotates() -> bool:
	return w3d.active_window_id != -1 and w3d.snapped_to.has(w3d.active_window_id) and not w3d._group_grab

# Traduit le scroll en rotation. C'est le SEUL endroit du code où la
# distinction souris/manette a lieu d'être.
#
# UNE action (« scroll_up »/« scroll_down »), DEUX sémantiques opposées. La
# molette émet un événement par cran : un cran par événement. Une gâchette de
# manette reste PRESSÉE tant qu'on la tient : c'est une vitesse, pas un
# compteur. Les traiter pareil appliquait un cran de 15° à chaque frame, soit
# 900°/s — un tour en quatre secondes.
#
# La molette garde son comportement de référence, inchangé : un cran par frame
# pendant l'appui (une molette n'étant pas maintenable en pratique).
#
# `connected` (manettes branchées) est injectable pour pouvoir simuler une
# manette dans les tests headless, où le moteur n'en voit aucune.
func _rotate_from_scroll(delta: float, connected: Array[int] = Input.get_connected_joypads()) -> void:
	# elif, et non if : la gâchette choisit ENTRE le taux et le cran, elle ne
	# doit pas cumuler les deux.
	if _scroll_from_gamepad("scroll_up", connected):
		_rotate_snapped(SNAP_ROTATE_RATE * delta)
	elif Input.is_action_just_pressed("scroll_up", false) \
			or Input.is_action_pressed("scroll_up", false):
		_rotate_snapped(SNAP_ROTATE_RATE * 3 * delta)
	if _scroll_from_gamepad("scroll_down", connected):
		_rotate_snapped(-SNAP_ROTATE_RATE * delta)
	elif Input.is_action_just_pressed("scroll_down", false) \
			or Input.is_action_pressed("scroll_down", false):
		_rotate_snapped(-SNAP_ROTATE_RATE * 3 * delta)

# L'action est-elle tenue par une manette ? On regarde les ÉVÉNEMENTS de
# l'action (et non le périphérique « courant » : la souris et la manette
# cohabitent, c'est le dernier à avoir parlé qui compte) et on vérifie que le
# bouton correspondant est enfoncé, sur les manettes RÉELLEMENT branchées.
#
# Un axe de stick reste un ÉVÉNEMENT de molette du point de vue de cette
# fonction : remapper le scroll sur un stick ne la ferait pas basculer en mode
# continu, ce qui est le comportement voulu — l'angle par cran reste alors la
# seule unité.
func _scroll_from_gamepad(action: String, connected: Array[int] = Input.get_connected_joypads()) -> bool:
	for ev in InputMap.action_get_events(action):
		if not (ev is InputEventJoypadButton):
			continue
		for device: int in _pad_devices(ev, connected):
			if Input.is_joy_button_pressed(device, ev.button_index):
				return true
	return false

# Les périphériques à interroger pour un bind de manette.
#
# Les binds sont enregistrés avec device = -1, qui signifie « n'importe quelle
# manette » et ne désigne AUCUN périphérique : l'état d'un -1 n'existe pas, et
# is_joy_button_pressed(-1, …) répond toujours faux. Interroger le -1 de
# l'événement faisait donc passer toute gâchette pour une molette — et la
# fenêtrecollée tournait alors de SNAP_YAW_STEP à chaque frame au lieu du taux
# continu, indépendamment de SNAP_ROTATE_RATE.
static func _pad_devices(ev: InputEvent,
		connected: Array[int] = Input.get_connected_joypads()) -> Array[int]:
	var devices: Array[int] = connected.duplicate()
	if ev.device >= 0 and not devices.has(ev.device):
		devices.append(ev.device)
	return devices

# Un cran de rotation d'une fenêtre collée, autour de l'ORIGINE MONDE DE SA
# ZONE DE COLLAGE. Le pivot n'est ni deviné ni reconstruit depuis une base
# périmée : c'est la position réelle de l'Area3D, donc exacte par construction
# quelle que soit l'orientation des deux fenêtres.
#
# Comme la zone est un ENFANT du quad, une rotation autour de son origine la
# laisse sur place : le recouvrement des zones — donc le collage — se maintient
# tout seul pendant la rotation. C'est exactement le comportement demandé, et
# il est géométrique, pas simulé.
# Tourne la fenêtre collée de `angle` radians (signe = sens). L'angle est
# Decide en amont : _rotate_from_scroll est seul juge du pas, molette ou
# gâchette.
func _rotate_snapped(angle: float) -> void:
	if not _scroll_rotates():
		return
	var snap: Dictionary = w3d.snapped_to.get(w3d.active_window_id, {})
	var area := _snap_pivot_area(w3d.active_window_id)
	if area == null:
		return
	var quad: MeshInstance3D = w3d.quads[w3d.active_window_id]
	var deco := _deco_of(quad)
	var delta := angle
	var pivot := area.global_transform.origin
	# L'axe est celui de la zone : verticale pour une zone latérale, ce qui
	# fait tourner la fenêtre comme une porte sur son arête de liaison.
	if snap["side"] == "right":
		var axis := area.global_transform.basis.y.normalized()
		var visual := visual_center(quad.global_position,
			quad.global_basis.y.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(w3d.active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			- base_after.y.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(w3d.active_window_id, base_after)
	if snap["side"] == "left":
		var axis := -area.global_transform.basis.y.normalized()
		var visual := visual_center(quad.global_position,
			-quad.global_basis.y.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(w3d.active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			+ base_after.y.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(w3d.active_window_id, base_after)
	if snap["side"] == "bottom":
		var axis := area.global_transform.basis.x.normalized()
		var visual := visual_center(quad.global_position,
			quad.global_basis.x.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(w3d.active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			- base_after.x.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(w3d.active_window_id, base_after)
	if snap["side"] == "top":
		var axis := -area.global_transform.basis.x.normalized()
		var visual := visual_center(quad.global_position,
			-quad.global_basis.x.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(w3d.active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			+ base_after.x.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(w3d.active_window_id, base_after)
	
# Area3D servant de pivot : celle du côté par lequel la fenêtre est collée.
func _snap_pivot_area(wid: int) -> Area3D:
	var snap: Dictionary = w3d.snapped_to.get(wid, {})
	if snap.is_empty():
		return null
	var side := String(snap.get("our_side", ""))
	var quad: MeshInstance3D = w3d.quads.get(wid, null)
	if quad == null or not is_instance_valid(quad) or side == "":
		return null
	return quad.get_node_or_null(_zone_path(side)) as Area3D

# ── Stockage de l'orientation (modèle VR : orientation FIXE) ────────────
#
func _stored_basis(wid: int) -> Basis:
	if not w3d.quads.has(wid):
		return Basis.IDENTITY
	return w3d._window_basis.get(wid, w3d.quads[wid].global_basis)

func _store_basis(wid: int, basis: Basis) -> void:
	if not w3d.quads.has(wid) or not is_instance_valid(w3d.quads[wid]):
		return
	w3d._window_basis[wid] = basis
	w3d.quads[wid].global_basis = basis

# Recopie l'orientation complète d'une fenêtre sur une autre — utilisé à la
# sortie du mode focus, où les fenêtres empilées repartent toutes avec la base
# de la première.
# Il faut recopier l'ÉTAT STOCKÉ et pas seulement global_basis : c'est
# _window_basis que la rotation au collage relit. Ne recopier que la base
# visible laisserait l'état à zéro angle, et la fenêtre se replacerait
# d'un coup à l'angle précédent au prochain cran de rotation.
func copy_window_basis(from_id: int, to_id: int) -> void:
	if not w3d.quads.has(from_id) or not w3d.quads.has(to_id):
		return
	_store_basis(to_id, _stored_basis(from_id))

# Oubli de toutes les données par fenêtre. Isolé de on_window_unmapped pour être
# testable : celui-ci await la freeing de l'occulteur, donc ne peut pas être
# appelé depuis un test runner synchrone.
func _erase_window_state(id: int) -> void:
	w3d.window_app_ids.erase(id)
	w3d.window_textures.erase(id)
	w3d.window_shared.erase(id)
	w3d.window_private.erase(id)
	w3d.window_server_side.erase(id)
	w3d._texture_versions.erase(id)
	w3d._alpha_probes.erase(id)
	w3d.focus_frozen.erase(id)
	w3d._alpha_decided.erase(id)
	w3d._alpha_translucent.erase(id)
	w3d._window_basis.erase(id)
	w3d.snapped_to.erase(id)
	if _snap_monitoring_wid == id:
		_snap_monitoring_wid = -1

# ── Géométrie de collage (fonctions PURES, testables sans scène) ───────
#
# Le cadre et le bandeau vivent AU-DESSUS du quad : ils ne sont ni dans la
# boîte de collision du contenu ni dans son occluder. L'empreinte VISIBLE
# d'une fenêtre est donc plus grande que son quad, et c'est elle qu'il faut
# coller — sinon deux fenêtres s'imbriqueraient en se collant. Les épaisseurs
# viennent du `decorations.json`, plus d'une constante en dur.

# Demi-dimensions VISIBLES (quad + cadre + bandeau) d'une fenêtre. Les
# épaisseurs viennent du JSON, plus d'une constante en dur.
static func visual_half_extent(mesh_size: Vector2, deco: Dictionary) -> Vector2:
	var t: float = deco.get("border", 0.0)
	var b: float = deco.get("titlebar", 0.0)
	return Vector2(mesh_size.x * 0.5 + t, (mesh_size.y + b + t) * 0.5)

# Position LOCALE du centre d'une zone de collage, dans le repère du quad.
# Volontairement CENTRÉE sur le bord (et non posée juste à l'extérieur) : deux
# zones opposées doivent se recouvrir quand on approche la position flush, pas
# seulement après l'avoir dépassée.
static func snap_zone_local_offset(half: Vector2, side: String) -> Vector3:
	match side:
		"left": return Vector3(-half.x, 0.0, 0.0)
		"right": return Vector3(half.x, 0.0, 0.0)
		"top": return Vector3(0.0, half.y, 0.0)
		"bottom": return Vector3(0.0, -half.y, 0.0)
	return Vector3.ZERO

# Taille de la dalle d'une zone, dans le repère du quad (X = droite,
# Y = haut, Z = vers la caméra).
#
# L'épaisseur de capture est portée par l'axe du COLLAGE : X pour une zone
# latérale, Y pour une zone horizontale. La confondre avec Z — l'épaisseur
# habituelle d'un billboard — donnerait des zones plates, sans aucune
# épaisseur latérale, donc aucun collage latéral possible.
#
# Z est ÉPAISSI lui aussi, à la même valeur. Un Z de 2 cm rendrait le collage
# impossible dès que les deux fenêtres ont ne serait-ce que 1 cm de décalage
# en profondeur — et le drag 3D fige la fenêtre sur une sphère autour de la
# caméra, donc deux fenêtres voisines à l'écran sont presque toujours à des
# profondeurs différentes. Épaissir Z rend le collage tolérant à ~50 cm de
# décalage, et le calage ramenant les centres de zone l'un sur l'autre, les
# deux fenêtres finissent COPLANAIRES : le collage reste exact.
static func snap_zone_size(half: Vector2, side: String) -> Vector3:
	var horizontal := side == "top" or side == "bottom"
	# Côté horizontal : s'étale sur toute la LARGEUR, épais en hauteur.
	# Côté latéral : s'étale sur toute la HAUTEUR, épais en largeur.
	return Vector3(
		half.x * 2.0 if horizontal else SNAP_ZONE_THICKNESS,
		SNAP_ZONE_THICKNESS if horizontal else half.y * 2.0,
		SNAP_ZONE_THICKNESS)

# Le pointeur peut-il encore tirer la fenêtre hors de portée ?
#
# Un collage est un point fixe : une fois calée, la fenêtre reste sur sa zone,
# donc elle ne peut plus s'en éloigner par elle-même et le recouvrement ne
# JAMAIS ne s'interrompt. Sans cette question, le collage serait définitif et
# la fenêtre collée impossible à déplacer.
#
# La réponse se lit sur la position VISE par le pointeur : `shift` est l'écart
# entre cette position et le point de calage, exprimé dans le repère des zones.
# Les deux zones sont alors coïncidentes et `slack` est la jeu exact, axe par
# axe, entre les deux boîtes — la taille de la zone, pas une constante choisie
# à la main.
static func zones_overlap_after_shift(our_half: Vector2, our_side: String,
		their_half: Vector2, their_side: String, shift: Vector3) -> bool:
	var slack := (snap_zone_size(our_half, our_side)
		+ snap_zone_size(their_half, their_side)) * 0.5
	return absf(shift.x) <= slack.x \
		and absf(shift.y) <= slack.y \
		and absf(shift.z) <= slack.z

# Deux côtés ne sont appariables que s'ils sont VRAIMENT opposés. Le même
# côté (droite/droite) et les côtés perpendiculaires (gauche/haut) sont
# exclus : sans ce filtre, une fenêtre près d'une autre en diagonale
# produirait un collage absurde.
static func is_opposite_side(a: String, b: String) -> bool:
	return (a == "left" and b == "right") \
		or (a == "right" and b == "left") \
		or (a == "top" and b == "bottom") \
		or (a == "bottom" and b == "top")

# Centre VISIBLE d'une fenêtre : décalé vers le haut d'un demi-bandeau.
static func visual_center(quad_position: Vector3, up: Vector3, deco: Dictionary) -> Vector3:
	var t: float = deco.get("border", 0.0)
	var b: float = deco.get("titlebar", 0.0)
	return quad_position + up * ((b - t) * 0.5)
