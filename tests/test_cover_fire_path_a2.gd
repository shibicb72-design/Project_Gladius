extends "res://tests/test_case.gd"
## Real match, live pawn physics and real tagged-wall probe; window-pixel touch routes.
## M2 C1b stage 3: the HUD no longer creates the old cover FIRE / Crouch squares; tests that pinned the squares'
## geometry, colours or hit circles, or the stick peek, are deleted. M2 C1b stage 4: shots are fired with the normal
## right Fire button (cover_fire / fire_tap below; was the routed "cover_fire" press), and the reach rule is
## CoverController.fire_available (was can_quick_draw).
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var wall: StaticBody3D
var shots := 0
var old_size: Vector2i
var old_profile: Dictionary
var old_dpi: float
var first_shot_s := -1.0

func tree() -> SceneTree:
	return Engine.get_main_loop()

func frames(count: int) -> void:
	for i in count:
		await tree().physics_frame
		await tree().process_frame

func box(at: Vector3, dimensions: Vector3, tagged: bool = true) -> StaticBody3D:
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

func setup(window: Vector2i, dpi: float, height: float = 2.2, edge: float = 0.25, enter: bool = true) -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {}
	PlatformServices.dpi_override = dpi
	tree().root.size = window
	load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"
	match_scene = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	tree().root.add_child(match_scene)
	await tree().process_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	pawn = match_scene.local_player
	touch = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	# Isolate geometry from random spawn/map occlusion, retaining the full real map and HUD.
	box(Vector3(1000, -0.1, 0), Vector3(30, 0.2, 30), false)
	wall = box(Vector3(1000, height * 0.5, -0.5), Vector3(4, height, 1))
	pawn.position = Vector3(1002 - edge, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	shots = 0
	first_shot_s = -1.0
	pawn.fired.connect(func():
		shots += 1
		if first_shot_s < 0.0:
			first_shot_s = pawn.get_clock()
	)
	if enter:
		# M2 C1b stage 1: a full forward touch push is the sprint gesture, which no longer auto-snaps; enter by Cover.
		pawn.handle_action_press("cover")
		pawn.cancel_cover_turn()  # M2 C1b stage 2: the view stays on the wall (as a look input would keep it)
		await frames(60)
	touch.provider.move_value = Vector2.ZERO
	touch.provider.cancel_sprint_lock()
	await frames(4)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER if enter else CoverController.State.FREE, "live probe cover state")
	assert_true(pawn.is_physics_processing(), "pawn physics stays running")
	if enter:
		assert_eq(pawn.cover.wall_key, wall.get_instance_id(), "facts come from tagged wall")

func cleanup() -> void:
	match_scene.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile
	PlatformServices.dpi_override = old_dpi
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""
	for action in ["fire", "jump", "aim", "swap_shoulder"]:
		Input.action_release(action)
	await tree().process_frame

func event_at(point: Vector2, down: bool, singleton: bool = false, index: int = 41) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	if singleton:
		Input.parse_input_event(event)
	else:
		tree().root.push_input(event, false)

func tap(point: Vector2, singleton: bool = false) -> void:
	event_at(point, true, singleton)
	await tree().process_frame
	event_at(point, false, singleton)
	await tree().process_frame

## M2 C1b stage 4: the right Fire button press / release in window pixels (was the routed cover FIRE press / release;
## the cancel flag of the old release has no meaning any more).
func cover_fire(down: bool, _cancel: bool = false) -> void:
	event_at(touch.get_button_rect(touch.RIGHT_FIRE_KEY).get_center(), down, false, 42)

## A Fire button tap, two physics frames down (was one process frame on the press-time route, which a polled button
## can miss between two physics ticks).
func fire_tap() -> void:
	cover_fire(true)
	await frames(2)
	cover_fire(false)
	await tree().process_frame

## A routed tap with the timing of hold_tap() (two frames down).
func fire_hold_tap() -> void:
	cover_fire(true)
	await frames(2)
	cover_fire(false)
	await frames(2)

func hold_tap(point: Vector2, singleton: bool = false) -> void:
	event_at(point, true, singleton)
	await frames(2)
	event_at(point, false, singleton)
	await frames(2)

