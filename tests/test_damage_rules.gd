extends "res://tests/test_case.gd"

const Rules := preload("res://scripts/systems/damage_rules.gd")
const HealthStateS := preload("res://scripts/systems/health_state.gd")
const WeaponDefS := preload("res://scripts/weapons/weapon_def.gd")

const CFG := {"shield_regen_delay_s": 5.0, "shield_regen_rate_per_s": 20.0, "overflow_to_health": true}


func _weapon(damage: float, hs: float = 1.5) -> WeaponDef:
	return WeaponDefS.from_dict("t", {"damage": damage, "headshot_multiplier": hs})


func test_shield_then_health() -> void:
	var s := HealthStateS.create(100, 100)
	var r := Rules.apply_hit(s, _weapon(40), false, 0, 1, false, CFG)
	assert_eq(s.shield, 60.0, "shield after hit")
	assert_eq(s.health, 100.0, "health untouched")
	assert_eq(r.shield_damage, 40.0, "shield_damage")
	Rules.apply_hit(s, _weapon(60), false, 0, 1, false, CFG)
	assert_eq(s.shield, 0.0, "shield gone")
	Rules.apply_hit(s, _weapon(30), false, 0, 1, false, CFG)
	assert_eq(s.health, 70.0, "health takes damage once shield is gone")


func test_overflow_carries_into_health() -> void:
	var s := HealthStateS.create(30, 100)
	var r := Rules.apply_hit(s, _weapon(50), false, 0, 1, false, CFG)
	assert_true(r.shield_broken, "shield_broken")
	assert_eq(s.health, 80.0, "overflow into health")
	assert_eq(r.health_damage, 20.0, "health_damage")
	var s2 := HealthStateS.create(30, 100)
	Rules.apply_hit(s2, _weapon(50), false, 0, 1, false, {"overflow_to_health": false})
	assert_eq(s2.health, 100.0, "no overflow when disabled")


func test_headshot_multiplier_applied() -> void:
	var s := HealthStateS.create(100, 100)
	var r := Rules.apply_hit(s, _weapon(20, 2.0), true, 0, 1, false, CFG)
	assert_eq(r.damage_dealt, 40.0, "headshot damage")
	assert_eq(s.shield, 60.0, "shield after headshot")


func test_no_friendly_fire() -> void:
	var s := HealthStateS.create(100, 100)
	var r := Rules.apply_hit(s, _weapon(50), false, 2, 2, false, CFG)
	assert_eq(r.damage_dealt, 0.0, "damage")
	assert_eq(r.blocked_reason, "friendly", "reason")
	assert_eq(s.shield, 100.0, "shield untouched")


func test_spawn_protected_takes_no_damage() -> void:
	var s := HealthStateS.create(100, 100)
	var r := Rules.apply_hit(s, _weapon(500), false, 0, 1, true, CFG)
	assert_eq(r.blocked_reason, "protected", "reason")
	assert_true(not r.killed, "not killed")
	assert_eq(s.shield, 100.0, "shield untouched")
	assert_eq(s.health, 100.0, "health untouched")


func test_kill_reported_when_health_zero() -> void:
	var s := HealthStateS.create(10, 20)
	var r := Rules.apply_hit(s, _weapon(25), false, 0, 1, false, CFG)
	assert_true(not r.killed, "alive at 5 health")
	r = Rules.apply_hit(s, _weapon(25), false, 0, 1, false, CFG)
	assert_true(r.killed, "killed")
	assert_true(s.is_dead(), "dead state")
	r = Rules.apply_hit(s, _weapon(25), false, 0, 1, false, CFG)
	assert_true(not r.killed, "no second kill")
	assert_eq(r.blocked_reason, "dead", "dead reason")


func test_regen_waits_for_delay_then_refills() -> void:
	var s := HealthStateS.create(100, 100)
	Rules.apply_hit(s, _weapon(60), false, 0, 1, false, CFG)
	Rules.tick_regen(s, 4.0, CFG)
	assert_eq(s.shield, 40.0, "no regen before delay")
	Rules.tick_regen(s, 2.0, CFG)  # 1 s past the delay at 20/s
	assert_eq(s.shield, 60.0, "regen only for time past delay")
	Rules.tick_regen(s, 10.0, CFG)
	assert_eq(s.shield, 100.0, "clamped to max")
	Rules.apply_hit(s, _weapon(10), false, 0, 1, false, CFG)
	Rules.tick_regen(s, 3.0, CFG)
	assert_eq(s.shield, 90.0, "damage resets the delay")
