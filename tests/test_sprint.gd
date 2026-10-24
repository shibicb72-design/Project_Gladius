extends "res://tests/test_case.gd"
## Sprint (G2c, Shibi Oct 22 2026; G3a2, Oct 23 2026: no hold, sprint starts on the threshold): smooth speed ramp,
## sprint lock, sensitivity.
## The trigger is driven like tests/test_physics_baseline.gd: TouchProvider -> InputRouter -> InputFrame -> Pawn
## (the pawn's _apply_movement is called directly, so the tick count is exact). The lock is driven through
## TouchHud touch events.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _Range := preload("res://scenes/test/weapon_range.tscn")
const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _GameHudScene := preload("res://scenes/ui/hud.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const DT := 1.0 / 60.0
const TEST_SIZE := Vector2(1152, 648)
const PROFILE_PATH := "user://test_sprint_profile.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _input_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/input.json")


func _move_cfg() -> Dictionary:
	return DataRegistry.new().get_movement_cfg()


func _provider(sens: float = -1.0) -> TouchProvider:
	var tp := TouchProvider.new()
	tp.configure(_input_cfg())
	tp.shape_move = false  # exact stick lengths; the shaping path is covered by the HUD tests below
	if sens >= 0.0:
		tp.set_sprint_sensitivity(sens)
	return tp


func _pawn() -> Array:
	var scene: Node3D = _Range.instantiate()
	_tree().root.add_child(scene)
	var p: Pawn = _PawnScene.instantiate()
	scene.add_child(p)
	p.global_position = Vector3(40.0, 0.0, 0.0)
	p.set_frame(InputFrame.new())
	p._movement = p._movement.duplicate(true)
	await _tree().physics_frame
	return [scene, p]


func _speed(p: Pawn) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()


## Runs provider -> router -> frame -> pawn for n ticks with a constant stick value; appends to rec.
func _sim(p: Pawn, tp: TouchProvider, r: InputRouter, move: Vector2, n: int, rec: Dictionary) -> void:
	for i in n:
		tp.move_value = move
		var fr := r.update_frame(DT)
		p.set_frame(fr)
		p._apply_movement(DT)
		rec["speed"].append(_speed(p))
		rec["factor"].append(p.sprint_factor)
		rec["sprint"].append(fr.sprint)


func _rec() -> Dictionary:
	return {"speed": [], "factor": [], "sprint": []}


func _rig(sens: float = -1.0) -> Array:
	var s := await _pawn()
	var tp := _provider(sens)
	var r := InputRouter.new()
	r.add_provider(tp)
	return [s[0], s[1], tp, r]


func _run_speed(p: Pawn) -> float:
	return p.get_move_speed()


func _step_bound(p: Pawn) -> float:
	var m: Dictionary = p._movement
	var run := _run_speed(p)
	return (run * float(m["sprint_speed_multiplier"]["value"]) - run) / (float(m["sprint_ramp_s"]["value"]) * 60.0) * 1.01


func _first_sprint_tick(rec: Dictionary) -> int:
	for i in rec["sprint"].size():
		if rec["sprint"][i]:
			return i + 1
	return -1


func _free(rig: Array) -> void:
	rig[3].free()
	rig[0].queue_free()


# ---------------------------------------------------------------- trigger and ramp

func test_sprint_starts_on_the_threshold() -> void:
	var g := await _rig()
	var p: Pawn = g[1]
	var rec := _rec()
	_sim(p, g[2], g[3], Vector2(0.0, -1.0), 1, rec)
	assert_eq(_first_sprint_tick(rec), 1, "sprint requested on the first tick past the threshold")
	assert_true(not _move_cfg().has("sprint_hold_s"), "no sprint_hold_s in data")
	_free(g)


func test_entry_ramp_is_smooth_and_reaches_sprint_speed() -> void:
	var g := await _rig()
	var p: Pawn = g[1]
	var rec := _rec()
	_sim(p, g[2], g[3], Vector2(0.0, -1.0), 30 + 80, rec)
	var bound := _step_bound(p)
	var worst := 0.0
	for i in range(15, rec["speed"].size()):
		var d: float = rec["speed"][i] - rec["speed"][i - 1]
		assert_true(d >= -1e-4, "entry non-decreasing at tick %d (%s)" % [i, d])
		worst = maxf(worst, d)
	assert_true(worst <= bound, "entry step %s <= bound %s" % [worst, bound])
	var target := _run_speed(p) * float(_move_cfg()["sprint_speed_multiplier"]["value"])
	assert_true(absf(_speed(p) - target) / target < 0.01, "reaches run x multiplier (%s vs %s)" % [_speed(p), target])
	_free(g)


