extends Node
## Watchdog heartbeat côté client : pendant un join (transfert niveau + avatar)
## le thread principal peut rester occupé plusieurs secondes. Un watchdog naïf
## voit alors des heartbeats « expirés » et déclenche un reconnect qui arrache
## la session juste après finalize_join → boucle de rejoin (constaté en réel).
## Ces helpers purs encodent la règle : ne JAMAIS armer le reconnect pendant le
## join ; ANNULER un reconnect programmé si le heartbeat est revenu entretemps.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")

func test_arm_forbidden_while_joining():
	var r = Runner.assert_eq(
		LANManager.heartbeat_reconnect_should_arm(false, 0, 10000, 4000),
		false,
		"even with stale heartbeats, don't arm reconnect while joining")
	if r != true: return r
	r = Runner.assert_eq(
		LANManager.heartbeat_reconnect_should_arm(false, 0, 40000, 4000),
		false,
		"long stale join window never arms the watchdog")
	return r

func test_arm_after_joined_and_stale():
	var r = Runner.assert_eq(
		LANManager.heartbeat_reconnect_should_arm(true, 0, 10000, 4000),
		true,
		"joined + heartbeats stale for > timeout → arm the watchdog")
	if r != true: return r
	return true

func test_no_arm_after_joined_but_fresh():
	var r = Runner.assert_eq(
		LANManager.heartbeat_reconnect_should_arm(true, 6000, 9000, 4000),
		false,
		"joined + last heartbeat within timeout → no watchdog")
	if r != true: return r
	return true

func test_stale_boundary():
	var r = Runner.assert_eq(
		LANManager.heartbeat_is_stale(5000, 9000, 4000),
		false,
		"exactly at timeout is not stale")
	if r != true: return r
	r = Runner.assert_eq(
		LANManager.heartbeat_is_stale(4999, 9000, 4000),
		true,
		"past timeout is stale")
	return r

func test_cancel_when_heartbeat_resumed():
	# Un reconnect a été programmé ; un heartbeat est arrivé pendant l'attente
	# du backoff (réseau vivant) → annuler, ne pas arracher la session.
	var r = Runner.assert_eq(
		LANManager.heartbeat_cancel_reconnect(true, 8000, 9000, 4000),
		true,
		"joined + heartbeat fresh → cancel the pending reconnect")
	if r != true: return r
	r = Runner.assert_eq(
		LANManager.heartbeat_cancel_reconnect(true, 1000, 9000, 4000),
		false,
		"joined + still stale → keep the reconnect")
	if r != true: return r
	return true

func test_no_cancel_while_joining():
	var r = Runner.assert_eq(
		LANManager.heartbeat_cancel_reconnect(false, 8000, 9000, 4000),
		false,
		"while joining (physical drop), queued heartbeat must not cancel the reconnect")
	return r