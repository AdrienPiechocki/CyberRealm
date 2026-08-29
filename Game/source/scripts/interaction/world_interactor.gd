extends Node3D
## Interaction « clic gauche » avec les objets du niveau.
##
## Convention pour les scripts utilisateur (voir user/README.md) :
##  - func interact(_player_id: int) — OBLIGATOIRE : appelée quand un joueur
##    clique l'objet (le rayon touche son collider ou celui d'un descendant).
##    La signature courte func interact() est aussi acceptée.
##  - func get_interact_prompt() -> String — optionnel : texte affiché sous le
##    viseur quand l'objet est visé (défaut : « Left click: interact »).
##  - func interact_focus(aimed: bool) — optionnel : surbrillance maison quand
##    le viseur entre/sort de l'objet.
##
## Multijoueur : chaque machine exécute SA copie. Un clic appelle interact()
## localement PUIS relaie à tous les pairs (RPC fiable, relais serveur) qui
## appellent interact() sur LEUR copie — même NodePath partout. Effets
## partagés automatiques tant que la fonction reste déterministe ; pour une
## logique autoritaire, comparez player_id à 1 (l'hôte).
##
## Priorité fenêtres : si le rayon touche d'abord une surface Wayland
## (fenêtre, barre de titre, popup), le clic appartient à l'application —
## aucune interaction monde. Portée : 3 m depuis la caméra.

const REACH := 3.0
# Remontée hiérarchique maximale depuis le collider touché pour trouver un
# nœud exposant interact() (ex. script porte sur le parent du StaticBody3D).
const MAX_ANCESTORS := 8
# Métas posés par windows_3d sur les colliders du système de fenêtres.
const WINDOW_METAS: Array[String] = ["window_id", "titlebar_of", "titlebar_button", "popup_id"]
# Anti-spam du relais réseau : au plus une interaction par pair et période.
const NET_RATE_LIMIT_MSEC := 150
const PROMPT_DEFAULT := "Left click: interact"

var player: CharacterBody3D = null
var lan: Node = null # session active ? (null en solo pur)

var _prompt: Label = null
var _aimed_target: Node = null
var _net_last_msec := {} # peer_id -> msec du dernier relais accepté

func setup(p_player: CharacterBody3D, p_lan: Node) -> void:
	player = p_player
	lan = p_lan
	# Étiquette HUD sous le viseur (réutilise le CanvasLayer UI du joueur).
	if player != null and player.has_node("UI"):
		_prompt = Label.new()
		var ls := LabelSettings.new()
		ls.font_size = 15
		ls.font_color = Color(1, 1, 1, 0.85)
		ls.shadow_color = Color(0, 0, 0, 0.8)
		ls.shadow_size = 3
		_prompt.label_settings = ls
		_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_prompt.anchor_left = 0.5
		_prompt.anchor_right = 0.5
		_prompt.anchor_top = 0.5
		_prompt.anchor_bottom = 0.5
		_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_prompt.offset_left = -200
		_prompt.offset_right = 200
		_prompt.offset_top = 24
		_prompt.offset_bottom = 48
		_prompt.visible = false
		(player.get_node("UI") as CanvasLayer).add_child(_prompt)

func _exit_tree() -> void:
	_set_aimed(null)

## Appelé chaque frame par wayland_room APRÈS win3d.process_raycast (même
## rayon caméra) : toutes les portes logiques amont (menus, focus, lock,
## overlays clavier, chargement LAN) ont déjà filtré.
## simulate_pressed : contourne Input pour les tests headless (la capture
## souris n'y existe pas).
func update_aim(ray_origin: Vector3, ray_dir: Vector3, simulate_pressed := false) -> void:
	if player == null or not is_instance_valid(player):
		return
	# Souris visible (menu qui se ferme, overlay…) : ce clic-là n'est pas un
	# tir FPS — ni visée, ni interaction.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not simulate_pressed:
		_set_aimed(null)
		return
	var target := resolve_target(ray_origin, ray_dir)
	_set_aimed(target)
	if target != null and (simulate_pressed or Input.is_action_just_pressed("left_click", false)):
		interact_with(target)

