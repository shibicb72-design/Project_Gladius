extends "res://tests/test_case.gd"
## Path A commit 2: optional ADS hold-vs-toggle (tps-demo timing) behind data flag.


func test_aim_toggle_disabled_passthrough() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": false, "aim_hold_threshold_s": 0.4})
	assert_true(t.resolve(true, 0.016), "hold passes through when disabled")
	assert_true(not t.resolve(false, 0.016), "release clears when disabled")


func test_aim_toggle_short_press_latches() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": true, "aim_hold_threshold_s": 0.4})
	assert_true(t.resolve(true, 0.1), "press aims")
	assert_true(t.resolve(false, 0.016), "short release latches aim on")
	assert_true(t.toggled_aim, "toggled_aim set")
	assert_true(t.resolve(false, 0.1), "stays aimed while latched")


func test_aim_toggle_long_hold_does_not_latch() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": true, "aim_hold_threshold_s": 0.4})
	var dt := 0.1
	var elapsed := 0.0
	while elapsed < 0.5:
		assert_true(t.resolve(true, dt), "holding aims")
		elapsed += dt
	assert_true(not t.resolve(false, dt), "long hold release does not latch")
	assert_true(not t.toggled_aim, "not toggled after long hold")


func test_aim_cfg_exposes_toggle_flag_default_off() -> void:
	var cfg := DataRegistry.new().get_aim_cfg()
	assert_true(cfg.has("aim_toggle_enabled"), "aim_toggle_enabled present")
	assert_true(cfg.has("aim_hold_threshold_s"), "aim_hold_threshold_s present")
	assert_eq(bool(cfg["aim_toggle_enabled"]), false, "default off preserves hold-to-aim")
	assert_eq(float(cfg["aim_hold_threshold_s"]), 0.4, "tps-demo 0.4s threshold")
