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


# ---- Stage 3: big-map switch, geared rule, landmark pick, glide, gear goal ----

## Flat world direction of a frame's move on `p` (frame.move is in the pawn's local x/z).
static func world_move(p: Pawn, f: InputFrame) -> Vector3:
	var w := p.global_transform.basis * Vector3(f.move.x, 0.0, f.move.y)
	w.y = 0.0
	return w.normalized()


static func flat_dir(from: Vector3, to: Vector3) -> Vector3:
	var d := to - from
	d.y = 0.0
	return d.normalized()


func test_big_map_switch_from_the_start_radius() -> void:
	await start(big_zone())
	var b := add_brain(m.bots[0])
	b._ensure_seeded()
	assert_true(b.is_big_map(), "start radius 400 > big_map_radius_m: big")
	m.queue_free()
	await start(small_zone())
	b = add_brain(m.bots[0])
	b._ensure_seeded()
	assert_true(not b.is_big_map(), "start radius 80: small")
	m.queue_free()
	# No rules at all (a bare director): small, the safe side.
	var d := MatchDirector.new()
	var p := Pawn.new()
	var c := BotBrain.new()
	c.setup(p, d, {}, base_cfg())
	c._ensure_seeded()
	assert_true(not c.is_big_map(), "no rules: small")
	c.free()
	p.free()
	d.free()


func test_geared_needs_armour_and_ammo() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	var gun := bot.loadout.get_active()
	assert_true(gun != null and not gun.def.is_melee(), "class gun in hand")
	var low := m.director.bot_ammo_low_magazines()
	bot.armor_tier = 0
	gun.reserve = int(ceil(gun.def.magazine * low)) + 5
	assert_true(not b.is_geared(), "no armour: not geared")
	bot.armor_tier = 1
	assert_true(b.is_geared(), "armour 1 and ammo above the low mark: geared")
	gun.reserve = int(gun.def.magazine * low) - 1
	assert_true(not b.is_geared(), "ammo below magazine x ammo_low_magazines: not geared")
	assert_eq(b.is_geared(), not bot.wants_item({"kind": "ammo"}, low, 70.0), "the ammo half is wants_item's ammo rule")
	gun.reserve = int(ceil(gun.def.magazine * low)) + 5
	assert_eq(b.is_geared(), not bot.wants_item({"kind": "ammo"}, low, 70.0), "the ammo half is wants_item's ammo rule (full)")
	m.queue_free()


## The jump pick (any item counts) is seeded per bot, spreads over the k nearest, never the farther ones, and
## repeats for the same seed.
func test_landmark_pick_is_seeded_spread_and_repeats() -> void:
	await start(big_zone(), true)
	var first: Array = []
	for i in m.bots.size():
		var b := add_brain(m.bots[i], {}, "A%d" % i)
		b._ensure_seeded()
		first.append(String(b._pick_landmark(Vector3.ZERO, true).get("id", "")))
	var again: Array = []
	for i in m.bots.size():
		var b := add_brain(m.bots[i], {}, "B%d" % i)
		b._ensure_seeded()
		again.append(String(b._pick_landmark(Vector3.ZERO, true).get("id", "")))
	assert_eq(again, first, "same seed and ids: the same picks")
	var kinds := {}
	for id in first:
		kinds[id] = true
	assert_true(kinds.size() >= 2, "17 bots spread over several landmarks: %s" % [kinds.keys()])
	assert_true(not kinds.has("porta_astra") and not kinds.has(""), "only the k = 3 nearest (porta_astra is the farthest from the origin): %s" % [kinds.keys()])
	m.queue_free()


