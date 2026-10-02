extends Node3D
## Quads 3D des fenêtres Wayland mappées et de leurs popups, plus toute la
## logique de pointage raycast : hover, clic, grab, déplacement et
## redimensionnement depuis la caméra du joueur.
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

signal window_created(window_id: int, quad: MeshInstance3D)
# Émis quand l'ensemble des fenêtres locales change (map/unmap, hide/show,
# taille, fin de déplacement/redimensionnement, plein écran) : le LAN s'en
# sert pour resynchroniser les quads noirs des autres joueurs.
signal windows_state_changed

const BORDER_MARGIN = 10 # en pixels sur la texture, zone de bord = redimensionnement
const CORNER_MARGIN = 20 # px, zone de coin (carrée, plus large que BORDER_MARGIN
						 # pour rester cliquable via raycast) = redimensionnement diagonal
const MIN_SURFACE_SIZE = 500 # px, garde-fou anti-fenêtre-écrasée
# Multiplicateur de taille des quads en unités monde : agrandit l'affichage
# 3D des fenêtres sans toucher à la résolution de l'image (les pixels par
# unité monde sont divisés d'autant, l'échantillonnage reste le même).
const WINDOW_QUAD_SCALE := 2.0

const Decorations := preload("res://scripts/ui/window_decorations.gd")
const WindowDecoration := preload("res://scripts/windows/window_decoration_3d.gd")

# Barre de titre du jeu (décorations server-side). Le compositeur répond
# SERVER_SIDE à xdg-decoration-v1 : les clients (dont xwayland-satellite,
# qui crashe si on lui laisse dessiner ses barres) ne dessinent rien, c'est
# le jeu qui affiche la barre au-dessus du contenu de chaque fenêtre.
# La géométrie de la barre ne vit plus ici : elle vient des SVG et du
# `decorations.json` de `ui/decorations/`, convertis en monde par fenêtre.
# Épaisseur (m) du BoxOccluder3D plaqué sur chaque quad fenêtre : assez fine
# pour rester proche du plan visuel, assez épaisse pour être rasterisée
# proprement par l'occlusion culling.
const WINDOW_OCCLUDER_DEPTH := 0.04

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

# Position de spawn des nouvelles fenêtres : toujours 1 m devant la caméra,
# mais décalée de STACK_Z_OFFSET derrière la précédente pour chaque fenêtre
# déjà présente à cet endroit, pour que deux fenêtres ouvertes coup sur coup
# ne s'empilent pas au même endroit. Même empilement qu'à la sortie du mode
# focus (voir focus_mode.gd).
const STACK_Z_OFFSET := 0.1 # m entre deux fenêtres empilées
const SPAWN_STACK_RADIUS := 0.5 # m, portée de détection des fenêtres déjà empilées au point de spawn

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

const WAYLAND_SHADER_CODE = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_always;

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0, 0.0);

