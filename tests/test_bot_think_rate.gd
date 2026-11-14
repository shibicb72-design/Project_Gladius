extends "res://tests/test_case.gd"
## M2P1C stop 7 (OQ-BOT-THINK): the bot think rate. A bot farther than think_rate.far_distance_m from every
## human that is not dead runs a full think only when (director.tick_count + player_id) % far_interval_ticks
## == 0; between thinks it coasts on the last decision (move along the path, turn-limited look, timers).
## The brains under test are driven by hand once per physics tick; every bot's own Brain is switched off.

const _MatchScene := preload("res://scenes/match/match.tscn")
const INTERVAL := 4
const FAR_M := 60.0

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


func dt() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)


## A match whose next circle closes on the centre (so a bot walks), no loot, every bot brain off and every
## other bot parked far away; the human stands at `human_at`.
func start(human_at: Vector3) -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = false
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 80.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 0.0, "shrink_s": 200.0, "radius_m": 6.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = "solo"
	assert_true(m.begin(), "begin")
	var i := 0
	for b in m.bots:
		b.get_node("Brain").set_physics_process(false)
		b.set_frame(InputFrame.new())
		b.global_position = Vector3(-70.0 + float(i % 6) * 4.0, 0.2, 60.0 + float(i / 6) * 4.0)
		i += 1
	m.local_player.global_position = human_at
	await frames(2)


func cfg_with(rate: Dictionary) -> Dictionary:
	var c: Dictionary = DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).duplicate(true)
	if rate.is_empty():
		c.erase("think_rate")
	else:
		c["think_rate"] = rate
	return c


func rate_on() -> Dictionary:
	return {"far_distance_m": FAR_M, "far_interval_ticks": INTERVAL}


## A fresh brain on `pawn` (not named Brain; the pawn's own Brain is off).
func add_brain(pawn: Pawn, cfg: Dictionary, tag: String) -> BotBrain:
	var cfg_all := DataRegistry.new().load_file("res://data/bots.json")
	var profile: Dictionary = cfg_all.get("profiles", {}).get("tiro", {})
	var b := BotBrain.new()
	b.name = "Test" + tag
	b.setup(pawn, m.director, profile, cfg)
	pawn.add_child(b)
	b.set_physics_process(false)  # driven by hand
	return b


static func fs(f: InputFrame) -> String:
	return "%s|%s|%s%s%s%s%s%s%s" % [var_to_str(f.move), var_to_str(f.look), int(f.fire_pressed), int(f.fire_just_pressed),
			int(f.jump_pressed), int(f.jump_just_pressed), int(f.reload_pressed), int(f.reload_just_pressed),
			int(f.swap_weapon_just_pressed)]


func walker() -> Pawn:
	var bot: Pawn = m.bots[0]
	bot.global_position = Vector3(40.0, 0.2, 0.0)
	return bot


## Near (a human 6 m away): the think-rate brain gives exactly the frames of today's build_frame, tick by tick.
func test_near_bot_thinks_every_tick_like_today() -> void:
	await start(Vector3(44.0, 0.2, 4.0))
	m.local_player.visible = false  # not a target (so it is never shot dead), still a human nearby
	var bot := walker()
	var sub := add_brain(bot, cfg_with(rate_on()), "Sub")
	var ref := add_brain(bot, cfg_with({}), "Ref")
	await frames(1)
	var same := true
	for t in 120:
		await frames(1)
		var fr := ref.build_frame(dt())
		var fsub := sub.next_frame(dt())
		if fs(fr) != fs(fsub):
			same = false
			print("near tick %d: ref %s sub %s" % [t, fs(fr), fs(fsub)])
			break
		bot.set_frame(fsub)
	assert_true(same, "near bot frames equal today's frames for 120 ticks")
	assert_eq(sub.think_ticks, sub.brain_ticks, "near bot: every tick a full think")
	assert_true(sub.brain_ticks == 120, "counted 120 grounded ticks (%d)" % sub.brain_ticks)
	m.queue_free()


