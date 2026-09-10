extends Node
## Tests pour le portrait figé de l'avatar (PlayersMenu AvatarViewport).

const Runner = preload("res://tests/runner.gd")
const PlayersMenu = preload("res://scripts/ui/players_menu.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const AvatarScene = preload("res://scenes/avatar.tscn")

func _structure_checks() -> Array:
	var scene := PlayerScene.instantiate()
	var checks: Array = []
	var vp := scene.get_node_or_null("PlayersMenuLayer/PlayersMenu/VBox/Content/Preview/AvatarViewport") as SubViewport
	checks.append([vp != null, "AvatarViewport trouvable"])
	if vp != null:
		checks.append([vp.transparent_bg == true, "fond transparent actif sur l'AvatarViewport"])
		checks.append([vp.own_world_3d == true, "monde 3D isolé (own_world_3d) : la preview ne rend pas le level"])
		var light := false
		for c in vp.get_children():
			if c is DirectionalLight3D:
				light = true
		checks.append([not light, "aucun DirectionalLight3D dans l'AvatarViewport"])
		var cam := vp.get_node_or_null("Camera3D") as Camera3D
		checks.append([cam != null, "Camera3D presente dans l'AvatarViewport"])
		if cam != null:
			checks.append([cam.rotation.x == 0.0, "camera sans inclinaison (pitch 0)"])
			checks.append([cam.rotation.y == 0.0, "camera droit devant (yaw 0)"])
			checks.append([cam.rotation.z == 0.0, "camera sans roll (z 0)"])
			checks.append([cam.position.x == 0.0, "camera centree sur l'avatar"])
	scene.free()
	return checks

func test_preview_viewport_config():
	for c in _structure_checks():
		var r = Runner.assert_eq(c[0], true, String(c[1]))
		if r != true: return r
	return true

func test_preview_materials_unshaded():
	var avatar := AvatarScene.instantiate()
	var albedo_before: Array = []
	var stack: Array[Node] = [avatar]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh != null:
			var mat: BaseMaterial3D = null
			if n.material_override is BaseMaterial3D:
				mat = n.material_override
			elif n.mesh.get_surface_count() > 0:
				mat = n.mesh.surface_get_material(0)
			if mat != null:
				albedo_before.append(mat.albedo_color)
		for child in n.get_children():
			stack.append(child)
	PlayersMenu.apply_flat_preview_materials(avatar)
	var overrides: Array = []
	var all_unshaded := true
	stack = [avatar]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh != null and n.material_override is BaseMaterial3D:
			var ov := n.material_override as BaseMaterial3D
			overrides.append(ov)
			if ov.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED:
				all_unshaded = false
		for child in n.get_children():
			stack.append(child)
	avatar.free()
	if overrides.is_empty():
		return Runner.assert_eq(true, false, "au moins un override unshaded applique")
	if not all_unshaded:
		return Runner.assert_eq(true, false, "tous les meshes en shading_mode UNSHADED")
	for i in range(mini(overrides.size(), albedo_before.size())):
		if overrides[i].albedo_color != albedo_before[i]:
			return Runner.assert_eq(true, false, "albedo conserve (mesh %d)" % i)
	return true