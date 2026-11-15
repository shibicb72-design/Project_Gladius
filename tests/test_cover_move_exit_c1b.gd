extends "res://tests/test_case.gd"
## M2 C1b stage 3: moving and exiting in cover (decision 8, fixes 3, 11, 14, 19, 24, 25, 26, 28). The stick is mapped
## through the camera yaw; its along-wall part slides (clamped at the wall's ends), its outward wall-normal part held
## cover.json exit_away_hold_s exits, the into-wall part does nothing. Exits: the away push, the Cover button, the
## Sprint lock (never a hard stick push), Jump, and a wall that vanishes; all through EXITING. Every input lock is at
## most input_lock_max_s. All numbers are OQ-COVER placeholders in data/cover.json.
## Pawn-level tests follow tests/test_cover_camera_c1b.gd (manual pawn ticks, the rig on real physics frames); the
## touch-button tests follow tests/test_cover_fire_fix.gd (real match, live physics, viewport touches).

const DT := 1.0 / 60.0
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig
var _wall: StaticBody3D


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")


func _ticks(seconds: float) -> int:
	return ceili(seconds / DT - 0.0001)


func _fp(key: String) -> float:
	return float(DataRegistry.new().get_camera_cfg()["first_person"][key]["value"])


# ---- pure controller ---------------------------------------------------------------------------

## Facts as CoverProbe.sample returns them for a wall face on z = 0 (normal +z), 4 m wide, 2.2 m tall.
func _probe(at: Vector3 = Vector3(0, 0, 0.6), basis: Basis = Basis.IDENTITY) -> Dictionary:
	return {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": at, "basis": basis,
		"distance_m": at.z, "left_m": at.x + 2.0, "right_m": 2.0 - at.x, "height_m": 2.2, "slide_speed_mps": 4.1783,
		"shot_clear": true, "stand_clear": true}


func _push_until_snap(c: CoverController, max_ticks: int, sprint := false) -> int:
	for i in max_ticks:
		c.tick(DT, Vector2(0, -1), false, _probe(), false, sprint)
		if c.state != CoverController.State.FREE:
			return i + 1
	return -1


func _enter_by_button(c: CoverController) -> void:
	assert_true(c.request_cover(_probe()), "enters by the Cover button")
	for i in _ticks(c.enter_duration()) + 1:
		c.tick(DT, Vector2.ZERO, false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "settled in cover")


func test_new_data_keys_and_every_lock_respects_the_cap() -> void:
	var cfg := _cfg()
	var cap := float(cfg["input_lock_max_s"])
	assert_true(bool(cfg["_placeholder"]), "cover.json is placeholder data")
	var note := str(cfg["_c1b_stage3_todo"])
	for key in ["OQ-COVER", "exit_away_hold_s", "back_exit_min", "exit_s", "auto_snap_blocked_by_sprint"]:
		assert_true(note.contains(key), "the stage 3 OQ-COVER note names %s" % key)
	assert_eq(float(cfg["exit_away_hold_s"]), 0.15, "shipped away-hold placeholder")
	assert_eq(float(cfg["exit_s"]), 0.15, "shipped exit placeholder")
	assert_eq(bool(cfg["auto_snap_blocked_by_sprint"]), true, "shipped switch: the spec default")
	for dead in ["peek_stick_min", "exit_stick_min", "exit_hold_s"]:
		assert_true(not cfg.has(dead), "the stick-peek key %s is gone" % dead)
	var c := CoverController.new(cfg)
	var locks := c.lock_durations()
	# M2 C1b stage 4: peek_s is no longer an input lock (it only sets the CoverAnim peek clip length); was >= 5.
	assert_true(locks.size() >= 4, "every lock span is listed")
	for key in locks:
		assert_true(float(locks[key]) <= cap + 0.000001, "lock %s = %s s <= input_lock_max_s %s" % [key, locks[key], cap])
	var over := _cfg()
	over["exit_s"] = 0.5
	over["enter_s"] = 0.5
	var capped := CoverController.new(over)
	assert_eq(capped.exit_duration(), cap, "a longer exit_s is capped")
	assert_eq(capped.enter_duration(), cap, "a longer enter_s is capped")
	# EXITING lasts exactly exit_duration() from data.
	_enter_by_button(c)
	assert_true(c.request_cover({}), "the Cover press begins the exit")
	var n := 0
	while c.state == CoverController.State.EXITING and n < 120:
		c.tick(DT, Vector2.ZERO, false, _probe(Vector3(0, 0, 0.45)))
		n += 1
	assert_eq(n, _ticks(c.exit_duration()), "EXITING lasted %d ticks" % n)


