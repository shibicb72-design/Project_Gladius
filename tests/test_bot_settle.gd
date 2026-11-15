extends "res://tests/test_case.gd"
## M2B2: the aim settle (BotTargeting.settle_scale, BotBrain._settle_s) and the fight band's near and far edges
## (BotBrain._fight_goal "close" / "band" / "near"). Big maps only; small maps draw as before. The brains under test
## are driven by hand; every bot's own Brain is switched off (the house style of tests/test_bot_route.gd).

const _MatchScene := preload("res://scenes/match/match.tscn")
const BOTS_PATH := "res://data/bots.json"

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
func start(zone: Dictionary, loot: bool = false) -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = loot
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


func all_cfg() -> Dictionary:
	return DataRegistry.new().load_file(BOTS_PATH)


func base_cfg() -> Dictionary:
	return all_cfg().get("brain", {}).duplicate(true)


func fight() -> Dictionary:
	return base_cfg()["fight"]


func add_brain(pawn: Pawn, cfg: Dictionary = {}, tag: String = "") -> BotBrain:
	var profile: Dictionary = all_cfg().get("profiles", {}).get("tiro", {})
	var b := BotBrain.new()
	b.name = "Test" + tag
	b.setup(pawn, m.director, profile, cfg if not cfg.is_empty() else base_cfg())
	pawn.add_child(b)
	b.set_physics_process(false)
	return b


func arm(p: Pawn, gun: String) -> void:
	p.apply_start_kit({"secondary": "gladius_lux"})
	p.take_item({"item_id": gun}, m.loot.def(gun))
	for i in p.loadout.slots.size():
		var s := p.loadout.slots[i]
		if s != null and s.def.id == gun:
			p.loadout.active = i


## settle_scale with the shipped fight data.
func scale_of(settle_s: float, speed: float, dist: float) -> float:
	var f := fight()
	return BotTargeting.settle_scale(settle_s, speed, dist, float(f["settle_s"]), float(f["settle_floor_frac"]),
			float(f["settle_speed_ref_mps"]), float(f["settle_range_ref_m"]))


## The shooter at (40, 0, 0) and one visible enemy 15 m away (the open spot test_bot_think_rate.gd uses).
func shooter_and_enemy() -> Array:
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(40.0, 0.2, 0.0)
	var enemy: Pawn = m.bots[1]
	enemy.global_position = Vector3(40.0, 0.2, -15.0)
	enemy.visible = true
	return [bot, enemy]


# ---- 1, 6: the scale (pure) ----

## The error limit shrinks with the settle clock and stops at the floor (a still target at range).
func test_limit_shrinks_over_time_and_stops_at_the_floor() -> void:
	var f := fight()
	var full := float(f["settle_s"])
	var floor_frac := float(f["settle_floor_frac"])
	var far := float(f["settle_range_ref_m"]) * 2.0
	assert_eq(scale_of(0.0, 0.0, far), 1.0, "no settle yet: the profile's error")
	var prev := 1.0
	var shrinking := true
	for i in range(1, 11):
		var s := scale_of(full * float(i) / 10.0, 0.0, far)
		shrinking = shrinking and s < prev
		prev = s
	assert_true(shrinking, "the scale falls every step up to settle_s")
	assert_true(absf(scale_of(full, 0.0, far) - floor_frac) < 1e-9, "settled: the floor (%s)" % scale_of(full, 0.0, far))
	assert_eq(scale_of(full * 3.0, 0.0, far), scale_of(full, 0.0, far), "never below the floor")
	assert_true(absf(scale_of(full * 0.5, 0.0, far) - lerpf(1.0, floor_frac, 0.5)) < 1e-9, "linear in time")
	# The limit itself: the largest error the draw can give.
	var rng := RandomNumberGenerator.new()
	var biggest := 0.0
	for i in 400:
		var e := BotTargeting.aim_error(0.35, 12.0, rng, scale_of(full, 0.0, far))
		biggest = maxf(biggest, maxf(absf(e.x), absf(e.y)))
	assert_true(biggest <= deg_to_rad(12.0) * 0.65 * floor_frac + 1e-9, "settled draws stay inside the floor limit (%s)" % biggest)
	assert_eq(BotTargeting.settle_scale(5.0, 0.0, far, 0.0, 0.2, 8.0, 40.0), 1.0, "settle_s 0: no settle")


