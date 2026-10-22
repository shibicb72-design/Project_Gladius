extends "res://tests/test_case.gd"

const RegistryS := preload("res://scripts/systems/data_registry.gd")


func test_registry_class_def_matches_json() -> void:
	var reg := RegistryS.new()
	var raw: Dictionary = reg.load_file("res://data/stats.json")
	var c := reg.get_class_def("sagittarii")
	assert_true(c != null, "sagittarii exists")
	if c == null:
		return
	var d: Dictionary = raw["classes"]["sagittarii"]
	assert_eq(c.shield, float(d["shield"]), "shield")
	assert_eq(c.health, float(d["health"]), "health")
	assert_eq(c.speed_pct, float(d["speed_pct"]), "speed_pct")
	assert_eq(c.enabled, true, "enabled")
	var w := reg.get_weapon_def("pilum_br")
	assert_true(w != null and w.damage == float(raw["weapons"]["pilum_br"]["damage"]), "weapon damage matches")
	assert_true(w != null and w.is_placeholder, "weapon flagged placeholder")
	assert_true(reg.get_class_def("nope") == null, "unknown class is null")
	assert_true(reg.load_file("res://data/missing.json").is_empty(), "missing file is empty")


func test_registry_validate_clean() -> void:
	var reg := RegistryS.new()
	var problems := reg.validate()
	assert_eq(problems.size(), 0, "validate problems: " + ", ".join(problems))