func test_glide_steers_to_the_landmark_on_a_big_map() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	bot.start_fall(Vector3(5.0, 60.0, 5.0))
	var f := b.build_frame(dt())
	assert_true(b._landmark_picked and b.landmark_id() != "", "picked a landmark at the jump (%s)" % b.landmark_id())
	assert_true(b._jump_from.distance_to(Vector3(5.0, 60.0, 5.0)) < 0.5, "measured from the jump position")
	var want := flat_dir(bot.global_position, BotBrain._lm_goal(b._landmark))
	assert_true(world_move(bot, f).dot(want) > 0.99, "the glide heads for the landmark anchor")
	m.queue_free()


func test_glide_steers_to_the_zone_spot_on_a_small_map() -> void:
	await start(small_zone(), true)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	bot.start_fall(Vector3(5.0, 60.0, 5.0))
	var f := b.build_frame(dt())
	assert_true(not b._landmark_picked, "small map: no landmark pick")
	var want := flat_dir(bot.global_position, b._zone_spot())
	assert_true(world_move(bot, f).dot(want) > 0.99, "the glide heads for the zone spot as before")
	m.queue_free()


## No loot placed at the jump: glide to the zone spot; once placed, pick from the stored jump position.
func test_glide_waits_for_the_loot_then_picks_from_the_jump() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	m.loot.placed = false
	bot.start_fall(Vector3(5.0, 60.0, 5.0))
	var f := b.build_frame(dt())
	assert_true(not b._landmark_picked, "no loot placed yet: no pick")
	assert_true(world_move(bot, f).dot(flat_dir(bot.global_position, b._zone_spot())) > 0.99, "glides to the zone spot meanwhile")
	m.loot.placed = true
	bot.global_position = Vector3(30.0, 50.0, 30.0)
	b.build_frame(dt())
	assert_true(b._landmark_picked and b.landmark_id() != "", "picked once the loot is placed")
	assert_true(b._jump_from.distance_to(Vector3(5.0, 60.0, 5.0)) < 0.5, "still measured from the jump position")
	m.queue_free()


## The gear goal: an ungeared bot with no loot in reach walks to its landmark; an emptied landmark is re-picked
## on the re-check; geared -> no gear goal. loot_seek_range_m is cut to 5 m so the loot goal stays out of it.
func test_gear_goal_walks_to_the_landmark_and_repicks_when_empty() -> void:
	await start(big_zone(), true)
	for id in m.loot.items.keys():
		m.loot.take(id)
	var a_id := m.loot.drop({"item_id": "armor_1"}, Vector3(44.0, 0.0, -38.0))  # aqua_alta
	m.loot.drop({"item_id": "armor_1"}, Vector3(42.0, 0.0, 41.0))  # specula
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(20.0, 0.2, -20.0)
	bot.armor_tier = 0
	var cfg := base_cfg()
	cfg["loot_seek_range_m"] = 5.0
	cfg["route"]["landmark_pick_k"] = 1
	var b := add_brain(bot, cfg)
	b._ensure_seeded()
	b._route_think()
	assert_eq(b.landmark_id(), "aqua_alta", "the nearest landmark with wanted loot")
	var g := b._goal(null, false)
	assert_eq(b.goal_kind, "gear", "not geared, nothing in reach: gear")
	assert_true(g.distance_to(BotBrain._lm_goal(b._landmark)) < 0.01, "walks to the landmark anchor")
	m.loot.take(a_id)
	b._goal(null, false)
	assert_eq(b.landmark_id(), "aqua_alta", "no re-check before the interval")
	b._gear_check_tick = m.director.tick_count  # the interval is up
	b._goal(null, false)
	assert_eq(b.landmark_id(), "specula", "emptied: re-picked the next landmark with loot")
	assert_eq(b.goal_kind, "gear", "still gearing")
	var gun := bot.loadout.get_active()
	bot.armor_tier = 1
	gun.reserve = int(ceil(gun.def.magazine * m.director.bot_ammo_low_magazines())) + 5
	b._goal(null, false)
	assert_true(b.goal_kind != "gear", "geared: no gear goal (%s)" % b.goal_kind)
	m.queue_free()


