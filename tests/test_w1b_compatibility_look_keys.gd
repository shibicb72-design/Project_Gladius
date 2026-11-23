extends "res://tests/test_case.gd"

const Dump := preload("res://tests/w1a_look_dump.gd")


func test_environment_overrides_name_real_properties_and_reach_the_match() -> void:
	var block := GreyboxArt.renderer_block(GreyboxArt.COMPATIBILITY_RENDERER)
	var properties := {}
	for property: Dictionary in Environment.new().get_property_list():
		properties[String(property["name"])] = true
	var configs: Dictionary = { "global": block.get("environment", {}) }
	for id: String in (block.get("variants", {}) as Dictionary):
		configs[id] = block["variants"][id].get("environment", {})
	for id: String in configs:
		for key: String in configs[id]:
			if not key.begins_with("_"):
				assert_true(properties.has(key), "%s Environment property exists: %s" % [id, key])

	GreyboxArt.renderer_override = GreyboxArt.COMPATIBILITY_RENDERER
	var stage := Dump.stage(Engine.get_main_loop())
	var world := stage.get_node("WorldEnvironment") as WorldEnvironment
	for id: String in Dump.VARIANTS:
		world.call("_apply_environment", world, id)
		var values: Dictionary = configs["global"].merged(configs.get(id, {}), true)
		for key: String in values:
			if key.begins_with("_") or not properties.has(key):
				continue
			var expected: Variant = values[key]
			var actual: Variant = world.environment.get(key)
			if expected is Array and expected.size() == 4:
				assert_eq(actual, GreyboxArt.color_value(expected), "%s applies %s" % [id, key])
			elif actual is float and expected is float:
				assert_true(is_equal_approx(actual, expected), "%s applies %s" % [id, key])
			else:
				assert_eq(actual, expected, "%s applies %s" % [id, key])
	stage.free()
	GreyboxArt.renderer_override = ""
