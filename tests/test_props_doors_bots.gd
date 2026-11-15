extends "res://tests/test_case.gd"
## M2 L1c commit 4: bots open a closed door on their path (MatchDirector._bot_doors, data/props.json door
## bot_open_delay_s, OQ-PROPS-DOOR). Covered: the timing rule from the data (delay + move time under bots.json
## stuck_window_s, both kinds); the crossing test (MatchDirector.path_crosses_door) on hand-made paths; the director
## pass driven by hand on a real NavigationAgent3D path (the delay in whole ticks, the count resetting when the bot
## leaves or stops, a bot walking past along the wall, a client, an open door never closed); and real-physics walks
## of a bot brain through a closed door and a closed gate (the door opens, the bot arrives, the brain's unstick never
## starts) and past a closed door along its wall (it stays closed).
## The fixture (ground, a wall with one opening, its own baked NavigationRegion3D; the door outside it, as on the
## map) stands at FX, far from the test map; the match's own bots are parked with their brains off.

const _MatchScene := preload("res://scenes/match/match.tscn")
const FX := Vector3(400.0, 0.0, 400.0)

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


func dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


## A brain whose goal is fixed (the walk under test); everything else is the real BotBrain (path following, the
## stuck window and the unstick).
class FixedGoalBrain extends BotBrain:
	var fixed_goal := Vector3.ZERO

	func _goal(_enemy: Pawn, _melee_only: bool) -> Vector3:
		_fight_hold = false
		_fight_mode = ""
		goal_kind = "test"
		return fixed_goal


static func calm_zone() -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 80.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 200.0, "radius_m": 40.0, "damage_per_s": 0.0}]}


## A match on the test map: every bot brain off, every bot and the human parked far from the fixture.
func start() -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = false
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = calm_zone()
	assert_true(m.begin(), "begin")
	var i := 0
	for b in m.bots:
		b.get_node("Brain").set_physics_process(false)
		b.set_frame(InputFrame.new())
		b.global_position = Vector3(-70.0 + float(i % 6) * 4.0, 0.2, 60.0 + float(i / 6) * 4.0)
		i += 1
	m.local_player.global_position = Vector3(70.0, 0.2, -70.0)
	await frames(2)