func test_away_push_needs_the_hold_and_sub_threshold_does_nothing() -> void:
	var c := CoverController.new(_cfg())
	_enter_by_button(c)
	var hold := _ticks(float(c.config["exit_away_hold_s"]))
	assert_true(hold > 1, "fixture: the hold spans several ticks")
	for attempt in 2:
		for i in hold - 1:
			c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
		assert_eq(c.state, CoverController.State.IN_COVER, "a push shorter than exit_away_hold_s stays (attempt %d)" % attempt)
		c.tick(DT, Vector2.ZERO, false, _probe(Vector3(0, 0, 0.45)))  # released: the hold restarts
	var below := float(c.config["back_exit_min"]) - 0.1
	for i in 60:
		c.tick(DT, Vector2(0, below), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "an away push below back_exit_min never exits")
	for i in hold - 1:
		c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "still in cover one tick before the hold")
	c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.EXITING, "the held away push exits after exactly exit_away_hold_s")


func test_reentry_cooldown_starts_at_free_after_each_exit() -> void:
	var cooldown_ticks := _ticks(float(_cfg()["reentry_cooldown_s"]))
	var hold_ticks := _ticks(float(_cfg()["snap_hold_s"]))
	for kind in ["stick", "cover_button", "jump_or_sprint_lock", "wall_gone"]:
		var c := CoverController.new(_cfg())
		_enter_by_button(c)
		match kind:
			"stick":
				for i in _ticks(float(c.config["exit_away_hold_s"])):
					c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
			"cover_button":
				c.request_cover({})
			"jump_or_sprint_lock":
				assert_true(c.request_exit(), "Pawn's Jump / Sprint lock exit")
			"wall_gone":
				var gone := _probe(Vector3(0, 0, 0.45))
				gone["hit"] = false
				gone["wall_gone"] = true
				c.tick(DT, Vector2.ZERO, false, gone)
		assert_eq(c.state, CoverController.State.EXITING, "%s: through EXITING" % kind)
		var n := 0
		while c.state != CoverController.State.FREE and n < 60:
			var p := _probe(Vector3(0, 0, 0.45))
			if kind == "wall_gone":
				p["hit"] = false
			c.tick(DT, Vector2.ZERO, false, p)
			n += 1
		assert_eq(c.state, CoverController.State.FREE, "%s: reaches FREE" % kind)
		assert_true(absf(c._cooldown_left - float(c.config["reentry_cooldown_s"])) < 0.000001, "%s: the cooldown starts when FREE is reached" % kind)
		var snap := _push_until_snap(c, cooldown_ticks + hold_ticks + 5)
		assert_true(snap > cooldown_ticks and snap <= cooldown_ticks + hold_ticks + 1, "%s: auto-snap only after the cooldown (took %d)" % [kind, snap])


func test_auto_snap_blocked_by_sprint_switch() -> void:
	for blocked in [true, false]:
		var cfg := _cfg()
		cfg["auto_snap_blocked_by_sprint"] = blocked
		var c := CoverController.new(cfg)
		var n := _push_until_snap(c, 120, true)
		if blocked:
			assert_eq(n, -1, "true: a sprinting (full) push into the wall never auto-snaps")
		else:
			assert_eq(n, _ticks(float(cfg["snap_hold_s"])), "false: a sprinting push snaps after the usual hold")
		var button := CoverController.new(cfg)
		assert_true(button.request_cover(_probe()), "the Cover button works either way (blocked=%s)" % blocked)


# ---- the real pawn and wall, the cover camera looking along the wall ------------------------------

