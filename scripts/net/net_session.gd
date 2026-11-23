class_name NetSession
extends Node
## Host/join/leave using Godot's high-level multiplayer API only. Two transports behind one seam: ENet (the default
## everywhere, LAN on desktop) and WebRTC (W2: browsers, signaled through the LAN relay, protocol v1). The transport
## is an explicit choice (`transport`); it never follows the platform.

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connected
signal failed
signal host_lost
## W2, WebRTC only: the relay gave this host id 1 and the server is up. `urls` are the join URLs to show guests.
## ENet hosting is synchronous and does not emit it.
signal host_ready(urls: PackedStringArray)

const NET_PATH := "res://data/net.json"
const MATCH_PATH := "res://data/match.json"
const TRANSPORT_ENET := "enet"
const TRANSPORT_WEBRTC := "webrtc"
## The only ICE configuration: LAN host candidates, no outside servers.
const ICE_CONFIG := {"iceServers": []}
const RELAY_PATH := "/signal"

## When true the session owns a private SceneMultiplayer for its own subtree (used to run a host and a
## client in one process). Set before adding to the tree.
var isolated: bool = false
var cfg: Dictionary = {}
var is_host: bool = false
## W0: a local, offline session (Play solo, AppFlow.solo). No ENet peer; the lobby acts as host without RPCs. Set by
## start_offline(), cleared by host_game / join_game / leave.
var solo: bool = false
var lobby: NetLobby
var bridge: NetMatchBridge
## W2: TRANSPORT_ENET (default) or TRANSPORT_WEBRTC. Set before host_game / join_game; only a relay-served web page
## sets WebRTC.
var transport: String = TRANSPORT_ENET
## W2: why the last WebRTC host / join failed or the host was lost, for the UI: "relay_unreachable", "relay_lost",
## "host_exists", "room_full", "no_host", "host_left", "timeout", "connection_failed", "bad_relay"; "" otherwise.
## Set before `failed` / `host_lost` fire; cleared by host_game / join_game.
var last_error: String = ""
## W2: the join URLs from the relay's `id` message (WebRTC host and guest).
var join_urls: PackedStringArray = PackedStringArray()
## W2 injectables. relay_url wins when set; else relay_url_provider (a Callable returning the ws(s):// URL); else the
## page's own location (web export only; "" elsewhere).
var relay_url: String = ""
var relay_url_provider: Callable
## Returns a WebSocketPeer-like socket for the signaling client; empty means a real WebSocketPeer.
var socket_factory: Callable
var rtc_factory: WebRtcFactory = WebRtcFactory.new()
## W2: round-trip ping and snapshot counters for the LAN smoke (debug web builds only; inert elsewhere).
var debug_ping: NetDebugPing
## W2: why the app's WebRTC session last lost its host ("host_left" / "relay_lost"), for the main menu to show once
## after the lobby or match sends the player back (they end the session first). Set only for AppFlow.session.
static var lost_notice: String = ""

var _mp: SceneMultiplayer
var _peer: ENetMultiplayerPeer
var _connecting_since_ms: int = -1
var _rtc: WebRTCMultiplayerPeer
var _signal: NetSignaling
var _pcs: Dictionary = {}  # peer id -> WebRTCPeerConnection (or a test fake)
var _rtc_role: String = ""  # "host" | "guest" while a WebRTC host / join is in progress or up
var _rtc_joined: bool = false  # guest: connected_to_server fired
var _signal_since_ms: int = -1  # host: until `id`; guest: until connected
var _host_lost_sent: bool = false


func _init() -> void:
	cfg = DataRegistry.new().load_file(NET_PATH)


func _enter_tree() -> void:
	if isolated:
		_mp = SceneMultiplayer.new()
		get_tree().set_multiplayer(_mp, get_path())
	else:
		_mp = multiplayer as SceneMultiplayer
	_mp.peer_connected.connect(func(id: int) -> void: peer_joined.emit(id))
	_mp.peer_disconnected.connect(func(id: int) -> void: peer_left.emit(id))
	_mp.connected_to_server.connect(_on_connected)
	_mp.connection_failed.connect(_on_failed)
	_mp.server_disconnected.connect(_on_server_disconnected)
	# Same node path on every peer, before anyone connects (RPC target must exist on the receiver).
	if lobby == null:
		lobby = NetLobby.new()
		lobby.name = "Lobby"
		add_child(lobby)
	if bridge == null:
		bridge = NetMatchBridge.new()
		bridge.name = "Bridge"
		add_child(bridge)
	# W2: always added (same RPC paths in every build); it only acts in a debug web build.
	if debug_ping == null:
		debug_ping = NetDebugPing.new()
		debug_ping.name = NetDebugPing.NODE_NAME
		add_child(debug_ping)


