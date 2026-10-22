extends "res://tests/test_case.gd"
## GBTN: every touch action button must DO something visible. Each case builds the match with the touch HUD,
## taps the button centre through Viewport.push_input (same path as tests/test_touch_controls.gd _deliver) and
## asserts the effect, under both move-stick modes, at both Fold sizes, with and without a move-stick finger held.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")

const SIZES: Array[Vector2i] = [Vector2i(2520, 1080), Vector2i(2176, 1812)]
const MODES: Array[String] = ["virtual", "custom"]
const BUTTON_TOUCH := 1
const STICK_TOUCH := 0


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame
	# process_frame fires before that frame's _process calls, so two frames guarantee one full HUD refresh.
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame


func _deliver(e: InputEvent) -> void:
	_root().push_input(e, true)


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	_deliver(e)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_deliver(e)


## Builds the match at `size` with the touch HUD under `mode`; optionally holds a move-stick finger (index 0).
func _setup(size: Vector2i, mode: String, stick_held: bool) -> Dictionary:
	_TouchHud.move_stick_override = mode
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.begin()
	var prev_size := _root().size
	_root().size = size
	await _frames(25)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await _frames(3)
	if stick_held:
		var start: Vector2 = touch._zone_rect("move_zone").get_center()
		_touch(STICK_TOUCH, start, true)
		_drag(STICK_TOUCH, start + Vector2(0, -60), Vector2(0, -60))
		await _frames(2)
	return {"m": m, "touch": touch, "pawn": m.local_player, "hud": m.hud, "prev": prev_size,
			"stick_held": stick_held, "tag": "%s %s mode=%s stick=%s" % [size, mode, mode, stick_held]}


func _teardown(ctx: Dictionary) -> void:
	if ctx["stick_held"]:
		_touch(STICK_TOUCH, Vector2.ZERO, false)
	(ctx["m"] as Node).queue_free()
	_root().size = ctx["prev"]
	await _frames(2)


func _press(ctx: Dictionary, action: String) -> void:
	_touch(BUTTON_TOUCH, (ctx["touch"] as Control).get_button_rect(action).get_center(), true)


func _release(ctx: Dictionary, action: String) -> void:
	_touch(BUTTON_TOUCH, (ctx["touch"] as Control).get_button_rect(action).get_center(), false)


## Runs `body` for every size x mode x stick-held combination.
func _each_combo(body: Callable) -> void:
	for size in SIZES:
		for mode in MODES:
			for stick in [false, true]:
				var ctx: Dictionary = await _setup(size, mode, stick)
				ctx["tag"] = "%s mode=%s stick=%s" % [size, mode, stick]
				await body.call(ctx)
				await _teardown(ctx)


func test_fire_button_spends_ammo_and_shows_tracer() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var w := pawn.loadout.get_active()
		assert_true(not w.def.is_melee(), "%s: start weapon is ranged" % ctx["tag"])
		var before := w.ammo_in_mag
		_press(ctx, "fire")
		await _frames(2)
		assert_true(w.ammo_in_mag < before, "%s: fire spent ammo (%d -> %d)" % [ctx["tag"], before, w.ammo_in_mag])
		assert_true(pawn.shot_fx.is_tracer_visible(), "%s: tracer visible" % ctx["tag"])
		assert_true(pawn.shot_fx.is_flash_visible(), "%s: muzzle flash visible" % ctx["tag"])
		_release(ctx, "fire"))


func test_reload_button_reloads_and_shows_indicator() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var hud: GameHud = ctx["hud"]
		var w := pawn.loadout.get_active()
		_press(ctx, "fire")
		await _frames(2)
		_release(ctx, "fire")
		await _frames(15)  # let the burst finish
		assert_true(w.ammo_in_mag < w.def.magazine, "%s: mag not full after firing" % ctx["tag"])
		_press(ctx, "reload")
		await _frames(2)
		assert_true(w.reloading, "%s: reloading started" % ctx["tag"])
		assert_true(hud.reload_box.visible, "%s: reload indicator visible" % ctx["tag"])
		_release(ctx, "reload")
		await _frames(int(ceil(w.def.reload_s * Engine.physics_ticks_per_second)) + 10)
		assert_true(not w.reloading and w.ammo_in_mag == w.def.magazine,
				"%s: ammo refilled (%d/%d)" % [ctx["tag"], w.ammo_in_mag, w.def.magazine])
		assert_true(not hud.reload_box.visible, "%s: reload indicator hidden after reload" % ctx["tag"]))


