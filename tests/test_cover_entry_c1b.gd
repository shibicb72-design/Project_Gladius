extends "res://tests/test_case.gd"
## M2 C1b stage 1: the Cover button and the auto-snap anti-sticky rules (data/cover.json, OQ-COVER), the LAN gate
## (MatchRoot.networked_match), the Shoulder/Cover slot in the touch HUD and the cover_snap haptic.

const DT := 1.0 / 60.0
const _MatchScene := preload("res://scenes/match/match.tscn")

var _root: Node3D
var _pawn: Pawn
var _wall: StaticBody3D


class FakeBackend extends HapticsBackend:
	var calls: Array = []

	func is_supported() -> bool:
		return true

	func vibrate(duration_ms: int, amplitude: float) -> void:
		calls.append([duration_ms, amplitude])


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")


## Facts as CoverProbe.sample returns them for a wall face on z = 0 (normal +z), 4 m wide, 2.2 m tall.
func _probe(at: Vector3 = Vector3(0, 0, 0.6), basis: Basis = Basis.IDENTITY) -> Dictionary:
	return {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": at, "basis": basis,
		"distance_m": at.z, "left_m": at.x + 2.0, "right_m": 2.0 - at.x, "height_m": 2.2, "slide_speed_mps": 4.1783,
		"shot_clear": true, "stand_clear": true}


func _ticks(seconds: float) -> int:
	return ceili(seconds / DT - 0.0001)


## Pushes the stick forward into the wall until the controller leaves FREE; returns the ticks it took (or -1).
func _push_until_snap(c: CoverController, max_ticks: int, fire := false, sprint := false, probe: Dictionary = {}) -> int:
	var p := probe if not probe.is_empty() else _probe()
	for i in max_ticks:
		c.tick(DT, Vector2(0, -1), fire, p, false, sprint)
		if c.state != CoverController.State.FREE:
			return i + 1
	return -1


func _settle_in_cover(c: CoverController) -> void:
	for i in _ticks(c.enter_duration()) + 1:
		c.tick(DT, Vector2.ZERO, false, _probe(Vector3(0, 0, 0.45)))


func _exit_to_free(c: CoverController) -> void:
	assert_true(c.request_cover({}), "Cover press in cover begins the exit")
	assert_eq(c.state, CoverController.State.EXITING, "exit begins at once")
	for i in _ticks(float(c.config["exit_s"])) + 1:
		c.tick(DT, Vector2.ZERO, false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.FREE, "exit completes")


# ---- data --------------------------------------------------------------------------------------

func test_new_cover_data_keys_exist_with_the_briefed_placeholders() -> void:
	var cfg := _cfg()
	for key in ["cover_button_range_m", "input_lock_max_s", "snap_lerp_s", "reentry_cooldown_s", "snap_hold_s",
			"max_wall_angle_deg", "probe_m", "enter_s"]:
		assert_true(cfg.has(key), "cover.json has " + key)
	assert_eq(float(cfg["cover_button_range_m"]), 1.5, "button range")
	assert_eq(float(cfg["probe_m"]), 0.7, "auto-snap keeps its own probe distance")
	assert_true(float(cfg["cover_button_range_m"]) > float(cfg["probe_m"]), "the button reaches farther than auto-snap")
	assert_true(str(cfg.get("_c1b_todo", "")).contains("OQ-COVER"), "the new numbers carry an OQ-COVER note")


# ---- the Cover button (controller) -------------------------------------------------------------

func test_cover_press_enters_within_button_range_and_not_beyond() -> void:
	var range_m := float(_cfg()["cover_button_range_m"])
	var c := CoverController.new(_cfg())
	assert_true(not c.can_enter_by_button(_probe(Vector3(0, 0, range_m + 0.05))), "beyond the range is not valid")
	assert_true(not c.request_cover(_probe(Vector3(0, 0, range_m + 0.05))), "a press beyond the range does nothing")
	assert_eq(c.state, CoverController.State.FREE, "still free beyond the range")
	var low := _probe(Vector3(0, 0, 1.0))
	low["height_m"] = float(_cfg()["min_cover_height_m"]) - 0.05
	assert_true(not c.request_cover(low), "too low to be cover")
	var miss := _probe(Vector3(0, 0, 1.0))
	miss["hit"] = false
	assert_true(not c.request_cover(miss), "no wall, no entry")
	assert_true(c.can_enter_by_button(_probe(Vector3(0, 0, range_m - 0.05))), "inside the range is valid")
	var entered := [0]
	c.entered.connect(func() -> void: entered[0] += 1)
	assert_true(c.request_cover(_probe(Vector3(0, 0, range_m - 0.05))), "a press inside the range enters")
	assert_eq(c.state, CoverController.State.ENTERING, "entering at once, no stick and no hold needed")
	assert_eq(entered[0], 1, "entered emitted once")
	assert_true(absf(c.target_position.z - float(_cfg()["wall_offset_m"])) < 0.001, "target is the wall plane")
	assert_true(not c.can_enter_by_button(_probe()), "not valid once in cover")