func _box(parent: Node, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = at


## Where fixture `i` stands (60 m apart along x from FX).
static func origin(i: int) -> Vector3:
	return FX + Vector3(60.0 * float(i), 0.0, 0.0)


## One fixture per kind, fixture i at origin(i): a 40 m ground and a wall along x (z 0, 0.4 m thick) with one
## opening the door's width, both under that fixture's baked NavigationRegion3D; the door (closed, threshold at y 0)
## in the opening under a Props sibling (outside the region, as on the map). Built BEFORE the match: with the test
## match in the tree a newly baked region was never published on the navigation map (measured; not investigated).
func fixture(kinds: Array) -> Array[Door]:
	var root := Node3D.new()
	root.name = "DoorFixture"
	tree().root.add_child(root)
	var out: Array[Door] = []
	for i in kinds.size():
		out.append(await _one_fixture(root, String(kinds[i]), origin(i)))
	return out


func _one_fixture(root: Node3D, kind: String, o: Vector3) -> Door:
	var nav := NavigationRegion3D.new()
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.navigation_mesh = mesh
	root.add_child(nav)
	var size := Vector3(2.0, 2.3, 0.12) if kind == Door.KIND_DOOR else Vector3(4.0, 4.5, 0.25)
	_box(nav, o + Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	var side := (20.0 - size.x * 0.5)
	for s: float in [-1.0, 1.0]:
		_box(nav, o + Vector3(s * (size.x * 0.5 + side * 0.5), size.y * 0.5 + 0.5, 0), Vector3(side, size.y + 1.0, 0.4))
	var props := Node3D.new()
	root.add_child(props)
	var entry := {"id": "Door_970" if kind == Door.KIND_DOOR else "Gate_970", "kind": kind,
			"at": [o.x, size.y * 0.5, o.z], "yaw": 0.0, "size": [size.x, size.y, size.z],
			"slide": "right" if kind == Door.KIND_DOOR else "apart", "start": "closed"}
	var door := Door.make(entry, WorldProps.door_cfg(WorldProps.config(), kind))
	props.add_child(door)
	await tree().physics_frame
	nav.bake_navigation_mesh(false)
	# The server publishes the region in a later (asynchronous) iteration: wait until it owns a point beside the wall.
	var probe := o + Vector3(0, 0.1, 5)
	var nav_map := nav.get_navigation_map()
	for i in Engine.physics_ticks_per_second * 3:
		await tree().physics_frame
		await tree().process_frame
		if NavigationServer3D.map_get_closest_point_owner(nav_map, probe) == nav.get_rid():
			break
	assert_true(NavigationServer3D.map_get_closest_point_owner(nav_map, probe) == nav.get_rid(), "%s: the fixture is on the navigation map" % kind)
	var through := NavigationServer3D.map_get_path(nav_map, o + Vector3(0, 0, 5), o + Vector3(0, 0, -5), true)
	var end := through[through.size() - 1] if through.size() > 0 else Vector3.INF
	assert_true(through.size() >= 2 and Vector2(end.x - o.x, end.z - (o.z - 5.0)).length() < 0.5, "%s: the nav path runs through the opening (doors are not in the bake)" % kind)
	assert_true(door.blocks(), "%s: its collider is on" % kind)
	return door


## The fixtures first (their regions published), then the match; the doors registered with the match's WorldProps.
func start_with(kinds: Array) -> Array[Door]:
	var doors := await fixture(kinds)
	await start()
	for door in doors:
		m.world_props.register_door(door)
		assert_eq(m.world_props.state_of(door.prop_id), WorldProps.CLOSED, "%s starts closed" % door.prop_id)
	return doors


func _free_fixture() -> void:
	var root := tree().root.get_node_or_null("DoorFixture")
	if root != null:
		root.queue_free()
	if m != null:
		m.queue_free()
	await frames(2)


## Replaces `bot`'s own Brain by a FixedGoalBrain named Brain (the director's bot test), physics on or off.
func fixed_brain(bot: Pawn, goal: Vector3, run: bool) -> FixedGoalBrain:
	var old := bot.get_node("Brain")
	bot.remove_child(old)
	old.free()
	var bots: Dictionary = DataRegistry.new().load_file("res://data/bots.json")
	var b := FixedGoalBrain.new()
	b.name = "Brain"
	b.fixed_goal = goal
	b.setup(bot, m.director, bots.get("profiles", {}).get("tiro", {}), bots.get("brain", {}).duplicate(true))
	bot.add_child(b)
	b.set_physics_process(run)
	return b


static func brain_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/bots.json").get("brain", {})


# ---- Timing (binding) ----

func test_delay_plus_move_time_stays_under_the_stuck_window_for_both_kinds() -> void:
	var window := float(brain_cfg().get("stuck_window_s", 0.0))
	assert_true(window > 0.0, "nonvacuous: bots.json brain.stuck_window_s is %.2f" % window)
	for kind: String in [Door.KIND_DOOR, Door.KIND_GATE]:
		var c := WorldProps.door_cfg(WorldProps.config(), kind)
		assert_true(c.has("bot_open_delay_s") and c.has("move_time_s"), "%s: both numbers are in the data" % kind)
		var delay := float(c.get("bot_open_delay_s", -1.0))
		var move := float(c.get("move_time_s", -1.0))
		assert_true(delay > 0.0 and move > 0.0, "%s: delay %.2f s and move %.2f s are > 0" % [kind, delay, move])
		assert_true(delay + move < window, "%s: delay %.2f + move %.2f = %.2f s < stuck_window_s %.2f" % [kind, delay, move, delay + move, window])
		print("DOORS_BOT_TIMING kind=%s delay_s=%.2f move_s=%.2f sum_s=%.2f stuck_window_s=%.2f" % [kind, delay, move, delay + move, window])


# ---- The crossing test ----

func test_path_crosses_door_only_through_the_opening_ahead() -> void:
	var root := Node3D.new()
	tree().root.add_child(root)
	var door := Door.make({"id": "Door_971", "kind": "door", "at": [10.0, 1.15, 5.0], "yaw": 90.0, "size": [2.0, 2.3, 0.12],
			"slide": "right", "start": "closed"}, WorldProps.door_cfg(WorldProps.config(), Door.KIND_DOOR))
	root.add_child(door)
	# yaw 90: the door's plane (local z = 0) is world x = 10 and the opening (local x within +-1) spans world z 4..6.
	var from := Vector3(11.5, 0.0, 5.0)
	var through := PackedVector3Array([Vector3(11.5, 0.0, 5.0), Vector3(8.0, 0.0, 5.2), Vector3(4.0, 0.0, 9.0)])
	assert_true(MatchDirector.path_crosses_door(door, from, through, 1), "a path through the opening crosses")
	assert_true(MatchDirector.path_crosses_door(door, Vector3(11.5, 0.0, 4.6), through, 1), "from beside the centre too")
	var along := PackedVector3Array([Vector3(11.0, 0.0, 0.0), Vector3(11.0, 0.0, 10.0)])
	assert_true(not MatchDirector.path_crosses_door(door, Vector3(11.0, 0.0, 2.0), along, 1), "along the wall: no")
	var wall := PackedVector3Array([Vector3(11.5, 0.0, 9.0), Vector3(8.0, 0.0, 9.0)])
	assert_true(not MatchDirector.path_crosses_door(door, Vector3(11.5, 0.0, 9.0), wall, 1), "through the wall beside the opening: no")
	var away := PackedVector3Array([Vector3(11.5, 0.0, 5.0), Vector3(16.0, 0.0, 5.0)])
	assert_true(not MatchDirector.path_crosses_door(door, from, away, 1), "away from the door: no")
	assert_true(not MatchDirector.path_crosses_door(door, from, through, 3), "the path behind (index past its end): no")
	assert_true(not MatchDirector.path_crosses_door(door, from, PackedVector3Array(), 0), "no path: no")
	var above := PackedVector3Array([Vector3(11.5, 6.0, 5.0), Vector3(8.0, 6.0, 5.0)])
	assert_true(not MatchDirector.path_crosses_door(door, Vector3(11.5, 6.0, 5.0), above, 1), "a floor above: no")
	var far := PackedVector3Array([Vector3(11.5, 0.0, 5.0), Vector3(30.0, 0.0, 5.0), Vector3(30.0, 0.0, 30.0), Vector3(-20.0, 0.0, 5.0)])
	assert_true(not MatchDirector.path_crosses_door(door, from, far, 1), "a crossing beyond the lookahead: no")
	root.free()


# ---- The director pass, driven by hand on a real agent path ----

## Points `bot` (brain off) at `goal`: the brain's agent plans the path, and the bot's move input is set.
func _plan(b: BotBrain, goal: Vector3) -> void:
	var agent: NavigationAgent3D = b.get("_agent")
	agent.target_position = goal
	agent.get_next_path_position()  # the test plans the path; the director only reads it
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)
	b.pawn.set_frame(f)


func test_director_pass_delay_reset_walk_past_client_and_never_closes() -> void:
	var door: Door = (await start_with([Door.KIND_DOOR]))[0]
	var props := m.world_props
	var bot: Pawn = m.bots[0]
	var b := fixed_brain(bot, FX + Vector3(0, 0, -6), false)
	await frames(1)
	bot.global_position = FX + Vector3(0.0, 0.05, 1.5)
	bot.velocity = Vector3.ZERO
	_plan(b, FX + Vector3(0, 0, -6))
	var agent: NavigationAgent3D = b.get("_agent")
	assert_true(agent.get_current_navigation_path().size() >= 2, "nonvacuous: a nav path (%d points)" % agent.get_current_navigation_path().size())
	assert_true(MatchDirector.path_crosses_door(door, bot.global_position, agent.get_current_navigation_path(), agent.get_current_navigation_path_index()), "the path runs through the doorway")
	var delay := float(WorldProps.door_cfg(props.cfg, Door.KIND_DOOR)["bot_open_delay_s"])
	var ticks := ceili(delay * float(Engine.physics_ticks_per_second) - 0.001)
	assert_true(ticks > 1, "nonvacuous: the delay is %d ticks" % ticks)
	var d0 := m.director.bot_doors_opened
	# The delay: closed through ticks - 1 passes, open on the next.
	for i in ticks - 1:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "still closed after %d ticks" % (ticks - 1))
	m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.OPEN, "open on tick %d" % ticks)
	assert_eq(m.director.bot_doors_opened, d0 + 1, "counted once")
	# Bots never close a door.
	for i in ticks * 3:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.OPEN, "an open door stays open")
	assert_eq(m.director.bot_doors_opened, d0 + 1, "and nothing more is counted")
	# The count resets when the bot leaves range ...
	props.set_door(door.prop_id, WorldProps.CLOSED)
	for i in ticks - 1:
		m.director._bot_doors()
	bot.global_position = FX + Vector3(0.0, 0.05, 5.0)  # out of the door's 2 m range
	m.director._bot_doors()
	bot.global_position = FX + Vector3(0.0, 0.05, 1.5)
	for i in ticks - 1:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "the count restarted after the bot left")
	m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.OPEN, "and runs out again")
	# ... and when it stops walking (no move input).
	props.set_door(door.prop_id, WorldProps.CLOSED)
	for i in ticks - 1:
		m.director._bot_doors()
	bot.set_frame(InputFrame.new())
	for i in ticks * 2:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "a bot standing still opens nothing")
	_plan(b, FX + Vector3(0, 0, -6))
	# A client does nothing.
	m.director.authoritative = false
	for i in ticks * 2:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "not authoritative: nothing opens")
	m.director.authoritative = true
	# Walking past along the wall (1 m in front of it, in range): never opened.
	bot.global_position = FX + Vector3(-1.5, 0.05, 1.0)
	_plan(b, FX + Vector3(6.0, 0.0, 1.0))
	assert_true(door.distance_to(bot.global_position) <= door.interact_range_m, "nonvacuous: the bot is in the door's range")
	assert_true(agent.get_current_navigation_path().size() >= 2, "nonvacuous: a nav path along the wall")
	for i in ticks * 3:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "a bot walking past along the wall does not open it")
	# A dead bot opens nothing.
	bot.global_position = FX + Vector3(0.0, 0.05, 1.5)
	_plan(b, FX + Vector3(0, 0, -6))
	bot.life = Pawn.Life.DEAD
	for i in ticks * 2:
		m.director._bot_doors()
	assert_eq(props.state_of(door.prop_id), WorldProps.CLOSED, "a dead bot opens nothing")
	bot.life = Pawn.Life.ALIVE
	await _free_fixture()


