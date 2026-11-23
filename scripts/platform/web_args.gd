class_name WebArgs
extends RefCounted
## W0 (binding fixes 9, 12): debug-only URL arguments for browser automation (tools/web/smoke.mjs, docs/WEB.md).
## Godot buttons are canvas pixels, so the smoke test cannot click Play solo; instead the page URL carries
##   ?autosolo=1[&length=<br.json match_length id>][&wait=<seconds in the lobby before Start>]
## which opens the Play solo lobby, applies the length (an unknown or missing id means the data default) and the
## data's solo team mode, and presses Start after `wait` seconds (0 = at once; clamped to 0..MAX_WAIT_S).
## Read ONLY in a debug build running in the browser (OS.is_debug_build() and the "web" feature tag): release builds
## and every other platform ignore the URL. The query string comes through JavaScriptBridge, which is a safe no-op
## off the web. Parsing is a pure function (parse) so tests run it headless with the debug / web flags as arguments.

## Upper bound for the lobby wait, so a typo cannot park the lobby for minutes. Automation-only, not a game tunable.
const MAX_WAIT_S := 30.0

## Tool/test hooks: when non-null they replace the real query string / debug flag / web flag. Never set in shipping code.
static var simulate_query: Variant = null
static var simulate_debug: Variant = null
static var simulate_web: Variant = null
## take_autosolo() hands the request out once per run (the menu is re-entered after every match).
static var _taken: bool = false
## The request between the main menu (MainMenu.apply_autosolo sets it with Play solo) and the solo lobby (which takes
## it, applies the length and presses Start). {} = none.
static var pending: Dictionary = {}


static func is_debug() -> bool:
	return bool(simulate_debug) if simulate_debug != null else OS.is_debug_build()


static func is_web() -> bool:
	return bool(simulate_web) if simulate_web != null else OS.has_feature("web")


## The page's query string ("?a=1&b=2", or "") in the browser; "" everywhere else.
static func read_query() -> String:
	if simulate_query != null:
		return str(simulate_query)
	if not OS.has_feature("web"):
		return ""
	var v: Variant = JavaScriptBridge.eval("window.location.search", true)
	return v if v is String else ""


## Pure: the query's key/value pairs (keys lower-case, values URI-decoded; a bare key maps to "").
static func query_pairs(query: String) -> Dictionary:
	var out := {}
	var q := query.strip_edges()
	if q.begins_with("?"):
		q = q.substr(1)
	for part in q.split("&", false):
		var kv := part.split("=", true, 1)
		var key := kv[0].uri_decode().strip_edges().to_lower()
		if key == "":
			continue
		out[key] = kv[1].uri_decode().strip_edges() if kv.size() > 1 else ""
	return out


## Pure: the autosolo request in `query`, or {} when there is none or it must be ignored (not a debug build, not the
## browser). A request is {"length": <valid match length id>, "wait_s": float}.
static func parse(query: String, debug_build: bool, web: bool) -> Dictionary:
	if not debug_build or not web:
		return {}
	var pairs := query_pairs(query)
	if str(pairs.get("autosolo", "")) != "1":
		return {}
	var wait_raw := str(pairs.get("wait", "0"))
	var wait_s := clampf(wait_raw.to_float(), 0.0, MAX_WAIT_S) if wait_raw.is_valid_float() else 0.0
	return {"length": SaveService.match_length(str(pairs.get("length", ""))), "wait_s": wait_s}


## The autosolo request for this run, handed out once (the first main menu takes it); {} afterwards or when none.
static func take_autosolo() -> Dictionary:
	if _taken:
		return {}
	_taken = true
	return parse(read_query(), is_debug(), is_web())


## Test hook: forget that the request was taken and clear the simulated flags.
static func reset_for_tests() -> void:
	_taken = false
	pending = {}
	simulate_query = null
	simulate_debug = null
	simulate_web = null


## Prints a marker line for the browser smoke test (GLADIUS_PAUSE_OPENED / _CLOSED), only in a debug web build, so
## desktop, Android and the headless suite stay quiet.
static func debug_marker(line: String) -> void:
	if is_debug() and is_web():
		print(line)
