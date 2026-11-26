extends Node
## Pointage raycast depuis la caméra : survol, clic, popups, barre de titre et boutons, bords de
## redimensionnement, plein écran.
##
## Module de Windows3D (nœud enfant « Pointer »), créé par la façade : l'état partagé vit dans la façade
## (`w3d`), l'état propre au module vit ici.

const Windows3D := preload("res://scripts/windows/windows_3d.gd")
var w3d: Windows3D = null

const BORDER_MARGIN = 10 # en pixels sur la texture, zone de bord = redimensionnement
const CORNER_MARGIN = 20 # px, zone de coin (carrée, plus large que BORDER_MARGIN
# Bouton de barre survolé : évite d'écrire une texture par frame quand rien
# n'a changé.
var _hover_btn: StaticBody3D = null

var pre_fullscreen_mesh_sizes: Dictionary = {} # wid (int) -> Vector2
var pre_fullscreen_surface_sizes: Dictionary = {} # wid (int) -> Vector2

# Pointage raycast principal, appelé à chaque frame par wayland_room.gd.
# Gère hover/clic/scroll vers les fenêtres et popups, ainsi que les grabs
# de déplacement (G) et de redimensionnement (bords/coins).
func process_raycast(ray_origin: Vector3, ray_dir: Vector3, delta: float, interact_active: bool) -> void:
	# Un bouton ne reste allumé que le temps où le rayon le vise vraiment : les
	# branches de grab, de resize et de rayon dans le vide reviennent toutes ici.
	_set_hover(null)
	# Seule entrée appelée TOUTES les frames, grabs ou non : c'est donc ici
	# qu'on rallume et qu'on éteint la surveillance des zones de collage, sans
	# avoir à toucher aux six sites de prise et de relâchement. L'appel est
	# idempotent, celui des frames de déplacement ne fait que l'anticiper.
	w3d.snap._sync_snap_monitoring(w3d.active_window_id if w3d.is_moving and not w3d._group_grab else -1)
	# Efface le pointeur wayland de toutes les fenêtres : il n'est re-posé
	# que si le raycast atteint une fenêtre ci-dessous. Les branches de
	# retour (drag, raycast dans le vide) laissent ainsi les captures de
	# fenêtre OBS sans curseur.
	w3d.compositor.set_window_pointer(-1, 0, 0, false)
	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if w3d.is_moving:
		# Fenêtre collée : le scroll pivote au lieu de pousser/tirer. Le
		# push/pull n'est proposé QUE hors collage, sinon on perd le
		# depth-move existant — c'est le même scroll, deux sens selon l'état.
		if w3d.snap._scroll_rotates():
			w3d.snap._rotate_from_scroll(delta)
		else:
			# just_pressed AVANT is_action_pressed : sur la frame d'appui d'un
			# clic molette, les deux sont vrais — l'ordre inverse donnait toujours
			# le petit pas (0.05) au lieu du saut (0.25).
			if Input.is_action_just_pressed("scroll_up", false):
				w3d.move_depth += 0.25
			elif Input.is_action_pressed("scroll_up", false):
				w3d.move_depth += 0.05
			if Input.is_action_just_pressed("scroll_down", false):
				w3d.move_depth -= 0.25
			elif Input.is_action_pressed("scroll_down", false):
				w3d.move_depth -= 0.05
		if w3d._group_grab:
			w3d.grab._update_group_move(ray_origin, ray_dir, delta)
		else:
			w3d.grab._update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab", true):
			w3d._set_window_occluder_active(w3d.active_window_id, true)
			w3d.is_moving = false
			w3d.active_window_id = -1
			w3d.windows_state_changed.emit()
		if Input.is_action_just_released(w3d._grab_action, true):
			w3d.grab._end_group_grab()
			w3d._set_window_occluder_active(w3d.active_window_id, true)
			w3d.is_moving = false
			w3d.active_window_id = -1
			w3d.windows_state_changed.emit()
			return
		return
	if w3d.is_resizing:
		w3d.grab._update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click", false):
			w3d._set_window_occluder_active(w3d.active_window_id, true)
			w3d.is_resizing = false
			w3d.grab._end_group_resize()
			w3d.resizing_edge = ""
			w3d.active_window_id = -1
			w3d.windows_state_changed.emit()
		return

	var to := ray_origin + ray_dir * 1000.0
	var space := w3d.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	# Jamais le corps du joueur (la caméra à hauteur de tête affleure le sommet de sa capsule).
	if w3d.player is CollisionObject3D:
		params.exclude = [(w3d.player as CollisionObject3D).get_rid()]
	# Explicite, alors que c'est déjà le défaut : les zones de collage sont des
	# Area3D, et si ce rayon les touchait un jour, on saisirait la ZONE au
	# lieu du corps — le grab viserait à côté de la fenêtre attrapée.
	params.collide_with_areas = false
	var hit := space.intersect_ray(params)

	if hit.is_empty():
		w3d.is_in_window = false
		w3d.compositor.forward_pointer_leave()
		# Relâchement du clic dans le vide (ex: drop d'un drag-and-drop hors
		# de toute fenêtre) : window_id=-1 -> le compositeur route quand même
		# l'événement au seat et annule un drag actif le cas échéant.
		if Input.is_action_just_released("left_click", false):
			w3d.compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			w3d.compositor.forward_pointer_button(-1, 0x111, false)
		return

	var body: Node3D = hit.collider

	if body.has_meta("popup_id"):
		w3d.is_in_window = true
		_handle_popup_pointer(body, hit, ray_origin, ray_dir)
		return

	if body.has_meta("decoration_edge"):
		# Clic sur le cadre : il EST la bordure de la fenêtre, donc la poignée
		# de redimensionnement. Rien n'est forwardé vers l'app.
		w3d.is_in_window = true
		_handle_decoration_edge(body, ray_origin, ray_dir)
		return

	if body.has_meta("titlebar_button"):
		# Clic sur un bouton de la barre de titre : fermer/réduire/agrandir.
		# Pas de forward du pointeur vers l'app (ce n'est pas du contenu).
		w3d.is_in_window = true
		_handle_titlebar_button(body)
		return

	if body.has_meta("titlebar_of"):
		# Clic sur la barre de titre du jeu : on redimensionne la fenêtre par le
		# haut, on ne forward rien à l'app (la barre n'est pas du contenu
		# applicatif).
		w3d.is_in_window = true
		_handle_titlebar(body, ray_origin, ray_dir)
		return

	if not body.has_meta("window_id"):
		w3d.is_in_window = false
		w3d.compositor.forward_pointer_leave()
		# Idem : relâchement sur un collider sans fenêtre (mur, sol, etc.)
		# doit pouvoir annuler un drag-and-drop en cours.
		if Input.is_action_just_released("left_click", false):
			w3d.compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			w3d.compositor.forward_pointer_button(-1, 0x111, false)
		return
	else:
		w3d.is_in_window = true
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh
	
	# Le point de contact du raycast est sur la FACE AVANT du boîtier de
	# collision (0.05 m d'épaisseur), pas sur le plan visuel du quad (z=0).
	# En incidence rasant — fenêtre proche, regard levé vers la barre de
	# titre — la face avant est décalée du plan visuel de ~0.025·tan(angle):
	# à 60° ça fait ~3 cm ≈ 20+ px trop bas, de quoi rater la croix et
	# cliquer le bouton juste en dessous. On réintersecte donc le rayon
	# avec le plan exact du quad.
	var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
	var wid: int = body.get_meta("window_id")
	# La texture est découpée à la window_geometry, donc UV * surface_size
	# donne des coordonnées dans le repère geometry. Le client Wayland
	# attend des coordonnées dans le repère surface (incluant les ombres),
	# d'où l'ajout de content_offset.
	var content_offset_fwd: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	if not w3d.popup_quads.is_empty():
		print("raycast: WINDOW wid=", wid, " uv=", uv, " px=",
			uv.x * win_size.x + content_offset_fwd.x, " py=",
			uv.y * win_size.y + content_offset_fwd.y,
			" content_offset=", content_offset_fwd, " surf_size=", win_size)
	w3d.compositor.forward_pointer_motion(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y)
	# Position du pointeur dans la fenêtre (coordonnées surface, y vers le
	# bas) : servira à composer le curseur dans la capture fenêtre OBS quand
	# la source a coché « afficher le curseur ».
	w3d.compositor.set_window_pointer(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y, true)

	if Input.is_action_just_pressed("grab", true) and not interact_active:
		w3d.active_window_id = wid
		w3d.is_moving = true
		# Même détachement d'occluder que toggle_grab_window/resize :
		# pendant le grab le quad réécrit sa transform à CHAQUE frame
		# (billboard), ce qui rediriterait la scène Embree entière (incluant
		# l'AutoOcclusion du niveau) → gros pic CPU par frame. Le réattache
		# se fait au relâchement dans la branche is_moving de process_raycast.
		w3d._set_window_occluder_active(wid, false)
		w3d.move_depth = w3d._camera().global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab", true):
		w3d.active_window_id = wid
		w3d.is_moving = false
		w3d.move_depth = 0.0
	if Input.is_action_just_pressed("grab_group", true) and not interact_active:
		w3d.grab._start_group_grab(wid, quad)
	if Input.is_action_just_pressed("left_click", false):
		w3d.focused_window_id = wid
		# Le haut du contenu n'est PAS une zone de drag : le clic y part vers
		# l'app (barre d'outils, onglets CSD). Le redimensionnement depuis le
		# haut se fait sur la barre de titre du jeu (voir _handle_titlebar).
		var edge := _border_edge(uv, win_size, body)
		if edge != "":
			# Bord de la fenêtre -> redimensionnement.
			w3d.grab._start_resize(wid, quad, ray_origin, ray_dir, edge)
		else:
			w3d.compositor.forward_pointer_button(wid, 0x110, true) # BTN_LEFT (evdev)
	if Input.is_action_just_released("left_click", false):
		w3d.compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click", false):
		w3d.focused_window_id = wid
		w3d.compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		w3d.compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up", false) or Input.is_action_pressed("scroll_up", false):
		w3d.compositor.forward_pointer_axis(wid, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down", false) or Input.is_action_pressed("scroll_down", false):
		w3d.compositor.forward_pointer_axis(wid, 0, 100.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var mesh: QuadMesh = quad.mesh
	var pid: int = body.get_meta("popup_id")
	var info: Dictionary = w3d.popup_parent_info.get(pid, {})
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))

	var pgeo: Dictionary = w3d.compositor.get_popup_geometry(pid)
	var popup_geo_off := Vector2(pgeo.get("x", 0), pgeo.get("y", 0))
	var px: float
	var py: float
	if info.get("parent_popup_id", -1) == -1 and w3d.quads.has(info.get("parent_window_id", -1)):
		# Popup directement parenté à une fenêtre : les coordonnées envoyées
		# au client doivent être celles du plan de la FENÊTRE, pas du plan 3D
		# du popup. Le popup est avancé de z=0.02 devant la fenêtre (anti
		# z-fighting) : le rayon coupe les deux plans à des points différents
		# selon l'angle de la caméra (parallaxe), ce qui décalait les
		# coordonnées de ~7-9 px (suffisant pour que Firefox ferme le menu).
		# On réintersecte donc le rayon avec le plan de la fenêtre pour avoir
		# la position réelle du curseur, puis on retranche l'origine du popup
		# (géométrie xdg-shell = coordonnées surface du parent).
		var window_quad: MeshInstance3D = w3d.quads[info.parent_window_id]
		var window_body: StaticBody3D = window_quad.get_child(0)
		var window_mesh: QuadMesh = window_quad.mesh
		var window_surface_size: Vector2 = window_body.get_meta("surface_size", Vector2(1, 1))
		var window_uv := _uv_at_plane(window_quad, window_mesh, ray_origin, ray_dir, hit.position)
		# info.x/y est relatif à la window_geometry du parent (xdg_positioner),
		# et le quad parent est recadré sur cette géométrie : pas de
		# content_offset du parent ici. On ajoute en revanche le décalage de la
		# window_geometry du popup dans sa surface (marge d'ombre GTK).
		px = window_uv.x * window_surface_size.x - float(info.x) + popup_geo_off.x
		py = window_uv.y * window_surface_size.y - float(info.y) + popup_geo_off.y
	else:
		# Sous-menu (parenté à un autre popup) : calcul direct sur le plan du
		# popup, même convention que précédemment.
		var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
		px = uv.x * win_size.x + popup_geo_off.x
		py = uv.y * win_size.y + popup_geo_off.y
	print("raycast: POPUP pid=", pid, " px=", px, " py=", py,
		" surf_size=", win_size, " quad_pos=", quad.global_position,
		" mesh_size=", mesh.size)
	w3d.compositor.forward_pointer_motion_popup(pid, px, py)

	if Input.is_action_just_pressed("scroll_up", false) or Input.is_action_pressed("scroll_up", false):
		w3d.compositor.forward_pointer_axis_popup(pid, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down", false) or Input.is_action_pressed("scroll_down", false):
		w3d.compositor.forward_pointer_axis_popup(pid, 0, 100.0)

	if Input.is_action_just_pressed("left_click", false):
		w3d.compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click", false):
		w3d.compositor.forward_pointer_button_popup(pid, 0x110, false)

	# Le clic droit doit aussi être relayé quand le curseur est au-dessus
	# d'un popup : sans relâchement, button_count reste bloqué à 1 dans
	# wlroots et le compositeur ne peut plus entrer le popup (hover/clic
	# impossibles). wlroots route les boutons vers la surface focusée, donc
	# le relâchement d'un clic parti sur la fenêtre y retombe correctement.
	if Input.is_action_just_pressed("right_click", false):
		w3d.compositor.forward_pointer_button_popup(pid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		w3d.compositor.forward_pointer_button_popup(pid, 0x111, false)

# Clic sur un bouton de la barre de titre.
func _handle_titlebar_button(body: StaticBody3D) -> void:
	if not Input.is_action_just_pressed("left_click", false):
		return
	var info: Dictionary = body.get_meta("titlebar_button")
	var wid: int = info["wid"]
	var action: String = info["action"]
	match action:
		"minimize":
			# xdg-shell n'a pas de minimize : on cache le quad (restauration
			# via le menu fenêtres, bouton HIDE/SHOW).
			w3d.toggle_hide(wid)
		"maximize":
			var is_fs: bool = w3d.fullscreen_windows.get(wid, false)
			toggle_window_fullscreen(wid, not is_fs)
		"close":
			w3d.compositor.close_window(wid)

func toggle_window_fullscreen(id: int, fullscreen: bool) -> void:
	w3d.fullscreen_windows[id] = fullscreen

	if not w3d.quads.has(id) or not is_instance_valid(w3d.quads[id]):
		return

	var quad: MeshInstance3D = w3d.quads[id]
	var mesh: QuadMesh = quad.mesh
	var body: StaticBody3D = quad.get_child(0)
	# Le groupe collé suit le changement de taille (voisines poussées/rapprochées).
	w3d.grab._begin_group_resize(id)

	if fullscreen:
		# 1. Store state prior to toggling fullscreen
		pre_fullscreen_mesh_sizes[id] = mesh.size
		pre_fullscreen_surface_sizes[id] = body.get_meta("surface_size", Vector2(1024, 768))

		# 2. Request viewport dimensions from the Wayland surface
		var vp_size := get_viewport().get_visible_rect().size
		var aspect = vp_size.x / max(vp_size.y, 1.0)
		
		# Standardized 3D height facing camera (1.0 meter high)
		mesh.size = Vector2(1.0 * aspect, 1.0) * Windows3D.WINDOW_QUAD_SCALE
		
		# Update collision shape to match mesh size
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		w3d._sync_decorations(quad)

		# Notify Wayland client buffer of target size
		w3d.compositor.set_window_size(id, int(vp_size.x), int(vp_size.y))

	else:
		# 1. Restore Quad Mesh Size
		if pre_fullscreen_mesh_sizes.has(id):
			mesh.size = pre_fullscreen_mesh_sizes[id]
			pre_fullscreen_mesh_sizes.erase(id)

		# Restore collision shape
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		w3d._sync_decorations(quad)

		# 2. Restore original Wayland client surface size
		if pre_fullscreen_surface_sizes.has(id):
			var orig_surf: Vector2 = pre_fullscreen_surface_sizes[id]
			w3d.compositor.set_window_size(id, int(orig_surf.x), int(orig_surf.y))
			pre_fullscreen_surface_sizes.erase(id)
	w3d.grab._update_group_resize(id)
	w3d.grab._end_group_resize()
	w3d.windows_state_changed.emit()

# Clic sur la barre de titre du jeu -> redimensionnement depuis le HAUT de la
# fenêtre : on tire la hauteur, bord bas et largeur restent en place. Même
# mécanique que le drag d'un bord (helper _start_resize), le seul écart est
# que la barre n'est pas un bord de l'écran : on la vise directement.
# Clic sur le cadre de la fenêtre : même mécanique que le drag d'un bord, le
# cadre en étant la bordure. `edge` vient de la meta de la pièce.
func _handle_decoration_edge(body: StaticBody3D, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var quad := body.get_parent().get_parent() as MeshInstance3D
	if quad == null:
		return
	var wid: int = int(body.get_meta("window_of", -1))
	if Input.is_action_just_pressed("left_click", false):
		w3d.focused_window_id = wid
		w3d.grab._start_resize(wid, quad, ray_origin, ray_dir, str(body.get_meta("decoration_edge", "")))
	if Input.is_action_just_released("left_click", false):
		w3d.grab._release_resize_gesture(wid)

# Allume le bouton visé et éteint le précédent. L'état n'est écrit que s'il
# change : la meta `button_state` sert de garde.
func _set_hover(body: StaticBody3D) -> void:
	if _hover_btn != body:
		if is_instance_valid(_hover_btn):
			_apply_button_state(_hover_btn, 0)
		_hover_btn = body
	if is_instance_valid(_hover_btn):
		_apply_button_state(_hover_btn,
			2 if Input.is_action_pressed("left_click", false) else 1)

func _apply_button_state(body: StaticBody3D, state: int) -> void:
	if int(body.get_meta("button_state", -1)) == state:
		return
	body.set_meta("button_state", state)
	var info: Dictionary = body.get_meta("titlebar_button", {})
	if info.is_empty():
		return
	var wid: int = int(info["wid"])
	Windows3D.WindowDecoration.set_button_state(body, str(info["action"]), state,
		w3d.fullscreen_windows.get(wid, false))

func _handle_titlebar(body: StaticBody3D, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var titlebar: MeshInstance3D = body.get_parent()
	var quad: MeshInstance3D = titlebar.get_parent()
	var wid: int = body.get_meta("titlebar_of")
	if Input.is_action_just_pressed("left_click", false):
		w3d.focused_window_id = wid
		w3d.grab._start_resize(wid, quad, ray_origin, ray_dir, "top")
	if Input.is_action_just_released("left_click", false):
		# Press + release sur la MÊME frame (clic rapide) : le relâchement
		# inter-frame passe par la branche is_resizing de process_raycast, pas
		# ici — réattacher ici garantit l'équilibre détachement/reliure.
		w3d.grab._release_resize_gesture(wid)

# UV exact sur le plan visuel du quad : le point renvoyé par le raycast est
# sur la face avant du boîtier de collision (épais), donc décalé du plan
# z=0 du quad de ~0.025·tan(angle). Négligeable de loin, mais à bout
# portant ça décale le clic de plusieurs dizaines de pixels vers le bas.
func _uv_at_plane(quad: MeshInstance3D, mesh: QuadMesh, ray_origin: Vector3, ray_dir: Vector3, fallback: Vector3) -> Vector2:
	var quad_plane := Plane(quad.global_transform.basis.z.normalized(), quad.global_position)
	var plane_hit = quad_plane.intersects_ray(ray_origin, ray_dir)
	if plane_hit == null:
		plane_hit = fallback
	var local := quad.to_local(plane_hit)
	return Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)

# Bord touché (marge en pixels de texture) -> "" si le clic est dans le
# corps de la fenêtre.
func _border_edge(uv: Vector2, win_size: Vector2, body: StaticBody3D) -> String:
	# Récupère la géométrie de contenu (sans ombres CSD). Si le client n'a
	# pas défini de géométrie (par ex. application SSD), on retombe sur la
	# taille complète de la surface.
	var _content_offset: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var content_size: Vector2 = body.get_meta("content_size", win_size)
	if content_size.x <= 0 or content_size.y <= 0:
		_content_offset = Vector2.ZERO
		content_size = win_size
	# Convertit les coordonnées UV en pixels de contenu. La texture est
	# découpée à la window_geometry, donc UV * win_size donne directement
	# les coordonnées dans le repère contenu (pas besoin de soustraire
	# content_offset). BORDER_MARGIN est relatif au bord visible du contenu.
	var px := uv.x * win_size.x
	var py := uv.y * win_size.y

	# Coins du bas: zone carrée large (CORNER_MARGIN), facile à viser via
	# raycast - aucun risque de conflit, pas de boutons de fenêtre en bas.
	var near_bottom_wide := py > content_size.y - CORNER_MARGIN
	var near_left_wide := px < CORNER_MARGIN
	var near_right_wide := px > content_size.x - CORNER_MARGIN
	if near_bottom_wide and near_left_wide:
		return "bottomleft"
	if near_bottom_wide and near_right_wide:
		return "bottomright"

	# Bords simples: bande fine (BORDER_MARGIN), hors des zones de coin.
	var edge := ""
	if py > content_size.y - BORDER_MARGIN:
		edge += "bottom"
	if px < BORDER_MARGIN:
		edge += "left"
	elif px > content_size.x - BORDER_MARGIN:
		edge += "right"
	return edge