func test_cover_press_in_cover_and_peek_exits_and_is_ignored_while_entering() -> void:
	var c := CoverController.new(_cfg())
	assert_true(c.request_cover(_probe(Vector3(0, 0, 1.0))), "enters")
	assert_true(not c.request_cover({}), "ENTERING ignores a second press")
	assert_eq(c.state, CoverController.State.ENTERING, "still entering")
	_settle_in_cover(c)
	assert_eq(c.state, CoverController.State.IN_COVER, "settled")
	_exit_to_free(c)
	# M2 C1b stage 3: the stick no longer peeks, so the peek is set directly (test seam; stage 4 leans from Fire / Aim).
	c = CoverController.new(_cfg())
	assert_true(c.request_cover(_probe(Vector3(1.65, 0, 0.45))), "enters near the right edge")
	_settle_in_cover(c)
	c.state = CoverController.State.PEEK_RIGHT
	assert_true(c.request_cover({}), "a press while peeked exits")
	assert_eq(c.state, CoverController.State.EXITING, "peek -> exiting")


func test_cooldown_blocks_auto_snap_but_not_the_cover_button() -> void:
	var cfg := _cfg()
	var c := CoverController.new(cfg)
	assert_true(c.request_cover(_probe(Vector3(0, 0, 1.0))), "enters")
	_settle_in_cover(c)
	_exit_to_free(c)
	var cooldown_ticks := _ticks(float(cfg["reentry_cooldown_s"]))
	var hold_ticks := _ticks(float(cfg["snap_hold_s"]))
	assert_true(cooldown_ticks > 2, "fixture: the cooldown spans several ticks")
	assert_eq(_push_until_snap(c, cooldown_ticks - 1), -1, "no auto-snap during the cooldown")
	assert_true(c.request_cover(_probe()), "the Cover button ignores the cooldown")
	assert_eq(c.state, CoverController.State.ENTERING, "button entry during the cooldown")
	_settle_in_cover(c)
	_exit_to_free(c)
	var n := _push_until_snap(c, cooldown_ticks + hold_ticks + 5)
	assert_true(n > cooldown_ticks, "auto-snap only after the cooldown (took %d ticks, cooldown %d)" % [n, cooldown_ticks])
	assert_true(n <= cooldown_ticks + hold_ticks + 1, "and then after the usual hold (took %d)" % n)


func test_no_auto_snap_while_sprinting() -> void:
	var c := CoverController.new(_cfg())
	assert_eq(_push_until_snap(c, 120, false, true), -1, "two seconds sprinting into the wall never snaps")
	var n := _push_until_snap(c, 120)
	assert_eq(n, _ticks(float(_cfg()["snap_hold_s"])), "the hold restarts when sprint ends")
	c = CoverController.new(_cfg())
	assert_true(c.request_cover(_probe()), "the Cover button still works for a sprinting player")


func test_no_auto_snap_while_fire_is_held() -> void:
	var c := CoverController.new(_cfg())
	assert_eq(_push_until_snap(c, 120, true), -1, "two seconds of Fire held into the wall never snaps")
	assert_eq(_push_until_snap(c, 120), _ticks(float(_cfg()["snap_hold_s"])), "the hold restarts when Fire is released")


func test_snap_hold_time_comes_from_data() -> void:
	for hold in [float(_cfg()["snap_hold_s"]), 0.4]:
		var cfg := _cfg()
		cfg["snap_hold_s"] = hold
		var c := CoverController.new(cfg)
		assert_eq(_push_until_snap(c, 120), _ticks(hold), "snap after %s s of pushing" % hold)
	assert_eq(float(_cfg()["snap_hold_s"]), 0.25, "shipped placeholder")