void fragment() {
	// Quand le buffer d'allocation (VkImage / texture) est plus grand que
	// le contenu réel (allocation arrondie au palier supérieur, ou surface
	// réduite sans réallocation), le UV doit être remappé pour n'échantil-
    // lonner que la zone de contenu. Sans ça, UV [0,1] couvre la totalité
    // de la texture (y compris la zone transparente/stale), déformant
	// l'image.
	vec2 ts = vec2(textureSize(window_texture, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	vec4 tex = texture(window_texture, mapped_uv);
	if (tex.a > 0.01) {
		vec3 unmultiplied = tex.rgb / max(tex.a, 0.001);
		ALBEDO = pow(unmultiplied, vec3(2.2));
		ALPHA = clamp(tex.a * 2.0, 0.0, 1.0);
	} else {
		discard;
	}
}
"""

# Variante sans depth test : utilisée quand l'effet "find" est actif pour
# que le contenu de la fenêtre reste visible même derrière d'autres quads.
const WAYLAND_SHADER_NO_DEPTH_CODE = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled;

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0, 0.0);

void fragment() {
	vec2 ts = vec2(textureSize(window_texture, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	vec4 tex = texture(window_texture, mapped_uv);
	if (tex.a > 0.01) {
		vec3 unmultiplied = tex.rgb / max(tex.a, 0.001);
		ALBEDO = pow(unmultiplied, vec3(2.2));
		ALPHA = clamp(tex.a * 2.0, 0.0, 1.0);
	} else {
		discard;
	}
}
"""

var compositor: WlrCompositor
var player: Node3D

var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var window_textures: Dictionary = {} # window_id (int) -> Texture2D
var window_titles: Dictionary = {} # window_id (int) -> String
var window_shared: Dictionary = {} # window_id (int) -> bool (visible par les autres joueurs)
var _texture_versions: Dictionary = {} # window_id (int) -> int (version du contenu, pour le LAN)
var fullscreen_windows: Dictionary = {} # window_id (int) -> bool (plein écran)
var window_server_side: Dictionary = {} # window_id (int) -> true si SSD, false si CSD
var popup_parent_info: Dictionary = {} # popup_id -> {parent_window_id, parent_popup_id, x, y, width, height}

# Shader UNIQUE partagé par toutes les fenêtres/popups. Le créer une seule
# fois évite à Godot de recompiler le shader à chaque ouverture de fenêtre
# (compile synchrone sur le thread principal au premier dessin → gros stall /
# chute de FPS perceptible). Le ShaderMaterial reste propre à chaque quad
# (uniformes window_texture/content_size), seule la ressource Shader est
# partagée.
var _shared_window_shader: Shader = null
var _shared_window_shader_no_depth: Shader = null

var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune

var resizing_edge := "" # "left", "right", "top", "bottom", etc.
var is_resizing := false
# Bouton de barre survolé : évite d'écrire une texture par frame quand rien
# n'a changé.
var _hover_btn: StaticBody3D = null
var is_moving := false
var active_window_id := -1
var is_in_window := false
# Déplacement: distance (caméra -> fenêtre) figée au moment du grab, la
# fenêtre suit ensuite le viseur le long de ce rayon.
var move_depth := 0.0

# Fenêtre sur laquelle celle-ci est collée : wid -> {wid, side}
var snapped_to: Dictionary = {} # wid (int) -> Dictionary

# Collage coupé (réglage pause_menu > GENERAL > Disable Window Snapping).
# Ne coupe que la DÉTECTION : un collage déjà établi se poursuit exactement
# comme si le pointeur s'en éloignait — la coupure est faite APRÈS la branche
# « déjà collée » de _find_snap, jamais avant.
var snapping_enabled := true

# Orientation figée par fenêtre : wid -> Basis.
# Avant, une fenêtre était un billboard — `global_basis = base caméra` réécrit
# à chaque frame, plus un yaw appliqué par-dessus. Une fenêtre qui hérite de
# l'orientation de sa voisine ne peut PAS rester un billboard : ce modèle
# écraserait l'héritage dès la frame suivante. D'où une base stockée, écrite
# uniquement à la création, à l'héritage du collage et au scroll de rotation.
var _window_basis: Dictionary = {} # wid (int) -> Basis

# Fenêtre dont les zones de collage sont en surveillance (monitoring actif).
var _snap_monitoring_wid := -1
# Couple (cible:côté:côté) qu'on vient de décoller : interdit de recoller tant
# que les zones se recouvrent encore, sinon la fenêtre recolle aussitôt.
var _snap_lockout := ""

# Redimensionnement: même principe de rayon à profondeur fixe, mais on
# garde aussi la base locale du quad et ses dimensions de départ pour
# convertir le déplacement du viseur (unités monde) en pixels de surface.
var resize_depth := 0.0
var resize_start_world := Vector3.ZERO
var resize_right_dir := Vector3.RIGHT
var resize_up_dir := Vector3.UP
var window_start_size := Vector2.ZERO # taille geometry (px) au moment du grab
var window_start_mesh_size := Vector2.ONE # taille quad (unités monde) au moment du grab
var window_start_local_pos := Vector3.ZERO # position locale du quad au moment du grab
var window_start_content_offset := Vector2.ZERO # offset geometry dans la surface au moment du grab
# Charnière du redimensionnement en cours : "" (plan), "yaw" (bord latéral
# partagé tiré) ou "pitch" (bord haut/bas partagé tiré). Le bord tiré peut alors
# bouger en PROFONDEUR, donc la fenêtre tirée pivote autour de son bord opposé
# (et sa voisine aussi, cf. _update_shared_edge). La profondeur se règle en
# regardant le long de l'axe du pivot (voir hinge_mode_for / RESIZE_DEPTH_GAIN).
var resize_hinge_mode := ""
var resize_start_basis := Basis.IDENTITY
var resize_start_pos := Vector3.ZERO

var pre_fullscreen_mesh_sizes: Dictionary = {} # wid (int) -> Vector2
var pre_fullscreen_surface_sizes: Dictionary = {} # wid (int) -> Vector2

var _group_grab := false
var _grab_action := "grab"
var _group_rel: Dictionary = {} # wid -> Transform3D relatif à la fenêtre saisie

func setup(compositor_ref: WlrCompositor, player_ref: Node3D) -> void:
	compositor = compositor_ref
	player = player_ref

func _camera() -> Camera3D:
	return player.get_node("Camera3D") as Camera3D

func _window_shader() -> Shader:
	if _shared_window_shader == null:
		_shared_window_shader = Shader.new()
		_shared_window_shader.code = WAYLAND_SHADER_CODE
	return _shared_window_shader

func _window_shader_no_depth() -> Shader:
	if _shared_window_shader_no_depth == null:
		_shared_window_shader_no_depth = Shader.new()
		_shared_window_shader_no_depth.code = WAYLAND_SHADER_NO_DEPTH_CODE
	return _shared_window_shader_no_depth

func next_spawn_pos() -> Vector3:
	var camera: Camera3D = _camera()
	var cam_pos: Vector3 = camera.global_position
	var cam_forward: Vector3 = -camera.global_basis.z
	# Position de base : 2 m devant la caméra.
	var base_pos := cam_pos + cam_forward * 2.0
	# Compter les fenêtres visibles déjà à cet endroit : chaque fenêtre dans
	# le rayon SPAWN_STACK_RADIUS du point de spawn décale la nouvelle de
	# STACK_Z_OFFSET derrière la précédente.
	var offset := 0.0
	for wid in quads:
		var quad: MeshInstance3D = quads[wid]
		if not is_instance_valid(quad) or not quad.visible:
			continue
		if quad.global_position.distance_to(base_pos) < SPAWN_STACK_RADIUS:
			offset += STACK_Z_OFFSET
	return base_pos - cam_forward * offset

func get_window_texture(wid: int) -> Texture2D:
	return window_textures.get(wid, null)

# État des fenêtres locales pour le partage LAN (quads des autres joueurs) :
# une entrée par fenêtre (partagée OU non), en coordonnées MONDE (le quad vit
# sous Windows3D, à l'identité de la room, pas dans le repère du niveau).
# « shared » vaut false → le quad distant reste noir (placeholder) ;
# « shared » vaut true → le contenu réel est streamé (voir get_window_image).
func get_windows_state() -> Array:
	var list: Array = []
	for wid in quads:
		var quad: MeshInstance3D = quads[wid]
		if not is_instance_valid(quad):
			continue
		var size := Vector2.ONE
		if quad.mesh is QuadMesh:
			size = (quad.mesh as QuadMesh).size
		list.append({
			"wid": wid,
			"transform": quad.global_transform,
			"size": size,
			"visible": quad.visible,
			"shared": window_shared.get(wid, false),
			"pid": compositor.get_window_pid(wid) if compositor != null else -1,
		})
	return list

# Image CPU actuelle d'une fenêtre, pour le stream « partage » vers les autres
# joueurs. Renvoie null si la fenêtre n'a pas encore de contenu.
# Deux chemins possibles côté compositeur :
#  - fallback CPU → ImageTexture : get_image() est direct ;
#  - chemin Vulkan zero-copy → Texture2DRD : get_image() renvoie null, on lit
#    alors l'image CPU que le compositeur a produite de façon synchrone à la
#    capture (get_window_cpu_image) — le readback RD différé lisait parfois un
#    buffer réutilisé (contenu de la scène au lieu de la fenêtre).
func get_window_image(wid: int) -> Image:
	var tex: Texture2D = window_textures.get(wid)
	if tex == null or not is_instance_valid(tex):
		return null
	if tex is Texture2DRD:
		# Chemin Vulkan zero-copy : l'affichage in-game échantillonne le
		# VkImage (correct), mais tex.get_image() ferait un readback RD
		# DIFFÉRÉ (texture_get_data exécuté plus tard sur le thread de rendu)
		# qui peut lire un buffer réutilisé → contenu de la scène au lieu de
		# la fenêtre. On lit donc la copie CPU faite de façon SYNCHRONE à la
		# capture (get_window_cpu_image), juste après le render pass et la
		# synchro DMA-BUF : elle ne peut pas être « tardive ».
		if compositor != null and compositor.has_method("get_window_cpu_image"):
			var cimg: Image = compositor.get_window_cpu_image(wid)
			if cimg != null and not cimg.is_empty():
				if not _debug_share_path.has(wid):
					_debug_share_path[wid] = "cpu_image"
					print("[share] ", wid, " path=cpu_image ", cimg.get_width(), "x", cimg.get_height())
				return cimg
			if not _debug_share_path.has(wid):
				_debug_share_path[wid] = "cpu_image_null"
				print("[share] ", wid, " path=cpu_image NULL (tex ", tex.get_class(), ")")
		return null
	var img := tex.get_image()
	if img != null and not img.is_empty():
		if not _debug_share_path.has(wid):
			_debug_share_path[wid] = "image_texture"
			print("[share] ", wid, " path=image_texture ", tex.get_width(), "x", tex.get_height(),
				" title=", _window_title(wid), " app=", _window_app_id(wid))
		return img
	return null

var _debug_share_path := {}

func _window_title(wid: int) -> String:
	if compositor == null or not compositor.has_method("get_window_list"):
		return ""
	for entry in compositor.get_window_list():
		if int(entry.get("id", -1)) == wid:
			return str(entry.get("title", ""))
	return ""

func _window_app_id(wid: int) -> String:
	if compositor == null or not compositor.has_method("get_window_list"):
		return ""
	for entry in compositor.get_window_list():
		if int(entry.get("id", -1)) == wid:
			return str(entry.get("app_id", ""))
	return ""

# Version du contenu d'une fenêtre (incrémentée à chaque capture). Le LAN ne
# stream une frame que si la version a changé, pour ne pas ré-encoder une
# fenêtre statique à chaque tick.
func get_window_texture_version(wid: int) -> int:
	return int(_texture_versions.get(wid, 0))

# Active/désactive la visibilité d'une fenêtre pour les autres joueurs
# (partage « screenshare » : aucun contrôle distant, juste l'affichage).
func set_window_shared(wid: int, shared: bool) -> void:
	window_shared[wid] = shared
	windows_state_changed.emit()

func is_window_shared(wid: int) -> bool:
	return window_shared.get(wid, false)

# Vrai si le joueur local déplace ou redimensionne une fenêtre : pendant
# ce temps le LAN envoie l'état des fenêtres à haute fréquence.
func is_window_interacting() -> bool:
	return is_moving or is_resizing

# Infos nécessaires au mode focus pour basculer la fenêtre en overlay 2D.
func get_quad_info(id: int) -> Dictionary:
	var info := {}
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return info
	var quad: MeshInstance3D = quads[id]
	var mat := quad.material_override as ShaderMaterial
	info["texture"] = mat.get_shader_parameter("window_texture") if mat else null
	var body: StaticBody3D = quad.get_child(0)
	info["surface_size"] = body.get_meta("surface_size", Vector2(1, 1))
	info["content_offset"] = body.get_meta("content_offset", Vector2.ZERO)
	info["content_size"] = body.get_meta("content_size", Vector2(1, 1))
	return info

func set_quad_visible(id: int, visible: bool) -> void:
	if quads.has(id) and is_instance_valid(quads[id]):
		var quad: MeshInstance3D = quads[id]
		quad.visible = visible
		_set_quad_interactive(quad, visible)

# L'occluder doit couvrir l'EMPREINTE VISIBLE, cadre et barre compris : sinon
# le culling mange les bords du décor quand deux fenêtres se font face.
func _sync_occluder(occ: OccluderInstance3D, quad: MeshInstance3D) -> void:
	# La boîte est lue dans les MÉTADONUES et pas dans `occ.occluder` : pendant
	# un resize détaché `occ.occluder` vaut null, la boîte ne vit plus que là.
	# Sans cette nuance, le réattachement resynchroniserait un objet vide et
	# laisserait l'occluder à sa taille périmée.
	var box := occ.get_meta("occluder_box", null) as BoxOccluder3D
	if box == null:
		box = occ.occluder as BoxOccluder3D
	if box == null:
		return
	var mesh := quad.mesh as QuadMesh
	if mesh == null:
		return
	var deco := _deco_of(quad)
	occ.position = Vector3(0.0, (deco["titlebar"] - deco["border"]) * 0.5, 0.0)
	box.size = Vector3(mesh.size.x + deco["border"] * 2.0,
		mesh.size.y + deco["titlebar"] + deco["border"], WINDOW_OCCLUDER_DEPTH)

# Active/désactive toutes les collisions d'un quad (corps du contenu, barre
# de titre, boutons, cadre) : un quad invisible ne doit plus être touchable.
# Paramètre `Node3D` et non `MeshInstance3D` : la récursion traverse des
# conteneurs qui ne sont pas des maillages, dont l'occluder et le décor.
func _set_quad_interactive(quad: Node3D, enabled: bool) -> void:
	for child in quad.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D:
					shape_node.disabled = not enabled
		elif child is Node3D and not (child is Area3D):
			# Node3D et pas MeshInstance3D : le décor est un simple conteneur,
			# la récursion doit le traverser. Area3D exclus : les zones de
			# collage sont today ignorées par cette fonction, on ne change rien.
			_set_quad_interactive(child, enabled)

# La fenêtre actuellement déplacée (grab menu), -1 si aucune.
func get_grabbed_window_id() -> int:
	return active_window_id if is_moving else -1

func is_window_grabbed(wid: int) -> bool:
	return is_moving and active_window_id == wid

func release_window_grab(wid: int) -> void:
	if not is_window_grabbed(wid):
		return
	is_moving = false
	active_window_id = -1
	_end_group_grab()
	_set_window_occluder_active(wid, true)
	windows_state_changed.emit()

# Détache (active=false) ou réattache (active=true) l'occluder d'une fenêtre
# au buffer d'occlusion. Pendant un grab/drag/resize, le quad réécrit sa
# transform à CHAQUE frame (grab billboard : _update_move fait un lerp de
# position + basis = caméra). Dans le moteur (4.7 : modules/raycast/
# raycast_occlusion_cull.cpp, Scenario::update + scenario_set_instance),
# tout changement de transform d'un OccluderInstance3D marque le scénario
# comme dirty → reconstruction COMPLÈTE de la scène Embree à la frame suivante
# (incluant l'occluder statique AutoOcclusion du niveau, jusqu'à 120k
# triangles) → gros coût CPU par frame pendant toute l'opération.
# Simple masquage (visible=false) NE SUFFIT PAS : le changement de transform
# re-dirt quand même à chaque frame (les occluders masqués restent enregistrés
# et leurs mises à jour de transform sont propagées). Il faut donc DÉTACHER le
# base (occ.occluder = null → set_base(RID()) → scenario_remove_instance).
# La fenêtre en cours de déplacement est de toute façon la plus proche de la
# caméra : ne pas occlure l'arrière-plan pendant l'opération n'est pas
# perceptible.
# Le booléen est appelé `active` pour rester cohérent avec les appelants
# (active=true au lâcher, active=false au début de l'opération).
func _set_window_occluder_active(wid: int, active: bool) -> void:
	if not quads.has(wid):
		return
	var occ := quads[wid].get_node_or_null("Occluder") as OccluderInstance3D
	if occ == null:
		return
	if active:
		var occ_box := occ.get_meta("occluder_box", null) as BoxOccluder3D
		if occ_box != null:
			# Resynchronise la taille : pendant un resize détaché le box n'est
			# plus mis à jour (gardé dans les métadonnées), il peut donc être
			# périmé par rapport au mesh au moment de réattacher.
			_sync_occluder(occ, quads[wid])
			if occ.occluder == null:
				occ.occluder = occ_box
	else:
		occ.occluder = null

# Toggle grab depuis le menu fenêtres : reprend une fenêtre déjà en cours de
# déplacement (is_moving) ou lâche la prise et la pose à sa position actuelle.
func toggle_grab_window(wid: int) -> void:
	if is_window_grabbed(wid):
		release_window_grab(wid)
		return
	if not quads.has(wid) or not is_instance_valid(quads[wid]):
		return
	var quad: MeshInstance3D = quads[wid]
	var cam := _camera()
	active_window_id = wid
	is_moving = true
	_set_window_occluder_active(wid, false)
	move_depth = cam.global_position.distance_to(quad.global_position)
	windows_state_changed.emit()

func toggle_hide(id: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	quad.visible = not quad.visible
	_set_quad_interactive(quad, quad.visible)
	windows_state_changed.emit()

func on_window_mapped(id: int, title: String, _app_id: String) -> void:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.6, 1.0) * WINDOW_QUAD_SCALE # ratio ajusté au premier texture_updated
	quad.mesh = mesh

	var shader := _window_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 0
	quad.material_override = mat
	# Surface plane qui projette une ombre : acné d'ombrage/aliasing au bord
	# (l'ombre "scintille" au sol/mur autour de la fenêtre). Une surface
	# d'app n'a pas vocation à jeter une ombre dure : on la désactive.
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var body := StaticBody3D.new()
	
	body.collision_layer = 2
	body.collision_mask = 2
	
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# Épaisseur fine : la face avant du boîtier reste proche du plan visuel
	# du quad, sinon le raycast renvoie un point décalé en incidence rasant.
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.01)
	col.shape = shape
	body.add_child(col)
	body.set_meta("window_id", id)
	quad.add_child(body)

	# Zones de collage : 4 Area3D, une par côté, enfants du quad. Enfant du
	# quad => position, rotation et taille suivent gratuitement, sans code par
	# frame ni reconstruction de cadre à chaque frame.
	_build_snap_zones(quad)

	# Occlusion culling : boîte fine alignée sur le quad. Enfant du quad →
	# suit grab/déplacement/rotation sans code par frame, et se désactive
	# automatiquement quand la fenêtre est cachée (hide/minimise/focus).
	# La dimension est tenue à jour par _sync_decorations(), appelée après
	# chaque changement de taille du mesh.
	var occ := OccluderInstance3D.new()
	occ.name = "Occluder"
	var occ_box := BoxOccluder3D.new()
	occ_box.size = Vector3(mesh.size.x, mesh.size.y, WINDOW_OCCLUDER_DEPTH)
	occ.occluder = occ_box
	# Référence conservée par _set_window_occluder_active() : détacher
	# l'occluder (occ.occluder = null) lâche la dernière référence autrement.
	occ.set_meta("occluder_box", occ_box)
	quad.add_child(occ)
	_sync_occluder(occ, quad)

	# Barre de titre du jeu (SSD) : quad coloré + Label3D posés AU-DESSUS du
	# contenu (ne recouvre jamais le contenu de l'app). Ajoutée APRÈS body
	# pour que quad.get_child(0) continue de renvoyer le corps du contenu.
	window_titles[id] = title
	WindowDecoration.build(quad, id, title)

	add_child(quad)
	quads[id] = quad
	window_shared[id] = false
	quad.global_position = next_spawn_pos()
	var camera := _camera()

	# Face caméra à la création. Écriture directe : aucune rotation n'a encore
	# été appliquée à cette fenêtre, il n'y a donc pas d'état à conserver.
	quad.global_basis = camera.global_transform.basis

	window_created.emit(id, quad)

func _process(delta: float) -> void:
	# Le décor est rechargé depuis un fichier, comme le thème CSS : le tick
	# renvoie true quand un mtime a changé.
	if Decorations.tick(delta):
		_sync_all_decorations()

func _sync_all_decorations() -> void:
	for id: int in quads.keys():
		var quad: MeshInstance3D = quads[id]
		if is_instance_valid(quad):
			_sync_decorations(quad)
	windows_state_changed.emit()

# Le client peut changer son titre à tout moment (xdg-shell set_title) :
# met à jour l'étiquette de la barre de titre du jeu.
func on_window_title_changed(id: int, title: String) -> void:
	window_titles[id] = title
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var bar_label: Label3D = quads[id].get_node_or_null("Titlebar/Label3D")
	if bar_label != null:
		bar_label.text = title
	windows_state_changed.emit()

# Recalcule décor et barre de titre après un changement de taille du contenu.
func _sync_decorations(quad: MeshInstance3D) -> void:
	# Zones de collage resynchronisées en PREMIER, avant tout early return : une
	# fenêtre sans barre de titre doit malgré tout avoir ses zones à la bonne
	# taille.
	_sync_snap_zones(quad)
	WindowDecoration.sync(quad)
	var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
	if occ != null:
		_sync_occluder(occ, quad)

# Active/désactive les collisions des éléments de la barre de titre
# (BarBody de redimensionnement + boutons) quand la décoration est masquée.
func _set_titlebar_interactive(titlebar: MeshInstance3D, enabled: bool) -> void:
	for child in titlebar.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D:
					shape_node.disabled = not enabled

# Montre/cache les boutons minimiser/maximiser/fermer de la barre de titre.
func _set_titlebar_buttons(titlebar: MeshInstance3D, enabled: bool) -> void:
	for btn_name in ["BtnClose", "BtnMaximize", "BtnMinimize"]:
		var btn := titlebar.get_node_or_null(btn_name) as StaticBody3D
		if btn == null:
			continue
		btn.visible = enabled
		for shape_node in btn.get_children():
			if shape_node is CollisionShape3D:
				shape_node.disabled = not enabled

# Montre/cache la barre de titre du jeu selon la décoration : SERVER_SIDE =>
# le compositeur gère la décoration (le jeu la dessine, boutons inclus) ;
# sinon le client dessine la sienne (CSD, ex. Firefox) : on affiche quand
# même la barre du jeu (titre + zone de drag) mais SANS les boutons, car le
# client a déjà ses propres boutons dans son contenu.
func on_window_decorations_changed(id: int, server_side: bool) -> void:
	window_server_side[id] = server_side
	if not quads.has(id):
		return
	var quad: MeshInstance3D = quads[id]
	var titlebar: MeshInstance3D = quad.get_node_or_null("Titlebar")
	if titlebar == null:
		return
	titlebar.visible = true
	_set_titlebar_interactive(titlebar, true)
	_set_titlebar_buttons(titlebar, server_side)
	WindowDecoration.set_frame_visible(quad, server_side)

func on_window_unmapped(id: int) -> void:
	if focused_window_id == id:
		focused_window_id = -1
	
	_erase_window_state(id)
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
			if occ != null:
				occ.queue_free()
				await get_tree().physics_frame
			quad.queue_free()
		quads.erase(id)
	windows_state_changed.emit()

# Vrai si le mesh de cette fenêtre est piloté par le redimensionnement en cours
# (la fenêtre tirée, ou une voisine qui partage son bord).
func _is_resize_controlled(id: int) -> bool:
	if not is_resizing:
		return false
	if id == active_window_id:
		return true
	for r in _resize_shared:
		if int(r["wid"]) == id:
			return true
	return false

func on_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	# Tracker la texture pour le menu de navigation
	window_textures[id] = texture
	# Version du contenu : incrémentée à chaque nouvelle capture, utilisée par
	# le LAN pour n'envoyer une frame que quand la fenêtre a réellement changé.
	_texture_versions[id] = _texture_versions.get(id, 0) + 1

	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	# Toujours mettre à jour la texture du shader : le pipeline Vulkan peut
	# avoir créé un nouveau VkImage/Texture2DRD si la taille a changé, et
	# l'ancien a été libéré. Ne pas mettre à jour laissait le shader
	# échantillonner un VkImage libéré → tearing/corruption GPU.
	(quad.material_override as ShaderMaterial).set_shader_parameter("window_texture", texture)
	# content_size = taille réelle du contenu (w × h). Le shader s'en
	# sert pour remapper UV quand le buffer d'allocation est plus grand
	# (round_up_capture_size) — sans ça, le contenu serait comprimé
	# dans le coin supérieur-gauche du mesh.
	(quad.material_override as ShaderMaterial).set_shader_parameter("content_size", Vector2(width, height))

	# Toujours synchroniser les métadonnées (surface_size, content_offset,
	# content_size) même pendant un resize : le calcul UV pour le forwarding
	# des événements pointeur utilise surface_size, et les détections de
	# bord utilisent content_size/content_offset. Sans ça, les UV sont
	# wrong dès que le client commite la nouvelle taille.
	var body: StaticBody3D = quad.get_child(0)
	body.set_meta("surface_size", Vector2(width, height))
	var geo := compositor.get_window_geometry(id)
	body.set_meta("content_offset", Vector2(geo["x"], geo["y"]))
	body.set_meta("content_size", Vector2(geo["width"], geo["height"]))

	# Pendant un redimensionnement actif, _update_resize contrôle la taille
	# du mesh, la position du quad et la CollisionShape3D. Ne pas écraser
	# ces valeurs ici : la texture capturée est probablement encore à
	# l'ancienne taille (le client n'a pas encore committé le buffer à la
	# nouvelle taille), donc recalculer le mesh sur sa base causerait un
	# flickering entre l'aspect cible et l'aspect stale à chaque frame.
	# Idem pour les voisines qui partagent le bord tiré : leur mesh est piloté par
	# _update_shared_edge. Sans ce garde, une texture encore à l'ancienne taille
	# réécrivait leur largeur à chaque frame (sans recaler la position) : le
	# bord partagé s'ouvrait ou se chevauchait visuellement.
	if _is_resize_controlled(id):
		return

	# Garde le ratio d'aspect réel de la fenêtre. Utilise la hauteur
	# courante du mesh (pas un hardcoded 3.0) pour éviter un saut de
	# taille après un resize où la hauteur a été interpolée.
	var aspect := float(width) / float(max(height, 1))
	var mesh: QuadMesh = quad.mesh
	var current_h: float = mesh.size.y if mesh.size.y > 0.0 else 3.0
	# Fenêtre fraîche (jamais redimensionnée à la main) : on dimensionne le
	# quad d'après sa taille naturelle en pixels, la hauteur du viewport
	# servant de référence (viewport_height px -> 1.0 unité monde). Sans ça,
	# une fenêtre de 300 px de haut s'ouvrirait aussi grande qu'une fenêtre
	# plein écran. Dès que le joueur a redimensionné la fenêtre (user_sized),
	# la taille monde choisie est conservée, seule l'aspect suit le client.
	if not body.get_meta("user_sized", false):
		var vh: float = get_viewport().get_visible_rect().size.y
		if vh > 0.0:
			current_h = float(height) / vh
		current_h = max(current_h, 0.05)
		# WINDOW_QUAD_SCALE s'applique uniquement à la hauteur calculée
		# depuis les pixels. Pour une fenêtre user_sized, current_h est
		# déjà une hauteur monde échelonnée (mesh.size.y) : la re-multiplier
		# doublerait la fenêtre à chaque texture_updated → croissance infinie.
		current_h *= WINDOW_QUAD_SCALE
	mesh.size = Vector2(current_h * aspect, current_h)

	# La CollisionShape3D doit suivre la même taille que le mesh, sinon le
	# raycast teste une zone qui ne correspond plus à ce qui est affiché.
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
	_sync_decorations(quad)
	windows_state_changed.emit()

func on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	var parent_quad: MeshInstance3D = null
	var parent_px_size := Vector2(1, 1)

	if parent_popup_id != -1 and popup_quads.has(parent_popup_id) and is_instance_valid(popup_quads[parent_popup_id]):
		# Sous-menu: parenté sur le popup qui l'a ouvert, pas sur la fenêtre racine.
		parent_quad = popup_quads[parent_popup_id]
		parent_px_size = parent_quad.get_meta("surface_size", Vector2(1, 1))
	elif quads.has(parent_window_id) and is_instance_valid(quads[parent_window_id]):
		parent_quad = quads[parent_window_id]
		var parent_body: StaticBody3D = parent_quad.get_child(0)
		parent_px_size = parent_body.get_meta("surface_size", Vector2(1, 1))

	if parent_quad == null:
		return

	var parent_mesh: QuadMesh = parent_quad.mesh

	# Conversion pixels -> mètres, en réutilisant l'échelle déjà connue du
	# parent immédiat (mêmes unités que sa propre capture de texture).
	var _scale := Vector2(
		parent_mesh.size.x / max(parent_px_size.x, 1.0),
		parent_mesh.size.y / max(parent_px_size.y, 1.0)
	)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(max(width * _scale.x, 0.01), max(height * _scale.y, 0.01))
	quad.mesh = mesh
	# Mémorisé pour qu'un éventuel sous-sous-menu puisse recalculer son
	# échelle à partir de CE popup plutôt que de la fenêtre racine, et pour
	# que _on_popup_texture_updated puisse redimensionner le mesh sur la
	# même base quand le buffer réel (potentiellement plus grand que la
	# géométrie logique ci-dessus) arrive.
	quad.set_meta("surface_size", Vector2(width, height))
	quad.set_meta("px_scale", _scale)

	# (x, y) = coin haut-gauche du popup relatif au coin haut-gauche de la
	# géométrie du parent immédiat. Le quad parent est centré sur son
	# origine locale, d'où le décalage de -size/2 pour repartir du vrai
	# coin haut-gauche.
	var local_left := -parent_mesh.size.x / 2.0 + x * _scale.x
	var local_top := parent_mesh.size.y / 2.0 - y * _scale.y
	quad.position = Vector3(
		local_left + mesh.size.x / 2.0,
		local_top - mesh.size.y / 2.0,
		0.02 # léger décalage devant le parent pour éviter le z-fighting
	)
	print("popup_layout: id=", id, " x=", x, " y=", y, " w=", width, " h=", height,
		" scale=", _scale, " quad_pos=", quad.position, " mesh_size=", mesh.size)

	var shader := _window_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 1 # Force l'affichage au-dessus des fenêtres
	quad.material_override = mat
	# Idem fenêtres : pas d'ombre (surface plate) pour éviter le scintillement.
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Les tooltips ont une région d'input vide: on les affiche mais on ne
	# crée pas de collision body, pour que le raycast passe au travers et
	# atteigne la fenêtre/le popup en dessous. Attention: Firefox committe
	# parfois l'input region dans le MÊME commit que le buffer (hamburger
	# menu) - au moment de popup_mapped elle est encore vide, donc on
	# re-vérifiera dans _on_popup_texture_updated quand le buffer arrive.
	if compositor.popup_accepts_input(id):
		_add_popup_collider(quad, id, width, height)
	else:
		quad.set_meta("tooltip", true)

	parent_quad.add_child(quad)
	popup_quads[id] = quad

	# Stocker les infos parent pour le mode focus
	popup_parent_info[id] = {
		"parent_window_id": parent_window_id,
		"parent_popup_id": parent_popup_id,
		"x": x, "y": y, "width": width, "height": height
	}

# Crée le collider du popup (raycast → hover/clic vers le client).
func _add_popup_collider(quad: MeshInstance3D, id: int, width: int, height: int) -> void:
	if quad.get_child_count() > 0:
		return
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3((quad.mesh as QuadMesh).size.x, (quad.mesh as QuadMesh).size.y, 0.01)
	col.shape = shape
	body.add_child(col)
	body.set_meta("popup_id", id)
	body.set_meta("surface_size", Vector2(width, height))
	quad.add_child(body)

func on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)
	popup_parent_info.erase(id)

