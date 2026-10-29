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

func setup(window: Vector2i, dpi: float, height: float = 2.2, edge: float = 0.25) -> void:
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
	pawn.fired.connect(func(): shots += 1)
	touch.provider.move_value = Vector2(0, -1)
	await frames(60)
	touch.provider.move_value = Vector2.ZERO
	touch.provider.cancel_sprint_lock()
	await frames(4)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "live probe enters cover")
	assert_true(pawn.is_physics_processing(), "pawn physics stays running")
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