## Floor, a 4 m wall whose face is on z = 0 (normal +z, tangent +x, ends at x = -2 and 2) and the local pawn with
## its rig at `at`, facing the wall. Enters by the Cover button and lets the automatic turn finish: the view then looks
## ALONG the wall toward CoverController.side.
func _fixture(at: Vector3 = Vector3(0, 0, 0.6)) -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	_root.add_child(floor_body)
	_wall = StaticBody3D.new()
	_wall.add_to_group(&"cover_wall")
	_wall.position = Vector3(0, 1.1, -0.5)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	_wall.add_child(shape)
	_root.add_child(_wall)
	_pawn = _PawnScene.instantiate()
	_pawn.position = at
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_pawn.enable_cover(_cfg())
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	await _tree().physics_frame
	await _tree().physics_frame
	_pawn.handle_action_press("cover")
	for i in 150:
		await _tick()
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0 and not _pawn.is_cover_turning():
			break
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "fixture: in cover")
	var along: Vector3 = _pawn.cover.tangent * float(_pawn.cover.side)
	assert_true((-_pawn.global_basis.z).dot(along) > 0.99, "fixture: the cover camera looks along the wall")


func _tick(move: Vector2 = Vector2.ZERO, jump: bool = false, fire: bool = false) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.jump_just_pressed = jump
	frame.fire_pressed = fire  # M2 C1b stage 4: Fire in cover is the frame's fire bit
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


## Stick right while looking along the wall is the wall normal (away), stick left is into the wall.
func _away_stick() -> Vector2:
	var right := _pawn.global_basis.x
	return Vector2(1, 0) if right.dot(_pawn.cover.normal) > 0.0 else Vector2(-1, 0)


func test_slide_along_the_wall_with_the_camera_along_it_clamped_at_both_ends() -> void:
	await _fixture()
	var margin := float(_pawn.cover.config["edge_margin_m"])
	var side := float(_pawn.cover.side)
	var z := _pawn.global_position.z
	for i in 120:
		await _tick(Vector2(0, -1))
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "a forward push along the wall stays in cover")
	assert_true(absf(_pawn.global_position.x - side * (2.0 - margin)) < 0.01, "forward slides to the end it looks at, clamped (x %s)" % _pawn.global_position.x)
	assert_true(absf(_pawn.global_position.z - z) < 0.02, "the slide stays on the wall plane")
	for i in 240:
		await _tick(Vector2(0, 1))
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "a backward push along the wall stays in cover")
	assert_true(absf(_pawn.global_position.x + side * (2.0 - margin)) < 0.01, "backward slides to the other end, clamped (x %s)" % _pawn.global_position.x)
	await _cleanup()


func test_into_wall_push_does_nothing() -> void:
	await _fixture()
	var start := _pawn.global_position
	for i in 60:
		await _tick(-_away_stick())
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "the into-wall push stays in cover")
	assert_true(_pawn.global_position.distance_to(start) < 0.01, "the into-wall push does not move the pawn")
	await _cleanup()


func test_away_push_exits_after_the_hold_with_the_camera_along_the_wall() -> void:
	await _fixture()
	var hold := _ticks(float(_pawn.cover.config["exit_away_hold_s"]))
	for i in hold - 1:
		await _tick(_away_stick())
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "shorter than exit_away_hold_s: still in cover")
	await _tick()
	for i in hold - 1:
		await _tick(_away_stick())
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "the hold restarts after a release")
	await _tick(_away_stick())
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "the held away push exits")
	var z := _pawn.global_position.z
	var meter := Meter.new()
	for i in 90:
		await _tick(_away_stick())
		meter.sample(_rig.get_camera())
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "the exit completes")
	assert_true(_pawn.global_position.z > z + 0.5, "the pawn walks away from the wall")
	_assert_smooth(meter, "exit by stick")
	await _cleanup()