## M2 H1c (OQ-SPRINT-LOCK): the only way to lock: a real touch on the move rest pushed to the Lock target, lifted there.
func lock_by_target() -> void:
	var origin: Vector2 = touch.get_move_rest()
	event_at(origin, true)
	await frames(1)
	var target: Vector2 = touch.get_lock_target_rect().get_center()
	var drag := InputEventScreenDrag.new()
	drag.index = 41
	drag.position = tree().root.get_screen_transform() * target
	drag.relative = tree().root.get_screen_transform().basis_xform(target - origin)
	tree().root.push_input(drag, false)
	await frames(2)
	event_at(target, false)
	await frames(2)

func test_aimed_auto_hold_auto_tap_and_semi_tap_preserve_mode() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	await hold_tap(touch._buttons["aim"].get_global_rect().get_center())
	await frames(30)
	assert_true(pawn.aiming and pawn.aim_blend == 1.0 and pawn.cover.aimed_out, "real Aim toggle zooms and holds lean")
	var weapon := pawn.loadout.get_active()
	assert_eq(weapon.fire_mode, "auto", "data default auto")
	cover_fire(true)
	await frames(30)
	cover_fire(false)
	await frames(12)
	assert_true(shots > 1, "held aimed FIRE repeats automatically")
	var before := shots
	await fire_tap()
	await frames(12)
	assert_eq(shots - before, 1, "aimed auto tap fires exactly one round")
	assert_eq(weapon.fire_mode, "auto", "FIRE does not change mode")
	weapon.fire_mode = "semi"
	before = shots
	await fire_tap()
	await frames(18)
	assert_eq(shots - before, 1, "aimed semi tap fires exactly one round")
	assert_eq(weapon.fire_mode, "semi", "cover control preserves semi")
	await cleanup()

## M2 C1b stage 3: one routed run (was: both Fold screens, each by viewport and by Input singleton taps on the square).
func test_rc_green_auto_tap_during_weapon_interval_is_not_lost() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	await hold_tap(touch._buttons["aim"].get_global_rect().get_center())
	await frames(30)
	assert_true(pawn.cover.fire_available() and pawn.cover.aimed_out, "green completed live lean")
	await fire_hold_tap()
	assert_eq(shots, 1, "first green auto tap shoots")
	await fire_tap()
	await frames(20)
	print("A2 RC rapid green auto taps shots=%d" % shots)
	assert_eq(shots, 2, "second accepted green auto tap survives weapon interval")
	await cleanup()

## M2 C1b stage 3: the colour assertions on the old square are gone; the reach rule is kept. M2 C1b stage 4: the rule
## is fire_available (was can_quick_draw) and the buffer is _fire_buffered (was _buffered_round / _quick_held).
func test_red_tap_no_queue_and_reach_updates_on_live_slide() -> void:
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 2.0)
	assert_true(not pawn.cover.fire_available(), "tall midwall red")
	var start := pawn.position
	await fire_tap()
	await frames(30)
	assert_true(not pawn.cover._fire_buffered and not pawn.cover._draw_active, "red tap queues nothing")
	assert_true(pawn.position.distance_to(start) < 0.00001 and shots == 0, "red tap never pops or fires")
	touch.provider.move_value = Vector2(0.49, 0)
	var crossed := false
	for i in 100:
		await frames(1)
		crossed = crossed or pawn.cover.fire_available()
	touch.provider.move_value = Vector2.ZERO
	await frames(20)
	assert_true(crossed and pawn.cover.fire_available(), "slide reaches green edge band")
	assert_true(shots == 0 and not pawn.cover._fire_buffered and not pawn.cover._draw_active, "old red tap is not promoted after green")
	await fire_tap()
	await frames(60)
	assert_eq(shots, 1, "fresh green tap fires")
	await cleanup()

func test_low_cover_green_fires_at_both_ends_and_middle() -> void:
	for edge in [0.25, 2.0, 3.75]:
		await setup(Vector2i(2176, 1812), 373.0, 1.1, edge)
		assert_true(pawn.cover.fire_available(), "low wall green along entire wall")
		await fire_tap()
		await frames(60)
		assert_eq(shots, 1, "low wall tap fires once")
		await cleanup()

