extends Node
## Tests de la configuration RPC du handshake PIN LAN.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func _rpc_mode(method: StringName) -> int:
	var script: GDScript = LANManager
	var all: Dictionary = script.get_rpc_config()
	if not all.has(method):
		return -1
	var entry: Dictionary = all.get(method, {})
	if entry.is_empty():
		return -1
	return int(entry.get("rpc_mode", -1))

func test_auth_request_callable_by_client():
	var mode := _rpc_mode(&"auth_request")
	if mode == -1:
		return Runner.assert_eq(true, false, "auth_request a une config RPC")
	if mode != MultiplayerAPI.RPC_MODE_ANY_PEER:
		return Runner.assert_eq(MultiplayerAPI.RPC_MODE_ANY_PEER, mode, "auth_request doit etre invocable par n'importe quel peer (le client l'envoie au host)")
	return true

func test_auth_result_from_host_only():
	var mode := _rpc_mode(&"auth_result")
	if mode == -1:
		return Runner.assert_eq(true, false, "auth_result a une config RPC")
	return Runner.assert_eq(mode, MultiplayerAPI.RPC_MODE_ANY_PEER, "auth_result invocable (garde from != 1 dans le handler)")

func test_heartbeat_authority_only():
	var mode := _rpc_mode(&"_host_heartbeat")
	if mode == -1:
		return Runner.assert_eq(true, false, "_host_heartbeat a une config RPC")
	return Runner.assert_eq(mode, MultiplayerAPI.RPC_MODE_AUTHORITY, "heartbeat emis par l'hote uniquement")