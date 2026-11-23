extends "res://tests/test_case.gd"
## W2: relay protocol v1 on the Godot side (pure encode / decode / validate), the relay URL from the page location,
## the ICE config, and the repo-wide "no outside ICE servers" scan.

const _Fakes := preload("res://tests/w2_fakes.gd")
const SDP := "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"


func _c2r(msg: Dictionary) -> String:
	return NetSignaling.validate(msg, NetSignaling.CLIENT_TO_RELAY)


func _r2c(msg: Variant) -> String:
	return NetSignaling.validate(msg, NetSignaling.RELAY_TO_CLIENT)


func test_every_client_message_encodes_and_round_trips() -> void:
	var msgs: Array[Dictionary] = [
		{"type": "host"},
		{"type": "join"},
		{"type": "offer", "to": 1, "sdp": SDP},
		{"type": "answer", "to": 3, "sdp": SDP},
		{"type": "candidate", "to": 1, "mid": "0", "index": 0, "name": "candidate:1 1 udp 1 192.168.1.5 5000 typ host"},
	]
	assert_eq(msgs.size(), NetSignaling.CLIENT_TO_RELAY.size(), "one sample per client -> relay type")
	for m in msgs:
		var text := NetSignaling.encode(m)
		assert_true(not text.is_empty(), "%s encodes" % m["type"])
		var back: Variant = JSON.parse_string(text)
		assert_true(back is Dictionary and _c2r(back) == "", "%s round-trips valid" % m["type"])
		assert_eq((back as Dictionary).size(), m.size(), "%s keeps exactly its fields" % m["type"])


func test_every_relay_message_decodes_with_int_ids() -> void:
	var texts: Dictionary = {
		"id": '{"type":"id","id":2,"urls":["https://192.168.1.5:8443/"]}',
		"peer_joined": '{"type":"peer_joined","id":2}',
		"offer": '{"type":"offer","from":2,"sdp":"v=0 x"}',
		"answer": '{"type":"answer","from":1,"sdp":"v=0 y"}',
		"candidate": '{"type":"candidate","from":1,"mid":"0","index":0,"name":"candidate:x"}',
		"peer_left": '{"type":"peer_left","id":4}',
		"room_full": '{"type":"room_full"}',
		"host_gone": '{"type":"host_gone"}',
		"error": '{"type":"error","code":"no_host"}',
	}
	assert_eq(texts.size(), NetSignaling.RELAY_TO_CLIENT.size(), "one sample per relay -> client type")
	for t: String in texts.keys():
		var m := NetSignaling.decode(texts[t])
		assert_eq(m.get("type"), t, "%s decodes" % t)
	var id_msg := NetSignaling.decode(texts["id"])
	assert_true(id_msg["id"] is int and id_msg["id"] == 2, "id is an int")
	assert_eq(id_msg["urls"], PackedStringArray(["https://192.168.1.5:8443/"]), "urls kept")
	var cand := NetSignaling.decode(texts["candidate"])
	assert_true(cand["from"] is int and cand["index"] is int, "candidate from / index are ints")


func test_refuses_malformed_unknown_and_oversized_messages() -> void:
	# validate reasons (relay -> client)
	assert_eq(_r2c([1, 2]), "not_object", "array refused")
	assert_eq(_r2c({"id": 1}), "no_type", "no type refused")
	assert_eq(_r2c({"type": 5}), "no_type", "non-string type refused")
	assert_eq(_r2c({"type": "hello"}), "unknown_type", "unknown type refused")
	assert_eq(_r2c({"type": "host"}), "unknown_type", "client-only type refused from the relay")
	assert_eq(_r2c({"type": "peer_left"}), "missing_field", "missing field refused")
	assert_eq(_r2c({"type": "room_full", "x": 1}), "extra_field", "extra field refused")
	assert_eq(_r2c({"type": "peer_left", "id": "2"}), "wrong_type", "string id refused")
	assert_eq(_r2c({"type": "peer_left", "id": 2.5}), "wrong_type", "fractional id refused")
	assert_eq(_r2c({"type": "peer_left", "id": true}), "wrong_type", "bool id refused")
	assert_eq(_r2c({"type": "candidate", "from": 1, "mid": "0", "index": -1, "name": "c"}), "wrong_type",
			"negative index refused")
	assert_eq(_r2c({"type": "offer", "from": 1, "sdp": ""}), "wrong_type", "empty sdp refused")
	assert_eq(_r2c({"type": "id", "id": 2, "urls": [1]}), "wrong_type", "non-string url refused")
	assert_eq(_r2c({"type": "id", "id": 2, "urls": "x"}), "wrong_type", "urls not an array refused")
	assert_eq(_r2c({"type": "error", "code": 3}), "wrong_type", "non-string code refused")
	assert_eq(NetSignaling.validate({"type": "offer", "from": 1, "sdp": "x".repeat(65)},
			NetSignaling.RELAY_TO_CLIENT, 64), "too_large", "sdp over the cap refused")
	# client -> relay
	assert_eq(_c2r({"type": "offer", "from": 1, "sdp": SDP}), "extra_field", "offer with from (relay field) refused")
	assert_eq(_c2r({"type": "id", "id": 1, "urls": []}), "unknown_type", "relay-only type refused from a client")
	assert_eq(_c2r({"type": "host", "role": "host"}), "extra_field", "spike's join role field refused")
	# decode refusals return {}
	assert_true(NetSignaling.decode("not json").is_empty(), "not JSON refused")
	assert_true(NetSignaling.decode("[1]").is_empty(), "JSON array refused")
	assert_true(NetSignaling.decode("").is_empty(), "empty frame refused")
	assert_true(NetSignaling.decode('{"type":"nope"}').is_empty(), "unknown type refused by decode")
	var big := '{"type":"offer","from":1,"sdp":"%s"}' % "x".repeat(NetSignaling.DEFAULT_MAX_BYTES)
	assert_true(NetSignaling.decode(big).is_empty(), "frame over 16384 bytes refused")
	assert_true(not NetSignaling.decode('{"type":"offer","from":1,"sdp":"x"}', 64).is_empty(), "small frame ok")
	# encode refusals return ""
	assert_eq(NetSignaling.encode({"type": "join", "x": 1}), "", "invalid message not encoded")
	assert_eq(NetSignaling.encode({"type": "offer", "to": 1, "sdp": "x".repeat(100)}, 64), "", "oversized not encoded")