## M2 C1b stage 3: was test_cover_slots_do_not_jump_lock_or_swap_and_ten_reliable_taps. Jump and the Sprint lock are
## no longer hidden in cover (they exit it; tests/test_cover_move_exit_c1b.gd) and the Crouch square is gone, so only
## the ten routed taps and the no-recoil rule are left.
func test_ten_reliable_cover_fire_taps_without_recoil() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var shoulder := rig.shoulder_side
	await frames(65)
	# Shibi, Nov 10 2026: no recoil on the quick shot from cover, so ten cover FIRE taps leave the real aim where it was
	# (with recoil it drifted into the wall and cover FIRE refused the shot).
	var aim_yaw := pawn.rotation.y
	var aim_pitch := pawn.pitch
	for i in 10:
		var before := shots
		await fire_tap()
		await frames(65)
		assert_eq(shots - before, 1, "green FIRE tap %d/10" % (i + 1))
		assert_true(absf(pawn.pitch - aim_pitch) < 1e-6 and absf(pawn.rotation.y - aim_yaw) < 1e-6, "no recoil from cover (tap %d)" % (i + 1))
		assert_true(not pawn.cover._draw_active, "quick draw auto-returns before next tap")
		assert_true(not Input.is_action_pressed("jump") and not touch.provider.sprint_locked, "cover FIRE never drives movement buttons")
		assert_eq(rig.shoulder_side, shoulder, "cover FIRE never swaps shoulder")
	print("A2 RELIABILITY green FIRE 10/10")
	await cleanup()

## M2 C1b stage 3: was test_free_controls_restore_and_cover_buttons_are_not_hittable; the old squares' visibility and
## hit-circle checks are gone (the HUD never creates them). The exit is the away push held exit_away_hold_s.
func test_free_controls_restore_after_cover() -> void:
	await setup(Vector2i(2176, 1812), 373.0)
	# Leave through real movement away from the wall, then stand in open ground.
	touch.provider.move_value = Vector2(0, 1)
	await frames(50)
	touch.provider.move_value = Vector2.ZERO
	await frames(15)
	assert_eq(pawn.cover.state, CoverController.State.FREE, "real exit to open ground")
	touch.provider.move_value = Vector2.ZERO
	await frames(45)
	# M2 C1b stage 1: on the ground the Shoulder slot is the visible Cover button (C1a hid the Shoulder there).
	# M2 H1c (OQ-SPRINT-LOCK): the Sprint lock button is hidden until sprint is locked (was: lock_button.visible).
	assert_true(touch._buttons["jump"].visible and touch._buttons["swap_shoulder"].visible and touch._action_of("swap_shoulder") == "cover" and not touch.lock_button.visible, "normal controls visible again, the slot is the Cover button")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), true)
	await frames(3)
	assert_true(pawn.velocity.y > 0, "restored Jump jumps")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), false)
	await frames(45)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var side := rig.shoulder_side
	var shots_before := shots
	await hold_tap(touch._buttons["swap_shoulder"].get_global_rect().get_center())
	# M2 C1b stage 1: the slot is the Cover button; out of its reach a press does nothing (no swap, no shot, no entry).
	assert_true(rig.is_first_person() and rig.shoulder_side == side and shots == shots_before and pawn.cover.state == CoverController.State.FREE, "Cover slot out of reach does nothing")
	# M2 H1c (OQ-SPRINT-LOCK): was a tap on the button while moving forward; now the push-and-lift on the Lock target.
	await lock_by_target()
	assert_true(touch.provider.sprint_locked and touch.lock_button.visible, "restored Sprint lock locks")
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(not touch.provider.sprint_locked and not touch.lock_button.visible, "restored Sprint lock unlocks")
	await cleanup()