# ---- Real physics: a bot brain walks through ----

## Walks `bot` with a real brain (physics on: the brain, the pawn, the director's pass and the door all run on their
## own ticks) from `from` to `to` (offsets from the door's fixture origin `o`) for at most `limit_s`.
func _walk(bot: Pawn, door: Door, o: Vector3, from: Vector3, to: Vector3, limit_s: float) -> Dictionary:
	var kind := door.kind
	bot.global_position = o + from + Vector3(0, 0.1, 0)
	bot.velocity = Vector3.ZERO
	bot.look_at(o + to + Vector3(0, 0.1, 0), Vector3.UP)
	var b := fixed_brain(bot, o + to, true)
	var d0 := m.director.bot_doors_opened
	var out := {"arrived": false, "unstick_ticks": 0, "opened_tick": -1, "range_tick": -1, "ticks": 0, "door_waits": 0}
	var n := ceili(limit_s / dt())
	for t in n:
		await tree().physics_frame
		out["ticks"] = t + 1
		if b._unstick_left > 0.0:
			out["unstick_ticks"] = int(out["unstick_ticks"]) + 1
		if int(out["range_tick"]) < 0 and door.distance_to(bot.global_position) <= door.interact_range_m:
			out["range_tick"] = t
		if int(out["opened_tick"]) < 0 and m.world_props.state_of(door.prop_id) == WorldProps.OPEN:
			out["opened_tick"] = t
		if Vector2(bot.global_position.x - (o + to).x, bot.global_position.z - (o + to).z).length() < 0.5:
			out["arrived"] = true
			break
	out["state"] = m.world_props.state_of(door.prop_id)
	out["by_bots"] = m.director.bot_doors_opened - d0
	out["door_waits"] = door.waits
	out["end"] = bot.global_position - o
	b.set_physics_process(false)
	bot.set_frame(InputFrame.new())
	print("DOORS_BOT_WALK kind=%s from=%s to=%s %s" % [kind, from, to, out])
	return out