## A moving target settles less (at the reference speed not at all); a near target settles less (reach).
func test_moving_and_near_targets_settle_less() -> void:
	var f := fight()
	var full := float(f["settle_s"])
	var ref_v := float(f["settle_speed_ref_mps"])
	var ref_d := float(f["settle_range_ref_m"])
	var still := scale_of(full, 0.0, ref_d)
	var walking := scale_of(full, ref_v * 0.5, ref_d)
	var running := scale_of(full, ref_v, ref_d)
	assert_true(still < walking and walking < running, "faster settles less (%s %s %s)" % [still, walking, running])
	assert_eq(running, 1.0, "at the reference speed: no settle")
	assert_eq(scale_of(full, ref_v * 2.0, ref_d), 1.0, "faster than the reference: no settle")
	var at_ref := scale_of(full, 0.0, ref_d)
	var half := scale_of(full, 0.0, ref_d * 0.5)
	var touching := scale_of(full, 0.0, 0.0)
	assert_true(at_ref < half and half < touching, "nearer settles less (%s %s %s)" % [at_ref, half, touching])
	assert_eq(touching, 1.0, "at 0 m: no settle")
	assert_eq(scale_of(full, 0.0, ref_d * 3.0), at_ref, "beyond the reference range: the full settle")
	assert_true(absf(BotTargeting.settle_scale(full, 0.0, 0.0, full, 0.2, 8.0, 0.0) - 0.2) < 1e-9, "range_ref 0: reach 1")
	assert_true(absf(BotTargeting.settle_scale(full, 50.0, 100.0, full, 0.2, 0.0, 40.0) - 0.2) < 1e-9, "speed_ref 0: never moving")


# ---- 3: the profiles stay ordered ----

func test_profiles_stay_ordered_settled_and_unsettled() -> void:
	var profiles: Dictionary = all_cfg()["profiles"]
	var names := ["tiro", "miles", "centurion", "legatus"]
	var max_deg := float(base_cfg()["max_aim_error_deg"])
	for sc in [1.0, scale_of(float(fight()["settle_s"]), 0.0, 100.0)]:
		var prev := INF
		var ordered := true
		for n in names:
			var rng := RandomNumberGenerator.new()
			rng.seed = 7
			var sum := 0.0
			for i in 50:
				sum += BotTargeting.aim_error(float(profiles[n]["accuracy"]), max_deg, rng, sc).length()
			ordered = ordered and sum < prev
			prev = sum
		assert_true(ordered and prev > 0.0, "scale %s: tiro > miles > centurion > legatus" % sc)


# ---- 4: no extra draws ----

## aim_error draws exactly two numbers whatever the scale, and scale 1.0 gives today's floats.
func test_scale_draws_the_same_numbers() -> void:
	var a := RandomNumberGenerator.new()
	var b := RandomNumberGenerator.new()
	var c := RandomNumberGenerator.new()
	a.seed = 99
	b.seed = 99
	c.seed = 99
	var same_one := true
	for i in 30:
		var ea := BotTargeting.aim_error(0.35, 12.0, a, 0.2 + float(i) / 40.0)
		var eb := BotTargeting.aim_error(0.35, 12.0, b)
		var ec := BotTargeting.aim_error(0.35, 12.0, c, 1.0)
		same_one = same_one and eb == ec
	assert_eq(a.state, b.state, "the same stream position after 30 draws with and without a scale")
	assert_true(same_one, "scale 1.0 = today's floats")