## M2 C1b stage 4: was test_look_and_optional_left_fire_general_action_only_outside_cover.
## M2 H1a: was test_look_fires_only_outside_cover_and_left_fire_also_in_cover; a look-zone hold now never fires.
func test_look_never_fires_and_left_fire_fires_in_and_out_of_cover() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	AppFlow.profile["left_fire_enabled"] = true
	touch.refresh_left_fire()
	for covered in [true, false]:
		if not covered:
			touch.provider.move_value = Vector2(0, 1)
			await frames(50)
			touch.provider.move_value = Vector2.ZERO
			await frames(15)
		for point in [Vector2(touch.size.x * 0.95, touch.size.y * 0.7), touch._buttons["fire_left"].get_global_rect().get_center()]:
			var before := shots
			event_at(point, true)
			await frames(20)
			# M2 H1a: only the Fire buttons press "fire", in and out of cover; the look-zone hold never does.
			# Was (C1b stage 4): the look-zone hold pressed "fire" outside cover only.
			var is_look: bool = point != touch._buttons["fire_left"].get_global_rect().get_center()
			assert_eq(Input.is_action_pressed("fire"), not is_look, "fire pressed by look=%s covered=%s" % [is_look, covered])
			event_at(point, false)
			await frames(12)
			if is_look:
				assert_eq(shots, before, "a look-zone hold never shoots (covered=%s)" % covered)
			else:
				assert_true(shots > before, "Left Fire shoots in and out of cover (covered=%s)" % covered)
			await frames(30)  # the return from the lean before the next press
	await cleanup()

## M2 C1b stage 3 (decision 8): the forward-extreme drag itself no longer leaves cover (it did: "transient Sprint
## press leaves cover"); the target stays reachable and releasing on it (the Sprint lock) exits.
func test_transient_sprint_target_cover_result_recorded_open() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	var origin: Vector2 = touch.get_move_rest()
	event_at(origin, true)
	await frames(1)
	var target: Vector2 = touch.get_lock_target_rect().get_center()
	var drag := InputEventScreenDrag.new()
	drag.index = 41
	drag.position = tree().root.get_screen_transform() * target
	drag.relative = tree().root.get_screen_transform().basis_xform(target - origin)
	tree().root.push_input(drag, false)
	await frames(2)
	assert_true(touch.provider.lock_target_visible(), "transient target available on forward gesture")
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "the forward gesture alone stays in cover")
	event_at(target, false)
	await frames(2)
	assert_true(touch.provider.sprint_locked, "release on the target locks sprint")
	assert_true(pawn.cover.state == CoverController.State.EXITING or pawn.cover.state == CoverController.State.FREE, "the Sprint lock leaves cover")
	print("A2 DECIDED (C1b) the forward gesture stays in cover; the Sprint lock leaves it")
	await cleanup()

func test_vf_timing_live_window_tap_motion_bounds_and_probe_cost() -> void:
	for edge in [0.01, 0.25, 0.5]:
		await setup(Vector2i(2520, 1080), 420.0, 2.2, edge)
		var start := pawn.position
		var last := start
		var began := pawn.get_clock()
		var previous_clock := began
		var pop := -1.0
		var returned := -1.0
		var return_start := -1.0
		var out_complete := -1.0
		var max_step := 0.0
		# M2 C1b stage 4: a two-frame Fire button tap (was the routed press and release in one frame).
		cover_fire(true)
		for i in 65:
			await frames(1)
			if i == 1:
				cover_fire(false)
			var now := pawn.get_clock()
			var dt := now - previous_clock
			var step := pawn.position.distance_to(last)
			max_step = maxf(max_step, step)
			assert_true(step <= pawn.get_max_move_speed() * dt + 0.0001, "every observed step obeys existing speed bound")
			if pop < 0.0 and pawn.position.distance_to(start) > 0.0001:
				pop = now - began
			if pawn.cover.aimed_out and out_complete < 0.0:
				out_complete = now - began
			if pawn.cover._draw_returning and return_start < 0.0:
				return_start = now - began
			if pop >= 0.0 and return_start < 0.0:
				assert_true(pawn.position.x + 0.0001 >= last.x, "lean out monotonic")
			if return_start >= 0.0:
				assert_true(pawn.position.x <= last.x + 0.0001, "return monotonic")
			if return_start >= 0.0 and returned < 0.0 and pawn.position.distance_to(start) < 0.01:
				returned = now - began
			last = pawn.position
			previous_clock = now
		print("A2 VF TIME edge=%.2f pop=%.4f shot=%.4f pose=%.4f return_start=%.4f return_end=%.4f max_observed_step=%.5f" % [edge, pop, first_shot_s - began, out_complete, return_start, returned, max_step])
		assert_true(pop >= 0.0 and pop < 0.1 and first_shot_s > began, "prompt live input and real shot")
		assert_true(out_complete >= 0.12 and out_complete <= 0.2 + 0.0001, "completed standing lean within 0.12-0.2s")
		assert_true(returned - return_start >= 0.12 - 0.0001 and returned - return_start <= 0.2 + 0.0001, "return transition 0.12-0.2s")
		var total := 0
		var peak := 0
		for i in 100:
			var t0 := Time.get_ticks_usec()
			pawn._cover_probe.sample(pawn, pawn.cover.config, true)
			var elapsed := Time.get_ticks_usec() - t0
			total += elapsed
			peak = maxi(peak, elapsed)
		print("A2 VF PROBE full real match map retained; 100 samples mean_us=%.2f max_us=%d" % [float(total) / 100.0, peak])
		# Also measure an actual map wall, not only the isolated fixture wall.
		for body in tree().get_nodes_in_group(&"cover_wall"):
			if not match_scene.map.is_ancestor_of(body):
				continue
			var shape := body.get_node_or_null("Shape") as CollisionShape3D
			if shape == null or not shape.shape is BoxShape3D:
				continue
			var half: Vector3 = shape.shape.size * 0.5
			if half.y * 2.0 < float(pawn.cover.config["min_cover_height_m"]):
				continue
			var probe := CoverProbe.new()
			probe._wall = body
			probe._normal = Vector3.BACK
			pawn.global_position = shape.global_position + Vector3(0, -half.y, half.z + float(pawn.cover.config["wall_offset_m"]))
			var facts := probe.sample(pawn, pawn.cover.config, true)
			if not facts["hit"]:
				continue
			total = 0
			peak = 0
			for i in 100:
				var t0 := Time.get_ticks_usec()
				probe.sample(pawn, pawn.cover.config, true)
				var elapsed := Time.get_ticks_usec() - t0
				total += elapsed
				peak = maxi(peak, elapsed)
			print("A2 VF ACTUAL MAP WALL %s; 100 samples mean_us=%.2f max_us=%d" % [body.name, float(total) / 100.0, peak])
			break
		await cleanup()