func test_stick_must_point_into_the_wall_within_the_max_angle() -> void:
	var max_deg := float(_cfg()["max_wall_angle_deg"])
	for case in [[max_deg - 5.0, true], [max_deg + 5.0, false]]:
		var c := CoverController.new(_cfg())
		var a := deg_to_rad(float(case[0]))
		var n := -1
		for i in 60:
			c.tick(DT, Vector2(sin(a), -cos(a)), false, _probe())
			if c.state != CoverController.State.FREE:
				n = i
				break
		assert_eq(n != -1, bool(case[1]), "stick %s deg off the wall normal snaps=%s" % [case[0], case[1]])
	var away := CoverController.new(_cfg())
	for i in 60:
		away.tick(DT, Vector2(0, 1), false, _probe())
	assert_eq(away.state, CoverController.State.FREE, "pulling away never snaps")


# ---- input lock and snap lerp ------------------------------------------------------------------

func test_entering_lock_never_exceeds_the_cap_and_the_lerp_continues() -> void:
	var cfg := _cfg()
	var cap := float(cfg["input_lock_max_s"])
	assert_true(cap <= 0.15 + 0.000001, "shipped cap is at most 0.15 s")
	for enter_s in [float(cfg["enter_s"]), 0.5]:
		var over := _cfg()
		over["enter_s"] = enter_s
		var c := CoverController.new(over)
		assert_true(c.enter_duration() <= cap + 0.000001, "ENTERING lasts at most the cap (enter_s %s)" % enter_s)
		assert_true(c.request_cover(_probe(Vector3(0, 0, 1.4))), "enters from 1.4 m")
		var pos := Vector3(0, 0, 1.4)
		var entering_ticks := 0
		var settled_z := -1.0
		var lerp_ticks := _ticks(float(over["snap_lerp_s"]))
		for i in lerp_ticks + 2:
			c.tick(DT, Vector2.ZERO, false, _probe(pos))
			if c.state == CoverController.State.ENTERING:
				entering_ticks += 1
			elif settled_z < 0.0:
				settled_z = pos.z
			var v := c.movement_velocity(pos, Vector3.ZERO, 6.3, DT)
			assert_true(v.length() <= 6.3 + 0.0001, "snap movement stays speed bounded")
			pos += v * DT
		assert_true(entering_ticks * DT <= cap + DT * 0.5, "ENTERING held %d ticks, cap %s s" % [entering_ticks, cap])
		assert_eq(c.state, CoverController.State.IN_COVER, "settled to IN_COVER")
		if float(over["snap_lerp_s"]) > cap:
			assert_true(settled_z > float(over["wall_offset_m"]) + 0.05, "the snap move continues after the state settles (z %s)" % settled_z)
		assert_true(absf(pos.z - float(over["wall_offset_m"])) < 0.01, "on the wall plane after snap_lerp_s (z %s)" % pos.z)


func test_stick_is_free_once_the_lock_ends() -> void:
	var c := CoverController.new(_cfg())
	assert_true(c.request_cover(_probe(Vector3(0, 0, 0.45))), "enters")
	for i in _ticks(c.enter_duration()):
		c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "the lock ended at the cap")
	# M2 C1b stage 3: the away push is counted from the first tick after the lock and exits after exit_away_hold_s.
	var hold := _ticks(float(c.config["exit_away_hold_s"]))
	for i in hold - 1:
		c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "the hold counts only after the lock")
	c.tick(DT, Vector2(0, 1), false, _probe(Vector3(0, 0, 0.45)))
	assert_eq(c.state, CoverController.State.EXITING, "the stick acts from the first tick after the lock")


# ---- the real pawn and wall --------------------------------------------------------------------

func _fixture(pawn_z: float) -> void:
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
	_wall = _make_wall(Vector3(0, 1.1, -0.5))
	_root.add_child(_wall)
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_pawn.position = Vector3(0, 0, pawn_z)
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_pawn.enable_cover(_cfg())
	await _tree().physics_frame
	await _tree().physics_frame


func _make_wall(at: Vector3, basis: Basis = Basis.IDENTITY) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.add_to_group(&"cover_wall")
	wall.transform = Transform3D(basis, at)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	wall.add_child(shape)
	return wall


func _tick(move: Vector2, fire := false, sprint := false) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.fire_pressed = fire
	frame.sprint = sprint
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _cleanup() -> void:
	_root.queue_free()
	await _tree().process_frame


func test_pawn_cover_press_enters_a_real_wall_in_range_and_holds_it() -> void:
	await _fixture(1.3)
	assert_true(_pawn.cover_button_available(), "offline local pawn offers the Cover button")
	assert_true(_pawn.cover_button_valid(), "a wall face 1.3 m ahead is valid")
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.ENTERING, "the press enters at once")
	for i in 60:
		await _tick(Vector2.ZERO)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "the locked probe keeps the wall the button found")
	assert_true(absf(_pawn.global_position.z - float(_pawn.cover.config["wall_offset_m"])) < 0.05, "moved onto the wall plane (z %s)" % _pawn.global_position.z)
	assert_true(not _pawn.cover_button_valid(), "no entry highlight while in cover")
	assert_true(_pawn.in_cover(), "in_cover for the active look")
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "a second press exits")
	for i in 30:
		await _tick(Vector2.ZERO)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "back to free")
	await _cleanup()


