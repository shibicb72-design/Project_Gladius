extends RefCounted
## W2 test fakes (not a test file: the runner only loads test_*.gd). Headless desktop Godot has no relay and no WebRTC
## library, so the session gets an in-memory relay (routes protocol v1 like tools/lan does), WebSocketPeer-like
## sockets wired to it, and fake peer connections. All quiet: nothing here prints, push_error's or push_warning's.

## A WebSocketPeer stand-in (states as WebSocketPeer: 0 connecting, 1 open, 3 closed); NetSignaling only calls these.
class FakeSocket:
	extends RefCounted
	var relay: FakeRelay
	var url: String = ""
	var state: int = 3
	var inbox: Array[PackedByteArray] = []
	## Every text frame this socket sent, decoded (in order).
	var sent: Array[Dictionary] = []
	var peer_id: int = 0

	func _init(r: FakeRelay) -> void:
		relay = r

	func connect_to_url(u: String) -> int:
		url = u
		relay.urls_dialed.append(u)
		if relay.refuse_connect:
			return ERR_CANT_CONNECT
		state = 0
		return OK

	func poll() -> void:
		if state == 0:
			state = 1 if relay.reachable else 3

	func get_ready_state() -> int:
		return state

	func send_text(text: String) -> int:
		if state != 1:
			return ERR_UNCONFIGURED
		var msg: Variant = JSON.parse_string(text)
		if msg is Dictionary:
			sent.append(msg)
		relay.receive(self, text)
		return OK

	func get_available_packet_count() -> int:
		return inbox.size()

	func get_packet() -> PackedByteArray:
		if inbox.is_empty():
			return PackedByteArray()
		var pkt: PackedByteArray = inbox.pop_front()
		return pkt

	func close(_code: int = 1000, _reason: String = "") -> void:
		if state == 3:
			return
		state = 3
		relay.on_close(self)

	## Relay side: queue a frame for the client.
	func deliver(msg: Dictionary) -> void:
		inbox.append(JSON.stringify(msg).to_utf8_buffer())

	## Relay side: close the connection (the client sees STATE_CLOSED after reading what is queued).
	func drop() -> void:
		state = 3


## One-room relay with protocol v1 routing (host id 1, guests 2, 3, ...; to -> from).
class FakeRelay:
	extends RefCounted
	var reachable: bool = true
	var refuse_connect: bool = false
	## When true the relay never answers (timeout tests).
	var silent: bool = false
	var max_peers: int = 8
	var urls: Array = ["https://192.168.1.5:8443/"]
	var host: FakeSocket
	var guests: Dictionary = {}  # id -> FakeSocket
	var next_id: int = 2
	var urls_dialed: Array[String] = []
	var dropped: int = 0

	func new_socket() -> FakeSocket:
		return FakeSocket.new(self)

	func receive(from: FakeSocket, text: String) -> void:
		if silent:
			return
		var msg: Variant = JSON.parse_string(text)
		if NetSignaling.validate(msg, NetSignaling.CLIENT_TO_RELAY) != "":
			dropped += 1
			from.deliver({"type": "error", "code": "bad_message"})
			return
		var d: Dictionary = msg
		match String(d["type"]):
			"host":
				if host != null:
					from.deliver({"type": "error", "code": "host_exists"})
					return
				host = from
				from.peer_id = 1
				from.deliver({"type": "id", "id": 1, "urls": urls})
			"join":
				if host == null:
					from.deliver({"type": "error", "code": "no_host"})
					return
				if 1 + guests.size() >= max_peers:
					from.deliver({"type": "room_full"})
					from.drop()
					return
				var id := next_id
				next_id += 1
				guests[id] = from
				from.peer_id = id
				from.deliver({"type": "id", "id": id, "urls": urls})
				host.deliver({"type": "peer_joined", "id": id})
			_:
				var to := int(d["to"])
				var target: FakeSocket = host if to == 1 else guests.get(to)
				if from.peer_id == 0 or target == null or target == from:
					from.deliver({"type": "error", "code": "bad_target"})
					return
				var fwd := d.duplicate()
				fwd.erase("to")
				fwd["from"] = from.peer_id
				target.deliver(fwd)

	func on_close(s: FakeSocket) -> void:
		if s == host:
			host = null
			for id: int in guests.keys():
				var g: FakeSocket = guests[id]
				g.deliver({"type": "host_gone"})
				g.drop()
			guests.clear()
			next_id = 2
		elif s.peer_id > 1 and guests.get(s.peer_id) == s:
			guests.erase(s.peer_id)
			if host != null:
				host.deliver({"type": "peer_left", "id": s.peer_id})

	## Test hook: the host's socket closes (tab closed / crashed).
	func close_host() -> void:
		if host != null:
			var h := host
			h.drop()
			on_close(h)

	## Test hook: a guest's socket closes.
	func close_guest(id: int) -> void:
		var g: FakeSocket = guests.get(id)
		if g != null:
			g.drop()
			on_close(g)


## A WebRTCPeerConnection stand-in: records calls and answers like Godot (offer -> answer auto-created, a local
## description -> one host candidate).
class FakePc:
	extends RefCounted
	signal session_description_created(type: String, sdp: String)
	signal ice_candidate_created(media: String, index: int, name: String)
	var config: Dictionary = {}
	var calls: Array[String] = []
	var local: Array = []
	var remote: Array = []
	var candidates: Array = []
	var closed: bool = false
	var tag: String = ""

	func _init(t: String) -> void:
		tag = t

	func initialize(c: Dictionary = {}) -> int:
		config = c
		calls.append("initialize")
		return OK

	func create_offer() -> int:
		calls.append("create_offer")
		session_description_created.emit("offer", "v=0 offer-" + tag)
		return OK

	func set_local_description(type: String, sdp: String) -> int:
		calls.append("set_local_description")
		local = [type, sdp]
		ice_candidate_created.emit("0", 0, "candidate:1 1 udp 2122260223 192.168.1.5 5000%s typ host" % tag)
		return OK

	func set_remote_description(type: String, sdp: String) -> int:
		calls.append("set_remote_description")
		remote = [type, sdp]
		if type == "offer":
			session_description_created.emit("answer", "v=0 answer-" + tag)
		return OK

	func add_ice_candidate(media: String, index: int, cand_name: String) -> int:
		candidates.append([media, index, cand_name])
		return OK

	func close() -> void:
		closed = true


## Keeps the real WebRTCMultiplayerPeer (it works headless) and fakes the peer connections and add / remove.
class FakeRtcFactory:
	extends WebRtcFactory
	var pcs: Array = []
	var attached: Dictionary = {}  # peer id -> FakePc
	var attach_order: Array = []  # [peer id, pc.calls snapshot at attach time]
	var detached: Array[int] = []
	var tag: String = "a"

	func new_peer_connection() -> Object:
		var pc := FakePc.new("%s%d" % [tag, pcs.size()])
		pcs.append(pc)
		return pc

	func attach(_rtc: WebRTCMultiplayerPeer, pc: Object, peer_id: int) -> int:
		attached[peer_id] = pc
		attach_order.append([peer_id, (pc as FakePc).calls.duplicate()])
		return OK

	func detach(_rtc: WebRTCMultiplayerPeer, peer_id: int) -> void:
		detached.append(peer_id)
		attached.erase(peer_id)