## Two brains on one bot, settle on and off, one enemy in sight: after several refreshes both the aim stream and
## the route stream are at the same position; only the settled errors are smaller.
func test_settle_adds_no_draws_on_either_stream() -> void:
	await start(big_zone())
	var pair := shooter_and_enemy()
	var bot: Pawn = pair[0]
	var off_cfg := base_cfg()
	off_cfg["fight"]["settle_s"] = 0.0
	var on := add_brain(bot, {}, "On")
	var off := add_brain(bot, off_cfg, "Off")
	await frames(1)
	var refresh_ticks := int(ceil(float(base_cfg()["aim_error_refresh_s"]) / dt()))
	for t in refresh_ticks * 6:
		await frames(1)
		on.build_frame(dt())
		off.build_frame(dt())
	assert_true(on.is_big_map() and on.target_id == (pair[1] as Pawn).player_id, "big map, the enemy in sight")
	assert_eq(on._rng.state, off._rng.state, "aim stream: same position")
	assert_eq(on._route_rng.state, off._route_rng.state, "route stream: same position")
	assert_true(on._settle_s > float(base_cfg()["fight"]["settle_s"]), "settled (%.2f s)" % on._settle_s)
	assert_true(on._aim_scale() < 1.0 and off._aim_scale() == 1.0, "on: scaled, off: not")
	assert_true(on._error.length() < off._error.length(), "settled error smaller (%s vs %s)" % [on._error, off._error])
	m.queue_free()


# ---- 2: the clock resets on a target change and when the target is lost ----

func test_settle_resets_on_a_new_target_and_when_lost() -> void:
	await start(big_zone())
	var pair := shooter_and_enemy()
	var bot: Pawn = pair[0]
	var enemy: Pawn = pair[1]
	var b := add_brain(bot)
	await frames(1)
	for t in 60:
		await frames(1)
		b.build_frame(dt())
	assert_eq(b.target_id, enemy.player_id, "the enemy is the target")
	assert_true(absf(b._settle_s - 59.0 * dt()) < 1e-6, "the clock ran from 0 at the first sight (%.3f)" % b._settle_s)
	assert_eq(b._settle_id, enemy.player_id, "the settle target")
	assert_true(absf(b._settle_dist - 15.0) < 0.1, "flat distance kept (%.2f)" % b._settle_dist)
	# Another enemy, nearer: a different id, the clock starts again.
	var other: Pawn = m.bots[2]
	other.global_position = Vector3(40.0, 0.2, 8.0)
	other.visible = true
	await frames(1)
	b.build_frame(dt())
	assert_eq(b.target_id, other.player_id, "the nearer enemy is the target now")
	assert_eq(b._settle_s, 0.0, "a new target: the clock resets")
	assert_eq(b._aim_scale(), 1.0, "and the scale is 1 again")
	b.build_frame(dt())
	assert_true(b._settle_s > 0.0, "and runs again on the new target")
	# Lost: nobody in sight.
	other.visible = false
	enemy.visible = false
	await frames(1)
	b.build_frame(dt())
	assert_true(b.target_id < 0 and b._settle_s == 0.0 and b._settle_id == -1, "lost: reset")
	# The target's flat speed is what the scale reads.
	b._track_settle(enemy, dt())
	enemy.velocity = Vector3(3.0, -5.0, 4.0)
	b._track_settle(enemy, dt())
	assert_true(absf(b._settle_speed - 5.0) < 1e-6, "flat speed of the target (%s)" % b._settle_speed)
	enemy.velocity = Vector3.ZERO
	m.queue_free()


# ---- 5: small maps unchanged ----

## On a small map the scale is exactly 1.0 however long the bot has aimed, and each draw equals today's formula;
## on a big map the same draw is today's formula times the settle scale.
func test_small_map_draws_today_s_errors() -> void:
	for big in [false, true]:
		await start(big_zone() if big else small_zone())
		var pair := shooter_and_enemy()
		var b := add_brain(pair[0])
		await frames(1)
		var same := true
		var draws := 0
		for t in 200:
			await frames(1)
			var will_draw := b._error_age_s - dt() <= 0.0 and b.target_id >= 0
			var st := b._rng.state
			var settle_before := b._settle_s
			b.build_frame(dt())
			if will_draw and b.target_id >= 0 and settle_before > 0.0:
				var r := RandomNumberGenerator.new()
				r.state = st
				var today := BotTargeting.aim_error(float(b.profile["accuracy"]), float(b.cfg["max_aim_error_deg"]), r)
				var sc := 1.0 if not big else scale_of(b._settle_s, b._settle_speed, b._settle_dist)
				same = same and b._error.is_equal_approx(today * sc)
				if not big:
					same = same and b._error == today
				draws += 1
		assert_true(b.is_big_map() == big, "map size %s" % big)
		assert_true(draws >= 5, "several refreshes checked (%d)" % draws)
		assert_true(same, "big=%s: every draw = today's formula x the scale" % big)
		if not big:
			b._settle_s = 100.0
			assert_eq(b._aim_scale(), 1.0, "small map: the scale is exactly 1.0")
		m.queue_free()
		await frames(1)


