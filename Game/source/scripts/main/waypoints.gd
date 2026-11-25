extends Node
## Waypoints : SUPER+SHIFT+N (N = 0..9, rangée de chiffres, touches physiques) enregistre la position du joueur,
## SUPER+N s'y téléporte. Sauvegarde dans user://waypoints.json, rangée par niveau (clé : uid de la scène du niveau,
## à défaut son chemin). Désactivé sur un niveau reçu d'un hôte LAN (pas de clé stable).
##
## Niveaux à « portées » (intérieurs rangés loin de l'extérieur, ex. Morrowind) : un nœud du groupe
## "waypoint_scope" exposant waypoint_teleport(pos, yaw) se charge de la téléportation (activer l'intérieur visé…).

const SAVE_PATH := "user://waypoints.json"
const SLOTS := {
	KEY_0: 0, KEY_1: 1, KEY_2: 2, KEY_3: 3, KEY_4: 4,
	KEY_5: 5, KEY_6: 6, KEY_7: 7, KEY_8: 8, KEY_9: 9,
}

var player: Node3D = null
var level_key := Callable()     # -> String ("" = waypoints indisponibles)
var can_handle := Callable()    # -> bool (menus, focus, mode interaction… : on laisse passer la touche)

var _data := {}                 # clé de niveau -> {"slot": {pos:[x,y,z], yaw, pitch}}
var _label: Label = null
var _tween: Tween = null

func _ready() -> void:
	_load()
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_label.offset_top = -140.0
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	_label.modulate.a = 0.0
	layer.add_child(_label)

func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or not k.meta_pressed or k.ctrl_pressed or k.alt_pressed:
		return
	var code: int = k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
	if not SLOTS.has(code):
		return
	if player == null or not is_instance_valid(player) or (can_handle.is_valid() and not can_handle.call()):
		return
	get_viewport().set_input_as_handled()
	var key := String(level_key.call()) if level_key.is_valid() else ""
	if key == "":
		_notify("Waypoints unavailable on this level")
		return
	var slot := int(SLOTS[code])
	if k.shift_pressed:
		_set_waypoint(key, slot)
	else:
		_goto_waypoint(key, slot)

func _set_waypoint(key: String, slot: int) -> void:
	var p := player.global_position
	var cam := player.get_node_or_null("Camera3D") as Camera3D
	var lvl: Dictionary = _data.get(key, {})
	lvl[str(slot)] = {"pos": [p.x, p.y, p.z], "yaw": player.rotation.y, "pitch": cam.rotation.x if cam else 0.0}
	_data[key] = lvl
	_save()
	_notify("Waypoint %d set" % slot)

func _goto_waypoint(key: String, slot: int) -> void:
	var w: Variant = (_data.get(key, {}) as Dictionary).get(str(slot))
	if w == null:
		_notify("Waypoint %d is empty" % slot)
		return
	var pos := Vector3(w["pos"][0], w["pos"][1], w["pos"][2])
	var yaw := float(w["yaw"])
	if "tps_orbit_yaw" in player:
		player.set("tps_orbit_yaw", 0.0)
	var scope := get_tree().get_first_node_in_group("waypoint_scope")
	if scope != null and scope.has_method("waypoint_teleport"):
		scope.waypoint_teleport(pos, yaw)
	else:
		player.global_position = pos
		player.rotation.y = yaw
		if "velocity" in player:
			player.set("velocity", Vector3.ZERO)
	var cam := player.get_node_or_null("Camera3D") as Camera3D
	if cam != null:
		cam.rotation.x = float(w.get("pitch", 0.0))
	_notify("Waypoint %d" % slot)

func _notify(text: String) -> void:
	_label.text = text
	_label.modulate.a = 1.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(1.2)
	_tween.tween_property(_label, "modulate:a", 0.0, 0.5)

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary:
		_data = parsed

func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("waypoints: écriture impossible (%s)" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(_data, "\t"))