func max_clients() -> int:
	var max_humans: int = int(DataRegistry.new().load_file(MATCH_PATH).get("max_humans", 6))
	return maxi(max_humans - 1, 1)


func get_port() -> int:
	return int(cfg.get("port", 7777))


## W0: Play solo. Drops any network peer and puts an OfflineMultiplayerPeer on this session's multiplayer (unique id 1,
## so the lobby's host entry is id 1 as on a real host) without creating any ENet peer. is_host stays false: it means
## "hosts an ENet server". The lobby reads `solo` for its host controls and local start.
func start_offline() -> void:
	leave()
	if _mp != null:
		_mp.multiplayer_peer = OfflineMultiplayerPeer.new()
	solo = true
	if lobby != null:
		lobby.solo = true


## Returns OK or an Error code. ENet: the server is up on return. WebRTC: OK means "started"; `host_ready` or
## `failed` (with last_error) fires later.
func host_game(port: int = -1) -> int:
	if transport == TRANSPORT_WEBRTC:
		return _start_webrtc("host")
	_set_solo(false)
	_host_lost_sent = false
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port if port > 0 else get_port(), max_clients())
	if err != OK:
		_peer = null
		return err
	_mp.multiplayer_peer = _peer
	is_host = true
	return OK


## Starts connecting; `connected` or `failed` fires later (failure includes the timeout). WebRTC ignores address and
## port (the page knows its relay).
func join_game(address: String, port: int = -1) -> int:
	if transport == TRANSPORT_WEBRTC:
		return _start_webrtc("guest")
	_set_solo(false)
	_host_lost_sent = false
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port if port > 0 else get_port())
	if err != OK:
		_peer = null
		return err
	_mp.multiplayer_peer = _peer
	is_host = false
	_connecting_since_ms = Time.get_ticks_msec()
	return OK


func leave() -> void:
	_connecting_since_ms = -1
	if _peer != null:
		_peer.close()
	_teardown_webrtc()
	if _mp != null:
		_mp.multiplayer_peer = null
	_peer = null
	is_host = false
	_set_solo(false)


func _set_solo(on: bool) -> void:
	solo = on
	if lobby != null:
		lobby.solo = on


## True when this session holds an ENet peer (host or client). Tests use it to check solo never makes one.
func has_enet_peer() -> bool:
	return _peer != null or (_mp != null and _mp.multiplayer_peer is ENetMultiplayerPeer)


## W2: true when this session holds a network peer of either transport (false in solo / offline and before a WebRTC
## host got its id).
func has_network_peer() -> bool:
	return has_enet_peer() or _rtc != null


func get_unique_id() -> int:
	return _mp.get_unique_id() if _mp != null and _mp.multiplayer_peer != null else 0


func is_connected_to_host() -> bool:
	if _rtc != null:
		return _rtc.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _process(_delta: float) -> void:
	_process_webrtc()
	if _connecting_since_ms < 0:
		return
	var timeout_ms := int(float(cfg.get("connect_timeout_s", 5.0)) * 1000.0)
	if Time.get_ticks_msec() - _connecting_since_ms > timeout_ms:
		_on_failed()


func _on_connected() -> void:
	_connecting_since_ms = -1
	if _rtc_role == "guest":
		_rtc_joined = true
		_signal_since_ms = -1
	connected.emit()


func _on_failed() -> void:
	if _rtc_role != "":
		_fail_webrtc("connection_failed")
		return
	if _connecting_since_ms < 0 and _peer == null:
		return
	leave()
	failed.emit()


func _on_server_disconnected() -> void:
	if _host_lost_sent:
		return
	if _rtc_role != "":
		_lose_host("host_left")
		return
	host_lost.emit()