func test_pawn_cover_press_beyond_range_does_nothing() -> void:
	await _fixture(1.5 + 0.3)
	assert_true(not _pawn.cover_button_valid(), "1.8 m is out of the button's reach")
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "no entry")
	await _tick(Vector2.ZERO)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "still free")
	await _cleanup()


func test_pawn_sprint_and_fire_block_the_real_auto_snap() -> void:
	await _fixture(0.6)
	for i in 60:
		await _tick(Vector2(0, -1), false, true)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "sprinting into the real wall does not snap")
	for i in 60:
		await _tick(Vector2(0, -1), true, false)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "Fire held into the real wall does not snap")
	for i in 40:
		await _tick(Vector2(0, -1))
	assert_true(_pawn.cover.state != CoverController.State.FREE, "a plain push snaps")
	await _cleanup()


func test_cover_snap_haptic_exists_and_plays_on_button_and_auto_entry() -> void:
	var ev: Dictionary = DataRegistry.new().load_file("res://data/haptics.json")["events"].get("cover_snap", {})
	assert_true(not ev.is_empty(), "haptics.json has cover_snap")
	var prev := Haptics.service
	var fake := FakeBackend.new()
	Haptics.service = HapticsService.new({}, fake)
	await _fixture(1.2)
	_pawn.handle_action_press("cover")
	assert_eq(fake.calls.size(), 1, "the button entry plays one haptic")
	var high: Dictionary = ev.get("high", {})
	assert_eq(fake.calls[0] if fake.calls.size() > 0 else [], [int(high.get("duration_ms", -1)), float(high.get("amplitude", -1.0))], "cover_snap's data values")
	await _cleanup()
	await _fixture(0.6)
	fake.calls.clear()
	for i in 40:
		await _tick(Vector2(0, -1))
	assert_eq(fake.calls.size(), 1, "the auto-snap plays one haptic")
	await _cleanup()
	Haptics.service = prev


# ---- the match: LAN gate and the HUD slot ------------------------------------------------------

func _offline_match() -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.begin()
	for i in 6:
		await _tree().physics_frame
	await _tree().process_frame
	return m


func test_offline_ground_slot_is_the_cover_button_and_shoulder_elsewhere() -> void:
	var m := await _offline_match()
	# M2 H1c: two more process frames (was none): under machine load the helper's physics waits can fall in one catch-up,
	# so the HUD's per-frame slot refresh had not run yet (load-sensitive, not a behaviour change).
	await _tree().process_frame
	await _tree().process_frame
	var touch: Control = m.get_node("Hud/TouchHud")
	var pawn := m.local_player
	assert_true(not m.networked_match and pawn.cover != null, "offline local player has cover")
	var key: String = touch.SHOULDER_KEY
	var b: Button = touch._buttons[key]
	assert_true(touch.cover_slot_active, "on the ground the slot is the Cover button")
	assert_eq(b.text, str(DataRegistry.new().load_file("res://data/ui.json")["cover_button"]["label"]), "Cover label")
	assert_eq(touch._action_of(key), "cover", "the slot presses the cover action")
	assert_true(b.visible, "visible in first person (no tap swallowing on the ground)")
	assert_true(touch.get_button_rect(key).size.x + 0.001 >= touch.get_element_min_px(key), "at least 48 dp")
	var got: Array = []
	m.router.action_triggered.connect(func(a: String) -> void: got.append(a))
	var c: Vector2 = touch.get_button_rect(key).get_center()
	touch._on_down(5, c)
	assert_true(Input.is_action_pressed("cover"), "the press holds InputMap 'cover'")
	assert_true(got.has("cover"), "and reaches the router's action_triggered (trigger_action)")
	touch._on_up(5)
	assert_true(not Input.is_action_pressed("cover"), "the release frees 'cover'")
	var states := [["carrier", func() -> void: pawn.drop_state = Pawn.Drop.ABOARD],
		# M2 C1b stage 3: lifted 30 m, so the pawn really falls (a FALLING pawn on the floor lands on its next physics
		# tick, which made this case depend on how many physics ticks two process frames hold).
		["falling", func() -> void:
			pawn.global_position.y += 30.0
			pawn.drop_state = Pawn.Drop.FALLING],
		["downed", func() -> void:
			pawn.drop_state = Pawn.Drop.NONE
			pawn.life = Pawn.Life.DOWNED]]
	for s in states:
		(s[1] as Callable).call()
		await _tree().process_frame
		await _tree().process_frame
		assert_true(not touch.cover_slot_active, "%s: no Cover button" % s[0])
		assert_eq(touch._action_of(key), "swap_shoulder", "%s: the slot is Shoulder swap" % s[0])
		assert_eq(b.text, "Shoulder", "%s: Shoulder label" % s[0])
		assert_true(b.visible, "%s: third person shows Shoulder" % s[0])
	pawn.life = Pawn.Life.ALIVE
	await _tree().process_frame
	await _tree().process_frame
	assert_true(touch.cover_slot_active, "back on the ground: Cover again")
	m.queue_free()
	await _tree().process_frame


