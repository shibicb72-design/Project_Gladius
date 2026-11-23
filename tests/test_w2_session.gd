extends "res://tests/test_case.gd"
## W2: NetSession's transport seam. ENet stays the default; the WebRTC path runs against an in-memory relay and fake
## peer connections (tests/w2_fakes.gd) because a headless desktop run has neither. Every session is isolated (its
## own SceneMultiplayer) and freed at the end of its test.

const _Fakes := preload("res://tests/w2_fakes.gd")
const URL := "wss://192.168.1.5:8443/signal"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > int(timeout_s * 1000.0):
			return false
		await _tree().process_frame
	return true


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_tree().root.add_child(s)
	return s


## A WebRTC session on `relay` with fake peer connections; `events` collects its signals in order.
func _rtc_session(node_name: String, relay: Object, tag: String, events: Array) -> NetSession:
	var s := _session(node_name)
	s.transport = NetSession.TRANSPORT_WEBRTC
	s.relay_url = URL
	s.socket_factory = relay.new_socket
	var f = _Fakes.FakeRtcFactory.new()
	f.tag = tag
	s.rtc_factory = f
	s.host_ready.connect(func(urls: PackedStringArray) -> void: events.append(["host_ready", urls]))
	s.failed.connect(func() -> void: events.append(["failed", s.last_error]))
	s.host_lost.connect(func() -> void: events.append(["host_lost", s.last_error]))
	s.connected.connect(func() -> void: events.append(["connected"]))
	return s


func _short_timeout(s: NetSession, seconds: float) -> void:
	s.cfg = s.cfg.duplicate(true)  # never edit the shared registry copy
	s.cfg["connect_timeout_s"] = seconds


func _end(sessions: Array) -> void:
	for s: NetSession in sessions:
		s.leave()
		s.queue_free()
	await _tree().process_frame


# ---- ENet stays the default ----------------------------------------------------------------

func test_transport_defaults_to_enet_and_hosts_an_enet_peer() -> void:
	PlatformServices.simulate_web = true  # the transport never follows the platform
	var s := _session("W2Enet")
	PlatformServices.simulate_web = false
	assert_eq(s.transport, NetSession.TRANSPORT_ENET, "default transport")
	assert_true(not s.has_enet_peer() and not s.has_network_peer(), "no peer before hosting")
	var ready_fired := [false]
	s.host_ready.connect(func(_u: PackedStringArray) -> void: ready_fired[0] = true)
	assert_eq(s.host_game(), OK, "ENet host starts synchronously")
	assert_true(s.is_host, "is_host at once")
	assert_true(s.has_enet_peer() and s.has_network_peer(), "ENet peer, network peer")
	assert_true(s.multiplayer.multiplayer_peer is ENetMultiplayerPeer, "ENet on the multiplayer")
	await _frames(2)
	assert_true(not ready_fired[0], "ENet does not emit host_ready")
	s.leave()
	assert_true(not s.has_enet_peer() and not s.has_network_peer(), "no peer after leave")
	s.start_offline()
	assert_true(s.solo, "solo")
	assert_true(not s.has_enet_peer() and not s.has_network_peer(), "solo: no ENet peer, no network peer")
	await _end([s])


# ---- WebRTC host ---------------------------------------------------------------------------