# ---- WebRTC transport (W2) -------------------------------------------------------------------

## The relay URL for a page at `protocol` ("http:" / "https:") and `host` ("host:port"): ws:// for http, wss:// for
## https, same host and port, path /signal.
static func relay_url_from_location(protocol: String, host: String) -> String:
	if host.is_empty():
		return ""
	var scheme := "wss://" if protocol.to_lower().begins_with("https") else "ws://"
	return scheme + host + RELAY_PATH


## The relay URL of the page this web export runs on; "" off the web (JavaScriptBridge is only used in a browser).
static func page_relay_url() -> String:
	if not OS.has_feature("web"):
		return ""
	var protocol: Variant = JavaScriptBridge.eval("location.protocol", true)
	var host: Variant = JavaScriptBridge.eval("location.host", true)
	if not protocol is String or not host is String:
		return ""
	return relay_url_from_location(protocol, host)


func _resolve_relay_url() -> String:
	if not relay_url.is_empty():
		return relay_url
	if relay_url_provider.is_valid():
		return String(relay_url_provider.call())
	return page_relay_url()


func _max_message_bytes() -> int:
	var relay: Variant = cfg.get("lan_relay", {})
	if relay is Dictionary and (relay as Dictionary).has("max_message_bytes"):
		return int(relay["max_message_bytes"])
	return int(cfg.get("max_message_bytes", NetSignaling.DEFAULT_MAX_BYTES))


func _start_webrtc(role: String) -> int:
	leave()
	last_error = ""
	join_urls = PackedStringArray()
	_host_lost_sent = false
	var url := _resolve_relay_url()
	if url.is_empty():
		last_error = "relay_unreachable"
		return ERR_CANT_CONNECT
	_signal = NetSignaling.new(_max_message_bytes(), socket_factory)
	_signal.opened.connect(_on_signal_opened)
	_signal.message_received.connect(_on_signal_message)
	_signal.closed.connect(_on_signal_closed)
	var err := _signal.open(url)
	if err != OK:
		_signal = null
		last_error = "relay_unreachable"
		return err
	_rtc_role = role
	_rtc_joined = false
	_signal_since_ms = Time.get_ticks_msec()
	return OK


func _process_webrtc() -> void:
	var sig := _signal  # a handler may drop _signal during poll
	if sig != null:
		sig.poll()
	if _signal_since_ms < 0:
		return
	var timeout_ms := int(float(cfg.get("connect_timeout_s", 5.0)) * 1000.0)
	if Time.get_ticks_msec() - _signal_since_ms > timeout_ms:
		_fail_webrtc("timeout")


func _on_signal_opened() -> void:
	_signal.send({"type": "host" if _rtc_role == "host" else "join"})


func _on_signal_message(msg: Dictionary) -> void:
	match String(msg["type"]):
		"id":
			_on_relay_id(int(msg["id"]), msg["urls"])
		"offer":
			if _rtc_role == "host" and _rtc != null:
				var from := int(msg["from"])
				if from > 1:
					if _pcs.has(from):  # a repeated offer replaces the old connection
						_drop_pc(from)
					var pc := _make_pc(from)
					if pc != null:
						pc.call("set_remote_description", "offer", String(msg["sdp"]))  # answer auto-created
		"answer":
			var pc: Object = _pcs.get(int(msg["from"]))
			if _rtc_role == "guest" and pc != null:
				pc.call("set_remote_description", "answer", String(msg["sdp"]))
		"candidate":
			var pc: Object = _pcs.get(int(msg["from"]))
			if pc != null:
				pc.call("add_ice_candidate", String(msg["mid"]), int(msg["index"]), String(msg["name"]))
		"peer_left":
			if _rtc_role == "host":
				_drop_pc(int(msg["id"]))
		"room_full":
			if _rtc_role == "guest" and not _rtc_joined:
				_fail_webrtc("room_full")
		"host_gone":
			if _rtc_role == "guest":
				_lose_host("host_left")
		"error":
			var code := String(msg["code"])
			if code == "host_exists" and _rtc_role == "host" and _rtc == null:
				_fail_webrtc(code)
			elif code == "no_host" and _rtc_role == "guest" and not _rtc_joined:
				_fail_webrtc(code)
			# Other codes (bad_target for a guest that just left, ...) are not fatal.


