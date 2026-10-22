class_name NetSession
extends Node
## Host/join/leave over ENet using Godot's high-level multiplayer API only.

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connected
signal failed
signal host_lost

const NET_PATH := "res://data/net.json"
const MATCH_PATH := "res://data/match.json"

## When true the session owns a private SceneMultiplayer for its own subtree (used to run a host and a
## client in one process). Set before adding to the tree.
var isolated: bool = false
var cfg: Dictionary = {}
var is_host: bool = false
var lobby: NetLobby

var _mp: SceneMultiplayer
var _peer: ENetMultiplayerPeer
var _connecting_since_ms: int = -1


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
	_mp.server_disconnected.connect(func() -> void: host_lost.emit())
	# Same node path on every peer, before anyone connects (RPC target must exist on the receiver).
	if lobby == null:
		lobby = NetLobby.new()
		lobby.name = "Lobby"
		add_child(lobby)


func max_clients() -> int:
	var max_humans: int = int(DataRegistry.new().load_file(MATCH_PATH).get("max_humans", 6))
	return maxi(max_humans - 1, 1)


func get_port() -> int:
	return int(cfg.get("port", 7777))


## Returns OK or an Error code.
func host_game(port: int = -1) -> int:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port if port > 0 else get_port(), max_clients())
	if err != OK:
		_peer = null
		return err
	_mp.multiplayer_peer = _peer
	is_host = true
	return OK


## Starts connecting; `connected` or `failed` fires later (failure includes the timeout).
func join_game(address: String, port: int = -1) -> int:
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
	if _mp != null:
		_mp.multiplayer_peer = null
	_peer = null
	is_host = false


func get_unique_id() -> int:
	return _mp.get_unique_id() if _mp != null and _mp.multiplayer_peer != null else 0


func is_connected_to_host() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _process(_delta: float) -> void:
	if _connecting_since_ms < 0:
		return
	var timeout_ms := int(float(cfg.get("connect_timeout_s", 5.0)) * 1000.0)
	if Time.get_ticks_msec() - _connecting_since_ms > timeout_ms:
		_on_failed()


func _on_connected() -> void:
	_connecting_since_ms = -1
	connected.emit()


func _on_failed() -> void:
	if _connecting_since_ms < 0 and _peer == null:
		return
	leave()
	failed.emit()