func test_webrtc_host_happy_path() -> void:
	var relay = _Fakes.FakeRelay.new()
	var events: Array = []
	var h := _rtc_session("W2Host", relay, "h", events)
	assert_eq(h.host_game(), OK, "host started")
	assert_true(not h.is_host and not h.has_network_peer(), "nothing up before the relay answers")
	var ok: bool = await _wait_until(func() -> bool: return not events.is_empty(), 2.0)
	assert_true(ok, "an answer came")
	assert_eq(relay.urls_dialed, [URL] as Array[String], "dialed the injected relay URL")
	assert_eq(relay.host.sent, [{"type": "host"}] as Array[Dictionary], "sent host")
	assert_eq(events, [["host_ready", PackedStringArray(relay.urls)]], "host_ready with the join URLs")
	assert_eq(h.join_urls, PackedStringArray(relay.urls), "join_urls kept")
	assert_true(h.is_host and h.has_network_peer() and not h.has_enet_peer(), "WebRTC host, no ENet peer")
	assert_true(h.multiplayer.multiplayer_peer is WebRTCMultiplayerPeer, "WebRTC peer on the multiplayer")
	assert_eq(h.get_unique_id(), 1, "server id 1")
	assert_true(h.is_connected_to_host(), "WebRTC server reports CONNECTED at once (bridge _online)")
	assert_true(h.lobby.is_host(), "the lobby sees a host")
	assert_eq(h.last_error, "", "no error")
	await _end([h])
	assert_true(relay.host == null, "leaving closed the signaling socket")


func test_webrtc_host_exists() -> void:
	var relay = _Fakes.FakeRelay.new()
	var log1: Array = []
	var log2: Array = []
	var h1 := _rtc_session("W2HostA", relay, "a", log1)
	var h2 := _rtc_session("W2HostB", relay, "b", log2)
	h1.host_game()
	await _wait_until(func() -> bool: return not log1.is_empty(), 2.0)
	h2.host_game()
	var ok: bool = await _wait_until(func() -> bool: return not log2.is_empty(), 2.0)
	assert_true(ok, "second host answered")
	assert_eq(log2, [["failed", "host_exists"]], "failed with host_exists")
	assert_true(not h2.is_host and not h2.has_network_peer(), "second host has no peer")
	assert_true(h1.is_host, "first host unaffected")
	await _end([h1, h2])


func test_webrtc_relay_unreachable() -> void:
	var relay = _Fakes.FakeRelay.new()
	relay.reachable = false
	var events: Array = []
	var h := _rtc_session("W2HostDown", relay, "h", events)
	assert_eq(h.host_game(), OK, "started")
	var ok: bool = await _wait_until(func() -> bool: return not events.is_empty(), 2.0)
	assert_true(ok, "failure reported")
	assert_eq(events, [["failed", "relay_unreachable"]], "relay_unreachable")
	assert_true(not h.has_network_peer(), "no peer")
	# No relay URL at all (not a relay-served page): refused synchronously.
	h.relay_url = ""
	assert_eq(h.host_game(), ERR_CANT_CONNECT, "no URL -> error code")
	assert_eq(h.last_error, "relay_unreachable", "code set")
	# The socket refuses to start.
	h.relay_url = URL
	relay.refuse_connect = true
	assert_eq(h.join_game("ignored"), ERR_CANT_CONNECT, "socket error returned")
	assert_eq(h.last_error, "relay_unreachable", "code set")
	await _end([h])


func test_webrtc_host_timeout() -> void:
	var relay = _Fakes.FakeRelay.new()
	relay.silent = true
	var events: Array = []
	var h := _rtc_session("W2HostSlow", relay, "h", events)
	assert_eq(float(h.cfg["connect_timeout_s"]), 5.0, "net.json timeout")
	_short_timeout(h, 0.2)
	h.host_game()
	await _frames(2)
	assert_true(events.is_empty(), "still waiting")
	var ok: bool = await _wait_until(func() -> bool: return not events.is_empty(), 2.0)
	assert_true(ok, "timed out")
	assert_eq(events, [["failed", "timeout"]], "timeout")
	assert_true(not h.has_network_peer() and not h.is_host, "nothing left")
	await _end([h])


# ---- WebRTC guest --------------------------------------------------------------------------

