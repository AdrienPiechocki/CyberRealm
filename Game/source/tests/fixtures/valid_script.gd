extends Node
## Fixture volontairement VALIDE : contrôle négatif de tests/fixtures/
## compile_error.gd (si les deux se comportaient pareil, le test ne prouverait
## rien).
func test_placeholder() -> Variant:
	return true
