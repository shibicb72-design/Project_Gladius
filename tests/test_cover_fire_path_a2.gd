extends "res://tests/test_case.gd"
## Real match, live pawn physics and real tagged-wall probe; window-pixel touch routes.
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var fire: CoverFireButton
var crouch: CoverCrouchButton
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
	fire = match_scene.hud.cover_fire_button
	crouch = match_scene.hud.cover_crouch_button
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
		touch.provider.move_value = Vector2(0, -1)
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

func test_rc_live_green_label_window_routes() -> void:
	for screen in [{"size": Vector2i(2520, 1080), "dpi": 420.0}, {"size": Vector2i(2176, 1812), "dpi": 373.0}]:
		for singleton in [false, true]:
			await setup(screen["size"], screen["dpi"])
			assert_true(fire.enabled, "real edge is green before tap")
			var drawn := fire.label.get_global_rect()
			assert_true(drawn.is_equal_approx(fire.get_touch_rect()), "drawn label and hit bounding rect agree")
			assert_true(fire._accept_point(drawn.get_center()), "drawn centre accepted")
			var ammo := pawn.loadout.get_active().ammo_in_mag
			await tap(drawn.get_center(), singleton)
			await frames(65)
			print("A2 RC %s singleton=%s shots=%d buffer=%s position=%s" % [screen["size"], singleton, shots, pawn.cover._buffered_round, pawn.position])
			assert_true(shots >= 1 and pawn.loadout.get_active().ammo_in_mag < ammo, "GREEN window tap fires a real shot")
			assert_true(not pawn.cover._draw_active and not pawn.cover.aimed_out, "tap auto-returns")
			await cleanup()

func test_fb_round_slot_geometry_fold_and_moved_layout() -> void:
	for screen in [{"size": Vector2i(2520, 1080), "dpi": 420.0}, {"size": Vector2i(2176, 1812), "dpi": 373.0}]:
		await setup(screen["size"], screen["dpi"])
		for moved in [false, true]:
			if moved:
				# Move the Sprint slot left; the old HUD-label exclusion still limits its size.
				var center: Vector2 = touch.get_lock_button_rect().get_center() - Vector2(32, 0)
				touch.apply_slot_layout({"sprint_lock": {"pos": [center.x / touch.size.x, center.y / touch.size.y], "size_pct": 100.0, "alpha_pct": 100.0}})
			fire.refresh()
			crouch.refresh()
			var occupied: Array[Rect2] = []
			var ui := DataRegistry.new().load_file("res://data/ui.json")
			var view: Vector2 = touch.size
			occupied.append(FireModeButton.touch_rect(ui["fire_mode_button"], view))
			occupied.append(PauseMenu.gear_touch_rect(ui["pause_gear"], view))
			for anchor in [[0.4, 0.04], [0.6, 0.04]]:
				occupied.append(FireModeButton.touch_rect({"anchor": anchor, "margin_dp": [8, 20], "touch_dp": 48}, view))
			for key in touch.get_element_keys():
				if key not in ["jump", "sprint_lock", "swap_shoulder"]:
					occupied.append(touch.get_element_rect(key))
			for button in [fire, crouch]:
				var rect: Rect2 = button.get_touch_rect()
				var slot: Rect2 = touch.get_button_rect("jump") if button == fire else touch.get_lock_button_rect()
				assert_true(button.is_visible_in_tree() and button.size.x > 0, "context control visibly drawn")
				assert_true(button.size.is_equal_approx(rect.size), "round control node matches drawn square")
				assert_true(rect.get_center().is_equal_approx(slot.get_center()), "context control centred on live replaced slot")
				assert_true(Rect2(Vector2.ZERO, view).encloses(rect) and rect.get_center().x > view.x * 0.5, "right thumb and fully on-screen")
				assert_true(is_equal_approx(rect.size.x, rect.size.y), "circle bounding square")
				var dp := rect.size.x / PlatformServices.new().get_dp_scale()
				assert_true(dp >= 48.0 and dp <= 96.001, "48dp floor and preferred 96dp ceiling")
				for obstacle in occupied:
					assert_true(not rect.intersects(obstacle), "clear of every visible element and former HUD labels: %s vs %s" % [rect, obstacle])
				assert_true(not button._accept_point(rect.position + Vector2.ONE), "corner outside circle is not a hit")
				print("A2 SIZE %s moved=%s %s dp=%s rect=%s" % [screen["size"], moved, button.name, dp, rect])
			assert_true(not fire.get_touch_rect().intersects(crouch.get_touch_rect()), "round controls clear each other")
			assert_true(not touch._buttons["jump"].visible and not touch._buttons["swap_shoulder"].visible and not touch.lock_button.visible, "movement-only controls hidden")
		await cleanup()

