extends SceneTree
## Headless runner: godot --headless --path . --script res://tests/run_tests.gd

const _ErrorLogger := preload("res://tests/script_error_logger.gd")

func _initialize() -> void:
	var passed := 0
	var failed := 0
	# Optional: godot ... --script res://tests/run_tests.gd -- --only=<substring of file::test> --repeat=N --dir=<res path>
	var only := ""
	var repeat := 1
	var move_stick_arg := ""
	var test_dir := "res://tests"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
		elif a.begins_with("--repeat="):
			repeat = maxi(1, int(a.substr(9)))
		elif a.begins_with("--dir="):
			test_dir = a.substr(6).trim_suffix("/")
		elif a.begins_with("--move-stick="):  # test-only: force the touch HUD move stick ("virtual" | "custom")
			move_stick_arg = a.substr(13)
			load("res://scripts/ui/touch_hud.gd").move_stick_override = move_stick_arg
	var dir := DirAccess.open(test_dir)
	var files: Array[String] = []
	if dir != null:
		for f in dir.get_files():
			if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
				files.append(f)
	files.sort()
	# The script-error logger is the real guard against runtime script errors (see the check below);
	# test_case.gd's `completed` flag is only a secondary check.
	var err_logger = _ErrorLogger.new()
	OS.add_logger(err_logger)
	# The root is still being set up inside _initialize; let one frame pass so add_child works for the
	# very first test (matters when --only selects a single scene-using test).
	await process_frame
	for f in files:
		var script: GDScript = load(test_dir + "/" + f)
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
				err_logger.errors.clear()
				await inst.run_test(mname)
				# A runtime script error aborts only the test body and the await above resumes, so `completed` is still
				# true; the script-error logger (err_logger) is the real guard. `completed` is a SECONDARY check.
				if inst.completed and inst.failures.is_empty() and err_logger.errors.is_empty():
					passed += 1
					print("PASS %s::%s" % [f, mname])
				else:
					failed += 1
					var why: Array[String] = []
					why.append_array(inst.failures)
					if not err_logger.errors.is_empty() or not inst.completed:
						var reason := "did not complete (script error?)"
						if not err_logger.errors.is_empty():
							reason += "; script error logged: %s" % err_logger.errors[0]
							if err_logger.errors.size() > 1:
								reason += " (+%d more)" % (err_logger.errors.size() - 1)
						why.append(reason)
					print("FAIL %s::%s: %s" % [f, mname, "; ".join(why)])
	OS.remove_logger(err_logger)
	print("TESTS: %d passed, %d failed" % [passed, failed])
	var code := 0
	if failed > 0 or passed == 0:
		code = 1
	quit(code)
