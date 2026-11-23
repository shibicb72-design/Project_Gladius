extends SceneTree
## W1a: records the Mobile look golden (tests/fixtures/w1a_mobile_look_golden.json) with tests/w1a_look_dump.gd.
## Run once on the code BEFORE a renderer-specific look change (W1a recorded it at base c9b385a, before
## greybox_art.gd learned the "compatibility" block):
##   godot.cmd --headless --path . --script res://tools/w1a_record_golden.gd -- --out=<absolute json path>
## With W1a's greybox_art.gd it injects the renderer "mobile" first (GreyboxArt.renderer_override).

const Dump := preload("res://tests/w1a_look_dump.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	if out == "":
		printerr("w1a_record_golden: give --out=<absolute json path>")
		quit(1)
		return
	# A no-op on the base code (no such static var there).
	(load("res://scripts/visual/greybox_art.gd") as GDScript).set("renderer_override", "mobile")
	await process_frame
	var dump := Dump.dump_all(self)
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(dump, "\t", true))
	f.close()
	print("W1A_GOLDEN written %s (%d variants)" % [out, dump.size()])
	quit(0)