## Exit by release, by dropping below the threshold, and by leaving the cone: the sprint factor eases back to 1.
func test_exit_ramps_down_without_a_step() -> void:
	var cone := float(_input_cfg()["sprint"]["forward_cone_half_angle_deg"]["value"])
	var out_of_cone := Vector2(sin(deg_to_rad(cone + 20.0)), -cos(deg_to_rad(cone + 20.0)))
	var thr := float(_input_cfg()["sprint"]["threshold_at_sensitivity_0"]["value"])
	var cases := {"release": Vector2.ZERO, "below threshold": Vector2(0.0, -(thr * 0.5)), "out of cone": out_of_cone}
	for name in cases:
		var g := await _rig()
		var p: Pawn = g[1]
		var rec := _rec()
		_sim(p, g[2], g[3], Vector2(0.0, -1.0), 30 + 80, rec)
		var rec2 := _rec()
		_sim(p, g[2], g[3], cases[name], 90, rec2)
		var run := _run_speed(p)
		var prev: float = rec["factor"][rec["factor"].size() - 1] * run
		var bound := _step_bound(p)
		for f in rec2["factor"]:
			var v: float = f * run
			assert_true(v <= prev + 1e-9, "%s: non-increasing (%s -> %s)" % [name, prev, v])
			assert_true(prev - v <= bound, "%s: step %s <= %s" % [name, prev - v, bound])
			prev = v
		assert_true(absf(p.sprint_factor - 1.0) < 1e-6, "%s: back to run speed, factor %s" % [name, p.sprint_factor])
		assert_true(not rec2["sprint"].has(true), "%s: no sprint request" % name)
		_free(g)


func test_outside_cone_or_below_threshold_never_sprints() -> void:
	var thr := float(_input_cfg()["sprint"]["threshold_at_sensitivity_0"]["value"])
	for v in [Vector2(0.7071, -0.7071), Vector2(0.0, -(thr - 0.05)), Vector2(1.0, 0.0), Vector2(0.0, 1.0)]:
		var g := await _rig(0.0)  # sensitivity 0: the strictest threshold
		var rec := _rec()
		_sim(g[1], g[2], g[3], v, 180, rec)
		assert_true(not rec["sprint"].has(true), "%s never sprints in 3 s" % v)
		assert_true(g[1].sprint_factor == 1.0, "%s keeps run speed" % v)
		_free(g)


func test_leaving_the_threshold_stops_and_returning_restarts_at_once() -> void:
	var g := await _rig()
	var rec := _rec()
	_sim(g[1], g[2], g[3], Vector2(0.0, -1.0), 24, rec)
	assert_true(rec["sprint"][23], "sprint true past the threshold")
	var rec2 := _rec()
	_sim(g[1], g[2], g[3], Vector2.ZERO, 1, rec2)
	assert_true(not rec2["sprint"][0], "sprint false on the tick the stick leaves")
	var rec3 := _rec()
	_sim(g[1], g[2], g[3], Vector2(0.0, -1.0), 1, rec3)
	assert_true(rec3["sprint"][0], "sprint true again on the first tick back")
	_free(g)


# ---------------------------------------------------------------- data

