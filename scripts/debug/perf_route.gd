extends Node
## W1a commit 4, DEBUG WEB BUILDS ONLY: the in-game half of the browser frame-rate harness (tools/web/perf.mjs;
## docs/WEB.md "Frame-rate harness"; docs/ARCHITECTURE.md "W1a perf hook"). Boot puts this node under the tree root
## only when WebArgs.perf_request() is non-empty (debug build + web + ?perf=1); release builds never create it. It edits
## no game file and changes no gameplay: it rides on W0's ?autosolo=1 match start and only
##   - at setup: applies the URL's quality through GraphicsPresets.apply_settings (a profile COPY with
##     graphics_quality set; nothing is saved), before any match look is built;
##   - when the match scene root (MatchRoot) enters the tree, before its _ready/begin: sets AppFlow.match_seed to the
##     URL's seed (the solo lobby has just put randi() there; MatchRoot.begin reads AppFlow.match_seed), so loot, bots'
##     seeded streams and the look variant (art_look.json rotation.by_seed) are fixed;
##   - once the director runs and warmup_frames have passed: makes its OWN Camera3D current (near/far copied from the
##     match camera) and flies the fixed route (views in DATA: tools/web/perf_route.json, injected by the harness as
##     window.GLADIUS_PERF_ROUTE because tools/ is not exported) for total_s x scale seconds of route clock (real time,
##     but at most MAX_STEP_S per frame, so a freeze stalls the camera instead of skipping views), recording every
##     frame's real delta (Time.get_ticks_usec between consecutive _process calls of this node);
##   - then the frame-cap probe: Engine.max_fps = 30, 60, 0 for probe.seconds each (after probe.settle_s), median
##     frame time each, then the value it found is restored;
##   - prints GLADIUS_PERF_DONE <json> and sets window.GLADIUS_PERF_RESULT.
## Bots, the local pawn and the zone are whatever the autosolo match gives (17 bots, lobby difficulty); the harness
## camera does not depend on them. The local player stands idle in the drop; if it is eliminated, SpectatorCamera takes
## the current camera once and this node takes it back (camera_retakes counts it).
## Console markers: GLADIUS_PERF_ARMED, GLADIUS_PERF_ROUTE_START <json>, GLADIUS_PERF_VIEW <name> (a hold begins),
## GLADIUS_PERF_PROBE <cap>, GLADIUS_PERF_DONE <json>, GLADIUS_PERF_ERROR <text>.

const ROUTE_RES := "res://tools/web/perf_route.json"
const FREEZE_MS := 250.0
const SLOW_MS := 33.0
## The most one frame advances the route clock (seconds): a freeze longer than this stalls the camera instead of
## skipping views. Tool constant, not a budget.
const MAX_STEP_S := 0.1

enum Phase { WAIT_MATCH, WARMUP, ROUTE, PROBE, DONE, FAILED }

## The URL request ({"quality", "seed"}) and the route config (perf_route.json plus the harness's "seconds"/"shots").
var request: Dictionary = {}
var route: Dictionary = {}
## Route time scale: the harness's --seconds / total_s (1.0 = the full route).
var time_scale: float = 1.0
## Web capture mode (harness --shots): the HUD layer is hidden so the screenshot shows the look only.
var shots: bool = false
var phase: Phase = Phase.WAIT_MATCH
## The published result (also window.GLADIUS_PERF_RESULT); {} until DONE.
var result: Dictionary = {}

var _match: Node
var _camera: Camera3D
var _segments: Array = []
var _total_s: float = 0.0
var _warm: int = 0
var _warmup_frames: int = 60
var _running_usec: int = 0
var _start_usec: int = 0
var _last_usec: int = 0
var _route_t: float = 0.0
var _route_wall_s: float = 0.0
var _deltas: Array = []
var _seg_deltas: Array = []
var _freezes: Array = []
var _cur_seg: int = -1
var _camera_retakes: int = 0
var _start_info: Dictionary = {}
var _saved_fps: int = 0
var _probe_caps: Array = [30, 60, 0]
var _probe_i: int = 0
var _probe_t0: int = 0
var _probe_deltas: Array = []
var _probe_out: Array = []


