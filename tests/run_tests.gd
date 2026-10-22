extends SceneTree
## Headless runner: godot --headless --path . --script res://tests/run_tests.gd

func _initialize() -> void:
	var passed := 0
	var failed := 0
	var dir := DirAccess.open("res://tests")
	var files: Array[String] = []
	if dir != null:
		for f in dir.get_files():
			if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
				files.append(f)
	files.sort()
	# Optional: godot ... --script res://tests/run_tests.gd -- --only=<substring of file::test> --repeat=N
	var only := ""
	var repeat := 1
	var move_stick_arg := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
		elif a.begins_with("--repeat="):
			repeat = maxi(1, int(a.substr(9)))
		elif a.begins_with("--move-stick="):  # test-only: force the touch HUD move stick ("virtual" | "custom")
			move_stick_arg = a.substr(13)
			load("res://scripts/ui/touch_hud.gd").move_stick_override = move_stick_arg
	# The root is still being set up inside _initialize; let one frame pass so add_child works for the
	# very first test (matters when --only selects a single scene-using test).
	await process_frame
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		if script == null or not script.can_instantiate():
			failed += 1
			print("FAIL %s: script did not load" % f)
			continue
		for m in script.get_script_method_list():
			var mname: String = m["name"]
			if not mname.begins_with("test_"):
				continue
			if only != "" and not ("%s::%s" % [f, mname]).contains(only):
				continue
			for i in repeat:
				# Start every test outside the physics step: a test that ended on a physics_frame await
				# would otherwise hand the next one a tick already in progress (pawns would run early).
				await process_frame
				# A test that forced a move-stick mode must not leak it into later tests.
				load("res://scripts/ui/touch_hud.gd").move_stick_override = move_stick_arg
				var inst = script.new()
				await inst.call(mname)
				if inst.failures.is_empty():
					passed += 1
					print("PASS %s::%s" % [f, mname])
				else:
					failed += 1
					print("FAIL %s::%s: %s" % [f, mname, "; ".join(inst.failures)])
	print("TESTS: %d passed, %d failed" % [passed, failed])
	var code := 0
	if failed > 0 or passed == 0:
		code = 1
	quit(code)
