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
