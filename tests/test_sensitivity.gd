extends "res://tests/test_case.gd"
## G2d: sensitivity tables, look-state API, gyro modes, inversion, presets, persistence and migration.
## The old single gyro toggle is still pinned by tests/test_decisions_batch1.gd:96-117 and
## tests/test_pause_menu.gd:267-272 (conflict with "replaces the toggle"; those tests are unchanged).

const _TMP := "user://test_profile_sens.json"
const _GYRO_RAW := Vector2(0.25, 0.5)  # FakeGyroPlatform reading as GyroProvider turns it into look


## Test double: pretends the device has a gyro and reports a fixed rate.
class FakeGyroPlatform extends PlatformServices:
	func has_gyro() -> bool:
		return true

	func get_gyro_rate() -> Vector3:
		return Vector3(0.5, 0.25, 0.0)


func _remove_tmp() -> void:
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/input.json")


## Router with a touch provider holding a fixed stick deflection; the base look is measured at 100%.
func _touch_router() -> Array:
	var r := InputRouter.new()
	var t := TouchProvider.new()
	t.configure(_cfg())
	t.look_value = Vector2(0.5, 0.0)
	r.add_provider(t)
	return [r, t]


func _gyro_router(mode: String) -> Array:
	var r := InputRouter.new()
	var g := GyroProvider.new()
	g.configure({"gyro_mode": mode})
	g._platform = FakeGyroPlatform.new()
	r.add_provider(g)
	return [r, g]


func _states() -> Array:
	var out: Array = []
	for k in _cfg()["sensitivity_tables"]["states"]:
		if not str(k).begins_with("_"):
			out.append(str(k))
	return out


func test_tables_and_ranges_in_data() -> void:
	var t: Dictionary = _cfg()["sensitivity_tables"]
	assert_eq(t["scope_rows"], ["tpp_fpp_no_scope", "red_dot", "2x", "4x", "8x", "16x"], "scope rows follow DESIGN.md scopes")
	assert_eq(t["free_look_rows"], ["tpp_character", "fpp_character"], "free look rows, no parachute")
	assert_eq(_states(), ["no_scope", "red_dot", "2x", "4x", "8x", "16x"], "aim states")
	for table in ["gyro", "ads_gyro"]:
		assert_eq(t["ranges"][table]["max"]["value"], 400, "%s max 400" % table)
		assert_true(str(t["ranges"][table]["max"]["_source"]).contains("Patch Notes 1.1"), "%s max sourced" % table)
		assert_true(not t["ranges"][table]["max"].has("_placeholder"), "%s max is not a placeholder" % table)
	for table in ["camera", "ads", "gyro", "ads_gyro", "free_look"]:
		for key in ["min", "default", "step"]:
			assert_eq(t["ranges"][table][key]["_placeholder"], true, "%s %s placeholder" % [table, key])
		if table != "gyro" and table != "ads_gyro":
			assert_eq(t["ranges"][table]["max"]["_placeholder"], true, "%s max placeholder" % table)
	assert_eq(t["presets"]["_placeholder"], true, "presets are placeholders")
	assert_eq(t["default_gyro_mode"]["value"], "off", "default gyro mode off (OQ-34)")


func test_every_camera_and_ads_row_is_applied() -> void:
	for table in ["camera", "ads"]:
		var made := _touch_router()
		var r: InputRouter = made[0]
		var base: float = r.update_frame().look.x
		assert_true(base > 0.0, "base look measured")
		var i := 0
		for state in _states():
			var row: String = r.sens.row_for_state(state)
			i += 1
			r.sens.set_value(table, row, 50.0 + 25.0 * i)
			r.set_ads(table == "ads")
			r.set_aim_state(state)
			var got: float = r.update_frame().look.x
			assert_true(absf(got - base * (50.0 + 25.0 * i) / 100.0) < 0.000001, "%s row %s applied (got %f)" % [table, row, got])
		r.free()


func test_free_look_rows_applied() -> void:
	var made := _touch_router()
	var r: InputRouter = made[0]
	var base: float = r.update_frame().look.x
	var i := 0
	for row in r.sens.rows_of(SensitivitySettings.FREE_LOOK):
		i += 1
		r.sens.set_value(SensitivitySettings.FREE_LOOK, row, 100.0 + 50.0 * i)
		r.set_free_look_row(row)
		assert_true(absf(r.update_frame().look.x - base * (1.0 + 0.5 * i)) < 0.000001, "free look row %s applied" % row)
	r.set_free_look_row("")
	assert_true(absf(r.update_frame().look.x - base) < 0.000001, "no free look row, no scaling")
	r.free()


