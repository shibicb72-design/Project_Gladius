extends "res://tests/test_case.gd"
## M2W1 item 3: the look variants (data/art_look.json) after the golden-hour dusk, the dusk_deep comparison
## variant, the optional look keys (absent = the engine default, the look before M2W1), and the ambient decor and
## sun shafts per map (data/art_world_maps.json).

## Light3D nodes in a built match stage at 1046309 (before M2W1 item 3), alesia_1km and alesia_section alike:
## 1 sun + 8 brazier OmniLight3D + 1 SpotLight3D beacon. No look or map may raise it.
const LIGHTS_BEFORE := 10
const REQUIRED := {
	"light": ["ambient_color", "ambient_energy", "tonemap_exposure", "sun_color", "sun_energy", "sun_rotation_degrees"],
	"fog": ["tonemap", "fog_mode", "fog_color", "fog_density", "fog_sky_affect", "fog_depth_begin_m", "fog_depth_end_m",
			"fog_depth_curve", "shadow_mode", "shadow_max_distance_m", "light_angular_distance"],
	"sky": ["radiance_size"],
	"post": ["glow_intensity", "glow_strength", "glow_bloom", "glow_hdr_threshold", "glow_blend", "fog_sun_scatter",
			"fog_aerial_perspective", "adjust_brightness", "adjust_contrast", "adjust_saturation", "vignette", "vignette_color"],
}


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _variants() -> Array:
	return (MatchLook.config()["variants"] as Dictionary).keys()


## A stage like the match's (Light, WorldEnvironment with GreyboxArt) and, when map_path is set, the map.
func _stage(map_path: String = "") -> Node3D:
	var stage := Node3D.new()
	var light := DirectionalLight3D.new()
	light.name = "Light"
	stage.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))
	stage.add_child(world)
	if map_path != "":
		var def: Dictionary = DataRegistry.new().load_file(map_path)
		var map: Node3D = load(String(def["scene"])).instantiate()
		map.get_node("ArtBuilder").set("map_json", map_path)
		stage.add_child(map)
	_tree().root.add_child(stage)
	return stage


func _lights(node: Node, out: Array) -> Array:
	if node is Light3D:
		out.append(node)
	for child in node.get_children():
		_lights(child, out)
	return out


func test_every_variant_resolves_with_the_keys_the_builder_reads() -> void:
	var ids := _variants()
	for want: String in ["dusk", "night", "storm", "dusk_deep"]:
		assert_true(ids.has(want), "variant %s exists" % want)
	for id: String in ids:
		var look := MatchLook.resolved(id)
		assert_eq(String(look["id"]), id, "%s resolves" % id)
		for block: String in REQUIRED:
			for key: String in REQUIRED[block]:
				assert_true((look[block] as Dictionary).has(key), "%s: %s.%s" % [id, block, key])
		assert_true((MatchLook.config()["weather_kinds"] as Dictionary).has(String(look["weather"])), "%s: weather kind exists" % id)
		assert_true(GreyboxArt.TONEMAPPERS.has(String(look["fog"]["tonemap"])), "%s: a known tonemapper" % id)


func test_rotation_ids_exist_and_dusk_deep_is_only_for_comparison() -> void:
	var cfg := MatchLook.config()
	var ids := _variants()
	assert_true(ids.has(String(cfg["variant"])), "the base variant exists")
	for id: Variant in cfg["rotation"]["by_seed"]:
		assert_true(ids.has(String(id)), "rotation id %s exists" % id)
	assert_true(not (cfg["rotation"]["by_seed"] as Array).has("dusk_deep"), "dusk_deep is not rotated in")
	for seed_value in 64:
		assert_true(ids.has(MatchLook.variant_for_seed(seed_value)), "seed %d picks a variant" % seed_value)
	# dusk_deep is the pre-M2W1 dusk: no override at all.
	assert_true((cfg["variants"]["dusk_deep"] as Dictionary).is_empty(), "dusk_deep overrides nothing")
	assert_eq(MatchLook.resolved("dusk_deep")["light"], GreyboxArt.config()["environment"], "dusk_deep light = the base light")
	assert_eq(MatchLook.resolved("dusk_deep")["fog"], LowpolyKit.config()["environment"], "dusk_deep fog = the base fog")


func test_forbidden_effects_stay_off_and_one_shadow_sun_for_every_variant() -> void:
	var stage := _stage()
	var world := stage.get_node("WorldEnvironment") as WorldEnvironment
	var preset := GraphicsPresets.new().get_preset()
	for id: String in _variants():
		world.call("_apply_environment", world, id)
		var env := world.environment
		assert_true(not env.ssao_enabled and not env.ssil_enabled and not env.ssr_enabled and not env.sdfgi_enabled
				and not env.volumetric_fog_enabled, "%s: SSAO, SSIL, SSR, SDFGI and volumetric fog off" % id)
		assert_eq(env.fog_mode, Environment.FOG_MODE_DEPTH, "%s: depth fog" % id)
		assert_eq(env.fog_enabled, bool(preset["art_fog_enabled"]), "%s: fog follows the preset" % id)
		var shadowed := _lights(stage, []).filter(func(l: Light3D) -> bool: return l.shadow_enabled)
		assert_eq(shadowed.size(), 1 if bool(preset["art_shadows_enabled"]) else 0, "%s: one shadow-casting sun" % id)
		var look := MatchLook.resolved(id)
		assert_true(is_equal_approx(env.fog_density, float(look["fog"]["fog_density"])), "%s: fog density from the look" % id)
		assert_eq(env.fog_light_color, GreyboxArt.color_value(look["fog"]["fog_color"]), "%s: fog colour from the look" % id)
	stage.free()


