extends "res://tests/test_case.gd"
## G2d2: the match applies the player's sensitivity settings at start and again whenever the in-match Settings
## panel or Sensitivity screen saves (MatchRoot.apply_sensitivity), and the kept quick "Gyro aim" toggle stays
## in step with the new gyro mode (OQ-GYRO-TOGGLE).

const _MatchScene := preload("res://scenes/match/match.tscn")
const _PanelScene := preload("res://scenes/ui/settings_panel.tscn")
const _TMP := "user://test_profile_match_sens.json"
const ADS_VALUE := 37.0
const CAMERA_VALUE := 173.0
const ROW := "tpp_fpp_no_scope"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _remove_tmp() -> void:
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))


## Starts an offline match whose profile (AppFlow.profile) is `profile`. Returns {"match", "touch"}: `touch` is a
## TouchProvider with a fixed look deflection that the test adds to the match's router to measure the look output.
func _start_match(profile: Dictionary) -> Dictionary:
	var tree := _tree()
	AppFlow.profile = profile
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 0.0
	assert_true(m.begin(), "match begins")
	m.pause_menu.settings.save = SaveService.new(_TMP)
	var t := TouchProvider.new()
	t.configure(DataRegistry.new().load_file("res://data/input.json"))
	t.look_value = Vector2(0.5, 0.0)
	m.router.add_provider(t)
	await tree.physics_frame
	return {"match": m, "touch": t}


func _finish(m: MatchRoot) -> void:
	Input.action_release("aim")
	m.queue_free()
	AppFlow.profile = {}
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	_remove_tmp()
	await _tree().process_frame
	await _tree().process_frame


## The look x the match's router produces right now, as a percent of the base look (100 = unscaled).
func _look_percent(m: MatchRoot, touch: TouchProvider) -> float:
	var base := touch.get_look().x
	assert_true(absf(base) > 0.0, "the fixed deflection produces a base look")
	return m.router.update_frame().look.x / base * 100.0


func _profile_with(ads: float, camera: float) -> Dictionary:
	var s := SensitivitySettings.new()
	s.set_value("ads", ROW, ads)
	s.set_value("camera", ROW, camera)
	var p := SaveService.new(_TMP).load_profile()
	p["sensitivity"] = s.to_dict()
	return p


func test_match_uses_ads_table_while_aiming_and_camera_table_otherwise() -> void:
	_remove_tmp()
	var ctx := await _start_match(_profile_with(ADS_VALUE, CAMERA_VALUE))
	var m: MatchRoot = ctx["match"]
	var touch: TouchProvider = ctx["touch"]
	assert_true(m.router.sens.percent("ads", ROW) != m.router.sens.percent("camera", ROW), "two different values")
	assert_true(is_equal_approx(_look_percent(m, touch), CAMERA_VALUE), "not aiming: Camera value")
	Input.action_press("aim")
	var n := 0
	while m.local_player.aim_blend <= 0.0 and n < 120:
		await _tree().physics_frame
		n += 1
	assert_true(m.local_player.aim_blend > 0.0, "aim_blend rose while Aim is held")
	await _tree().physics_frame
	assert_true(is_equal_approx(_look_percent(m, touch), ADS_VALUE), "aiming: ADS value, got %s" % _look_percent(m, touch))
	Input.action_release("aim")
	n = 0
	while m.local_player.aim_blend > 0.0 and n < 240:
		await _tree().physics_frame
		n += 1
	assert_true(is_equal_approx(m.local_player.aim_blend, 0.0), "aim_blend fell after release")
	await _tree().physics_frame
	assert_true(is_equal_approx(_look_percent(m, touch), CAMERA_VALUE), "released: Camera value again")
	await _finish(m)


func test_in_match_sensitivity_screen_applies_at_once() -> void:
	_remove_tmp()
	var ctx := await _start_match(SaveService.new(_TMP).load_profile())
	var m: MatchRoot = ctx["match"]
	var touch: TouchProvider = ctx["touch"]
	var panel := m.pause_menu.settings
	var default_pct := m.router.sens.percent("camera", ROW)
	assert_true(is_equal_approx(_look_percent(m, touch), default_pct), "starts at the stored value")
	assert_eq(m._gyro.mode, "off", "gyro starts off")
	panel.open_sensitivity()
	var screen := panel.sensitivity_layer.get_child(0) as SensitivityScreen
	screen.sliders["camera/%s" % ROW].value = 40.0
	assert_true(is_equal_approx(_look_percent(m, touch), 40.0), "slider change measured in the router's look output")
	screen.mode_buttons["scope_on"].pressed.emit()
	assert_eq(m._gyro.mode, "scope_on", "gyro mode re-applied to the provider")
	assert_eq(m.router.sens.gyro_mode, "scope_on", "router settings carry the mode")
	screen.invert_x_button.pressed.emit()
	assert_true(m.router.sens.gyro_invert_x, "inversion re-applied to the router")
	screen.preset_buttons["high"].pressed.emit()
	assert_true(is_equal_approx(_look_percent(m, touch), m.router.sens.percent("camera", ROW)), "preset applied too")
	assert_true(m.router.sens.percent("camera", ROW) != 40.0, "the preset replaced the slider value")
	await _finish(m)


func test_quick_gyro_toggle_in_match_applies_at_once() -> void:
	_remove_tmp()
	var ctx := await _start_match(SaveService.new(_TMP).load_profile())
	var m: MatchRoot = ctx["match"]
	m.pause_menu.settings.gyro_button.pressed.emit()
	assert_eq(m._gyro.mode, "always_on", "toggle applied to the running match")
	assert_true(m._gyro.enabled, "provider enabled")
	await _finish(m)


## OQ-GYRO-TOGGLE: the old single toggle (tests/test_decisions_batch1.gd, tests/test_pause_menu.gd) must agree
## with the Sensitivity settings: off -> always_on -> off, saved in "sensitivity", legacy flag in step.
func test_gyro_toggle_matches_sensitivity_gyro_mode() -> void:
	_remove_tmp()
	var panel: SettingsPanel = _PanelScene.instantiate()
	panel.save = SaveService.new(_TMP)
	_tree().root.add_child(panel)
	var start := SensitivitySettings.from_profile(SaveService.new(_TMP).load_profile())
	assert_eq(start.gyro_mode, "off", "starts off")
	panel.gyro_button.pressed.emit()
	var p := SaveService.new(_TMP).load_profile()
	assert_eq(SensitivitySettings.from_profile(p).gyro_mode, "always_on", "off -> always_on in the sensitivity settings")
	assert_eq(p["sensitivity"]["gyro_mode"], "always_on", "saved profile carries the mode")
	assert_eq(p["gyro_enabled"], true, "legacy flag in step (on)")
	assert_eq(panel.gyro_mode, "always_on", "panel state")
	assert_true(panel.gyro_enabled, "panel legacy value in step (on)")
	panel.gyro_button.pressed.emit()
	p = SaveService.new(_TMP).load_profile()
	assert_eq(SensitivitySettings.from_profile(p).gyro_mode, "off", "always_on -> off")
	assert_eq(p["sensitivity"]["gyro_mode"], "off", "saved profile carries off")
	assert_eq(p["gyro_enabled"], false, "legacy flag in step (off)")
	assert_true(not panel.gyro_enabled, "panel legacy value in step (off)")
	panel.free()
	AppFlow.profile = {}
	_remove_tmp()