# ---- 7: the band's near and far edges for both guns ----

func test_band_edges_for_both_guns() -> void:
	await start(big_zone(), true)
	var bot: Pawn = m.bots[0]
	var enemy: Pawn = m.bots[1]
	var f := fight()
	var step := float(f["strafe_step_m"])
	var push := step * float(f["band_push_frac"])
	for gun in ["pilum_br", "sagittarii_rifle"]:
		arm(bot, gun)
		bot.global_position = Vector3(0.0, 0.2, 0.0)
		var b := add_brain(bot, {}, gun)
		b._ensure_seeded()
		var sight := b.sight_m()
		assert_eq(sight, minf(float(f["sight_by_weapon"][gun]), bot.loadout.get_active().def.range_m), "%s: the data sight" % gun)
		var near_e := sight * float(f["band_near_frac"])
		var far_e := sight * float(f["band_far_frac"])
		var cases := [[far_e + 0.5, "close"], [far_e - 0.5, "band"], [near_e + 0.5, "band"], [near_e - 0.5, "near"]]
		for c in cases:
			b._goal(null, false)  # a think without a fight goal: the next point is fresh
			enemy.global_position = Vector3(float(c[0]), 0.2, 0.0)
			var g := b._goal(enemy, false)
			var label := "%s at %.1f m (near %.1f, far %.1f)" % [gun, float(c[0]), near_e, far_e]
			assert_eq(b.goal_kind, "fight", label + ": fight")
			assert_eq(b._fight_mode, c[1], label + ": mode")
			var off := g - bot.global_position
			if c[1] == "close":
				assert_true(g.is_equal_approx(enemy.global_position) and not b._fight_hold, label + ": walks to the enemy")
			elif c[1] == "band":
				assert_true(b._fight_hold and absf(off.x - push) < 0.01 and absf(absf(off.z) - step) < 0.01, label + ": sideways plus forward (%s)" % off)
			else:
				assert_true(b._fight_hold and absf(off.x) < 0.01 and absf(absf(off.z) - step) < 0.01, label + ": sideways only (%s)" % off)
		# band -> near: the point is recomputed (no forward part) without a draw.
		b._goal(null, false)
		enemy.global_position = Vector3(near_e + 0.5, 0.2, 0.0)
		b._goal(enemy, false)
		var st := b._route_rng.state
		var side := b._strafe_side
		var flip := b._strafe_flip_tick
		enemy.global_position = Vector3(near_e - 0.5, 0.2, 0.0)
		var gn := b._goal(enemy, false)
		assert_true(b._fight_mode == "near" and absf((gn - bot.global_position).x) < 0.01, "%s: band -> near recomputes the point" % gun)
		enemy.global_position = Vector3(near_e + 0.5, 0.2, 0.0)
		var gb := b._goal(enemy, false)
		assert_true(b._fight_mode == "band" and absf((gb - bot.global_position).x - push) < 0.01, "%s: near -> band recomputes the point" % gun)
		assert_true(b._route_rng.state == st and b._strafe_side == side and b._strafe_flip_tick == flip, "%s: no draw, same side and period" % gun)
		b.queue_free()
	# band_near_frac >= band_far_frac: near wins (no band zone; beyond the near edge it closes in).
	var cfg := base_cfg()
	cfg["fight"]["band_near_frac"] = 0.7
	cfg["fight"]["band_far_frac"] = 0.6
	arm(bot, "pilum_br")
	var c2 := add_brain(bot, cfg, "Over")
	c2._ensure_seeded()
	var s2 := c2.sight_m()
	enemy.global_position = Vector3(s2 * 0.65, 0.2, 0.0)
	c2._goal(enemy, false)
	assert_eq(c2._fight_mode, "near", "near >= far: between the edges is near")
	enemy.global_position = Vector3(s2 * 0.75, 0.2, 0.0)
	c2._goal(enemy, false)
	assert_eq(c2._fight_mode, "close", "near >= far: beyond the near edge closes in")
	m.queue_free()