## Résout la cible visée : premier objet interactif sur le rayon (collider
## touché puis ses ancêtres), null si rien / fenêtre Wayland / hors portée.
func resolve_target(ray_origin: Vector3, ray_dir: Vector3) -> Node:
	var to := ray_origin + ray_dir * REACH
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	params.collide_with_areas = false
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return null
	var collider: Object = hit.collider
	for meta in WINDOW_METAS:
		if collider.has_meta(meta):
			return null
	# Distance réelle au point d'impact (l'ancêtre interactif peut être plus
	# loin que son collider — c'est le contact qui compte).
	if (hit.position as Vector3).distance_to(ray_origin) > REACH:
		return null
	return _find_interactable(collider as Node)

static func _find_interactable(from: Node) -> Node:
	var n := from
	for i in MAX_ANCESTORS:
		if n == null or not is_instance_valid(n):
			return null
		if n.has_method("interact"):
			return n
		n = n.get_parent()
	return null

## Déclenche une interaction : exécution locale immédiate, puis relais aux
## autres pairs (chaque machine appellera interact() sur sa copie).
func interact_with(target: Node) -> void:
	if target == null or not is_instance_valid(target) or not target.has_method("interact"):
		return
	var my_id := multiplayer.get_unique_id()
	_call_interact(target, my_id)
	if lan != null and is_instance_valid(lan) \
			and lan.has_method("is_session_active") and lan.is_session_active():
		_net_interact.rpc(String((target as Node).get_path()), my_id)

## Appelle interact() avec ou sans argument player_id selon la signature
## déclarée par le script utilisateur.
static func _call_interact(n: Node, peer_id: int) -> void:
	for m in n.get_method_list():
		if m.name != "interact":
			continue
		if (m.args as Array).size() >= 1:
			n.call("interact", peer_id)
		else:
			n.call("interact")
		return

# ── Relais multijoueur ───────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable")
func _net_interact(target_path: String, from_peer: int) -> void:
	_apply_net_interact(multiplayer.get_remote_sender_id(), target_path, from_peer)

## Corps du relais isolé pour testabilité (sender explicite).
func _apply_net_interact(sender: int, target_path: String, from_peer: int) -> void:
	if sender == 0 or sender != from_peer:
		return
	var now := Time.get_ticks_msec()
	if now - int(_net_last_msec.get(sender, -NET_RATE_LIMIT_MSEC)) < NET_RATE_LIMIT_MSEC:
		return
	_net_last_msec[sender] = now
	var level := _level_root()
	if level == null:
		return
	var prefix := String(level.get_path()) + "/"
	if not target_path.begins_with(prefix):
		push_warning("Interactor: out-of-level target rejected (%s)" % target_path)
		return
	var n := get_node_or_null(NodePath(target_path))
	if n != null and n.has_method("interact"):
		_call_interact(n, from_peer)

# Racine du niveau résolue à la demande : elle est REMPLACÉE en LAN
# (apply_host_level / restore_local_level), une référence figée vieillirait.
func _level_root() -> Node:
	var p := get_parent()
	return p.get_node_or_null("Level") if p != null else null

# ── Survol : hooks de focus + étiquette HUD ──────────────────────────

func _set_aimed(t: Node) -> void:
	if t == _aimed_target:
		return
	if _aimed_target != null and is_instance_valid(_aimed_target) \
			and _aimed_target.has_method("interact_focus"):
		_aimed_target.interact_focus(false)
	_aimed_target = t
	if t != null and t.has_method("interact_focus"):
		t.interact_focus(true)
	_update_prompt()

func _update_prompt() -> void:
	if _prompt == null or not is_instance_valid(_prompt):
		return
	var txt := _prompt_text(_aimed_target)
	if txt.is_empty():
		_prompt.visible = false
	else:
		_prompt.text = txt
		_prompt.visible = true

## Texte à afficher pour une cible visée ("" = rien). Facteur isolé pour
## testabilité.
func _prompt_text(target: Node) -> String:
	if target == null or not is_instance_valid(target):
		return ""
	var txt := PROMPT_DEFAULT
	if target.has_method("get_interact_prompt"):
		txt = str(target.get_interact_prompt())
	return txt