## The same scene on a small map never gears: today's goal.
func test_small_map_never_gears() -> void:
	await start(small_zone(), true)
	for id in m.loot.items.keys():
		m.loot.take(id)
	m.loot.drop({"item_id": "armor_1"}, Vector3(44.0, 0.0, -38.0))
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(20.0, 0.2, -20.0)
	bot.armor_tier = 0
	var cfg := base_cfg()
	cfg["loot_seek_range_m"] = 5.0
	var b := add_brain(bot, cfg)
	b._ensure_seeded()
	b._goal(null, false)
	assert_true(b.goal_kind == "hold" or b.goal_kind == "zone", "small map: today's spot or hold (%s)" % b.goal_kind)
	assert_true(not b._landmark_picked, "small map: no landmark")
	m.queue_free()


## The aim stream: the route picks draw only from the route stream, so the aim draws are unchanged.
func test_route_draws_leave_the_aim_stream_alone() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var a := add_brain(bot, {}, "A")
	var b := add_brain(bot, {}, "B")
	a._ensure_seeded()
	b._ensure_seeded()
	for i in 5:
		a._pick_landmark(Vector3(float(i) * 7.0, 0.0, 0.0), true)
		a._pick_landmark(Vector3(0.0, 0.0, float(i) * 7.0), false)
	var same := true
	for i in 20:
		var ea := BotTargeting.aim_error(0.35, 12.0, a._rng)
		var eb := BotTargeting.aim_error(0.35, 12.0, b._rng)
		same = same and ea == eb
	assert_true(same, "aim error sequences equal with and without route picks")
	assert_eq(a._spot_dir, b._spot_dir, "same spot direction")
	m.queue_free()


# ---- Stage 4: rotation in time ----

## A zone of start radius `start_r` whose first wait is `wait_s` and whose next circle is a small 10 m one.
static func timed_zone(start_r: float, wait_s: float) -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": start_r, "damage_skips_shield": false,
			"phases": [{"wait_s": wait_s, "shrink_s": 200.0, "radius_m": 10.0, "damage_per_s": 0.0}]}


## Puts `bot` on the line from the origin side toward its zone spot so that the walk takes `t_s` seconds by the
## rotation formula (inverted), still inside the current circle.
func place_for_walk(bot: Pawn, b: BotBrain, t_s: float) -> void:
	var spot := b._zone_spot()
	var d := (t_s - b._route_f("rotate_margin_s", 10.0)) / b._route_f("rotate_detour", 1.3) * bot.get_move_speed()
	var dir := Vector3(-spot.x, 0.0, -spot.z).normalized() if Vector2(spot.x, spot.z).length() > 1.0 else Vector3.RIGHT
	bot.global_position = Vector3(spot.x, 0.2, spot.z) + dir * d


func test_rotation_starts_when_the_walk_outlasts_the_wait() -> void:
	await start(timed_zone(400.0, 60.0))
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	b._ensure_seeded()
	assert_true(b.is_big_map(), "big map")
	var rules := m.director.rules
	assert_eq(rules.zone_state(), "waiting", "the zone waits")
	var left := rules.zone_seconds_left()
	# The formula, computed here independently.
	place_for_walk(bot, b, left - 5.0)
	var spot := b._zone_spot()
	var want := Vector2(spot.x - bot.global_position.x, spot.z - bot.global_position.z).length() / bot.get_move_speed() \
			* float(base_cfg()["route"]["rotate_detour"]) + float(base_cfg()["route"]["rotate_margin_s"])
	assert_true(absf(b._time_to_reach() - want) < 0.01, "time_to_reach = distance / class speed x detour + margin (%.2f vs %.2f)" % [b._time_to_reach(), want])
	assert_true(not rules.is_outside(Vector2(bot.global_position.x, bot.global_position.z)), "inside the current circle")
	assert_true(not b._inside_target(), "outside the next circle")
	assert_true(not b._zone_pressure(), "walk %.1f s < %.1f s left: no pressure yet" % [b._time_to_reach(), left])
	place_for_walk(bot, b, left + 5.0)
	assert_true(b._zone_pressure(), "walk %.1f s > %.1f s left: pressure" % [b._time_to_reach(), left])
	# The old fixed margin would have said "no pressure" here (60 s left > zone_margin_s 25).
	assert_true(left > float(base_cfg()["zone_margin_s"]), "the old margin rule would not have fired")
	m.queue_free()


