extends "res://tests/test_case.gd"
## W0 commits 3-4: the Web export preset (appended; Android and iOS untouched), rendering_method.web, and the
## debug-only URL arguments (WebArgs, binding fixes 9 and 12): ?autosolo=1&length=<id>&wait=<s> is parsed only in a
## debug build in the browser (both flags are arguments of the pure parse, or simulated), an unknown length means the
## data default, and the menu + solo lobby turn a request into a started match exactly as Play solo + Start.
## WebArgs' simulate_* / _taken / pending and AppFlow's session / lobby / solo / profile are globals: every test
## restores them. Profile writes go to TMP only.

const _WebArgs := preload("res://scripts/platform/web_args.gd")
const PRESETS := "res://export_presets.cfg"
const TMP := "user://test_w0_web_profile.json"
const QUERY := "?autosolo=1&length=12"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _preset(cfg: ConfigFile, platform: String) -> String:
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and cfg.get_value(section, "platform", "") == platform:
			return section
	return ""


func _restore(old_profile: Dictionary) -> void:
	AppFlow.end_session()
	AppFlow.session = null
	AppFlow.lobby = null
	AppFlow.solo = false
	AppFlow.match_seed = 0
	AppFlow.profile = old_profile
	_WebArgs.reset_for_tests()
	_WebArgs._taken = true  # as after the first menu of the run: no later menu in the suite takes a request
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## Records printed lines while installed (debug_marker below).
class _PrintSpy extends Logger:
	var lines: Array[String] = []

	func _log_message(message: String, _error: bool) -> void:
		lines.append(message.strip_edges())


func test_web_preset_single_threaded_and_excludes_tests_and_tools() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(PRESETS), OK, "cannot load " + PRESETS)
	var section := _preset(cfg, "Web")
	assert_true(section != "", "no preset with platform Web")
	if section == "":
		return
	var opts := section + ".options"
	assert_eq(cfg.get_value(section, "name", ""), "Web")
	assert_eq(cfg.get_value(section, "export_path", ""), "build/web/index.html")
	assert_eq(cfg.get_value(opts, "variant/thread_support", true), false, "single-threaded (no COOP/COEP headers)")
	assert_eq(cfg.get_value(opts, "vram_texture_compression/for_desktop", false), true, "desktop texture compression")
	assert_eq(cfg.get_value(opts, "html/canvas_resize_policy", -1), 2, "adaptive: the canvas fills the tab")
	assert_eq(cfg.get_value(opts, "html/focus_canvas_on_start", false), true, "keys reach the game at once")
	var excludes: Array[String] = []
	for f in str(cfg.get_value(section, "exclude_filter", "")).split(",", false):
		excludes.append(f.strip_edges())
	assert_true("tests/*" in excludes and "tools/*" in excludes, "tests and tools excluded: %s" % [excludes])
	assert_true(str(cfg.get_value(section, "include_filter", "")).contains("data/*.json"), "data json packed")
	for other: String in ["Android", "iOS"]:
		assert_true(_preset(cfg, other) != "", "the %s preset stays" % other)


func test_web_renderer_is_compatibility() -> void:
	assert_eq(str(ProjectSettings.get_setting("rendering/renderer/rendering_method.web", "")), "gl_compatibility",
			"rendering_method.web set explicitly")
	assert_eq(str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")), "mobile",
			"the base renderer is unchanged")


func test_query_pairs_decodes_and_lowercases_keys() -> void:
	var p := _WebArgs.query_pairs("?AutoSolo=1&length=%31%32&flag&=x&wait=2.5")
	assert_eq(p.get("autosolo"), "1")
	assert_eq(p.get("length"), "12", "URI-decoded")
	assert_eq(p.get("flag"), "", "bare key")
	assert_eq(p.get("wait"), "2.5")
	assert_true(not p.has(""), "an empty key is dropped")
	assert_true(_WebArgs.query_pairs("").is_empty() and _WebArgs.query_pairs("?").is_empty(), "empty query")


func test_autosolo_parsed_in_a_debug_web_build() -> void:
	var r := _WebArgs.parse(QUERY, true, true)
	assert_eq(r.get("length"), "12", "the requested length")
	assert_eq(float(r.get("wait_s", -1.0)), 0.0, "no wait by default")
	r = _WebArgs.parse(QUERY + "&wait=4", true, true)
	assert_eq(float(r.get("wait_s", -1.0)), 4.0, "lobby wait")


func test_autosolo_ignored_in_release_and_off_web() -> void:
	assert_true(_WebArgs.parse(QUERY, false, true).is_empty(), "release build ignores the URL")
	assert_true(_WebArgs.parse(QUERY, true, false).is_empty(), "off the web the URL is ignored")
	assert_true(_WebArgs.parse(QUERY, false, false).is_empty(), "release off the web")
	assert_true(_WebArgs.parse("?autosolo=0&length=12", true, true).is_empty(), "autosolo must be 1")
	assert_true(_WebArgs.parse("?length=12", true, true).is_empty(), "no autosolo key")