func test_bot_brain_walks_through_a_closed_door_without_an_unstick() -> void:
	var doors := await start_with([Door.KIND_DOOR, Door.KIND_GATE])
	for i in doors.size():
		var kind := doors[i].kind
		var r: Dictionary = await _walk(m.bots[i], doors[i], origin(i), Vector3(0.3, 0, 7.0), Vector3(-0.3, 0, -7.0), 10.0)
		assert_eq(int(r["by_bots"]), 1, "%s: the bot pass opened it once" % kind)
		assert_true(int(r["opened_tick"]) >= 0 and int(r["range_tick"]) >= 0, "%s: it came in range and the door opened" % kind)
		assert_true(int(r["opened_tick"]) - int(r["range_tick"]) >= ceili(0.4 / dt()) - 1, "%s: not before the delay (range %d, open %d)" % [kind, int(r["range_tick"]), int(r["opened_tick"])])
		assert_true(bool(r["arrived"]), "%s: the bot arrived on the far side (end %s)" % [kind, r["end"]])
		assert_eq(int(r["unstick_ticks"]), 0, "%s: the brain's unstick never started" % kind)
		assert_eq(int(r["door_waits"]), 0, "%s: the door never waited for the bot" % kind)
	await _free_fixture()


func test_bot_brain_walking_past_along_the_wall_leaves_the_door_closed() -> void:
	var door: Door = (await start_with([Door.KIND_DOOR]))[0]
	var r: Dictionary = await _walk(m.bots[0], door, origin(0), Vector3(-6.0, 0, 1.0), Vector3(6.0, 0, 1.0), 8.0)
	await _free_fixture()
	assert_true(bool(r["arrived"]), "the bot walked past (end %s)" % r["end"])
	assert_true(int(r["range_tick"]) >= 0, "nonvacuous: it passed within the door's range")
	assert_eq(int(r["state"]), WorldProps.CLOSED, "the door stays closed")
	assert_eq(int(r["by_bots"]), 0, "no bot opening")
	assert_eq(int(r["unstick_ticks"]), 0, "no unstick")
