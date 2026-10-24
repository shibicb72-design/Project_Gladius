extends "res://tests/test_case.gd"
## The runner's FAIL line must name the logged script error. Same subprocess as test_runner_safety.gd.

const FIXTURE_DIR := "res://tests/fixtures/runner_error"


func test_fail_reason_names_the_logged_script_error() -> void:
	var output: Array = []
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/run_tests.gd", "--", "--dir=" + FIXTURE_DIR,
	])
	OS.execute(OS.get_executable_path(), args, output, true)
	var text := "\n".join(PackedStringArray(output))
	assert_true(text.contains("did not complete (script error?); script error logged:"), "reason names the logged error, output: %s" % text)
	assert_true(text.contains("script error logged: Cannot call method 'call' on a null value."),"reason carries the fixture's null-call error text, output: %s" % text)
