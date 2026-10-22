extends "res://tests/test_case.gd"
## Move-feel tunables (data/input.json move_feel, data/stats.json movement): each one is injected with a
## non-neutral value through the loaded dictionaries (never by editing data files) and must be read and applied.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _Range := preload("res://scenes/test/weapon_range.tscn")
const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Provider := preload("res://scripts/input/providers/touch_provider.gd")
const DT := 1.0 / 60.0


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _input_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/input.json")


func _provider(feel: Dictionary) -> TouchProvider:
	var cfg := _input_cfg()
	for k in feel:
		cfg["move_feel"][k]["value"] = feel[k]
	var p: TouchProvider = _Provider.new()
	p.configure(cfg)
	return p


func test_response_exponent_is_applied() -> void:
	var p := _provider({"radial_deadzone": 0.0, "response_exponent": 2.0})
	p.move_value = Vector2(0.5, 0.0)
	assert_true(absf(p.get_move().length() - 0.25) < 1e-5, "exponent 2.0 maps length 0.5 to 0.25, got %s" % p.get_move())
	p.move_value = Vector2(0.0, -1.0)
	assert_true(p.get_move().is_equal_approx(Vector2(0.0, -1.0)), "full deflection stays full")


func test_radial_deadzone_uses_length_not_axes() -> void:
	var p := _provider({"radial_deadzone": 0.12, "response_exponent": 1.0})
	p.move_value = Vector2(0.07, 0.07)  # length 0.099
	assert_eq(p.get_move(), Vector2.ZERO, "(0.07,0.07) is inside a 0.12 radial dead zone")
	p.move_value = Vector2(0.1, 0.0)
	assert_eq(p.get_move(), Vector2.ZERO, "(0.1,0) is inside too: same by length")
	p = _provider({"radial_deadzone": 0.09, "response_exponent": 1.0})
	p.move_value = Vector2(0.07, 0.07)
	var diag := p.get_move()
	p.move_value = Vector2(0.1, 0.0)
	var axis := p.get_move()
	assert_true(diag != Vector2.ZERO and axis != Vector2.ZERO, "both outside a 0.09 dead zone")
	assert_true(absf(diag.length() - axis.length()) < 0.01, "same length treated alike: %s vs %s" % [diag.length(), axis.length()])
	assert_true(absf(diag.x - diag.y) < 1e-6, "no diagonal snapping: direction kept, got %s" % diag)
	p.move_value = Vector2(1.0, 0.0)
	assert_true(absf(p.get_move().length() - 1.0) < 1e-5, "the rest is rescaled to reach 1.0")


func test_vjoy_deadzone_and_clampzone_reach_the_joystick() -> void:
	_TouchHud.move_stick_override = "virtual"
	var hud: Control = _HudScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["move_feel"]["vjoy_deadzone_ratio"]["value"] = 0.3
	hud.cfg["move_feel"]["vjoy_clampzone_ratio"]["value"] = 0.7
	hud.rebuild_move_stick()
	var j := hud.move_stick as VirtualJoystick
	assert_true(absf(j.deadzone_ratio - 0.3) < 1e-5, "deadzone_ratio read from data, got %s" % j.deadzone_ratio)
	assert_true(absf(j.clampzone_ratio - 0.7) < 1e-5, "clampzone_ratio read from data, got %s" % j.clampzone_ratio)
	hud.free()


## A pawn on the free lane of the test range, driven by calling _apply_movement directly (no physics await,
## so the tick count is exact).
func _pawn() -> Array:
	var scene: Node3D = _Range.instantiate()
	_tree().root.add_child(scene)
	var p: Pawn = _PawnScene.instantiate()
	scene.add_child(p)
	p.global_position = Vector3(40.0, 0.0, 0.0)
	var f := InputFrame.new()
	p.set_frame(f)
	p._movement = p._movement.duplicate(true)  # tests inject values without touching the shared registry
	await _tree().physics_frame
	return [scene, p, f]


func _speed(p: Pawn) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()


func _run(p: Pawn, n: int) -> float:
	for i in n:
		p._apply_movement(DT)
	return _speed(p)


func test_accel_time_is_applied() -> void:
	var s := await _pawn()
	var p: Pawn = s[1]
	var f: InputFrame = s[2]
	p._movement["ground_accel"]["time_s"] = 0.5
	p.velocity = Vector3.ZERO
	f.move = Vector2(0.0, -1.0)
	var full: float = p.get_move_speed()
	assert_true(absf(_run(p, 15) - full * 0.5) < full * 0.01, "half speed after 15 ticks, got %s" % _speed(p))
	assert_true(absf(_run(p, 15) - full) < full * 0.01, "full speed after 30 ticks at 60 Hz, got %s" % _speed(p))
	p._movement["ground_accel"]["time_s"] = 0.0
	p.velocity = Vector3.ZERO
	assert_true(absf(_run(p, 1) - full) < full * 0.01, "0 means instant")
	s[0].queue_free()


func test_decel_time_is_applied() -> void:
	var s := await _pawn()
	var p: Pawn = s[1]
	var f: InputFrame = s[2]
	p._movement["ground_accel"]["time_s"] = 0.0
	f.move = Vector2(0.0, -1.0)
	var full := _run(p, 1)
	p._movement["ground_decel"]["time_s"] = 0.5
	f.move = Vector2.ZERO
	assert_true(absf(_run(p, 15) - full * 0.5) < full * 0.01, "half speed after 15 decel ticks, got %s" % _speed(p))
	assert_true(_run(p, 15) < full * 0.01, "stopped after 30 ticks, got %s" % _speed(p))
	p._movement["ground_decel"]["time_s"] = 0.0
	f.move = Vector2(0.0, -1.0)
	_run(p, 1)
	f.move = Vector2.ZERO
	assert_eq(_run(p, 1), 0.0, "decel 0 means instant stop")
	s[0].queue_free()