## A small map keeps zone_margin_s: 20 s left < 25 -> pressure even for a bot a few metres from its spot; 60 s
## left -> none even for a bot whose walk would take longer.
func test_small_map_keeps_the_fixed_margin() -> void:
	await start(timed_zone(80.0, 20.0))
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	b._ensure_seeded()
	assert_true(not b.is_big_map(), "small map")
	place_for_walk(bot, b, 16.0)
	assert_true(not b._inside_target(), "outside the next circle")
	assert_true(b._zone_pressure(), "20 s left < zone_margin_s 25: pressure")
	m.queue_free()
	await start(timed_zone(80.0, 60.0))
	bot = m.bots[0]
	b = add_brain(bot)
	b._ensure_seeded()
	place_for_walk(bot, b, 24.0)
	assert_true(not m.director.rules.is_outside(Vector2(bot.global_position.x, bot.global_position.z)), "inside the current circle")
	assert_true(not b._inside_target(), "outside the next circle")
	assert_true(not b._zone_pressure(), "60 s left > 25: no pressure (walk %.0f s)" % b._time_to_reach())
	m.queue_free()
	# The big map with the same 20 s left and a short walk: no pressure (the new rule, not the margin).
	await start(timed_zone(400.0, 20.0))
	bot = m.bots[0]
	b = add_brain(bot)
	b._ensure_seeded()
	place_for_walk(bot, b, 16.0)
	assert_true(not b._inside_target(), "outside the next circle")
	assert_true(not b._zone_pressure(), "big map: a 16 s walk with 20 s left is not late")
	m.queue_free()


# ---- Stage 5: hearing and the hunt goal ----

func test_hearing_remembers_enemy_gun_shots_only() -> void:
	await start(big_zone(), false, "squads")
	var bot: Pawn = m.bots[0]
	var mate: Pawn = null
	var enemy: Pawn = null
	for p in m.bots:
		if p == bot:
			continue
		if p.squad_id == bot.squad_id and mate == null:
			mate = p
		elif p.squad_id != bot.squad_id and enemy == null:
			enemy = p
	assert_true(mate != null and enemy != null, "a mate and an enemy")
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	var b := add_brain(bot)
	b._ensure_seeded()
	b._listen()
	var near := Vector3(40.0, 1.4, 20.0)
	enemy.shot.emit(near, Vector3.FORWARD, "pilum_br")
	assert_eq(b.heard_count, 1, "an enemy gun shot 45 m away is heard")
	assert_true(b._enemy_mem.distance_to(near) < 0.01 and b._enemy_mem_tick == m.director.tick_count, "remembered where and when")
	enemy.shot.emit(Vector3(10.0, 1.4, 0.0), Vector3.FORWARD, "gladius_lux")
	assert_eq(b.heard_count, 1, "a blade swing is not heard")
	mate.shot.emit(Vector3(10.0, 1.4, 0.0), Vector3.FORWARD, "pilum_br")
	assert_eq(b.heard_count, 1, "a squad mate's shot is not an enemy")
	var radius := float(base_cfg()["route"]["hearing_radius_m"])
	enemy.shot.emit(Vector3(radius + 5.0, 1.4, 0.0), Vector3.FORWARD, "sagittarii_rifle")
	assert_eq(b.heard_count, 1, "out of the hearing radius")
	bot.life = Pawn.Life.DEAD
	enemy.shot.emit(near, Vector3.FORWARD, "pilum_br")
	assert_eq(b.heard_count, 1, "a dead listener does not react")
	bot.life = Pawn.Life.ALIVE
	b._listen()
	enemy.shot.emit(near, Vector3.FORWARD, "pilum_br")
	assert_eq(b.heard_count, 2, "wired once: one shot, one count")
	b.free()
	enemy.shot.emit(near, Vector3.FORWARD, "pilum_br")  # the connection died with the brain (no error)
	var left := 0
	for c in enemy.shot.get_connections():
		if not is_instance_valid((c["callable"] as Callable).get_object()):
			left += 1
	assert_eq(left, 0, "no connection to a freed brain remains")
	m.queue_free()


