extends "res://tests/test_case.gd"
## W2 commit 3: NetDebugPing, the LAN smoke's round-trip and snapshot counters. Present on every session under the same
## name (RPC paths match in every build), inactive outside a debug web build (simulate_active overrides the gate here),
## median / max maths, snapshot counting from the bridge's snapshot_received, markers only while active, and a real
## ping / pong round trip between two isolated ENet sessions on loopback. NetDebugPing.simulate_active is a global:
## every test restores it.

const _Fakes := preload("res://tests/w2_fakes.gd")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > int(timeout_s * 1000.0):
			return false
		await _tree().process_frame
	return true


func _session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_tree().root.add_child(s)
	return s


func _end(sessions: Array) -> void:
	for s: NetSession in sessions:
		s.leave()
		s.queue_free()
	await _tree().process_frame


func test_present_on_every_session_and_inactive_by_default() -> void:
	NetDebugPing.simulate_active = null
	var s := _session("W2PingDefault")
	await _frames(1)
	var p := s.get_node_or_null(NetDebugPing.NODE_NAME) as NetDebugPing
	assert_true(p != null and p == s.debug_ping, "child named %s" % NetDebugPing.NODE_NAME)
	assert_true(not NetDebugPing.gate(), "headless debug run: not a web build")
	assert_true(not p.active and not p.is_processing(), "inactive")
	assert_true(not p.send_ping(), "an inactive node never pings")
	var lines: Array = []
	p.marker_sink = func(l: String) -> void: lines.append(l)
	p.report()
	s.host_lost.emit()
	assert_true(lines.is_empty(), "inactive: no markers")
	# Solo and ENet sessions have it too (same path on every peer in every build).
	var t := _session("W2PingOther")
	t.start_offline()
	assert_true(t.get_node_or_null(NetDebugPing.NODE_NAME) != null, "solo session has it")
	await _end([s, t])


func test_median_and_max() -> void:
	var empty: Array[float] = []
	assert_eq(NetDebugPing.median(empty), 0.0, "empty median")
	assert_eq(NetDebugPing.max_of(empty), 0.0, "empty max")
	var odd: Array[float] = [5.0, 1.0, 3.0]
	assert_eq(NetDebugPing.median(odd), 3.0, "odd count")
	var even: Array[float] = [4.0, 1.0, 3.0, 10.0]
	assert_eq(NetDebugPing.median(even), 3.5, "even count: mean of the middle two")
	assert_eq(NetDebugPing.max_of(even), 10.0, "max")
	assert_eq(NetDebugPing.min_of(even), 1.0, "min")
	assert_eq(NetDebugPing.min_of(empty), 0.0, "empty min")
	assert_eq(even, [4.0, 1.0, 3.0, 10.0] as Array[float], "the input is not reordered")


func test_samples_are_bounded() -> void:
	var p := NetDebugPing.new()
	for i in NetDebugPing.MAX_SAMPLES + 5:
		p.add_sample(float(i))
	assert_eq(p.samples.size(), NetDebugPing.MAX_SAMPLES, "bounded")
	assert_eq(p.samples[0], 5.0, "oldest dropped")
	p.free()


func test_counts_snapshots_and_prints_markers_when_active() -> void:
	NetDebugPing.simulate_active = true
	var s := _session("W2PingActive")
	NetDebugPing.simulate_active = null
	var p := s.debug_ping
	var lines: Array = []
	p.marker_sink = func(l: String) -> void: lines.append(l)
	p.set_process(false)  # this test drives report() itself
	await _frames(1)
	assert_true(p.active, "simulated debug web build")
	for i in 3:
		s.bridge.snapshot_received.emit()
	assert_eq(p.snapshots, 3, "counted from the bridge")
	p.report()
	assert_eq(lines, ["GLADIUS_LAN_SNAPSHOTS 3"], "no ping line without samples")
	lines.clear()
	for v: float in [2.0, 8.0, 4.0]:
		p.add_sample(v)
	p.report()
	assert_eq(lines, ["GLADIUS_LAN_SNAPSHOTS 3", "GLADIUS_LAN_PING median_ms=4.0 max_ms=8.0 n=3 min_ms=2.0"], "ping summary")
	lines.clear()
	s.last_error = "relay_lost"
	s.host_lost.emit()
	s.connected.emit()  # (peer_joined / peer_left are not emitted by hand: the lobby would answer them with RPCs)
	s.last_error = "no_host"
	s.failed.emit()
	s.host_ready.emit(PackedStringArray(["https://10.0.0.2:47443/"]))
	assert_eq(lines, ["GLADIUS_LAN_HOST_LOST relay_lost", "GLADIUS_LAN_CONNECTED", "GLADIUS_LAN_ERROR no_host", "GLADIUS_LAN_HOST_READY https://10.0.0.2:47443/"],
			"session markers")
	await _end([s])


func test_ping_round_trip_over_loopback() -> void:
	NetDebugPing.simulate_active = true
	var host := _session("W2PingHost")
	var guest := _session("W2PingGuest")
	NetDebugPing.simulate_active = null
	for s: NetSession in [host, guest]:
		s.debug_ping.set_process(false)
		s.debug_ping.marker_sink = func(_l: String) -> void: pass  # quiet suite log
	var port := 20000 + randi() % 20000
	assert_eq(host.host_game(port), OK, "host up")
	assert_eq(guest.join_game("127.0.0.1", port), OK, "joining")
	var ok: bool = await _wait_until(func() -> bool: return guest.is_connected_to_host(), 5.0)
	assert_true(ok, "connected")
	assert_true(not host.debug_ping.send_ping(), "the host does not ping")
	ok = await _wait_until(func() -> bool:
			guest.debug_ping.send_ping()
			return not guest.debug_ping.samples.is_empty(), 5.0)
	assert_true(ok, "a pong came back")
	var ms: float = guest.debug_ping.samples[0]
	assert_true(ms >= 0.0 and ms < 5000.0, "plausible round trip %.2f ms" % ms)
	assert_true(host.debug_ping.samples.is_empty(), "the host keeps no samples")
	await _end([guest, host])
