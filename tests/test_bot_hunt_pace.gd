extends "res://tests/test_case.gd"
## M2B2 hunt pace (data/bots.json brain.route hunt_speed_scale / hunt_edge_frac / hunt_patrol_step_deg /
## hunt_delay_s, big maps only, placeholders OQ-BOT-ROUTE): the off values give the M2B1 hunt, the move scale, the
## rim patrol, the regroup delay, no extra draws, and small maps untouched. Brains are driven by hand (as in
## tests/test_bot_route.gd); every bot's own Brain is switched off.

const _MatchScene := preload("res://scenes/match/match.tscn")

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


func dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


static func small_zone() -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 80.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 200.0, "radius_m": 40.0, "damage_per_s": 0.0}]}


static func big_zone() -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 400.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 200.0, "radius_m": 200.0, "damage_per_s": 0.0}]}


## A match on the test map with every bot brain off and every bot parked out of sight; the human far away.
func start(zone: Dictionary) -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = false
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = "solo"
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


## The shipped brain config with the three pace knobs set (speed scale, rim fraction, delay seconds).
func knobs(speed: float, edge: float, delay: float) -> Dictionary:
	var cfg := base_cfg()
	cfg["route"]["hunt_speed_scale"] = speed
	cfg["route"]["hunt_edge_frac"] = edge
	cfg["route"]["hunt_delay_s"] = delay
	return cfg


func off_cfg() -> Dictionary:
	return knobs(1.0, 0.0, 0.0)


func add_brain(pawn: Pawn, cfg: Dictionary = {}, tag: String = "") -> BotBrain:
	var profile: Dictionary = DataRegistry.new().load_file("res://data/bots.json").get("profiles", {}).get("tiro", {})
	var b := BotBrain.new()
	b.name = "Test" + tag
	b.setup(pawn, m.director, profile, cfg if not cfg.is_empty() else base_cfg())
	pawn.add_child(b)
	b.set_physics_process(false)
	return b


func gear_up(p: Pawn) -> void:
	p.armor_tier = 1
	var gun := p.loadout.get_active()
	gun.reserve = int(ceil(gun.def.magazine * m.director.bot_ammo_low_magazines())) + 5


static func flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


func delay_ticks(cfg: Dictionary) -> int:
	return int(float(cfg["route"]["hunt_delay_s"]) * float(Engine.physics_ticks_per_second))


# ---- (a) all three off: the M2B1 hunt ----

## Off values and missing keys both give today's goals: centre, a fresh memory first, a reached point falls
## through; goal_kind "hunt" even right after landing; the move scale is 1.
func test_knobs_off_give_the_m2b1_hunt() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	var c := m.director.zone_target_center()
	var bare := base_cfg()
	for k in ["hunt_speed_scale", "hunt_edge_frac", "hunt_patrol_step_deg", "hunt_delay_s"]:
		bare["route"].erase(k)
	for cfg in [off_cfg(), bare]:
		bot.global_position = c + Vector3(30.0, 0.2, 0.0)
		var b := add_brain(bot, cfg)
		b._ensure_seeded()
		b._route_think()  # landing: the delay clock would start here
		var g := b._goal(null, false)
		assert_eq(b.goal_kind, "hunt", "off: hunt after landing")
		assert_eq(g, c, "off: exactly the next circle's centre")
		assert_eq(b._hunt_move_scale(), 1.0, "off: full speed")
		var mem := c + Vector3(-40.0, 0.0, 10.0)
		b._remember_enemy(mem)
		g = b._goal(null, false)
		assert_true(b.goal_kind == "hunt" and g == mem, "off: a fresh memory first")
		bot.global_position = c + Vector3(3.0, 0.2, 0.0)
		b._enemy_mem_tick = -1
		g = b._goal(null, false)
		assert_true(b.goal_kind == "hold" or b.goal_kind == "zone", "off: arrived falls through (%s)" % b.goal_kind)
		assert_eq(g, b._zone_spot(), "off: today's spot")
		b.free()
	m.queue_free()


# ---- (b) the move scale ----

