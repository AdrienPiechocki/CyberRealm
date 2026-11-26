extends Node
## Audio des fenêtres partagées : un flux OPUS par fenêtre, joué chez les autres joueurs depuis son quad.
##
## Module de LanManager (nœud enfant « AudioShare »). La capture et l'encodage sont faits par
## scripts/main/window_audio.gd (qui gère aussi le son spatialisé local) ; ce module ne fait que transporter les
## paquets ([seq u32][OPUS 20 ms], non fiables, canal 3) et les décoder par émetteur et par fenêtre. Coupé en
## session en ligne (comme le partage des fenêtres).

signal window_audio_received(from_id: int, wid: int, frames: PackedVector2Array)

const MAX_PACKET := 1500

var lan = null                   # LanManager (non typé : doublure possible dans les tests)

# Diagnostic (journal de déconnexion de session.gd).
var _audio_active := false
var _audio_send_count := 0
var _audio_received_count := 0

## Envoie les paquets d'une fenêtre partagée locale à tous les autres joueurs.
func send_window_audio(wid: int, packets: Array) -> void:
	if packets.is_empty() or not lan.is_session_active() or lan.online_restricted():
		return
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return
	_audio_active = true
	var me := multiplayer.get_unique_id()
	for pkt in packets:
		_audio_send_count += 1
		for peer in multiplayer.get_peers():
			if peer != me:
				_sync_window_audio.rpc_id(peer, wid, pkt)

@rpc("any_peer", "call_remote", "unreliable", 3)
func _sync_window_audio(wid: Variant, bytes: Variant) -> void:
	if lan.online_restricted() or not wid is int or not bytes is PackedByteArray:
		return
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or (bytes as PackedByteArray).size() > MAX_PACKET:
		return
	if lan.compositor == null:
		return
	var frames: PackedVector2Array = lan.compositor.audio_decode_window("%d:%d" % [from, wid], bytes)
	if frames.is_empty():
		return
	_audio_received_count += 1
	window_audio_received.emit(from, wid, frames)

func _stop_audio_share() -> void:
	_audio_active = false
	_audio_send_count = 0
	_audio_received_count = 0
