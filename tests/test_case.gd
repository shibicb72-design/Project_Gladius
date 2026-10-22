extends RefCounted
## Base class for tests. Failures are recorded, never push_error'd.

var failures: Array[String] = []
## Set by the runner (run_tests.gd) once the test body has returned.
var completed: bool = false


## Runner entry point: runs the named test and marks it completed when the body returns.
func run_test(method: String) -> void:
	await call(method)
	completed = true


func assert_true(cond: bool, msg: String = "expected true") -> void:
	if not cond:
		failures.append(msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	if actual != expected:
		failures.append("%s (expected %s, got %s)" % [msg, str(expected), str(actual)])
