#!/usr/bin/env godot --headless --script
## Minimalist test runner for CyberRealm GDScript tests.
## Usage: godot --headless --script tests/runner.gd
##
## Discovers all test_*.gd files in the same directory, instantiates them,
## runs every public test_*() method, and reports PASS/FAIL with a summary.

extends SceneTree

var _total := 0
var _passed := 0
var _failed := 0
var _errors: PackedStringArray = []

func _init() -> void:
	# Les tests doivent pouvoir insérer des noeuds dans l'arbre de scène
	# (ex. tests UI) : pendant _init, ni le SceneTree ni le main loop ne sont
	# encore attachés. On attend une frame avant d'exécuter les tests.
	await process_frame
	var dir_path := ProjectSettings.globalize_path("res://tests/")
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("runner: cannot open tests/ directory: " + dir_path)
		quit(1)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			# `await` ICI aussi, et c'est le maillon manquant : un appel nu
			# à une fonction qui contient `await` la suspend et rend la main
			# immédiatement. La boucle while repartait alors à son tour, le
			# résumé s'imprimait, et le fichier courant comme tous les suivants
			# n'étaient jamais exécutés — toujours sans le moindre échec.
			await _run_test_script("res://tests/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	print("")
	print("═══════════════════════════════════════════════")
	print("  RESULTS: %d passed, %d failed, %d total" % [_passed, _failed, _total])
	print("═══════════════════════════════════════════════")
	if not _errors.is_empty():
		print("")
		for e in _errors:
			print("  FAIL: " + e)
	quit(1 if _failed > 0 else 0)

## Un script de test est utilisable s'il est non nul ET instanciable.
##
## Piège : load() ne renvoie PAS null sur un script invalide. Godot renvoie
## quand même un objet GDScript, seulement non instanciable — un `== null`
## laisse donc passer tous les fichiers cassés, qui disparaissent alors
## silencieusement de la suite (0 test, 0 échec, quit(0)).
static func is_test_script_usable(script: Script) -> bool:
	return script != null and script.can_instantiate()

func _run_test_script(resource_path: String) -> void:
	var script: Script = load(resource_path)
	# Sans ce controle, un fichier de test cassé ne comptait aucun test et
	# aucun échec : le runner affichait un résumé propre et sortait en 0, donc
	# une suite entièrement cassée passait en CI.
	if not is_test_script_usable(script):
		var short := resource_path.get_file()
		_total += 1
		_failed += 1
		var msg := "script non instanciable (erreur de compilation ?)"
		_errors.append(short + " — " + msg)
		print("  ✗ " + short + " — " + msg)
		return

	var instance = Node.new()
	instance.set_script(script)
	root.add_child(instance)

	for method in instance.get_method_list():
		var mname: String = method["name"]
		if mname.begins_with("test_") and (method["flags"] & METHOD_FLAG_CONST) == 0:
			_total += 1
			var short := resource_path.get_file() + "::" + mname
			# `await` sur l'appel, et non un appel nu : un test qui contient
			# `await` est une coroutine, et l'appeler sans `await` lève
			# « Trying to call an async function without "await" », un
			# FATAL qui interromp la boucle entière. Conséquence mesurée :
			# le fichier de test concerné et tous les suivants disparaissaient
			# de la suite, qui annonçait un résumé propre — exactement le
			# genre de disappearance que ce runner existe pour empêcher.
			# Sur une valeur ordinaire (test synchrone), `await` renvoie la
			# valeur telle quelle : les deux formes passent par le même chemin.
			var result = await instance.call(mname)
			print(result)
			if result is bool and result == true:
				_passed += 1
				print("  ✓ " + short)
			else:
				_failed += 1
				# Un test qui échoue renvoie soit false, soit le message
				# d'assertion (String). Les deux sont utiles : sans ce
				# branchement le message réel était écrasé par
				# « assertion failed », ce qui rendait tout échec inexploitable.
				var msg: String
				if result is String:
					msg = result
				elif result is bool:
					msg = "le test a renvoyé false (message non fourni)"
				else:
					msg = "retour inattendu : " + str(result)
				print("  ✗ " + short + " — " + msg)
				_errors.append(short + " — " + msg)

	instance.free()

# ── Assertion helpers ──────────────────────────────────────────────────
static func assert_true(condition: bool, msg: String = ""):
	if not condition:
		return "assert_true: " + msg if msg != "" else "assert_true failed"
	return true

static func assert_eq(a, b, msg: String = ""):
	if a != b:
		return "assert_eq: %s != %s — %s" % [str(a), str(b), msg if msg != "" else ""]
	return true

static func assert_ne(a, b, msg: String = ""):
	if a == b:
		return "assert_ne: %s == %s — %s" % [str(a), str(b), msg if msg != "" else ""]
	return true

static func assert_approx(a: float, b: float, tolerance: float = 0.01, msg: String = ""):
	if absf(a - b) > tolerance:
		return "assert_approx: |%f - %f| > %f — %s" % [a, b, tolerance, msg if msg != "" else ""]
	return true
