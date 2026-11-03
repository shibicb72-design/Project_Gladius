extends "res://tests/test_case.gd"
## D2 (spec G1.7 part 1): cover FIRE reaches the cover only through the input layer
## (TouchProvider -> InputRouter -> MatchRoot -> Pawn -> CoverController). Real match, live pawn physics,
## real window-pixel taps pushed through the viewport. The router's re-emitted signals are recorded in `routed`.
var match_scene: MatchRoot
var pawn: Pawn
var touch: Control
var fire: CoverFireButton
var wall: StaticBody3D
var shots := 0
var routed: Array = []
var looks: Array = []
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

## Same fixture as test_cover_fire_path_a2.gd (green 0.25 m edge of a 2.2 m tagged wall), default move stick
## (as test_cover_crouch.gd, whose set_suspended path these tests also use).
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
	fire = match_scene.hud.cover_fire_button
	box(Vector3(1000, -0.1, 0), Vector3(30, 0.2, 30), false)
	wall = box(Vector3(1000, 1.1, -0.5), Vector3(4, 2.2, 1))
	pawn.position = Vector3(1002 - 0.25, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	shots = 0
	pawn.fired.connect(func(): shots += 1)
	routed = []
	looks = []
	match_scene.router.action_triggered.connect(func(a: String): routed.append(["press", a]))
	match_scene.router.action_released.connect(func(a: String, c: bool): routed.append(["release", a, c]))
	match_scene.router.action_look_changed.connect(func(a: String, on: bool): looks.append([a, on]))
	# Walk in through the input layer (KeyboardMouseProvider reads move_forward).
	Input.action_press("move_forward")
	await frames(60)
	Input.action_release("move_forward")
	touch.provider.cancel_sprint_lock()
	await frames(4)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "live probe cover state")
	assert_true(fire.visible and fire.enabled, "cover FIRE visible and green")

func cleanup() -> void:
	match_scene.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile
	PlatformServices.dpi_override = old_dpi
	for action in ["fire", "jump", "aim", "swap_shoulder", "move_forward"]:
		Input.action_release(action)
	await tree().process_frame

func touch_at(point: Vector2, down: bool, index: int = 42) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)

func drag_at(point: Vector2, relative: Vector2, index: int) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = tree().root.get_screen_transform() * point
	event.relative = relative
	tree().root.push_input(event, false)

func mouse_at(point: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.device = InputEvent.DEVICE_ID_MOUSE
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)

func fire_point() -> Vector2:
	return fire.get_touch_rect().get_center()

## Cover hold state that quick_draw(pressed, cancel_buffer) writes.
func held() -> Array:
	return [pawn.cover._quick_held, pawn.cover._buffered_round]

## A look-zone point clear of every TouchHud element (incl. cover-hidden slots) and both cover buttons.
func look_point() -> Vector2:
	var zone: Rect2 = touch._zone_hit_rect("look_zone")
	var blocked: Array[Rect2] = [fire.get_touch_rect().grow(20), match_scene.hud.cover_crouch_button.get_touch_rect().grow(20), touch.get_lock_button_rect()]
	for key in touch.get_element_keys():
		blocked.append(touch.get_element_rect(key).grow(20))
	for fy in [0.5, 0.35, 0.65, 0.2, 0.8]:
		for fx in [0.5, 0.3, 0.7, 0.15, 0.85]:
			var p := zone.position + zone.size * Vector2(fx, fy)
			if blocked.all(func(r: Rect2): return not r.has_point(p)):
				return p
	assert_true(false, "no free look-zone point")
	return zone.get_center()

## Starts a moved HUD look drag (TouchHud.is_look_active()) away from every button.
func start_look(index: int) -> Vector2:
	var start := look_point()
	touch_at(start, true, index)
	assert_eq(touch._look_touch, index, "touch-down reached the look zone")
	for k in range(1, 4):
		drag_at(start + Vector2(30, 20) * k, Vector2(30, 20), index)
	assert_true(touch.is_look_active(), "HUD look drag active")
	return start + Vector2(90, 60)

## The direct-call reference: what quick_draw(true) then quick_draw(false, cancel) did before D2.
func direct_reference(cancel: bool) -> Array:
	pawn.cover.quick_draw(true)
	var on := held()
	pawn.cover.quick_draw(false, cancel)
	var off := held()
	pawn.cover.quick_draw(false, true)
	return [on, off]

# ---- T1 / T2: real press and release ------------------------------------------------------------