func test_vf_muzzle_wall_guard_spends_no_ammo() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	# An additional near cover collider spans the completed lean's muzzle ray.
	box(Vector3(1000, 1.5, -1.5), Vector3(20, 3, 0.2))
	await frames(2)
	var weapon := pawn.loadout.get_active()
	var ammo := weapon.ammo_in_mag
	await fire_tap()
	await frames(45)
	assert_true(not pawn._cover_probe.shot_clear(pawn), "muzzle ray hits cover wall")
	assert_eq(shots, 0, "wall guard blocks shots")
	assert_eq(weapon.ammo_in_mag, ammo, "wall guard preserves ammo")
	cover_fire(false, true)
	await cleanup()

func test_vf_rest_weapon_hands_player_side_and_back_to_wall() -> void:
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 2.0)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	# M2 C1b stage 2: the stance is automatic (HIGH 2.2 m wall: standing; was both stances via Crouch taps), and the
	# rest pose hugs the wall: facing along it toward the cover side, turned out by animation.hug_out_deg, back and
	# shoulder to the wall (was: back flat to the wall, forward == normal).
	for stance in [false]:
		await frames(45)
		assert_eq(pawn.cover.crouched, stance, "high cover: standing")
		var normal := pawn.cover.normal
		var plane := pawn.cover.wall_point
		var forward := -model.global_basis.z
		var out := deg_to_rad(float(pawn.cover.config["animation"]["hug_out_deg"]))
		var hug := (pawn.cover.tangent * float(pawn.cover.side) * cos(out) + normal * sin(out)).normalized()
		assert_true(forward.dot(hug) > 0.99, "rest pose hugs the wall, facing along it")
		assert_true(forward.dot(normal) > 0.0, "rest pose back toward the wall")
		var margin := float(pawn.cover.config["motion_epsilon_m"])
		var points: Array[Vector3] = [model.barrel_tip.global_position, model.foregrip.global_position]
		for bone in ["RightUpperArm", "RightForeArm", "RightHand", "LeftHand"]:
			points.append(model.skeleton.global_transform * model.skeleton.get_bone_global_pose(model.skeleton.find_bone(bone)).origin)
		var bounds := model.rifle.get_aabb()
		for i in 8:
			points.append(model.rifle.global_transform * bounds.get_endpoint(i))
		var minimum := INF
		for point in points:
			minimum = minf(minimum, (point - plane).dot(normal))
			assert_true((point - plane).dot(normal) >= margin, "rest arm/hand/weapon remains on player side of wall with epsilon margin")
		print("A2 VF REST crouch=%s minimum_plane_clearance_m=%.5f yaw=%.5f" % [stance, minimum, model.rotation.y])
	await cleanup()