func test_jump_in_cover_exits_and_jumps() -> void:
	await _fixture()
	var y := _pawn.global_position.y
	await _tick(Vector2.ZERO, true)
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "Jump begins the exit")
	assert_true(_pawn.velocity.y > 0.0, "and jumps")
	var top := y
	for i in 20:
		await _tick()
		top = maxf(top, _pawn.global_position.y)
	assert_true(top > y + 0.3, "the pawn leaves the ground (peak %.3f m)" % (top - y))
	assert_true(_pawn.cover.state == CoverController.State.FREE, "the exit completes")
	await _cleanup()


## Per-frame camera move and turn (the test_first_person_camera.gd Meter).
class Meter:
	var last: Transform3D
	var started := false
	var max_m := 0.0
	var max_deg := 0.0

	func sample(cam: Camera3D) -> void:
		var xf := cam.global_transform
		if started:
			max_m = maxf(max_m, xf.origin.distance_to(last.origin))
			max_deg = maxf(max_deg, rad_to_deg((last.basis.get_rotation_quaternion().inverse() * xf.basis.get_rotation_quaternion()).get_angle()))
		last = xf
		started = true


func _assert_smooth(meter: Meter, tag: String) -> void:
	var max_m := _fp("smooth_max_step_m")
	var max_deg := _fp("smooth_max_step_deg")
	print("C1B MOVE_EXIT %s max_step_m=%.4f max_turn_deg=%.4f (limits %.2f m, %.1f deg)" % [tag, meter.max_m, meter.max_deg, max_m, max_deg])
	assert_true(meter.max_m < max_m, "%s: per-frame camera move %.4f m < %.2f m" % [tag, meter.max_m, max_m])
	assert_true(meter.max_deg < max_deg, "%s: per-frame camera turn %.4f deg < %.1f deg" % [tag, meter.max_deg, max_deg])


## Item 5, fix 19: the cover body is freed while in cover (IN_COVER) and while drawn out at the edge. The pawn leaves
## through EXITING (never straight to FREE), with no script error (the runner fails a test on any logged error), and
## the camera blends back with every per-frame move under the C1a limit.
func test_vanished_wall_exits_through_exiting_without_a_snap() -> void:
	for case in ["in_cover", "drawn_out"]:
		await _fixture(Vector3(1.65, 0, 0.6) if case == "drawn_out" else Vector3(0, 0, 0.6))
		if case == "drawn_out":
			# M2 C1b stage 4: drawn out by a Fire press (the frame's fire bit; was the routed quick_draw(true)).
			await _tick(Vector2.ZERO, false, true)
			for i in 20:
				await _tick()
			assert_true(_pawn.cover.aim_out_amount > 0.0 and _pawn.cover._draw_active, "fixture: drawn out at the edge")
		var meter := Meter.new()
		meter.sample(_rig.get_camera())
		if case == "drawn_out":
			_wall.queue_free()
			await _tree().process_frame
		else:
			_wall.free()
		assert_true(not is_instance_valid(_wall), "%s: the cover body is freed" % case)
		var states: Array = []
		for i in 120:
			await _tick()
			meter.sample(_rig.get_camera())
			if states.is_empty() or states[-1] != _pawn.cover.state:
				states.append(_pawn.cover.state)
			if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
				break
		assert_eq(states[0], CoverController.State.EXITING, "%s: the first tick after the wall vanished is EXITING" % case)
		assert_eq(states[-1], CoverController.State.FREE, "%s: then FREE" % case)
		assert_eq(_rig.get_first_person_weight(), 1.0, "%s: back in first person" % case)
		_assert_smooth(meter, "vanished wall " + case)
		await _cleanup()


func test_probe_reports_a_freed_wall_as_gone_and_never_touches_it() -> void:
	await _fixture()
	var probe: CoverProbe = _pawn._cover_probe  # locked on the wall by the entry
	var locked := probe.sample(_pawn, _pawn.cover.config, true)
	assert_true(bool(locked["hit"]) and not locked.has("wall_gone"), "a live locked wall is a hit")
	_wall.free()
	var after := probe.sample(_pawn, _pawn.cover.config, true)
	assert_true(not bool(after["hit"]) and bool(after.get("wall_gone", false)), "a freed locked wall is wall_gone")
	var unlocked := CoverProbe.new().sample(_pawn, _pawn.cover.config, false)
	assert_true(not unlocked.has("wall_gone"), "an unlocked sample never reports wall_gone")
	await _cleanup()


