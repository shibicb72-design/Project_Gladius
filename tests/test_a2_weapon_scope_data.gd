extends "res://tests/test_case.gd"
## A2 T4: scopes belong to weapon data, including future class assignments.

func test_a2_weapon_scope_defaults_and_data_loadout_mapping() -> void:
	var registry := DataRegistry.new()
	var weapons: Dictionary = registry.load_file("res://data/stats.json")["weapons"]
	var rifle: Dictionary = weapons["sagittarii_rifle"]
	assert_eq(registry.get_weapon_def("sagittarii_rifle").scope, rifle["scope"], "approved rifle scope loaded")
	assert_true(str(rifle["scope"]) != "no_scope", "rifle has a scope")
	assert_true(rifle.has("_scope_note"), "approval and placeholder note present")
	var classes: Dictionary = registry.load_file("res://data/loadouts.json")["classes"]
	for class_id in classes:
		var slots := registry.get_loadout_ids(str(class_id))
		for slot in slots:
			var id := str(slots[slot])
			if id == "":
				continue
			assert_eq(registry.get_weapon_def(id).scope, str(weapons[id].get("scope", "no_scope")), "class slot reads its weapon field")
	var states: Dictionary = registry.load_file("res://data/input.json")["sensitivity_tables"]["states"]
	var settings := SensitivitySettings.new()
	for id in weapons:
		var scope := registry.get_weapon_def(str(id)).scope
		assert_true(not scope.begins_with("_") and states.has(scope), "shipped scope is a valid state")
		assert_true(settings.row_for_state(scope) != "", "shipped scope maps to a row")
	assert_eq(WeaponDef.from_dict("test", {}).scope, "no_scope", "absent field default")
	var without_scope := rifle.duplicate(true)
	without_scope.erase("scope")
	assert_eq(WeaponDef.from_dict("sagittarii_rifle", without_scope).scope, "no_scope", "id does not assign a scope")
	var with_scope: Dictionary = weapons["pilum_br"].duplicate(true)
	with_scope["scope"] = "4x"
	assert_eq(WeaponDef.from_dict("pilum_br", with_scope).scope, "4x", "field supplies scope for any weapon")
	assert_true(registry.validate().is_empty(), "data remains valid")
