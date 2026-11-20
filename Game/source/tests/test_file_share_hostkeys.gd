extends Node
## Épinglage des clés d'hôte sshd pour le partage de fichiers : filtre des clés
## reçues du réseau, known_hosts généré, options ssh de l'expéditeur.

const Runner := preload("res://tests/runner.gd")
const FileShare := preload("res://scripts/network/file_share_manager.gd")

# Corps ed25519 réel (32 octets de clé) : base64 valide, décodable.
const KEY_BODY := "AAAAC3NzaC1lZDI1NTE5AAAAIGfhmCXFK5rY0SL4quaGivQrg3LqCAnpTeumCLGCj7Bs"
const KEY := "ssh-ed25519 " + KEY_BODY

func _fail(r: Variant) -> bool:
	return r is String and r != ""

func test_sanitize_keeps_valid_key_and_drops_comment() -> Variant:
	var out := FileShare.sanitize_host_keys(PackedStringArray([KEY + " root@machine"]))
	return Runner.assert_eq(out, PackedStringArray([KEY]), "commentaire retiré, clé gardée")

func test_sanitize_rejects_injection_and_garbage() -> Variant:
	var bad := PackedStringArray([
		"@cert-authority * " + KEY,          # marqueur known_hosts
		"ssh-dss " + KEY_BODY,               # type refusé
		"ssh-ed25519 pas du base64 !",       # corps invalide
		"ssh-ed25519 " + KEY_BODY + "\n127.0.0.1 ssh-ed25519 " + KEY_BODY,  # saut de ligne
		"ssh-ed25519",                       # corps manquant
		"",
	])
	var out := FileShare.sanitize_host_keys(bad)
	# Seule la ligne au saut de ligne est « récupérable » : son premier champ est
	# valide, le reste est jeté — jamais de seconde ligne known_hosts.
	for k in out:
		if k.contains("\n") or k.begins_with("@") or k.count(" ") != 1:
			return "ligne dangereuse conservée : " + k
	return Runner.assert_true(not out.has("ssh-dss " + KEY_BODY), "type refusé conservé")

func test_sanitize_limits_count_and_dedups() -> Variant:
	var many := PackedStringArray()
	for i in 10:
		many.append(KEY)
	var out := FileShare.sanitize_host_keys(many)
	return Runner.assert_eq(out.size(), 1, "doublons fusionnés")

func test_known_hosts_content_pins_ip_only() -> Variant:
	var content := FileShare.known_hosts_content("192.168.1.20", PackedStringArray([KEY]))
	var r = Runner.assert_eq(content, "192.168.1.20 " + KEY + "\n", "ligne known_hosts")
	if _fail(r):
		return r
	# Pas d'IP littérale (nom, joker, motif) : rien n'est généré.
	for host in ["*", "example.com", "10.0.0.1,evil", "", "10.0.0.*"]:
		if FileShare.known_hosts_content(host, PackedStringArray([KEY])) != "":
			return "known_hosts généré pour un hôte non littéral : " + host
	return true

func test_known_hosts_content_is_accepted_by_ssh_keygen() -> Variant:
	if OS.execute("sh", ["-c", "command -v ssh-keygen"]) != 0:
		return true # outil absent : rien à comparer
	var path := "user://kh_test_hostkeys"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(FileShare.known_hosts_content("192.168.1.20", PackedStringArray([KEY])))
	f.close()
	var out := []
	var code := OS.execute("ssh-keygen", ["-F", "192.168.1.20", "-f",
		ProjectSettings.globalize_path(path)], out)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return Runner.assert_eq(code, 0, "ssh-keygen retrouve l'hôte épinglé")

func test_strict_policy_in_rsync_argv() -> Variant:
	var strict := FileShare.build_rsync_argv(PackedStringArray(["/tmp/a"]), "u", "/k", "10.0.0.2",
		"/d", "/p", "/e", "/kh", true)
	var tofu := FileShare.build_rsync_argv(PackedStringArray(["/tmp/a"]), "u", "/k", "10.0.0.2",
		"/d", "/p", "/e", "/kh")
	var s_opts := "\n".join(strict)
	var t_opts := "\n".join(tofu)
	if not s_opts.contains("StrictHostKeyChecking=yes") or s_opts.contains("accept-new"):
		return "épinglage : StrictHostKeyChecking=yes attendu"
	if not t_opts.contains("StrictHostKeyChecking=accept-new"):
		return "repli TOFU : accept-new attendu par défaut"
	return Runner.assert_true(s_opts.contains("GlobalKnownHostsFile=/dev/null"),
		"aucun known_hosts système ne doit s'ajouter à l'épinglage")

func test_local_host_public_keys_reads_clean_lines() -> Variant:
	var path := "user://host_key_test.pub"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(KEY + " root@box\n")
	f.close()
	var out := FileShare.local_host_public_keys([path, "user://absent.pub"])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return Runner.assert_eq(out, PackedStringArray([KEY]), "clé lue, commentaire retiré, absent ignoré")