# ---- the real touch buttons in a real match -------------------------------------------------------

var match_scene: MatchRoot
var touch: Control
var old_size: Vector2i
var old_profile: Dictionary
var old_dpi: float


func frames(count: int) -> void:
	for i in count:
		await _tree().physics_frame
		await _tree().process_frame


func _match_box(at: Vector3, dimensions: Vector3, tagged: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var bounds := BoxShape3D.new()
	bounds.size = dimensions
	shape.shape = bounds
	body.add_child(shape)
	if tagged:
		body.add_to_group(&"cover_wall")
	match_scene.add_child(body)
	return body


## The test_cover_fire_fix.gd fixture (2520 x 1080 at 420 dpi, the custom stick), a 4 m 2.2 m wall far from the
## map with the pawn at its middle; enters with the Cover button and keeps the automatic turn (view along the wall).
func _match_setup() -> void:
	old_size = _tree().root.size
	old_profile = AppFlow.profile
	old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {}
	PlatformServices.dpi_override = 420.0
	_tree().root.size = Vector2i(2520, 1080)
	load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"
	match_scene = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	_tree().root.add_child(match_scene)
	await _tree().process_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	_pawn = match_scene.local_player
	touch = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	_match_box(Vector3(1000, -0.1, 0), Vector3(30, 0.2, 30), false)
	_wall = _match_box(Vector3(1000, 1.1, -0.5), Vector3(4, 2.2, 1), true)
	_pawn.position = Vector3(1000, 0, 0.6)
	_pawn.rotation = Vector3.ZERO
	_pawn.pitch = 0.0
	_pawn.velocity = Vector3.ZERO
	_pawn.enable_cover(_cfg())
	await frames(2)
	await _tap(touch.get_button_rect(touch.SHOULDER_KEY).get_center())
	for i in 90:
		await frames(1)
		if _pawn.cover.state == CoverController.State.IN_COVER and not _pawn.is_cover_turning():
			break
	touch.provider.move_value = Vector2.ZERO
	touch.provider.cancel_sprint_lock()
	await frames(2)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "fixture: the real Cover button entered")
	var along: Vector3 = _pawn.cover.tangent * float(_pawn.cover.side)
	assert_true((-_pawn.global_basis.z).dot(along) > 0.99, "fixture: the view looks along the wall")


func _match_cleanup() -> void:
	match_scene.queue_free()
	await _tree().process_frame
	_tree().root.size = old_size
	AppFlow.profile = old_profile
	PlatformServices.dpi_override = old_dpi
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""
	for action in ["fire", "jump", "aim", "swap_shoulder", "cover"]:
		Input.action_release(action)
	await _tree().process_frame


func _event_at(point: Vector2, down: bool, index: int = 47) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = _tree().root.get_screen_transform() * point
	_tree().root.push_input(event, false)


func _tap(point: Vector2) -> void:
	_event_at(point, true)
	await frames(2)
	_event_at(point, false)
	await frames(1)


func _wait_free(max_frames: int = 60) -> void:
	for i in max_frames:
		if _pawn.cover.state == CoverController.State.FREE:
			return
		await frames(1)


func test_hidden_slots_empty_and_jump_sprint_lock_cover_visible_in_cover() -> void:
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	# M2 C1b stage 4: the whole cover_buttons block is gone (was: its hidden_slots list is empty).
	assert_true(not ui.has("cover_buttons"), "ui.json has no cover_buttons block (no slot hidden in cover)")
	await _match_setup()
	assert_true(touch._buttons["jump"].visible, "Jump visible in cover")
	assert_true(touch.lock_button.visible, "the Sprint lock visible in cover")
	assert_true(touch._buttons["swap_shoulder"].visible and touch._action_of("swap_shoulder") == "cover", "the Cover button visible in cover")
	assert_true(touch.cover_slot_engaged, "the Cover button shows its active state")
	for key in ["jump", "sprint_lock", "swap_shoulder"]:
		assert_true(key in touch.get_element_keys(), "%s stays a layout element in cover" % key)
	# M2 C1b stage 4: the slot-hiding machinery is deleted (was: assert not touch.cover_controls_active).
	assert_true(not ("cover_controls_active" in touch) and not touch.has_method("set_cover_controls_active"), "the old slot hiding is gone")
	assert_true(match_scene.find_children("CoverFireButton", "", true, false).is_empty() and match_scene.find_children("CoverCrouchButton", "", true, false).is_empty(), "the old cover FIRE / Crouch squares are not created")
	await _match_cleanup()