func test_small_map_does_not_listen() -> void:
	await start(small_zone(), false, "squads")
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	b._ensure_seeded()
	b._goal(null, false)
	assert_eq(b._listen_count, -1, "small map: no shot wiring")
	m.queue_free()


## A geared bot with nothing in sight: hunts toward the next circle's centre, a fresh memory first, a stale one
## is ignored, and close to the point it falls through to today's spot / hold.
func test_hunt_goal() -> void:
	await start(big_zone())
	var bot: Pawn = m.bots[0]
	var gun := bot.loadout.get_active()
	bot.armor_tier = 1
	gun.reserve = int(ceil(gun.def.magazine * m.director.bot_ammo_low_magazines())) + 5
	var c := m.director.zone_target_center()
	bot.global_position = c + Vector3(30.0, 0.2, 0.0)
	var b := add_brain(bot)
	b._ensure_seeded()
	assert_true(b.is_geared(), "geared")
	var g := b._goal(null, false)
	assert_eq(b.goal_kind, "hunt", "geared, nothing seen: hunt")
	assert_true(Vector2(g.x - c.x, g.z - c.z).length() < 0.01, "toward the next circle's centre")
	var mem := c + Vector3(-40.0, 0.0, 10.0)
	b._remember_enemy(mem)
	g = b._goal(null, false)
	assert_true(b.goal_kind == "hunt" and g.distance_to(mem) < 0.01, "a fresh memory comes first")
	b._enemy_mem_tick = m.director.tick_count - int(float(base_cfg()["route"]["hunt_memory_s"]) * Engine.physics_ticks_per_second) - 1
	g = b._goal(null, false)
	assert_true(Vector2(g.x - c.x, g.z - c.z).length() < 0.01, "a stale memory is ignored")
	bot.global_position = c + Vector3(3.0, 0.2, 0.0)
	b._goal(null, false)
	assert_true(b.goal_kind == "hold" or b.goal_kind == "zone", "arrived: today's spot or hold (%s)" % b.goal_kind)
	m.queue_free()


# ---- Stage 6: sight per gun and the fight band ----

## Gives `p` the blade plus `gun` from the ground and holds the gun.
func arm(p: Pawn, gun: String) -> void:
	p.apply_start_kit({"secondary": "gladius_lux"})
	p.take_item({"item_id": gun}, m.loot.def(gun))
	for i in p.loadout.slots.size():
		var s := p.loadout.slots[i]
		if s != null and s.def.id == gun:
			p.loadout.active = i