## Far (no human within 60 m): full thinks only on (tick_count + player_id) % 4 == 0; two bots stagger.
func test_far_bot_thinks_on_its_cadence_and_bots_stagger() -> void:
	await start(Vector3(-70.0, 0.2, -70.0))
	var a := walker()
	var b: Pawn = m.bots[1]
	b.global_position = Vector3(-30.0, 0.2, -20.0)
	assert_true(posmod(a.player_id - b.player_id, INTERVAL) != 0, "the two ids fall on different cadence ticks")
	var ba := add_brain(a, cfg_with(rate_on()), "A")
	var bb := add_brain(b, cfg_with(rate_on()), "B")
	await frames(1)
	var think_a: Array = []
	var think_b: Array = []
	var cadence_ok := true
	for t in 80:
		await frames(1)
		var tick := m.director.tick_count
		var na := ba.think_ticks
		var nb := bb.think_ticks
		a.set_frame(ba.next_frame(dt()))
		b.set_frame(bb.next_frame(dt()))
		if ba.think_ticks > na:
			think_a.append(tick)
		if bb.think_ticks > nb:
			think_b.append(tick)
		if t > 0:  # the first grounded tick always thinks (there is no decision to keep yet)
			cadence_ok = cadence_ok and (ba.think_ticks > na) == (posmod(tick + a.player_id, INTERVAL) == 0)
			cadence_ok = cadence_ok and (bb.think_ticks > nb) == (posmod(tick + b.player_id, INTERVAL) == 0)
	assert_true(cadence_ok, "far bots think exactly on their cadence ticks: a %s b %s" % [think_a, think_b])
	assert_true(think_a.size() >= 19 and think_a.size() <= 21, "a thought %d of 80 ticks" % think_a.size())
	var shared := 0
	for t in think_a:
		if think_b.has(t):
			shared += 1
	assert_true(shared <= 1, "staggered: %d shared think ticks" % shared)
	m.queue_free()


## A skipped tick: no one-shots and no fire; the look is this tick's turn-limited delta toward the last
## decided yaw/pitch; the move keeps its world direction when the pawn is turned; the bot walks on.
func test_skipped_tick_coasts_on_the_last_decision() -> void:
	await start(Vector3(-70.0, 0.2, -70.0))
	var bot := walker()
	var enemy: Pawn = m.bots[1]
	var sub := add_brain(bot, cfg_with(rate_on()), "Sub")
	await frames(1)
	bot.rotation.y = BotTargeting.yaw_of(Vector3(-1.0, 0.0, 0.0)) + PI  # facing away from the circle
	var turn := float(sub.cfg.get("turn_rate_rad_s", 6.0)) * dt()
	var start_pos := bot.global_position
	var start_d := 0.0
	var skipped := 0
	var oneshots_clear := true
	var look_ok := true
	var look_changed := false
	var world_ok := true
	var prev_look := Vector2.INF
	for t in 90:
		await frames(1)
		var n := sub.think_ticks
		var want := BotTargeting.look_toward(bot.rotation.y, bot.pitch, sub._last_yaw, sub._last_pitch, turn)
		var f := sub.next_frame(dt())
		if sub.think_ticks == n:
			skipped += 1
			oneshots_clear = oneshots_clear and not (f.jump_just_pressed or f.swap_weapon_just_pressed \
					or f.reload_just_pressed or f.fire_just_pressed or f.fire_pressed or f.reload_pressed)
			look_ok = look_ok and f.look.is_equal_approx(want) and absf(f.look.x) <= turn + 1e-6
			if prev_look != Vector2.INF and not f.look.is_equal_approx(prev_look):
				look_changed = true
			# Same tick, pawn turned by 0.7 rad: the coast re-expresses the same world direction.
			var w1 := bot.global_transform.basis * Vector3(f.move.x, 0.0, f.move.y)
			var saved := bot.rotation.y
			bot.rotation.y += 0.7
			var unstick := sub._unstick_left
			var stuck := sub._stuck_t
			var f2 := sub._coast_frame(0.0)
			sub._unstick_left = unstick
			sub._stuck_t = stuck
			var w2 := bot.global_transform.basis * Vector3(f2.move.x, 0.0, f2.move.y)
			bot.rotation.y = saved
			world_ok = world_ok and w1.is_equal_approx(w2) and w1.length() > 0.5
		prev_look = f.look
		bot.set_frame(f)
	var goal := Vector2(sub._last_goal.x, sub._last_goal.z)
	start_d = goal.distance_to(Vector2(start_pos.x, start_pos.z))
	var end_d := goal.distance_to(Vector2(bot.global_position.x, bot.global_position.z))
	assert_eq(sub.goal_kind, "zone", "walking to its spot in the next circle")
	assert_true(skipped >= 60, "most ticks coasted (%d of 90)" % skipped)
	assert_true(oneshots_clear, "skipped ticks press no one-shot, no fire, no reload")
	assert_true(look_ok, "skipped-tick look = look_toward(last yaw/pitch, this tick's turn)")
	assert_true(look_changed, "the look delta is recomputed (it shrinks as the bot lines up), never reused")
	assert_true(world_ok, "the kept move is a world direction, re-expressed in the turned pawn's frame")
	assert_true(end_d < start_d - 2.0, "the far bot walked its path toward the circle: %.1f -> %.1f" % [start_d, end_d])
	assert_true(enemy.is_alive(), "no fight in this scenario")
	m.queue_free()