func test_cover_button_exit_through_the_real_button() -> void:
	await _match_setup()
	await _tap(touch.get_button_rect(touch.SHOULDER_KEY).get_center())
	assert_true(_pawn.cover.state == CoverController.State.EXITING or _pawn.cover.state == CoverController.State.FREE, "the real Cover button exits")
	await _wait_free()
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "the exit completes")
	await _match_cleanup()


func test_hard_forward_push_neither_sprints_nor_exits_and_the_lock_stays_usable() -> void:
	await _match_setup()
	var x := _pawn.global_position.x
	touch.provider.move_value = Vector2(0, -1)
	await frames(60)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "a hard forward push does not exit")
	assert_true(touch.provider.cover_suppress_sprint, "the touch HUD set the provider's cover flag")
	assert_true(not touch.provider.is_sprinting(), "the forward-extreme gesture does not sprint in cover")
	assert_true(not _pawn._frame.sprint and is_equal_approx(_pawn.sprint_factor, 1.0), "no sprint reaches the pawn")
	assert_true(absf(_pawn.global_position.x - x) > 0.5, "the forward push slides along the wall instead")
	assert_true(touch.lock_button.visible and touch.provider.lock_target_visible(), "the Sprint lock button and target stay reachable")
	await _tap(touch.lock_button.get_global_rect().get_center())
	assert_true(touch.provider.sprint_locked, "the real Sprint lock button locks in cover")
	assert_true(_pawn.cover.state == CoverController.State.EXITING or _pawn.cover.state == CoverController.State.FREE, "and the lock exits")
	touch.provider.move_value = Vector2.ZERO
	await _wait_free()
	await frames(2)
	assert_true(not touch.provider.cover_suppress_sprint, "the flag clears outside cover")
	await _match_cleanup()


func test_sprint_lock_exit_through_the_real_lock_button() -> void:
	await _match_setup()
	touch.provider.move_value = Vector2(0, -0.5)  # a partial forward push: a slide along the wall, no sprint gesture
	await frames(3)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "the partial push slides")
	await _tap(touch.lock_button.get_global_rect().get_center())
	assert_true(touch.provider.sprint_locked, "the real Sprint lock button locks")
	assert_true(_pawn.cover.state == CoverController.State.EXITING or _pawn.cover.state == CoverController.State.FREE, "the Sprint lock press exits")
	touch.provider.move_value = Vector2.ZERO
	await _wait_free()
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "the exit completes")
	await frames(20)
	assert_true(_pawn.sprint_factor > 1.0, "and sprints")
	touch.provider.cancel_sprint_lock()
	await _match_cleanup()


func test_jump_exits_and_jumps_through_the_real_jump_button() -> void:
	await _match_setup()
	var y := _pawn.global_position.y
	var point: Vector2 = touch._buttons["jump"].get_global_rect().get_center()
	_event_at(point, true)
	var top := y
	var exited := false
	for i in 4:
		await frames(1)
		top = maxf(top, _pawn.global_position.y)
		exited = exited or _pawn.cover.state == CoverController.State.EXITING
	_event_at(point, false)
	for i in 20:
		await frames(1)
		top = maxf(top, _pawn.global_position.y)
	assert_true(exited, "the real Jump button exits through EXITING")
	assert_true(top > y + 0.3, "and jumps (peak %.3f m)" % (top - y))
	await _wait_free()
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "the exit completes")
	await _match_cleanup()
