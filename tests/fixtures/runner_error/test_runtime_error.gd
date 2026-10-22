extends "res://tests/test_case.gd"
## Fixture for test_runner_safety.gd: parses cleanly, then hits a RUNTIME script error before the end of the
## test. It is only ever run via run_tests.gd --dir=res://tests/fixtures/runner_error (never by the normal scan).

func test_null_call_before_the_end() -> void:
	var holder: Object = null
	holder.call("not_a_method")  # runtime error: call on null (untyped call keeps the file parseable)
	assert_true(true, "unreachable")