func _on_relay_id(id: int, urls: PackedStringArray) -> void:
	if _rtc != null:
		return
	join_urls = urls
	_rtc = rtc_factory.new_multiplayer_peer()
	if _rtc_role == "host":
		if id != 1 or _rtc.create_server() != OK:
			_fail_webrtc("bad_relay")
			return
		_mp.multiplayer_peer = _rtc  # CONNECTED at once, unique id 1
		is_host = true
		_signal_since_ms = -1
		host_ready.emit(urls)
		return
	if id < 2 or _rtc.create_client(id) != OK:
		_fail_webrtc("bad_relay")
		return
	_mp.multiplayer_peer = _rtc
	is_host = false
	var pc := _make_pc(1)
	if pc == null:
		_fail_webrtc("connection_failed")
		return
	pc.call("create_offer")  # the guest offers (spike result)


## Makes, initializes and adds the peer connection for peer_id (add_peer before create_offer /
## set_remote_description so the negotiated data channels are in the SDP).
func _make_pc(peer_id: int) -> Object:
	var pc: Object = rtc_factory.new_peer_connection()
	if pc == null or int(pc.call("initialize", ICE_CONFIG)) != OK:
		return null
	pc.connect("session_description_created", _on_pc_sdp.bind(pc, peer_id))
	pc.connect("ice_candidate_created", _on_pc_candidate.bind(peer_id))
	if rtc_factory.attach(_rtc, pc, peer_id) != OK:
		pc.call("close")
		return null
	_pcs[peer_id] = pc
	return pc


func _on_pc_sdp(type: String, sdp: String, pc: Object, peer_id: int) -> void:
	if _pcs.get(peer_id) != pc:
		return
	# Send first: the description must reach the peer before any candidate that setting it may produce.
	if _signal != null:
		_signal.send({"type": type, "to": peer_id, "sdp": sdp})
	pc.call("set_local_description", type, sdp)


func _on_pc_candidate(media: String, index: int, cand_name: String, peer_id: int) -> void:
	if _signal != null and _pcs.has(peer_id):
		_signal.send({"type": "candidate", "to": peer_id, "mid": media, "index": index, "name": cand_name})


## Host: a guest left the relay. Removes it from the multiplayer peer now (peer_disconnected fires at once if it was
## connected) instead of waiting ~7 s for the browser's ICE timeout.
func _drop_pc(peer_id: int) -> void:
	var pc: Object = _pcs.get(peer_id)
	_pcs.erase(peer_id)
	if _rtc != null:
		rtc_factory.detach(_rtc, peer_id)
	if pc != null:
		pc.call("close")


func _on_signal_closed(was_open: bool) -> void:
	_signal = null
	if _rtc_role == "host":
		if _rtc == null:
			_fail_webrtc("relay_lost" if was_open else "relay_unreachable")
		# A running host keeps its connected guests; only new joins need the relay.
	elif _rtc_role == "guest":
		if _rtc != null:  # had an id: the room (or the relay) is gone
			_lose_host("relay_lost")
		else:
			_fail_webrtc("relay_lost" if was_open else "relay_unreachable")


func _fail_webrtc(code: String) -> void:
	last_error = code
	leave()
	failed.emit()


## Guest: the host is gone. Tears down and emits host_lost exactly once (a later server_disconnected is ignored).
func _lose_host(code: String) -> void:
	if _host_lost_sent:
		return
	_host_lost_sent = true
	last_error = code
	if AppFlow.session == self:
		lost_notice = code
	leave()
	host_lost.emit()


## W2: the pending host-lost reason for the main menu, cleared on read ("" when none).
static func take_lost_notice() -> String:
	var code := lost_notice
	lost_notice = ""
	return code


func _teardown_webrtc() -> void:
	_signal_since_ms = -1
	_rtc_role = ""
	_rtc_joined = false
	if _signal != null:
		var s := _signal
		_signal = null
		s.close()
	for id: int in _pcs.keys():
		var pc: Object = _pcs[id]
		pc.call("close")
	_pcs.clear()
	if _rtc != null:
		var rtc := _rtc
		_rtc = null
		rtc.close()
