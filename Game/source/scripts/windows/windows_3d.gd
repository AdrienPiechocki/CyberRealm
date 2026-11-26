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
# Une fenêtre a été cachée (SUPER+H…) ou réaffichée : la barre de tâches la voit « minimized ».
signal window_hidden_changed(window_id: int, hidden: bool)
# Multiplicateur de taille des quads en unités monde : agrandit l'affichage
# 3D des fenêtres sans toucher à la résolution de l'image (les pixels par
# unité monde sont divisés d'autant, l'échantillonnage reste le même).
const WINDOW_QUAD_SCALE := 2.0

const Decorations := preload("res://scripts/ui/window_decorations.gd")
const WindowDecoration := preload("res://scripts/windows/window_decoration_3d.gd")
const WindowShaders := preload("res://scripts/windows/window_shaders.gd")

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

# Position de spawn des nouvelles fenêtres : toujours 1 m devant la caméra,
# mais décalée de STACK_Z_OFFSET derrière la précédente pour chaque fenêtre
# déjà présente à cet endroit, pour que deux fenêtres ouvertes coup sur coup
# ne s'empilent pas au même endroit. Même empilement qu'à la sortie du mode
# focus (voir focus_mode.gd).
const STACK_Z_OFFSET := 0.1 # m entre deux fenêtres empilées
## Distance (m) devant la caméra où apparaissent les nouvelles fenêtres ; aussi
## celle où arrive une fenêtre saisie depuis le window_menu.
const SPAWN_DISTANCE := 2.0
const SPAWN_STACK_RADIUS := 0.5 # m, portée de détection des fenêtres déjà empilées au point de spawn

const WAYLAND_SHADER_CODE = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_always;

global uniform vec3 window_bcs;
global uniform vec4 window_tm;
// Les fenêtres ne doivent subir ni le tonemap ni l'ajustement couleur de
// l'Environment (post-traitement du viewport). On renvoie la valeur linéaire
// que le pipeline (exposition -> tonemap -> luminosité (linéaire) -> sRGB ->
// contraste -> saturation (moyenne)) ramène exactement à la couleur d'origine.
// window_bcs = (luminosité, contraste, saturation) ; window_tm = (mode,
// white, exposition, -) avec mode 0 linéaire, 1 Reinhard, 2 filmic (3 ACES
// et 4 AgX : pas d'inverse, tonemap non compensé).
vec3 window_untonemap(vec3 y) {
	float w = window_tm.y;
	if (window_tm.x > 0.5 && window_tm.x < 1.5) {
		float w2 = w * w;
		y = min(y, vec3(0.999));
		return w2 * 0.5 * ((y - 1.0) + sqrt((1.0 - y) * (1.0 - y) + 4.0 * y / w2));
	} else if (window_tm.x > 1.5 && window_tm.x < 2.5) {
		const float FM_A = 0.88;
		const float FM_B = 0.6;
		const float FM_C = 0.1;
		const float FM_D = 0.2;
		const float FM_E = 0.01;
		const float FM_F = 0.3;
		float wt = ((w * (FM_A * w + FM_C * FM_B) + FM_D * FM_E) / (w * (FM_A * w + FM_B) + FM_D * FM_F)) - FM_E / FM_F;
		vec3 t = min(y, vec3(0.999)) * wt + FM_E / FM_F;
		vec3 a = (t - 1.0) * FM_A;
		vec3 b = FM_B * (t - FM_C);
		vec3 c = FM_D * (t * FM_F - FM_E);
		vec3 disc = max(b * b - 4.0 * a * c, 0.0);
		return (-b - sqrt(disc)) / (2.0 * min(a, vec3(-0.0001)));
	}
	return y;
}

vec3 window_encode(vec3 d) {
	float m = (d.r + d.g + d.b) / 3.0;
	d = m + (d - m) / max(window_bcs.z, 0.05);
	d = (d - 0.5) / max(window_bcs.y, 0.05) + 0.5;
	vec3 lin = pow(clamp(d, 0.0, 1.0), vec3(2.2)) / max(window_bcs.x, 0.05);
	return window_untonemap(lin) / max(window_tm.z, 0.01);
}

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0, 0.0);
// true : alpha normalisé (x2, clampé) — masque l'alpha < 1 parasite des
// buffers de jeux. false : alpha brut, pour les fenêtres réellement
// translucides (Konsole...), détectées par la sonde d'alpha.
uniform bool opaque_mode = true;

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
		ALBEDO = window_encode(unmultiplied);
		ALPHA = opaque_mode ? clamp(tex.a * 2.0, 0.0, 1.0) : tex.a;
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