func test_sight_per_gun_is_clamped_to_the_gun_range() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	b._ensure_seeded()
	var fight: Dictionary = base_cfg()["fight"]
	assert_eq(float(fight["sight_by_weapon"]["pilum_br"]), 60.0, "shipped placeholder: pilum_br 60")
	assert_eq(float(fight["sight_by_weapon"]["sagittarii_rifle"]), 60.0, "shipped placeholder: sagittarii_rifle 60")
	assert_eq(float(fight["band_far_frac"]), 0.25, "shipped placeholder: band_far_frac 0.25")
	assert_eq(float(fight["repath_m"]), 3.0, "shipped placeholder: repath_m 3")
	arm(bot, "pilum_br")
	assert_eq(b.sight_m(), minf(60.0, bot.loadout.get_active().def.range_m), "pilum_br: 60 (range 80)")
	arm(bot, "sagittarii_rifle")
	assert_eq(b.sight_m(), 60.0, "sagittarii_rifle: 60 (range 200)")
	var cfg := base_cfg()
	cfg["fight"]["sight_by_weapon"]["pilum_br"] = 500.0
	var c := add_brain(bot, cfg, "C")
	c._ensure_seeded()
	arm(bot, "pilum_br")
	assert_eq(c.sight_m(), bot.loadout.get_active().def.range_m, "never above the gun's range_m")
	bot.loadout.active = 1  # the blade
	assert_eq(c.sight_m(), float(cfg["sight_range_m"]), "the blade: sight_range_m")
	m.queue_free()
	await start(small_zone(), true)
	bot = m.bots[0]
	b = add_brain(bot)
	b._ensure_seeded()
	arm(bot, "sagittarii_rifle")
	assert_eq(b.sight_m(), float(base_cfg()["sight_range_m"]), "small map: sight_range_m as before")
	m.queue_free()


func test_fight_band_closes_in_then_strafes_without_unsticking() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var enemy: Pawn = m.bots[1]
	arm(bot, "pilum_br")
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	var b := add_brain(bot)
	b._ensure_seeded()
	var far_edge := b.sight_m() * float(base_cfg()["fight"]["band_far_frac"])
	enemy.global_position = Vector3(far_edge + 10.0, 0.2, 0.0)
	var g := b._goal(enemy, false)
	assert_eq(b.goal_kind, "fight", "a standing enemy beyond the band: fight")
	assert_true(g.distance_to(enemy.global_position) < 0.01 and not b._fight_hold, "closes in on the enemy")
	enemy.global_position = Vector3(far_edge * 0.5, 0.2, 0.0)
	g = b._goal(enemy, false)
	assert_true(b.goal_kind == "fight" and b._fight_hold, "inside the band: hold the band")
	var off := g - bot.global_position
	var step := float(base_cfg()["fight"]["strafe_step_m"])
	assert_true(absf(off.length() - step) < 0.01 and absf(off.x) < 0.01, "a strafe point to one side (%s)" % off)
	var side := b._strafe_side
	# The strafe point is fixed for the period: the pawn and the enemy move, the goal does not.
	bot.global_position = Vector3(0.5, 0.2, 0.4)
	enemy.global_position = Vector3(far_edge * 0.5, 0.2, 1.0)
	var g2 := b._goal(enemy, false)
	assert_eq(b._strafe_side, side, "same side until the period ends")
	assert_true(g2.is_equal_approx(g), "same strafe point until the period ends (%s vs %s)" % [g2, g])
	b._strafe_flip_tick = m.director.tick_count
	var g3 := b._goal(enemy, false)
	assert_eq(b._strafe_side, -side, "the side flips after the period")
	var off3 := g3 - bot.global_position
	assert_true(not g3.is_equal_approx(g) and absf(off3.length() - step) < 0.01, "a new point from here at the flip (%s)" % off3)
	# A different enemy: the point is recomputed at once (same side, same flip tick).
	var other: Pawn = m.bots[2]
	other.global_position = Vector3(0.5, 0.2, far_edge * 0.5)
	var flip_tick := b._strafe_flip_tick
	var g4 := b._goal(other, false)
	var to_other := other.global_position - bot.global_position
	assert_true(absf((g4 - bot.global_position).dot(Vector3(to_other.x, 0.0, to_other.z).normalized())) < 0.01, "new enemy: a fresh point to its side (%s)" % g4)
	assert_true(b._strafe_side == -side and b._strafe_flip_tick == flip_tick, "new enemy: side and period kept")
	# Leaving the band and coming back: a fresh point.
	enemy.global_position = Vector3(far_edge + 10.0, 0.2, 0.0)
	b._goal(enemy, false)
	assert_true(not b._fight_hold, "out of the band: closing in")
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	enemy.global_position = Vector3(far_edge * 0.5, 0.2, 0.0)
	var g5 := b._goal(enemy, false)
	assert_true(absf(g5.x) < 0.01 and absf((g5 - bot.global_position).length() - step) < 0.01, "back in the band: a fresh point from here (%s)" % g5)
	b._strafe_flip_tick = m.director.tick_count + 1000  # no flip during the rest of the test
	# Pinned in the band (the pawn never moves): never an unstick, think or coast.
	for t in window_ticks(b) * 2:
		b._move_direction(enemy, false, dt())
		b._follow_path(dt())
	assert_true(b._unstick_left <= 0.0 and b._stuck_t == 0.0, "strafing in the band does not unstick")
	# A downed target is not fought in the band (today's goals; finish_downed shoots it).
	enemy.life = Pawn.Life.DOWNED
	b._goal(enemy, false)
	assert_true(b.goal_kind != "fight" and not b._fight_hold, "downed target: no band (%s)" % b.goal_kind)
	enemy.life = Pawn.Life.ALIVE
	# The blade keeps chase.
	bot.loadout.active = 1
	enemy.global_position = Vector3(8.0, 0.2, 0.0)
	b._goal(enemy, true)
	assert_eq(b.goal_kind, "chase", "blade only: chase as before")
	m.queue_free()