func test_vf_crouched_first_shot_measured_without_changing_reserved_blend() -> void:
	# M2 C1b stage 2 (decision 7): behind HIGH cover the soldier always stands, so the crouched first shot is now behind
	# a LOW 1.1 m wall (crouched automatically; was a 2.2 m wall plus a Crouch tap).
	await setup(Vector2i(2520, 1080), 420.0, 1.1, 0.5)
	await frames(15)
	assert_true(pawn.cover.crouched and pawn.cover.crouch_amount == 1.0, "low cover: crouched automatically")
	var began := pawn.get_clock()
	await fire_tap()
	await frames(60)
	assert_eq(shots, 1, "crouched green routed tap fires once")
	assert_true(pawn.cover.crouch_amount == 1.0 and not pawn.cover._draw_active, "automatic return restores crouch")
	assert_eq(pawn.cover.config["crouch_blend_s"], 0.2, "reserved crouch timing unchanged")
	print("A2 OPEN crouched full-band first_shot_s=%.4f (reserved 0.2s rise unchanged)" % (first_shot_s - began))
	await cleanup()

func test_vf_camera_damped_in_cover_and_free_follow_restored() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	var rig := pawn.get_node("CameraRig") as CameraRig
	cover_fire(true)  # M2 C1b stage 4: a two-frame Fire button tap (was the routed press and release in one frame)
	var lag_seen := false
	for i in 12:
		await frames(1)
		if i == 1:
			cover_fire(false)
		lag_seen = lag_seen or absf(rig.global_position.x - pawn.global_position.x) > 0.0001
	assert_true(lag_seen and rig._cover_follow_active, "camera damps translation while cover transitions")
	await frames(45)
	assert_true(absf(rig.global_position.x - pawn.global_position.x) < 0.01, "cover follow settles")
	touch.provider.move_value = Vector2(0, 1)
	await frames(50)
	touch.provider.move_value = Vector2.ZERO
	await frames(3)
	assert_eq(pawn.cover.state, CoverController.State.FREE, "left cover")
	assert_true(not rig._cover_follow_active and rig.position.x == 0.0 and rig.position.z == 0.0, "FREE original follow restored")
	await cleanup()

func test_normal_buttons_work_before_first_cover_entry() -> void:
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 0.25, false)
	# M2 C1b stage 1: before cover entry (first person, on the ground) the Shoulder slot is the visible Cover button.
	# M2 H1c (OQ-SPRINT-LOCK): the Sprint lock button is hidden until sprint is locked (was: lock_button.visible).
	assert_true(touch._buttons["jump"].visible and touch._buttons["swap_shoulder"].visible and touch._action_of("swap_shoulder") == "cover" and not touch.lock_button.visible, "normal slots visible before entry, the slot is the Cover button")
	assert_true("jump" in touch.get_element_keys() and "sprint_lock" in touch.get_element_keys() and "swap_shoulder" in touch.get_element_keys(), "all layout keys restored outside cover")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), true)
	await frames(3)
	assert_true(pawn.velocity.y > 0.0, "Jump works before cover entry")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), false)
	await frames(45)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var side := rig.shoulder_side
	# M2 H1c (OQ-SPRINT-LOCK): was a tap on the button while moving forward; now the push-and-lift on the Lock target.
	await lock_by_target()
	assert_true(touch.provider.sprint_locked and touch.lock_button.visible, "Sprint lock works before entry")
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(not touch.provider.sprint_locked, "Sprint unlock works before entry")
	await frames(20)  # the locked run moved the pawn forward; let the speed ease down
	touch.provider.move_value = Vector2.ZERO
	# M2 C1b stage 1: the slot is the Cover button (C1a swallowed this tap in first person); the wall is in reach.
	await hold_tap(touch._buttons["swap_shoulder"].get_global_rect().get_center())
	assert_true(pawn.cover.state != CoverController.State.FREE and rig.shoulder_side == side, "the Cover slot enters cover and never swaps shoulder")
	assert_eq(shots, 0, "normal movement controls do not fire")
	await cleanup()
