class_name NetLobby
extends Node
## Networked lobby. The host owns the LobbyState; clients send their own name/class and receive the
## full state back. All lobby RPCs live here (the node exists on every peer before anyone connects).
## Never changes scenes: the UI listens to `match_starting`.
## TODO (OQ-27): join in progress is out of milestone 1; after start the host rejects new joins.

signal state_changed
signal match_starting

const CLASSES: Array[String] = ["hastati", "sagittarii"]

var state := LobbyState.new()
var match_seed: int = 0

var _session: NetSession


func _enter_tree() -> void:
	_session = get_parent() as NetSession
	if _session != null and not _session.peer_left.is_connected(_on_peer_left):
		_session.peer_left.connect(_on_peer_left)
		_session.peer_joined.connect(_on_peer_joined)


func local_id() -> int:
	return _session.get_unique_id() if _session != null else 0




func is_host() -> bool:
	# Unique id 1 is always the server; this also makes an offline (no peer) session a solo host.
	return _session != null and (_session.is_host or local_id() == 1)


## Host only: sets up the lobby and adds the host's own entry.
func host_open(squads: int, squad_size: int, host_name: String, rotation: Array = []) -> void:
	state = LobbyState.new()
	state.setup(squads, squad_size, rotation)
	state.add_human(local_id(), _clean_name(host_name))
	state_changed.emit()


## Sets this peer's own name and class. The host applies it directly, a client asks the host.
func submit_local(player_name: String, class_id: String) -> void:
	if is_host():
		_apply(local_id(), player_name, class_id)
		_broadcast()
	else:
		_request_update.rpc_id(1, player_name, class_id)


func start_match() -> bool:
	if not is_host() or not state.start():
		return false
	match_seed = randi()
	_start_match.rpc(state.to_dict(), match_seed)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_update(player_name: String, class_id: String) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	_apply(sender, player_name, class_id)
	_broadcast()


@rpc("authority", "call_remote", "reliable")
func _sync_state(d: Dictionary) -> void:
	state = LobbyState.from_dict(d)
	state_changed.emit()


@rpc("authority", "call_local", "reliable")
func _start_match(d: Dictionary, seed_value: int) -> void:
	state = LobbyState.from_dict(d)
	match_seed = seed_value
	AppFlow.lobby = state
	AppFlow.match_seed = seed_value
	state_changed.emit()
	match_starting.emit()


## Host only. Adds the sender if new (rejected once started or full), then edits only that entry.
func _apply(peer_id: int, player_name: String, class_id: String) -> void:
	if state.find_human(peer_id) < 0 and not state.add_human(peer_id, _clean_name(player_name)):
		return
	var i := state.find_human(peer_id)
	var clean := _clean_name(player_name)
	if not clean.is_empty() and not state.started:
		state.humans[i]["name"] = clean
	if class_id in CLASSES:
		state.set_class(peer_id, class_id)
	state_changed.emit()


func _clean_name(player_name: String) -> String:
	var max_len: int = int(_session.cfg.get("max_name_length", 24)) if _session != null else 24
	return player_name.strip_edges().substr(0, max_len)


func _broadcast() -> void:
	if is_host():
		_sync_state.rpc(state.to_dict())


func _on_peer_joined(peer_id: int) -> void:
	if is_host():
		_sync_state.rpc_id(peer_id, state.to_dict())


func _on_peer_left(peer_id: int) -> void:
	if is_host():
		state.remove_human(peer_id)
		state_changed.emit()
		_broadcast()
