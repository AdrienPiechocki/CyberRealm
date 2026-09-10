extends Node
## Tests pour la validation de fichiers du partage LAN.

const Runner = preload("res://tests/runner.gd")
const FileShare = preload("res://scripts/network/file_share_manager.gd")

func _sample_path(filename: String) -> String:
	return OS.get_cache_dir().path_join(filename)

func test_readable_file_size():
	var path := _sample_path("cyberrealm_fs_sample.bin")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("0123456789")
	f.close()
	var r = Runner.assert_eq(FileShare.readable_file_size(path), 10, "Fichier lisible -> taille exacte")
	DirAccess.remove_absolute(path)
	return r

func test_readable_file_size_missing():
	var path := _sample_path("cyberrealm_fs_missing.bin")
	DirAccess.remove_absolute(path) # s'assurer qu'il n'existe pas
	var r = Runner.assert_eq(FileShare.readable_file_size(path), 0, "Fichier absent -> 0")
	if r != true: return r
	return true
