extends "res://tests/test_case.gd"
## M2B1: the bot brain's route and fight rules (stuck window, big-map switch, gearing, rotation, hearing, hunt,
## sight per gun, fight band). The brains under test are driven by hand; every bot's own Brain is switched off.

const _MatchScene := preload("res://scenes/match/match.tscn")

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


func dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


## A small calm zone (start radius 80 m: a small map for the brain).
static func small_zone() -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 80.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 200.0, "radius_m": 40.0, "damage_per_s": 0.0}]}


## A big calm zone (start radius 400 m: above big_map_radius_m).
static func big_zone(wait_s: float = 1000.0) -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 400.0, "damage_skips_shield": false,
			"phases": [{"wait_s": wait_s, "shrink_s": 200.0, "radius_m": 200.0, "damage_per_s": 0.0}]}


## A match on the test map with every bot brain off and every bot parked out of sight; the human far away.
func start(zone: Dictionary, loot: bool = false, mode: String = "solo") -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = loot
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	assert_true(m.begin(), "begin")
	var i := 0
	for b in m.bots:
		b.get_node("Brain").set_physics_process(false)
		b.set_frame(InputFrame.new())
		b.global_position = Vector3(-70.0 + float(i % 6) * 4.0, 0.2, 60.0 + float(i / 6) * 4.0)
		b.visible = false
		i += 1
	m.local_player.global_position = Vector3(70.0, 0.2, -70.0)
	m.local_player.visible = false
	await frames(2)


func base_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).duplicate(true)


## A fresh brain on `pawn` (not named Brain; the pawn's own Brain is off), driven by hand.
func add_brain(pawn: Pawn, cfg: Dictionary = {}, tag: String = "") -> BotBrain:
	var profile: Dictionary = DataRegistry.new().load_file("res://data/bots.json").get("profiles", {}).get("tiro", {})
	var b := BotBrain.new()
	b.name = "Test" + tag
	b.setup(pawn, m.director, profile, cfg if not cfg.is_empty() else base_cfg())
	pawn.add_child(b)
	b.set_physics_process(false)
	return b


func window_ticks(b: BotBrain) -> int:
	return int(ceil(float(b.cfg.get("stuck_window_s", 2.0)) / dt())) + 1


# ---- Stage 2: the stuck window starts where the bot stands ----

## A pinned bot (it never moves) far from the world origin starts an unstick after its FIRST window. Before the
## fix the first window measured from Vector3.ZERO, so a bot 40 m out always "moved" and was never flagged.
func test_pinned_bot_far_from_origin_unsticks_after_the_first_window() -> void:
	await start(small_zone())
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(40.0, 0.2, 30.0)
	var b := add_brain(bot)
	var n := window_ticks(b)
	var started := -1
	for t in n:
		b._track_stuck(dt())
		if b._unstick_left > 0.0:
			started = t
			break
	assert_true(started >= 0, "pinned 50 m from the origin: unstick within the first window (%d ticks)" % n)
	m.queue_free()


## The same through the coast path: _follow_path advances the window on coast ticks, and the think that ends
## it judges from where the window started.
func test_pinned_bot_window_started_on_a_coast_tick() -> void:
	await start(small_zone())
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(-40.0, 0.2, -30.0)
	var b := add_brain(bot)
	b._last_goal = Vector3(-10.0, 0.0, -30.0)
	b._last_goal_active = true
	var n := window_ticks(b)
	for t in n - 1:
		b._follow_path(dt())
	assert_true(b._stuck_from.distance_to(bot.global_position) < 0.01, "the window opened at the bot (coast tick)")
	b._track_stuck(dt())
	assert_true(b._unstick_left > 0.0, "pinned after a coast-started window: unstick")
	m.queue_free()


## A bot far from the origin that keeps walking (1 m per window, hand-moved) is never flagged stuck.
func test_walking_bot_far_from_origin_is_not_flagged() -> void:
	await start(small_zone())
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(40.0, 0.2, 30.0)
	var b := add_brain(bot)
	var n := window_ticks(b)
	var step := 1.0 / float(n)
	var flagged := false
	for t in n * 3:
		bot.global_position += Vector3(step, 0.0, 0.0)
		b._track_stuck(dt())
		flagged = flagged or b._unstick_left > 0.0
	assert_true(not flagged, "walking 1 m per window: never stuck")
	m.queue_free()


## Hold resets the window: a bot that stood still on "hold" and then walks gets a full fresh window.
func test_hold_then_walk_opens_a_fresh_window() -> void:
	await start(small_zone())
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(40.0, 0.2, 30.0)
	var b := add_brain(bot)
	var n := window_ticks(b)
	for t in n - 5:
		b._track_stuck(dt())
	b._last_goal_active = false
	b._follow_path(dt())  # hold: the window resets
	assert_eq(b._stuck_t, 0.0, "hold resets the window")
	bot.global_position = Vector3(45.0, 0.2, 30.0)
	for t in n - 5:
		b._track_stuck(dt())
	assert_true(b._unstick_left <= 0.0, "a fresh window: no unstick before its end")
	m.queue_free()
