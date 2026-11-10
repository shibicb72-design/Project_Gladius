extends "res://tests/test_case.gd"
## M1 S5: battle royale bot brain goals in the real match scene: seek a gun, follow the zone, revive a mate,
## charge with the blade. (A full bot-only match runs on demand: tests/sim/, not in the suite.)

const _MatchScene := preload("res://scenes/match/match.tscn")

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


func start(zone: Dictionary, mode: String = "solo", loot: bool = true, revive_s: float = -1.0) -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 2718
	m.ground_loot = loot
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	if revive_s > 0.0:
		m.director.mode_cfg["downed"]["revive_s"] = revive_s
	assert_true(m.begin(), "begin")
	await frames(2)


static func calm_zone() -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}


## Only `keep` thinks; every other bot is idle and moved far away so nobody is in sight.
func isolate(keep: Pawn) -> void:
	var i := 0
	for b in m.bots:
		if b == keep:
			continue
		b.get_node("Brain").set_physics_process(false)
		b.global_position = Vector3(-70.0 + float(i % 6) * 4.0, 0.2, -70.0 + float(i / 6) * 4.0)
		i += 1
	m.local_player.global_position = Vector3(70.0, 0.2, -70.0)


func test_unarmed_bot_goes_for_a_gun_and_picks_it_up() -> void:
	await start(calm_zone())
	var bot: Pawn = m.bots[0]
	isolate(bot)
	for id in m.loot.items.keys():
		m.loot.take(id)
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	m.loot.drop({"item_id": "pilum_br"}, Vector3(6.0, 0.0, 0.0))
	await frames(2)
	assert_eq(bot.get_node("Brain").goal_kind, "loot", "goal is the gun")
	var n := 0
	while bot.loadout.slots[0] == null and n < 400:
		await frames(1)
		n += 1
	assert_true(bot.loadout.slots[0] != null and bot.loadout.slots[0].def.id == "pilum_br", "picked up the gun")
	m.queue_free()


func test_bot_heads_into_the_closing_zone() -> void:
	var zone := {"start_center": [0, 0], "start_radius_m": 80.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 0.0, "shrink_s": 200.0, "radius_m": 6.0, "damage_per_s": 0.0}]}
	await start(zone, "solo", false)
	var bot: Pawn = m.bots[0]
	isolate(bot)
	bot.global_position = Vector3(40.0, 0.2, 0.0)
	await frames(2)
	assert_eq(bot.get_node("Brain").goal_kind, "zone", "shrinking zone: goal is the next circle")
	var c := m.director.zone_target_center()
	var before := Vector2(bot.global_position.x - c.x, bot.global_position.z - c.z).length()
	await frames(120)
	var after := Vector2(bot.global_position.x - c.x, bot.global_position.z - c.z).length()
	assert_true(after < before - 2.0, "closed in: %.1f -> %.1f" % [before, after])
	m.queue_free()


func test_bot_revives_a_downed_squad_mate() -> void:
	await start(calm_zone(), "squads", false, 0.5)
	var bot: Pawn = m.bots[0]
	var mate: Pawn = null
	for b in m.bots:
		if b != bot and b.squad_id == bot.squad_id:
			mate = b
			break
	assert_true(mate != null, "a squad mate exists")
	isolate(bot)
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	mate.global_position = Vector3(5.0, 0.2, 0.0)
	m.director.rules.report_zero_health(mate.player_id, -1, "zone")
	await frames(2)
	assert_true(mate.is_downed(), "mate downed")
	var n := 0
	while mate.is_downed() and n < 300:
		await frames(1)
		n += 1
	assert_eq(mate.life, Pawn.Life.ALIVE, "the bot walked over and revived its mate")
	m.queue_free()


func test_blade_only_bot_charges_a_close_enemy() -> void:
	await start(calm_zone())
	var bot: Pawn = m.bots[0]
	isolate(bot)
	var enemy: Pawn = m.bots[1]
	bot.global_position = Vector3(0.0, 0.2, 0.0)
	enemy.global_position = Vector3(0.0, 0.2, -8.0)
	enemy.visible = true
	await frames(30)
	assert_eq(bot.get_node("Brain").goal_kind, "chase", "blade only: chase the close enemy")
	var d := Vector2(bot.global_position.x - enemy.global_position.x, bot.global_position.z - enemy.global_position.z).length()
	assert_true(d < 7.0, "closed the distance (%.1f m)" % d)
	m.queue_free()


