extends Node
## Tests du runner lui-même (tests/runner.gd).
##
## Régression : un fichier de test qui ne compile pas DISPARAISSAIT de la
## suite. Le runner testait `load(...) == null`, or load() ne renvoie jamais
## null sur un script invalide — Godot renvoie un GDScript non instanciable. Le
## fichier était donc ignoré en silence : 0 test compté, 0 échec, quit(0). Une
## suite entièrement cassée passait en CI, et il fallait compter les tests à la
## main pour s'en apercevoir (c'est arrivé deux fois : 139 tests devenus 92 sans
## le moindre échec signalé).
##
## Le test vérifie la FONCTION de décision, pas le runner entier : celle-ci est
## le seul endroit où la distinction se joue, et elle est vérifiable sans
## lancer une sous-suite.

const Runner = preload("res://tests/runner.gd")

## Source INVALIDE construite à l'exécution : un vrai fichier invalide dans le
## projet gênerait l'éditeur et l'export (la fixture compile_error.gd avait dû
## être commentée, ce qui rendait ces tests faux).
const BROKEN_SOURCE := "extends Node\nfunc test_ce_fichier_ne_compile_pas() -> Variant:\n\treturn cette_fonction_nexiste_pas()\n"
const VALID := "res://tests/fixtures/valid_script.gd"

## Compile BROKEN_SOURCE : reload() échoue, mais renvoie bien un GDScript non nul.
func _load_broken() -> GDScript:
	var script := GDScript.new()
	script.source_code = BROKEN_SOURCE
	script.reload() # erreur de compilation attendue (affichée dans la console)
	return script

func test_broken_script_is_detected_as_unusable() -> Variant:
	## Le cœur de la régression : un script qui ne compile pas doit être
	## rejeté. Sans ce test, revenir à un test `== null` ne casserait rien.
	var res: Variant = Runner.assert_true(not Runner.is_test_script_usable(_load_broken()),
		"un fichier de test qui ne compile pas doit être détecté comme inutilisable")
	return res

func test_broken_script_loads_to_a_non_null_resource() -> Variant:
	## Le PIÈGE exact, épinglé pour qu'on ne le « corrige » pas : load()
	## renvoie un objet non nul. C'est ce non-null trompeur qui rendait le
	## test `== null` inopérant, et un futur refactor pourrait s'y fier à
	## nouveau en « le simplifiant ».
	var script: Script = _load_broken()
	var res: Variant = Runner.assert_true(script != null,
		"un script invalide reste un objet non nul (comme le load() du runner)")
	if _fail(res): return res
	return Runner.assert_true(not script.can_instantiate(),
		"…mais il n'est pas instanciable : c'est le seul signal exploitable")

func test_valid_script_is_accepted() -> Variant:
	## Contrôle négatif : si la fixture « cassée » et la fixture « valide » se
	## comportaient pareil, le test de détection ne prouverait rien.
	var res: Variant = Runner.assert_true(Runner.is_test_script_usable(load(VALID)),
		"un fichier de test valide doit être accepté")
	return res

func test_null_script_is_not_usable() -> Variant:
	## Un fichier absent : load() renvoie null là, et null n'est pas utilisable.
	var res: Variant = Runner.assert_true(
		not Runner.is_test_script_usable(load("res://tests/fixtures/does_not_exist.gd")),
		"un fichier absent ne doit pas être considéré comme utilisable")
	return res

func _fail(res: Variant) -> bool:
	return res is String and res != ""
