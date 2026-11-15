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
	# M2 C1b stage 2: the player keeps the view on the wall (Pawn.cancel_cover_turn, what a look input does), so these
	# old-path tests keep their view-relative stick inputs; the automatic turn is tested in test_cover_camera_c1b.gd.
	for i in 60:
		await tick(Vector2(0, -1))
		if pawn.in_cover():
			pawn.cancel_cover_turn()
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "fixture snaps")

## M2 C1b stage 2: resizes the cover wall in place (bottom on the floor); the probe re-reads its height every tick, so
## the automatic crouch follows (LOW iff height < muzzle_height_m).
func set_wall_height(height: float) -> void:
	((wall.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size.y = height
	wall.position.y = height / 2.0

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
	# M2 C1b stage 2: enter behind HIGH cover (standing), then the wall turns LOW (was toggle_crouch) and HIGH again (was
	# the second toggle_crouch); the automatic crouch follows the height with the same blend, shapes and animation.
	await fixture(2.2)
	var other: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	other.position.x = 10
	root.add_child(other)
	other.set_physics_process(false)
	var original := other.get_node("CollisionShape3D").shape as CapsuleShape3D
	var original_height := original.height
	var body := pawn.get_node("CollisionShape3D") as CollisionShape3D
	assert_true(body.shape != original, "shape is per instance")
	assert_eq(pawn.cover.crouch_amount, 0.0, "standing behind high cover")
	set_wall_height(1.1)
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
	set_wall_height(2.2)
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
	# M2 C1b stage 4: the look-drag lean (set_look_active) is gone (was: Aim off while a drag was held kept the lean,
	# and the general fire action could not shoot from it). Aim off now returns; the general fire action (mouse,
	# keyboard, gamepad) leans and fires like the Fire buttons.
	Input.action_press("aim")
	await router_tick(router)
	Input.action_release("aim")
	for i in 30:
		await router_tick(router)
	assert_true(not pawn.aiming and not pawn.cover.aimed_out, "Aim off returns")
	yaw = pawn.rotation.y
	await router_tick(router)
	assert_eq(pawn.rotation.y, yaw, "scope_on does not turn without ADS")
	gyro.configure({"gyro_mode": "always_on"})
	await router_tick(router)
	assert_true(pawn.rotation.y != yaw, "always_on steers unzoomed in cover")
	gyro.configure({"gyro_mode": "off"})
	pawn.rotation.y = 0.0
	Input.action_press("fire")
	for i in 60:
		await router_tick(router)
	Input.action_release("fire")
	assert_true(shots >= 1, "the general fire action (keyboard / mouse / gamepad) leans and fires in cover")
	for i in 40:
		await router_tick(router)
	assert_true(not pawn.cover.aimed_out, "Fire release returns")
	router.free()
	await cleanup()

## M2 C1b stage 3: test_context_buttons_real_match_routing_clearance_and_cancel was deleted here (it pinned the old
## cover Crouch / FIRE squares, which the HUD no longer creates; see docs/ARCHITECTURE.md 4.21 stage 3).

func test_overhang_refuses_stand_and_low_wall_quick_tap_rises_then_returns() -> void:
	await fixture()  # M2 C1b stage 2: LOW 1.1 m wall, crouched automatically (was toggle_crouch)
	await ticks(14)
	assert_true(pawn.cover.crouched and pawn.cover.crouch_amount == 1.0, "low wall: crouched automatically")
	var roof := add_wall(Vector3(0, 1.45, 0.5), Vector3(1.5, 0.2, 1.0))
	await ticks(2)
	set_wall_height(2.2)  # was toggle_crouch (a stand request): the wall turns HIGH, so the automatic rule wants to stand
	await ticks(20)
	assert_true(not pawn.cover.crouched and pawn.cover.crouch_amount == 1.0, "stand refused under overhang")
	set_wall_height(1.1)
	roof.queue_free()
	await ticks(2)
	assert_true(pawn.cover.fire_available(), "low cover green at mid-wall")
	await tick(Vector2.ZERO, false, true)  # M2 C1b stage 4: a one-tick Fire press (was quick_draw(true) / (false))
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
	# M2 C1b stage 4 (fix 7): the reach rule is fire_available (was can_quick_draw); the press is the frame's fire bit
	# (was quick_draw(true)); the drag lean is replaced by the Aim lean (fix 16).
	assert_true(not pawn.cover.fire_available(), "high mid-wall red")
	await ticks(60, Vector2.ZERO, true, true)
	assert_true(pawn.aiming and pawn.aim_blend == 1.0, "ADS still zooms at red mid-wall")
	assert_true(pawn.global_position.distance_to(start) < 0.0001, "red press / midwall Aim cannot move pawn")
	assert_eq(shots, 0, "Fire at red mid-wall does not shoot")
	assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "no ammo spent")
	# Released press: sliding into the band does not promote it.
	for i in 100:
		await tick(Vector2(0.49, 0))
	assert_true(pawn.cover.fire_available(), "slide reaches green usable edge")
	assert_eq(shots, 0, "the red press is not promoted")
	await ticks(30, Vector2.ZERO, true)
	assert_true(pawn.cover.aimed_out and not pawn.cover.blocks_fire(), "Aim lean clears high wall")
	assert_eq(shots, 0, "Aim never fires")
	await tick(Vector2.ZERO, true, true)
	assert_eq(shots, 1, "FIRE during the Aim lean shoots immediately")
	await ticks(20, Vector2.ZERO, true)
	pawn.loadout.get_active().fire_mode = "auto"
	await ticks(60, Vector2.ZERO, true, true)
	var after := shots
	assert_true(after >= 6 and after <= 8, "auto while held at weapon data interval")
	await ticks(20, Vector2.ZERO, true)
	assert_eq(shots, after, "auto stops on release while Aim holds pose")
	await ticks(40)
	assert_true(not pawn.cover.aimed_out and pawn.global_position.x < 2, "Aim off returns to anchor")
	await cleanup()

func test_aim_holds_without_fire_and_delayed_semi_round_stays_out() -> void:
	await fixture()  # M2 C1b stage 2: the 1.1 m wall is LOW, so the pawn is already crouched (was toggle_crouch here)
	await ticks(14)
	# M2 C1b stage 4 (fix 16): Aim alone rises and holds (was: Aim plus the general fire action, which never shot);
	# the drag hold after Aim off is gone, so both semi presses come while Aim is on and Aim goes off right after the
	# second one (was: quick_draw taps during a drag hold).
	await ticks(120, Vector2.ZERO, true)
	assert_true(pawn.cover.aimed_out and pawn.cover.crouch_amount == 0.0, "Aim rises and stays for two seconds")
	assert_eq(shots, 0, "Aim alone never shoots")
	await tick(Vector2.ZERO, true, true)
	assert_eq(shots, 1, "the first semi press fires from the held rise")
	await ticks(6, Vector2.ZERO, true)
	await tick(Vector2.ZERO, true, true)
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
	assert_true(not pawn.cover.fire_available(), "zero-gap joined edge is not usable")
	joined.queue_free()
	await ticks(2)
	assert_true(pawn.cover.fire_available(), "removed neighbor exposes usable end")
	await ticks(30, Vector2.ZERO, true)
	assert_true(pawn.cover.aimed_out, "Aim leans at edge")
	# M2 C1b stage 4: the fire_requires_peek switch is deleted (was set false here); the pose gate is always on, and
	# the full-range ray still blocks on top of it.
	# Point diagonally back across the long wall, beyond a short muzzle check.
	pawn.rotation.y = PI / 4.0
	await tick(Vector2.ZERO, true)
	assert_true(pawn.cover.aimed_out and pawn.cover.blocks_fire(), "full-range ray blocks the glancing shot from the completed pose")
	await ticks(60, Vector2.ZERO, true, true)  # Fire held (was quick_draw(true))
	assert_eq(shots, 0, "wall ray blocks all shots and ammo")
	assert_eq(pawn.loadout.get_active().ammo_in_mag, pawn.loadout.get_active().def.magazine, "blocked ray spends no ammo")
	await cleanup()

func test_legacy_burst_stays_out_until_all_rounds_and_blocked_pending_round_is_preserved() -> void:
	await fixture(2.2)
	await ticks(100, Vector2(0.49, 0))
	var weapon := pawn.loadout.get_active()
	weapon.fire_mode = ""
	await tick(Vector2.ZERO, false, true)  # M2 C1b stage 4: a one-tick Fire press (was quick_draw(true) / (false))
	for i in 60:
		await tick()
		no_shape_clip()
	assert_eq(shots, weapon.def.burst_count, "legacy tap completes full burst before return")
	await ticks(30)
	assert_true(not pawn.cover.aimed_out, "legacy burst eventually returns automatically")
	weapon.fire_mode = "semi"
	await ticks(30, Vector2.ZERO, true)
	# M2 C1b stage 4: two one-tick Fire presses during the Aim lean (were quick_draw taps).
	await tick(Vector2.ZERO, true, true)
	await ticks(6, Vector2.ZERO, true)
	await tick(Vector2.ZERO, true, true)
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