func test_speed_scale_on_hunt_and_regroup_in_think_and_coast() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	var c := m.director.zone_target_center()
	bot.global_position = c + Vector3(60.0, 0.2, 0.0)
	var cfg := knobs(0.5, 0.0, 0.0)  # no delay yet: hunt
	var b := add_brain(bot, cfg)
	b._ensure_seeded()
	var f := b.build_frame(dt())
	assert_eq(b.goal_kind, "hunt", "hunting")
	assert_true(absf(f.move.length() - 0.5) < 1e-4, "hunt: half speed in build_frame (%.4f)" % f.move.length())
	f = b._coast_frame(dt())
	assert_true(absf(f.move.length() - 0.5) < 1e-4, "hunt: half speed on a coast tick (%.4f)" % f.move.length())
	b.cfg["route"]["hunt_delay_s"] = 20.0
	b._regroup_tick = m.director.tick_count  # an enemy was just in sight: regroup
	f = b.build_frame(dt())
	assert_eq(b.goal_kind, "regroup", "regrouping")
	assert_true(absf(f.move.length() - 0.5) < 1e-4, "regroup: half speed in build_frame (%.4f)" % f.move.length())
	f = b._coast_frame(dt())
	assert_true(absf(f.move.length() - 0.5) < 1e-4, "regroup: half speed on a coast tick (%.4f)" % f.move.length())
	# The unstick sidestep walks at full speed, in a think and on a coast tick.
	b._unstick_left = 0.5
	f = b.build_frame(dt())
	assert_true(b.goal_kind == "regroup" and absf(f.move.length() - 1.0) < 1e-4, "unstick: full speed (%.4f)" % f.move.length())
	f = b._coast_frame(dt())
	assert_true(absf(f.move.length() - 1.0) < 1e-4, "unstick on a coast tick: full speed (%.4f)" % f.move.length())
	b._unstick_left = 0.0
	# The clamp.
	b.cfg["route"]["hunt_speed_scale"] = 0.1
	f = b.build_frame(dt())
	assert_true(absf(f.move.length() - 0.3) < 1e-4, "clamped up to 0.3 (%.4f)" % f.move.length())
	b.cfg["route"]["hunt_speed_scale"] = 2.0
	f = b.build_frame(dt())
	assert_true(absf(f.move.length() - 1.0) < 1e-4, "clamped down to 1.0 (%.4f)" % f.move.length())
	m.queue_free()


## Another walking goal ("zone": hunting needs gear here and the bot has none) keeps full speed.
func test_speed_scale_leaves_other_goals_alone() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	bot.armor_tier = 0
	var c := m.director.zone_target_center()
	bot.global_position = c + Vector3(180.0, 0.2, 0.0)
	var cfg := knobs(0.5, 0.0, 0.0)
	cfg["route"]["hunt_requires_gear"] = true
	var b := add_brain(bot, cfg)
	var f := b.build_frame(dt())
	assert_eq(b.goal_kind, "zone", "walking to its spot")
	assert_true(absf(f.move.length() - 1.0) < 1e-4, "zone: full speed (%.4f)" % f.move.length())
	f = b._coast_frame(dt())
	assert_true(absf(f.move.length() - 1.0) < 1e-4, "zone on a coast tick: full speed (%.4f)" % f.move.length())
	m.queue_free()


# ---- (c) the rim patrol ----

func test_rim_patrol_steps_around_and_follows_the_circle() -> void:
	await start(big_zone())
	var cfg := knobs(1.0, 0.8, 0.0)
	var step := deg_to_rad(float(cfg["route"]["hunt_patrol_step_deg"]))
	var signs := {}
	for p in [m.bots[0], m.bots[1]]:
		var bot: Pawn = p
		gear_up(bot)
		var c := m.director.zone_target_center()
		var r := m.director.zone_target_radius()
		bot.global_position = c + Vector3(0.0, 0.2, 0.0)
		var b := add_brain(bot, cfg.duplicate(true), str(bot.player_id))
		b._ensure_seeded()
		var g := b._goal(null, false)
		assert_eq(b.goal_kind, "hunt", "rim: hunt")
		assert_true(absf(flat(g - c).length() - r * 0.8) < 1e-3, "on the rim at 0.8 x radius (%.2f)" % flat(g - c).length())
		var a0 := flat(g - c).angle()
		assert_true(absf(wrapf(a0 - b._spot_dir.angle(), -PI, PI)) < 1e-4, "starts at the spot direction's angle")
		assert_eq(b._goal(null, false), g, "not arrived: the same goal (no jitter)")
		bot.global_position = g + Vector3(2.0, 0.2, 0.0)
		assert_true(b._hunt_goal() != Vector3.INF, "at the waypoint: never INF (it steps on)")
		var g2 := b._goal(null, false)
		assert_eq(b.goal_kind, "hunt", "at the waypoint: still hunting, never hold")
		var turn := wrapf(flat(g2 - c).angle() - a0, -PI, PI)
		var want := 1.0 if posmod(bot.player_id, 2) == 0 else -1.0
		assert_true(absf(absf(turn) - step) < 1e-3, "one step per arrival (%.4f rad)" % turn)
		assert_true(signf(turn) == want, "the per-bot direction (id %d: %.4f)" % [bot.player_id, turn])
		signs[signf(turn)] = true
		assert_eq(b._goal(null, false), g2, "after the step: the same goal again")
		# The next circle moves (a new phase): the waypoint follows it, same angle.
		var circle: Dictionary = m.director.rules._circles[0]
		var old_c: Vector2 = circle["center"]
		var old_r: float = circle["radius"]
		circle["center"] = old_c + Vector2(20.0, -10.0)
		circle["radius"] = 150.0
		var c2 := m.director.zone_target_center()
		var g3 := b._goal(null, false)
		assert_true(absf(flat(g3 - c2).length() - 150.0 * 0.8) < 1e-3, "follows the moved circle's radius")
		assert_true(absf(wrapf(flat(g3 - c2).angle() - flat(g2 - c).angle(), -PI, PI)) < 1e-4, "same angle on the moved circle")
		circle["center"] = old_c
		circle["radius"] = old_r
		b.free()
	assert_eq(signs.size(), 2, "even and odd ids walk opposite ways")
	m.queue_free()


