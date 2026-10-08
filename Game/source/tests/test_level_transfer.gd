extends Node
## Transfert de niveau LAN : sémantique des buffers (T0), machine à état de
## réception (T1), file de chunks d'envoi (T2), cache bake+compress (T3).
##
## T0 documente la sémantique RÉELLE de PackedByteArray sur Godot 4.7.2 :
## - `var b: PackedByteArray = d["key"]` PARTAGE le buffer (append en place,
##   O(chunk) → assemblage dict+local O(n), pas O(n²) — H1 rétracté par T0).
## - `(d["key"] as PackedByteArray)` DÉTACHE (copie) : l'append ne remonte
##   pas dans le dict. C'est ce chemin-cast que décrit le commentaire de
##   _receive_level_baked — jamais utiliser le cast sur le buffer accumulé.
## Budget ci-dessous : linéarité à 36 Mo (< 1 s ; un O(n²) coûterait ~3 s+).

const Runner := preload("res://tests/runner.gd")
const LANManager := preload("res://scripts/network/lan_manager.gd")

const CHUNK := 24000        # LEVEL_CHUNK_SIZE réel
const COUNT := 1500         # 36 Mo : sépare nettement O(n) (~30 ms) d'O(n²) (~3 s)

## Un seul modèle construit par octets, puis dupliqué (memcpy C++) : aucun test
## n'exige des chunks distincts, et la boucle par octet × 5813 chunks serait
## bien trop lente dans GDScript.
static func _chunks(count: int, size: int) -> Array[PackedByteArray]:
	var template := PackedByteArray()
	template.resize(size)
	for j in size:
		template[j] = j % 251
	var out: Array[PackedByteArray] = []
	out.resize(count)
	for i in count:
		out[i] = template.duplicate()
	return out

func test_dict_pattern_is_linear() -> Variant:
	# Pattern de _receive_level_baked (variable locale, PAS le cast) : doit
	# rester O(n) — budget ×30 sur le mesuré (29 ms à 36 Mo).
	var src := _chunks(COUNT, CHUNK)
	var d: Dictionary = {"data": PackedByteArray()}
	var t0 := Time.get_ticks_msec()
	for c in src:
		var data: PackedByteArray = d["data"]
		data.append_array(c)
		d["data"] = data
	var dict_ms := Time.get_ticks_msec() - t0
	var r: Variant = Runner.assert_true(dict_ms < 1000,
		"assemblage dict+local doit rester O(n) à 36 Mo: %d ms" % dict_ms)
	if r is String:
		return r
	var total: PackedByteArray = d["data"]
	return Runner.assert_eq(total.size(), COUNT * CHUNK, "taille assemblée")

func test_dict_pattern_loses_no_bytes() -> Variant:
	# Le pattern historique est correct (c'était la vitesse présumée, pas le
	# contenu, qui motivait T1) : bytes identiques à la concaténation directe.
	var d: Dictionary = {"data": PackedByteArray()}
	var src := _chunks(64, 1024)
	for c in src:
		var data: PackedByteArray = d["data"]
		data.append_array(c)
		d["data"] = data
	var joined := _concat(src)
	return Runner.assert_eq(d["data"], joined, "les deux patterns produisent les mêmes octets")

func test_as_cast_detaches_from_dictionary() -> Variant:
	# Le piège que T1 doit éviter : le cast copie, l'append ne remonte pas.
	var d: Dictionary = {"data": PackedByteArray([1, 2, 3])}
	(d["data"] as PackedByteArray).append(9)
	var r: Variant = Runner.assert_eq(d["data"], PackedByteArray([1, 2, 3]),
		"le cast as PackedByteArray détache : le dict ne voit pas l'append")
	if r is String:
		return r
	var shared: PackedByteArray = d["data"]
	shared.append(4)
	return Runner.assert_eq(d["data"], PackedByteArray([1, 2, 3, 4]),
		"la variable typée partage : le dict voit l'append en place")

