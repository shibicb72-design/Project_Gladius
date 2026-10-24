extends "res://tests/test_case.gd"
## GBTN2: host aim authority (spread comes from the host's latest InputFrame, not the client flag) and bot shots
## announced to clients and drawn by them.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const PEER := 77
const PID := 5


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _host_rig() -> Dictionary:
	var root := Node.new()
	_tree().root.add_child(root)
	var director := MatchDirector.new()
	root.add_child(director)
	var bridge := NetMatchBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	bridge.set_physics_process(false)
	bridge.setup(director)
	var pawn: Pawn = _PawnScene.instantiate()
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = Vector3(0, 0.1, 0)
	director.add_player(PID, pawn)
	bridge.register_peer(PEER, PID)
	return {"root": root, "bridge": bridge, "pawn": pawn, "director": director}


func _frame(aim: bool) -> Array:
	var f := InputFrame.new()
	f.aim_pressed = aim
	return f.to_array()


func _fire(bridge: NetMatchBridge, pawn: Pawn, claimed_aimed: bool) -> Dictionary:
	return bridge.host_handle_fire(PEER, pawn.get_muzzle_position(), Vector3(0, 0, -1),
			pawn.loadout.get_active().def.id, claimed_aimed)


func test_host_ignores_client_claimed_aim_when_frame_says_not_aiming() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	bridge.host_note_input(PEER, _frame(false))
	assert_true(_fire(bridge, rig["pawn"], true)["ok"], "shot accepted")
	assert_eq(bridge.last_spread_mult, 1.0, "client aimed=true but frame aim_pressed=false: spread_mult 1.0")
	rig["root"].queue_free()


func test_host_uses_frame_aim_even_when_client_claims_not_aimed() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	bridge.host_note_input(PEER, _frame(true))
	assert_true(_fire(bridge, rig["pawn"], false)["ok"], "shot accepted")
	var want: float = float(DataRegistry.new().get_aim_cfg()["aim_spread_mult"])
	assert_eq(bridge.last_spread_mult, want, "frame aim_pressed=true: aim_spread_mult used")
	assert_true(want < 1.0, "aim_spread_mult is a real tightening")
	rig["root"].queue_free()


func test_bot_shot_is_announced_with_the_bot_player_id_and_client_draws_it() -> void:
	var rig := _host_rig()
	var director: MatchDirector = rig["director"]
	var bot: Pawn = _PawnScene.instantiate()
	(rig["root"] as Node).add_child(bot)
	bot.set_physics_process(false)
	director.add_player(8, bot)
	# Host side: every bot's shot_resolved goes through announce_pawn_shot -> announce_shot (ev_shot payload).
	var host: NetMatchBridge = rig["bridge"]
	var seen: Array = []
	host.shot_announced.connect(func(id: int, o: Vector3, e: Vector3) -> void: seen.append([id, o, e]))
	MatchRoot.wire_bot_shots(host, [bot])
	bot.fire_shot()
	assert_eq(seen.size(), 1, "one bot shot -> one announce_shot")
	assert_eq(seen[0][0] if seen.size() > 0 else -1, 8, "announced with the bot's player id")
	# Client side: the ev_shot signal for that id draws the tracer on the bot pawn.
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.begin()
	var cbot: Pawn = _PawnScene.instantiate()
	m.add_child(cbot)
	m.director.add_player(8, cbot)
	assert_true(not cbot.shot_fx.is_tracer_visible(), "no tracer before the event")
	m._on_remote_shot(8, Vector3(0, 1, 0), Vector3(0, 1, -20))
	assert_true(cbot.shot_fx.is_tracer_visible(), "client draws the tracer on the bot pawn")
	assert_true(cbot.shot_fx.is_flash_visible(), "client draws the muzzle flash on the bot pawn")
	m.queue_free()
	rig["root"].queue_free()
