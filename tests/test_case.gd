extends RefCounted
## Base class for tests. Failures are recorded, never push_error'd.

var failures: Array[String] = []
## SECONDARY guard only. Set true when run_test() resumes after the body. In Godot 4.7.2 a runtime script error
## aborts just the called test body and the awaiting caller resumes, so this is still set true after such an
## error and CANNOT detect it. The real guard is the script-error logger (tests/script_error_logger.gd, checked
## in run_tests.gd). This flag only catches a body that never returns control normally.
var completed: bool = false


## Runner entry point: runs the named test, then sets `completed` (see above; not proof the body ran to its end).
func run_test(method: String) -> void:
	await call(method)
	completed = true


func assert_true(cond: bool, msg: String = "expected true") -> void:
	if not cond:
		failures.append(msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	if actual != expected:
		failures.append("%s (expected %s, got %s)" % [msg, str(expected), str(actual)])