## Called by Boot before the node enters the tree: keeps the request and applies its quality (if any) to `viewport`.
func setup(req: Dictionary, viewport: Viewport) -> void:
	request = req.duplicate(true)
	var q := str(request.get("quality", ""))
	if q != "":
		var prof: Dictionary = AppFlow.profile.duplicate(true)
		prof["graphics_quality"] = q
		GraphicsPresets.new().apply_settings(prof, viewport, PlatformServices.new().is_pc())


func _ready() -> void:
	process_priority = 1000  # after the match's own nodes, so its camera retake is the last word of the frame
	process_mode = Node.PROCESS_MODE_ALWAYS
	var injected := injected_config()
	route = injected.get("route", {}) if injected.get("route") is Dictionary else {}
	if route.is_empty():
		route = load_route_file(ROUTE_RES)
	if route.is_empty() or (route.get("views", []) as Array).is_empty():
		_fail("no route: window.GLADIUS_PERF_ROUTE missing and %s unreadable" % ROUTE_RES)
		return
	_total_s = float(route.get("total_s", 90.0))
	var seconds := float(injected.get("seconds", _total_s))
	time_scale = clampf(seconds / _total_s, 0.01, 10.0) if _total_s > 0.0 else 1.0
	shots = bool(injected.get("shots", false))
	_warmup_frames = maxi(0, int(route.get("warmup_frames", 60)))
	var probe: Dictionary = route.get("probe", {})
	_probe_caps = probe.get("caps", [30, 60, 0])
	_segments = timeline(route["views"], time_scale)
	get_tree().node_added.connect(_on_node_added)
	print("GLADIUS_PERF_ARMED " + JSON.stringify({"quality": request.get("quality", ""), "seed": request.get("seed", 0),
			"time_scale": time_scale, "shots": shots, "active_preset": GraphicsPresets.resolved_active_id()}))


## The harness's injected config (window.GLADIUS_PERF_ROUTE = {"route": <perf_route.json>, "seconds", "shots"}), or {}.
static func injected_config() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var v: Variant = JavaScriptBridge.eval("JSON.stringify(window.GLADIUS_PERF_ROUTE || null)", true)
	if v is String:
		var d: Variant = JSON.parse_string(v)
		if d is Dictionary:
			return d
	return {}


## The page clock (performance.timeOrigin + performance.now(), epoch ms) in the browser, so the harness can place its
## own requestAnimationFrame stamps against the route without the console's delivery delay; -1 off the web.
static func page_epoch_ms() -> float:
	if not OS.has_feature("web"):
		return -1.0
	var v: Variant = JavaScriptBridge.eval("performance.timeOrigin + performance.now()", true)
	return float(v) if v is float or v is int else -1.0


static func load_route_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


## Pure: the route's segments in order. Each view gives a "travel" segment from the previous view (travel_s > 0; the
## first view's travel is ignored) and a "hold" segment at the view (hold_s > 0). Times are scaled by `scale`.
## A segment: {"name", "kind", "from": view, "to": view, "start_s", "end_s"}.
static func timeline(views: Array, scale: float) -> Array:
	var out: Array = []
	var t := 0.0
	var prev: Dictionary = {}
	for v: Variant in views:
		var view: Dictionary = v
		var travel := float(view.get("travel_s", 0.0)) * scale
		if not prev.is_empty() and travel > 0.0:
			out.append({"name": "to_" + str(view["name"]), "kind": "travel", "from": prev, "to": view, "start_s": t, "end_s": t + travel})
			t += travel
		var hold := float(view.get("hold_s", 0.0)) * scale
		if hold > 0.0:
			out.append({"name": str(view["name"]), "kind": "hold", "from": view, "to": view, "start_s": t, "end_s": t + hold})
			t += hold
		prev = view
	return out


## Pure: the route length of a timeline (seconds).
static func timeline_length(segments: Array) -> float:
	return float(segments[-1]["end_s"]) if not segments.is_empty() else 0.0


