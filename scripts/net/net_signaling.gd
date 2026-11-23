class_name NetSignaling
extends RefCounted
## W2: the browser side of the LAN relay's signaling channel (relay protocol v1). Owns one WebSocket-like socket that
## the session polls by hand every frame, encodes the client -> relay messages and decodes / validates the relay ->
## client ones. The socket is injectable (socket_factory) because a headless desktop run has no relay: tests pass a
## fake with the same small interface as WebSocketPeer (connect_to_url, poll, get_ready_state, send_text,
## get_available_packet_count, get_packet, close). The encode / decode / validate functions are pure and static.

## The socket reached STATE_OPEN (once per open()).
signal opened
## One valid relay -> client message (ids already converted to int).
signal message_received(msg: Dictionary)
## The socket closed or failed. `was_open` is false when it never opened (relay unreachable). Not emitted by close().
signal closed(was_open: bool)

const PROTO := 1
const DEFAULT_MAX_BYTES := 16384
const STATE_CONNECTING := 0  # WebSocketPeer.STATE_CONNECTING
const STATE_OPEN := 1  # WebSocketPeer.STATE_OPEN
const STATE_CLOSED := 3  # WebSocketPeer.STATE_CLOSED

## Field schemas: name -> "int" | "id" (int >= 0) | "string" | "sdp" (non-empty string) | "urls" (array of strings).
const CLIENT_TO_RELAY := {
	"host": {},
	"join": {},
	"offer": {"to": "int", "sdp": "sdp"},
	"answer": {"to": "int", "sdp": "sdp"},
	"candidate": {"to": "int", "mid": "string", "index": "id", "name": "string"},
}
const RELAY_TO_CLIENT := {
	"id": {"id": "int", "urls": "urls"},
	"peer_joined": {"id": "int"},
	"offer": {"from": "int", "sdp": "sdp"},
	"answer": {"from": "int", "sdp": "sdp"},
	"candidate": {"from": "int", "mid": "string", "index": "id", "name": "string"},
	"peer_left": {"id": "int"},
	"room_full": {},
	"host_gone": {},
	"error": {"code": "string"},
}

## Returns a new socket; empty means a real WebSocketPeer.
var socket_factory: Callable
var max_bytes: int = DEFAULT_MAX_BYTES
## Relay -> client messages refused by decode (malformed, unknown, oversized, binary).
var dropped: int = 0

var _socket: Object
var _was_open: bool = false
var _done: bool = false


func _init(max_message_bytes: int = DEFAULT_MAX_BYTES, factory: Callable = Callable()) -> void:
	max_bytes = max_message_bytes
	socket_factory = factory


## Starts connecting to `url` (ws:// or wss://). Returns OK or an Error code.
func open(url: String) -> int:
	close()
	_socket = socket_factory.call() if socket_factory.is_valid() else WebSocketPeer.new()
	_was_open = false
	_done = false
	if _socket == null:
		return ERR_CANT_CREATE
	var err: int = _socket.connect_to_url(url)
	if err != OK:
		_socket = null
		_done = true
	return err


func is_open() -> bool:
	return _socket != null and not _done and _was_open


## Call every frame. Emits opened / message_received / closed from here only.
func poll() -> void:
	if _socket == null or _done:
		return
	_socket.poll()
	var state: int = _socket.get_ready_state()
	if state == STATE_OPEN and not _was_open:
		_was_open = true
		opened.emit()
	while _socket != null and not _done and _socket.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _socket.get_packet()
		var msg := decode(pkt.get_string_from_utf8(), max_bytes) if pkt.size() <= max_bytes else {}
		if msg.is_empty():
			dropped += 1
		else:
			message_received.emit(msg)
	if _socket != null and not _done and _socket.get_ready_state() == STATE_CLOSED:
		_done = true
		closed.emit(_was_open)


## Encodes and sends one client -> relay message. False (nothing sent) when invalid or not open.
func send(msg: Dictionary) -> bool:
	if not is_open():
		return false
	var text := encode(msg, max_bytes)
	if text.is_empty():
		return false
	return _socket.send_text(text) == OK


## Closes the socket without emitting `closed` (a deliberate leave).
func close() -> void:
	if _socket != null and not _done:
		_socket.close()
	_socket = null
	_done = true


# ---- pure protocol v1 ------------------------------------------------------------------------

## JSON text of a valid client -> relay message, or "" when it fails validation or exceeds max_message_bytes.
static func encode(msg: Dictionary, max_message_bytes: int = DEFAULT_MAX_BYTES) -> String:
	if validate(msg, CLIENT_TO_RELAY) != "":
		return ""
	var text := JSON.stringify(msg)
	if text.to_utf8_buffer().size() > max_message_bytes:
		return ""
	return text


## Parses one relay -> client text frame. Returns the message with integer fields as int, or {} when refused.
static func decode(text: String, max_message_bytes: int = DEFAULT_MAX_BYTES) -> Dictionary:
	if text.is_empty() or text.to_utf8_buffer().size() > max_message_bytes:
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var data: Variant = json.data
	if not data is Dictionary:
		return {}
	var msg: Dictionary = data
	if validate(msg, RELAY_TO_CLIENT, max_message_bytes) != "":
		return {}
	return normalize(msg, RELAY_TO_CLIENT)


## "" when `msg` is a valid message of `schemas` (CLIENT_TO_RELAY or RELAY_TO_CLIENT), else the refusal reason:
## "not_object", "no_type", "unknown_type", "missing_field", "extra_field", "wrong_type", "too_large".
static func validate(msg: Variant, schemas: Dictionary, max_message_bytes: int = DEFAULT_MAX_BYTES) -> String:
	if not msg is Dictionary:
		return "not_object"
	var d: Dictionary = msg
	if not d.has("type") or not d["type"] is String:
		return "no_type"
	var type: String = d["type"]
	if not schemas.has(type):
		return "unknown_type"
	var schema: Dictionary = schemas[type]
	for key in d.keys():
		if not key is String or (key != "type" and not schema.has(key)):
			return "extra_field"
	for field: String in schema.keys():
		if not d.has(field):
			return "missing_field"
		var why := _check_field(d[field], schema[field], max_message_bytes)
		if why != "":
			return why
	return ""


## Copy of a validated message with every integer field as int (JSON numbers arrive as float).
static func normalize(msg: Dictionary, schemas: Dictionary) -> Dictionary:
	var out := msg.duplicate(true)
	var schema: Dictionary = schemas.get(String(msg.get("type", "")), {})
	for field: String in schema.keys():
		if schema[field] in ["int", "id"]:
			out[field] = int(out[field])
		elif schema[field] == "urls":
			out[field] = PackedStringArray(out[field])
	return out


static func _check_field(v: Variant, kind: String, max_message_bytes: int) -> String:
	match kind:
		"int", "id":
			if not _is_integral(v):
				return "wrong_type"
			if kind == "id" and float(v) < 0.0:
				return "wrong_type"
		"string":
			if not v is String:
				return "wrong_type"
		"sdp":
			if not v is String or String(v).is_empty():
				return "wrong_type"
			if String(v).to_utf8_buffer().size() > max_message_bytes:
				return "too_large"
		"urls":
			if not v is Array:
				return "wrong_type"
			for u: Variant in v:
				if not u is String:
					return "wrong_type"
	return ""


static func _is_integral(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		var f: float = v
		return is_finite(f) and f == floorf(f) and absf(f) < 9.0e15
	return false
