class_name UserScriptMirror
extends RefCounted
## Miroir disque des scripts utilisateur transmis en LAN.
##
## Une map/avatar custom peut porter des scripts .gd situés sous res://user/.
## Ces fichiers n'existent pas sur les machines des autres joueurs : avant
## l'envoi d'un blob baké, LevelBaker collecte leurs sources, les réécrit vers
## un chemin miroir (user://lan_mirror/<lot>/user/…) et le manifeste
## {chemin_miroir → source} voyage avec le blob. À la réception, install()
## écrit chaque fichier : tous les chemins du blob (ext_resource des scènes
## bakées, preload()/load()/extends dans les scripts) pointent alors vers de
## VRAIS fichiers locaux, résolus nativement par ResourceLoader — sans
## mécanisme custom au chargement.
##
## Chaque lot de scripts est écrit sous un préfixe UNIQUE (sel + compteur de
## lot, stables le temps d'une session) : deux installations successives ne
## partagent jamais un chemin, ce qui contourne le cache de ressources de
## Godot (qui sinon rendrait une ancienne version d'un script réinstallé).

const MIRROR_ROOT := "user://lan_mirror"
# Préfixe réécrit dans les sources collectées.
const RES_PREFIX := "res://user/"
# Garde-fou : taille cumulée maximale des sources acceptées d'un pair.
const MAX_MANIFEST_BYTES := 1048576

# Sel propre au processus : garantit que nos chemins miroirs n'entrent jamais
# en collision avec ceux d'un autre lancement du jeu (cache de ressources,
# restes de fichiers d'une session précédente).
static var _salt := ""
static var _batch_count := 0

## Ouvre un nouveau lot : préfixe de répertoire unique pour un ensemble de
## scripts bakés/transmis ensemble (niveau, ou avatar d'un joueur).
static func new_batch() -> String:
	if _salt.is_empty():
		_salt = "%d_%d" % [Time.get_unix_time_from_system(), randi() % 1000000000]
	_batch_count += 1
	return "%d_%d" % [_batch_count, randi() % 1000000000]

## Préfixe de remappage des chemins pour un lot : res://user/X → <retour>X.
static func batch_prefix(batch: String) -> String:
	if _salt.is_empty():
		new_batch()
	return "%s/%s_%s/user/" % [MIRROR_ROOT, batch, _salt]

## Chemin miroir d'un chemin res://user/ pour un lot donné.
static func mirror_path(res_path: String, batch: String) -> String:
	return batch_prefix(batch) + res_path.trim_prefix(RES_PREFIX)

## Vrai si le chemin désigne un script utilisateur transférable.
static func is_user_script_path(res_path: String) -> bool:
	return res_path.begins_with(RES_PREFIX) and res_path.ends_with(".gd")

## Réécrit les occurrences de res://user/ d'une source vers le lot.
static func rewritten_source(source: String, batch: String) -> String:
	return source.replace(RES_PREFIX, batch_prefix(batch))

## Manifeste recevable ? Clés confinées au miroir, taille cumulée bornée.
static func valid(manifest: Dictionary) -> bool:
	var total := 0
	for k in manifest:
		var p := String(k)
		if not p.begins_with(MIRROR_ROOT + "/"):
			return false
		total += String(manifest[k]).length()
	if total > MAX_MANIFEST_BYTES:
		push_warning("UserScriptMirror: manifeste trop volumineux (%d Ko) — ignoré" % (total / 1024))
		return false
	return true

## Écrit chaque entrée {chemin_miroir → source} sur le disque. Utilisé côté
## hôte (le reload des copies doit résoudre preload/extends depuis le disque)
## comme côté client (avant le chargement des blobs reçus). Retourne le nombre
## de fichiers écrits.
static func install(manifest: Dictionary) -> int:
	var count := 0
	for k in manifest:
		var p := String(k)
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			var dir_err := DirAccess.make_dir_recursive_absolute(p.get_base_dir())
			if dir_err != OK:
				push_warning("UserScriptMirror: impossible de créer %s (%s)" % [p.get_base_dir(), error_string(dir_err)])
				continue
			f = FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			push_warning("UserScriptMirror: impossible d'écrire %s" % p)
			continue
		f.store_string(String(manifest[k]))
		f.close()
		count += 1
	return count

## Purge complète du miroir (début de session LAN).
static func clear() -> void:
	if DirAccess.dir_exists_absolute(MIRROR_ROOT):
		_remove_dir_recursive(MIRROR_ROOT)

static func _remove_dir_recursive(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var p := path.path_join(f)
		if d.current_is_dir():
			_remove_dir_recursive(p)
		else:
			DirAccess.remove_absolute(p)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
