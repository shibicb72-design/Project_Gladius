extends "res://tests/test_case.gd"

const KothS := preload("res://scripts/systems/koth_rules.gd")
const ModeRegistryS := preload("res://scripts/systems/mode_registry.gd")

const CFG := {"rules": "koth", "points_per_second": 1, "score_to_win": 100, "time_limit_s": 600}


func _koth(cfg: Dictionary = CFG) -> KothRules:
	var k: KothRules = KothS.new()
	k.setup(cfg)
	k.register_squads([0, 1])
	return k


func test_uncontested_scores_one_per_second() -> void:
	var k := _koth()
	for i in 10:
		k.tick(1.0, {0: 2})
	assert_eq(k.scores[0], 10.0, "squad 0 score")
	assert_eq(k.scores[1], 0.0, "squad 1 score")


func test_contested_scores_nothing() -> void:
	var k := _koth()
	k.tick(5.0, {0: 1, 1: 1})
	assert_eq(k.scores[0], 0.0, "squad 0")
	assert_eq(k.scores[1], 0.0, "squad 1")


func test_empty_hill_scores_nothing() -> void:
	var k := _koth()
	k.tick(5.0, {})
	k.tick(5.0, {0: 0})
	assert_eq(k.scores[0], 0.0, "squad 0")


func test_first_to_100_wins() -> void:
	var k := _koth()
	for i in 99:
		k.tick(1.0, {1: 1})
	assert_true(not k.is_over(), "not over at 99")
	var events := k.tick(1.0, {1: 1})
	assert_true(k.is_over(), "over at 100")
	assert_eq(k.result()["winner"], 1, "winner")
	assert_eq(events.back()["type"], "match_over", "match_over event")


func test_timer_ends_highest_wins() -> void:
	var k := _koth({"points_per_second": 1, "score_to_win": 100, "time_limit_s": 20})
	for i in 5:
		k.tick(1.0, {0: 1})
	for i in 15:
		k.tick(1.0, {})
	assert_true(k.is_over(), "over at time limit")
	assert_eq(k.result()["winner"], 0, "winner")
	assert_true(not k.result()["draw"], "no draw")


func test_timer_tie_is_draw() -> void:
	var k := _koth({"points_per_second": 1, "score_to_win": 100, "time_limit_s": 10})
	for i in 10:
		k.tick(1.0, {})
	assert_true(k.is_over(), "over")
	assert_true(k.result()["draw"], "draw")
	assert_eq(k.result()["winner"], -1, "no winner")


func test_mode_registry_resolves_koth() -> void:
	var modes := {"koth": CFG}
	var r := ModeRegistryS.create("koth", modes)
	assert_true(r != null and r is KothRules, "koth resolves to KothRules")
	assert_true(ModeRegistryS.create("nope", modes) == null, "unknown mode is null")