func test_every_gyro_row_is_applied() -> void:
	for table in ["gyro", "ads_gyro"]:
		var made := _gyro_router("always_on")
		var r: InputRouter = made[0]
		assert_eq(r.update_frame().look, _GYRO_RAW, "gyro base look")
		var i := 0
		for state in _states():
			var row: String = r.sens.row_for_state(state)
			i += 1
			r.sens.set_value(table, row, 50.0 + 30.0 * i)
			r.set_ads(table == "ads_gyro")
			r.set_aim_state(state)
			var got: Vector2 = r.update_frame().look
			assert_true(got.is_equal_approx(_GYRO_RAW * (50.0 + 30.0 * i) / 100.0), "%s row %s applied (got %s)" % [table, row, str(got)])
		r.free()


func test_look_state_api_picks_the_row() -> void:
	var r := InputRouter.new()
	assert_eq(r.aim_state, "no_scope", "starts at no_scope")
	r.set_ads(true)
	r.set_aim_state("4x")
	assert_eq(r.aim_state, "4x", "4x selected")
	r.set_aim_state("nonsense")
	assert_eq(r.aim_state, "no_scope", "unknown state falls back to no_scope")
	r.set_aim_state("8x")
	r.set_ads(false)
	assert_eq(r.aim_state, "no_scope", "leaving ADS resets the state")
	r.sens.set_value("camera", "tpp_fpp_no_scope", 70.0)
	r.sens.set_value("ads", "tpp_fpp_no_scope", 40.0)
	assert_eq(r.look_percent("camera"), 70.0, "camera table while not aiming")
	r.set_ads(true)
	assert_eq(r.look_percent("camera"), 40.0, "ADS table while aiming")
	r.free()


func test_gyro_mode_gating() -> void:
	var expect := {"off": [false, false], "scope_on": [false, true], "always_on": [true, true]}  # [hip, ads]
	for mode in expect:
		var made := _gyro_router(mode)
		var r: InputRouter = made[0]
		r.set_ads(false)
		assert_eq(r.update_frame().look != Vector2.ZERO, expect[mode][0], "%s hip" % mode)
		r.set_ads(true)
		assert_eq(r.update_frame().look != Vector2.ZERO, expect[mode][1], "%s ads" % mode)
		r.free()
	var legacy := _gyro_router("on")
	assert_eq((legacy[1] as GyroProvider).mode, "always_on", "legacy 'on' means always_on")
	(legacy[0] as InputRouter).free()


func test_gyro_inversion() -> void:
	var made := _gyro_router("always_on")
	var r: InputRouter = made[0]
	r.sens.gyro_invert_x = true
	assert_eq(r.update_frame().look, Vector2(-_GYRO_RAW.x, _GYRO_RAW.y), "invert X")
	r.sens.gyro_invert_x = false
	r.sens.gyro_invert_y = true
	assert_eq(r.update_frame().look, Vector2(_GYRO_RAW.x, -_GYRO_RAW.y), "invert Y")
	r.sens.gyro_invert_x = true
	assert_eq(r.update_frame().look, -_GYRO_RAW, "invert both")
	r.free()


func test_gyro_max_400_clamps() -> void:
	var s := SensitivitySettings.new()
	s.set_value("gyro", "red_dot", 1000.0)
	s.set_value("ads_gyro", "2x", 9999.0)
	assert_eq(s.percent("gyro", "red_dot"), 400.0, "gyro clamps to 400")
	assert_eq(s.percent("ads_gyro", "2x"), 400.0, "ads gyro clamps to 400")
	var d := s.to_dict()
	d["values"]["gyro"]["4x"] = 12345
	assert_eq(SensitivitySettings.from_dict(d).percent("gyro", "4x"), 400.0, "a hand-edited file clamps to 400")
	s.set_value("camera", "red_dot", 1000.0)
	assert_eq(s.percent("camera", "red_dot"), s.range_of("camera")["max"], "camera clamps to its own max")


func test_presets_set_every_value_and_edit_switches_to_custom() -> void:
	var s := SensitivitySettings.new()
	var cfg: Dictionary = s.cfg
	for name in ["low", "medium", "high"]:
		assert_true(s.apply_preset(name), "apply %s" % name)
		assert_eq(s.preset, name, "preset name %s" % name)
		for t in s.all_tables():
			for row in s.rows_of(t):
				assert_eq(s.percent(t, row), s.clamp_value(t, float(cfg["presets"][name][t])), "%s %s/%s" % [name, t, row])
	s.set_value("ads", "8x", 77.0)
	assert_eq(s.preset, "custom", "an edit switches to Custom")
	assert_true(not s.apply_preset("nope"), "unknown preset rejected")
	assert_eq(s.preset, "custom", "a rejected preset changes nothing")
	var fresh := SensitivitySettings.new()
	assert_eq(fresh.preset, str(cfg["default_preset"]), "default preset")
	for t in fresh.all_tables():
		for row in fresh.rows_of(t):
			assert_eq(fresh.percent(t, row), fresh.range_of(t)["default"], "default %s/%s" % [t, row])