## Pure: compass bearing (0 = north = -z, 90 = east = +x) and up-positive pitch to a forward vector (parity_capture's).
static func forward(yaw_deg: float, pitch_deg: float) -> Vector3:
	var y := deg_to_rad(yaw_deg)
	var p := deg_to_rad(pitch_deg)
	return Vector3(sin(y) * cos(p), sin(p), -cos(y) * cos(p))


## Pure: frame statistics of real frame deltas in milliseconds.
##   median_ms: the middle value (the mean of the two middle values for an even count);
##   p99_ms: the nearest-rank 99th percentile (sorted[ceil(0.99 n) - 1]);
##   one_percent_low_ms: the MEAN of the slowest 1 percent of frames (at least one frame), one_percent_low_fps its
##   1000 / x; over_33ms: frames longer than 33 ms; max_ms the longest; mean_ms the mean.
static func frame_stats(deltas: Array) -> Dictionary:
	var n := deltas.size()
	if n == 0:
		return {"frames": 0}
	var s: Array = deltas.duplicate()
	s.sort()
	var mid := n >> 1
	var median := float(s[mid]) if n % 2 == 1 else (float(s[mid - 1]) + float(s[mid])) * 0.5
	var p99 := float(s[clampi(ceili(0.99 * n) - 1, 0, n - 1)])
	var worst_n := maxi(1, floori(n * 0.01))
	var worst_sum := 0.0
	for i in worst_n:
		worst_sum += float(s[n - 1 - i])
	var low := worst_sum / worst_n
	var total := 0.0
	var over := 0
	for d: Variant in s:
		total += float(d)
		if float(d) > SLOW_MS:
			over += 1
	return {
		"frames": n,
		"median_ms": snappedf(median, 0.01),
		"mean_ms": snappedf(total / n, 0.01),
		"p99_ms": snappedf(p99, 0.01),
		"one_percent_low_ms": snappedf(low, 0.01),
		"one_percent_low_fps": snappedf(1000.0 / low, 0.1) if low > 0.0 else 0.0,
		"over_33ms": over,
		"max_ms": snappedf(float(s[n - 1]), 0.01),
	}


func _on_node_added(node: Node) -> void:
	if _match != null or not (node is MatchRoot):
		return
	_match = node
	var seed_value := int(request.get("seed", 0))
	if seed_value != 0:
		AppFlow.match_seed = seed_value  # read by MatchRoot.begin (match_root.gd ~:261), which runs in this node's _ready


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	match phase:
		Phase.WAIT_MATCH:
			if _match != null and is_instance_valid(_match) and _match.is_inside_tree():
				var director: Variant = _match.get("director")
				if director != null and bool(director.get("running")) and _match.get("local_player") != null:
					_running_usec = now
					phase = Phase.WARMUP
		Phase.WARMUP:
			_warm += 1
			if _warm >= _warmup_frames:
				_start_route(now)
		Phase.ROUTE:
			_route_frame(now)
		Phase.PROBE:
			_probe_frame(now)


func _ground(x: float, z: float) -> float:
	var map: Variant = _match.get("map")
	if map is Node and (map as Node).has_node("ArtBuilder"):
		var terrain: Variant = (map as Node).get_node("ArtBuilder").get("terrain")
		if terrain is MapTerrain:
			return (terrain as MapTerrain).height_at(x, z)
	return 0.0


func _view_point(view: Dictionary) -> Vector3:
	var pos: Array = view["pos"]
	var x := float(pos[0])
	var z := float(pos[1])
	return Vector3(x, _ground(x, z) + float(view.get("eye_m", 1.7)), z)


