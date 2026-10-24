extends "res://tests/test_case.gd"
## DESIGN.md:15 melee rule for the Gladius Lux swing (OQ-56): front = 70% of FULL shield, Gladiator front
## breaks a full shield, behind = instant kill. Back angle and the no-shield front case are placeholders.

func _cfg() -> Dictionary:
	return DataRegistry.new().get_melee_cfg()


func _hit(state: HealthState, behind: bool, gladiator: bool) -> DamageRules.HitResult:
	return DamageRules.apply_melee(state, 0, 1, false, behind, gladiator, _cfg())


func test_melee_cfg_is_in_data_and_validates() -> void:
	var cfg := _cfg()
	assert_eq(float(cfg.get("melee_front_shield_fraction", 0.0)), 0.7, "DESIGN.md:15 front fraction 0.7")
	assert_true(float(cfg.get("melee_back_angle_deg", 0.0)) > 0.0, "back angle threshold read from data")
	assert_true("melee_back_angle_deg" in cfg.get("_placeholders", []), "back angle marked placeholder")
	assert_true("front_hit_no_shield_rule" in cfg.get("_placeholders", []), "no-shield rule marked placeholder")
	assert_eq(DataRegistry.new().validate(), PackedStringArray(), "registry validates clean")


func test_front_hit_takes_70_percent_of_full_shield() -> void:
	var s := HealthState.create(100.0, 100.0)
	var r := _hit(s, false, false)
	assert_eq(s.shield, 30.0, "70% of full shield removed")
	assert_eq(s.health, 100.0, "health untouched")
	assert_true(not r.killed and not r.shield_broken, "not broken, not killed")
	# Damaged shield: still 70% of the FULL value, not of the current one.
	var s2 := HealthState.create(100.0, 100.0)
	s2.shield = 50.0
	_hit(s2, false, false)
	assert_eq(s2.shield, 0.0, "50 left, 70 of full dealt: shield gone")
	assert_eq(s2.health, 80.0, "overflow of 20 goes to health through the normal path")


func test_gladiator_front_hit_breaks_a_full_shield() -> void:
	var s := HealthState.create(140.0, 130.0)  # Triarii shield
	var r := _hit(s, false, true)
	assert_eq(s.shield, 0.0, "full shield broken in one hit")
	assert_true(r.shield_broken, "shield_broken reported")
	assert_eq(s.health, 130.0, "health untouched by the break itself")


func test_back_hit_is_instant_kill() -> void:
	var s := HealthState.create(140.0, 130.0)
	var r := _hit(s, true, false)
	assert_true(r.killed and s.is_dead(), "killed")
	assert_eq(s.shield, 0.0, "shield zeroed")
	assert_eq(r.damage_dealt, 270.0, "damage reports shield + health")


func test_front_hit_with_no_shield_takes_70_percent_of_full_shield_from_health() -> void:
	# PLACEHOLDER rule (OQ-56): not a Shibi decision.
	var s := HealthState.create(100.0, 100.0)
	s.shield = 0.0
	var r := _hit(s, false, false)
	assert_eq(s.health, 30.0, "70 of the full shield value comes off health")
	assert_eq(r.health_damage, 70.0, "reported as health damage")
	var g := HealthState.create(60.0, 120.0)
	g.shield = 0.0
	_hit(g, false, true)
	assert_eq(g.health, 120.0 - 60.0, "Gladiator attacker: same placeholder path, no special case here")


func test_gladiator_front_hit_no_shield_takes_full_max_shield_from_health() -> void:
	# PLACEHOLDER rule (OQ-56 item 3): not a Shibi decision.
	assert_true("gladiator_front_hit_no_shield_rule" in _cfg().get("_placeholders", []), "marked placeholder")
	var s := HealthState.create(80.0, 90.0)
	s.shield = 0.0
	var r := _hit(s, false, true)
	assert_eq(s.health, 10.0, "full max_shield (80) comes off health, not 70%")
	assert_eq(r.health_damage, 80.0, "reported as health damage")
	var n := HealthState.create(80.0, 90.0)
	n.shield = 0.0
	_hit(n, false, false)
	assert_eq(n.health, 90.0 - 56.0, "non-Gladiator attacker keeps the 70% amount")


func test_missing_back_angle_is_an_error_and_hit_is_invalid() -> void:
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	var victim := Pawn.new()
	victim.setup("hastati", 1)
	root.add_child(attacker)
	root.add_child(victim)
	attacker.global_position = Vector3(0, 80, 0)
	victim.global_position = Vector3(0, 80, -1.0)
	var errors: Array[String] = []
	victim.melee_error_sink = func(msg: String) -> void: errors.append(msg)
	victim.melee_cfg_override = {"melee_front_shield_fraction": 0.7}
	var r := victim.receive_melee(attacker)
	assert_eq(r.blocked_reason, "invalid_melee_cfg", "hit reported invalid")
	assert_eq(r.damage_dealt, 0.0, "no damage reported")
	assert_eq(victim.bridge.state.shield, 100.0, "shield untouched")
	assert_eq(victim.bridge.state.health, 100.0, "health untouched")
	assert_eq(errors.size(), 1, "one clear error reported")
	assert_true(errors.size() == 1 and errors[0].contains("melee_back_angle_deg"), "error names the key")
	attacker.free()
	victim.free()


