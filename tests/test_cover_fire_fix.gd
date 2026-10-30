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

func occupied_rects() -> Dictionary:
	var ui: Dictionary = fire.ui_cfg
	var view: Vector2 = touch._area()
	var result := {
		"fire_mode": FireModeButton.touch_rect(ui["fire_mode_button"], view),
		"gear": PauseMenu.gear_touch_rect(ui["pause_gear"], view)
	}
	var reserved: Dictionary = ui["cover_buttons"]["reserved_top_row"]
	for i in reserved["anchors"].size():
		result["reserved_%d" % i] = FireModeButton.touch_rect({"anchor": reserved["anchors"][i], "margin_dp": reserved["margin_dp"], "touch_dp": reserved["touch_dp"]}, view)
	for key in touch.get_element_keys():
		if key not in ui["cover_buttons"]["hidden_slots"]:
			result[key] = touch.get_element_rect(key)
	return result

## Independent reconstruction of the pre-floor legacy rule, for trigger evidence.
func pre_move_side(button: CoverCrouchButton, occupied: Dictionary) -> float:
	var center := button._slot_center(button.config_key)
	var local := center - touch.global_position
	var view: Vector2 = touch._area()
	var dp := PlatformServices.new().get_dp_scale()
	var gap := float(button.ui_cfg["cover_buttons"]["clearance_dp"]) * dp
	var side := minf(float(button.cfg["preferred_dp"]) * dp, 2.0 * minf(minf(local.x, view.x - local.x), minf(local.y, view.y - local.y)))
	for obstacle: Rect2 in occupied.values():
		var distance := (center - obstacle.get_center()).abs() - obstacle.size * 0.5
		side = minf(side, 2.0 * (maxf(distance.x, distance.y) - gap))
	var peer := button._slot_center("cover_crouch" if button == fire else "cover_fire")
	var separation := (center - peer).abs()
	return minf(side, maxf(separation.x, separation.y) - gap)

func apply_center(key: String, center: Vector2) -> void:
	var local := center - touch.global_position
	touch.apply_slot_layout({key: {"pos": [local.x / touch.size.x, local.y / touch.size.y], "size_pct": 100.0, "alpha_pct": 100.0}})
	fire.refresh()
	crouch.refresh()

func clear_square(rect: Rect2, occupied: Array, gap: float) -> bool:
	for obstacle: Rect2 in occupied:
		var separation := (rect.get_center() - obstacle.get_center()).abs() - (rect.size + obstacle.size) * 0.5
		if maxf(separation.x, separation.y) < gap - 0.0001:
			return false
	return true

func check_layout(button: CoverCrouchButton, baseline: Rect2, shift: float) -> void:
	var dp := PlatformServices.new().get_dp_scale()
	var min_side := float(touch._layout["button_min_dp"]) * dp
	var occupied := occupied_rects()
	var before := pre_move_side(button, occupied)
	var slot := button._slot_center(button.config_key)
	var rect := button.get_touch_rect()
	var moved := not rect.get_center().is_equal_approx(slot)
	var overlaps: Array[String] = []
	var floored := Rect2(slot - Vector2.ONE * min_side * 0.5, Vector2.ONE * min_side)
	for key in occupied:
		if floored.intersects(occupied[key]):
			overlaps.append(key)
	print("A2 L moved %s %s shift=%.1f slot=%s pre_dp=%.5f overlaps=%s moved=%s final=%s dp=%.5f distance=%.5f" % [tree().root.size, button.config_key, shift, slot, before / dp, overlaps, moved, rect, rect.size.x / dp, rect.get_center().distance_to(slot)])
	assert_eq(moved, before < min_side, "pinned fixture moves exactly when legacy slot is below minimum")
	if not moved:
		var legacy := Rect2(slot - Vector2.ONE * maxf(before, min_side) * 0.5, Vector2.ONE * maxf(before, min_side))
		assert_true(rect.is_equal_approx(legacy), "unmoved fixture retains the legacy live-slot rect")
	assert_true(baseline.has_area(), "baseline measured before saved-layout edit")
	assert_true(button.is_visible_in_tree() and button.label.get_global_rect().is_equal_approx(rect), "drawn control matches hit rect")
	assert_true(is_equal_approx(rect.size.x, rect.size.y), "round bounding square")
	assert_true(rect.size.x / dp >= 48.0 - 0.0001 and rect.size.x / dp <= float(button.cfg["preferred_dp"]) + 0.0001, "finger size and preferred maximum")
	assert_true(not button._accept_point(rect.position + Vector2.ONE), "bounding-square corner is outside drawn hit circle")
	var origin: Vector2 = touch.global_position
	var view: Vector2 = touch._area()
	assert_true(Rect2(origin, view).encloses(rect), "fully inside HUD")
	var peer := crouch if button == fire else fire
	var obstacles: Array = occupied.values()
	obstacles.append(peer.get_touch_rect())
	var gap := float(button.ui_cfg["cover_buttons"]["clearance_dp"]) * dp
	assert_true(clear_square(rect, obstacles, gap), "clear of visible controls, exclusions and peer")
	if moved:
		var region: Array = button.ui_cfg["cover_buttons"]["thumb_reach_min"]
		var lower := origin + Vector2(view.x * float(region[0]), view.y * float(region[1]))
		assert_true(rect.get_center().x >= lower.x and rect.get_center().y >= lower.y, "right lower thumb region")
		var distance := rect.get_center().distance_to(slot)
		var best_grid := INF
		var x := maxf(lower.x, origin.x + min_side * 0.5)
		while x <= origin.x + view.x - min_side * 0.5:
			var y := maxf(lower.y, origin.y + min_side * 0.5)
			while y <= origin.y + view.y - min_side * 0.5:
				var center := Vector2(x, y)
				if center.distance_to(slot) < distance:
					var square := Rect2(center - Vector2.ONE * min_side * 0.5, Vector2.ONE * min_side)
					if clear_square(square, obstacles, gap):
						best_grid = minf(best_grid, center.distance_to(slot))
				y += dp
			x += dp
		assert_true(best_grid >= distance - dp, "1dp scan finds no free centre closer by more than 1dp")
	var rig := pawn.get_node("CameraRig") as CameraRig
	var shoulder := rig.shoulder_side
	var old_crouch := pawn.cover.crouched
	var ammo := pawn.loadout.get_active().ammo_in_mag
	var before_shots := shots
	event_at(button.label.get_global_rect().get_center(), true)
	await frames(1)
	assert_true(not Input.is_action_pressed("jump") and pawn.velocity.y == 0.0, "no Jump press")
	assert_true(not touch.provider.sprint_locked, "no sprint lock")
	assert_eq(rig.shoulder_side, shoulder, "no shoulder swap")
	event_at(button.label.get_global_rect().get_center(), false)
	await frames(40)
	if button == fire:
		assert_eq(shots, before_shots + 1, "drawn FIRE viewport tap fires shot")
		assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo - 1, "drawn FIRE spends one round")
	else:
		assert_eq(pawn.cover.crouched, not old_crouch, "drawn Crouch viewport tap toggles stance")
		assert_eq(shots, before_shots, "Crouch does not fire")

