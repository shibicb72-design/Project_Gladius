extends "res://tests/test_case.gd"
## The runner must not count a test that died on a runtime script error as PASS. Runs run_tests.gd in a
## subprocess on a fixture dir whose one test calls a method on null before its end.

const FIXTURE_DIR := "res://tests/fixtures/runner_error"


func test_runtime_script_error_is_reported_as_fail_with_nonzero_exit() -> void:
	var output: Array = []
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/run_tests.gd", "--", "--dir=" + FIXTURE_DIR,
	])
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	var text := "\n".join(PackedStringArray(output))
	assert_true(text.contains("FAIL test_runtime_error.gd::test_null_call_before_the_end"), "fixture test reported as FAIL, output: %s" % text)
	assert_true(text.contains("did not complete"), "reason says the test did not complete, output: %s" % text)
	assert_true(not text.contains("PASS test_runtime_error.gd"), "fixture test must not PASS")
	assert_true(code != 0, "runner exit code is non-zero, got %d" % code)


func test_fixture_dir_is_not_in_the_default_scan() -> void:
	var names := DirAccess.get_files_at("res://tests")
	assert_true(not names.has("test_runtime_error.gd"), "fixture file lives under tests/fixtures only")
	assert_true(FileAccess.file_exists(FIXTURE_DIR + "/test_runtime_error.gd"), "fixture exists")