func test_validate_melee_reports_missing_keys() -> void:
	assert_eq(DataRegistry.validate_melee(_cfg()), PackedStringArray(), "real melee cfg is clean")
	var no_back := DataRegistry.validate_melee({"melee_front_shield_fraction": 0.7, "front_breaks_full_shield_classes": []})
	assert_eq(no_back, PackedStringArray(["melee.melee_back_angle_deg missing"]), "missing back angle reported")
	var no_frac := DataRegistry.validate_melee({"melee_back_angle_deg": 90, "front_breaks_full_shield_classes": []})
	assert_eq(no_frac, PackedStringArray(["melee.melee_front_shield_fraction missing"]), "missing fraction reported")
	var no_classes := DataRegistry.validate_melee({"melee_front_shield_fraction": 0.7, "melee_back_angle_deg": 90})
	assert_eq(no_classes, PackedStringArray(["melee.front_breaks_full_shield_classes missing"]), "missing classes reported")
	assert_true(DataRegistry.validate_melee({"melee_front_shield_fraction": 0.7, "melee_back_angle_deg": 200,
			"front_breaks_full_shield_classes": []}).size() == 1,
			"out-of-range angle still reported")


## A melee cfg override that lacks `missing_key` (all others present): the hit is invalid, one error names the key.
func _check_missing_melee_key(missing_key: String) -> void:
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	var victim := Pawn.new()
	victim.setup("hastati", 1)
	root.add_child(attacker)
	root.add_child(victim)
	attacker.global_position = Vector3(0, 80, 0)
	victim.global_position = Vector3(0, 80, -1.0)
	var errors: Array[String] = []
	victim.melee_error_sink = func(msg: String) -> void: errors.append(msg)
	var cfg := {"melee_back_angle_deg": 90.0, "melee_front_shield_fraction": 0.7,
			"front_breaks_full_shield_classes": ["gladiator"]}
	cfg.erase(missing_key)
	victim.melee_cfg_override = cfg
	var r := victim.receive_melee(attacker)
	assert_eq(r.blocked_reason, "invalid_melee_cfg", missing_key + ": hit reported invalid")
	assert_eq(r.damage_dealt, 0.0, missing_key + ": no damage reported")
	assert_eq(victim.bridge.state.shield, 100.0, missing_key + ": shield untouched")
	assert_eq(victim.bridge.state.health, 100.0, missing_key + ": health untouched")
	assert_eq(errors.size(), 1, missing_key + ": one clear error reported")
	assert_true(errors.size() == 1 and errors[0].contains(missing_key), missing_key + ": error names the key")
	attacker.free()
	victim.free()


func test_missing_front_fraction_is_an_error_and_hit_is_invalid() -> void:
	_check_missing_melee_key("melee_front_shield_fraction")


func test_missing_front_breaks_classes_is_an_error_and_hit_is_invalid() -> void:
	_check_missing_melee_key("front_breaks_full_shield_classes")


func test_guards_still_apply_to_melee() -> void:
	var s := HealthState.create(100.0, 100.0)
	assert_eq(DamageRules.apply_melee(s, 1, 1, false, true, false, _cfg()).blocked_reason, "friendly", "friendly")
	assert_eq(DamageRules.apply_melee(s, 0, 1, true, true, false, _cfg()).blocked_reason, "protected", "protected")
	assert_eq(s.health, 100.0, "no damage when blocked")


func test_angle_boundary_just_inside_and_outside_threshold() -> void:
	var threshold := float(_cfg()["melee_back_angle_deg"])
	var target := Vector3.ZERO
	var facing := Vector3(0, 0, -1)
	var eps := 0.5
	for side: float in [1.0, -1.0]:
		var inside: float = deg_to_rad(threshold - eps) * side
		var outside: float = deg_to_rad(threshold + eps) * side
		var a_in := Vector3(-sin(inside), 0, -cos(inside)) * 1.5
		var a_out := Vector3(-sin(outside), 0, -cos(outside)) * 1.5
		assert_true(not Melee.is_from_behind(target, facing, a_in, threshold), "just inside = front")
		assert_true(Melee.is_from_behind(target, facing, a_out, threshold), "just outside = from behind")
	assert_true(not Melee.is_from_behind(target, facing, Vector3(0, 0, -1.5), threshold), "dead ahead = front")
	assert_true(Melee.is_from_behind(target, facing, Vector3(0, 0, 1.5), threshold), "directly behind = back")
	assert_true(Melee.is_from_behind(target, facing, Vector3(0, 9, 1.5), threshold), "height is ignored")


func test_pawn_receive_melee_uses_target_facing() -> void:
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	var victim := Pawn.new()
	victim.setup("hastati", 1)
	root.add_child(attacker)
	root.add_child(victim)
	attacker.global_position = Vector3(0, 80, 0)
	victim.global_position = Vector3(0, 80, -1.0)
	# Victim faces -Z (away from the attacker at +Z): from behind -> instant kill.
	victim.receive_melee(attacker)
	assert_true(victim.bridge.state.is_dead(), "hit from behind kills")
	victim.respawn_at(Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 80, -1.0)))
	victim.receive_melee(attacker)
	assert_true(victim.is_alive(), "facing the attacker: survives")
	assert_eq(victim.bridge.state.shield, 30.0, "front hit: 70% of full 100 shield")
	# Gladiator attacker breaks a full shield from the front.
	var glad := Pawn.new()
	glad.setup("gladiator", 0)
	root.add_child(glad)
	glad.global_position = Vector3(0, 80, 0)
	victim.respawn_at(Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 80, -1.0)))
	victim.receive_melee(glad)
	assert_eq(victim.bridge.state.shield, 0.0, "Gladiator front hit breaks the full shield")
	assert_eq(victim.bridge.state.health, 100.0, "health intact")
	attacker.free()
	victim.free()
	glad.free()