func test_bot_reloads_an_empty_gun_and_swaps_off_the_blade() -> void:
	await start(calm_zone())
	var bot: Pawn = m.bots[0]
	isolate(bot)
	bot.take_item({"item_id": "pilum_br"}, m.loot.def("pilum_br"))
	var gun := bot.loadout.slots[0]
	gun.ammo_in_mag = 0
	gun.reserve = 30
	await frames(3)
	assert_true(gun.reloading or gun.ammo_in_mag > 0, "an empty gun with reserve gets reloaded")
	var n := 0
	while gun.ammo_in_mag == 0 and n < 300:
		await frames(1)
		n += 1
	assert_true(gun.ammo_in_mag > 0, "and the magazine refills")
	bot.loadout.active = 1  # the blade
	await frames(40)
	assert_eq(bot.loadout.active, 0, "a bot holding the blade swaps to its loaded gun")
	gun.ammo_in_mag = 0
	gun.reserve = 0
	await frames(40)
	assert_true(bot.loadout.get_active().def.is_melee(), "a gun with no ammo at all is put away for the blade")
	m.queue_free()


## A pawn driven frame by frame (its brain off): fire until the magazine is empty.
func _fire_until_empty(p: Pawn) -> void:
	var w := p.loadout.get_active()
	var n := 0
	while w.ammo_in_mag > 0 and n < 240:
		var f := InputFrame.new()
		f.fire_pressed = true
		f.fire_just_pressed = (n % 2) == 0
		p.set_frame(f)
		await frames(1)
		n += 1
	p.set_frame(InputFrame.new())
	await frames(1)


func test_a_gun_that_runs_dry_by_firing_auto_reloads() -> void:
	await start(calm_zone(), "solo", false)
	var p: Pawn = m.bots[0]
	isolate(p)
	p.get_node("Brain").set_physics_process(false)
	var w := p.loadout.get_active()
	assert_true(w != null and not w.def.is_melee(), "class loadout starts with a gun")
	w.ammo_in_mag = 2
	w.reserve = 30
	await _fire_until_empty(p)
	assert_true(w.reloading, "fired its last round with reserve left: reloading started by itself")
	# Flag off: no auto-reload.
	w.cancel_reload()
	w.ammo_in_mag = 2
	p.bridge.combat_cfg["auto_reload_on_empty"] = false
	await _fire_until_empty(p)
	assert_true(not w.reloading, "flag off: no automatic reload")
	# No reserve: nothing to reload.
	p.bridge.combat_cfg["auto_reload_on_empty"] = true
	w.ammo_in_mag = 2
	w.reserve = 0
	await _fire_until_empty(p)
	assert_true(not w.reloading, "no reserve: no reload")
	m.queue_free()


func test_same_match_seed_gives_the_same_bot_and_pawn_draws() -> void:
	var a := BotBrain.new()
	var b := BotBrain.new()
	var d := MatchDirector.new()
	d.match_seed = 4242
	var pa := Pawn.new()
	var pb := Pawn.new()
	pa.player_id = 107
	pb.player_id = 107
	a.setup(pa, d, {}, {})
	b.setup(pb, d, {}, {})
	a._ensure_seeded()
	b._ensure_seeded()
	assert_eq(a._spot_dir, b._spot_dir, "same seed and id: same landing spot direction")
	pa.player_id = 108
	var c := BotBrain.new()
	c.setup(pa, d, {}, {})
	c._ensure_seeded()
	assert_true(c._spot_dir != a._spot_dir, "another player id: another spot")
	pa.seed_rng(hash([4242, 107]))
	pb.seed_rng(hash([4242, 107]))
	assert_eq(pa._rng.randf(), pb._rng.randf(), "pawn spread RNG repeats for the same seed")
	for n in [a, b, c]:
		n.free()
	pa.free()
	pb.free()
	d.free()
