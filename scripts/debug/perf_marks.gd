extends RefCounted
## W1c step 1 (measurement only), DEBUG WEB BUILDS WITH ?perf=1 ONLY: phase timestamps for the browser stall analysis
## (tools/web/perf.mjs, tools/web/perf_stalls.mjs; docs/WEB.md "Stall timing (W1c)"). Same gate as the PerfRoute node
## (WebArgs.perf_request(): debug build + web + perf=1): release builds, desktop, Android and the headless suite never
## print anything, and every call is then one cached bool test. A timing call changes no game state, no output and no
## RNG use; it only reads the clocks, prints one console line and (in the browser) adds one performance.measure / mark
## so the phase shows under blink.user_timing in a Chrome trace.
##
## Console line (one per call, grep-able by the prefix):
##   GLADIUS_T <label> <msec since engine start> <duration ms | -> page=<page epoch ms> [<key>=<value> ...]
## <duration> is the span for done() (the line is printed at the END of the span) and "-" for mark(); page= is
## performance.timeOrigin + performance.now() at that moment (-1 off the web), so the harness can place the span on
## its own requestAnimationFrame clock without the console's delivery delay. In a trace the span is the user-timing
## measure "GT:<label>" (ending at page=), a mark is the user-timing mark "GT:<label>".
##
## Usage (the only pattern; no other side effects):
##   var t := _PerfMarks.start()
##   <the work>
##   _PerfMarks.done("map.terrain", t)

const _WebArgs := preload("res://scripts/platform/web_args.gd")
const PREFIX := "GLADIUS_T"

## -1 not decided yet, 0 off, 1 on. Decided once per run from the real flags; never cached while a test simulates them.
static var _state: int = -1


## True only in a debug web build whose URL has perf=1 (the PerfRoute gate).
static func enabled() -> bool:
	if _state >= 0:
		return _state == 1
	var simulated := _WebArgs.simulate_query != null or _WebArgs.simulate_debug != null or _WebArgs.simulate_web != null
	var on := _WebArgs.is_debug() and _WebArgs.is_web() and OS.has_feature("web") and not _WebArgs.perf_request().is_empty()
	if not simulated:
		_state = 1 if on else 0
	return on


## Start of a span: the engine clock in microseconds, or -1 when timing is off (done() then does nothing).
static func start() -> int:
	return Time.get_ticks_usec() if enabled() else -1


## End of a span begun with start(): prints the line with its duration. `extra` is appended as is ("k=v k2=v2").
static func done(label: String, started_usec: int, extra: String = "") -> void:
	if started_usec < 0:
		return
	emit(label, (Time.get_ticks_usec() - started_usec) / 1000.0, extra)


## A point in time (no duration).
static func mark(label: String, extra: String = "") -> void:
	if not enabled():
		return
	emit(label, -1.0, extra)


## Prints one line; dur_ms < 0 means a mark. Does nothing unless enabled() (callers that build `extra` in a loop
## still check enabled() first, so the string is not built for nothing).
static func emit(label: String, dur_ms: float, extra: String = "") -> void:
	if not enabled():
		return
	var page := _page_stamp(label, dur_ms)
	var dur := "-" if dur_ms < 0.0 else "%.1f" % dur_ms
	print("%s %s %d %s page=%.1f%s" % [PREFIX, label, Time.get_ticks_msec(), dur, page, (" " + extra) if extra != "" else ""])


## In the browser: adds the user-timing measure (span ending now, dur_ms long) or mark, returns the page epoch ms.
static func _page_stamp(label: String, dur_ms: float) -> float:
	if not OS.has_feature("web"):
		return -1.0
	var js_name := JSON.stringify("GT:" + label)
	var js_call := "performance.mark(%s)" % js_name if dur_ms < 0.0 \
			else "performance.measure(%s,{start:Math.max(0,n-%.3f),end:n})" % [js_name, dur_ms]
	var v: Variant = JavaScriptBridge.eval("(function(){var n=performance.now();try{%s;}catch(e){}return performance.timeOrigin+n;})()" % js_call, true)
	return float(v) if v is float or v is int else -1.0


## GLADIUS_CAN_MOVE (debug web builds only, like GLADIUS_MATCH_STARTED; WebArgs.debug_marker): printed once, at the
## first physics tick after MatchRoot.begin() returned a started match. That tick is the first one in which
## MatchRoot._physics_process hands the router's InputFrame to the local pawn while the director runs: aboard the
## carrier the pawn applies look and records Jump as its drop request (Pawn._physics_process, Drop.ABOARD), so it is
## the first moment the player's input acts. SceneTree.physics_frame fires just before the nodes' _physics_process.
## Also a GLADIUS_T "can_move" mark when timing is on. No-op everywhere else.
static func arm_can_move(tree: SceneTree) -> void:
	if tree == null or not (_WebArgs.is_debug() and _WebArgs.is_web()):
		return
	tree.physics_frame.connect(func() -> void:
			_WebArgs.debug_marker("GLADIUS_CAN_MOVE")
			mark("can_move"), CONNECT_ONE_SHOT)


## W1c fix pass 1, measurement only: the data/warmup.json "listed" kinds the shader warm-up leaves out, from the URL's
## warm_skip=<kind>[,<kind>...] (tools/web/perf.mjs --warm-skip=...: the "before" number of a warm entry, measured on
## the same commit). Only where enabled() (debug web build + ?perf=1); [] everywhere else, so release builds, desktop,
## Android, plain debug web runs and the headless suite always warm every entry.
static func warm_skip() -> PackedStringArray:
	var out := PackedStringArray()
	if not enabled():
		return out
	for kind in str(_WebArgs.query_pairs(_WebArgs.read_query()).get("warm_skip", "")).split(",", false):
		if kind.strip_edges() != "":
			out.append(kind.strip_edges())
	return out


## Test hook: forget the decided state.
static func reset_for_tests() -> void:
	_state = -1
