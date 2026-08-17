extends Node3D
## Effets visuels sur les fenêtres 3D : flash blanc à l'ouverture et
## highlight X-RAY (touche "find" du menu fenêtres) qui matérialise une
## fenêtre derrière les murs (no_depth_test).
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const FLASH_DURATION := 0.2

var windows: Node3D
var xray_windows: Dictionary = {} # window_id (int) -> bool
var xray_time: float = 0.0
var xray_overlay: StandardMaterial3D # material pour l'effet X-RAY (no_depth_test)
var flash_windows: Dictionary = {} # window_id (int) -> {mat, elapsed} — flash blanc à l'ouverture

func setup(windows_ref: Node3D) -> void:
	windows = windows_ref
	# Matériau X-RAY: transparent, passe devant tout (no_depth_test)
	xray_overlay = StandardMaterial3D.new()
	xray_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	xray_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	xray_overlay.albedo_color = Color(1.0, 0.15, 0.15, 0.6)
	xray_overlay.no_depth_test = true
	xray_overlay.render_priority = 10
	xray_overlay.cull_mode = BaseMaterial3D.CULL_DISABLED

func on_window_created(id: int, quad: MeshInstance3D) -> void:
	_start_flash(id, quad)

func on_window_unmapped(id: int) -> void:
	xray_windows.erase(id)
	_end_flash(id)

# Bascule le highlight X-RAY d'une fenêtre (action FIND du menu fenêtres).
func toggle_find(id: int) -> void:
	xray_windows[id] = not xray_windows.get(id, false)
	var active: bool = xray_windows.get(id, false)
	if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
		if not active:
			windows.quads[id].material_overlay = null
		else:
			set_quad_visible(id, true)
			windows.quads[id].material_overlay = xray_overlay

func set_quad_visible(id: int, visible: bool) -> void:
	if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
		var quad: MeshInstance3D = windows.quads[id]
		quad.visible = visible
		_set_quad_interactive(quad, visible)

func _set_quad_interactive(quad: MeshInstance3D, enabled: bool) -> void:
	for child in quad.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D:
					shape_node.disabled = not enabled
		elif child is MeshInstance3D:
			_set_quad_interactive(child, enabled)

func process(delta: float) -> void:
	_update_xray(delta)
	_update_flashes(delta)

func _update_xray(delta: float) -> void:
	if xray_windows.is_empty():
		return
	xray_time += delta
	var pulse := (sin(xray_time * 6.0) * 0.5 + 0.5) # 0..1, ~1 Hz
	xray_overlay.albedo_color.a = 0.3 + pulse * 0.5

func _start_flash(id: int, quad: MeshInstance3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.4, .4)
	mat.no_depth_test = true
	mat.render_priority = 10
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material_overlay = mat
	flash_windows[id] = {"mat": mat, "elapsed": 0.0}

func _end_flash(id: int) -> void:
	if not flash_windows.has(id):
		return
	if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
		windows.quads[id].material_overlay = null
	flash_windows.erase(id)

func _update_flashes(delta: float) -> void:
	if flash_windows.is_empty():
		return
	for id in flash_windows.keys():
		var entry: Dictionary = flash_windows[id]
		entry["elapsed"] += delta
		var t: float = entry["elapsed"] / FLASH_DURATION
		if t >= 1.0:
			_end_flash(id)
		else:
			var mat: StandardMaterial3D = entry.get("mat")
			if mat:
				mat.albedo_color.a = (1.0 - t) * 0.9