func _start_route(now: int) -> void:
	if not _match_ok():
		return
	for seg: Dictionary in _segments:
		seg["from_at"] = _view_point(seg["from"])
		seg["to_at"] = _view_point(seg["to"])
		_seg_deltas.append([])
	var old := get_viewport().get_camera_3d()
	_camera = Camera3D.new()
	_camera.name = "PerfRouteCamera"
	if old != null:
		_camera.near = old.near
		_camera.far = old.far
		_camera.keep_aspect = old.keep_aspect
	_match.add_child(_camera)
	_camera.make_current()
	if shots:
		var hud := _match.get_node_or_null("Hud") as CanvasLayer
		if hud != null:
			hud.visible = false
	var vp := get_viewport()
	var bots: Variant = _match.get("bots")
	_start_info = {
		"preset_active": GraphicsPresets.resolved_active_id(),
		"quality_requested": request.get("quality", ""),
		"seed": AppFlow.match_seed,
		"variant": MatchLook.variant_for_seed(AppFlow.match_seed),
		"max_fps": Engine.max_fps,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"viewport_size": [(vp as Window).size.x, (vp as Window).size.y] if vp is Window else [vp.get_visible_rect().size.x, vp.get_visible_rect().size.y],
		"content_scale_visible_rect": [vp.get_visible_rect().size.x, vp.get_visible_rect().size.y],
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"msaa_3d": vp.msaa_3d,
		"scaling_3d_scale": vp.scaling_3d_scale,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"camera_far_m": _camera.far,
		"bots": (bots as Array).size() if bots is Array else -1,
		"time_scale": time_scale,
		"route_s": timeline_length(_segments),
		"warmup_frames": _warmup_frames,
		"seconds_director_running_to_route": snappedf((now - _running_usec) / 1e6, 0.01),
		"shots": shots,
		"page_epoch_ms": page_epoch_ms(),
	}
	print("GLADIUS_PERF_ROUTE_START " + JSON.stringify(_start_info))
	_start_usec = now
	_last_usec = now
	_place(0.0)
	phase = Phase.ROUTE


func _match_ok() -> bool:
	if _match == null or not is_instance_valid(_match) or not _match.is_inside_tree():
		_fail("the match left the tree during %s" % Phase.keys()[phase])
		return false
	return true


func _segment_at(t: float) -> int:
	for i in _segments.size():
		if t < float(_segments[i]["end_s"]):
			return i
	return _segments.size() - 1


## Puts the camera on the route at route time t (seconds) and prints GLADIUS_PERF_VIEW when a hold begins.
func _place(t: float) -> void:
	var i := _segment_at(t)
	var seg: Dictionary = _segments[i]
	if i != _cur_seg:
		_cur_seg = i
		if seg["kind"] == "hold":
			print("GLADIUS_PERF_VIEW " + str(seg["name"]))
	var a: Dictionary = seg["from"]
	var b: Dictionary = seg["to"]
	var span := float(seg["end_s"]) - float(seg["start_s"])
	var u := smoothstep(0.0, 1.0, clampf((t - float(seg["start_s"])) / span, 0.0, 1.0)) if span > 0.0 else 1.0
	var at: Vector3 = (seg["from_at"] as Vector3).lerp(seg["to_at"], u)
	if seg["kind"] == "travel":
		at.y += float(b.get("arc_m", 0.0)) * sin(PI * u)
	var yaw := rad_to_deg(lerp_angle(deg_to_rad(float(a.get("yaw_deg", 0.0))), deg_to_rad(float(b.get("yaw_deg", 0.0))), u))
	var pitch := lerpf(float(a.get("pitch_deg", 0.0)), float(b.get("pitch_deg", 0.0)), u)
	_camera.fov = lerpf(float(a.get("fov_deg", 75.0)), float(b.get("fov_deg", 75.0)), u)
	_camera.global_position = at
	_camera.look_at(at + forward(yaw, pitch) * 100.0, Vector3.UP)
	if not _camera.current:
		_camera.make_current()
		_camera_retakes += 1


