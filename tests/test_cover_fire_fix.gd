extends "res://tests/test_case.gd"
## FIRE FIX: real match, live physics, window-pixel input via root viewport.
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var fire: CoverFireButton
var crouch: CoverCrouchButton
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

func setup(screen: Dictionary, edge: float = 0.25, enter: bool = true) -> void:
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
	fire = match_scene.hud.cover_fire_button
	crouch = match_scene.hud.cover_crouch_button
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
		touch.provider.move_value = Vector2(0, -1)
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
	await tree().process_frame
	event_at(point, false)
	await tree().process_frame

func test_t_arrival_tick_first_shot_standing_and_crouched() -> void:
	for stance in [false, true]:
		for edge in [0.01, 0.25, 0.50]:
			await setup(SCREENS[0], edge)
			if stance:
				await tap(crouch.label.get_global_rect().get_center())
				await frames(15)
			var start := pawn.position
			var began := pawn.get_clock()
			var pop := -1.0
			event_at(fire.label.get_global_rect().get_center(), true)
			event_at(fire.label.get_global_rect().get_center(), false)
			for i in 60:
				await frames(1)
				if pop < 0.0 and pawn.position.distance_to(start) > 0.0001:
					pop = pawn.get_clock() - began
			var latency := first_shot_s - began
			print("A2 T edge=%.2f crouched=%s pop=%.4f first_shot=%.4f" % [edge, stance, pop, latency])
			assert_eq(shots, 1, "real isolated green tap fires once")
			assert_true(pop >= 0.0 and pop < 0.1, "tap starts live pop-out promptly")
			if not stance:
				assert_true(latency > 0.0 and latency <= (0.1834 if edge == 0.50 else 0.1667), "arrival-tick standing shot meets speed-bound target")
			assert_eq(pawn.cover.config["crouch_blend_s"], 0.2, "reserved crouch blend unchanged")
			await cleanup()
