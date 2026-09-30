extends Node
## Fixture VOLONTAIREMENT invalide : ne corrigez pas cette erreur.
## Elle sert à tester que le runner détecte un fichier de test qui ne compile
## pas. Voir tests/test_runner.gd.
func test_ce_fichier_ne_compile_pas() -> Variant:
	return cette_fonction_nexiste_pas()