func test_bake_recv_assembles_in_order_and_completes() -> Variant:
	var src := _chunks(500, CHUNK)
	var state: Dictionary = {}
	LANManager.bake_recv_init(state, 500, 500 * CHUNK, Vector3(1, 2, 3), Vector3.ZERO, Vector3.ONE)
	for i in 499:
		var r: Variant = Runner.assert_eq(LANManager.bake_recv_append(state, i, src[i]), "more",
			"chunk %d intermédiaire" % i)
		if r is String:
			return r
	var r: Variant = Runner.assert_eq(LANManager.bake_recv_append(state, 499, src[499]), "complete",
		"dernier chunk = complete")
	if r is String:
		return r
	return Runner.assert_eq(LANManager.bake_recv_payload(state), _concat(src),
		"octets identiques à la source")

func test_bake_recv_rejects_out_of_order_and_duplicates() -> Variant:
	var state: Dictionary = {}
	var c := PackedByteArray([1, 2, 3])
	LANManager.bake_recv_init(state, 10, 999, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	var r: Variant = Runner.assert_eq(LANManager.bake_recv_append(state, 2, c), "reject", "index > next rejeté")
	if r is String:
		return r
	r = Runner.assert_eq(LANManager.bake_recv_append(state, 0, c), "more", "premier chunk accepté")
	if r is String:
		return r
	r = Runner.assert_eq(LANManager.bake_recv_append(state, 0, c), "reject", "doublon rejeté")
	if r is String:
		return r
	return Runner.assert_eq(LANManager.bake_recv_append(state, 5, PackedByteArray()), "reject",
		"chunk vide rejeté")

func test_bake_recv_restarts_on_new_total() -> Variant:
	# Un nouveau transfert (autre session, autre blob) repart de zéro, comme le
	# faisait déjà le test d'`total` dans _receive_level_baked.
	var state: Dictionary = {}
	LANManager.bake_recv_init(state, 10, 100, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	LANManager.bake_recv_append(state, 0, PackedByteArray([9]))
	LANManager.bake_recv_init(state, 12, 120, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	var r: Variant = Runner.assert_eq(int(state["next"]), 0, "reset complet du compteur")
	if r is String:
		return r
	return Runner.assert_eq(int((state["buf"] as PackedByteArray).size()), 0, "reset complet du buffer")

func test_bake_recv_needs_init_on_empty_or_new_total() -> Variant:
	# Garde de (ré)initialisation (revue finale, Issue 1) : un état vide (pas
	# de "total") ou un total différent = nouveau transfert → il faut init,
	# exactement comme avant (le helper ne fait que regrouper ces deux cas).
	var r: Variant = Runner.assert_true(LANManager.bake_recv_needs_init({}, 10, 0),
		"état vide (aucune clé total) → init")
	if r is String:
		return r
	var state: Dictionary = {}
	LANManager.bake_recv_init(state, 10, 100, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	return Runner.assert_true(LANManager.bake_recv_needs_init(state, 12, 3),
		"total différent = autre blob → init")

func test_bake_recv_needs_init_detects_restart_on_ordered_channel() -> Variant:
	# Même total mais index 0 alors que next > 0 : sur le canal fiable ENet
	# (ordonné), un index 0 en pleine réception ne peut être qu'un
	# redémarrage du transfert (double _register_player de l'hôte) — sans
	# ré-init, les chunks 0..next-1 de la nouvelle série seraient rejetés
	# puis le chunk 0 APPENDÉ au vieux buffer partiel : corruption silencieuse
	# si le contenu diffère jamais.
	var state: Dictionary = {}
	LANManager.bake_recv_init(state, 10, 100, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	LANManager.bake_recv_append(state, 0, PackedByteArray([1]))
	LANManager.bake_recv_append(state, 1, PackedByteArray([2]))
	var r: Variant = Runner.assert_true(LANManager.bake_recv_needs_init(state, 10, 0),
		"index 0 alors que next > 0, même total = redémarrage → init")
	if r is String:
		return r
	# Poursuite normale en cours de flux (index == next, même total) : pas d'init.
	return Runner.assert_true(not LANManager.bake_recv_needs_init(state, 10, 2),
		"index == next en cours de transfert = suite de la série → pas d'init")

func test_bake_recv_append_is_linear() -> Variant:
	# Budget du T0 : 5813 chunks × 24 Ko = ~136 Mo assemblés par append en
	# place, O(chunk) chacun → O(n) total, zéro concaténation finale.
	var src := _chunks(5813, CHUNK)
	var state: Dictionary = {}
	LANManager.bake_recv_init(state, 5813, 5813 * CHUNK, Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	var t0 := Time.get_ticks_msec()
	for c in src:
		LANManager.bake_recv_append(state, int(state["next"]), c)
	var ms := Time.get_ticks_msec() - t0
	var r: Variant = Runner.assert_eq(int(state["bytes"]), 5813 * CHUNK, "taille totale")
	if r is String:
		return r
	return Runner.assert_true(ms < 3000, "assemblage linéaire par append: %d ms" % ms)

func test_build_level_chunks_covers_blob_exactly() -> Variant:
	var blob := PackedByteArray()
	blob.resize(CHUNK * 3 + 111)
	var chunks := LANManager.build_level_chunks(blob, CHUNK)
	var r: Variant = Runner.assert_eq(chunks.size(), 4, "3 chunks pleins + 1 partiel")
	if r is String:
		return r
	r = Runner.assert_eq(chunks[0].size(), CHUNK, "chunk plein")
	if r is String:
		return r
	r = Runner.assert_eq(chunks[3].size(), 111, "dernier chunk tronqué")
	if r is String:
		return r
	return Runner.assert_eq(chunks[0], blob.slice(0, CHUNK), "contenu = découpe du blob")

func test_build_level_chunks_is_linear() -> Variant:
	# 136 Mo découpés une seule fois (pas à chaque tick d'envoi).
	var blob := PackedByteArray()
	blob.resize(CHUNK * 5813)
	var t0 := Time.get_ticks_msec()
	var chunks := LANManager.build_level_chunks(blob, CHUNK)
	var ms := Time.get_ticks_msec() - t0
	var r: Variant = Runner.assert_eq(chunks.size(), 5813, "5813 chunks")
	if r is String:
		return r
	return Runner.assert_true(ms < 3000, "découpe unique O(n): %d ms" % ms)

func test_build_level_chunks_empty_blob() -> Variant:
	return Runner.assert_eq(LANManager.build_level_chunks(PackedByteArray(), CHUNK).size(), 0,
		"blob vide = aucun chunk")

# ── T3 : cache bake+compress préparé au démarrage de l'hébergement ────

var _provider_calls := 0

func _fake_bake() -> Dictionary:
	_provider_calls += 1
	var b := PackedByteArray()
	b.resize(CHUNK * 10)
	# Valeurs pseudo-aléatoires DÉTERMINISTES (hash) : quasi-incompressibles,
	# pour que l'envoi multi-chunks soit réellement exercé. Pas de rand*() :
	# les tests doivent être reproductibles d'un run à l'autre.
	for i in b.size():
		b[i] = hash(i) % 256
	return {"bytes": b, "scripts": {}, "spawn": Vector3.ZERO,
		"spawn_rotation": Vector3.ZERO, "spawn_scale": Vector3.ONE}

func test_prepare_level_send_cache_compresses_once() -> Variant:
	var inst = LANManager.new()
	inst.level_bake_provider = Callable(self, "_fake_bake")
	_provider_calls = 0
	var r: Variant = Runner.assert_true(inst._prepare_level_send_cache(), "préparation OK")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(not inst._level_compressed_cache.is_empty(), "cache compressé peuplé")
	if r is String:
		inst.free()
		return r
	var first: PackedByteArray = inst._level_compressed_cache.duplicate()
	r = Runner.assert_true(inst._prepare_level_send_cache(), "second appel OK (déjà prêt)")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_eq(_provider_calls, 1, "le bake ne tourne qu'une fois")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_eq(inst._level_compressed_cache, first, "pas de recompress")
	inst.free()
	return r

func test_send_level_to_never_bakes_inline() -> Variant:
	# C'est LA régression du gel : _send_level_to (appelé depuis le handler
	# RPC _register_player) ne doit JAMAIS appeler le provider ni compresser.
	var inst = LANManager.new()
	inst.level_bake_provider = Callable(self, "_fake_bake")
	_provider_calls = 0
	var r: Variant = Runner.assert_true(inst._prepare_level_send_cache(), "cache préparé")
	if r is String:
		inst.free()
		return r
	inst._send_level_to(2)   # manifeste vide = aucun RPC → testable sans pair
	r = Runner.assert_eq(_provider_calls, 1, "toujours 1 seule passe de bake")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(inst._level_send_queue.has(2), "file d'envoi peuplée pour le peer 2")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(not inst._level_compressed_cache.is_empty(),
		"un prepare réussi ne peut pas laisser le cache compressé vide")
	if r is String:
		inst.free()
		return r
	var entry: Dictionary = inst._level_send_queue[2]
	var chunks: Array[PackedByteArray] = entry["chunks"]
	var expected := ceili(float(inst._level_compressed_cache.size()) / float(CHUNK))
	r = Runner.assert_eq(chunks.size(), expected, "chunks pré-découpés depuis le cache")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_eq(int(entry["total"]), chunks.size(), "total de la file == chunks")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(chunks.size() > 1,
		"blob quasi-incompressible → envoi multi-chunks réellement exercé")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_eq(_concat(chunks), inst._level_compressed_cache,
		"les chunks couvrent le cache compressé octet à octet")
	inst.free()
	return r

func test_invalidate_clears_both_caches() -> Variant:
	var inst = LANManager.new()
	inst.level_bake_provider = Callable(self, "_fake_bake")
	inst._prepare_level_send_cache()
	inst._invalidate_level_send_cache()
	var r: Variant = Runner.assert_true(inst._level_baked_cache.is_empty(), "bake vidé")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(inst._level_compressed_cache.is_empty(), "compressé vidé")
	inst.free()
	return r

func test_disconnect_clears_deferred_level_send() -> Variant:
	# État de session : le différé stagé par un miss ne peut pas survivre au
	# disconnect — sinon la reprise en tête de _drain_level_send ré-enverrait
	# des ids morts ou recyclés au prochain hébergement.
	var inst = LANManager.new()
	# _disconnect_session suppose un noeud dans l'arbre (multiplayer non nul) :
	# hors arbre, l'accès multiplayer.multiplayer_peer lèverait une erreur et
	# couperait la fonction en plein milieu. Aucune frame ne passe pendant ce
	# test synchrone → _physics_process de l'instance ne tourne pas.
	add_child(inst)
	var r: Variant = Runner.assert_true(not inst._level_send_cache_ready(),
		"cache froid : le miss de _send_level_to stage le différé")
	if r is String:
		inst.free()
		return r
	inst._send_level_to(2)   # miss → id + drapeau, AUCUN RPC (return avant le manifeste)
	r = Runner.assert_true(inst._defer_level_send.has(2), "peer 2 différé stagé par le miss")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(inst._level_send_deferred, "drapeau différé levé par le miss")
	if r is String:
		inst.free()
		return r
	inst._disconnect_session()
	r = Runner.assert_true(inst._defer_level_send.is_empty(),
		"les pairs en attente du niveau ne survivent pas au disconnect")
	if r is String:
		inst.free()
		return r
	r = Runner.assert_true(not inst._level_send_deferred,
		"drapeau différé reposé au disconnect")
	inst.free()
	return r

func _concat(chunks: Array[PackedByteArray]) -> PackedByteArray:
	var out := PackedByteArray()
	for c in chunks:
		out.append_array(c)
	return out