func test_reload_on_full_mag_shows_full_cue() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var hud: GameHud = ctx["hud"]
		var w := pawn.loadout.get_active()
		var before := w.ammo_in_mag
		assert_eq(before, w.def.magazine, "%s: mag starts full" % ctx["tag"])
		_press(ctx, "reload")
		await _frames(2)
		assert_true(hud.cue_label.visible and hud.cue_label.text == "Full", "%s: Full cue shown, got '%s'" % [ctx["tag"], hud.cue_label.text])
		assert_true(not w.reloading, "%s: no reload on a full mag" % ctx["tag"])
		assert_eq(w.ammo_in_mag, before, "%s: ammo unchanged" % ctx["tag"])
		_release(ctx, "reload"))


func test_fire_on_empty_mag_shows_empty_cue() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var hud: GameHud = ctx["hud"]
		var w := pawn.loadout.get_active()
		w.ammo_in_mag = 0
		_press(ctx, "fire")
		await _frames(2)
		assert_true(hud.cue_label.visible and hud.cue_label.text == "Empty", "%s: Empty cue shown, got '%s'" % [ctx["tag"], hud.cue_label.text])
		assert_eq(w.ammo_in_mag, 0, "%s: still empty" % ctx["tag"])
		_release(ctx, "fire"))


func test_swap_button_changes_slot_and_shows_toast() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var hud: GameHud = ctx["hud"]
		var slot := pawn.loadout.active
		_press(ctx, "swap_weapon")
		await _frames(2)
		assert_true(pawn.loadout.active != slot, "%s: active slot changed" % ctx["tag"])
		var name := pawn.loadout.get_active().def.display_name
		assert_true(hud.toast_label.visible and hud.toast_label.text == name,
				"%s: toast shows '%s', got '%s'" % [ctx["tag"], name, hud.toast_label.text])
		_release(ctx, "swap_weapon"))


func test_aim_button_zooms_and_releases() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var rig: CameraRig = pawn.get_node("CameraRig")
		var base := rig.base_fov
		assert_true(is_equal_approx(rig.get_fov(), base), "%s: starts at base FOV" % ctx["tag"])
		_press(ctx, "aim")
		await _frames(int(ceil(0.5 * Engine.physics_ticks_per_second)))
		assert_true(pawn.aiming, "%s: pawn aiming" % ctx["tag"])
		assert_true(rig.get_fov() < base, "%s: FOV zoomed (%s < %s)" % [ctx["tag"], rig.get_fov(), base])
		assert_true(pawn.get_spread_mult() < 1.0, "%s: aim tightens spread" % ctx["tag"])
		_release(ctx, "aim")
		await _frames(int(ceil(0.5 * Engine.physics_ticks_per_second)))
		assert_true(is_equal_approx(rig.get_fov(), base), "%s: FOV back to base (%s vs %s)" % [ctx["tag"], rig.get_fov(), base])
		assert_true(is_equal_approx(pawn.get_spread_mult(), 1.0), "%s: spread back to normal" % ctx["tag"]))


func test_jump_button_lifts_pawn() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		assert_true(pawn.is_on_floor(), "%s: pawn on floor before jump" % ctx["tag"])
		_press(ctx, "jump")
		await _frames(2)
		assert_true(pawn.velocity.y > 0.0, "%s: velocity.y > 0 after jump (%s)" % [ctx["tag"], pawn.velocity.y])
		_release(ctx, "jump"))


func test_hit_marker_shows_on_a_hit_only() -> void:
	var ctx: Dictionary = await _setup(SIZES[0], "custom", false)
	var pawn: Pawn = ctx["pawn"]
	var hud: GameHud = ctx["hud"]
	pawn.shot_resolved.emit(Vector3.ZERO, Vector3.FORWARD, {})
	assert_true(not hud.hit_marker.visible, "miss shows no hit marker")
	pawn.shot_resolved.emit(Vector3.ZERO, Vector3.FORWARD, {"target": pawn})
	assert_true(hud.hit_marker.visible, "hit shows the hit marker")
	await _teardown(ctx)