func hold_tap(point: Vector2, singleton: bool = false) -> void:
	event_at(point, true, singleton)
	await frames(2)
	event_at(point, false, singleton)
	await frames(2)

func test_aimed_auto_hold_auto_tap_and_semi_tap_preserve_mode() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	await hold_tap(touch._buttons["aim"].get_global_rect().get_center())
	await frames(30)
	assert_true(pawn.aiming and pawn.aim_blend == 1.0 and pawn.cover.aimed_out, "real Aim toggle zooms and holds lean")
	var weapon := pawn.loadout.get_active()
	assert_eq(weapon.fire_mode, "auto", "data default auto")
	var point := fire.label.get_global_rect().get_center()
	event_at(point, true)
	await frames(30)
	event_at(point, false)
	await frames(12)
	assert_true(shots > 1, "held aimed FIRE repeats automatically")
	var before := shots
	await tap(point)
	await frames(12)
	assert_eq(shots - before, 1, "aimed auto tap fires exactly one round")
	assert_eq(weapon.fire_mode, "auto", "FIRE does not change mode")
	weapon.fire_mode = "semi"
	before = shots
	await tap(point)
	await frames(18)
	assert_eq(shots - before, 1, "aimed semi tap fires exactly one round")
	assert_eq(weapon.fire_mode, "semi", "cover control preserves semi")
	await cleanup()

func test_rc_green_auto_tap_during_weapon_interval_is_not_lost() -> void:
	for screen in [{"size": Vector2i(2520, 1080), "dpi": 420.0}, {"size": Vector2i(2176, 1812), "dpi": 373.0}]:
		for singleton in [false, true]:
			await setup(screen["size"], screen["dpi"])
			await hold_tap(touch._buttons["aim"].get_global_rect().get_center())
			await frames(30)
			assert_true(fire.enabled and pawn.cover.aimed_out, "green completed live lean")
			var point := fire.label.get_global_rect().get_center()
			await hold_tap(point, singleton)
			assert_eq(shots, 1, "first green auto tap shoots")
			await tap(point, singleton)
			await frames(20)
			print("A2 RC rapid green auto taps %s singleton=%s shots=%d" % [screen["size"], singleton, shots])
			assert_eq(shots, 2, "second accepted green auto tap survives weapon interval")
			await cleanup()

func test_red_tap_no_queue_and_colour_updates_next_frame_on_live_slide() -> void:
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 2.0)
	assert_true(not fire.enabled, "tall midwall red")
	var start := pawn.position
	await tap(fire.label.get_global_rect().get_center())
	await frames(30)
	assert_true(not pawn.cover._buffered_round and not pawn.cover._quick_held and not pawn.cover._draw_active, "red tap queues nothing")
	assert_true(pawn.position.distance_to(start) < 0.00001 and shots == 0, "red tap never pops or fires")
	touch.provider.move_value = Vector2(0.49, 0)
	var crossed := false
	for i in 100:
		await frames(1)
		fire.refresh()
		assert_eq(fire.enabled, pawn.cover.can_quick_draw(), "colour matches live reach within crossing frame")
		var color: Array = fire.cfg["enabled_color" if fire.enabled else "disabled_color"]
		assert_eq(fire.label.self_modulate, Color(color[0], color[1], color[2], color[3]), "colour is data red/green")
		crossed = crossed or fire.enabled
	touch.provider.move_value = Vector2.ZERO
	await frames(20)
	assert_true(crossed and fire.enabled, "slide reaches green edge band")
	assert_true(shots == 0 and not pawn.cover._buffered_round and not pawn.cover._draw_active, "old red tap is not promoted after green")
	await tap(fire.label.get_global_rect().get_center())
	await frames(60)
	assert_eq(shots, 1, "fresh green tap fires")
	await cleanup()

func test_low_cover_green_fires_at_both_ends_and_middle() -> void:
	for edge in [0.25, 2.0, 3.75]:
		await setup(Vector2i(2176, 1812), 373.0, 1.1, edge)
		assert_true(fire.enabled, "low wall green along entire wall")
		await tap(fire.label.get_global_rect().get_center())
		await frames(60)
		assert_eq(shots, 1, "low wall tap fires once")
		await cleanup()

