extends Node
## Le signal `players_changed(roster: Array)` de lan_manager émet UN argument.
## players_menu.gd s'y connecte via _refresh_tabs : si la méthode n'accepte pas
## cet argument, chaque _emit_players() déclenche « Method expected 0
## argument(s), but called with 1 » sur toutes les machines de la session.

const Runner = preload("res://tests/runner.gd")
const PlayersMenu = preload("res://scripts/ui/players_menu.gd")

func test_refresh_tabs_accepts_roster_argument():
	var inst: Node = PlayersMenu.new()
	var found := false
	var arity := 0
	for m in inst.get_method_list():
		if String(m.get("name", "")) == "_refresh_tabs":
			found = true
			arity = (m.get("args", []) as Array).size()
	inst.free()
	var r = Runner.assert_true(found, "_refresh_tabs() doit exister")
	if r != true: return r
	return Runner.assert_true(
		arity >= 1,
		"_refresh_tabs doit accepter l'argument roster du signal players_changed (arity=%d)" % arity)