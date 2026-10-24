extends Node
## Tests de X11Display : sélection d'un display X11 libre pour xwayland-satellite.
##
## Contexte : KWin 6.8+ réserve les displays :0 ET :1 (--xwayland-init-display),
## le jeu devait donc choisir dynamiquement un display libre au lieu de coder
## ":1" en dur (sinon xwayland-satellite échoue et les apps X11 atterrissent
## sur le Xwayland de KWin).

const Runner = preload("res://tests/runner.gd")
const X11 = preload("res://scripts/main/x11_display.gd")

var _test_root := ""

func _fresh_dirs() -> void:
	# Deux répertoires jetables : l'un imite /tmp (locks .X<n>-lock),
	# l'autre /tmp/.X11-unix (sockets X<n>). Des chemins injectés, donc
	# les tests ne touchent jamais aux vrais fichiers du système.
	_test_root = ProjectSettings.globalize_path("user://tests/x11_display")
	_rm_rf(_test_root)
	for sub in ["lock", "unix"]:
		DirAccess.make_dir_recursive_absolute(_test_root.path_join(sub))

func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	# include_hidden : les locks .X<n>-lock commencent par un point ; sans
	# ça ils survivent au nettoyage et faussent les tests suivants.
	d.include_hidden = true
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

func _touch(rel_path: String) -> void:
	var path := _test_root.path_join(rel_path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("1234")
		f.close()

# ── is_display_busy ───────────────────────────────────────────────────

func test_is_display_busy_display_libre():
	_fresh_dirs()
	var r = X11.is_display_busy(2, _test_root.path_join("lock"), _test_root.path_join("unix"))
	return Runner.assert_eq(r, false, "ni lock ni socket → display libre")

func test_is_display_busy_lock_present():
	_fresh_dirs()
	_touch("lock/.X2-lock")
	var r = X11.is_display_busy(2, _test_root.path_join("lock"), _test_root.path_join("unix"))
	return Runner.assert_eq(r, true, "/tmp/.X<n>-lock présent → display pris")

func test_is_display_busy_socket_present():
	_fresh_dirs()
	_touch("unix/X3")
	var r = X11.is_display_busy(3, _test_root.path_join("lock"), _test_root.path_join("unix"))
	return Runner.assert_eq(r, true, "socket /tmp/.X11-unix/X<n> présent → display pris")

# ── pick_free_display ─────────────────────────────────────────────────

func test_pick_free_display_saute_les_displays_pris():
	_fresh_dirs()
	# :2 pris (lock), :3 pris (socket) → le premier libre est :4.
	_touch("lock/.X2-lock")
	_touch("unix/X3")
	var r = X11.pick_free_display(_test_root.path_join("lock"), _test_root.path_join("unix"), 2, 5)
	return Runner.assert_eq(r, 4, "les displays :2 et :3 sont pris → premier libre :4")

func test_pick_free_display_retourne_moins_un_sans_libre():
	_fresh_dirs()
	_touch("lock/.X2-lock")
	_touch("unix/X3")
	_touch("lock/.X4-lock")
	var r = X11.pick_free_display(_test_root.path_join("lock"), _test_root.path_join("unix"), 2, 4)
	return Runner.assert_eq(r, -1, "aucun display libre dans l'intervalle → -1")

func test_pick_free_display_reel_evite_les_displays_hote():
	# Contre le vrai /tmp : le résultat doit être libre et jamais :0/:1
	# (réservés par KWin). Si tout est pris (environnement extrême), -1
	# est accepté — il est détecté et journalisé au démarrage du jeu.
	var r = X11.pick_free_display()
	if r == -1:
		return true
	var msg := "display %d sélectionné" % r
	var ok = Runner.assert_true(r >= 2, msg + " — doit être >= 2 (:0 et :1 hébergés par KWin)")
	if ok != true: return ok
	return Runner.assert_eq(
		X11.is_display_busy(r, "/tmp", "/tmp/.X11-unix"), false,
		msg + " — le display retourné doit être réellement libre")

# ── fichier runtime (cyberrealm-x11-display) ──────────────────────────

func test_runtime_file_dans_le_runtime_dir():
	var r = X11.runtime_file("/run/user/1000")
	return Runner.assert_eq(r, "/run/user/1000/cyberrealm-x11-display",
		"le fichier vit à côté de cyberrealm-session-bus")

func test_write_runtime_file_ecrit_le_display():
	_fresh_dirs()
	var rt := _test_root.path_join("rt")
	DirAccess.make_dir_recursive_absolute(rt)
	var ok = X11.write_runtime_file(rt, ":4")
	var check = Runner.assert_eq(ok, true, "écriture réussie")
	if check != true: return check
	var path := X11.runtime_file(rt)
	check = Runner.assert_true(FileAccess.file_exists(path), "fichier créé : " + path)
	if check != true: return check
	var rf := FileAccess.open(path, FileAccess.READ)
	if rf == null:
		return "fichier illisible : " + path
	var content := rf.get_as_text().strip_edges()
	rf.close()
	return Runner.assert_eq(content, ":4", "contenu = display écrit")

func test_write_runtime_file_refuse_display_vide():
	_fresh_dirs()
	var rt := _test_root.path_join("rt2")
	DirAccess.make_dir_recursive_absolute(rt)
	var r = X11.write_runtime_file(rt, "")
	return Runner.assert_eq(r, false, "display vide refusé (pas de fichier corrompu)")