func test_visible_in_cover_peek_aim_both_stances_and_circle_only_hits() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	for pose in ["rest", "peek", "aim"]:
		if pose == "peek":
			touch.provider.move_value = Vector2(0.6, 0)
			await frames(22)
			assert_eq(pawn.cover.state, CoverController.State.PEEK_RIGHT, "live peek")
		elif pose == "aim":
			touch.provider.move_value = Vector2.ZERO
			await frames(30)
			await hold_tap(touch._buttons["aim"].get_global_rect().get_center())
			await frames(30)
			assert_true(pawn.aiming and pawn.cover.aimed_out, "aim lean")
		for stance in [false, true]:
			if pawn.cover.crouched != stance:
				await tap(crouch.label.get_global_rect().get_center())
				await frames(15)
			assert_eq(pawn.cover.crouched, stance, "real Crouch tap selects stance")
			for button in [fire, crouch]:
				assert_true(button.is_visible_in_tree() and button.size.x > 0, "cover control drawn in %s crouch=%s" % [pose, stance])
				assert_true(Rect2(Vector2.ZERO, touch.size).encloses(button.get_touch_rect()), "button inside canvas")
				var before := shots
				var old_crouch := pawn.cover.crouched
				await tap(button.label.get_global_rect().position + Vector2.ONE)
				await frames(4)
				assert_eq(shots, before, "outside circle never fires")
				assert_eq(pawn.cover.crouched, old_crouch, "outside circle never crouches")
	await cleanup()

func test_cover_slots_do_not_jump_lock_or_swap_and_ten_reliable_taps() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var shoulder := rig.shoulder_side
	for key in ["jump", "sprint_lock", "swap_shoulder"]:
		var rect: Rect2 = touch.get_element_rect(key)
		# Corners of each old square, including points outside the new circles.
		for point in [rect.position + Vector2.ONE, rect.end - Vector2.ONE]:
			await hold_tap(point)
			assert_true(not Input.is_action_pressed("jump") and pawn.velocity.y == 0.0, "hidden Jump cannot jump")
			assert_true(not touch.provider.sprint_locked, "hidden lock cannot toggle")
			assert_eq(rig.shoulder_side, shoulder, "hidden Shoulder cannot swap")
	await frames(65)
	for i in 10:
		var before := shots
		await tap(fire.label.get_global_rect().get_center())
		await frames(65)
		assert_eq(shots - before, 1, "green FIRE tap %d/10" % (i + 1))
		assert_true(not pawn.cover._draw_active, "quick draw auto-returns before next tap")
		var stance := pawn.cover.crouched
		await tap(crouch.label.get_global_rect().get_center())
		await frames(15)
		assert_eq(pawn.cover.crouched, not stance, "Crouch tap %d/10" % (i + 1))
		assert_true(not Input.is_action_pressed("jump") and not touch.provider.sprint_locked, "replacement circles never drive movement buttons")
		assert_eq(rig.shoulder_side, shoulder, "replacement circles never swap shoulder")
	print("A2 RELIABILITY green FIRE 10/10; Crouch 10/10")
	await cleanup()

func test_free_controls_restore_and_cover_buttons_are_not_hittable() -> void:
	await setup(Vector2i(2176, 1812), 373.0)
	var previous := fire.get_touch_rect()
	# Leave through real movement away from the wall, then stand in open ground.
	touch.provider.move_value = Vector2(0, 1)
	await frames(50)
	touch.provider.move_value = Vector2.ZERO
	await frames(15)
	assert_eq(pawn.cover.state, CoverController.State.FREE, "real exit to open ground")
	for running in [false, true]:
		touch.provider.move_value = Vector2(0, -0.3) if running else Vector2.ZERO
		await frames(2)
		assert_true(not fire.is_visible_in_tree() and not crouch.is_visible_in_tree(), "no cover control outside cover")
		assert_true(not fire._accept_point(previous.get_center()), "old FIRE circle not hittable")
		var before := shots
		await hold_tap(previous.get_center())
		assert_eq(shots, before, "tap on former FIRE slot does not use FIRE")
	touch.provider.move_value = Vector2.ZERO
	await frames(45)
	assert_true(touch._buttons["jump"].visible and touch._buttons["swap_shoulder"].visible and touch.lock_button.visible, "normal controls visible again")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), true)
	await frames(3)
	assert_true(pawn.velocity.y > 0, "restored Jump jumps")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), false)
	await frames(45)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var side := rig.shoulder_side
	await hold_tap(touch._buttons["swap_shoulder"].get_global_rect().get_center())
	assert_true(rig.shoulder_side != side, "restored Shoulder swaps")
	touch.provider.move_value = Vector2(0, -0.3)
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(touch.provider.sprint_locked, "restored Sprint lock locks")
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(not touch.provider.sprint_locked, "restored Sprint lock unlocks")
	await cleanup()

