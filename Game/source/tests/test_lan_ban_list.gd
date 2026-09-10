extends Node
## Tests pour la liste de ban IP persistée du lan_manager.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func _ban_path() -> String:
	return OS.get_cache_dir().path_join("cyberrealm_ban_test.json")

func test_is_ip_banned():
	var list := ["192.168.1.23", "10.0.0.7"]
	var r = Runner.assert_eq(LANManager.is_ip_banned("192.168.1.23", list), true, "IP presente -> bannie")
	if r != true: return r
	r = Runner.assert_eq(LANManager.is_ip_banned("192.168.1.99", list), false, "IP absente -> libre")
	if r != true: return r
	r = Runner.assert_eq(LANManager.is_ip_banned("", list), false, "IP vide -> jamais bannie")
	if r != true: return r
	return true

func test_ban_list_roundtrip():
	var path := _ban_path()
	var r = Runner.assert_eq(LANManager.load_ban_list_from(path), [], "Fichier absent -> liste vide")
	if r != true: return r
	var list := ["192.168.1.23", "10.0.0.7"]
	LANManager.save_ban_list_to(path, list)
	var loaded := LANManager.load_ban_list_from(path)
	r = Runner.assert_eq(loaded.size(), 2, "Round-trip : 2 entrees conservees")
	if r != true: return r
	r = Runner.assert_eq(String(loaded[0]), "192.168.1.23", "IP 0 conservee")
	if r != true: return r
	DirAccess.remove_absolute(path)
	return true

func test_ban_list_corrupt():
	var path := _ban_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var loaded := LANManager.load_ban_list_from(path)
	var r = Runner.assert_eq(loaded, [], "Fichier corrompu -> liste vide")
	if r != true: return r
	DirAccess.remove_absolute(path)
	return true
