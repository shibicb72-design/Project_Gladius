extends "res://tests/test_case.gd"
## W1a commit 4: the browser frame-rate harness's game half. WebArgs.parse_perf reads ?perf=1&quality=<id>&seed=<n>
## only in a debug web build (flags as arguments, or simulated); bad values are ignored. Boot adds the PerfRoute node
## (scripts/debug/perf_route.gd) only for debug + web + perf=1. tools/web/perf_route.json: every view complete and
## inside alesia_500, total 90 s, the variant seeds pick their variants. PerfRoute.frame_stats on fixed deltas.
## Globals touched (WebArgs.simulate_*, PlatformServices.simulate_pc, GraphicsPresets, AppFlow.profile / match_seed,
## Engine.max_fps, the root viewport) are restored by every test.

const _WebArgs := preload("res://scripts/platform/web_args.gd")
const _PerfRoute := preload("res://scripts/debug/perf_route.gd")
const BOOT_SCENE := "res://scenes/boot/boot.tscn"
const ROUTE := "res://tools/web/perf_route.json"
const MAP := "res://data/maps/alesia_500.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i: int in n:
		await _tree().process_frame


func _route() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROUTE))
	return d if d is Dictionary else {}


func test_perf_arguments_parsed_in_a_debug_web_build() -> void:
	var r := _WebArgs.parse_perf("?autosolo=1&perf=1&quality=pc_high&seed=20261123", true, true)
	assert_eq(r.get("quality"), "pc_high", "quality")
	assert_eq(r.get("seed"), 20261123, "seed")
	r = _WebArgs.parse_perf("?perf=1", true, true)
	assert_eq(r, {"quality": "", "seed": 0}, "perf alone: no quality, no seed")
	for q: String in ["default", "pc_medium", "pc_high"]:
		assert_eq(_WebArgs.parse_perf("?perf=1&quality=" + q, true, true).get("quality"), q, "preset id " + q)
	assert_eq(_WebArgs.parse_perf("?perf=1&seed=-7", true, true).get("seed"), -7, "a negative whole seed is a seed")


func test_bad_perf_values_are_ignored() -> void:
	assert_eq(_WebArgs.parse_perf("?perf=1&quality=ultra", true, true).get("quality"), "", "unknown preset id")
	assert_eq(_WebArgs.parse_perf("?perf=1&quality=", true, true).get("quality"), "", "empty quality (Auto)")
	assert_eq(_WebArgs.parse_perf("?perf=1&seed=abc", true, true).get("seed"), 0, "non-numeric seed")
	assert_eq(_WebArgs.parse_perf("?perf=1&seed=1.5", true, true).get("seed"), 0, "a fractional seed")
	assert_eq(_WebArgs.parse_perf("?perf=1&seed=", true, true).get("seed"), 0, "empty seed")
	assert_true(_WebArgs.parse_perf("?perf=0&quality=pc_high&seed=3", true, true).is_empty(), "perf must be 1")
	assert_true(_WebArgs.parse_perf("?quality=pc_high&seed=3", true, true).is_empty(), "quality and seed need perf=1")
	assert_true(_WebArgs.parse_perf("", true, true).is_empty(), "no query")


func test_perf_arguments_ignored_in_release_and_off_web() -> void:
	var q := "?perf=1&quality=pc_high&seed=5"
	assert_true(_WebArgs.parse_perf(q, false, true).is_empty(), "release build ignores the URL")
	assert_true(_WebArgs.parse_perf(q, true, false).is_empty(), "off the web the URL is ignored")
	assert_true(_WebArgs.parse_perf(q, false, false).is_empty(), "release off the web")
	_WebArgs.simulate_query = q
	_WebArgs.simulate_debug = false
	_WebArgs.simulate_web = true
	assert_true(_WebArgs.perf_request().is_empty(), "perf_request: simulated release build")
	_WebArgs.simulate_debug = true
	assert_eq(_WebArgs.perf_request().get("seed"), 5, "perf_request: simulated debug web build")
	_WebArgs.simulate_query = null
	_WebArgs.simulate_debug = null
	_WebArgs.simulate_web = null
	assert_true(_WebArgs.perf_request().is_empty(), "the real headless run is not the web")