global uniform vec3 window_bcs;
global uniform vec4 window_tm;
// Les fenêtres ne doivent subir ni le tonemap ni l'ajustement couleur de
// l'Environment (post-traitement du viewport). On renvoie la valeur linéaire
// que le pipeline (exposition -> tonemap -> luminosité (linéaire) -> sRGB ->
// contraste -> saturation (moyenne)) ramène exactement à la couleur d'origine.
// window_bcs = (luminosité, contraste, saturation) ; window_tm = (mode,
// white, exposition, -) avec mode 0 linéaire, 1 Reinhard, 2 filmic (3 ACES
// et 4 AgX : pas d'inverse, tonemap non compensé).
vec3 window_untonemap(vec3 y) {
	float w = window_tm.y;
	if (window_tm.x > 0.5 && window_tm.x < 1.5) {
		float w2 = w * w;
		y = min(y, vec3(0.999));
		return w2 * 0.5 * ((y - 1.0) + sqrt((1.0 - y) * (1.0 - y) + 4.0 * y / w2));
	} else if (window_tm.x > 1.5 && window_tm.x < 2.5) {
		const float FM_A = 0.88;
		const float FM_B = 0.6;
		const float FM_C = 0.1;
		const float FM_D = 0.2;
		const float FM_E = 0.01;
		const float FM_F = 0.3;
		float wt = ((w * (FM_A * w + FM_C * FM_B) + FM_D * FM_E) / (w * (FM_A * w + FM_B) + FM_D * FM_F)) - FM_E / FM_F;
		vec3 t = min(y, vec3(0.999)) * wt + FM_E / FM_F;
		vec3 a = (t - 1.0) * FM_A;
		vec3 b = FM_B * (t - FM_C);
		vec3 c = FM_D * (t * FM_F - FM_E);
		vec3 disc = max(b * b - 4.0 * a * c, 0.0);
		return (-b - sqrt(disc)) / (2.0 * min(a, vec3(-0.0001)));
	}
	return y;
}

vec3 window_encode(vec3 d) {
	float m = (d.r + d.g + d.b) / 3.0;
	d = m + (d - m) / max(window_bcs.z, 0.05);
	d = (d - 0.5) / max(window_bcs.y, 0.05) + 0.5;
	vec3 lin = pow(clamp(d, 0.0, 1.0), vec3(2.2)) / max(window_bcs.x, 0.05);
	return window_untonemap(lin) / max(window_tm.z, 0.01);
}

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0, 0.0);
// true : alpha normalisé (x2, clampé) — masque l'alpha < 1 parasite des
// buffers de jeux. false : alpha brut, pour les fenêtres réellement
// translucides (Konsole...), détectées par la sonde d'alpha.
uniform bool opaque_mode = true;