func test_webrtc_guest_offer_answer_and_candidates() -> void:
	var relay = _Fakes.FakeRelay.new()
	var hlog: Array = []
	var glog: Array = []
	var h := _rtc_session("W2HostG", relay, "h", hlog)
	var g := _rtc_session("W2Guest", relay, "g", glog)
	h.host_game()
	await _wait_until(func() -> bool: return not hlog.is_empty(), 2.0)
	assert_eq(g.join_game("10.9.9.9", 1234), OK, "join started (address ignored)")
	var hf = h.rtc_factory
	var gf = g.rtc_factory
	var ok: bool = await _wait_until(func() -> bool:
			return gf.pcs.size() == 1 and not gf.pcs[0].remote.is_empty() and not gf.pcs[0].candidates.is_empty(), 2.0)
	assert_true(ok, "the guest's peer connection got the answer and a candidate")
	assert_eq(relay.urls_dialed, [URL, URL] as Array[String], "the guest dialed the relay too")
	var gs: Dictionary = relay.guests[2].sent[0]
	assert_eq(gs, {"type": "join"}, "sent join")
	assert_eq(g.get_unique_id(), 2, "create_client with the relay id")
	assert_true(g.has_network_peer() and not g.has_enet_peer() and not g.is_host, "WebRTC guest peer")
	assert_true(not g.is_connected_to_host(), "not connected yet (fake pcs never connect)")
	# Guest side: one pc for peer 1, ICE config, added before the offer.
	var gpc = gf.pcs[0]
	assert_eq(gpc.config, NetSession.ICE_CONFIG, "guest pc ICE config")
	assert_eq(gf.attach_order, [[1, ["initialize"]]], "add_peer(pc, 1) right after initialize, before create_offer")
	assert_eq(gpc.calls.slice(0, 3), ["initialize", "create_offer", "set_local_description"], "offer made, set local")
	assert_eq(gpc.remote, ["answer", "v=0 answer-h0"], "host's answer applied")
	assert_eq(gpc.candidates.size(), 1, "host's candidate applied")
	assert_eq(gpc.candidates[0][2], "candidate:1 1 udp 2122260223 192.168.1.5 5000h0 typ host", "the host's candidate")
	# Host side: pc for peer 2, added before set_remote_description(offer), answer sent back.
	assert_eq(hf.pcs.size(), 1, "host made one pc")
	var hpc = hf.pcs[0]
	assert_eq(hpc.config, NetSession.ICE_CONFIG, "host pc ICE config")
	assert_eq(hf.attach_order, [[2, ["initialize"]]], "add_peer(pc, 2) before set_remote_description")
	assert_eq(hpc.remote, ["offer", "v=0 offer-g0"], "guest's offer applied")
	assert_eq(hpc.candidates.size(), 1, "guest's candidate applied")
	var types: Array = []
	for m: Dictionary in relay.guests[2].sent:
		types.append(m["type"])
	assert_eq(types, ["join", "offer", "candidate"], "guest sent join, offer, candidate")
	types.clear()
	for m: Dictionary in relay.host.sent:
		types.append(m["type"])
	assert_eq(types, ["host", "answer", "candidate"], "host sent host, answer, candidate")
	assert_eq(relay.dropped, 0, "every message valid for the relay")
	assert_eq(glog, [], "no failure on the guest")
	await _end([g, h])


func test_webrtc_room_full_and_no_host() -> void:
	var relay = _Fakes.FakeRelay.new()
	var glog: Array = []
	var g := _rtc_session("W2GuestAlone", relay, "g", glog)
	g.join_game("")
	var ok: bool = await _wait_until(func() -> bool: return not glog.is_empty(), 2.0)
	assert_true(ok, "no_host reported")
	assert_eq(glog, [["failed", "no_host"]], "no_host")
	assert_true(not g.has_network_peer(), "no peer")

	relay.max_peers = 2
	var hlog: Array = []
	var g2log: Array = []
	var h := _rtc_session("W2HostFull", relay, "h", hlog)
	h.host_game()
	await _wait_until(func() -> bool: return not hlog.is_empty(), 2.0)
	glog.clear()
	g.join_game("")
	await _wait_until(func() -> bool: return g.get_unique_id() == 2, 2.0)
	var g2 := _rtc_session("W2GuestLate", relay, "x", g2log)
	g2.join_game("")
	ok = await _wait_until(func() -> bool: return not g2log.is_empty(), 2.0)
	assert_true(ok, "room_full reported")
	assert_eq(g2log, [["failed", "room_full"]], "room_full")
	assert_true(not g2.has_network_peer(), "late guest has no peer")
	assert_eq(glog, [], "first guest unaffected")
	await _end([g2, g, h])