# ---- (d) the regroup delay ----

func test_delay_regroups_after_landing_and_after_a_fight() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	bot.global_position = Vector3(40.0, 0.2, 0.0)
	var enemy: Pawn = m.bots[1]
	enemy.global_position = Vector3(40.0, 0.2, -15.0)
	var cfg := knobs(1.0, 0.0, 0.5)
	var b := add_brain(bot, cfg)
	var c := m.director.zone_target_center()
	await frames(1)
	b.build_frame(dt())  # the first grounded think: landing
	var landed := m.director.tick_count
	assert_eq(b._regroup_tick, landed, "the delay starts at landing")
	var mem := c + Vector3(-40.0, 0.0, 10.0)
	b._remember_enemy(mem)
	var g := b._goal(null, false)
	assert_eq(b.goal_kind, "regroup", "after landing: regroup")
	assert_eq(g, c, "regroup ignores the fresh memory: the centre (rim off)")
	await frames(delay_ticks(cfg) - 2)
	b._remember_enemy(mem)
	b._goal(null, false)
	assert_eq(b.goal_kind, "regroup", "one tick before the delay ends: still regroup")
	await frames(2)
	b._remember_enemy(mem)
	g = b._goal(null, false)
	assert_true(b.goal_kind == "hunt" and g == mem, "the landing delay has passed: hunt to the memory (%s)" % b.goal_kind)
	# An enemy comes into sight, then leaves: regroup again.
	enemy.visible = true
	await frames(1)
	b.build_frame(dt())
	assert_eq(b.target_id, enemy.player_id, "the enemy is in sight")
	assert_eq(b._regroup_tick, m.director.tick_count, "the delay restarts at the last think with an enemy in sight")
	enemy.visible = false
	await frames(1)
	b.build_frame(dt())
	assert_eq(b.goal_kind, "regroup", "after the fight: regroup, not straight to the memory")
	assert_true(b._enemy_mem_tick >= 0, "the memory is kept")
	# The delay after the fight passes: hunt to the memory.
	await frames(delay_ticks(cfg))
	b._remember_enemy(mem)
	g = b._goal(null, false)
	assert_true(b.goal_kind == "hunt" and g == mem, "after the delay: hunt to the memory (%s)" % b.goal_kind)
	# Regroup with the rim off falls through near the centre, as the hunt does.
	b._regroup_tick = m.director.tick_count
	bot.global_position = c + Vector3(3.0, 0.2, 0.0)
	b._goal(null, false)
	assert_true(b.goal_kind == "hold" or b.goal_kind == "zone", "regroup arrived: falls through (%s)" % b.goal_kind)
	m.queue_free()


# ---- (e) no draws ----

## Two brains on one bot, knobs off and on, an enemy in sight then gone, think and coast ticks: both streams end
## at the same position.
func test_knobs_add_no_draws_on_either_stream() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	bot.global_position = Vector3(40.0, 0.2, 0.0)
	var enemy: Pawn = m.bots[1]
	enemy.global_position = Vector3(40.0, 0.2, -15.0)
	enemy.visible = true
	var off := add_brain(bot, off_cfg(), "Off")
	var on := add_brain(bot, knobs(0.6, 0.8, 1.0), "On")
	var kinds := {}
	for t in 300:
		if t == 100:
			enemy.visible = false
		await frames(1)
		if t % 3 == 0:
			off.build_frame(dt())
			on.build_frame(dt())
		else:
			off._coast_frame(dt())
			on._coast_frame(dt())
		kinds[on.goal_kind] = true
	assert_true(kinds.has("regroup") and kinds.has("hunt"), "the on brain regrouped and hunted: %s" % [kinds.keys()])
	assert_eq(on._rng.state, off._rng.state, "aim stream: same position")
	assert_eq(on._route_rng.state, off._route_rng.state, "route stream: same position")
	assert_eq(on._spot_dir, off._spot_dir, "same spot direction")
	m.queue_free()


# ---- (f) small maps ----

func test_small_map_ignores_the_knobs() -> void:
	await start(small_zone())
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	bot.global_position = Vector3(60.0, 0.2, 0.0)
	var on := add_brain(bot, knobs(0.4, 0.8, 20.0), "On")
	var off := add_brain(bot, off_cfg(), "Off")
	for t in 5:
		await frames(1)
		var fa := on.build_frame(dt())
		var fb := off.build_frame(dt())
		assert_true(not on.is_big_map(), "small map")
		assert_eq(on.goal_kind, off.goal_kind, "same goal kind (%s)" % on.goal_kind)
		assert_true(on.goal_kind != "hunt" and on.goal_kind != "regroup", "no hunt on a small map")
		assert_eq(on._last_goal, off._last_goal, "same goal")
		assert_eq(fa.move, fb.move, "same move")
		assert_eq(on._regroup_tick, -1, "no delay clock")
	m.queue_free()
