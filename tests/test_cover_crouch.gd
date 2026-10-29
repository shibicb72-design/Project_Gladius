extends "res://tests/test_case.gd"
const DT := 1.0 / 60.0
var root: Node3D
var pawn: Pawn
var wall: StaticBody3D
var shots := 0

func tree() -> SceneTree:
	return Engine.get_main_loop()

func fixture(height: float = 1.1) -> void:
	root = Node3D.new()
	tree().root.add_child(root)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	wall = add_wall(Vector3(0, height / 2.0, -0.5), Vector3(4, height, 1))
	pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.position = Vector3(0, 0, 0.6)
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	pawn.loadout.get_active().fire_mode = "semi"
	pawn.shot.connect(func(origin: Vector3, direction: Vector3, _id: String):
		shots += 1
		var range_m := pawn.loadout.get_active().def.range_m
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * range_m, 1, [pawn.get_rid()])
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
		assert_true(hit.is_empty() or not hit["collider"].is_in_group(&"cover_wall"), "EVERY cover shot clears wall for full weapon range")
		assert_true(pawn.cover.crouch_amount == 0.0, "every cover shot leaves standing lean-out")
	)
	shots = 0
	await tree().physics_frame
	await ticks(60, Vector2(0, -1))
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "fixture snaps")

func add_wall(at: Vector3, dimensions: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.add_to_group(&"cover_wall")
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = dimensions
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body

func tick(move: Vector2 = Vector2.ZERO, aim: bool = false, fire: bool = false) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.aim_pressed = aim
	frame.fire_pressed = fire
	frame.fire_just_pressed = fire and not pawn._frame.fire_pressed
	pawn.set_frame(frame)
	var previous := pawn.global_position
	pawn._physics_process(DT)
	assert_true(NetValidator.new().validate_move(previous, pawn.global_position, DT, pawn.get_max_move_speed(), float(pawn._movement["jump_velocity"]), pawn.floor_max_angle), "all CR1 motion passes unchanged host speed validator")
	await tree().physics_frame

func ticks(count: int, move: Vector2 = Vector2.ZERO, aim: bool = false, fire: bool = false) -> void:
	for i in count:
		await tick(move, aim, fire)

func cleanup() -> void:
	root.queue_free()
	await tree().process_frame

func no_shape_clip() -> void:
	for shape: CollisionShape3D in [pawn.get_node("CollisionShape3D"), pawn.get_node("Head/CollisionShape3D")]:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = shape.global_transform
		query.collision_mask = 1
		query.exclude = [pawn.get_rid()]
		for hit in pawn.get_world_3d().direct_space_state.intersect_shape(query):
			assert_true(not hit["collider"].is_in_group(&"cover_wall"), "capsule/head never intersect cover")

func test_crouch_blend_shapes_animation_and_standing_restore() -> void:
	await fixture()
	var other: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	other.position.x = 10
	root.add_child(other)
	other.set_physics_process(false)
	var original := other.get_node("CollisionShape3D").shape as CapsuleShape3D
	var original_height := original.height
	var body := pawn.get_node("CollisionShape3D") as CollisionShape3D
	assert_true(body.shape != original, "shape is per instance")
	pawn.cover.toggle_crouch()
	var duration := float(pawn.cover.config["crouch_blend_s"])
	var previous := 0.0
	var presentation := pawn.get_node("CoverAnim") as CoverAnim
	presentation.set_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for i in ceili(duration / DT) + 1:
		await tick()
		var amount := pawn.cover.crouch_amount
		assert_true(amount >= previous and amount - previous <= DT / duration + 0.00001, "linear monotonic blend within one-tick bound")
		presentation.sync_pose(DT)
		model.animation_tree.advance(DT)
		assert_true(is_equal_approx(float(model.animation_tree.get("parameters/cover/cover_idle_r/crouch/blend_amount")), amount), "AnimationTree follows amount")
		no_shape_clip()
		previous = amount
	assert_true(is_equal_approx(previous, 1.0), "crouch reaches one within one tick")
	assert_true(body.position.y + (body.shape as CapsuleShape3D).height / 2.0 < 1.1, "capsule under 1.1m top")
	var head := pawn.get_node("Head") as Node3D
	assert_true(head.position.y + (pawn.get_node("Head/CollisionShape3D").shape as SphereShape3D).radius < 1.1, "Head under 1.1m top")
	var head_bone := model.skeleton.global_transform * model.skeleton.get_bone_global_pose(model.skeleton.find_bone("Head")).origin
	assert_true(head_bone.distance_to(head.global_position) < 0.0001, "skeleton Head follows lowered hitbox: bone=%s hitbox=%s" % [head_bone, head.global_position])
	assert_eq(original.height, original_height, "other pawn unchanged")
	pawn.cover.toggle_crouch()
	await ticks(14)
	assert_true(is_equal_approx((body.shape as CapsuleShape3D).height, 1.6), "standing capsule restored")
	assert_true(is_equal_approx(head.position.y, 1.75), "standing Head restored")
	await cleanup()

class FakeGyro extends PlatformServices:
	func has_gyro() -> bool:
		return true
	func get_gyro_rate() -> Vector3:
		return Vector3(0, 0.25, 0)

func router_tick(router: InputRouter) -> void:
	router.set_ads(pawn.aim_blend > 0.0)
	pawn.set_frame(router.update_frame(DT))
	pawn._physics_process(DT)
	await tree().physics_frame

func test_real_aim_latch_and_gyro_modes_while_leaned() -> void:
	await fixture(2.2)
	await ticks(100, Vector2(0.49, 0))
	var router := InputRouter.new()
	router.add_provider(KeyboardMouseProvider.new())
	var gyro := GyroProvider.new()
	gyro._platform = FakeGyro.new()
	gyro.configure({"gyro_mode": "scope_on"})
	router.add_provider(gyro)
	Input.action_press("aim")
	await router_tick(router)
	Input.action_release("aim")
	for i in 120:
		await router_tick(router)
	assert_true(pawn.cover.aimed_out and pawn.aiming, "one real Aim tap stays leaned and zoomed two seconds")
	assert_eq(shots, 0, "Aim latch and ADS gyro never fire")
	var yaw := pawn.rotation.y
	await router_tick(router)
	assert_true(pawn.rotation.y != yaw, "scope_on gyro turns aim while Aim-leaned")
	pawn.cover.set_look_active(true)
	Input.action_press("aim")
	await router_tick(router)
	Input.action_release("aim")
	for i in 30:
		await router_tick(router)
	assert_true(not pawn.aiming and pawn.cover.aimed_out, "Aim off while drag held keeps lean")
	yaw = pawn.rotation.y
	await router_tick(router)
	assert_eq(pawn.rotation.y, yaw, "scope_on does not turn quick/drag lean without ADS")
	gyro.configure({"gyro_mode": "always_on"})
	await router_tick(router)
	assert_true(pawn.rotation.y != yaw, "always_on steers unzoomed lean")
	Input.action_press("fire")
	for i in 60:
		await router_tick(router)
	Input.action_release("fire")
	assert_eq(shots, 0, "look/Left Fire/general fire action cannot shoot during drag lean")
	pawn.cover.set_look_active(false)
	gyro.configure({"gyro_mode": "off"})
	for i in 40:
		await router_tick(router)
	assert_true(not pawn.cover.aimed_out, "drag release returns after second Aim tap")
	router.free()
	await cleanup()

func touch_event(index: int, at: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = down
	tree().root.push_input(event, true)

func test_context_buttons_real_match_routing_clearance_and_cancel() -> void:
	var old_size := tree().root.size
	var old_profile := AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(1512, 648)
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	tree().root.add_child(match_scene)
	await tree().physics_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	await tree().process_frame
	await tree().process_frame
	var local := match_scene.local_player
	local.set_physics_process(false)
	local.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var touch: Control = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	var crouch := match_scene.hud.cover_crouch_button
	var fire := match_scene.hud.cover_fire_button
	for button in [crouch, fire]:
		button.refresh()
		assert_true(not button.visible, "context control hidden in FREE")
		assert_true(button.get_parent() == touch.get_parent() and button.get_index() > touch.get_index(), "context sibling after TouchHud")
		assert_true(button.process_physics_priority < local.process_physics_priority, "context state forwarded before pawn physics")
	local.cover.state = CoverController.State.IN_COVER
	local.cover._facts = {"height_m": 1.1, "muzzle_height_m": 1.3, "stand_clear": true}
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	for dpi in [420.0, 373.0]:
		PlatformServices.dpi_override = dpi
		for view in [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]:
			touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			touch.size = view
			touch.relayout()
			for button in [crouch, fire]:
				button.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
				button.size = view
				button.refresh()
				var rect: Rect2 = button.get_touch_rect()
				assert_true(button.visible and rect.size.x / PlatformServices.new().get_dp_scale() >= 48.0, "visible contextual 48dp target")
				assert_true(Rect2(Vector2.ZERO, view).encloses(rect), "context control on-screen")
				var reserved: Array[Rect2] = [PauseMenu.gear_touch_rect(ui["pause_gear"], view), FireModeButton.touch_rect(ui["fire_mode_button"], view)]
				for key in touch.get_element_keys():
					reserved.append(touch.get_element_rect(key))
				for other_rect in reserved:
					assert_true(not rect.intersects(other_rect), "context control clear of gear/mode/all TouchHud elements")
			assert_true(not crouch.get_touch_rect().intersects(fire.get_touch_rect()), "context controls do not overlap")
	PlatformServices.dpi_override = 0.0
	for button in [crouch, fire]:
		button.size = Vector2(1512, 648)
		button._place()
	touch.size = Vector2(1512, 648)
	touch.relayout()
	touch_event(8, crouch.get_touch_rect().get_center(), true)
	touch_event(8, crouch.get_touch_rect().get_center(), false)
	assert_true(local.cover.crouched, "routed crouch tap toggles once")
	assert_eq(touch._look_touch, -1, "crouch touch consumed")
	var point := fire.get_touch_rect().get_center()
	touch_event(9, point, true)
	assert_true(local.cover._quick_held, "context FIRE owns held input")
	assert_eq(touch._look_touch, -1, "FIRE press consumed")
	assert_true(not Input.is_action_pressed("fire"), "context FIRE never presses general action")
	var drag := InputEventScreenDrag.new()
	drag.index = 9
	drag.position = point + Vector2(100, 100)
	drag.relative = Vector2(100, 100)
	tree().root.push_input(drag, true)
	assert_eq(touch._look_touch, -1, "captured FIRE drag consumed")
	touch_event(9, drag.position, false)
	assert_true(not local.cover._quick_held and local.cover._buffered_round, "release preserves buffered tap")
	for interruption in ["hide", "suspend", "pause", "death"]:
		local.cover.quick_draw(true)
		match interruption:
			"hide": fire.hide()
			"suspend": touch.set_suspended(true)
			"pause": match_scene.pause_menu.open()
			"death": local.bridge.state.health = 0; local.bridge.state.shield = 0
		fire.refresh() if interruption != "hide" else fire._release(true)
		assert_true(not local.cover._quick_held and not local.cover._buffered_round, "interruption cancels FIRE: " + interruption)
		if interruption == "pause":
			match_scene.pause_menu.close()
		if interruption == "suspend":
			touch.set_suspended(false)
		fire.refresh()
	match_scene.queue_free()
	tree().root.size = old_size
	AppFlow.profile = old_profile
	await tree().process_frame
	await tree().process_frame

func test_overhang_refuses_stand_and_low_wall_quick_tap_rises_then_returns() -> void:
	await fixture()
	pawn.cover.toggle_crouch()
	await ticks(14)
	var roof := add_wall(Vector3(0, 1.45, 0.5), Vector3(1.5, 0.2, 1.0))
	await ticks(2)
	pawn.cover.toggle_crouch()
	await ticks(20)
	assert_true(pawn.cover.crouched and pawn.cover.crouch_amount == 1.0, "stand refused under overhang")
	roof.queue_free()
	await ticks(2)
	assert_true(pawn.cover.can_quick_draw(), "low cover green at mid-wall")
	pawn.cover.quick_draw(true)
	pawn.cover.quick_draw(false)
	for i in 60:
		await tick()
		no_shape_clip()
	assert_eq(shots, 1, "released buffered semi tap shoots exactly once after rise")
	assert_true(pawn.cover.crouch_amount == 1.0 and not pawn.cover.aimed_out, "returns automatically to prior crouch")
	await cleanup()

func test_high_midwall_red_press_and_aim_levels_edge_drag_and_fullauto() -> void:
	await fixture(2.2)
	var start := pawn.global_position
	var ammo := pawn.loadout.get_active().ammo_in_mag
	assert_true(not pawn.cover.can_quick_draw(), "high mid-wall red")
	pawn.cover.quick_draw(true)
	await ticks(60, Vector2.ZERO, true, true)
	assert_true(pawn.aiming and pawn.aim_blend == 1.0, "ADS still zooms at red mid-wall")
	assert_true(pawn.global_position.distance_to(start) < 0.0001, "red press / midwall Aim cannot move pawn")
	assert_eq(shots, 0, "red press and general fire do not shoot")
	assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "no ammo spent")
	var button := CoverFireButton.new()
	button.bind(pawn, null, null)
	tree().root.add_child(button)
	button.set_physics_process(false)
	button.set_process(false)
	var fire_cfg: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["cover_fire"]
	var red: Array = fire_cfg["disabled_color"]
	var green: Array = fire_cfg["enabled_color"]
	button.refresh()
	assert_eq(button.label.self_modulate, Color(red[0], red[1], red[2], red[3]), "red equals data colour")
	# Red press still held: sliding into the band must not promote it.
	for i in 100:
		await tick(Vector2(0.49, 0))
		button.refresh()
		assert_eq(button.enabled, pawn.cover.can_quick_draw(), "colour/reach updates within crossing tick")
		var expected: Array = green if pawn.cover.can_quick_draw() else red
		assert_eq(button.label.self_modulate, Color(expected[0], expected[1], expected[2], expected[3]), "colour always equals data")
	assert_true(pawn.cover.can_quick_draw(), "slide reaches green usable edge")
	assert_eq(shots, 0, "red press not promoted while held")
	pawn.cover.quick_draw(false)
	button.queue_free()
	await tree().process_frame
	pawn.cover.set_look_active(true)
	await ticks(30)
	assert_true(pawn.cover.aimed_out and not pawn.cover.blocks_fire(), "drag lean clears high wall")
	assert_eq(shots, 0, "drag never fires")
	pawn.cover.quick_draw(true)
	await tick()
	pawn.cover.quick_draw(false)
	assert_eq(shots, 1, "FIRE during drag shoots immediately")
	await ticks(20)
	pawn.loadout.get_active().fire_mode = "auto"
	pawn.cover.quick_draw(true)
	await ticks(60)
	pawn.cover.quick_draw(false)
	var after := shots
	assert_true(after >= 6 and after <= 8, "auto while held at weapon data interval")
	await ticks(20)
	assert_eq(shots, after, "auto stops on release while drag holds pose")
	pawn.cover.set_look_active(false)
	await ticks(40)
	assert_true(not pawn.cover.aimed_out and pawn.global_position.x < 2, "drag release returns to anchor")
	await cleanup()

func test_aim_holds_without_fire_and_delayed_semi_round_stays_out() -> void:
	await fixture()
	pawn.cover.toggle_crouch()
	await ticks(14)
	await ticks(120, Vector2.ZERO, true, true)
	assert_true(pawn.cover.aimed_out and pawn.cover.crouch_amount == 0.0, "Aim rises and stays for two seconds")
	assert_eq(shots, 0, "Aim plus general fire never shoots")
	pawn.cover.set_look_active(true)
	await ticks(20, Vector2.ZERO, false)
	assert_true(pawn.cover.aimed_out, "drag holds after Aim off")
	pawn.cover.quick_draw(true)
	await tick()
	pawn.cover.quick_draw(false)
	await ticks(6)
	pawn.cover.quick_draw(true)
	await tick()
	pawn.cover.quick_draw(false)
	pawn.cover.set_look_active(false)
	await ticks(3)
	assert_true(pawn.cover.aimed_out, "second semi round armed within interval keeps pose out")
	await ticks(60)
	assert_eq(shots, 2, "delayed second round leaves clear lean pose")
	assert_true(pawn.cover.crouch_amount == 1.0, "returns only after locked round")
	await cleanup()

func test_joined_edges_and_turning_back_into_wall_blocks_even_without_pose_gate() -> void:
	await fixture(2.2)
	var joined := add_wall(Vector3(4, 1.1, -0.5), Vector3(4, 2.2, 1))
	await ticks(100, Vector2(0.49, 0))
	assert_true(not pawn.cover.can_quick_draw(), "zero-gap joined edge is not usable")
	joined.queue_free()
	await ticks(2)
	assert_true(pawn.cover.can_quick_draw(), "removed neighbor exposes usable end")
	await ticks(30, Vector2.ZERO, true)
	assert_true(pawn.cover.aimed_out, "Aim leans at edge")
	pawn.cover.config["fire_requires_peek"] = false
	# Point diagonally back across the long wall, beyond a short muzzle check.
	pawn.rotation.y = PI / 4.0
	await tick(Vector2.ZERO, true)
	assert_true(pawn.cover.blocks_fire(), "full-range ray blocks glancing shot even without pose requirement")
	pawn.cover.quick_draw(true)
	await ticks(60, Vector2.ZERO, true)
	assert_eq(shots, 0, "wall ray blocks all shots and ammo")
	assert_eq(pawn.loadout.get_active().ammo_in_mag, pawn.loadout.get_active().def.magazine, "blocked ray spends no ammo")
	await cleanup()

func test_legacy_burst_stays_out_until_all_rounds_and_blocked_pending_round_is_preserved() -> void:
	await fixture(2.2)
	await ticks(100, Vector2(0.49, 0))
	var weapon := pawn.loadout.get_active()
	weapon.fire_mode = ""
	pawn.cover.quick_draw(true)
	pawn.cover.quick_draw(false)
	for i in 60:
		await tick()
		no_shape_clip()
	assert_eq(shots, weapon.def.burst_count, "legacy tap completes full burst before return")
	await ticks(30)
	assert_true(not pawn.cover.aimed_out, "legacy burst eventually returns automatically")
	weapon.fire_mode = "semi"
	await ticks(30, Vector2.ZERO, true)
	pawn.cover.quick_draw(true)
	await tick(Vector2.ZERO, true)
	pawn.cover.quick_draw(false)
	await ticks(6, Vector2.ZERO, true)
	pawn.cover.quick_draw(true)
	await tick(Vector2.ZERO, true)
	pawn.cover.quick_draw(false)
	var before := shots
	var ammo := weapon.ammo_in_mag
	pawn.rotation.y = PI / 4.0
	await ticks(30, Vector2.ZERO, true)
	assert_eq(shots, before, "armed semi cannot emit when turned into wall")
	assert_eq(weapon.ammo_in_mag, ammo, "armed semi retains ammo against wall")
	pawn.rotation.y = 0.0
	await ticks(3, Vector2.ZERO, true)
	assert_eq(shots, before + 1, "deferred semi emits once after ray clears")
	await cleanup()