func test_bad_length_and_wait_fall_back() -> void:
	var def := SaveService.match_length_default()
	assert_true(def != "", "br.json has a default length")
	assert_eq(_WebArgs.parse("?autosolo=1&length=99", true, true).get("length"), def, "unknown id -> data default")
	assert_eq(_WebArgs.parse("?autosolo=1&length=", true, true).get("length"), def, "empty id -> data default")
	assert_eq(_WebArgs.parse("?autosolo=1", true, true).get("length"), def, "missing id -> data default")
	assert_eq(float(_WebArgs.parse("?autosolo=1&wait=abc", true, true).get("wait_s")), 0.0, "bad wait -> 0")
	assert_eq(float(_WebArgs.parse("?autosolo=1&wait=-3", true, true).get("wait_s")), 0.0, "negative wait -> 0")
	assert_eq(float(_WebArgs.parse("?autosolo=1&wait=999", true, true).get("wait_s")), _WebArgs.MAX_WAIT_S,
			"wait clamped")


func test_take_autosolo_once_and_real_flags_ignore_it_headless() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_WebArgs.reset_for_tests()
	assert_eq(_WebArgs.read_query(), "", "no query string off the web")
	assert_true(_WebArgs.take_autosolo().is_empty(), "headless (not the web): nothing")
	_WebArgs.reset_for_tests()
	_WebArgs.simulate_query = QUERY
	_WebArgs.simulate_debug = true
	_WebArgs.simulate_web = true
	assert_eq(_WebArgs.take_autosolo().get("length"), "12", "first take")
	assert_true(_WebArgs.take_autosolo().is_empty(), "handed out once per run")
	_WebArgs.reset_for_tests()
	_WebArgs.simulate_query = QUERY
	_WebArgs.simulate_debug = false
	_WebArgs.simulate_web = true
	assert_true(_WebArgs.take_autosolo().is_empty(), "simulated release build: nothing")
	_restore(old_profile)


func test_debug_marker_prints_only_in_a_debug_web_build() -> void:
	var old_profile: Dictionary = AppFlow.profile
	var spy := _PrintSpy.new()
	OS.add_logger(spy)
	_WebArgs.reset_for_tests()
	_WebArgs.debug_marker("W0_MARKER_HEADLESS")
	_WebArgs.simulate_debug = true
	_WebArgs.simulate_web = true
	_WebArgs.debug_marker("W0_MARKER_WEB")
	_WebArgs.simulate_debug = false
	_WebArgs.debug_marker("W0_MARKER_RELEASE")
	OS.remove_logger(spy)
	assert_true("W0_MARKER_WEB" in spy.lines, "printed in a debug web build: %s" % [spy.lines])
	assert_true(not "W0_MARKER_HEADLESS" in spy.lines, "quiet headless")
	assert_true(not "W0_MARKER_RELEASE" in spy.lines, "quiet in release")
	_restore(old_profile)


func test_autosolo_menu_and_lobby_start_a_solo_match() -> void:
	var old_profile: Dictionary = AppFlow.profile
	AppFlow.profile = {"gamertag": "Solus"}
	AppFlow.session = null
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	menu.save = SaveService.new(TMP)
	var went: Array = []
	menu.go_scene = func(p: String) -> void: went.append(p)
	_root().add_child(menu)
	await _frames(1)
	assert_true(not menu.apply_autosolo({}), "no request: nothing happens")
	assert_true(went.is_empty() and not AppFlow.solo, "no scene change without a request")
	var request := _WebArgs.parse(QUERY + "&wait=0.3", true, true)
	assert_true(menu.apply_autosolo(request), "the request presses Play solo")
	assert_true(AppFlow.solo, "solo flag set")
	assert_eq(went, [AppFlow.LOBBY_SCENE], "the solo lobby opens")
	assert_eq(_WebArgs.pending.get("length"), "12", "the request waits for the lobby")
	menu.free()

	var s := NetSession.new()
	s.name = "W0WebSession"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	var lobby_went: Array = []
	lobby.go_scene = func(p: String) -> void: lobby_went.append(p)
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP)
	assert_true(_WebArgs.pending.is_empty(), "the lobby took the request")
	assert_true(lobby.solo and not s.has_enet_peer(), "solo lobby, no ENet peer")
	assert_eq(lobby.state.match_length, "12", "the requested length applied")
	await _frames(2)
	assert_true(lobby_went.is_empty(), "still in the lobby during the wait")
	await _tree().create_timer(0.5).timeout
	assert_eq(lobby_went, [AppFlow.MATCH_SCENE], "Start pressed after the wait")
	assert_true(AppFlow.lobby != null and AppFlow.lobby.started, "the lobby state started")
	assert_eq(AppFlow.lobby.match_length, "12", "started with the requested length")
	lobby.free()
	await _frames(1)
	_restore(old_profile)


func test_leaving_the_lobby_during_the_wait_cancels_the_start() -> void:
	var old_profile: Dictionary = AppFlow.profile
	AppFlow.profile = {"gamertag": "Solus"}
	var s := NetSession.new()
	s.name = "W0WebSession2"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	AppFlow.solo = true
	_WebArgs.pending = _WebArgs.parse(QUERY + "&wait=0.2", true, true)
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	var lobby_went: Array = []
	lobby.go_scene = func(p: String) -> void: lobby_went.append(p)
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP)
	await _frames(1)
	lobby.free()
	await _tree().create_timer(0.4).timeout
	assert_true(lobby_went.is_empty(), "no Start after the lobby was left: %s" % [lobby_went])
	assert_true(AppFlow.lobby == null or not AppFlow.lobby.started, "nothing started")
	_restore(old_profile)