func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not popup_quads.has(id) or not is_instance_valid(popup_quads[id]):
		return
	var quad: MeshInstance3D = popup_quads[id]
	(quad.material_override as ShaderMaterial).set_shader_parameter("window_texture", texture)
	(quad.material_override as ShaderMaterial).set_shader_parameter("content_size", Vector2(width, height))
	# popup_mapped donne la géométrie logique (xdg_surface.set_window_geometry),
	# utilisée uniquement pour le placement relatif au parent. Le buffer
	# réellement capturé ici peut être plus grand (marge d'ombre ajoutée par
	# le client, GTK/Qt notamment) - sans cette resynchronisation, le hover
	# convertissait les uv avec l'échelle de la géométrie logique au lieu de
	# celle du buffer affiché, envoyant des coordonnées fausses au client.
	var mesh: QuadMesh = quad.mesh
	var old_size := mesh.size
	var aspect := float(width) / float(max(height, 1))
	mesh.size = Vector2(old_size.y * aspect, old_size.y) if old_size.y > 0.0 else Vector2(1, 1)

	quad.set_meta("surface_size", Vector2(width, height)) # utilisé par un éventuel sous-menu

	# Les tooltips n'ont pas de collision body (pas d'input region). Si le
	# popup a été marqué tooltip au map mais que l'input region a été
	# committée avec le buffer (Firefox hamburger menu), on crée le collider
	# tardivement ici. Sinon on resynchronise sa taille sur le buffer.
	if quad.get_child_count() == 0 and quad.has_meta("tooltip") and compositor.popup_accepts_input(id):
		_add_popup_collider(quad, id, width, height)
		quad.remove_meta("tooltip")
		print("popup_collider_late: id=", id, " w=", width, " h=", height)
	elif quad.get_child_count() > 0:
		var body: StaticBody3D = quad.get_child(0)
		body.set_meta("surface_size", Vector2(width, height))
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

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
	_sync_snap_monitoring(active_window_id if is_moving and not _group_grab else -1)
	# Efface le pointeur wayland de toutes les fenêtres : il n'est re-posé
	# que si le raycast atteint une fenêtre ci-dessous. Les branches de
	# retour (drag, raycast dans le vide) laissent ainsi les captures de
	# fenêtre OBS sans curseur.
	compositor.set_window_pointer(-1, 0, 0, false)
	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if is_moving:
		# Fenêtre collée : le scroll pivote au lieu de pousser/tirer. Le
		# push/pull n'est proposé QUE hors collage, sinon on perd le
		# depth-move existant — c'est le même scroll, deux sens selon l'état.
		if _scroll_rotates():
			_rotate_from_scroll(delta)
		else:
			# just_pressed AVANT is_action_pressed : sur la frame d'appui d'un
			# clic molette, les deux sont vrais — l'ordre inverse donnait toujours
			# le petit pas (0.05) au lieu du saut (0.25).
			if Input.is_action_just_pressed("scroll_up", false):
				move_depth += 0.25
			elif Input.is_action_pressed("scroll_up", false):
				move_depth += 0.05
			if Input.is_action_just_pressed("scroll_down", false):
				move_depth -= 0.25
			elif Input.is_action_pressed("scroll_down", false):
				move_depth -= 0.05
		if _group_grab:
			_update_group_move(ray_origin, ray_dir, delta)
		else:
			_update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab", true):
			_set_window_occluder_active(active_window_id, true)
			is_moving = false
			active_window_id = -1
			windows_state_changed.emit()
		if Input.is_action_just_released(_grab_action, true):
			_end_group_grab()
			_set_window_occluder_active(active_window_id, true)
			is_moving = false
			active_window_id = -1
			windows_state_changed.emit()
			return
		return
	if is_resizing:
		_update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click", false):
			_set_window_occluder_active(active_window_id, true)
			is_resizing = false
			_end_group_resize()
			resizing_edge = ""
			active_window_id = -1
			windows_state_changed.emit()
		return

	var to := ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	# Explicite, alors que c'est déjà le défaut : les zones de collage sont des
	# Area3D, et si ce rayon les touchait un jour, on saisirait la ZONE au
	# lieu du corps — le grab viserait à côté de la fenêtre attrapée.
	params.collide_with_areas = false
	var hit := space.intersect_ray(params)

	if hit.is_empty():
		is_in_window = false
		compositor.forward_pointer_leave()
		# Relâchement du clic dans le vide (ex: drop d'un drag-and-drop hors
		# de toute fenêtre) : window_id=-1 -> le compositeur route quand même
		# l'événement au seat et annule un drag actif le cas échéant.
		if Input.is_action_just_released("left_click", false):
			compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			compositor.forward_pointer_button(-1, 0x111, false)
		return

	var body: Node3D = hit.collider

	if body.has_meta("popup_id"):
		is_in_window = true
		_handle_popup_pointer(body, hit, ray_origin, ray_dir)
		return

	if body.has_meta("decoration_edge"):
		# Clic sur le cadre : il EST la bordure de la fenêtre, donc la poignée
		# de redimensionnement. Rien n'est forwardé vers l'app.
		is_in_window = true
		_handle_decoration_edge(body, ray_origin, ray_dir)
		return

	if body.has_meta("titlebar_button"):
		# Clic sur un bouton de la barre de titre : fermer/réduire/agrandir.
		# Pas de forward du pointeur vers l'app (ce n'est pas du contenu).
		is_in_window = true
		_handle_titlebar_button(body)
		return

	if body.has_meta("titlebar_of"):
		# Clic sur la barre de titre du jeu : on redimensionne la fenêtre par le
		# haut, on ne forward rien à l'app (la barre n'est pas du contenu
		# applicatif).
		is_in_window = true
		_handle_titlebar(body, ray_origin, ray_dir)
		return

	if not body.has_meta("window_id"):
		is_in_window = false
		compositor.forward_pointer_leave()
		# Idem : relâchement sur un collider sans fenêtre (mur, sol, etc.)
		# doit pouvoir annuler un drag-and-drop en cours.
		if Input.is_action_just_released("left_click", false):
			compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			compositor.forward_pointer_button(-1, 0x111, false)
		return
	else:
		is_in_window = true
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
	if not popup_quads.is_empty():
		print("raycast: WINDOW wid=", wid, " uv=", uv, " px=",
			uv.x * win_size.x + content_offset_fwd.x, " py=",
			uv.y * win_size.y + content_offset_fwd.y,
			" content_offset=", content_offset_fwd, " surf_size=", win_size)
	compositor.forward_pointer_motion(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y)
	# Position du pointeur dans la fenêtre (coordonnées surface, y vers le
	# bas) : servira à composer le curseur dans la capture fenêtre OBS quand
	# la source a coché « afficher le curseur ».
	compositor.set_window_pointer(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y, true)

	if Input.is_action_just_pressed("grab", true) and not interact_active:
		active_window_id = wid
		is_moving = true
		# Même détachement d'occluder que toggle_grab_window/resize :
		# pendant le grab le quad réécrit sa transform à CHAQUE frame
		# (billboard), ce qui rediriterait la scène Embree entière (incluant
		# l'AutoOcclusion du niveau) → gros pic CPU par frame. Le réattache
		# se fait au relâchement dans la branche is_moving de process_raycast.
		_set_window_occluder_active(wid, false)
		move_depth = _camera().global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab", true):
		active_window_id = wid
		is_moving = false
		move_depth = 0.0
	if Input.is_action_just_pressed("grab_group", true) and not interact_active:
		_start_group_grab(wid, quad)
	if Input.is_action_just_pressed("left_click", false):
		focused_window_id = wid
		# Le haut du contenu n'est PAS une zone de drag : le clic y part vers
		# l'app (barre d'outils, onglets CSD). Le redimensionnement depuis le
		# haut se fait sur la barre de titre du jeu (voir _handle_titlebar).
		var edge := _border_edge(uv, win_size, body)
		if edge != "":
			# Bord de la fenêtre -> redimensionnement.
			_start_resize(wid, quad, ray_origin, ray_dir, edge)
		else:
			compositor.forward_pointer_button(wid, 0x110, true) # BTN_LEFT (evdev)
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click", false):
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up", false) or Input.is_action_pressed("scroll_up", false):
		compositor.forward_pointer_axis(wid, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down", false) or Input.is_action_pressed("scroll_down", false):
		compositor.forward_pointer_axis(wid, 0, 100.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var mesh: QuadMesh = quad.mesh
	var pid: int = body.get_meta("popup_id")
	var info: Dictionary = popup_parent_info.get(pid, {})
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))

	var px: float
	var py: float
	if info.get("parent_popup_id", -1) == -1 and quads.has(info.get("parent_window_id", -1)):
		# Popup directement parenté à une fenêtre : les coordonnées envoyées
		# au client doivent être celles du plan de la FENÊTRE, pas du plan 3D
		# du popup. Le popup est avancé de z=0.02 devant la fenêtre (anti
		# z-fighting) : le rayon coupe les deux plans à des points différents
		# selon l'angle de la caméra (parallaxe), ce qui décalait les
		# coordonnées de ~7-9 px (suffisant pour que Firefox ferme le menu).
		# On réintersecte donc le rayon avec le plan de la fenêtre pour avoir
		# la position réelle du curseur, puis on retranche l'origine du popup
		# (géométrie xdg-shell = coordonnées surface du parent).
		var window_quad: MeshInstance3D = quads[info.parent_window_id]
		var window_body: StaticBody3D = window_quad.get_child(0)
		var window_mesh: QuadMesh = window_quad.mesh
		var window_surface_size: Vector2 = window_body.get_meta("surface_size", Vector2(1, 1))
		var window_content_offset: Vector2 = window_body.get_meta("content_offset", Vector2.ZERO)
		var window_uv := _uv_at_plane(window_quad, window_mesh, ray_origin, ray_dir, hit.position)
		var surface_pos := Vector2(
			window_uv.x * window_surface_size.x + window_content_offset.x,
			window_uv.y * window_surface_size.y + window_content_offset.y)
		px = surface_pos.x - float(info.x)
		py = surface_pos.y - float(info.y)
	else:
		# Sous-menu (parenté à un autre popup) : calcul direct sur le plan du
		# popup, même convention que précédemment.
		var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
		px = uv.x * win_size.x
		py = uv.y * win_size.y
	print("raycast: POPUP pid=", pid, " px=", px, " py=", py,
		" surf_size=", win_size, " quad_pos=", quad.global_position,
		" mesh_size=", mesh.size)
	compositor.forward_pointer_motion_popup(pid, px, py)

	if Input.is_action_just_pressed("scroll_up", false) or Input.is_action_pressed("scroll_up", false):
		compositor.forward_pointer_axis_popup(pid, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down", false) or Input.is_action_pressed("scroll_down", false):
		compositor.forward_pointer_axis_popup(pid, 0, 100.0)

	if Input.is_action_just_pressed("left_click", false):
		compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button_popup(pid, 0x110, false)

	# Le clic droit doit aussi être relayé quand le curseur est au-dessus
	# d'un popup : sans relâchement, button_count reste bloqué à 1 dans
	# wlroots et le compositeur ne peut plus entrer le popup (hover/clic
	# impossibles). wlroots route les boutons vers la surface focusée, donc
	# le relâchement d'un clic parti sur la fenêtre y retombe correctement.
	if Input.is_action_just_pressed("right_click", false):
		compositor.forward_pointer_button_popup(pid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button_popup(pid, 0x111, false)

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
			toggle_hide(wid)
		"maximize":
			var is_fs: bool = fullscreen_windows.get(wid, false)
			toggle_window_fullscreen(wid, not is_fs)
		"close":
			compositor.close_window(wid)

func toggle_window_fullscreen(id: int, fullscreen: bool) -> void:
	fullscreen_windows[id] = fullscreen

	if not quads.has(id) or not is_instance_valid(quads[id]):
		return

	var quad: MeshInstance3D = quads[id]
	var mesh: QuadMesh = quad.mesh
	var body: StaticBody3D = quad.get_child(0)
	# Le groupe collé suit le changement de taille (voisines poussées/rapprochées).
	_begin_group_resize(id)

	if fullscreen:
		# 1. Store state prior to toggling fullscreen
		pre_fullscreen_mesh_sizes[id] = mesh.size
		pre_fullscreen_surface_sizes[id] = body.get_meta("surface_size", Vector2(1024, 768))

		# 2. Request viewport dimensions from the Wayland surface
		var vp_size := get_viewport().get_visible_rect().size
		var aspect = vp_size.x / max(vp_size.y, 1.0)
		
		# Standardized 3D height facing camera (1.0 meter high)
		mesh.size = Vector2(1.0 * aspect, 1.0) * WINDOW_QUAD_SCALE
		
		# Update collision shape to match mesh size
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		_sync_decorations(quad)

		# Notify Wayland client buffer of target size
		compositor.set_window_size(id, int(vp_size.x), int(vp_size.y))

	else:
		# 1. Restore Quad Mesh Size
		if pre_fullscreen_mesh_sizes.has(id):
			mesh.size = pre_fullscreen_mesh_sizes[id]
			pre_fullscreen_mesh_sizes.erase(id)

		# Restore collision shape
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		_sync_decorations(quad)

		# 2. Restore original Wayland client surface size
		if pre_fullscreen_surface_sizes.has(id):
			var orig_surf: Vector2 = pre_fullscreen_surface_sizes[id]
			compositor.set_window_size(id, int(orig_surf.x), int(orig_surf.y))
			pre_fullscreen_surface_sizes.erase(id)
	_update_group_resize(id)
	_end_group_resize()
	windows_state_changed.emit()

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
		focused_window_id = wid
		_start_resize(wid, quad, ray_origin, ray_dir, str(body.get_meta("decoration_edge", "")))
	if Input.is_action_just_released("left_click", false):
		_release_resize_gesture(wid)

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
	WindowDecoration.set_button_state(body, str(info["action"]), state,
		fullscreen_windows.get(wid, false))

func _handle_titlebar(body: StaticBody3D, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var titlebar: MeshInstance3D = body.get_parent()
	var quad: MeshInstance3D = titlebar.get_parent()
	var wid: int = body.get_meta("titlebar_of")
	if Input.is_action_just_pressed("left_click", false):
		focused_window_id = wid
		_start_resize(wid, quad, ray_origin, ray_dir, "top")
	if Input.is_action_just_released("left_click", false):
		# Press + release sur la MÊME frame (clic rapide) : le relâchement
		# inter-frame passe par la branche is_resizing de process_raycast, pas
		# ici — réattacher ici garantit l'équilibre détachement/reliure.
		_release_resize_gesture(wid)

func _release_resize_gesture(wid: int) -> void:
	_set_window_occluder_active(wid, true)
	is_resizing = false
	_end_group_resize()
	resizing_edge = ""
	active_window_id = -1

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

# Lance un redimensionnement sur le côté `edge` de la fenêtre `wid`, d'après la
# position de la fenêtre et le point visé par le rayon caméra au moment du clic.
#
# Les deux entrées passent par ici : le drag d'un bord de la fenêtre et le drag
# de sa barre de titre (côté "top"). L'état de départ est identique dans les
# deux cas, donc il n'est figé qu'une fois — sans quoi les deux sites
# divergeaient dès qu'un champ de plus était ajouté.
#
# `edge` ne contient jamais "left"/"right" pour un drag de barre de titre : le
# pivot en profondeur n'a de sens que sur un bord PARTAGÉ, où le bord commun
# bouge pour les deux fenêtres. Le mode est donc déduit du voisinage, pas du
# côté tiré seul (voir hinge_mode_for).
func _start_resize(wid: int, quad: MeshInstance3D, ray_origin: Vector3,
		ray_dir: Vector3, edge: String) -> void:
	if not quads.has(wid) or not is_instance_valid(quad):
		return
	var body: StaticBody3D = quad.get_child(0)
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var content_offset: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var content_size: Vector2 = body.get_meta("content_size", win_size)
	if content_size.x <= 0 or content_size.y <= 0:
		content_offset = Vector2.ZERO

	active_window_id = wid
	resizing_edge = edge
	is_resizing = true
	# Même détachement d'occluder que toggle_grab_window : le quad réécrit sa
	# transform à chaque frame du drag, ce qui reconstruction Embree à chaque
	# frame. Le réattache se fait au relâchement.
	_set_window_occluder_active(wid, false)
	resize_depth = _camera().global_position.distance_to(quad.global_position)
	resize_start_world = ray_origin + ray_dir * resize_depth
	resize_right_dir = quad.global_transform.basis.x.normalized()
	resize_up_dir = quad.global_transform.basis.y.normalized()
	window_start_size = win_size
	window_start_content_offset = content_offset
	window_start_mesh_size = (quad.mesh as QuadMesh).size
	window_start_local_pos = quad.position
	resize_start_basis = quad.global_basis
	resize_start_pos = quad.global_position
	_begin_group_resize(wid, edge)
	# Charnière : uniquement si le bord TIRÉ est partagé avec une voisine. Un
	# coin dont le côté latéral est partagé reste en lacet ; un coin partagé par
	# le haut ou le bas seulement passe en tangage ; sans voisin, le resize est
	# plan, barre de titre comprise (le regard vertical y est la hauteur).
	# Charnière désactivée (RESIZE_HINGE_ENABLED) : un bord partagé ne se déplace
	# que sur l'axe des fenêtres liées, jamais en profondeur ni en pivotant.
	resize_hinge_mode = hinge_mode_for(edge, _shared_sides()) if RESIZE_HINGE_ENABLED else ""

# La fenêtre suit le viseur le long du rayon caméra, à profondeur figée
# (distance capturée au moment du grab) - fonctionne même si la souris ne
# se déplace jamais à l'écran (mode capturé), puisque seule l'orientation
# de la caméra entre ici en jeu.
func _update_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var cam: Camera3D = _camera()
	_sync_snap_monitoring(active_window_id)
	# Plus de translation latérale à la souris pendant le grab 3D.
	# Son décalage était cumulé SANS borne et réinjecté dans target_pos AVANT
	# la recherche de snap : le point visé s'éloignait donc progressivement des
	# zones, le collage sautait, la fenêtre repartait face caméra, et le
	# décalage continuait de croître tant que le bouton restait enfoncé. C'était
	# l'un des deux moteurs de l'oscillation observée en jeu. Le snap ajuste
	# déjà la position : la translation était redondante ET destructrice.
	var target_pos = ray_origin + ray_dir * move_depth
	# Collage : la position visée est corrigée vers le bord d'une fenêtre
	# voisine AVANT le lerp, sinon la fenêtre ne s'accroche jamais
	# (le lerp la ramène vers le point brut à chaque frame).
	var snap := _find_snap(target_pos)
	var was_snapped := snapped_to.has(active_window_id)
	# L'orientation AVANT la position, et non l'inverse.
	#
	# Les zones sont des ENFANTS du quad : écrire la base de la voisine les
	# DÉPLACE. Caler d'abord, tourner ensuite, donnait un point de collage
	# immédiatement périmé — les zones sortaient de la voisine, le collage
	# sautait, la fenêtre repassait face caméra, et le cycle se refermait à la
	# frame suivante. On reste alors collé sans jamais tenir : la fenêtre
	# oscille tant qu'on la tient.
	# L'orientation n'est adoptée qu'UNE fois, à l'entrée dans le collage (dans
	# _set_snap). La réécrire à chaque frame annulait le scroll de rotation.
	_set_snap(active_window_id, snap)
	if not snap.is_empty():
		# Recalculé APRÈS le changement d'orientation : _find_snap a raisonné
		# sur les zones telles qu'elles étaient AVANT, donc sur une base qui
		# n'est plus celle du quad. Le recalcul se fait dans le repère final,
		# et le calage reste exact bord à bord.
		target_pos = _snap_flush_position(active_window_id, snap)
	# Déplacement fluide
	quad.global_position = quad.global_position.lerp(
		target_pos,
		10.0 * delta
	)

	# Orientation : deux régimes, et c'est le COLLAGE qui les sépare.
	#
	# LIBRE : la fenêtre suit la caméra. Elle reste face au joueur pendant
	# qu'il la déplace, et suit sa tête s'il regarde ailleurs — sans cela on la
	# manipule de biais et on ne lit plus ce qu'elle affiche. On écrit
	# l'ÉTAT STOCKÉ aussi, sinon la rotation au collage relirait plus tard une
	# base périmée et la fenêtre se replacerait d'un coup.
	#
	# COLLÉE : au contraire, elle fige l'orientation de sa voisine (écrite par
	# _adopt_neighbour_basis). La suivre ici anéantirait la rotation au
	# collage à la frame suivante, et le raccord VR ne serait plus plat.
	#
	# `was_snapped` — l'état de la frame PRÉCÉDENTE — et non celui calculé
	# plus haut. Dès qu'une fenêtre est ENGAGÉE dans un collage, son
	# orientation lui appartient : la laisser repartir face caméra pendant
	# une frame suffirait à faire perdre le recouvrement que le collage vient
	# d'établir, et la fenêtre clignoterait entre les deux orientations pour
	# toute la durée du grab. Le recouvrement est mesuré sur la pose
	# précédente, donc l'orientation ne doit l'être qu'une fois le collage
	# réel : c'est le tout premier frame, où elle n'était pas encore engagée.
	if snap.is_empty() and not was_snapped:
		_store_basis(active_window_id, cam.global_transform.basis)

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
	var wid := active_window_id
	if wid == -1:
		return {}
	# Déjà collée : le collage se TIENT, il ne se redécide pas. Le refaire à
	# chaque frame depuis les recouvrements physiques bouclait : coller ->
	# adopter la rotation de la voisine -> les zones bougent, le recouvrement
	# disparaît -> décoller -> repasser face caméra -> recoller...
	var held: Dictionary = snapped_to.get(wid, {})
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
		and quads.has(their_wid) and quads[their_wid].visible
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
	var quad: MeshInstance3D = quads.get(wid, null)
	if quad == null or not is_instance_valid(quad):
		return Vector2.ZERO
	var mesh := quad.mesh as QuadMesh
	return visual_half_extent(mesh.size, _deco_of(quad)) if mesh != null else Vector2.ZERO

# Métriques de la fenêtre exprimées en unités MONDE : c'est le seul endroit où
# le ratio px/unité est calculé pour le décor.
func _deco_of(quad: MeshInstance3D) -> Dictionary:
	var mesh := quad.mesh as QuadMesh
	if mesh == null:
		return Decorations.world(Decorations.metrics(), Decorations.FALLBACK_PX_SCALE)
	var body := quad.get_child(0) as StaticBody3D
	var surface: Vector2 = body.get_meta("surface_size", Vector2.ZERO) if body != null else Vector2.ZERO
	return Decorations.world(Decorations.metrics(), Decorations.px_scale(surface, mesh.size))

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
	var moving_quad: MeshInstance3D = quads.get(moving_wid, null)
	if moving_quad == null or not is_instance_valid(moving_quad):
		return pairs
	var our_zones := _zones_of(moving_quad)
	for other_wid in quads:
		if other_wid == moving_wid:
			continue
		var other_quad: MeshInstance3D = quads[other_wid]
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
	var quad: MeshInstance3D = quads.get(wid, null)
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
	if wid > -1 and quads.has(wid) and is_instance_valid(quads[wid]):
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
	var cur: Dictionary = snapped_to.get(active_window_id, {})
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
	for c in quads:
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
	var snap: Dictionary = snapped_to.get(wid, {})
	if snap.is_empty():
		return -1
	return int(snap.get("wid", -1))

# Enregistre (ou efface) l'état de collage d'une fenêtre et n'émet le changement
# d'état réseau QUE sur transition : un emit par frame enverrait 60 fois/sec un
# état identique.
func _set_snap(wid: int, snap: Dictionary) -> void:
	var before: Dictionary = snapped_to.get(wid, {})
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
		snapped_to.erase(wid)
	else:
		# Entrée OU changement de voisine : dans les deux cas c'est une nouvelle
		# liaison, donc la fenêtre reprend l'orientation décidée par le collage.
		snapped_to[wid] = snap
		_adopt_neighbour_basis(wid, snap)
	windows_state_changed.emit()

# La fenêtre saisie prend l'orientation de sa voisine — le modèle VR : deux
# fenêtres collées ont la même orientation, sinon le raccord n'est pas plat.
func _adopt_neighbour_basis(wid: int, snap: Dictionary) -> void:
	var source := int(snap.get("adopt_basis_of", -1))
	if source == -1:
		source = int(snap.get("wid", -1))
	if source == -1 or source == wid or not quads.has(source):
		return
	_store_basis(wid, _stored_basis(source))

# Le scroll ne pivote QUE si la fenêtre est collée : sinon il garde son sens
# de push/pull (move_depth), qui n'a pas le droit de disparaître.
func _scroll_rotates() -> bool:
	return active_window_id != -1 and snapped_to.has(active_window_id) and not _group_grab

# ── Redimensionnement synchronisé du groupe collé ────────────────────────
#
# Redimensionner une fenêtre déplace son bord, donc les fenêtres collées de ce
# côté doivent suivre (et celles qui leur sont collées derrière elles) : le
# groupe se translate comme un bloc. On ne translate que le long de la normale
# du bord — le décalage latéral entre voisines est conservé.
#
# Une entrée par fenêtre directement collée à la redimensionnée :
# {side (côté de la redimensionnée), zone_start, members: [{wid, pos}]}.
var _resize_links: Array = []
# Voisines qui PARTAGENT le bord tiré : {side (côté de la tirée), wid, mesh, px,
# offset, pos}.
var _resize_shared: Array = []

# Voisines directes d'une fenêtre dans le graphe de collage (les deux sens).
func _snap_neighbours(wid: int) -> Array:
	var out: Array = []
	var own: Dictionary = snapped_to.get(wid, {})
	if not own.is_empty():
		out.append({"wid": int(own.get("wid", -1)), "side": str(own.get("our_side", ""))})
	for other in snapped_to:
		var sn: Dictionary = snapped_to[other]
		if other != wid and int(sn.get("wid", -1)) == wid:
			out.append({"wid": int(other), "side": str(sn.get("side", ""))})
	return out

# Toutes les fenêtres atteignables depuis `start` sans repasser par `visited`.
func _collect_group(start: int, visited: Dictionary) -> Array:
	var members: Array = []
	var queue: Array = [start]
	visited[start] = true
	while not queue.is_empty():
		var w: int = queue.pop_front()
		members.append(w)
		for n in _snap_neighbours(w):
			var nw := int(n["wid"])
			if nw != -1 and quads.has(nw) and not visited.has(nw):
				visited[nw] = true
				queue.append(nw)
	return members

# `edge` non vide (drag d'un bord) : la voisine collée sur ce bord le PARTAGE.
# Le bord commun bouge pour les deux fenêtres, mais leurs bords EXTÉRIEURS (le
# bord opposé de la tirée, le bord lointain de la voisine) restent en place :
# chacune pivote autour du sien pour garder le contact avec le bord commun. Les
# voisines des autres côtés, et tout le groupe lors d'un maximize (`edge`
# vide), sont simplement translatées avec leur zone de collage.
func _begin_group_resize(wid: int, edge: String = "") -> void:
	_resize_links.clear()
	_resize_shared.clear()
	var quad: MeshInstance3D = quads.get(wid, null)
	if quad == null:
		return
	var visited := {wid: true}
	for link in _snap_neighbours(wid):
		var nw := int(link["wid"])
		if nw == -1 or not quads.has(nw) or visited.has(nw):
			continue
		var side: String = link["side"]
		var area := quad.get_node_or_null(_zone_path(side)) as Area3D
		if area == null:
			continue
		if edge != "" and edge.contains(side):
			var nq: MeshInstance3D = quads[nw]
			var nbody: StaticBody3D = nq.get_child(0)
			visited[nw] = true
			_set_window_occluder_active(nw, false)
			# Zones de la voisine : `near` touche notre bord, `far` est son bord
			# opposé (reste en place pendant tout le drag). `near_delta` = écart initial entre
			# sa zone proche et la nôtre (nul tant que rien n'a décalé les deux
			# fenêtres), conservé pendant tout le drag pour ne pas recentrer la
			# voisine.
			var near_zone := nq.get_node_or_null(_zone_path(_opposite_side(side))) as Area3D
			var far_zone := nq.get_node_or_null(_zone_path(side)) as Area3D
			if near_zone == null or far_zone == null:
				continue
			_resize_shared.append({
				"side": side, "wid": nw,
				"near_delta": near_zone.global_transform.origin - area.global_transform.origin,
				"far": far_zone.global_transform.origin,
				"basis": nq.global_basis,
				"mesh": (nq.mesh as QuadMesh).size,
				"px": nbody.get_meta("surface_size", Vector2(1, 1)),
				"offset": nbody.get_meta("content_offset", Vector2.ZERO),
				"pos": nq.global_position,
			})
			continue
		var members: Array = []
		for m in _collect_group(nw, visited):
			var q: MeshInstance3D = quads[m]
			if is_instance_valid(q):
				members.append({"wid": m, "pos": q.global_position})
		_resize_links.append({
			"kind": "translate",
			"side": side,
			"zone_start": area.global_transform.origin,
			"members": members,
		})

func _end_group_resize() -> void:
	resize_hinge_mode = ""
	for r in _resize_shared:
		_set_window_occluder_active(int(r["wid"]), true)
	_resize_shared.clear()
	_resize_links.clear()
	windows_state_changed.emit()

# Côtés de la fenêtre redimensionnée qui portent une voisine collée ET
# partagent le bord tiré (donc une entrée par _resize_shared).
func _shared_sides() -> Array:
	var out: Array = []
	for r in _resize_shared:
		out.append(str(r["side"]))
	return out

# Croissance MAX (monde) de la fenêtre tirée sur l'axe horizontal ou vertical :
# la voisine ne doit pas passer sous MIN_SURFACE_SIZE.
func _shared_growth_limit(horizontal: bool) -> float:
	var limit := INF
	for r in _resize_shared:
		var side: String = r["side"]
		if (side == "left" or side == "right") != horizontal:
			continue
		var mesh: Vector2 = r["mesh"]
		var px: Vector2 = r["px"]
		var m := mesh.x if horizontal else mesh.y
		var p := px.x if horizontal else px.y
		limit = min(limit, max(m * (1.0 - MIN_SURFACE_SIZE / max(p, 1.0)), 0.0))
	return limit

func _opposite_side(side: String) -> String:
	match side:
		"left": return "right"
		"right": return "left"
		"top": return "bottom"
		"bottom": return "top"
	return ""

# Redimensionne ET fait pivoter la voisine qui PARTAGE le bord tiré (la fenêtre
# tirée est déjà à jour : voir _update_resize).
#
# Le bord commun suit le viseur, y compris en profondeur. Le bord LOINTAIN de la
# voisine ne bouge pas : c'est son pivot, comme le bord opposé de la tirée.
#
#  - bord PROCHE = zone de la tirée (déplacée) + écart initial ;
#  - bord LOINTAIN = fixe ;
#  - orientation : rotation autour de l'axe du bord (vertical pour un collage
#    latéral) qui aligne l'axe de largeur sur « proche -> lointain ». Avec des
#    rotations égales (fenêtres coplanaires) l'angle est nul : on retrouve le
#    simple redimensionnement ;
#  - taille sur l'axe du collage = distance entre les deux bords (mesh,
#    collision et surface côté client, à densité de pixels constante), jamais
#    sous MIN_SURFACE_SIZE ;
#  - centre déduit de la position de sa zone proche, comme au collage.
func _update_shared_edge(_d_x: float, _d_y: float) -> void:
	var xq: MeshInstance3D = quads.get(active_window_id, null)
	if xq == null:
		return
	for r in _resize_shared:
		var nw := int(r["wid"])
		var nq: MeshInstance3D = quads.get(nw, null)
		if nq == null or not is_instance_valid(nq):
			continue
		var side: String = r["side"]
		var xz := xq.get_node_or_null(_zone_path(side)) as Area3D
		if xz == null:
			continue
		var near_side := _opposite_side(side)
		var horizontal := side == "left" or side == "right"
		var b0: Basis = r["basis"]
		var near_pt: Vector3 = xz.global_transform.origin + Vector3(r["near_delta"])
		var far_pt: Vector3 = r["far"]
		# Sens proche -> lointain dans le repère DE DÉPART de la voisine, et
		# axe du bord autour duquel elle pivote (hauteur pour un collage latéral,
		# largeur pour un collage vertical).
		var dir_old: Vector3
		match side:
			"right": dir_old = b0.x
			"left": dir_old = -b0.x
			"top": dir_old = b0.y
			_: dir_old = -b0.y
		dir_old = dir_old.normalized()
		var axis := (b0.y if horizontal else b0.x).normalized()
		var want := far_pt - near_pt
		want -= axis * want.dot(axis)
		var span := want.length()
		var nb := b0
		if span > 0.001:
			var angle := dir_old.signed_angle_to(want / span, axis)
			nb = Basis(axis, angle) * b0
		else:
			span = 0.001
		var mesh0: Vector2 = r["mesh"]
		var px0: Vector2 = r["px"]
		var off: Vector2 = r["offset"]
		var mesh1 := mesh0
		var px1 := px0
		if horizontal:
			# Jamais sous la taille minimale : le mesh et les pixels restent
			# cohérents quand le bord commun se rapproche trop du bord lointain.
			mesh1.x = max(span, mesh0.x * MIN_SURFACE_SIZE / max(px0.x, 1.0))
			px1.x = max(px0.x * mesh1.x / max(mesh0.x, 0.001), MIN_SURFACE_SIZE)
		else:
			# La zone haute/basse est portée par l'empreinte VISIBLE (mesh +
			# cadre + bandeau de titre). `deco` est calculé sur le mesh COURANT
			# de la voisine : c'est l'épaisseur telle qu'elle était avant le
			# drag, donc bien l'empreinte visible à retrancher du `span`.
			var deco := _deco_of(nq)
			mesh1.y = max(span - deco["titlebar"] - deco["border"], mesh0.y * MIN_SURFACE_SIZE / max(px0.y, 1.0))
			px1.y = max(px0.y * mesh1.y / max(mesh0.y, 0.001), MIN_SURFACE_SIZE)
		(nq.mesh as QuadMesh).size = mesh1
		var nbody: StaticBody3D = nq.get_child(0)
		nbody.set_meta("user_sized", true)
		var shape: BoxShape3D = (nbody.get_child(0) as CollisionShape3D).shape
		shape.size = Vector3(mesh1.x, mesh1.y, shape.size.z)
		# Orientation écrite dans l'ÉTAT STOCKÉ aussi : c'est lui que relisent
		# la rotation au scroll et la règle des 3 fenêtres.
		_store_basis(nw, nb)
		_sync_decorations(nq)
		compositor.set_window_size(nw, int(px1.x) + int(off.x) * 2, int(px1.y) + int(off.y) * 2)
		fullscreen_windows[nw] = false
		var near_local := snap_zone_local_offset(visual_half_extent(mesh1, _deco_of(nq)), near_side)
		nq.global_position = near_pt - nb * near_local

func _update_group_resize(wid: int) -> void:
	var quad: MeshInstance3D = quads.get(wid, null)
	if quad == null or _resize_links.is_empty():
		return
	for link in _resize_links:
		if link["kind"] != "translate":
			continue
		var area := quad.get_node_or_null(_zone_path(link["side"])) as Area3D
		if area == null:
			continue
		var zb := area.global_transform.basis
		var side: String = link["side"]
		var normal := (zb.y if side == "top" or side == "bottom" else zb.x).normalized()
		var moved := area.global_transform.origin - Vector3(link["zone_start"])
		var shift := normal * moved.dot(normal)
		for m in link["members"]:
			var q: MeshInstance3D = quads.get(m["wid"], null)
			if q != null and is_instance_valid(q):
				q.global_position = Vector3(m["pos"]) + shift

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
func _rotate_from_scroll(delta: float) -> void:
	# elif, et non if : la gâchette choisit ENTRE le taux et le cran, elle ne
	# doit pas cumuler les deux.
	if _scroll_from_gamepad("scroll_up"):
		_rotate_snapped(SNAP_ROTATE_RATE * delta)
	elif Input.is_action_just_pressed("scroll_up", false) \
			or Input.is_action_pressed("scroll_up", false):
		_rotate_snapped(SNAP_ROTATE_RATE * 3 * delta)
	if _scroll_from_gamepad("scroll_down"):
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
func _scroll_from_gamepad(action: String) -> bool:
	for ev in InputMap.action_get_events(action):
		if not (ev is InputEventJoypadButton):
			continue
		for device: int in _pad_devices(ev):
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
	var snap: Dictionary = snapped_to.get(active_window_id, {})
	var area := _snap_pivot_area(active_window_id)
	if area == null:
		return
	var quad: MeshInstance3D = quads[active_window_id]
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
		var base_after := _stored_basis(active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			- base_after.y.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(active_window_id, base_after)
	if snap["side"] == "left":
		var axis := -area.global_transform.basis.y.normalized()
		var visual := visual_center(quad.global_position,
			-quad.global_basis.y.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			+ base_after.y.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(active_window_id, base_after)
	if snap["side"] == "bottom":
		var axis := area.global_transform.basis.x.normalized()
		var visual := visual_center(quad.global_position,
			quad.global_basis.x.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			- base_after.x.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(active_window_id, base_after)
	if snap["side"] == "top":
		var axis := -area.global_transform.basis.x.normalized()
		var visual := visual_center(quad.global_position,
			-quad.global_basis.x.normalized(), deco)
		var orbit := visual - pivot
		# La base APRÈS rotation, pour que le décalage du bandeau suive la fenêtre
		# qui pivote (sinon elle glisserait de 3 cm en montant).
		var base_after := _stored_basis(active_window_id).rotated(axis, delta)
		quad.global_position = pivot + orbit.rotated(axis, delta) \
			+ base_after.x.normalized() * ((deco["titlebar"] - deco["border"]) * 0.5)
		_store_basis(active_window_id, base_after)
	
# Area3D servant de pivot : celle du côté par lequel la fenêtre est collée.
func _snap_pivot_area(wid: int) -> Area3D:
	var snap: Dictionary = snapped_to.get(wid, {})
	if snap.is_empty():
		return null
	var side := String(snap.get("our_side", ""))
	var quad: MeshInstance3D = quads.get(wid, null)
	if quad == null or not is_instance_valid(quad) or side == "":
		return null
	return quad.get_node_or_null(_zone_path(side)) as Area3D

# ── Stockage de l'orientation (modèle VR : orientation FIXE) ────────────
#
func _stored_basis(wid: int) -> Basis:
	if not quads.has(wid):
		return Basis.IDENTITY
	return _window_basis.get(wid, quads[wid].global_basis)

func _store_basis(wid: int, basis: Basis) -> void:
	if not quads.has(wid) or not is_instance_valid(quads[wid]):
		return
	_window_basis[wid] = basis
	quads[wid].global_basis = basis

# Recopie l'orientation complète d'une fenêtre sur une autre — utilisé à la
# sortie du mode focus, où les fenêtres empilées repartent toutes avec la base
# de la première.
# Il faut recopier l'ÉTAT STOCKÉ et pas seulement global_basis : c'est
# _window_basis que la rotation au collage relit. Ne recopier que la base
# visible laisserait l'état à zéro angle, et la fenêtre se replacerait
# d'un coup à l'angle précédent au prochain cran de rotation.
func copy_window_basis(from_id: int, to_id: int) -> void:
	if not quads.has(from_id) or not quads.has(to_id):
		return
	_store_basis(to_id, _stored_basis(from_id))

# Oubli de toutes les données par fenêtre. Isolé de on_window_unmapped pour être
# testable : celui-ci await la freeing de l'occulteur, donc ne peut pas être
# appelé depuis un test runner synchrone.
func _erase_window_state(id: int) -> void:
	window_textures.erase(id)
	window_shared.erase(id)
	window_server_side.erase(id)
	_texture_versions.erase(id)
	_window_basis.erase(id)
	snapped_to.erase(id)
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

# ── Redimensionnement (fonctions PURES) ─────────────────────────────────
#
# Un bord tiré grandit VERS L'EXTÉRIEUR : tirer le bord droit vers la droite
# agrandit, tirer le bord haut vers le haut agrandit aussi (et non l'inverse,
# qui est le piège de lecture quand on passe des px aux unités monde, y vers le
# haut). La largeur ne bouge que si le côté tiré est latéral, la hauteur que si
# le côté tiré est horizontal — d'où un bord haut qui ne touche QUE la hauteur,
# bord bas et largeur inchangés.

# Taille de surface après le déplacement `d` (unités monde, dans la base du
# quad) du côté `edge`, au ratio `px_per_unit` figé au grab.
static func resized_surface_size(start: Vector2, edge: String, d: Vector2,
		px_per_unit: Vector2) -> Vector2:
	var out := start
	if "right" in edge:
		out.x = start.x + d.x * px_per_unit.x
	elif "left" in edge:
		out.x = start.x - d.x * px_per_unit.x
	if "bottom" in edge:
		out.y = start.y - d.y * px_per_unit.y
	elif "top" in edge:
		out.y = start.y + d.y * px_per_unit.y
	return out

## Profondeur d'un bord partagé tiré, pilotée par le REGARD le long de l'axe du
## pivot : vertical en lacet, horizontal en tangage.
##
## En regardant plus HAUT (lacet) ou plus À DROITE (tangage) que là où le drag a
## commencé, le bord s'éloigne ; l'inverse le rapproche. L'écart du point visé,
## exprimé en mètres dans la base de la fenêtre au grab, est converti en mètres
## de profondeur avec ce gain. Mettre une valeur négative inverse le sens.
## Rien n'est lu pendant un drag de coin : le regard le long de l'axe du pivot
## y règle déjà l'autre dimension.
const RESIZE_DEPTH_GAIN := 1.0

## Autorise le pivot (lacet/tangage) d'un bord partagé tiré. Désactivé : le bord
## partagé reste dans le plan et ne glisse que le long de l'axe de collage
## (horizontal pour un collage latéral, vertical pour un collage haut/bas).
const RESIZE_HINGE_ENABLED := false

## Charnière d'un drag : "" (plan), "yaw" (bord latéral tiré) ou "pitch" (bord
## haut/bas tiré).
##
## Elle n'existe que si le bord TIRÉ est PARTAGÉ avec une voisine collée : le
## bord commun bouge pour les deux fenêtres, donc le pivot en profondeur est
## visible des deux côtés. Sans voisin, les quatre côtés restent plans — y
## compris les latéraux, dont le lacet n'aurait rien à partager.
##
## `shared_sides` : les côtés de CETTE fenêtre qui portent une voisine collée.
## Un coin dont les deux côtés sont partagés reste en lacet : c'est le seul mode
## où les deux fenêtres peuvent se suivre mutuellement.
static func hinge_mode_for(edge: String, shared_sides: Array) -> String:
	var lateral := false
	var vertical := false
	for s in shared_sides:
		var side := str(s)
		if side == "left" or side == "right":
			lateral = true
		elif side == "top" or side == "bottom":
			vertical = true
	if lateral and ("left" in edge or "right" in edge):
		return "yaw"
	if vertical and ("top" in edge or "bottom" in edge):
		return "pitch"
	return ""

## Charnière : géométrie pure d'un drag en lacet ou en tangage.
##
## Le bord OPPOSÉ au bord tiré est le pivot et reste fixe ; le bord tiré suit le
## point visé dans le plan de la fenêtre, qui pivote pour pointer vers lui. Le
## composant du déplacement le long de l'axe du pivot (le vertical en lacet,
## l'horizontale en tangage) est retiré du plan — le pivot ne peut pas le suivre
## — et converti en profondeur (RESIZE_DEPTH_GAIN), sauf si le côté
## perpendiculaire est lui aussi tiré, auquel cas ce regard règle déjà cette
## dimension.
##
## Renvoie :
##  - basis : orientation de la fenêtre après rotation autour de l'axe du pivot ;
##  - delta : croissance (unités monde) à passer à resized_surface_size, seule
##    l'axe de la charnière est renseignée — le côté perpendiculaire reste à la
##    charge du delta projeté par l'appelant ;
##  - pivot : direction du bord opposé vers le bord tiré, au moment du grab
##    (signe compris) : c'est la position du pivot qui en découle ;
##  - out : la même direction dans la base tournée, du pivot vers le nouveau
##    centre.
static func resize_hinge(mode: String, edge: String, basis: Basis,
		mesh_size: Vector2, world_delta: Vector3) -> Dictionary:
	var x0 := basis.x.normalized()
	var y0 := basis.y.normalized()
	if mode == "":
		return {"basis": basis, "delta": Vector2.ZERO, "pivot": Vector3.ZERO, "out": Vector3.ZERO}
	var yaw := mode == "yaw"
	var axis := (y0 if yaw else x0).normalized()
	var sgn := 1.0 if (("right" in edge) if yaw else ("top" in edge)) else -1.0
	var extent: float = mesh_size.x if yaw else mesh_size.y
	var pivot := (x0 if yaw else y0) * sgn
	# Le côté perpendiculaire est-il aussi tiré ? (coin)
	var corner := (("top" in edge) or ("bottom" in edge)) if yaw \
		else (("left" in edge) or ("right" in edge))
	var along := world_delta.dot(axis)
	var depth := Vector3.ZERO
	if not corner:
		depth = -basis.z.normalized() * (along * RESIZE_DEPTH_GAIN)
	var target := pivot * extent + (world_delta - axis * along) + depth
	var nb := basis
	if target.length() > 0.001:
		nb = Basis(axis, pivot.signed_angle_to(target.normalized(), axis)) * basis
	var delta := Vector2.ZERO
	var growth := target.length() - extent
	if yaw:
		delta.x = sgn * growth
	else:
		delta.y = sgn * growth
	return {
		"basis": nb,
		"delta": delta,
		"pivot": pivot,
		"out": (nb.x.normalized() * sgn) if yaw else (nb.y.normalized() * sgn),
	}

func _update_resize(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var mesh: QuadMesh = quad.mesh

	# Delta du viseur (unités monde) projeté sur la même profondeur figée
	# qu'au moment du grab, puis exprimé dans la base locale du quad.
	var cur_world := ray_origin + ray_dir * resize_depth
	var world_delta := cur_world - resize_start_world
	var local_dx := world_delta.dot(resize_right_dir)
	var local_dy := world_delta.dot(resize_up_dir)

	# Charnière (bord tiré PARTAGÉ) : le bord commun suit le point visé, en
	# lacet comme en tangage, et le bord opposé reste fixe. La rotation, la
	# croissance et la profondeur sont calculées par resize_hinge ; le côté
	# perpendiculaire d'un coin reste sur le delta projeté ci-dessus.
	var hinge := {}
	if resize_hinge_mode != "":
		hinge = resize_hinge(resize_hinge_mode, resizing_edge, resize_start_basis,
			window_start_mesh_size, world_delta)
		local_dx = (hinge["delta"] as Vector2).x
		local_dy = (hinge["delta"] as Vector2).y

	# Ratio pixels de surface / unité monde, figé au grab (le mesh ne
	# change pas de taille pendant le drag, seul window_texture_updated
	# le fera une fois le client redessiné à la nouvelle taille).
	var px_per_unit_x: float = window_start_size.x / max(window_start_mesh_size.x, 0.001)
	var px_per_unit_y: float = window_start_size.y / max(window_start_mesh_size.y, 0.001)

	var new_size := resized_surface_size(window_start_size, resizing_edge,
		Vector2(local_dx, local_dy),
		Vector2(px_per_unit_x, px_per_unit_y))
	var new_w := new_size.x
	var new_h := new_size.y

	# La voisine qui partage le bord tiré rétrécit d'autant : la croissance est
	# bornée pour qu'elle ne passe pas sous la taille minimale. Un bord HAUT
	# partagé tire la voisine par son bord bas, donc la borne vaut aussi pour
	# "top".
	if "left" in resizing_edge or "right" in resizing_edge:
		new_w = min(new_w, window_start_size.x + _shared_growth_limit(true) * px_per_unit_x)
	if "bottom" in resizing_edge or "top" in resizing_edge:
		new_h = min(new_h, window_start_size.y + _shared_growth_limit(false) * px_per_unit_y)
	new_w = max(new_w, MIN_SURFACE_SIZE)
	new_h = max(new_h, MIN_SURFACE_SIZE)

	# set_window_size envoie les dimensions de la SURFACE (buffer) au client
	# Wayland, pas la geometry. Les ombres CSD sont typiquement symétriques,
	# donc surface = geometry + 2 * content_offset.
	var surface_w := int(new_w) + int(window_start_content_offset.x) * 2
	var surface_h := int(new_h) + int(window_start_content_offset.y) * 2
	compositor.set_window_size(active_window_id, surface_w, surface_h)
	fullscreen_windows[active_window_id] = false
	# Met à jour la taille du mesh ET la position en même temps pour que
	# le bord fixe reste immobile pendant le drag. Sans cette mise à jour,
	# seul le position changeait → le bord "fixe" dérivait car le mesh
	# gardait l'ancienne taille (causant le tearing visible pendant le
	# resize).
	var new_mesh_w: float = window_start_mesh_size.x * (new_w / max(window_start_size.x, 1.0))
	var new_mesh_h: float = window_start_mesh_size.y * (new_h / max(window_start_size.y, 1.0))
	mesh.size = Vector2(new_mesh_w, new_mesh_h)

	# La CollisionShape3D doit suivre la même taille que le mesh.
	var body: StaticBody3D = quad.get_child(0)
	# Une fenêtre redimensionnée à la main garde sa taille monde : on_texture_updated
	# ne doit plus la recalculer d'après les pixels (voir user_sized là-bas).
	body.set_meta("user_sized", true)
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(new_mesh_w, new_mesh_h, shape.size.z)
	_sync_decorations(quad)

	# Repositionne le bord fixe: le shift compense exactement la moitié
	# du delta taille, de sorte que le bord opposé ne bouge pas.
	var delta_w_world: float = (new_mesh_w - window_start_mesh_size.x) / 2.0
	var delta_h_world: float = (new_mesh_h - window_start_mesh_size.y) / 2.0
	if resize_hinge_mode != "":
		# Bord FIXE = bord opposé au bord tiré, au départ du drag. La fenêtre
		# pivote autour de lui (axe = celui du bord) vers le point visé, puis son
		# centre se déduit de ce bord fixe, de sa nouvelle taille et de son nouvel
		# angle. Le côté perpendiculaire (coin) se cale sur le delta plan, comme
		# en mode plan, mais dans la base de DÉPART : le bord fixe ne doit pas
		# dériver.
		var pivot: Vector3 = hinge["pivot"]
		var out_dir: Vector3 = hinge["out"]
		var yaw := resize_hinge_mode == "yaw"
		var up0 := resize_start_basis.y.normalized()
		var x0 := resize_start_basis.x.normalized()
		var far_pt := resize_start_pos - pivot * ((window_start_mesh_size.x if yaw
				else window_start_mesh_size.y) * 0.5)
		var new_extent: float = new_mesh_w if yaw else new_mesh_h
		# Orientation écrite dans l'ÉTAT STOCKÉ aussi : c'est lui que relisent
		# la rotation au scroll et la règle des 3 fenêtres.
		_store_basis(active_window_id, hinge["basis"])
		var perp_shift := Vector3.ZERO
		if yaw:
			if "top" in resizing_edge:
				perp_shift += up0 * delta_h_world
			elif "bottom" in resizing_edge:
				perp_shift -= up0 * delta_h_world
		else:
			if "left" in resizing_edge:
				perp_shift -= x0 * delta_w_world
			elif "right" in resizing_edge:
				perp_shift += x0 * delta_w_world
		quad.global_position = far_pt + out_dir * (new_extent * 0.5) + perp_shift
	else:
		var shift := Vector3.ZERO
		if "left" in resizing_edge:
			shift -= resize_right_dir * delta_w_world
		elif "right" in resizing_edge:
			shift += resize_right_dir * delta_w_world
		if "top" in resizing_edge:
			shift += resize_up_dir * delta_h_world
		elif "bottom" in resizing_edge:
			shift -= resize_up_dir * delta_h_world
		quad.position = window_start_local_pos + shift
	_update_group_resize(active_window_id)
	_update_shared_edge(new_mesh_w - window_start_mesh_size.x,
		new_mesh_h - window_start_mesh_size.y)


# Un grab de groupe vaut-il quelque chose depuis cette fenêtre ? Elle a au
# moins une voisine collée ET encore là : le groupe inclut la fenêtre saisie
# elle-même (_start_group_grab), donc sans voisine ce serait un grab ordinaire.
#
# Une voisine disparue ne compte pas — et le cas est réel : un unmapped
# n'efface que SA propre entrée (voir _erase_window_state), la voisine garde la
# sienne et pointerait sur une fenêtre qui n'existe plus.
func can_group_grab(wid: int) -> bool:
	if not quads.has(wid):
		return false
	for link in _snap_neighbours(wid):
		if quads.has(int(link["wid"])):
			return true
	return false

# Bascule le grab de groupe sur `wid` : le menu radial est le seul point
# d'entrée à même de l'INTERROMPRE. L'action Maj+G, elle, ne fait que le
# démarrer, le moteur du grab le terminant au relâchement physique de la touche
# (cf. _update_move). Un grab amorcé depuis l'anneau n'a aucun appui derrière
# lui : sans cette seconde validation, la fenêtre resterait accrochée au viseur
# pour toujours — « pas de relâchement d'action » ne veut pas dire « pas de fin ».
func toggle_group_grab(wid: int) -> void:
	if is_group_grabbed(wid):
		release_window_grab(wid)
		return
	var quad: MeshInstance3D = quads.get(wid, null)
	if quad == null or not is_instance_valid(quad):
		return
	_start_group_grab(wid, quad)

# Le groupe est-il en train d'être saisi, sur CETTE fenêtre ? _group_grab vaut
# pour tout grab de groupe, y compris celui d'une autre fenêtre : c'est
# l'identifiant de la fenêtre saisie qui fait foi, sinon l'anneau proposerait
# « DROP GROUP » devant une fenêtre qui n'a rien à voir avec la saisie en cours.
func is_group_grabbed(wid: int) -> bool:
	return _group_grab and is_window_grabbed(wid)

func _start_group_grab(wid: int, quad: MeshInstance3D) -> void:
	active_window_id = wid
	is_moving = true
	move_depth = _camera().global_position.distance_to(quad.global_position)
	_group_rel.clear()
	var inv := quad.global_transform.affine_inverse()
	for m in _collect_group(wid, {}):
		var q: MeshInstance3D = quads.get(m, null)
		if q == null or not is_instance_valid(q):
			continue
		_set_window_occluder_active(m, false)
		if m != wid:
			_group_rel[m] = inv * q.global_transform
	# Groupe de 1 => grab normal (billboard + snap)
	_group_grab = not _group_rel.is_empty()
	_grab_action = "grab_group"
	windows_state_changed.emit()

func _update_group_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	var quad: MeshInstance3D = quads.get(active_window_id, null)
	if quad == null or not is_instance_valid(quad):
		return
	var target := ray_origin + ray_dir * move_depth
	quad.global_position = quad.global_position.lerp(target, 10.0 * delta)
	# La fenêtre visée fait face au joueur (état stocké inclus, comme _update_move)
	_store_basis(active_window_id, _camera().global_transform.basis)
	var t := quad.global_transform
	for m in _group_rel:
		var q: MeshInstance3D = quads.get(m, null)
		if q != null and is_instance_valid(q):
			var mt: Transform3D = t * (_group_rel[m] as Transform3D)
			q.global_transform = mt
			_window_basis[m] = mt.basis

func _end_group_grab() -> void:
	for m in _group_rel:
		_set_window_occluder_active(int(m), true)
	_group_rel.clear()
	_group_grab = false
	_grab_action = "grab"