## Boots with the simulated query/flags; returns whether the root got a PerfRoute node (removed again) and its
## active preset afterwards.
func _boot_with(query: Variant, debug: Variant, web: Variant) -> Dictionary:
	var saved_profile: Dictionary = AppFlow.profile.duplicate(true)
	var saved_fps := Engine.max_fps
	var vp := _tree().root
	var saved := {"scale": vp.scaling_3d_scale, "msaa": vp.msaa_3d, "aniso": vp.anisotropic_filtering_level,
			"vsync": DisplayServer.window_get_vsync_mode()}
	_WebArgs.simulate_query = query
	_WebArgs.simulate_debug = debug
	_WebArgs.simulate_web = web
	PlatformServices.simulate_pc = true  # so a requested quality can take effect headless (a browser is a PC)
	var boot: Boot = load(BOOT_SCENE).instantiate()
	boot.auto_advance = false
	boot.navigate = func() -> void: pass
	vp.add_child(boot)
	await _frames(2)
	var node := vp.get_node_or_null(Boot.PERF_ROUTE_NAME)
	var own := GraphicsPresets.choose_id(SaveService.graphics_quality(AppFlow.profile.get("graphics_quality", null)), true)
	var out := {"added": node != null, "preset": GraphicsPresets.resolved_active_id(), "own": own,
			"script_ok": node != null and node.get_script() == _PerfRoute}
	if node != null:
		node.queue_free()
	boot.queue_free()
	await _frames(1)
	_WebArgs.simulate_query = null
	_WebArgs.simulate_debug = null
	_WebArgs.simulate_web = null
	PlatformServices.simulate_pc = false
	AppFlow.profile = saved_profile
	Engine.max_fps = saved_fps
	vp.scaling_3d_scale = saved["scale"]
	vp.msaa_3d = saved["msaa"]
	vp.anisotropic_filtering_level = saved["aniso"]
	DisplayServer.window_set_vsync_mode(saved["vsync"])
	RenderingServer.directional_shadow_atlas_set_size(GraphicsPresets.project_shadow_atlas_size(), GraphicsPresets.project_shadow_atlas_16_bits())
	GraphicsPresets.active_id = ""
	GraphicsPresets.applied = {}
	return out


func test_boot_adds_the_perf_node_only_for_debug_web_perf() -> void:
	var q := "?autosolo=1&perf=1&quality=pc_medium&seed=9"
	var r: Dictionary = await _boot_with(q, true, true)
	assert_true(bool(r["added"]), "debug + web + perf=1: PerfRoute under the root")
	assert_true(bool(r["script_ok"]), "the node runs scripts/debug/perf_route.gd")
	assert_eq(r["preset"], "pc_medium", "the requested quality is the active preset")
	r = await _boot_with(q, false, true)
	assert_true(not bool(r["added"]), "release build: no node")
	assert_eq(r["preset"], r["own"], "release build: the PC's own pick, not the URL's")
	r = await _boot_with(q, true, false)
	assert_true(not bool(r["added"]), "not the web: no node")
	r = await _boot_with("?autosolo=1&quality=pc_medium", true, true)
	assert_true(not bool(r["added"]), "no perf=1: no node")
	r = await _boot_with(null, null, null)
	assert_true(not bool(r["added"]), "the real headless run: no node")


func test_perf_node_sets_the_seed_when_the_match_root_enters() -> void:
	var saved_seed := AppFlow.match_seed
	var perf: Node = _PerfRoute.new()
	perf.request = {"quality": "", "seed": 4242}
	AppFlow.match_seed = 77  # what the solo lobby put there (randi())
	var match_root: Node = load("res://scripts/systems/match_root.gd").new()
	var other := Node.new()
	perf.call("_on_node_added", other)
	other.free()
	assert_eq(AppFlow.match_seed, 77, "another node: unchanged")
	perf.call("_on_node_added", match_root)
	assert_eq(AppFlow.match_seed, 4242, "MatchRoot entering: the URL seed replaces the lobby's")
	var perf2: Node = _PerfRoute.new()
	perf2.request = {"quality": "", "seed": 0}
	AppFlow.match_seed = 77
	perf2.call("_on_node_added", match_root)
	assert_eq(AppFlow.match_seed, 77, "no seed requested: the lobby's seed stays")
	match_root.free()
	perf.free()
	perf2.free()
	AppFlow.match_seed = saved_seed


