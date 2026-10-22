class_name MatchRoster
extends RefCounted
## Builds the pawn set of a lobby match (one pawn per slot) and wires the network bridge.
## The match scene stays small; this holds the per-human / per-bot setup and the bridge attach.

const _PawnScene := preload("res://scenes/player/pawn.tscn")

var local_pawn: Pawn
var local_player_id: int = -1
var bots: Array[Pawn] = []
var bridge: NetMatchBridge
var session: NetSession
var _director: MatchDirector


## Slot with this peer id; offline (peer id 0) or unknown ids fall back to the first human.
static func local_slot(slots: Array, peer_id: int) -> int:
	var first_human := -1
	for i in slots.size():
		if bool(slots[i]["is_bot"]):
			continue
		if first_human < 0:
			first_human = i
		if peer_id != 0 and int(slots[i]["peer_id"]) == peer_id:
			return i
	return first_human


## One pawn per slot under `parent`, registered with the director under the lobby's player id.
## Only the local pawn is left without a brain; bots get one when `bot_brains` (host / offline).
func build(parent: Node, director: MatchDirector, slots: Array, local_peer: int, bot_brains: bool,
		include_bots: bool, hill_center: Vector3, hill_radius: float, networked: bool = false) -> void:
	_director = director
	var local_i := local_slot(slots, local_peer)
	for i in slots.size():
		var s: Dictionary = slots[i]
		var is_bot: bool = s["is_bot"]
		if is_bot and not include_bots:
			continue
		var pawn: Pawn = _PawnScene.instantiate()
		pawn.class_id = str(s["class_id"])
		pawn.squad_id = int(s["squad_id"])
		pawn.name = ("Bot%d" if is_bot else "Player%d") % int(s["player_id"])
		parent.add_child(pawn)
		director.add_player(int(s["player_id"]), pawn)
		if is_bot:
			bots.append(pawn)
			if bot_brains:
				BotSpawner.attach_brain(pawn, director, hill_center, hill_radius)
		elif i == local_i:
			local_pawn = pawn
			local_player_id = int(s["player_id"])
			if networked and not bot_brains:
				# Client: local hitscan is presentation only; damage comes from the host.
				pawn.hit_authority = Callable()
		if networked and i != local_i and (not is_bot or not bot_brains):
			# bot_brains is true exactly on the host / offline; host bots keep their brains (LOCAL).
			pawn.net_mode = Pawn.NetMode.HOST_REMOTE if bot_brains else Pawn.NetMode.REPLICA


## Wires the session's bridge to the director. Host registers every remote human; a client replays
## host events through the passive director.
func attach_bridge(net_session: NetSession, slots: Array) -> void:
	session = net_session
	bridge = session.bridge
	bridge.setup(_director)
	bridge.local_player_id = local_player_id
	if session.is_host:
		for s in slots:
			if not bool(s["is_bot"]) and int(s["player_id"]) != local_player_id:
				bridge.register_peer(int(s["peer_id"]), int(s["player_id"]))
		session.peer_left.connect(_on_peer_left)
	else:
		bridge.score_event.connect(_director.apply_remote_score)
		bridge.respawn_event.connect(_director.apply_remote_respawn)
		bridge.match_over_event.connect(_director.apply_remote_match_over)


func detach_bridge() -> void:
	if bridge == null or not is_instance_valid(bridge):
		return
	bridge.detach()
	if session.peer_left.is_connected(_on_peer_left):
		session.peer_left.disconnect(_on_peer_left)
	for pair in [[bridge.score_event, _director.apply_remote_score],
			[bridge.respawn_event, _director.apply_remote_respawn],
			[bridge.match_over_event, _director.apply_remote_match_over]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	bridge = null


func _on_peer_left(peer_id: int) -> void:
	var pid: int = bridge.peer_to_player.get(peer_id, -1)
	bridge.unregister_peer(peer_id)
	var pawn := _director.player(pid) if pid >= 0 else null
	if pawn != null:
		# TODO(OQ-27): DESIGN.md says "Quitter replaced by bot"; in-match drop handling is out of
		# milestone 1, so the pawn is only marked inactive for now.
		pawn.set_active(false)
