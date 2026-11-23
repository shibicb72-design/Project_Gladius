extends "res://tests/test_case.gd"
## W1a: the look per renderer. Mobile must stay exactly the look before W1a (an exact property dump of the
## Environment, its sky, the sun and the world material against tests/fixtures/w1a_mobile_look_golden.json, recorded
## from base c9b385a before greybox_art.gd learned the "compatibility" block), and data/art_look.json "compatibility"
## is read only when the renderer is gl_compatibility (the web build).

const Dump := preload("res://tests/w1a_look_dump.gd")
const GOLDEN := "res://tests/fixtures/w1a_mobile_look_golden.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _with_renderer(method: String) -> Dictionary:
	GreyboxArt.renderer_override = method
	var out := Dump.dump_all(_tree())
	GreyboxArt.renderer_override = ""
	return out


## The world material's variation_* uniforms belong to WorldKit (set on the shared material when a map with the kit
## looks was built earlier in the same process), not to the look: left out so the test does not depend on test order.
static func _compared(part: String, key: String) -> bool:
	return not (part == "world_material" and key.contains("variation_"))


## Lists every key whose value differs (or is missing on one side), "<variant>/<object>/<key>: got | want".
func _diff(got: Dictionary, want: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for variant: String in want:
		for part: String in want[variant]:
			var w: Dictionary = want[variant][part]
			var g: Dictionary = (got.get(variant, {}) as Dictionary).get(part, {})
			for key: String in w:
				if not _compared(part, key):
					continue
				if not g.has(key) or String(g[key]) != String(w[key]):
					out.append("%s/%s/%s: %s | %s" % [variant, part, key, g.get(key, "<missing>"), w[key]])
			for key: String in g:
				if _compared(part, key) and not w.has(key):
					out.append("%s/%s/%s: %s | <not in golden>" % [variant, part, key, g[key]])
	return out


func test_mobile_look_is_byte_identical_to_the_golden() -> void:
	var want: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	assert_true(want is Dictionary and (want as Dictionary).size() == Dump.VARIANTS.size(), "golden has dusk, night, storm")
	var diffs := _diff(_with_renderer("mobile"), want)
	assert_true(diffs.is_empty(), "Mobile look unchanged (%d differences; first: %s)" % [diffs.size(), diffs.slice(0, 5)])


func test_forward_plus_reads_no_compatibility_values() -> void:
	# Forward+ builds the same Environment as Mobile here (the preset's fx_* switches decide its extras).
	var want: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var diffs := _diff(_with_renderer("forward_plus"), want)
	assert_true(diffs.is_empty(), "Forward+ look unchanged (%d differences; first: %s)" % [diffs.size(), diffs.slice(0, 5)])


func test_compatibility_block_only_for_gl_compatibility() -> void:
	var block: Dictionary = MatchLook.config().get("compatibility", {})
	assert_true(not block.is_empty(), "data/art_look.json has a compatibility block")
	assert_true(bool(block.get("_placeholder", false)), "the block is marked a placeholder")
	assert_true(String(block.get("_note", "")).contains("OQ-WEB-GFX-PARITY"), "the block names its open question")
	assert_eq(GreyboxArt.renderer_block("gl_compatibility"), block, "gl_compatibility reads the block")
	for method: String in ["mobile", "forward_plus", "dummy", ""]:
		assert_true(GreyboxArt.renderer_block(method).is_empty(), "%s reads no compatibility values" % method)
	GreyboxArt.renderer_override = "gl_compatibility"
	assert_eq(GreyboxArt.renderer(), "gl_compatibility", "the renderer can be injected")
	GreyboxArt.renderer_override = ""
	assert_eq(GreyboxArt.renderer(), RenderingServer.get_current_rendering_method(), "no injection = the running renderer")


func test_compatibility_block_values_reach_the_environment() -> void:
	# A made-up block (not the data's): the base values for every variant, then the variant's own on top.
	var block := {
		"_note": "test",
		"environment": {"fog_density": 0.25, "fog_light_color": [0.1, 0.2, 0.3, 1.0], "_skip": 9.0},
		"variants": {"night": {"environment": {"fog_density": 0.5}}},
	}
	var env := Environment.new()
	GreyboxArt._apply_renderer_block(env, block, "dusk")
	assert_true(is_equal_approx(env.fog_density, 0.25), "the base value applies")
	assert_eq(env.fog_light_color, Color(0.1, 0.2, 0.3, 1.0), "a 4-number array is a colour")
	env = Environment.new()
	GreyboxArt._apply_renderer_block(env, block, "night")
	assert_true(is_equal_approx(env.fog_density, 0.5), "the variant's value wins")
	env = Environment.new()
	var defaults := Environment.new()
	GreyboxArt._apply_renderer_block(env, {}, "night")
	assert_eq(env.fog_density, defaults.fog_density, "an empty block changes nothing")


func test_compatibility_build_applies_the_data_block() -> void:
	# With the injected Compatibility renderer the built Environment carries every value of the data block (today
	# none: the block is empty on purpose), and the rest stays the Mobile look.
	var block: Dictionary = MatchLook.config().get("compatibility", {})
	var want: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var got := _with_renderer("gl_compatibility")
	var touched := {}
	for key: String in (block.get("environment", {}) as Dictionary):
		touched[key] = true
	for id: String in (block.get("variants", {}) as Dictionary):
		for key: String in ((block["variants"][id] as Dictionary).get("environment", {}) as Dictionary):
			touched[key] = true
	var diffs := _diff(got, want).filter(func(d: String) -> bool:
		var parts := d.split("/")
		return not (parts[1] == "environment" and touched.has(parts[2].split(":")[0])))
	assert_true(diffs.is_empty(), "outside the block's keys Compatibility builds the Mobile look (%s)" % [diffs.slice(0, 5)])
