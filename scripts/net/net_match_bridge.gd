class_name NetMatchBridge
extends Node
## Connects MatchDirector to the network. The host is authoritative for hits, damage, score and
## respawns; clients own their movement (T-03) and send input and fire requests.
## Add as a child named "Bridge" of the NetSession so RPC paths match on every peer.

signal snapshot_received
signal kill_event(killer_id: int, victim_id: int)
signal respawn_event(player_id: int)
signal match_over_event(result: Dictionary)

var director: MatchDirector
var validator: NetValidator
var registry: DataRegistry = DataRegistry.new()
var snapshot_interval_s: float = 1.0 / 15.0
## Host: peer id -> player id.
var peer_to_player: Dictionary = {}
## Host: latest InputFrame per player id.
var last_frames: Dictionary = {}
## Client: player id -> {pos, yaw, shield, health, alive} from the latest host snapshot.
var replica: Dictionary = {}
var scores: Dictionary = {}
var last_snapshot_tick: int = -1

var _clock: float = 0.0
var _since_snapshot: float = 0.0
var _tick: int = 0
var _last_move_s: Dictionary = {}  # player id -> time of last accepted position
var _rng := RandomNumberGenerator.new()


func setup(match_director: MatchDirector) -> void:
	director = match_director
	var cfg := registry.load_file("res://data/net.json")
	validator = NetValidator.new(cfg.get("validation", {}))
	snapshot_interval_s = 1.0 / maxf(float(cfg.get("snapshot_rate_hz", 15)), 1.0)
	_rng.randomize()
	director.match_over.connect(_host_match_over)
	director.score_changed.connect(_host_score_changed)
	director.player_respawned.connect(_host_respawned)


func _is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func register_peer(peer_id: int, player_id: int) -> void:
	peer_to_player[peer_id] = player_id


func unregister_peer(peer_id: int) -> void:
	var pid: int = peer_to_player.get(peer_id, -1)
	peer_to_player.erase(peer_id)
	last_frames.erase(pid)
	validator.forget(pid)


# ---- client -> host -------------------------------------------------------------------------

func send_input(frame: InputFrame, pos: Vector3, yaw: float) -> void:
	_tick += 1
	submit_input.rpc_id(1, frame.to_array(), pos, yaw, _tick)


func send_fire(origin: Vector3, direction: Vector3, weapon_id: String) -> void:
	_tick += 1
	request_fire.rpc_id(1, origin, direction, weapon_id, _tick)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(frame_array: Array, pos: Vector3, yaw: float, _client_tick: int) -> void:
	if not _is_host():
		return
	var pid: int = peer_to_player.get(multiplayer.get_remote_sender_id(), -1)
	var pawn: Pawn = director.player(pid) if pid >= 0 else null
	if pawn == null:
		return
	last_frames[pid] = InputFrame.from_array(frame_array)
	var dt := _clock - float(_last_move_s.get(pid, _clock - 0.1))
	if pawn.is_alive() and validator.validate_move(pawn.global_position, pos, dt, pawn.get_move_speed()):
		pawn.global_position = pos
		pawn.rotation.y = yaw
		_last_move_s[pid] = _clock


@rpc("any_peer", "call_remote", "reliable")
func request_fire(origin: Vector3, direction: Vector3, weapon_id: String, _client_tick: int) -> void:
	if not _is_host():
		return
	host_handle_fire(multiplayer.get_remote_sender_id(), origin, direction, weapon_id)


## Host: validate, raycast on host state and apply DamageRules. Returns {ok, reason, hit}.
func host_handle_fire(peer_id: int, origin: Vector3, direction: Vector3, weapon_id: String) -> Dictionary:
	var pid: int = peer_to_player.get(peer_id, -1)
	var pawn: Pawn = director.player(pid) if pid >= 0 else null
	if pawn == null or not pawn.is_alive():
		return {"ok": false, "reason": "no_pawn"}
	var w := pawn.loadout.get_active()
	var v := validator.validate_fire(pid, weapon_id, w.def if w != null else null, _clock, origin,
			pawn.get_muzzle_position(), direction)
	if not v["ok"]:
		return v
	var exclude: Array[RID] = [pawn.get_rid()]
	var hit := Hitscan.fire(pawn.get_world_3d().direct_space_state, pawn, origin, direction, w.def, exclude,
			Callable(self, "_host_authority"), _rng)
	v["hit"] = hit
	return v


func _host_authority(attacker: Node, target: Node, weapon_def: WeaponDef, is_headshot: bool) -> void:
	var res: DamageRules.HitResult = target.receive_hit(weapon_def, is_headshot, attacker.squad_id)
	if res.killed:
		var killer := _player_id_of(attacker)
		var victim := _player_id_of(target)
		kill_event.emit(killer, victim)
		if multiplayer.multiplayer_peer != null:
			ev_kill.rpc(killer, victim)


func _player_id_of(pawn: Node) -> int:
	for id in director.all_players():
		if director.all_players()[id] == pawn:
			return id
	return -1


# ---- host -> clients -----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_clock += delta
	if director == null or not _is_host():
		return
	_since_snapshot += delta
	if _since_snapshot >= snapshot_interval_s:
		_since_snapshot = 0.0
		_tick += 1
		snapshot.rpc(_tick, build_snapshot())


## One entry per player: [player_id, pos, yaw, shield, health, alive].
func build_snapshot() -> Array:
	var out: Array = []
	for id in director.all_players():
		var p: Pawn = director.all_players()[id]
		out.append([id, p.global_position, p.rotation.y, p.bridge.state.shield, p.bridge.state.health,
				p.is_alive()])
	return out


@rpc("authority", "call_remote", "unreliable_ordered")
func snapshot(tick: int, entries: Array) -> void:
	last_snapshot_tick = tick
	for e in entries:
		replica[int(e[0])] = {"pos": e[1], "yaw": float(e[2]), "shield": float(e[3]), "health": float(e[4]),
				"alive": bool(e[5])}
	snapshot_received.emit()


## Client: copies the replicated state onto pawns that are not driven locally.
func apply_replica(local_player_id: int) -> void:
	for id in replica:
		var pawn: Pawn = director.player(id)
		if pawn == null or id == local_player_id:
			continue
		var r: Dictionary = replica[id]
		pawn.global_position = r["pos"]
		pawn.rotation.y = r["yaw"]
		pawn.bridge.state.shield = r["shield"]
		pawn.bridge.state.health = r["health"]
		pawn.set_active(r["alive"])


func _host_score_changed(new_scores: Dictionary) -> void:
	if _is_host():
		ev_score.rpc(new_scores)


func _host_respawned(player_id: int) -> void:
	if _is_host():
		ev_respawn.rpc(player_id)


func _host_match_over(result: Dictionary) -> void:
	if _is_host():
		ev_match_over.rpc(result)


@rpc("authority", "call_remote", "reliable")
func ev_kill(killer_id: int, victim_id: int) -> void:
	kill_event.emit(killer_id, victim_id)


@rpc("authority", "call_remote", "reliable")
func ev_respawn(player_id: int) -> void:
	respawn_event.emit(player_id)


@rpc("authority", "call_remote", "reliable")
func ev_score(new_scores: Dictionary) -> void:
	scores = new_scores


@rpc("authority", "call_remote", "reliable")
func ev_match_over(result: Dictionary) -> void:
	match_over_event.emit(result)
