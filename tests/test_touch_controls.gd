extends "res://tests/test_case.gd"

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _LookMath := preload("res://scripts/input/look_math.gd")
const _Router := preload("res://scripts/input/input_router.gd")
const _Gamepad := preload("res://scripts/input/providers/gamepad_provider.gd")


# The headless root viewport is only 64x64, so the HUD is given a realistic size explicitly.
const TEST_SIZE := Vector2(1152, 648)


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _new_hud(mode: String = "stick") -> Control:
	var hud: Control = _HudScene.instantiate()
	_root().add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.cfg["look"]["mode"] = mode
	hud.provider.configure(hud.cfg)
	hud.refresh_visibility()
	_fix_size(hud)
	return hud


func _fix_size(hud: Control) -> void:
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = TEST_SIZE


func _touch(hud: Control, idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	hud._input(e)


func _drag(hud: Control, idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	hud._input(e)


func _cap_per_tick(hud: Control) -> float:
	return deg_to_rad(float(hud.cfg["look"]["max_turn_rate_deg_s"])) / _LookMath.tick_hz()


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame


func _router_for(hud: Control) -> InputRouter:
	var r: InputRouter = _Router.new()
	r.add_provider(hud.provider)
	return r


func test_move_stick_forward_and_release() -> void:
	var hud := _new_hud()
	var r := _router_for(hud)
	var start := Vector2(200, 400)
	_touch(hud, 0, start, true)
	_drag(hud, 0, start + Vector2(0, -80), Vector2(0, -80))
	var mv: Vector2 = r.update_frame().move
	assert_true(mv.y < 0.0, "move forward, got %s" % mv)
	assert_true(mv.length() > 0.0 and mv.length() <= 1.0001, "move length in (0,1], got %s" % mv.length())
	_touch(hud, 0, start + Vector2(0, -80), false)
	assert_eq(r.update_frame().move, Vector2.ZERO, "released")
	r.free()
	hud.free()


func test_move_stick_in_match_moves_pawn() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.begin()
	await _frames(3)
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	_fix_size(hud)
	var before := m.local_player.global_position
	_touch(hud, 0, Vector2(200, 400), true)
	_drag(hud, 0, Vector2(200, 300), Vector2(0, -100))
	await _frames(10)
	var after := m.local_player.global_position
	var d := Vector2(after.x - before.x, after.z - before.z).length()
	assert_true(d > 0.01, "pawn moved horizontally, delta %s" % d)
	_touch(hud, 0, Vector2(200, 300), false)
	m.queue_free()


func test_look_is_capped_in_both_modes() -> void:
	for mode in ["stick", "drag"]:
		var hud := _new_hud(mode)
		var cap := _cap_per_tick(hud)
		var start := Vector2(900, 300)
		_touch(hud, 1, start, true)
		_drag(hud, 1, start + Vector2(10000, 10000), Vector2(10000, 10000))
		var v: Vector2 = hud.provider.get_look()
		assert_true(absf(v.x) <= cap + 1e-6 and absf(v.y) <= cap + 1e-6, "%s capped, got %s cap %s" % [mode, v, cap])
		assert_true(v.x > 0.0 and v.y > 0.0, "%s direction" % mode)
		hud.free()


func test_small_drag_is_small_and_directional() -> void:
	var hud := _new_hud("drag")
	var cap := _cap_per_tick(hud)
	_touch(hud, 1, Vector2(900, 300), true)
	_drag(hud, 1, Vector2(905, 300), Vector2(5, 0))
	var v: Vector2 = hud.provider.get_look()
	assert_true(v.x > 0.0 and v.x < cap and is_zero_approx(v.y), "small right drag, got %s" % v)
	assert_eq(hud.provider.get_look(), Vector2.ZERO, "accumulator consumed")
	hud.free()
	var hud2 := _new_hud("stick")
	var radius: float = hud2._radius()
	_touch(hud2, 1, Vector2(900, 300), true)
	_drag(hud2, 1, Vector2(900 + radius * 0.3, 300), Vector2(radius * 0.3, 0))
	var s: Vector2 = hud2.provider.get_look()
	assert_true(s.x > 0.0 and s.x < cap, "partial stick small, got %s" % s)
	hud2.free()


func test_gamepad_obeys_cap() -> void:
	var cfg := {"look": {"max_turn_rate_deg_s": 90.0, "stick_rate_deg_s": 720.0}}
	var cap := deg_to_rad(90.0) / _LookMath.tick_hz()
	var v := _LookMath.look_from_stick(Vector2(1, -1), cfg, _LookMath.tick_hz())
	assert_true(absf(v.x) <= cap + 1e-9 and absf(v.y) <= cap + 1e-9, "stick math capped, got %s" % v)
	var gp = _Gamepad.new()
	gp.configure(cfg)
	Input.action_press("look_right", 1.0)
	Input.action_press("look_down", 1.0)
	var g: Vector2 = gp.get_look()
	Input.action_release("look_right")
	Input.action_release("look_down")
	assert_true(g.x > 0.0 and g.x <= cap + 1e-9 and g.y <= cap + 1e-9, "gamepad capped, got %s cap %s" % [g, cap])


func test_tap_in_look_zone_pulses_fire() -> void:
	for mode in ["stick", "drag"]:
		var hud := _new_hud(mode)
		_touch(hud, 2, Vector2(900, 300), true)
		_touch(hud, 2, Vector2(900, 300), false)
		assert_true(Input.is_action_pressed("fire"), "%s tap presses fire" % mode)
		hud._process(1.0)
		assert_true(not Input.is_action_pressed("fire"), "%s fire released" % mode)
		hud.free()


func test_look_drag_is_not_a_tap() -> void:
	var hud := _new_hud("drag")
	_touch(hud, 2, Vector2(900, 300), true)
	_drag(hud, 2, Vector2(1000, 300), Vector2(100, 0))
	_touch(hud, 2, Vector2(1000, 300), false)
	assert_true(not Input.is_action_pressed("fire"), "drag does not fire")
	hud.free()


func test_move_touch_never_fires_or_aims() -> void:
	var hud := _new_hud()
	_touch(hud, 0, Vector2(200, 400), true)
	_drag(hud, 0, Vector2(250, 350), Vector2(50, -50))
	assert_true(not Input.is_action_pressed("fire"), "no fire from move stick")
	assert_true(not Input.is_action_pressed("aim"), "no aim from move stick")
	_touch(hud, 0, Vector2(250, 350), false)
	assert_true(not Input.is_action_pressed("fire"), "no fire after release")
	hud.free()


func test_mouse_emulation_off_while_hud_active_and_restored() -> void:
	Input.emulate_mouse_from_touch = true
	var hud := _new_hud()
	assert_true(not Input.emulate_mouse_from_touch, "emulation off while HUD active")
	hud.free()
	assert_true(Input.emulate_mouse_from_touch, "emulation restored after HUD freed")