## Closing in keeps its goal while the enemy stays within fight.repath_m of it; then the goal moves to the enemy.
func test_close_in_goal_moves_only_past_repath_m() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var enemy: Pawn = m.bots[1]
	arm(bot, "pilum_br")
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	var b := add_brain(bot)
	b._ensure_seeded()
	var far := b.sight_m() * float(base_cfg()["fight"]["band_far_frac"]) + 20.0
	var repath := float(base_cfg()["fight"]["repath_m"])
	enemy.global_position = Vector3(far, 0.2, 0.0)
	var g := b._goal(enemy, false)
	assert_true(b.goal_kind == "fight" and g.is_equal_approx(enemy.global_position), "closes in on the enemy")
	enemy.global_position = Vector3(far, 0.2, repath - 0.5)
	var g2 := b._goal(enemy, false)
	assert_true(g2.is_equal_approx(g), "enemy within repath_m of the goal: goal kept (%s)" % g2)
	enemy.global_position = Vector3(far, 0.2, repath + 0.5)
	var g3 := b._goal(enemy, false)
	assert_true(g3.is_equal_approx(enemy.global_position), "enemy past repath_m: goal moves to it (%s)" % g3)
	# Another enemy, or a think without a close-in goal in between: the goal is taken fresh.
	var other: Pawn = m.bots[2]
	other.global_position = Vector3(far, 0.2, repath + 1.0)
	assert_true(b._goal(other, false).is_equal_approx(other.global_position), "new enemy: its position")
	enemy.global_position = Vector3(far, 0.2, repath + 1.5)
	b._goal(null, false)
	assert_true(b._goal(enemy, false).is_equal_approx(enemy.global_position), "after a think without a fight goal: fresh")
	# The agent is not handed a kept fight goal again.
	var kept := b._goal(enemy, false)
	b._move_direction(enemy, false, dt())
	var agent_target := b._agent.target_position
	assert_true(agent_target.is_equal_approx(kept), "agent target = the fight goal")
	m.queue_free()


func test_small_map_never_fights_in_a_band() -> void:
	await start(small_zone(), true)
	var bot: Pawn = m.bots[0]
	var enemy: Pawn = m.bots[1]
	arm(bot, "pilum_br")
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	enemy.global_position = Vector3(20.0, 0.2, 0.0)
	var b := add_brain(bot)
	b._ensure_seeded()
	b._goal(enemy, false)
	assert_true(b.goal_kind != "fight" and not b._fight_hold, "small map: today's goals (%s)" % b.goal_kind)
	m.queue_free()