## Timers run every tick: with an enemy in sight and the frames not applied (static world), the far brain's
## aim timers, aim error and swap cooldown equal a brain that thinks every tick after T seconds.
func test_timers_advance_every_tick() -> void:
	await start(Vector3(-70.0, 0.2, -70.0))
	var bot := walker()
	var enemy: Pawn = m.bots[1]
	enemy.global_position = Vector3(40.0, 0.2, -15.0)
	enemy.visible = true
	var sub := add_brain(bot, cfg_with(rate_on()), "Sub")
	var ref := add_brain(bot, cfg_with({}), "Ref")
	await frames(1)
	sub._swap_cooldown = 0.5
	ref._swap_cooldown = 0.5
	var max_dev := 0.0
	for t in 100:  # 1.67 s: several aim-error refreshes (0.5 s)
		await frames(1)
		ref.build_frame(dt())
		sub.next_frame(dt())
		max_dev = maxf(max_dev, absf(sub._error_age_s - ref._error_age_s))
		max_dev = maxf(max_dev, absf(sub._seen_for_s - ref._seen_for_s))
		max_dev = maxf(max_dev, absf(sub._swap_cooldown - ref._swap_cooldown))
	assert_true(sub.think_ticks < 40, "the far brain coasted (%d thinks)" % sub.think_ticks)
	assert_true(ref._seen_for_s > 1.0, "the enemy stayed in sight (%.2f s)" % ref._seen_for_s)
	assert_true(max_dev <= dt() + 1e-6, "timers within one tick: max deviation %.4f s" % max_dev)
	assert_true(sub._error.is_equal_approx(ref._error), "same aim error draw on the same tick")
	assert_eq(sub._swap_cooldown, 0.0, "swap cooldown ran out")
	m.queue_free()


