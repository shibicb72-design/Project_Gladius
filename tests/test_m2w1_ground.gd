extends "res://tests/test_case.gd"
## M2W1 item 4: the ground detail (scripts/visual/shaders/ground.gdshader detail branch, data/art_ground_detail.json,
## graphics preset art_ground_detail_enabled). The ground paint's inputs (art_materials.json "ground") stay as
## they were: footsteps and the baked paint read them.

const PAINT_HASH := "54179b8650e1112efec992a94aa2bce984d24edb918cec4b4c00d181f1415ee8"
const MAP := "res://data/maps/alesia_1km.json"
## art_materials.json "ground" keys at 1046309 (GroundPaint.inputs_hash reads every one of them).
const GROUND_KEYS := ["_note", "_paint_note", "paint_px_per_m", "paint_px_cap", "earth_color", "grass_color",
		"grass_dry_color", "paving_color", "earth_tile_m", "grass_tile_m", "paving_tile_m", "macro_tile_m", "macro_strength",
		"edge_noise", "puddle_level", "puddle_soft", "citadel_paving_m", "landmark_paving_m", "road_half_width_m",
		"ring_road_radius_m", "grass_from_m", "grass_full_m", "cover_trodden_m"]
## Fetch budget per ground pixel (the S2 path has six; M2W1 allows at most three more).
const S2_FETCHES := 6
const MAX_DETAIL_FETCHES := 9


func _code() -> String:
	return (load(WorldSurface.GROUND_SHADER_PATH) as Shader).code


## The fragment's two branches: [detail branch, S2 branch].
func _branches() -> Array:
	var code := _code()
	var frag := code.substr(code.find("void fragment()"))
	var on_at := frag.find("if (detail_enabled) {")
	var off_at := frag.find("} else {", on_at)
	return [frag.substr(on_at, off_at - on_at), frag.substr(off_at)]


func test_ground_paint_inputs_unchanged() -> void:
	var keys: Array = (WorldSurface.config()["ground"] as Dictionary).keys()
	keys.sort()
	var want: Array = GROUND_KEYS.duplicate()
	want.sort()
	assert_eq(keys, want, "art_materials.json ground keys are the recorded set")
	var settings := GroundPaint.settings_for(DataRegistry.parse_quiet(MAP))
	var baked := String(settings.get("baked", ""))
	var image := ResourceLoader.load(baked, "", ResourceLoader.CACHE_MODE_IGNORE) as Image if baked != "" else null
	assert_true(image != null and String(image.get_meta(&"inputs_sha256", "")) == PAINT_HASH, "alesia_1km's baked paint carries the pinned inputs hash")
	var snapshot: Dictionary = DataRegistry.parse_quiet("res://data/maps/snapshots/alesia_1km_colliders.json")
	assert_eq(String(snapshot.get("ground_paint_inputs_sha256", "")), PAINT_HASH, "the collider snapshot pins the same hash")
	for key: String in (WorldSurface.ground_detail_config()["uniforms"] as Dictionary):
		assert_true(not keys.has(key), "detail key %s is not an art_materials ground key" % key)


func test_toggle_off_is_the_s2_ground() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(WorldSurface.GROUND_SHADER_PATH)
	WorldSurface.apply_ground_detail(mat, false)
	assert_eq(mat.get_shader_parameter("detail_enabled"), false, "off: the detail branch is not taken")
	for key: String in (WorldSurface.ground_detail_config()["uniforms"] as Dictionary):
		assert_eq(mat.get_shader_parameter(key), null, "off: %s is not set" % key)
	assert_true(_code().contains("uniform bool detail_enabled = false;"), "the shader's default is the S2 path")
	# The S2 body is still the else branch, line for line (the lines that make its look).
	var s2: String = _branches()[1]
	for line: String in ["vec4 nz = texture(noise_pack, p * macro_per_m);",
			"vec4 wide = texture(noise_pack, p * macro_per_m * 0.27 + vec2(0.37, 0.11));",
			"vec3 earth = earth_color * (0.2 + 1.6 * te.r);",
			"albedo *= 1.0 + (wide.g * 0.6 + nz.g * 0.4 - 0.5) * 2.0 * macro_strength;",
			"ROUGHNESS = mix(mix(t.g, wet_roughness + 0.25, damp * 0.6), 0.04, puddle);"]:
		assert_true(s2.contains(line), "S2 branch keeps: " + line)
	assert_eq(s2.count("texture("), S2_FETCHES, "S2 branch: six fetches")


func test_detail_keys_reach_the_material_and_the_shader() -> void:
	assert_true(bool(GraphicsPresets.new().get_preset().get("art_ground_detail_enabled", false)), "default preset: detail on")
	var paint := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var mat := WorldSurface.ground_material(paint, 100.0, "m2w1_ground_test")
	assert_eq(mat.get_shader_parameter("detail_enabled"), true, "on: the detail branch")
	var detail := WorldSurface.ground_detail_config()
	var code := _code()
	for key: String in (detail["uniforms"] as Dictionary):
		var value: Variant = detail["uniforms"][key]
		var want: Variant = WorldSurface._color(value) if value is Array else float(value)
		assert_eq(mat.get_shader_parameter(key), want, "%s reaches the material" % key)
		var re := RegEx.create_from_string("uniform\\s+\\w+\\s+%s\\b" % key)
		assert_true(re.search(code) != null, "%s is a ground shader uniform" % key)
	assert_eq(mat.get_shader_parameter("rock_layer"), float((WorldSurface.config()["layers"] as Array).find("rock")), "rock layer from its name")
	assert_true(is_equal_approx(float(mat.get_shader_parameter("rock_tiles_per_m")), 1.0 / float(detail["rock_tile_m"])), "rock tile")
	# The wet look still reaches the ground (storm puddles).
	var before := WorldSurface.wet()
	WorldSurface.set_wet(0.8)
	assert_true(is_equal_approx(float(mat.get_shader_parameter("wet")), 0.8), "wet reaches the detailed ground")
	WorldSurface.set_wet(before)


func test_fetch_budget_and_one_branch() -> void:
	var on: String = _branches()[0]
	var fetches := on.count("texture(")
	assert_true(fetches <= MAX_DETAIL_FETCHES, "detail branch: %d fetches, at most %d" % [fetches, MAX_DETAIL_FETCHES])
	# M2W1 astraB: the 360 m noise fetch is gone (its value is the place map's A, baked at load); the place map
	# takes that fetch: still eight.
	assert_eq(fetches, 8, "detail branch: paint, place map, 2 noise, 4 surface tiles")
	assert_true(on.contains("texture(place_map,") and not on.contains("p / detail_large_m"), "the place map replaces the 360 m noise fetch")
	var frag := _code().substr(_code().find("void fragment()"))
	assert_eq(frag.count("if ("), 1, "one branch in the fragment (on the uniform detail_enabled)")
	assert_true(on.contains("puddle_d") and on.contains("wet"), "the detail branch keeps the wet and puddle terms")