func test_signaling_client_drops_bad_frames_and_emits_good_ones() -> void:
	var relay = _Fakes.FakeRelay.new()
	var sock = relay.new_socket()
	var sig := NetSignaling.new(NetSignaling.DEFAULT_MAX_BYTES, func() -> Object: return sock)
	var got: Array = []
	var state := {"opened": 0, "closed": []}
	sig.opened.connect(func() -> void: state["opened"] += 1)
	sig.message_received.connect(func(m: Dictionary) -> void: got.append(m))
	sig.closed.connect(func(was_open: bool) -> void: state["closed"].append(was_open))
	assert_eq(sig.open("ws://127.0.0.1:8080/signal"), OK, "open starts")
	assert_true(not sig.send({"type": "host"}), "nothing sent before open")
	sig.poll()
	assert_eq(state["opened"], 1, "opened once")
	sock.inbox.append("garbage".to_utf8_buffer())
	sock.inbox.append('{"type":"peer_joined","id":2,"extra":1}'.to_utf8_buffer())
	sock.deliver({"type": "peer_joined", "id": 2})
	sig.poll()
	assert_eq(sig.dropped, 2, "two bad frames counted")
	assert_eq(got.size(), 1, "one good frame emitted")
	assert_true(sig.send({"type": "host"}), "valid message sent when open")
	assert_true(not sig.send({"type": "host", "x": 1}), "invalid message not sent")
	assert_eq(sock.sent, [{"type": "host"}], "only the valid frame reached the socket")
	sock.drop()
	sig.poll()
	sig.poll()
	assert_eq(state["closed"], [true], "closed once, after having been open")
	assert_eq(state["opened"], 1, "still opened once")


func test_relay_url_follows_the_page_location() -> void:
	assert_eq(NetSession.relay_url_from_location("http:", "127.0.0.1:8080"), "ws://127.0.0.1:8080/signal",
			"http page -> ws, same host:port")
	assert_eq(NetSession.relay_url_from_location("https:", "192.168.1.5:8443"), "wss://192.168.1.5:8443/signal",
			"https page -> wss, same host:port")
	assert_eq(NetSession.relay_url_from_location("https:", ""), "", "no host -> no URL")
	assert_eq(NetSession.page_relay_url(), "", "off the web there is no page location (JavaScriptBridge unused)")
	var s := NetSession.new()
	assert_eq(s._resolve_relay_url(), "", "default resolves to nothing off the web")
	s.relay_url_provider = func() -> String: return "ws://10.0.0.2:8080/signal"
	assert_eq(s._resolve_relay_url(), "ws://10.0.0.2:8080/signal", "provider used")
	s.relay_url = "wss://10.0.0.3:8443/signal"
	assert_eq(s._resolve_relay_url(), "wss://10.0.0.3:8443/signal", "explicit relay_url wins")
	s.free()


func test_ice_config_is_exactly_no_servers() -> void:
	assert_eq(NetSession.ICE_CONFIG, {"iceServers": []}, "ICE config")
	assert_eq(JSON.stringify(NetSession.ICE_CONFIG), '{"iceServers":[]}', "ICE config, serialized")


## "st"+"un:" is refused anywhere (plain substring). "tu"+"rn:" is a common word in game code ("var turn: float",
## "no automatic return: ..."), so it is refused in its ICE URL shape: not inside a word and followed at once by a host
## character ("tu"+"rn:host", "tu"+"rns:host"). Needles are split so this file never matches itself.
func test_no_outside_ice_server_urls_in_the_repo() -> void:
	var stun := "st" + "un:"
	var turn_url := RegEx.create_from_string("(?<![a-z0-9_])tu" + "rns?:(?=[^\\s\"'])")
	var exts: Array[String] = ["gd", "json", "mjs", "js", "cjs", "cfg", "md", "txt", "html", "tres", "tscn", "py",
			"sh", "ps1", "csv", "yml", "yaml", "toml"]
	var hits: Array[String] = []
	var scanned := 0
	for root in ["res://scripts", "res://tools", "res://data", "res://tests"]:
		var files: Array[String] = []
		_collect(root, exts, files)
		for f in files:
			scanned += 1
			var text := FileAccess.get_file_as_string(f).to_lower()
			if text.contains(stun):
				hits.append("%s contains %s" % [f, stun])
			var m := turn_url.search(text)
			if m != null:
				hits.append("%s contains %s" % [f, m.get_string()])
	assert_true(scanned > 50, "scanned the repo's text files (%d)" % scanned)
	assert_true(turn_url.search("ice: tu" + "rn:192.168.1.5:3478") != null, "the URL shape is caught")
	assert_true(turn_url.search("var turn: float; no automatic return: x") == null, "game words are not")
	assert_eq(hits, [] as Array[String], "no outside STUN / TURN server anywhere")


func _collect(dir_path: String, exts: Array[String], out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.include_hidden = false
	for f in d.get_files():
		if f.get_extension().to_lower() in exts:
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_collect(dir_path.path_join(sub), exts, out)
