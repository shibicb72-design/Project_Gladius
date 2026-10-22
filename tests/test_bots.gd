extends "res://tests/test_case.gd"

const _MatchScene := preload("res://scenes/match/match.tscn")
const BOTS_PATH := "res://data/bots.json"


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file(BOTS_PATH)


func test_fill_counts_from_data() -> void:
	var plan := BotSpawner.plan_fill({0: 1}, _cfg(), 2)
	assert_eq(plan.size(), 5, "1 human -> 5 bots for 2x3")
	var per_squad := {0: 0, 1: 0}
	for e in plan:
		per_squad[e["squad"]] += 1
	assert_eq(per_squad[0], 2, "squad 0 bots")
	assert_eq(per_squad[1], 3, "squad 1 bots")
	assert_eq(BotSpawner.plan_fill({0: 3, 1: 3}, _cfg(), 2).size(), 0, "full squads need no bots")


func test_bots_alternate_classes() -> void:
	var plan := BotSpawner.plan_fill({0: 1}, _cfg(), 2)
	var rotation: Array = _cfg()["class_rotation"]
	for i in plan.size():
		assert_eq(plan[i]["class_id"], rotation[i % rotation.size()], "class of bot %d" % i)
	assert_true(plan[0]["class_id"] != plan[1]["class_id"], "neighbouring bots differ")


func test_targeting_picks_nearest_visible_enemy_not_teammate() -> void:
	var cands := [
		{"id": 1, "pos": Vector3(2, 0, 0), "squad": 0, "alive": true, "visible": true},   # teammate
		{"id": 2, "pos": Vector3(10, 0, 0), "squad": 1, "alive": true, "visible": true},
		{"id": 3, "pos": Vector3(5, 0, 0), "squad": 1, "alive": true, "visible": false},  # hidden
		{"id": 4, "pos": Vector3(4, 0, 0), "squad": 1, "alive": false, "visible": true},  # dead
		{"id": 5, "pos": Vector3(20, 0, 0), "squad": 1, "alive": true, "visible": true},
	]
	assert_eq(BotTargeting.pick_target(Vector3.ZERO, 0, cands, 60.0), 2, "nearest visible living enemy")
	assert_eq(BotTargeting.pick_target(Vector3.ZERO, 0, cands, 5.0), -1, "none in range")
	assert_eq(BotTargeting.pick_target(Vector3.ZERO, 0, [], 60.0), -1, "no candidates")


func test_aim_error_scales_with_accuracy() -> void:
	var low := 0.0
	var high := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in 200:
		low += BotTargeting.aim_error(0.2, 12.0, rng).length()
	rng.seed = 42
	for i in 200:
		high += BotTargeting.aim_error(0.9, 12.0, rng).length()
	assert_true(low > high * 3.0, "low accuracy errs more (%s vs %s)" % [low, high])
	assert_eq(BotTargeting.aim_error(1.0, 12.0, rng), Vector2.ZERO, "perfect accuracy has no error")


func test_bot_profile_fields_present() -> void:
	var profiles: Dictionary = _cfg()["profiles"]
	for name in ["tiro", "miles", "centurion", "legatus"]:
		assert_true(profiles.has(name), "profile " + name)
		for field in ["accuracy", "reaction_time_s", "damage_mult", "health_mult", "aim_smartness", "grenade_freq"]:
			assert_true(profiles.get(name, {}).has(field), "%s.%s" % [name, field])
	assert_true(_cfg()["match_fill"]["profile"] in profiles, "match_fill profile exists")
	assert_eq(BotCommands.enabled_from(_cfg()).size(), 0, "no commands in milestone 1")


func test_bot_moves_toward_hill() -> void:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 60.0
	assert_true(m.begin(), "begin succeeds")
	assert_eq(m.bots.size(), 5, "five bots spawned")
	await tree.physics_frame
	var bot: Pawn = m.bots[m.bots.size() - 1]  # squad 1, away from the player
	var center: Vector3 = m.zone.global_position
	var start := bot.global_position.distance_to(center)
	for i in 180:
		await tree.physics_frame
	var after := bot.global_position.distance_to(center)
	assert_true(after < start - 1.0, "bot closed on hill: %s -> %s" % [start, after])
	m.queue_free()
