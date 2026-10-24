extends "res://tests/test_case.gd"

const SpawnS := preload("res://scripts/systems/spawn_rules.gd")

const CFG := {"respawn_s": 5, "spawn_protection_s": 5}


func _spawn() -> SpawnRules:
	var s: SpawnRules = SpawnS.new()
	s.setup(CFG)
	return s


func test_squad_spot_fixed_for_match() -> void:
	var s := _spawn()
	s.assign_squad_spots([0, 1, 2], ["a", "b", "c", "d"], 42)
	var first = s.squad_spot(1)
	s.start_respawn("p1")
	s.tick(6.0)
	assert_eq(s.squad_spot(1), first, "spot unchanged after respawn")
	var s2 := _spawn()
	s2.assign_squad_spots([0, 1, 2], ["a", "b", "c", "d"], 42)
	assert_eq(s2.squad_spot(1), first, "same seed gives same spot")


func test_spots_unique_per_squad() -> void:
	for seed_value in 20:
		var s := _spawn()
		assert_true(s.assign_squad_spots([0, 1, 2, 3, 4, 5], ["a", "b", "c", "d", "e", "f"], seed_value), "assign ok")
		var seen := {}
		for q in 6:
			seen[s.squad_spot(q)] = true
		assert_eq(seen.size(), 6, "unique spots for seed %d" % seed_value)
	var s3 := _spawn()
	assert_true(not s3.assign_squad_spots([0, 1], ["a"], 1), "too few spots rejected")


func test_respawn_after_5s() -> void:
	var s := _spawn()
	s.start_respawn("p")
	assert_eq(s.tick(4.9).size(), 0, "not yet")
	assert_true(s.is_waiting_respawn("p"), "still waiting")
	assert_eq(s.tick(0.2), ["p"], "respawned")
	assert_true(not s.is_waiting_respawn("p"), "no longer waiting")
	assert_true(s.is_protected("p"), "protected on spawn")


func test_protection_ends_on_fire() -> void:
	var s := _spawn()
	s.spawn_now("p")
	assert_true(s.is_protected("p"), "protected")
	s.notify_event("p", "fire")
	assert_true(not s.is_protected("p"), "fire ends protection")


func test_protection_survives_pickup_event() -> void:
	var s := _spawn()
	s.spawn_now("p")
	s.notify_event("p", "pickup")
	assert_true(s.is_protected("p"), "pickup keeps protection")


func test_protection_expires_after_5s() -> void:
	var s := _spawn()
	s.spawn_now("p")
	s.tick(4.9)
	assert_true(s.is_protected("p"), "still protected at 4.9")
	s.tick(0.2)
	assert_true(not s.is_protected("p"), "expired")