func test_look_and_optional_left_fire_general_action_only_outside_cover() -> void:
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
			assert_eq(Input.is_action_pressed("fire"), not covered, "general fire action gated at HUD in cover")
			event_at(point, false)
			await frames(12)
			if covered:
				assert_eq(shots, before, "only contextual FIRE can shoot in cover")
			else:
				assert_true(shots > before, "normal fire source shoots outside cover")
	await cleanup()

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
	event_at(target, false)
	await frames(2)
	assert_true(touch.provider.sprint_locked, "record current transient sprint behavior, not a new product decision")
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "transient lock does not leave cover")
	print("A2 OPEN transient Sprint target CAN lock sprint in cover")
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
		event_at(fire.label.get_global_rect().get_center(), true)
		event_at(fire.label.get_global_rect().get_center(), false)
		for i in 65:
			await frames(1)
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
	await tap(fire.label.get_global_rect().get_center())
	await frames(45)
	assert_true(not pawn._cover_probe.shot_clear(pawn), "muzzle ray hits cover wall")
	assert_eq(shots, 0, "wall guard blocks shots")
	assert_eq(weapon.ammo_in_mag, ammo, "wall guard preserves ammo")
	fire._release(true)
	await cleanup()

func test_vf_rest_weapon_hands_player_side_and_back_to_wall() -> void:
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 2.0)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	for stance in [false, true]:
		if pawn.cover.crouched != stance:
			await tap(crouch.label.get_global_rect().get_center())
		await frames(45)
		var normal := pawn.cover.normal
		var plane := pawn.cover.wall_point
		var forward := -model.global_basis.z
		assert_true(forward.dot(normal) > 0.99, "rest pose back faces wall")
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
	await setup(Vector2i(2520, 1080), 420.0, 2.2, 0.5)
	await tap(crouch.label.get_global_rect().get_center())
	await frames(15)
	var began := pawn.get_clock()
	await tap(fire.label.get_global_rect().get_center())
	await frames(60)
	assert_eq(shots, 1, "crouched green viewport tap fires once")
	assert_true(pawn.cover.crouch_amount == 1.0 and not pawn.cover._draw_active, "automatic return restores crouch")
	assert_eq(pawn.cover.config["crouch_blend_s"], 0.2, "reserved crouch timing unchanged")
	print("A2 OPEN crouched full-band first_shot_s=%.4f (reserved 0.2s rise unchanged)" % (first_shot_s - began))
	await cleanup()

func test_vf_camera_damped_in_cover_and_free_follow_restored() -> void:
	await setup(Vector2i(2520, 1080), 420.0)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var point := fire.label.get_global_rect().get_center()
	event_at(point, true)
	event_at(point, false)
	var lag_seen := false
	for i in 12:
		await frames(1)
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
	assert_true(not fire.is_visible_in_tree() and not crouch.is_visible_in_tree(), "context controls hidden before entry")
	assert_true(touch._buttons["jump"].visible and touch._buttons["swap_shoulder"].visible and touch.lock_button.visible, "normal slots visible before entry")
	assert_true("jump" in touch.get_element_keys() and "sprint_lock" in touch.get_element_keys() and "swap_shoulder" in touch.get_element_keys(), "all layout keys restored outside cover")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), true)
	await frames(3)
	assert_true(pawn.velocity.y > 0.0, "Jump works before cover entry")
	event_at(touch._buttons["jump"].get_global_rect().get_center(), false)
	await frames(45)
	var rig := pawn.get_node("CameraRig") as CameraRig
	var side := rig.shoulder_side
	await hold_tap(touch._buttons["swap_shoulder"].get_global_rect().get_center())
	assert_true(rig.shoulder_side != side, "Shoulder works before cover entry")
	touch.provider.move_value = Vector2(0, -0.3)
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(touch.provider.sprint_locked, "Sprint lock works before entry")
	await hold_tap(touch.lock_button.get_global_rect().get_center())
	assert_true(not touch.provider.sprint_locked, "Sprint unlock works before entry")
	assert_eq(shots, 0, "normal movement controls do not fire")
	await cleanup()