func test_optional_keys_default_to_the_look_before_m2w1() -> void:
	var defaults := Environment.new()
	var fresh := DirectionalLight3D.new()
	var stage := _stage()
	var world := stage.get_node("WorldEnvironment") as WorldEnvironment
	var sun := stage.get_node("Light") as DirectionalLight3D
	# dusk first (it sets optional keys), then dusk_deep on the same sun: every optional value is back to default.
	world.call("_apply_environment", world, "dusk")
	assert_true(not is_equal_approx(sun.shadow_blur, fresh.shadow_blur), "dusk sets a shadow blur (the check below means something)")
	world.call("_apply_environment", world, "dusk_deep")
	var env := world.environment
	assert_eq(env.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR, "ambient from the colour")
	assert_eq(env.ambient_light_sky_contribution, defaults.ambient_light_sky_contribution, "sky contribution default")
	assert_eq(env.reflected_light_source, defaults.reflected_light_source, "reflection source default")
	assert_eq(env.tonemap_mode, Environment.TONE_MAPPER_ACES, "ACES")
	assert_eq(env.tonemap_white, defaults.tonemap_white, "tonemap white default")
	assert_eq(env.fog_height, defaults.fog_height, "fog height default")
	assert_eq(env.fog_height_density, defaults.fog_height_density, "fog height density default")
	assert_eq(env.glow_hdr_scale, defaults.glow_hdr_scale, "glow hdr scale default")
	for i in 7:
		assert_eq(env.get_glow_level(i), defaults.get_glow_level(i), "glow level %d default" % i)
	for prop: String in ["shadow_blur", "shadow_bias", "shadow_normal_bias", "shadow_opacity", "directional_shadow_fade_start",
			"directional_shadow_blend_splits"]:
		assert_eq(sun.get(prop), fresh.get(prop), "sun %s back to default" % prop)
	var sky_mat := env.sky.sky_material as ShaderMaterial
	for key: String in ["cloud_light_mix", "cloud_base", "cloud2_cover", "horizon_haze"]:
		assert_eq(sky_mat.get_shader_parameter(key), null, "dusk_deep leaves the sky uniform %s at its shader default (0)" % key)
	# The shader's own defaults draw nothing new.
	var code := (load("res://scripts/visual/shaders/sky_astra.gdshader") as Shader).code
	for decl: String in ["uniform float cloud_light_mix = 0.0;", "uniform float cloud_base = 0.0;", "uniform float cloud2_cover = 0.0;",
			"uniform float horizon_haze = 0.0;"]:
		assert_true(code.contains(decl), "sky default: " + decl)
	stage.free()
	fresh.free()


func test_no_light_increase_and_decor_out_of_the_hill() -> void:
	for path: String in ["res://data/maps/alesia_1km.json", "res://data/maps/alesia_section.json"]:
		var stage := _stage(path)
		await _tree().process_frame
		await _tree().process_frame
		var lights := _lights(stage, [])
		assert_true(lights.size() <= LIGHTS_BEFORE, "%s: %d lights, at most %d" % [path, lights.size(), LIGHTS_BEFORE])
		var builder := stage.find_child("ArtBuilder", true, false)
		var terrain := WorldAmbient.terrain_of(builder)
		var ambient := builder.get_node("Ambient") as WorldAmbient
		if terrain != null:
			# Every decor root stands on the terrain (not inside the citadel hill, as the 160 m map's points did).
			for node: Node3D in ambient.get_children():
				if node is MultiMeshInstance3D:
					continue
				var p := node.global_position
				assert_true(p.y >= terrain.height_at(p.x, p.z) - 0.01, "%s: %s at or above the ground" % [path, node.name])
			var batch := ambient.get_node_or_null("Foliage") as MultiMeshInstance3D
			# The headless (dummy) renderer reads every MultiMesh transform back as identity: check tufts only when readable.
			if batch != null and batch.multimesh.instance_count > 0 and batch.multimesh.get_instance_transform(0) != Transform3D():
				for i in batch.multimesh.instance_count:
					var at := batch.multimesh.get_instance_transform(i).origin
					assert_true(absf(at.y - terrain.height_at(at.x, at.z)) < 0.01, "%s: tuft %d on the ground (%s, ground %.3f)" % [path, i, at, terrain.height_at(at.x, at.z)])
					if absf(at.y - terrain.height_at(at.x, at.z)) >= 0.01:
						break
			for p: Array in MatchLook.shaft_places(builder):
				assert_true(float(p[1]) > terrain.height_at(p[0], p[2]), "%s: shaft above the ground" % path)
		else:
			assert_eq(MatchLook.shaft_places(builder), MatchLook.config()["shafts"]["at"], "%s: flat map keeps shafts.at" % path)
			var cfg: Dictionary = DataRegistry.new().load_file("res://data/art_world.json")
			assert_eq(WorldAmbient.config_for(cfg, builder), cfg, "%s: flat map keeps art_world.json" % path)
		stage.free()


func test_map_blocks_never_add_lights() -> void:
	var world: Dictionary = DataRegistry.new().load_file("res://data/art_world.json")
	var maps: Dictionary = DataRegistry.new().load_file(WorldAmbient.MAPS_PATH)
	var blocks: Array = [maps["terrain_default"]]
	blocks.append_array((maps["maps"] as Dictionary).values())
	for block: Dictionary in blocks:
		for group: String in ["braziers", "beacons"]:
			var n := (block[group]["positions"] as Array).size() if block.has(group) else (world[group]["positions"] as Array).size()
			assert_true(n <= (world[group]["positions"] as Array).size(), "%s: no more than art_world.json's" % group)
