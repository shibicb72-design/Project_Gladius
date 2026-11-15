extends "res://tests/test_case.gd"
## FIRE FIX: real match, live physics, window-pixel input via root viewport.
## M2 C1b stage 3: the HUD no longer creates the old cover FIRE / Crouch squares. Their layout tests (test_l_*) are
## deleted; the shot tests drive the routed "cover_fire" press directly (TouchProvider.trigger_action /
## release_action, the path those squares used) until stage 4 moves Fire in cover to the normal Fire buttons.
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var shots := 0
var first_shot_s := -1.0
var old_size: Vector2i
var old_profile: Dictionary
var old_dpi: float
const SCREENS := [{"size": Vector2i(2520, 1080), "dpi": 420.0}, {"size": Vector2i(2176, 1812), "dpi": 373.0}]

func tree() -> SceneTree:
	return Engine.get_main_loop()

func frames(count: int) -> void:
	for i in count:
		await tree().physics_frame
		await tree().process_frame

func box(at: Vector3, dimensions: Vector3, tagged: bool) -> void:
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

## M2 C1b stage 3: view_on_wall false keeps the automatic entry turn (the view then looks along the wall).
func setup(screen: Dictionary, edge: float = 0.25, enter: bool = true, view_on_wall: bool = true) -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {}
	PlatformServices.dpi_override = screen["dpi"]
	tree().root.size = screen["size"]
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
	box(Vector3(1000, -0.1, 0), Vector3(30, 0.2, 30), false)
	box(Vector3(1000, 1.1, -0.5), Vector3(4, 2.2, 1), true)
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
		if view_on_wall:
			pawn.cancel_cover_turn()  # M2 C1b stage 2: the view stays on the wall (as a look input would keep it)
		await frames(60)
	touch.provider.move_value = Vector2.ZERO
	touch.provider.cancel_sprint_lock()
	await frames(4)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER if enter else CoverController.State.FREE, "fixture live cover state")

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

func event_at(point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 41
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)

func drag_to(point: Vector2, relative: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 41
	event.position = tree().root.get_screen_transform() * point
	event.relative = tree().root.get_screen_transform().basis_xform(relative)
	tree().root.push_input(event, false)

func tap(point: Vector2) -> void:
	event_at(point, true)
	await frames(2)
	event_at(point, false)
	await frames(2)

## The routed cover FIRE press / release (what the old square sent).
func cover_fire(down: bool) -> void:
	if down:
		touch.provider.trigger_action("cover_fire")
	else:
		touch.provider.release_action("cover_fire", false)

## M2 C1b stage 3: the press is routed instead of tapped on the old square, and the crouched pass (a Crouch tap,
## ignored in cover since stage 2) is gone: one standing pass per edge.
func test_t_arrival_tick_first_shot_standing() -> void:
	for edge in [0.01, 0.25, 0.50]:
		await setup(SCREENS[0], edge)
		var start := pawn.position
		var began := pawn.get_clock()
		var pop := -1.0
		cover_fire(true)
		cover_fire(false)
		for i in 60:
			await frames(1)
			if pop < 0.0 and pawn.position.distance_to(start) > 0.0001:
				pop = pawn.get_clock() - began
		var latency := first_shot_s - began
		print("A2 T edge=%.2f pop=%.4f first_shot=%.4f" % [edge, pop, latency])
		assert_eq(shots, 1, "isolated green tap fires once")
		assert_true(pop >= 0.0 and pop < 0.1, "tap starts live pop-out promptly")
		assert_true(latency > 0.0 and latency <= (0.1834 if edge == 0.50 else 0.1667), "arrival-tick standing shot meets speed-bound target")
		assert_eq(pawn.cover.config["crouch_blend_s"], 0.2, "reserved crouch blend unchanged")
		await cleanup()

## M2 C1b stage 3: was test_s_new_sprint_gesture_exits_cover_and_release_locks. A hard forward push (the touch
## sprint gesture) no longer exits cover: with the view along the wall it is a slide, and InputFrame.sprint stays false.
## The lock target stays reachable, and releasing on it (the Sprint lock) exits and sprints.
func test_s_hard_push_stays_and_lock_release_exits() -> void:
	for quick_draw in [false, true]:
		await setup(SCREENS[0], 0.25, true, false)
		if quick_draw:
			await tap(touch._buttons["aim"].get_global_rect().get_center())
			await frames(20)
			assert_true(pawn.cover.aimed_out, "active quick draw fixture")
		var origin: Vector2 = touch.get_move_rest()
		event_at(origin, true)
		await frames(1)
		var target: Vector2 = touch.get_lock_target_rect().get_center()
		drag_to(target, target - origin)
		await frames(30)
		assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "the forward extreme does not leave cover")
		assert_true(not touch.provider.is_sprinting(), "the stick gesture does not sprint in cover")
		assert_true(touch.provider.lock_target_visible(), "transient lock target remains available")
		event_at(target, false)
		await frames(2)
		assert_true(touch.provider.sprint_locked, "real release on target locks sprint")
		assert_eq(pawn.cover.state, CoverController.State.EXITING, "the Sprint lock leaves cover within two ticks")
		await frames(ceili(pawn.cover.exit_duration() * Engine.physics_ticks_per_second))
		assert_eq(pawn.cover.state, CoverController.State.FREE, "the exit completes while sprint held")
		await frames(10)
		assert_true(pawn.sprint_factor > 1.0, "sprint speed factor ramps")
		print("A2 S quick_draw=%s exit=FREE sprint_factor=%.5f locked=%s" % [quick_draw, pawn.sprint_factor, touch.provider.sprint_locked])
		await cleanup()

func test_s_lock_already_on_enters_and_stays_in_cover() -> void:
	await setup(SCREENS[0], 0.25, false)
	touch.provider.move_value = Vector2(0, -0.3)
	await frames(1)
	await tap(touch.lock_button.get_global_rect().get_center())
	assert_true(touch.provider.sprint_locked, "real free Sprint lock button locks")
	await frames(60)
	# M2 C1b stage 1: no auto-snap while sprinting; the Cover button enters and the held lock is not a new Sprint press.
	assert_eq(pawn.cover.state, CoverController.State.FREE, "a forward sprint lock never auto-snaps")
	await tap(touch.get_button_rect(touch.SHOULDER_KEY).get_center())
	# M2 C1b stage 2: the view stays on the wall (as a look input would keep it), so the held stick still pushes into
	# the wall instead of along it.
	pawn.cancel_cover_turn()
	await frames(60)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "the Cover button enters with the lock on")
	await frames(60)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "existing lock stays in cover sixty more ticks")
	assert_true(touch.provider.sprint_locked, "cover entry preserves existing lock")
	await cleanup()

## M2 C1b stage 3: the FIRE hold is routed instead of held on the old square.
func test_h_aimed_semi_hold_records_shot_count() -> void:
	await setup(SCREENS[0])
	pawn.loadout.get_active().fire_mode = "semi"
	await tap(touch._buttons["aim"].get_global_rect().get_center())
	await frames(20)
	assert_true(pawn.cover.aimed_out, "completed aimed-out pose before hold")
	cover_fire(true)
	await frames(30)
	cover_fire(false)
	await frames(2)
	print("A2 H semi cover FIRE hold 30 frames shots=%d" % shots)
	assert_true(shots >= 1, "held cover FIRE emits a shot; repeat policy remains undecided")
	await cleanup()
