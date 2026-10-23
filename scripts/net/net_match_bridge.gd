class_name NetMatchBridge
extends Node
## Connects MatchDirector to the network. The host is authoritative for hits, damage, score and
## respawns; clients own their movement (T-03) and send input and fire requests.
## Add as a child named "Bridge" of the NetSession so RPC paths match on every peer.

signal snapshot_received
## Client: the host reports a shot (any shooter) so the flash and tracer can be drawn.
signal shot_event(player_id: int, origin: Vector3, end: Vector3)
## Host: emitted for every shot it reports to the clients (ev_shot payload), whether or not a peer is connected.
signal shot_announced(player_id: int, origin: Vector3, end: Vector3)
signal kill_event(killer_id: int, victim_id: int)
signal respawn_event(player_id: int)
signal match_over_event(result: Dictionary)
signal score_event(new_scores: Dictionary)

var director: MatchDirector
var validator: NetValidator
var registry: DataRegistry = DataRegistry.new()
var snapshot_interval_s: float = 1.0 / 15.0
## Client: seconds between input packets (data/net.json input_rate_hz).
var input_interval_s: float = 1.0 / 15.0
## Host: peer id -> player id.
var peer_to_player: Dictionary = {}
## Client: player id -> {pos, yaw, shield, health, alive} from the latest host snapshot.
var replica: Dictionary = {}
var scores: Dictionary = {}
var last_snapshot_tick: int = -1
## Client: player id of the locally driven pawn (set by MatchRoster).
var local_player_id: int = -1

var _clock: float = 0.0
var _since_snapshot: float = 0.0
var _tick: int = 0
var _last_move_s: Dictionary = {}  # player id -> time of last accepted position
var _last_correction_s: Dictionary = {}  # player id -> _clock of the last correct_position
var _rng :=RandomNumberGenerator.new()
var _last_aim_point: Dictionary = {}  # player id -> camera-centre aim point of the last InputFrame (if it had one)
var _last_aim: Dictionary = {}  # player id -> aim_pressed of the last InputFrame received from that peer
## Spread multiplier used by the most recent host_handle_fire (read by tests).
var last_spread_mult: float = 1.0


## Called by MatchRoot when the match begins. Until then (and after detach) every handler ignores packets.
func setup(match_director: MatchDirector) -> void:
	detach()
	director = match_director
	var cfg := registry.load_file("res://data/net.json")
	validator = NetValidator.new(cfg.get("validation", {}))
	snapshot_interval_s = 1.0 / maxf(float(cfg.get("snapshot_rate_hz", 15)), 1.0)
	input_interval_s = 1.0 / maxf(float(cfg.get("input_rate_hz", cfg.get("snapshot_rate_hz", 15))), 1.0)
	_rng.randomize()
	director.match_over.connect(_host_match_over)
	director.score_changed.connect(_host_score_changed)
	director.player_respawned.connect(_host_respawned)


func detach() -> void:
	if director != null:
		director.match_over.disconnect(_host_match_over)
		director.score_changed.disconnect(_host_score_changed)
		director.player_respawned.disconnect(_host_respawned)
	director = null


func _is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


## False before connecting and after leaving (the tree then holds an offline peer).
func _online() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer \
			and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func register_peer(peer_id: int, player_id: int) -> void:
	peer_to_player[peer_id] = player_id


func unregister_peer(peer_id: int) -> void:
	var pid: int = peer_to_player.get(peer_id, -1)
	peer_to_player.erase(peer_id)
	_last_correction_s.erase(pid)
	if validator != null:
		validator.forget(pid)


# ---- client -> host -------------------------------------------------------------------------

func send_input(frame: InputFrame, pos: Vector3, yaw: float) -> void:
	if not _online():
		return
	_tick += 1
	submit_input.rpc_id(1, frame.to_array(), pos, yaw, _tick)


func send_fire(origin: Vector3, direction: Vector3, weapon_id: String, aimed: bool = false) -> void:
	if not _online():
		return
	_tick += 1
	request_fire.rpc_id(1, origin, direction, weapon_id, _tick, aimed)


func send_reload() -> void:
	if _online():
		request_reload.rpc_id(1)


## Sends the active slot (idempotent, so a repeated request cannot toggle the host weapon back).
func send_weapon_slot(slot: int) -> void:
	if _online():
		request_weapon_slot.rpc_id(1, slot)