func test_t1_real_touch_press_and_release_match_direct_calls_at_the_same_moments() -> void:
	await setup()
	var expected := direct_reference(false)
	routed.clear()
	var ammo := pawn.loadout.get_active().ammo_in_mag
	touch_at(fire_point(), true)
	assert_eq(routed, [["press", "cover_fire"]], "touch press routed once, synchronously")
	assert_eq(held(), expected[0], "press acts at press time like quick_draw(true)")
	assert_eq(fire._press_index, 42, "button owns the touch")
	assert_true(not Input.is_action_pressed("fire"), "cover FIRE never presses the general fire action")
	touch_at(fire_point(), false)
	assert_eq(routed, [["press", "cover_fire"], ["release", "cover_fire", false]], "release routed with cancel_buffer=false")
	assert_eq(held(), expected[1], "release acts at release time like quick_draw(false), buffered tap kept")
	assert_eq(fire._press_index, -1, "touch freed")
	await frames(65)
	assert_true(shots >= 1 and pawn.loadout.get_active().ammo_in_mag < ammo, "routed green tap fires a real shot")
	assert_true(not pawn.cover._draw_active and not pawn.cover.aimed_out, "tap auto-returns")
	await cleanup()

func test_t2_real_mouse_press_release_and_every_release_path_keeps_cancel_buffer() -> void:
	await setup()
	var expected := direct_reference(false)
	routed.clear()
	mouse_at(fire_point(), true)
	assert_eq(routed, [["press", "cover_fire"]], "mouse press routed")
	assert_eq(held(), expected[0], "mouse press acts at press time")
	assert_true(fire._mouse_held, "button owns the mouse")
	mouse_at(fire_point(), false)
	assert_eq(routed[-1], ["release", "cover_fire", false], "mouse release routed with cancel_buffer=false")
	assert_eq(held(), expected[1], "mouse release acts at release time")
	await frames(65)
	var cancelled := direct_reference(true)
	assert_eq(cancelled[1], [false, false], "reference: cancel drops the buffered round")
	for path in ["hide", "refresh_hidden", "input_unavailable"]:
		await frames(4)
		assert_true(fire.visible, "visible before %s" % path)
		touch_at(fire_point(), true)
		assert_eq(held(), [true, true], "held before %s" % path)
		routed.clear()
		match path:
			"hide":
				fire.hide()  # NOTIFICATION_VISIBILITY_CHANGED
			"refresh_hidden":
				touch.suspended = true
				fire.refresh()
			"input_unavailable":
				touch.suspended = true
				touch_at(Vector2(5, 5), true, 50)  # any event reaches _input while unavailable
		# As before D2: a hiding refresh releases twice (NOTIFICATION_VISIBILITY_CHANGED, then refresh itself).
		var count: int = {"hide": 1, "refresh_hidden": 2, "input_unavailable": 1}[path]
		var expected_routed: Array = []
		for i in count:
			expected_routed.append(["release", "cover_fire", true])
		assert_eq(routed, expected_routed, "%s releases with cancel_buffer=true" % path)
		assert_eq(held(), cancelled[1], "%s cancels like quick_draw(false, true)" % path)
		assert_eq(fire._press_index, -1, "%s frees the touch" % path)
		touch.suspended = false
		if path == "input_unavailable":
			touch_at(Vector2(5, 5), false, 50)
		touch_at(fire_point(), false)  # the finger lifts later: nothing is held any more
		fire.refresh()
	await cleanup()

# ---- T3 / T3b: gates apply to the press only -----------------------------------------------------

func test_t3_menu_suspend_and_death_presses_do_nothing() -> void:
	await setup()
	var point := fire_point()
	match_scene.pause_menu.open()
	assert_true(match_scene.menu_open, "menu open")
	assert_true(not fire._accept_point(point), "button refuses the press behind the menu")
	routed.clear()
	touch.provider.trigger_action("cover_fire")
	assert_eq(routed, [["press", "cover_fire"]], "router re-emits")
	assert_eq(held(), [false, false], "MatchRoot menu gate: a press does nothing")
	match_scene.pause_menu.close()
	await frames(4)
	touch.set_suspended(true)
	routed.clear()
	touch_at(point, true)
	assert_true(not routed.has(["press", "cover_fire"]), "suspended: no press sent")
	assert_eq(held(), [false, false], "suspended: a press does nothing")
	touch_at(point, false)
	touch.set_suspended(false)
	await frames(4)
	pawn.bridge.state.health = 0
	pawn.bridge.state.shield = 0
	assert_true(not pawn.is_alive(), "pawn dead")
	routed.clear()
	touch_at(point, true)
	assert_true(not routed.has(["press", "cover_fire"]), "dead: no press sent")
	touch.provider.trigger_action("cover_fire")
	assert_eq(held(), [false, false], "dead: a press (even sent directly) does nothing")
	touch_at(point, false)
	await cleanup()