func test_perf_route_data_is_complete_inside_the_map_and_90_s() -> void:
	var cfg := _route()
	assert_true(not cfg.is_empty(), "perf_route.json parses")
	assert_eq(cfg.get("map"), MAP, "the route is for alesia_500")
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP))
	var half := float(map["overrides"]["br"]["drop"]["map_half_m"])
	assert_true(half > 200.0, "alesia_500 map_half_m read (%s)" % half)
	var views: Array = cfg.get("views", [])
	assert_true(views.size() >= 4, "drop, market, a gate, the citadel")
	var names: Array = []
	for v: Variant in views:
		var view: Dictionary = v
		var n := str(view.get("name", ""))
		names.append(n)
		var pos: Variant = view.get("pos")
		assert_true(pos is Array and (pos as Array).size() == 2, "%s: pos [x, z]" % n)
		for key: String in ["eye_m", "yaw_deg", "pitch_deg", "fov_deg", "travel_s", "hold_s"]:
			assert_true(view.get(key) is float or view.get(key) is int, "%s: %s is a number" % [n, key])
		if pos is Array and (pos as Array).size() == 2:
			assert_true(absf(float(pos[0])) <= half and absf(float(pos[1])) <= half, "%s at %s inside +-%s m" % [n, pos, half])
		assert_true(float(view.get("fov_deg", 0)) > 20.0 and float(view.get("fov_deg", 0)) < 120.0, "%s: fov sane" % n)
		assert_true(absf(float(view.get("pitch_deg", 0))) < 80.0, "%s: pitch below 80 deg (look_at stays defined)" % n)
	for want: String in ["drop", "market", "porta_aquilae", "citadel_top"]:
		assert_true(names.has(want), "view %s present" % want)
	assert_true(names.has(cfg.get("shot_view")), "shot_view names a view")
	assert_eq(float(cfg.get("total_s", 0)), 90.0, "total_s 90")
	var segs: Array = _PerfRoute.timeline(views, 1.0)
	assert_true(is_equal_approx(_PerfRoute.timeline_length(segs), 90.0), "the views add up to 90 s (%s)" % _PerfRoute.timeline_length(segs))
	assert_true(is_equal_approx(_PerfRoute.timeline_length(_PerfRoute.timeline(views, 20.0 / 90.0)), 20.0), "--seconds=20 scales to 20 s")
	assert_eq(str(segs[0]["name"]), "drop", "the route opens on the drop hold")
	var seeds: Dictionary = cfg.get("variant_seeds", {})
	assert_eq(seeds.size(), 3, "a seed per variant")
	for variant: String in seeds:
		assert_eq(MatchLook.variant_for_seed(int(seeds[variant])), variant, "seed %s picks %s" % [seeds[variant], variant])
	assert_eq(int(cfg.get("seed", 0)), int(seeds.get("dusk", -1)), "the perf seed is the dusk seed")


func test_frame_stats_on_fixed_deltas() -> void:
	var d: Array = []
	for i in 95:
		d.append(10.0)
	d.append_array([20.0, 30.0, 40.0, 50.0, 60.0])
	d.shuffle()
	var s: Dictionary = _PerfRoute.frame_stats(d)
	assert_eq(s["frames"], 100, "frames")
	assert_eq(s["median_ms"], 10.0, "median")
	assert_eq(s["mean_ms"], 11.5, "mean")
	assert_eq(s["p99_ms"], 50.0, "p99 nearest rank = sorted[98]")
	assert_eq(s["one_percent_low_ms"], 60.0, "1 percent low = mean of the slowest 1 frame")
	assert_eq(s["one_percent_low_fps"], 16.7, "1000 / 60")
	assert_eq(s["over_33ms"], 3, "40, 50, 60 are over 33 ms")
	assert_eq(s["max_ms"], 60.0, "max")
	var e: Array = []
	for i in 198:
		e.append(16.0)
	e.append_array([100.0, 200.0])
	s = _PerfRoute.frame_stats(e)
	assert_eq(s["one_percent_low_ms"], 150.0, "200 frames: the slowest 2 averaged")
	assert_eq(s["median_ms"], 16.0, "even count: mean of the two middle values")
	assert_eq(_PerfRoute.frame_stats([1.0, 2.0, 3.0, 4.0])["median_ms"], 2.5, "median of 1..4")
	assert_eq(_PerfRoute.frame_stats([33.0, 33.5])["over_33ms"], 1, "33.0 is not over 33 ms")
	assert_eq(_PerfRoute.frame_stats([]), {"frames": 0}, "no frames")