func test_l_jump_fixture_remaps_only_conflicting_fire() -> void:
	var shift := 32.0
	for screen in SCREENS:
		await setup(screen)
		var baseline := fire.get_touch_rect()
		var peer := crouch.get_touch_rect()
		var original: Vector2 = touch.get_button_rect("jump").get_center()
		apply_center("jump", original - Vector2(shift, 0))
		var dp := PlatformServices.new().get_dp_scale()
		# Pin the same shift at both Fold sizes. Only increase it if the cover
		# screen's minimum square has no visible-element overlap.
		if screen == SCREENS[0]:
			var minimum := float(touch._layout["button_min_dp"]) * dp
			while original.x - shift - 8.0 >= touch.global_position.x + touch.size.x * 0.5:
				var slot := fire._slot_center("cover_fire")
				var square := Rect2(slot - Vector2.ONE * minimum * 0.5, Vector2.ONE * minimum)
				var overlaps := false
				for obstacle: Rect2 in occupied_rects().values():
					overlaps = overlaps or square.intersects(obstacle)
				if overlaps:
					break
				shift += 8.0
				apply_center("jump", original - Vector2(shift, 0))
		assert_true(crouch.get_touch_rect().is_equal_approx(peer), "Jump fixture preserves Crouch baseline")
		await check_layout(fire, baseline, shift)
		await cleanup()

func test_l_reload_fixture_remaps_only_conflicting_crouch() -> void:
	for screen in SCREENS:
		await setup(screen)
		var baseline := crouch.get_touch_rect()
		var peer := fire.get_touch_rect()
		var center: Vector2 = touch.get_button_rect("reload").get_center()
		var shift := center.distance_to(touch.get_lock_button_rect().get_center())
		apply_center("sprint_lock", center)
		assert_true(fire.get_touch_rect().is_equal_approx(peer), "Reload fixture preserves FIRE baseline")
		await check_layout(crouch, baseline, shift)
		await cleanup()

func test_l_default_layout_matches_measured_baseline() -> void:
	var expected := [
		[Rect2(1188.862, 136.9424, 132.1952, 132.1952), Rect2(779.2424, 204.6825, 134.955, 134.955)],
		[Rect2(870.1431, 397.2591, 149.1378, 149.1378), Rect2(533.22, 290.88, 223.8, 223.8)]
	]
	for i in SCREENS.size():
		await setup(SCREENS[i])
		for j in 2:
			var button: CoverCrouchButton = fire if j == 0 else crouch
			var rect := button.get_touch_rect()
			var baseline: Rect2 = expected[i][j]
			assert_true(rect.position.distance_to(baseline.position) < 0.001 and rect.size.distance_to(baseline.size) < 0.001, "default baseline geometry unchanged")
			print("A2 L baseline %s %s rect=%s dp=%.5f" % [SCREENS[i]["size"], button.config_key, rect, rect.size.x / PlatformServices.new().get_dp_scale()])
		await cleanup()

func test_l_both_conflicts_resolve_fire_before_crouch() -> void:
	await setup(SCREENS[0])
	var fire_baseline := fire.get_touch_rect()
	var crouch_baseline := crouch.get_touch_rect()
	var fire_slot: Vector2 = touch.get_button_rect("jump").get_center() - Vector2(32, 0)
	var crouch_slot: Vector2 = touch.get_button_rect("reload").get_center()
	var fire_local := fire_slot - touch.global_position
	var crouch_local := crouch_slot - touch.global_position
	touch.apply_slot_layout({
		"jump": {"pos": [fire_local.x / touch.size.x, fire_local.y / touch.size.y], "size_pct": 100.0, "alpha_pct": 100.0},
		"sprint_lock": {"pos": [crouch_local.x / touch.size.x, crouch_local.y / touch.size.y], "size_pct": 100.0, "alpha_pct": 100.0}
	})
	fire.refresh()
	crouch.refresh()
	await check_layout(fire, fire_baseline, 32.0)
	await check_layout(crouch, crouch_baseline, crouch_slot.distance_to(crouch_baseline.get_center()))
	await cleanup()
