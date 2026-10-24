extends "res://tests/test_case.gd"
## Runs the whole tests/test_touch_controls.gd file again with the move stick forced to "custom"
## (test-only static override on touch_hud.gd, never by editing data/input.json). The plain run of
## that file covers whatever input.json says; this one guarantees the custom stick stays covered.

const _TouchHud := preload("res://scripts/ui/touch_hud.gd")


func test_whole_touch_controls_file_passes_with_custom_move_stick() -> void:
	var script: GDScript = load("res://tests/test_touch_controls.gd")
	var prev: String = _TouchHud.move_stick_override
	_TouchHud.move_stick_override = "custom"
	var ran := 0
	for m in script.get_script_method_list():
		var mname: String = m["name"]
		if not mname.begins_with("test_"):
			continue
		var inst = script.new()
		await inst.call(mname)
		ran += 1
		for f in inst.failures:
			failures.append("[custom] %s: %s" % [mname, f])
	_TouchHud.move_stick_override = prev
	assert_true(ran > 20, "ran the whole touch controls file, ran %d" % ran)