func _route_frame(now: int) -> void:
	if not _match_ok():
		return
	var dt_ms := (now - _last_usec) / 1000.0
	_last_usec = now
	# The delta ends the frame that rendered the camera placed last frame: it belongs to that placement's segment.
	var i := maxi(_cur_seg, 0)
	_deltas.append(dt_ms)
	(_seg_deltas[i] as Array).append(dt_ms)
	if dt_ms > FREEZE_MS:
		_freezes.append({"route_t_s": snappedf(_route_t, 0.01), "wall_s": snappedf((now - _start_usec) / 1e6, 0.01),
				"ms": snappedf(dt_ms, 0.1), "segment": _segments[i]["name"]})
	# Route clock: real time, but one frame advances it by at most MAX_STEP_S, so a multi-second freeze does not skip
	# views (every view gets rendered frames); the wall time the route took is reported as route_wall_s.
	_route_t += minf(dt_ms / 1000.0, MAX_STEP_S)
	var t := _route_t
	if t >= timeline_length(_segments):
		_route_wall_s = (now - _start_usec) / 1e6
		_place(timeline_length(_segments))
		_saved_fps = Engine.max_fps
		_probe_i = 0
		_probe_start(now)
		phase = Phase.PROBE
		return
	_place(t)


func _probe_start(now: int) -> void:
	Engine.max_fps = int(_probe_caps[_probe_i])
	_probe_t0 = now
	_last_usec = now
	_probe_deltas = []
	if _probe_i == 0:
		_start_info["probe_page_epoch_ms"] = page_epoch_ms()
	print("GLADIUS_PERF_PROBE %d" % Engine.max_fps)


func _probe_frame(now: int) -> void:
	if not _match_ok():
		Engine.max_fps = _saved_fps
		return
	var probe: Dictionary = route.get("probe", {})
	var settle := float(probe.get("settle_s", 0.5))
	var seconds := float(probe.get("seconds", 5.0))
	var dt_ms := (now - _last_usec) / 1000.0
	_last_usec = now
	var t := (now - _probe_t0) / 1e6
	if t > settle:
		_probe_deltas.append(dt_ms)
	if not _camera.current:
		_camera.make_current()
		_camera_retakes += 1
	if t < settle + seconds:
		return
	var st := frame_stats(_probe_deltas)
	_probe_out.append({"max_fps": int(_probe_caps[_probe_i]), "frames": st.get("frames", 0),
			"median_ms": st.get("median_ms", 0.0), "implied_fps": snappedf(1000.0 / float(st["median_ms"]), 0.1) if float(st.get("median_ms", 0.0)) > 0.0 else 0.0})
	_probe_i += 1
	if _probe_i < _probe_caps.size():
		_probe_start(now)
		return
	Engine.max_fps = _saved_fps
	_finish()


func _finish() -> void:
	var segs: Array = []
	for i in _segments.size():
		var st := frame_stats(_seg_deltas[i])
		segs.append({"name": _segments[i]["name"], "kind": _segments[i]["kind"],
				"start_s": snappedf(float(_segments[i]["start_s"]), 0.01), "end_s": snappedf(float(_segments[i]["end_s"]), 0.01),
				"frames": st.get("frames", 0), "median_ms": st.get("median_ms", null), "max_ms": st.get("max_ms", null)})
	result = _start_info.duplicate()
	result["ok"] = true
	result["route"] = frame_stats(_deltas)
	result["one_percent_low_definition"] = "mean of the slowest 1 percent of frame deltas (at least one frame)"
	result["p99_definition"] = "nearest-rank 99th percentile of frame deltas"
	result["segments"] = segs
	result["freezes_over_250ms"] = _freezes
	result["camera_retakes"] = _camera_retakes
	result["cap_probe"] = _probe_out
	result["max_fps_restored"] = Engine.max_fps
	result["clock"] = "Time.get_ticks_usec between consecutive _process calls of PerfRoute (real time); a delta counts for the segment the camera was in while that frame rendered"
	result["route_clock"] = "real time, at most %.2f s per frame (a freeze stalls the camera; it does not skip views)" % MAX_STEP_S
	result["route_wall_s"] = snappedf(_route_wall_s, 0.01)
	phase = Phase.DONE
	_publish("GLADIUS_PERF_DONE")


func _fail(why: String) -> void:
	result = {"ok": false, "error": why}
	phase = Phase.FAILED
	print("GLADIUS_PERF_ERROR " + why)
	_publish("GLADIUS_PERF_DONE")


func _publish(marker: String) -> void:
	var json := JSON.stringify(result)
	print(marker + " " + json)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.GLADIUS_PERF_RESULT = " + json + ";", true)