func test_sprint_data_markers() -> void:
	var m := _move_cfg()
	assert_true(not m.has("sprint_hold_s"), "sprint_hold_s removed (no hold, G3a2)")
	assert_eq(m["sprint_speed_multiplier"]["value"], 1.34, "multiplier")
	assert_eq(m["sprint_speed_multiplier"]["note"], "our placeholder starting value, no sourced number", "multiplier note")
	assert_true(not m.has("sprint_speed_mult"), "exactly one multiplier key")
	assert_true(not m["sprint_speed_multiplier"].has("_source"), "multiplier cites no source")
	assert_eq(m["sprint_speed_multiplier"]["_placeholder"], true, "multiplier _placeholder")
	assert_eq(m["sprint_ramp_s"]["_placeholder"], true, "sprint_ramp_s _placeholder")
	assert_eq(m["base_speed_mps"], 4.7, "run speed 4.7 (MEASURED (PC), community sources pubg.fandom.com/wiki/Movement_Speed and samurai-gamers)")
	assert_eq(m["_placeholder"], true, "movement stays a placeholder")
	assert_eq(m["base_speed_note"], "Shibi Oct 22 asked for +5-10%; +7.5% chosen (5.0 x 1.075). base_speed_mps stays a placeholder.", "walk note")
	var sp: Dictionary = _input_cfg()["sprint"]
	for k in ["threshold_at_sensitivity_0", "threshold_at_sensitivity_100", "forward_cone_half_angle_deg", "lock_target", "lock_button"]:
		assert_eq(sp[k]["_placeholder"], true, k + " _placeholder")
	var s: Dictionary = _input_cfg()["sprint_sensitivity"]
	assert_eq([float(s["min"]), float(s["max"]), float(s["default"]), float(s["step"])], [0.0, 100.0, 50.0, 5.0], "sensitivity range")
	assert_eq(s["_source"], "HT Tech report of BGMI 1.6 notes, single unofficial source; Shibi chose it as the starting point Oct 22 2026", "sensitivity _source")
	assert_true(not s.has("_placeholder"), "sensitivity is not a placeholder")


func test_walk_speed_and_accel_rate() -> void:
	var g := await _rig()
	var p: Pawn = g[1]
	var wf := InputFrame.new()
	wf.move = Vector2(0.0, -1.0)
	wf.sprint = false  # the provider would sprint on tick 1, so walk speed is measured with sprint forced off
	p.set_frame(wf)
	for i in 25:
		p._apply_movement(DT)
	assert_true(absf(_speed(p) - 4.7) / 4.7 < 0.01, "walk speed 4.7 within 1%%, got %s" % _speed(p))
	_free(g)
	var s := await _pawn()
	var q: Pawn = s[1]
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)
	q.set_frame(f)
	var prev := 0.0
	for i in 5:
		q._apply_movement(DT)
		var gain := _speed(q) - prev
		assert_true(absf(gain - 40.0 / 60.0) / (40.0 / 60.0) < 0.01, "accel tick %d gains %s (40/60)" % [i, gain])
		prev = _speed(q)
	s[0].queue_free()


# ---------------------------------------------------------------- sensitivity

func _min_sprint_length(sens: float) -> float:
	var d := SprintDetector.new()
	d.configure(_move_cfg(), _input_cfg()["sprint"], _input_cfg()["sprint_sensitivity"])
	d.sensitivity = sens
	var l := 0.0
	while l <= 1.0001:
		if d.at_forward_extreme(Vector2(0.0, -l)):
			return l
		l += 0.005
	return 2.0


func test_higher_sensitivity_needs_a_shorter_push_but_same_speed() -> void:
	var l0 := _min_sprint_length(0.0)
	var l50 := _min_sprint_length(50.0)
	var l100 := _min_sprint_length(100.0)
	assert_true(l0 > l50 and l50 > l100, "push length shrinks with sensitivity: %s %s %s" % [l0, l50, l100])
	var finals: Array[float] = []
	for sens in [0.0, 50.0, 100.0]:
		var g := await _rig(sens)
		var rec := _rec()
		_sim(g[1], g[2], g[3], Vector2(0.0, -1.0), 30 + 80, rec)
		finals.append(_speed(g[1]))
		assert_eq(_first_sprint_tick(rec), 1, "sprint starts on the first tick at sens %s" % sens)
		_free(g)
	assert_true(absf(finals[0] - finals[1]) < 1e-3 and absf(finals[1] - finals[2]) < 1e-3, "sprint speed unchanged: %s" % [finals])