func test_t3b_held_press_is_cancelled_by_menu_suspend_and_death_and_look_goes_false() -> void:
	await setup()
	for interruption in ["pause", "suspend", "death"]:
		await frames(4)
		var point := fire_point()
		touch_at(point, true)
		var look_end := start_look(43)
		fire.refresh()
		assert_eq(held(), [true, true], "held before %s" % interruption)
		assert_true(pawn.cover._look_active, "look-hold active before %s" % interruption)
		routed.clear()
		looks.clear()
		match interruption:
			"pause": match_scene.pause_menu.open()
			"suspend": touch.set_suspended(true)
			"death": pawn.bridge.state.health = 0; pawn.bridge.state.shield = 0
		fire.refresh()
		assert_true(routed.size() > 0 and routed.all(func(r): return r == ["release", "cover_fire", true]), "%s: only cancelling releases routed" % interruption)
		assert_eq(held(), [false, false], "%s: _quick_held and _buffered_round both false" % interruption)
		assert_eq(looks[-1], ["cover_fire", false], "%s: look-active false routed" % interruption)
		assert_true(not pawn.cover._look_active, "%s: look-active false on the cover" % interruption)
		match interruption:
			"pause": match_scene.pause_menu.close()
			"suspend": touch.set_suspended(false)
		touch_at(look_end, false, 43)
		touch_at(point, false)
	await cleanup()

# ---- T3c: stateless release clears a press made directly on the cover ----------------------------

func test_t3c_direct_cover_press_is_cleared_by_routed_release_and_hidden_refresh() -> void:
	await setup()
	pawn.cover.quick_draw(true)
	assert_eq(held(), [true, true], "direct press held, no button press")
	assert_true(fire._press_index == -1 and not fire._mouse_held, "button holds nothing")
	routed.clear()
	fire._release(true)
	assert_eq(routed, [["release", "cover_fire", true]], "release routed even with no button press")
	assert_eq(held(), [false, false], "fire._release(true) clears the direct press")
	pawn.cover.quick_draw(true)
	assert_eq(held(), [true, true], "direct press held again")
	routed.clear()
	touch.set_suspended(true)
	fire.refresh()
	assert_true(not fire.visible, "hidden while suspended")
	assert_true(routed.has(["release", "cover_fire", true]), "hidden refresh routes the cancelling release")
	assert_eq(held(), [false, false], "refresh() when hidden clears the direct press")
	touch.set_suspended(false)
	await cleanup()

# ---- T4: look-active follows the HUD look state ---------------------------------------------------

func test_t4_look_active_follows_hud_look_and_goes_false_on_hide_and_exit() -> void:
	await setup()
	fire.refresh()
	assert_true(not touch.is_look_active() and not pawn.cover._look_active, "no look drag: look-hold off")
	var look_end := start_look(44)
	looks.clear()
	fire.refresh()
	fire.refresh()
	assert_eq(looks, [["cover_fire", true], ["cover_fire", true]], "sent every refresh, unchanged or not")
	assert_eq(pawn.cover._look_active, fire._available() and touch.is_look_active(), "look-hold = available and HUD look")
	assert_true(pawn.cover._look_active, "look drag: look-hold on")
	await frames(3)
	assert_eq(pawn.cover._look_active, fire._available() and touch.is_look_active(), "per-frame refresh keeps it in step")
	touch_at(look_end, false, 44)
	fire.refresh()
	assert_true(not touch.is_look_active() and not pawn.cover._look_active, "look released: look-hold off")
	look_end = start_look(45)
	fire.refresh()
	assert_true(pawn.cover._look_active, "second drag on")
	touch.set_suspended(true)
	fire.refresh()
	assert_true(not fire.visible and not pawn.cover._look_active, "hidden: look-hold off")
	touch.set_suspended(false)
	await frames(4)
	look_end = start_look(46)
	fire.refresh()
	assert_true(pawn.cover._look_active, "third drag on")
	routed.clear()
	looks.clear()
	fire.queue_free()
	await tree().process_frame
	assert_true(not is_instance_valid(fire), "button left the tree")
	assert_true(routed.has(["release", "cover_fire", true]), "exit routes the cancelling release")
	assert_eq(looks[-1], ["cover_fire", false], "exit routes look-active false")
	assert_true(not pawn.cover._look_active, "exit: look-hold off")
	touch_at(look_end, false, 46)
	await cleanup()
