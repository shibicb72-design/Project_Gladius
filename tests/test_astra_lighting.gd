extends "res://tests/test_case.gd"

func _shadow_lights(node: Node) -> Array[Light3D]:
	var lights: Array[Light3D] = []
	if node is Light3D and node.shadow_enabled:
		lights.append(node)
	for child in node.get_children():
		lights.append_array(_shadow_lights(child))
	return lights

func test_mobile_lighting_depth_fog_and_one_hard_sun() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	tree.root.add_child(match_scene)
	var env: Environment = match_scene.get_node("WorldEnvironment").environment
	var cfg: Dictionary = LowpolyKit.config()["environment"]
	var preset := GraphicsPresets.new().get_preset()
	assert_eq(env.fog_enabled, bool(preset["art_fog_enabled"]), "fog preset")
	assert_eq(env.glow_enabled, bool(preset["art_glow_enabled"]), "glow preset")
	assert_eq(env.fog_mode, Environment.FOG_MODE_DEPTH, "explicit nonvolumetric depth fog")
	assert_eq(env.fog_light_color, GreyboxArt.color_value(cfg["fog_color"]), "fog color from data")
	assert_true(is_equal_approx(env.fog_density, float(cfg["fog_density"])), "fog density from data")
	assert_eq(env.tonemap_mode, Environment.TONE_MAPPER_ACES, "ACES placeholder")
	assert_true(not env.ssao_enabled and not env.ssil_enabled and not env.ssr_enabled and not env.sdfgi_enabled and not env.volumetric_fog_enabled, "advanced effects disabled")
	var lights := _shadow_lights(match_scene)
	assert_eq(lights.size(), 1, "one shadow light")
	if lights.size() == 1:
		assert_true(lights[0] is DirectionalLight3D, "directional sun only")
		var sun := lights[0] as DirectionalLight3D
		assert_eq(sun.directional_shadow_mode, DirectionalLight3D.SHADOW_ORTHOGONAL, "single shadow split")
		assert_true(sun.directional_shadow_max_distance <= 60 and sun.light_angular_distance == 0, "bounded hard shadows")
		assert_eq(sun.directional_shadow_max_distance, float(cfg["shadow_max_distance_m"]), "shadow distance from data")
	assert_eq(ProjectSettings.get_setting("rendering/renderer/rendering_method"), "mobile", "Mobile stays")
	match_scene.free()