func test_default_is_gyro_off() -> void:
	_remove_tmp()
	var p := SaveService.new(_TMP).load_profile()
	assert_eq(SensitivitySettings.from_profile(p).gyro_mode, "off", "default gyro mode off")
	assert_eq(p["gyro_enabled"], false, "legacy flag off")


func test_save_load_round_trip() -> void:
	_remove_tmp()
	var svc := SaveService.new(_TMP)
	var s := SensitivitySettings.new()
	s.apply_preset("high")
	s.set_value("gyro", "16x", 250.0)
	s.set_value("free_look", "fpp_character", 33.0)
	s.set_gyro_mode("scope_on")
	s.gyro_invert_x = true
	var p := svc.load_profile()
	p["sensitivity"] = s.to_dict()
	assert_true(svc.save_profile(p), "saved")
	var back := SensitivitySettings.from_profile(SaveService.new(_TMP).load_profile())
	assert_eq(back.to_dict(), s.to_dict(), "round trip")
	assert_eq(back.preset, "custom", "edits kept the Custom preset")
	assert_eq(back.gyro_mode, "scope_on", "mode kept")
	assert_eq(back.percent("gyro", "16x"), 250.0, "gyro row kept")
	assert_eq(SaveService.new(_TMP).load_profile()["gyro_enabled"], true, "legacy flag follows the mode")
	_remove_tmp()


func test_missing_keys_use_data_defaults() -> void:
	var f := FileAccess.open(_TMP, FileAccess.WRITE)
	f.store_string('{"sensitivity": {"values": {"gyro": {"red_dot": 150}}, "preset": "bogus"}}')
	f.close()
	var s := SensitivitySettings.from_profile(SaveService.new(_TMP).load_profile())
	assert_eq(s.percent("gyro", "red_dot"), 150.0, "present key kept")
	assert_eq(s.percent("gyro", "2x"), s.range_of("gyro")["default"], "missing row gets the data default")
	assert_eq(s.gyro_mode, "off", "missing mode is off")
	assert_eq(s.preset, str(s.cfg["default_preset"]), "bad preset name ignored")
	_remove_tmp()


func test_old_gyro_enabled_migration() -> void:
	for pair in [[true, "always_on"], [false, "off"]]:
		var f := FileAccess.open(_TMP, FileAccess.WRITE)
		f.store_string('{"version": 1, "gamertag": "Old", "gyro_enabled": %s}' % str(pair[0]).to_lower())
		f.close()
		var p := SaveService.new(_TMP).load_profile()
		assert_eq(SensitivitySettings.from_profile(p).gyro_mode, pair[1], "gyro_enabled %s maps to %s" % [str(pair[0]), pair[1]])
		assert_eq(p["gamertag"], "Old", "other keys kept")
		assert_eq(p["gyro_enabled"], pair[0], "legacy flag unchanged")
	_remove_tmp()


func test_screen_buttons_sliders_and_persistence() -> void:
	_remove_tmp()
	var screen: SensitivityScreen = load("res://scenes/ui/sensitivity_screen.tscn").instantiate()
	screen.save = SaveService.new(_TMP)
	(Engine.get_main_loop() as SceneTree).root.add_child(screen)
	assert_eq(screen.sliders.size(), 4 * 6 + 2, "26 sliders: four tables of six rows and two free look rows")
	screen.preset_buttons["high"].pressed.emit()
	assert_eq(screen.settings.preset, "high", "preset button")
	assert_eq(screen.sliders["camera/2x"].value, screen.settings.percent("camera", "2x"), "slider follows the preset")
	screen.sliders["gyro/red_dot"].value = 500.0
	assert_eq(screen.sliders["gyro/red_dot"].max_value, 400.0, "gyro slider max 400")
	assert_eq(screen.settings.preset, "custom", "slider edit switches to Custom")
	screen.mode_buttons["scope_on"].pressed.emit()
	screen.invert_y_button.pressed.emit()
	var back := SensitivitySettings.from_profile(SaveService.new(_TMP).load_profile())
	assert_eq(back.gyro_mode, "scope_on", "mode persisted")
	assert_eq(back.gyro_invert_y, true, "inversion persisted")
	assert_eq(back.percent("gyro", "red_dot"), 400.0, "clamped slider value persisted")
	var dp_h := Vector2(0.0, 48.0 * PlatformServices.new().get_dp_scale()).y  # Vector2 stores float32
	assert_true(screen.sliders["camera/red_dot"].custom_minimum_size.y >= dp_h, "slider is at least 48 dp")
	screen.free()
	AppFlow.profile = {}
	_remove_tmp()