## Who counts: a dead human does not; an alive idle human does; a far bot turns near within one interval.
func test_human_rule_and_becoming_near() -> void:
	await start(Vector3(-70.0, 0.2, -70.0))
	var bot := walker()
	var sub := add_brain(bot, cfg_with(rate_on()), "Sub")
	await frames(1)
	var human := m.local_player
	human.visible = false  # not a target; it still counts as a human
	assert_true(not human.has_node("Brain"), "the human has no brain")
	assert_true(not sub._human_within(FAR_M), "human 130 m away: far")
	human.global_position = bot.global_position + Vector3(5.0, 0.0, 0.0)
	assert_true(sub._human_within(FAR_M), "alive idle human 5 m away: near")
	human.life = Pawn.Life.DEAD
	assert_true(not sub._human_within(FAR_M), "a dead human does not count")
	human.life = Pawn.Life.DOWNED
	assert_true(not sub._human_within(FAR_M), "a downed human does not count (alive humans only)")
	human.life = Pawn.Life.ALIVE
	human.global_position = Vector3(-70.0, 0.2, -70.0)
	for t in 12:  # settle into the far cadence
		await frames(1)
		bot.set_frame(sub.next_frame(dt()))
	assert_true(not sub._near, "far before the human comes")
	human.global_position = bot.global_position + Vector3(5.0, 0.0, 0.0)
	var late := -1
	for t in INTERVAL * 3:
		await frames(1)
		bot.set_frame(sub.next_frame(dt()))
		if sub._near and late < 0:
			late = t
	assert_true(late >= 0 and late <= INTERVAL - 1, "near within one interval (after %d ticks)" % late)
	var n := sub.think_ticks
	for t in INTERVAL * 2:
		await frames(1)
		bot.set_frame(sub.next_frame(dt()))
	assert_eq(sub.think_ticks - n, INTERVAL * 2, "near: thinks every tick")
	m.queue_free()


## Feature off (interval 1, or distance 0): a far bot gives today's build_frame frames tick by tick.
func test_feature_off_equals_today() -> void:
	for rate in [{"far_distance_m": FAR_M, "far_interval_ticks": 1}, {"far_distance_m": 0.0, "far_interval_ticks": INTERVAL}]:
		await start(Vector3(-70.0, 0.2, -70.0))
		var bot := walker()
		var sub := add_brain(bot, cfg_with(rate), "Sub")
		var ref := add_brain(bot, cfg_with({}), "Ref")
		await frames(1)
		var same := true
		for t in 60:
			await frames(1)
			var fr := ref.build_frame(dt())
			var fsub := sub.next_frame(dt())
			same = same and fs(fr) == fs(fsub)
			bot.set_frame(fsub)
		assert_true(same, "feature off %s: frames equal today's" % [str(rate)])
		assert_eq(sub.think_ticks, sub.brain_ticks, "feature off: every tick thinks")
		m.queue_free()
		await tree().process_frame


func _scripted_run() -> Array:
	await start(Vector3(-70.0, 0.2, -70.0))
	var bot := walker()
	var enemy: Pawn = m.bots[1]
	enemy.global_position = Vector3(30.0, 0.2, -12.0)
	enemy.visible = true
	var sub := add_brain(bot, cfg_with(rate_on()), "Sub")
	await frames(1)
	var seq: Array = []
	for t in 90:
		await frames(1)
		var f := sub.next_frame(dt())
		seq.append(fs(f))
		bot.set_frame(f)
	m.queue_free()
	await tree().process_frame
	return seq


## The same scripted scenario twice in one process: identical frames (the cadence is per match).
func test_deterministic_per_match() -> void:
	var a := await _scripted_run()
	var b := await _scripted_run()
	assert_eq(a.size(), 90, "ran 90 ticks")
	assert_true(a == b, "same scenario, same frame sequence")


## Report only: the share of grounded bot ticks that were full thinks in a sim-like match (all bots on their
## own brains with the data think rate, the human idle at its spawn, real loot).
func test_report_think_share() -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 99
	m.ground_loot = true
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	assert_true(m.begin(), "begin")
	await frames(600)
	var thinks := 0
	var ticks := 0
	for b in m.bots:
		var brain: BotBrain = b.get_node("Brain")
		thinks += brain.think_ticks
		ticks += brain.brain_ticks
	var rate: Dictionary = DataRegistry.new().load_file("res://data/bots.json")["brain"]["think_rate"]
	print("BOT_THINK far_distance_m=%s far_interval_ticks=%s bots=%d ticks=%d thinks=%d share=%.2f" % [
			rate["far_distance_m"], rate["far_interval_ticks"], m.bots.size(), ticks, thinks, float(thinks) / maxf(ticks, 1.0)])
	assert_true(ticks > 0 and thinks < ticks, "some bot ticks coasted")
	m.queue_free()