@rpc("any_peer", "call_remote", "reliable")
func request_reload() -> void:
	if director != null and _is_host():
		host_handle_reload(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func request_weapon_slot(slot: int) -> void:
	if director != null and _is_host():
		host_handle_weapon_slot(multiplayer.get_remote_sender_id(), slot)


## Host: starts a reload on the host copy of the player's active weapon.
func host_handle_reload(peer_id: int) -> bool:
	var pawn: Pawn = director.player(peer_to_player.get(peer_id, -1)) if director != null else null
	if pawn == null or not pawn.is_alive() or pawn.loadout.get_active() == null:
		return false
	var w := pawn.loadout.get_active()
	w.update(_clock, false)
	return w.start_reload(_clock)


## Host: follows the client's active slot if that slot holds a weapon.
func host_handle_weapon_slot(peer_id: int, slot: int) -> bool:
	var pawn: Pawn = director.player(peer_to_player.get(peer_id, -1)) if director != null else null
	if pawn == null or not pawn.is_alive() or slot < 0 or slot >= pawn.loadout.slots.size() \
			or pawn.loadout.slots[slot] == null:
		return false
	if slot != pawn.loadout.active:
		var old := pawn.loadout.get_active()
		if old != null:
			old.cancel_reload()
		pawn.loadout.active = slot
	return true


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(frame_array: Array, pos: Vector3, yaw: float, _client_tick: int) -> void:
	if director == null or not _is_host():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var pid: int = peer_to_player.get(peer_id, -1)
	if pid < 0 or director.player(pid) == null:
		return
	host_note_input(peer_id, frame_array)
	host_handle_move(peer_id, pos, yaw)


## Host: remembers the peer's latest InputFrame Aim state. It is the only aim source for host_handle_fire.
func host_note_input(peer_id: int, frame_array: Array) -> void:
	var pid: int = peer_to_player.get(peer_id, -1)
	if pid >= 0:
		var f := InputFrame.from_array(frame_array)
		_last_aim[pid] = f.aim_pressed
		if f.has_aim_point:
			_last_aim_point[pid] = f.aim_point
		else:
			_last_aim_point.erase(pid)


## Host: accepts a client position if plausible; otherwise the host position stays authoritative and the
## client is snapped back. Returns whether the move was accepted.
func host_handle_move(peer_id: int, pos: Vector3, yaw: float) -> bool:
	var pid: int = peer_to_player.get(peer_id, -1)
	var pawn: Pawn = director.player(pid) if director != null and pid >= 0 else null
	if pawn == null or not pawn.is_alive():
		return false
	var dt := _clock - float(_last_move_s.get(pid, _clock - 0.1))
	# Reset on every attempt so a repeated far position never ages into acceptance.
	_last_move_s[pid] = _clock
	if validator.validate_move(pawn.global_position, pos, dt, pawn.get_move_speed(),
			float(registry.get_movement_cfg().get("jump_velocity", 0.0)), pawn.floor_max_angle):
		pawn.global_position = pos
		pawn.rotation.y = yaw
		return true
	var last: float = _last_correction_s.get(pid, -INF)
	if _clock - last >= snapshot_interval_s:
		_last_correction_s[pid] = _clock
		if _online():
			correct_position.rpc_id(peer_id, pawn.global_position)
	return false


## Client: the host rejected a move; snap the local pawn to the host position.
@rpc("authority", "call_remote", "reliable")
func correct_position(pos: Vector3) -> void:
	var pawn: Pawn = director.player(local_player_id) if director != null else null
	if pawn == null:
		return
	pawn.global_position = pos
	pawn.velocity = Vector3.ZERO


@rpc("any_peer", "call_remote", "reliable")
func request_fire(origin: Vector3, direction: Vector3, weapon_id: String, _client_tick: int,
		_aimed: bool = false) -> void:
	if director == null or not _is_host():
		return
	host_handle_fire(multiplayer.get_remote_sender_id(), origin, direction, weapon_id)


## Host: validate, raycast on host state and apply DamageRules. Returns {ok, reason, hit}.
## Spread tightens (stats.json aim.aim_spread_mult) from the Aim state of the host's latest received InputFrame
## for this peer; a client-claimed aim flag is ignored (the RPC keeps its signature for compatibility).
func host_handle_fire(peer_id: int, origin: Vector3, direction: Vector3, weapon_id: String,
		_aimed: bool = false) -> Dictionary:
	var pid: int = peer_to_player.get(peer_id, -1)
	var pawn: Pawn = director.player(pid) if director != null and pid >= 0 else null
	if pawn == null or not pawn.is_alive():
		return {"ok": false, "reason": "no_pawn"}
	var w := pawn.loadout.get_active()
	if w == null:
		return {"ok": false, "reason": "wrong_weapon"}
	# The host copy of the weapon is the ammo authority; rate stays with NetValidator (clock skew).
	w.update(_clock, false)
	if w.reloading:
		return {"ok": false, "reason": "reloading"}
	if not w.has_ammo():
		return {"ok": false, "reason": "empty"}
	# Right-shoulder camera: when the client sent an aim point, the shot goes from the host muzzle to that point
	# (the claimed direction is ignored); a point whose muzzle ray is blocked spawns no shot. Checked before
	# validate_fire so a rejected aim does not use up the fire-rate window.
	var muzzle := pawn.get_muzzle_position()
	var has_point := _last_aim_point.has(pid)
	if has_point:
		var aim_ok := AimMath.validate_aim(pawn.get_world_3d().direct_space_state, muzzle, _last_aim_point[pid],
				float(registry.get_camera_cfg()["aim_validate_epsilon_m"]["value"]), pawn.hitscan_exclude())
		if not aim_ok["ok"]:
			push_warning("fire rejected for player %d: %s (aim point %s)" % [pid, aim_ok["reason"], _last_aim_point[pid]])
			return aim_ok
	var v := validator.validate_fire(pid, weapon_id, w.def, _clock, origin, muzzle, direction)
	if not v["ok"]:
		return v
	if has_point:
		origin = muzzle
		direction = (_last_aim_point[pid] - muzzle).normalized()
	pawn.fired.emit()  # ends spawn protection through MatchDirector, same as a local shot
	if w.def.is_melee():
		# Energy blade (OQ-07): no ammo; the host runs the swing on its own pawn states.
		v["hit"] = pawn.melee_swing(w.def, origin, direction, Callable(self, "_host_authority"))
		return v
	w.ammo_in_mag -= 1
	var spread_mult: float = float(DataRegistry.new().get_aim_cfg()["aim_spread_mult"]) \
			if _last_aim.get(pid, false) else 1.0
	last_spread_mult = spread_mult
	var hit := Hitscan.fire(pawn.get_world_3d().direct_space_state, pawn, origin, direction, w.def,
			pawn.hitscan_exclude(),
			Callable(self, "_host_authority"), _rng, spread_mult)
	v["hit"] = hit
	var end: Vector3 = hit["position"] if hit.has("position") else origin + direction.normalized() * w.def.range_m
	pawn.show_shot_fx(origin, end)
	announce_shot(pid, origin, end)
	return v


## Host: tells every client about a shot so they draw the flash and tracer (the shooter ignores its own).
func announce_shot(player_id: int, origin: Vector3, end: Vector3) -> void:
	shot_announced.emit(player_id, origin, end)
	if multiplayer.multiplayer_peer != null and _is_host():
		ev_shot.rpc(player_id, origin, end)


func announce_pawn_shot(pawn: Pawn, origin: Vector3, end: Vector3) -> void:
	announce_shot(_player_id_of(pawn), origin, end)


@rpc("authority", "call_remote", "unreliable")
func ev_shot(player_id: int, origin: Vector3, end: Vector3) -> void:
	shot_event.emit(player_id, origin, end)


func _host_authority(attacker: Node, target: Node, weapon_def: WeaponDef, is_headshot: bool) -> void:
	var res: DamageRules.HitResult
	if weapon_def.is_melee() and attacker is Pawn and target.has_method("receive_melee"):
		res = target.receive_melee(attacker)
	else:
		res = target.receive_hit(weapon_def, is_headshot, attacker.squad_id)
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
	if director == null:
		return
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


## Client: shield, health and alive of the local pawn come from the host; its position stays its own.
func apply_local_vitals(local_player_id: int) -> void:
	var pawn: Pawn = director.player(local_player_id) if director != null else null
	if pawn == null or not replica.has(local_player_id) or not replica[local_player_id].has("alive"):
		return
	var r: Dictionary = replica[local_player_id]
	pawn.bridge.state.shield = r["shield"]
	pawn.bridge.state.health = r["health"]
	if bool(r["alive"]) != pawn.visible:
		pawn.set_active(r["alive"])


## Client: puts the local pawn on the host's position for it (spawn / respawn), so the host's
## movement check accepts the next input.
func snap_local_to_replica(local_player_id: int) -> void:
	var pawn: Pawn = director.player(local_player_id) if director != null else null
	if pawn == null or not replica.has(local_player_id) or not replica[local_player_id].has("pos"):
		return
	var r: Dictionary = replica[local_player_id]
	pawn.global_position = r["pos"]
	pawn.rotation.y = r["yaw"]
	pawn.velocity = Vector3.ZERO


func _host_score_changed(new_scores: Dictionary) -> void:
	if _is_host():
		ev_score.rpc(new_scores)


func _host_respawned(player_id: int) -> void:
	if _is_host():
		var pawn := director.player(player_id)
		ev_respawn.rpc(player_id, pawn.global_position, pawn.rotation.y)


func _host_match_over(result: Dictionary) -> void:
	if _is_host():
		ev_match_over.rpc(result)


@rpc("authority", "call_remote", "reliable")
func ev_kill(killer_id: int, victim_id: int) -> void:
	kill_event.emit(killer_id, victim_id)


@rpc("authority", "call_remote", "reliable")
func ev_respawn(player_id: int, pos: Vector3 = Vector3.INF, yaw: float = 0.0) -> void:
	if pos.is_finite():
		# The spawn position rides on the event so the client can snap to it before the next snapshot.
		var r: Dictionary = replica.get(player_id, {})
		r["pos"] = pos
		r["yaw"] = yaw
		replica[player_id] = r
	respawn_event.emit(player_id)


@rpc("authority", "call_remote", "reliable")
func ev_score(new_scores: Dictionary) -> void:
	scores = new_scores
	score_event.emit(new_scores)


@rpc("authority", "call_remote", "reliable")
func ev_match_over(result: Dictionary) -> void:
	match_over_event.emit(result)
