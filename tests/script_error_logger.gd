extends Logger
## Records runtime script errors (null calls, bad indexes ...) while a test runs. A test that hits one aborts
## its own body silently, so the runner uses this to turn that into a FAIL instead of a PASS.

var errors: Array[String] = []


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_SCRIPT:
		errors.append("%s (%s:%d in %s)" % [rationale if rationale != "" else code, file, line, function])
