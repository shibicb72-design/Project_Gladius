extends "res://tests/test_case.gd"
## D2 part 1: cover FIRE reaches the cover only through the input layer
## (TouchProvider -> InputRouter -> MatchRoot -> Pawn -> CoverController). Real match, live pawn physics.
## M2 C1b stage 3: the HUD no longer creates the old cover FIRE square, so every test that pressed, dragged or hid it
## (T1, T2, T3b, T3c, T4) is gone; what is left is the routed "cover_fire" path itself, which stage 4 turns into a
## no-op (it then deletes this file).
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var routed: Array = []
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

## The green 0.25 m edge of a 2.2 m tagged wall, as before.
func setup() -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {}
	PlatformServices.dpi_override = 420.0
	tree().root.size = Vector2i(2520, 1080)
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
	box(Vector3(1000, 1.1, -0.5), Vector3(4, 2.2, 1))
	pawn.position = Vector3(1002 - 0.25, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	routed = []
	match_scene.router.action_triggered.connect(func(a: String): routed.append(["press", a]))
	match_scene.router.action_released.connect(func(a: String, c: bool): routed.append(["release", a, c]))
	# Walk in through the input layer (KeyboardMouseProvider reads move_forward).
	Input.action_press("move_forward")
	for i in 60:
		await frames(1)
		if pawn.in_cover():
			pawn.cancel_cover_turn()  # M2 C1b stage 2: the view stays on the wall (as a look input would keep it)
	Input.action_release("move_forward")
	touch.provider.cancel_sprint_lock()
	await frames(4)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "live probe cover state")

func cleanup() -> void:
	match_scene.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile
	PlatformServices.dpi_override = old_dpi
	for action in ["fire", "jump", "aim", "swap_shoulder", "move_forward"]:
		Input.action_release(action)
	await tree().process_frame

## Cover hold state that quick_draw(pressed, cancel_buffer) writes.
func held() -> Array:
	return [pawn.cover._quick_held, pawn.cover._buffered_round]

## M2 C1b stage 3: was test_t3_menu_suspend_and_death_presses_do_nothing (its button-tap parts are gone). The routed
## press and release still reach the quick draw; MatchRoot's menu gate and the pawn's alive gate still refuse it.
func test_t3_routed_press_release_and_gates() -> void:
	await setup()
	routed.clear()
	touch.provider.trigger_action("cover_fire")
	assert_eq(routed, [["press", "cover_fire"]], "router re-emits the press")
	assert_eq(held(), [true, true], "the routed press acts like quick_draw(true)")
	touch.provider.release_action("cover_fire", true)
	assert_eq(routed[-1], ["release", "cover_fire", true], "router re-emits the release")
	assert_eq(held(), [false, false], "the cancelling release acts like quick_draw(false, true)")
	match_scene.pause_menu.open()
	assert_true(match_scene.menu_open, "menu open")
	touch.provider.trigger_action("cover_fire")
	assert_eq(held(), [false, false], "MatchRoot menu gate: a press does nothing")
	match_scene.pause_menu.close()
	await frames(4)
	pawn.bridge.state.health = 0
	pawn.bridge.state.shield = 0
	assert_true(not pawn.is_alive(), "pawn dead")
	touch.provider.trigger_action("cover_fire")
	assert_eq(held(), [false, false], "dead: a press (even sent directly) does nothing")
	await cleanup()