func test_full_analog_speed_and_strafe_ratio_injected() -> void:
	var s := await _pawn()
	var p: Pawn = s[1]
	var f: InputFrame = s[2]
	p._movement["ground_accel"]["time_s"] = 0.0
	var full: float = p.get_move_speed()
	f.move = Vector2(0.0, -0.5)
	assert_true(absf(_run(p, 1) - full * 0.5) < full * 0.01, "half stick = half speed (no walk/run step)")
	p._movement["strafe_back_ratio"]["value"] = 0.5
	f.move = Vector2(1.0, 0.0)
	assert_true(absf(_run(p, 1) - full * 0.5) < full * 0.01, "sideways uses the injected ratio 0.5")
	f.move = Vector2(0.0, 1.0)
	assert_true(absf(_run(p, 1) - full * 0.5) < full * 0.01, "backward uses the injected ratio 0.5")
	f.move = Vector2(0.0, -1.0)
	assert_true(absf(_run(p, 1) - full) < full * 0.01, "forward ignores the ratio")
	s[0].queue_free()


## Shipped data: steady-state strafe and backpedal are 0.889 x forward.
func test_shipped_strafe_and_backpedal_are_0_889_of_forward() -> void:
	var s := await _pawn()
	var p: Pawn = s[1]
	var f: InputFrame = s[2]
	var speeds := {}
	for dir in {"forward": Vector2(0.0, -1.0), "sideways": Vector2(1.0, 0.0), "backward": Vector2(0.0, 1.0)}.keys():
		p.velocity = Vector3.ZERO
		f.move = {"forward": Vector2(0.0, -1.0), "sideways": Vector2(1.0, 0.0), "backward": Vector2(0.0, 1.0)}[dir]
		speeds[dir] = _run(p, 40)
	assert_true(absf(speeds["forward"] - 5.0) < 0.05, "forward walk speed unchanged at 5 m/s, got %s" % speeds["forward"])
	assert_true(absf(speeds["sideways"] - 0.889 * speeds["forward"]) < 0.00889 * speeds["forward"], "strafe 0.889 x forward, got %s" % speeds)
	assert_true(absf(speeds["backward"] - 0.889 * speeds["forward"]) < 0.00889 * speeds["forward"], "backpedal 0.889 x forward, got %s" % speeds)
	s[0].queue_free()


## Shipped data: the forward ramp matches the old single "accel: 40" formula, v[n] = move_toward(v[n-1], target, 40 * dt).
func test_shipped_ramp_matches_old_accel_40_behaviour() -> void:
	var s := await _pawn()
	var p: Pawn = s[1]
	var f: InputFrame = s[2]
	p.velocity = Vector3.ZERO
	f.move = Vector2(0.0, -1.0)
	var old := 0.0
	for n in 12:
		old = move_toward(old, 5.0, 40.0 * DT)
		var v := _run(p, 1)
		assert_true(absf(v - old) <= maxf(0.01 * old, 1e-3), "ramp up tick %d: %s vs old %s" % [n + 1, v, old])
	assert_true(absf(old - 5.0) < 1e-6 and absf(_speed(p) - 5.0) < 0.05, "steady state unchanged")
	f.move = Vector2.ZERO
	for n in 12:
		old = move_toward(old, 0.0, 40.0 * DT)
		var v := _run(p, 1)
		assert_true(absf(v - old) <= maxf(0.01 * old, 1e-3), "ramp down tick %d: %s vs old %s" % [n + 1, v, old])
	assert_eq(_speed(p), 0.0, "stopped")
	s[0].queue_free()


func test_shipped_data_markers() -> void:
	var m: Dictionary = DataRegistry.new().get_movement_cfg()
	assert_eq(m["strafe_back_ratio"]["_source"], "TSG Forge Wiki community tag data: sideways 2 / forward 2.25, backward 2", "ratio _source")
	assert_eq(m["strafe_back_ratio"]["value"], 0.889, "ratio value")
	assert_true(not m["strafe_back_ratio"].has("_placeholder"), "ratio is not a placeholder")
	for k in ["ground_accel", "ground_decel"]:
		assert_eq(m[k]["_placeholder"], true, k + " _placeholder")
	assert_true(absf(float(m["ground_accel"]["time_s"]) - 5.0 / 40.0) < 1e-9, "accel time = 5.0 / 40.0")
	assert_true(absf(float(m["ground_decel"]["time_s"]) - 5.0 / 40.0) < 1e-9, "decel time = 5.0 / 40.0")
	var feel: Dictionary = _input_cfg()["move_feel"]
	for k in ["vjoy_deadzone_ratio", "vjoy_clampzone_ratio", "radial_deadzone", "response_exponent"]:
		assert_eq(feel[k]["_placeholder"], true, k + " _placeholder")
	assert_eq(feel["response_exponent"]["value"], 1.0, "neutral exponent")
	assert_eq(feel["vjoy_clampzone_ratio"]["value"], 1.0, "neutral clamp")
	assert_eq(feel["vjoy_deadzone_ratio"]["value"], 0.0, "engine-default deadzone_ratio")
