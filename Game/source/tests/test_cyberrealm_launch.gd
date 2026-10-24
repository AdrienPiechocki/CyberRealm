extends Node
## Tests de compositors/cyberrealm-launch : la redirection DISPLAY doit
## suivre le display dynamique choisi par le jeu ($XDG_RUNTIME_DIR/
## cyberrealm-x11-display) au lieu d'un ":1" codé en dur — KWin 6.8+ utilise
## déjà :0 et :1, un ":1" fixe enverrait les apps X11 sur le bureau KDE.

const Runner = preload("res://tests/runner.gd")

var _test_root := ""

func _fresh_rt(name: String) -> String:
	_test_root = ProjectSettings.globalize_path("user://tests/cyberrealm_launch")
	_rm_rf(_test_root)
	var rt := _test_root.path_join(name)
	DirAccess.make_dir_recursive_absolute(rt)
	return rt

func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f != "." and f != "..":
			var child := path.path_join(f)
			if d.current_is_dir():
				_rm_rf(child)
			else:
				DirAccess.remove_absolute(child)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)

func _touch(path: String, content: String = "") -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()

## Lance cyberrealm-launch avec XDG_RUNTIME_DIR contrôlé et renvoie la
## valeur de $DISPLAY telle que le processus enfant l'a vue.
##
## PIEGE : ne JAMAIS placer "$DISPLAY" dans une chaîne `sh -c` passée à
## OS.execute — la couche d'exécution de l'hôte (wrapping `sh -c --`)
## expand la variable avec SON environnement avant d'atteindre le launcher,
## et le test lirait le DISPLAY du bureau KDE. `printenv` est externe : il
## lit l'environnement du processus, sans aucune expansion shell.
func _run_launcher(rt: String) -> String:
	var launcher := ProjectSettings.globalize_path("res://../../compositors/cyberrealm-launch")
	var output := []
	OS.execute("/usr/bin/env", [
		"XDG_RUNTIME_DIR=" + rt,
		"bash", launcher,
		"printenv", "DISPLAY",
	], output, true)
	var result := ""
	for line in output:
		result += str(line)
	return result.strip_edges()

func test_lit_le_display_du_fichier_runtime():
	var rt := _fresh_rt("with_game")
	_touch(rt.path_join("cyberrealm-0"))           # le jeu tourne
	_touch(rt.path_join("cyberrealm-x11-display"), ":5\n")
	var r = _run_launcher(rt)
	return Runner.assert_eq(r, ":5",
		"DISPLAY doit venir de cyberrealm-x11-display (le display réel du jeu)")

func test_fallback_quand_fichier_absent():
	var rt := _fresh_rt("no_file")
	_touch(rt.path_join("cyberrealm-0"))           # le jeu tourne, mais pas de fichier
	var r = _run_launcher(rt)
	return Runner.assert_eq(r, ":2",
		"sans fichier, fallback sur :2 (jamais :0/:1 : hébergés par KWin)")

func test_rien_redirige_sans_jeu():
	var rt := _fresh_rt("no_game")
	# Pas de socket cyberrealm-0 → pas de redirection, DISPLAY inchangé
	# (la valeur héritée de la session hôte doit être répercutée telle quelle).
	var r = _run_launcher(rt)
	return Runner.assert_eq(r, OS.get_environment("DISPLAY").strip_edges(),
		"sans le jeu, DISPLAY ne doit pas être touché")
