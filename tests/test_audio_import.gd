extends "res://tests/test_case.gd"
## The audio import tool's recipe rule for positional one-shots (tools/import_audio.gd one_shot_cap_problem):
## a mono output without a loop may not be cut longer than defaults.one_shot_max_s; stereo one-shots are not capped.
## Also holds the shipped recipe to it. The tool itself needs ffmpeg and the staging folder, so only the rule runs here.

const TOOL := "res://tools/import_audio.gd"
const RECIPE := "res://tools/audio_import.json"


func test_a_positional_one_shot_over_the_cap_is_rejected() -> void:
	var tool: GDScript = load(TOOL)
	var defaults := {"one_shot_max_s": 1.6}
	var long: String = tool.one_shot_cap_problem({"id": "long_take", "channels": "mono", "max_s": 1.7}, defaults)
	assert_true(long.contains("long_take") and long.contains("cap"), "a mono one-shot of 1.7 s is rejected: \"%s\"" % long)
	assert_eq(tool.one_shot_cap_problem({"id": "edge", "channels": "mono", "max_s": 1.6}, defaults), "", "a mono one-shot at the cap passes")
	assert_eq(tool.one_shot_cap_problem({"id": "plain", "channels": "mono"}, defaults), "", "no own max_s: the default cut, which is the cap")
	assert_eq(tool.one_shot_cap_problem({"id": "thunder", "channels": "stereo", "max_s": 6.5}, defaults), "", "a stereo one-shot is not positional and not capped")
	assert_eq(tool.one_shot_cap_problem({"id": "bed", "channels": "mono", "max_s": 9.0, "loop": {"length_s": 20.0}}, defaults), "", "a loop has no one-shot cut")
	# Without defaults.one_shot_max_s the tool's own fallback is the cap.
	assert_true(not String(tool.one_shot_cap_problem({"id": "x", "channels": "mono", "max_s": 1.65}, {})).is_empty(), "the fallback cap rejects 1.65 s")
	assert_eq(tool.one_shot_cap_problem({"id": "x", "channels": "mono", "max_s": 1.6}, {}), "", "the fallback cap is 1.6 s")


func test_the_shipped_recipe_keeps_every_positional_one_shot_under_the_cap() -> void:
	var tool: GDScript = load(TOOL)
	var recipe: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECIPE))
	assert_true(recipe is Dictionary, "the recipe parses")
	if not recipe is Dictionary:
		return
	var defaults: Dictionary = recipe.get("defaults", {})
	assert_eq(float(defaults.get("one_shot_max_s", 0.0)), float(tool.ONE_SHOT_MAX_S), "the recipe's cap is the tool's fallback (1.6 s)")
	var positional := 0
	for out: Dictionary in recipe.get("outputs", []):
		assert_eq(tool.one_shot_cap_problem(out, defaults), "", "%s passes the one-shot cap" % out.get("id", ""))
		if not out.has("loop"):
			# Every one-shot sets its own cut, so a change of the default never re-cuts a shipped take.
			assert_true(out.has("max_s"), "%s sets its own max_s" % out.get("id", ""))
			positional += 1 if out.get("channels") == "mono" else 0
	assert_true(positional > 0, "the recipe has positional one-shots (%d)" % positional)