void fragment() {
	vec2 ts = vec2(textureSize(window_texture, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	vec4 tex = texture(window_texture, mapped_uv);
	if (tex.a > 0.01) {
		vec3 unmultiplied = tex.rgb / max(tex.a, 0.001);
		ALBEDO = window_encode(unmultiplied);
		ALPHA = opaque_mode ? clamp(tex.a * 2.0, 0.0, 1.0) : tex.a;
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
var window_app_ids: Dictionary = {} # window_id (int) -> String (app_id Wayland / classe X11)
var window_shared: Dictionary = {} # window_id (int) -> bool (visible par les autres joueurs)
var _texture_versions: Dictionary = {} # window_id (int) -> int (version du contenu, pour le LAN)
var fullscreen_windows: Dictionary = {} # window_id (int) -> bool (plein écran)
var window_server_side: Dictionary = {} # window_id (int) -> true si SSD, false si CSD
var popup_parent_info: Dictionary = {} # popup_id -> {parent_window_id, parent_popup_id, x, y, width, height}

# Posé par wayland_room : Callable(clé: String, actif: bool) — demande/libère
# la copie CPU des captures auprès du lan_manager.
var cpu_capture_notify: Callable = Callable()
## Fenêtres en mode focus : leur quad 3D (toujours visible derrière l'overlay)
## garde sa taille d'avant le focus. Le client est agrandi plein écran, et
## suivre sa texture donnait au quad la taille de l'écran : à la sortie du
## focus, ce grand quad opaque masquait le niveau jusqu'à ce que le client
## ait recommit sa taille d'origine.
var focus_frozen: Dictionary = {} # wid (int) -> true
var _alpha_probes: Dictionary = {} # wid -> temps restant avant abandon
var _alpha_decided: Dictionary = {} # wid -> true (classé, ne plus sonder)
var _alpha_translucent: Dictionary = {} # wid -> bool (résultat de la classification)

var _shared_window_shader: Shader = null
var _shared_window_shader_no_depth: Shader = null
var _shared_window_shader_translucent: Shader = null

var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune

var resizing_edge := "" # "left", "right", "top", "bottom", etc.
var is_resizing := false
var is_moving := false
var active_window_id := -1
var is_in_window := false
# Déplacement: distance (caméra -> fenêtre) figée au moment du grab, la
# fenêtre suit ensuite le viseur le long de ce rayon.
var move_depth := 0.0

# Fenêtre sur laquelle celle-ci est collée : wid -> {wid, side}
var snapped_to: Dictionary = {} # wid (int) -> Dictionary

# Orientation figée par fenêtre : wid -> Basis.
# Avant, une fenêtre était un billboard — `global_basis = base caméra` réécrit
# à chaque frame, plus un yaw appliqué par-dessus. Une fenêtre qui hérite de
# l'orientation de sa voisine ne peut PAS rester un billboard : ce modèle
# écraserait l'héritage dès la frame suivante. D'où une base stockée, écrite
# uniquement à la création, à l'héritage du collage et au scroll de rotation.
var _window_basis: Dictionary = {} # wid (int) -> Basis

var _group_grab := false
var _grab_action := "grab"

# ── Modules (nœuds enfants, créés dans _init : mêmes chemins de RPC chez le serveur et les clients) ──
const PointerModule := preload("res://scripts/windows/windows_3d/pointer.gd")
const GrabModule := preload("res://scripts/windows/windows_3d/grab.gd")
const SnapModule := preload("res://scripts/windows/windows_3d/snap.gd")
const SortingModule := preload("res://scripts/windows/windows_3d/sorting.gd")
const AlphaModule := preload("res://scripts/windows/windows_3d/alpha.gd")
var pointer: PointerModule = null
var grab: GrabModule = null
var snap: SnapModule = null
var sorting: SortingModule = null
var alpha: AlphaModule = null

func _init() -> void:
	pointer = PointerModule.new()
	pointer.name = "Pointer"
	pointer.w3d = self
	add_child(pointer)
	grab = GrabModule.new()
	grab.name = "Grab"
	grab.w3d = self
	add_child(grab)
	snap = SnapModule.new()
	snap.name = "Snap"
	snap.w3d = self
	add_child(snap)
	sorting = SortingModule.new()
	sorting.name = "Sorting"
	sorting.w3d = self
	add_child(sorting)
	alpha = AlphaModule.new()
	alpha.name = "Alpha"
	alpha.w3d = self
	add_child(alpha)

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

# Variante translucide : même rendu mais sans écriture de profondeur, sinon la
# fenêtre translucide du dessus (triée avant celle du dessous selon la position)
# rejette par depth test les pixels de la fenêtre derrière elle.
func _window_shader_translucent() -> Shader:
	if _shared_window_shader_translucent == null:
		_shared_window_shader_translucent = Shader.new()
		_shared_window_shader_translucent.code = WAYLAND_SHADER_CODE.replace(
			"depth_draw_always", "depth_draw_never")
	return _shared_window_shader_translucent

func _window_shader_no_depth() -> Shader:
	if _shared_window_shader_no_depth == null:
		_shared_window_shader_no_depth = Shader.new()
		_shared_window_shader_no_depth.code = WAYLAND_SHADER_NO_DEPTH_CODE
	return _shared_window_shader_no_depth

func next_spawn_pos() -> Vector3:
	var camera: Camera3D = _camera()
	var cam_pos: Vector3 = camera.global_position
	var cam_forward: Vector3 = -camera.global_basis.z
	# Position de base : SPAWN_DISTANCE devant la caméra.
	var base_pos := cam_pos + cam_forward * SPAWN_DISTANCE
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
# Taille en pixels du contenu d'une fenêtre (texture), (0, 0) si pas encore de contenu.
func _content_px(wid: int) -> Vector2i:
	var tex: Texture2D = window_textures.get(wid)
	if tex == null or not is_instance_valid(tex):
		return Vector2i.ZERO
	return Vector2i(tex.get_width(), tex.get_height())

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
			# Pour les clients qui suivent une fenêtre (overlay de Ludodex) : taille du
			# CONTENU en pixels (la « size » ci-dessus est celle du quad 3D, en mètres),
			# nom, et « hidden » = masquée par toggle_hide (l'équivalent de « réduite »).
			"width": _content_px(wid).x,
			"height": _content_px(wid).y,
			"title": window_titles.get(wid, ""),
			"app_id": window_app_ids.get(wid, ""),
			"hidden": not quad.visible,
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
	var deco := snap._deco_of(quad)
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
	# Une fenêtre translucide laisse voir derrière elle : jamais d'occludeur.
	if active and _alpha_translucent.get(wid, false):
		occ.occluder = null
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

func toggle_hide(id: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	quad.visible = not quad.visible
	_set_quad_interactive(quad, quad.visible)
	window_hidden_changed.emit(id, not quad.visible)
	windows_state_changed.emit()

func on_window_mapped(id: int, title: String, app_id: String) -> void:
	window_app_ids[id] = app_id
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
	snap._build_snap_zones(quad)

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

	quad.add_to_group("window")
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
	alpha._update_alpha_probes(delta)
	# Le décor est rechargé depuis un fichier, comme le thème CSS : le tick
	# renvoie true quand un mtime a changé.
	if Decorations.tick(delta):
		_sync_all_decorations()
	sorting._update_window_sorting()

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
	snap._sync_snap_zones(quad)
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
	
	# Le compositeur libère la texture de la fenêtre juste après l'unmap : pour
	# que la transition de fermeture ait encore une image à animer, on en prend
	# un instantané AVANT d'oublier l'état.
	var snapshot_rid := RID()
	var snapshot: Texture2D = null
	if WindowShaders.get_shader("close") != null and quads.has(id):
		var snap := _snapshot_texture(window_textures.get(id))
		snapshot = snap[0]
		snapshot_rid = snap[1]
	snap._erase_window_state(id)
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
			if occ != null:
				occ.queue_free()
				await get_tree().physics_frame
			if is_instance_valid(quad) and quad.visible \
					and WindowShaders.get_shader("close") != null:
				# Transition de fermeture : le quad survit le temps de l'effet,
				# mais n'est plus ni une fenêtre, ni cliquable, ni enregistré.
				quads.erase(id)
				windows_state_changed.emit()
				quad.remove_from_group("window")
				_disable_collisions(quad)
				if snapshot != null:
					var base := quad.material_override as ShaderMaterial
					if base != null:
						base.set_shader_parameter("window_texture", snapshot)
				await _play_transition(quad, "close")
			if is_instance_valid(quad):
				quad.queue_free()
		if snapshot_rid.is_valid():
			await get_tree().process_frame
			var rd := RenderingServer.get_rendering_device()
			if rd != null:
				rd.free_rid(snapshot_rid)
		quads.erase(id)
	windows_state_changed.emit()

# Copie GPU de la texture d'une fenêtre, indépendante du cycle de vie de la
# fenêtre. Renvoie [Texture2D ou null, RID de la copie (à libérer) ou RID()].
func _snapshot_texture(tex: Texture2D) -> Array:
	if tex == null or not is_instance_valid(tex):
		return [null, RID()]
	if not (tex is Texture2DRD):
		var img := tex.get_image()
		if img == null or img.is_empty():
			return [null, RID()]
		return [ImageTexture.create_from_image(img), RID()]
	var rd := RenderingServer.get_rendering_device()
	var src: RID = (tex as Texture2DRD).texture_rd_rid
	if rd == null or not src.is_valid() or not rd.texture_is_valid(src):
		return [null, RID()]
	var fmt := rd.texture_get_format(src)
	if fmt == null or not (fmt.usage_bits & RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT):
		return [null, RID()]
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var dst := rd.texture_create(fmt, RDTextureView.new())
	if not dst.is_valid():
		return [null, RID()]
	var size := Vector3(fmt.width, fmt.height, 1.0)
	if rd.texture_copy(src, dst, Vector3.ZERO, Vector3.ZERO, size, 0, 0, 0, 0) != OK:
		rd.free_rid(dst)
		return [null, RID()]
	var out := Texture2DRD.new()
	out.texture_rd_rid = dst
	return [out, dst]

func _disable_collisions(node: Node) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0
		(node as CollisionObject3D).collision_mask = 0
	for c in node.get_children():
		_disable_collisions(c)

# Joue la transition "open" / "close" (shader utilisateur) sur le quad et son
# décor. Rend la main à la fin ; sans shader, retourne aussitôt.
func _play_transition(quad: MeshInstance3D, kind: String) -> void:
	var mats: Array = WindowShaders.begin_transition(quad, kind)
	if mats.is_empty():
		return
	var closing := kind == "close"
	var dur := float(Decorations.metrics().get("transition_%s_duration" % kind, 0.3))
	WindowShaders.set_progress(mats, 0.0, closing)
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void: WindowShaders.set_progress(mats, v, closing),
		0.0, 1.0, maxf(dur, 0.01))
	await tw.finished
	if not is_instance_valid(quad):
		return
	WindowShaders.end_transition(quad)
	if closing:
		return
	# Matériaux rendus : on réapplique le skin de bordure et le mode d'alpha
	# éventuellement décidé pendant l'effet.
	_sync_decorations(quad)
	if quad.has_meta("pending_opaque"):
		var wid := int(quad.get_meta("window_id_of", -1))
		if wid >= 0:
			alpha._set_quad_opaque_mode(wid, bool(quad.get_meta("pending_opaque")))
		quad.remove_meta("pending_opaque")

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
	alpha._start_alpha_probe(id)
	# Transition d'ouverture : à la PREMIÈRE texture (avant, le contenu est vide).
	if not quad.has_meta("open_played"):
		quad.set_meta("open_played", true)
		_play_transition(quad, "open")

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

	if focus_frozen.has(id):
		return
	_fit_quad_to_surface(quad, body, width, height)

## Redonne au quad la taille monde correspondant à une surface de width × height
## px (ratio d'aspect du client ; hauteur conservée si la fenêtre a été
## redimensionnée à la main).
func _fit_quad_to_surface(quad: MeshInstance3D, body: StaticBody3D, width: int, height: int) -> void:
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

## Fin du gel de taille (sortie du focus). `refit` : la fenêtre ne sera pas
## redimensionnée par le client, on recale donc le quad sur sa surface actuelle.
func release_focus_frozen(id: int, refit: bool) -> void:
	focus_frozen.erase(id)
	if not refit or not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	var body: StaticBody3D = quad.get_child(0)
	var sz: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	_fit_quad_to_surface(quad, body, int(sz.x), int(sz.y))

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
# Voisines qui PARTAGENT le bord tiré : {side (côté de la tirée), wid, mesh, px,
# offset, pos}.
var _resize_shared: Array = []

# ── Relais vers les modules (API publique inchangée) ─────────────────

func can_group_grab(wid: int) -> bool:
	return grab.can_group_grab(wid)

func copy_window_basis(from_id: int, to_id: int) -> void:
	snap.copy_window_basis(from_id, to_id)

func get_grabbed_window_id() -> int:
	return grab.get_grabbed_window_id()

func get_window_translucent(wid: int) -> int:
	return alpha.get_window_translucent(wid)

func is_group_grabbed(wid: int) -> bool:
	return grab.is_group_grabbed(wid)

func process_raycast(ray_origin: Vector3, ray_dir: Vector3, delta: float, interact_active: bool) -> void:
	pointer.process_raycast(ray_origin, ray_dir, delta, interact_active)

func set_snapping_enabled(on: bool) -> void:
	snap.set_snapping_enabled(on)

func set_window_translucent(wid: int, translucent: bool) -> void:
	alpha.set_window_translucent(wid, translucent)

func toggle_grab_window(wid: int, at_spawn_distance := false) -> void:
	grab.toggle_grab_window(wid, at_spawn_distance)

func toggle_group_grab(wid: int) -> void:
	grab.toggle_group_grab(wid)