func test_highlight_follows_cover_validity() -> void:
	var m := await _offline_match()
	var touch: Control = m.get_node("Hud/TouchHud")
	var pawn := m.local_player
	await _tree().process_frame
	if pawn.cover_button_valid():
		failures.append("fixture: the spawn already faces cover within reach; the test needs open ground ahead")
		m.queue_free()
		return
	assert_true(touch.cover_slot_active and not touch.cover_slot_valid, "no highlight with nothing in reach")
	var ahead := -pawn.global_basis.z
	ahead.y = 0
	ahead = ahead.normalized()
	var wall := _make_wall(pawn.global_position + ahead * 1.6 + Vector3.UP * 1.1, Basis.looking_at(ahead))
	m.add_child(wall)
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	assert_true(pawn.cover_button_valid(), "a wall face 1.1 m ahead is valid")
	assert_true(touch.cover_slot_valid, "the slot highlights")
	var sb := (touch._buttons[touch.SHOULDER_KEY] as Button).get_theme_stylebox("normal") as StyleBoxFlat
	var col: Array = DataRegistry.new().load_file("res://data/ui.json")["cover_button"]["valid_border_color"]
	assert_true(sb != null and sb.border_color.is_equal_approx(Color(col[0], col[1], col[2], col[3])), "valid border colour")
	wall.global_position = pawn.global_position + ahead * 2.6 + Vector3.UP * 1.1
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	assert_true(not touch.cover_slot_valid, "the highlight drops when the wall is out of reach")
	pawn.handle_action_press("cover")
	assert_true(not pawn.in_cover(), "and a press there does nothing")
	m.queue_free()
	await _tree().process_frame


func test_lan_host_has_no_cover_button_and_no_auto_snap() -> void:
	var s := NetSession.new()
	s.name = "TCoverHost"
	s.isolated = true
	_tree().root.add_child(s)
	s.host_game()
	s.lobby.host_open(2, 3, "Host")
	# M2 H1c item 1: a LAN session needs another human (a host alone is offline for cover; test_h1c_cover_button.gd).
	assert_true(s.lobby.state.add_human(2, "Client"), "a second human joins the lobby")
	assert_true(s.lobby.start_match(), "host lobby starts")
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = s.lobby.match_seed
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	assert_true(m.begin(), "host match begins")
	for i in 6:
		await _tree().physics_frame
	await _tree().process_frame
	var pawn := m.local_player
	assert_true(m.networked_match, "the LAN signal is set")
	assert_eq(pawn.net_mode, Pawn.NetMode.LOCAL, "the host's own pawn is LOCAL (net_mode alone cannot gate it)")
	assert_true(pawn.in_lan_session(), "the pawn sees the LAN session")
	assert_true(pawn.cover == null, "no cover controller on LAN, so no auto-snap")
	pawn.enable_cover(_cfg())
	assert_true(pawn.cover == null, "the explicit seam refuses too")
	assert_true(not pawn.cover_button_available(), "no Cover button offered")
	var touch: Control = m.get_node("Hud/TouchHud")
	assert_true(not touch.cover_slot_active, "the slot is not the Cover button")
	assert_true(touch._action_of(touch.SHOULDER_KEY) != "cover", "the slot never presses cover")
	assert_true(not (touch._buttons[touch.SHOULDER_KEY] as Button).visible or touch._action_of(touch.SHOULDER_KEY) == "swap_shoulder", "Cover is hidden")
	pawn.handle_action_press("cover")
	assert_true(pawn.cover == null, "a cover press on LAN is a no-op")
	m.queue_free()
	s.leave()
	s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame
	await _tree().process_frame