func test_sensitivity_default_step_clamp() -> void:
	var s: Dictionary = _input_cfg()["sprint_sensitivity"]
	assert_eq(_provider().detector.sensitivity, 50.0, "default 50")
	assert_eq(SprintDetector.snap_sensitivity(52.0, s), 50.0, "52 -> 50")
	assert_eq(SprintDetector.snap_sensitivity(53.0, s), 55.0, "53 -> 55")
	assert_eq(SprintDetector.snap_sensitivity(-20.0, s), 0.0, "clamp 0")
	assert_eq(SprintDetector.snap_sensitivity(250.0, s), 100.0, "clamp 100")


func test_sensitivity_profile_round_trip() -> void:
	var save := SaveService.new(PROFILE_PATH)
	var prof := SaveService.defaults()
	assert_eq(prof["sprint_sensitivity"], 50, "profile default is the data default")
	prof["sprint_sensitivity"] = 75.0
	prof["sprint_lock_pos"] = [0.25, 0.5]
	assert_true(save.save_profile(prof), "saved")
	var back := save.load_profile()
	assert_eq(back["sprint_sensitivity"], 75.0, "slider round trip")
	assert_eq(back["sprint_lock_pos"], [0.25, 0.5], "lock button position round trip")
	prof["sprint_sensitivity"] = 53.0
	save.save_profile(prof)
	assert_eq(save.load_profile()["sprint_sensitivity"], 55.0, "saved value snaps to the step")
	prof["sprint_sensitivity"] = 900.0
	save.save_profile(prof)
	assert_eq(save.load_profile()["sprint_sensitivity"], 100.0, "saved value clamps")


func test_settings_slider_saves_to_profile() -> void:
	var old_profile: Dictionary = AppFlow.profile
	var menu := MainMenu.new()
	menu.save = SaveService.new(PROFILE_PATH)
	_tree().root.add_child(menu)
	assert_eq(menu.sprint_slider.step, 5.0, "slider step from data")
	assert_eq([menu.sprint_slider.min_value, menu.sprint_slider.max_value], [0.0, 100.0], "slider range from data")
	menu.sprint_slider.value = 85.0
	assert_eq(menu.save.load_profile()["sprint_sensitivity"], 85.0, "slider value saved in the profile")
	assert_eq(AppFlow.profile["sprint_sensitivity"], 85.0, "AppFlow profile updated")
	menu.free()
	AppFlow.profile = old_profile


# ---------------------------------------------------------------- lock (GUI path)

func _hud(mode: String, layout: String = "floating") -> Control:
	_TouchHud.move_stick_override = mode
	var hud: Control = _HudScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.cfg["touch_layout"]["vjoy_layout"] = layout
	hud.refresh_visibility()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = TEST_SIZE
	hud.rebuild_move_stick()
	return hud