func test_webrtc_guest_timeout_and_peer_left_on_host() -> void:
	var relay = _Fakes.FakeRelay.new()
	var hlog: Array = []
	var glog: Array = []
	var h := _rtc_session("W2HostT", relay, "h", hlog)
	var g := _rtc_session("W2GuestT", relay, "g", glog)
	var left: Array[int] = []
	h.peer_left.connect(func(id: int) -> void: left.append(id))
	h.host_game()
	await _wait_until(func() -> bool: return not hlog.is_empty(), 2.0)
	_short_timeout(g, 0.4)
	g.join_game("")
	var hf = h.rtc_factory
	await _wait_until(func() -> bool: return hf.attached.has(2), 2.0)
	assert_true(hf.attached.has(2), "host added peer 2")
	# The fake pcs never connect: the join times out as a whole (id and offer happened, `connected` did not).
	var ok: bool = await _wait_until(func() -> bool: return not glog.is_empty(), 2.0)
	assert_true(ok, "guest timed out")
	assert_eq(glog, [["failed", "timeout"]], "timeout")
	assert_true(not g.has_network_peer() and g.get_unique_id() == 0, "guest torn down")
	assert_true(relay.guests.is_empty(), "guest socket closed")
	ok = await _wait_until(func() -> bool: return hf.detached.size() == 1 and hf.detached[0] == 2, 2.0)
	assert_true(ok, "host removed peer 2 on peer_left (no ICE timeout wait)")
	assert_true(hf.pcs[0].closed, "host closed that peer connection")
	assert_true(not hf.attached.has(2), "peer 2 gone from the host")
	assert_eq(hlog.size(), 1, "host still up, nothing else emitted")
	assert_true(h.is_host and h.has_network_peer(), "host still hosting")
	await _end([h])


func test_webrtc_host_gone_two_sessions_host_lost_once() -> void:
	var relay = _Fakes.FakeRelay.new()
	var hlog: Array = []
	var glog: Array = []
	var h := _rtc_session("W2HostX", relay, "h", hlog)
	var g := _rtc_session("W2GuestX", relay, "g", glog)
	h.host_game()
	await _wait_until(func() -> bool: return not hlog.is_empty(), 2.0)
	g.join_game("")
	var gf = g.rtc_factory
	await _wait_until(func() -> bool: return gf.pcs.size() == 1 and not gf.pcs[0].remote.is_empty(), 2.0)
	assert_true(g.has_network_peer() and g.get_unique_id() == 2, "guest in the room")
	relay.close_host()  # the host's tab closes
	var ok: bool = await _wait_until(func() -> bool: return not glog.is_empty(), 2.0)
	assert_true(ok, "guest noticed")
	# A late SceneMultiplayer server_disconnected (Chrome's ICE timeout) must not emit a second host_lost.
	(g.multiplayer as SceneMultiplayer).server_disconnected.emit()
	await _frames(3)
	assert_eq(glog, [["host_lost", "host_left"]], "host_lost exactly once, no failed")
	assert_true(not g.has_network_peer() and not g.has_enet_peer(), "guest has no network peer")
	assert_true(g.multiplayer.multiplayer_peer == null or g.multiplayer.multiplayer_peer is OfflineMultiplayerPeer,
			"guest multiplayer cleared")
	assert_true(gf.pcs[0].closed, "guest closed its peer connection")
	assert_eq(hlog.size(), 1, "host side emitted nothing new")
	await _end([g, h])