func _touch(hud: Control, idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	hud._input(e)


func _drag(hud: Control, idx: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	hud._input(e)


## The virtual stick's value comes from the VirtualJoystick actions in _process; the test feeds it directly.
func _push(hud: Control, mode: String, idx: int, to: Vector2, deflection: Vector2) -> void:
	_drag(hud, idx, to)
	if mode == "virtual":
		hud.provider.move_value = deflection


func _modes() -> Array:
	return [["custom", "floating"], ["virtual", "floating"], ["virtual", "fixed"]]


func _start(hud: Control, mode: String, layout: String) -> Vector2:
	return hud.get_move_rest() if layout == "fixed" and mode == "virtual" else Vector2(200, 400)


func test_release_on_target_locks_release_elsewhere_stops() -> void:
	for m in _modes():
		var mode: String = m[0]
		var layout: String = m[1]
		var tag := "%s/%s" % [mode, layout]
		var hud := _hud(mode, layout)
		var r := InputRouter.new()
		r.add_provider(hud.provider)
		var start := _start(hud, mode, layout)
		var rad: float = hud._radius()
		# Past the threshold: sprint on the first tick, no hold, in every move-stick mode.
		_touch(hud, 0, start, true)
		_push(hud, mode, 0, start + Vector2(0.0, -rad), Vector2(0.0, -1.0))
		var fr: InputFrame = r.update_frame(DT)
		assert_true(fr.sprint, tag + ": sprint on the first tick past the threshold")
		assert_true(hud.provider.lock_target_visible(), tag + ": lock target shown past the trigger")
		# Release elsewhere (short of the target): movement stops.
		_push(hud, mode, 0, start + Vector2(0.0, -rad * 0.95), Vector2(0.0, -0.95))
		_touch(hud, 0, start + Vector2(0.0, -rad * 0.95), false)
		fr = r.update_frame(DT)
		assert_true(not hud.provider.sprint_locked and fr.move == Vector2.ZERO and not fr.sprint, tag + ": release elsewhere stops")
		# Release on the target: locks forward sprint with no finger down.
		_touch(hud, 0, start, true)
		_push(hud, mode, 0, start + Vector2(0.0, -rad), Vector2(0.0, -1.0))
		var target: Rect2 = hud.get_lock_target_rect()
		assert_true(target.size.x / PlatformServices.new().get_dp_scale() >= 48.0 - 1e-3, tag + ": target >= 48 dp")
		_push(hud, mode, 0, target.get_center(), Vector2(0.0, -1.0))
		_touch(hud, 0, target.get_center(), false)
		fr = r.update_frame(DT)
		assert_true(hud.provider.sprint_locked, tag + ": release on target locks")
		assert_true(fr.sprint and fr.move == Vector2(0.0, -1.0), tag + ": locked = forward sprint, %s" % fr.move)
		# Look still works while locked.
		_touch(hud, 2, Vector2(900, 300), true)
		_drag(hud, 2, Vector2(960, 300))
		assert_true(hud.provider.look_value.x > 0.0 and hud.provider.sprint_locked, tag + ": look works while locked")
		_touch(hud, 2, Vector2(960, 300), false)
		# A new move-stick touch cancels the lock.
		_touch(hud, 3, start, true)
		assert_true(not hud.provider.sprint_locked, tag + ": new move touch cancels the lock")
		_touch(hud, 3, start, false)
		r.free()
		hud.free()
	_TouchHud.move_stick_override = ""


func test_lock_button_locks_without_holding_and_cancels() -> void:
	for m in _modes():
		var mode: String = m[0]
		var layout: String = m[1]
		var tag := "%s/%s" % [mode, layout]
		var hud := _hud(mode, layout)
		var r := InputRouter.new()
		r.add_provider(hud.provider)
		var btn: Vector2 = hud.get_lock_button_rect().get_center()
		_touch(hud, 1, btn, true)  # not moving: nothing to lock
		_touch(hud, 1, btn, false)
		assert_true(not hud.provider.sprint_locked, tag + ": button does nothing while standing still")
		var start := _start(hud, mode, layout)
		_touch(hud, 0, start, true)
		_push(hud, mode, 0, start + Vector2(0.0, -hud._radius() * 0.5), Vector2(0.0, -0.5))
		_touch(hud, 1, btn, true)  # tap with the other thumb while moving forward
		_touch(hud, 1, btn, false)
		assert_true(hud.provider.sprint_locked, tag + ": tap while moving forward locks")
		_touch(hud, 0, start, false)  # finger up: still locked
		var fr := r.update_frame(DT)
		assert_true(fr.sprint and fr.move == Vector2(0.0, -1.0), tag + ": locked without holding")
		_touch(hud, 1, btn, true)
		_touch(hud, 1, btn, false)
		assert_true(not hud.provider.sprint_locked, tag + ": tap while locked cancels")
		assert_true(r.update_frame(DT).move == Vector2.ZERO, tag + ": stopped after cancel")
		r.free()
		hud.free()
	_TouchHud.move_stick_override = ""


## The locked pawn keeps sprint speed, and cancelling eases down (no step).
func test_locked_pawn_holds_sprint_speed_then_eases_down() -> void:
	var g := await _rig()
	var p: Pawn = g[1]
	var tp: TouchProvider = g[2]
	tp.move_value = Vector2(0.0, -0.5)
	tp.toggle_sprint_lock()
	assert_true(tp.sprint_locked, "locked")
	var rec := _rec()
	_sim(p, tp, g[3], Vector2.ZERO, 120, rec)
	var target := _run_speed(p) * float(_move_cfg()["sprint_speed_multiplier"]["value"])
	assert_true(absf(_speed(p) - target) / target < 0.01, "locked pawn at sprint speed, got %s" % _speed(p))
	tp.cancel_sprint_lock()
	var rec2 := _rec()
	_sim(p, tp, g[3], Vector2.ZERO, 90, rec2)
	var prev: float = rec["factor"][rec["factor"].size() - 1]
	var step := (float(_move_cfg()["sprint_speed_multiplier"]["value"]) - 1.0) / (float(_move_cfg()["sprint_ramp_s"]["value"]) * 60.0) * 1.01
	for f in rec2["factor"]:
		assert_true(f <= prev + 1e-9 and prev - f <= step, "ease down without a step (%s -> %s)" % [prev, f])
		prev = f
	assert_true(absf(prev - 1.0) < 1e-6, "back to run speed")
	_free(g)


# ---------------------------------------------------------------- layout

func _check_lock_layout(sz: Vector2) -> void:
	_TouchHud.move_stick_override = "custom"
	var touch := _hud("custom")
	touch.size = sz
	touch.relayout()
	var game: GameHud = _GameHudScene.instantiate()
	_tree().root.add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	game.scores_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.timer_label.text = "10:00"
	game.hill_label.text = "Hill: contested"
	game.weapon_label.text = "Gladius Rifle"
	game.ammo_label.text = "120 / 360"
	await _tree().process_frame
	await _tree().process_frame
	var hud_items := {
		"shield_bar": game.shield_bar, "health_bar": game.health_bar, "weapon_label": game.weapon_label,
		"ammo_label": game.ammo_label, "scores_label": game.scores_label, "timer_label": game.timer_label,
		"hill_label": game.hill_label}
	var others := {"move_stick": touch.move_stick.get_global_rect(), "look_stick": touch.look_stick.get_global_rect()}
	for action in touch.get_button_actions():
		others["button_" + action] = touch.get_button_rect(action)
	var mine := {"lock_button": touch.get_lock_button_rect(), "lock_target_at_rest": touch.get_lock_target_rect()}
	var view := Rect2(Vector2.ZERO, sz)
	var dp := PlatformServices.new().get_dp_scale()
	for mname in mine:
		var rect: Rect2 = mine[mname]
		assert_true(rect.size.x / dp >= 48.0 - 1e-3 and rect.size.y / dp >= 48.0 - 1e-3, "%s >= 48 dp at %s" % [mname, sz])
		assert_true(view.encloses(rect), "%s inside the viewport at %s, got %s" % [mname, sz, rect])
		for hname in hud_items:
			assert_true(not rect.intersects(hud_items[hname].get_global_rect()), "%s overlaps %s at %s" % [mname, hname, sz])
		for oname in others:
			assert_true(not rect.intersects(others[oname]), "%s overlaps %s at %s" % [mname, oname, sz])
	game.free()
	touch.free()
	_TouchHud.move_stick_override = ""


func test_lock_button_clear_of_hud_at_four_sizes() -> void:
	for sz in [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]:
		await _check_lock_layout(sz)


## A whole tap on the stick (down, then up, no drag) cancels the lock and leaves the player stopped.
func test_tap_on_stick_cancels_lock_and_stops() -> void:
	for m in _modes():
		var mode: String = m[0]
		var layout: String = m[1]
		var tag := "%s/%s" % [mode, layout]
		var hud := _hud(mode, layout)
		var r := InputRouter.new()
		r.add_provider(hud.provider)
		var start := _start(hud, mode, layout)
		var rad: float = hud._radius()
		_touch(hud, 0, start, true)
		_push(hud, mode, 0, start + Vector2(0.0, -rad), Vector2(0.0, -1.0))
		var target: Rect2 = hud.get_lock_target_rect()
		_push(hud, mode, 0, target.get_center(), Vector2(0.0, -1.0))
		_touch(hud, 0, target.get_center(), false)
		var fr := r.update_frame(DT)
		assert_true(hud.provider.sprint_locked, tag + ": release on target locks")
		# Tap: down and up at the stick start, no drag.
		_touch(hud, 1, start, true)
		_touch(hud, 1, start, false)
		assert_true(not hud.provider.sprint_locked, tag + ": tap cancels the lock")
		fr = r.update_frame(DT)
		assert_true(fr.move == Vector2.ZERO and not fr.sprint, tag + ": stopped after the tap, move %s" % fr.move)
		r.free()
		hud.free()
	_TouchHud.move_stick_override = ""
