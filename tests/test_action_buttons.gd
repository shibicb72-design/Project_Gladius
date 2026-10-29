extends "res://tests/test_case.gd"
## GBTN: every touch action button must DO something visible. Each case builds the match with the touch HUD,
## taps the button centre through Viewport.push_input (same path as tests/test_touch_controls.gd _deliver) and
## asserts the effect, under both move-stick modes, at both Fold sizes, with and without a move-stick finger held.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Rig := preload("res://tests/button_rig.gd")

const SIZES: Array[Vector2i] = [Vector2i(2520, 1080), Vector2i(2176, 1812)]
const MODES: Array[String] = ["virtual", "custom"]
const BUTTON_TOUCH := 1
const STICK_TOUCH := 0
const LOOK_TOUCH := 2


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
	if action == "fire":
		# F1: the main Fire button is gone; exercise the real look-tap release pulse.
		var point: Vector2 = ctx["touch"].get_element_rect("look_stick").get_center()
		_touch(BUTTON_TOUCH, point, true)
		_touch(BUTTON_TOUCH, point, false)
		return
	_touch(BUTTON_TOUCH, (ctx["touch"] as Control).get_button_rect(action).get_center(), true)


func _release(ctx: Dictionary, action: String) -> void:
	if action == "fire":
		return  # already released by the look tap in _press
	_touch(BUTTON_TOUCH, (ctx["touch"] as Control).get_button_rect(action).get_center(), false)


## One quick tap on a HUD button: press, two frames, release, two frames.
func _tap(ctx: Dictionary, action: String) -> void:
	_press(ctx, action)
	await _frames(2)
	_release(ctx, action)
	await _frames(2)


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


## OQ-AIM pure tap toggle (Shibi pick 1.1): a tap zooms and the zoom stays after release; a second tap restores.
func test_aim_button_tap_toggles_zoom() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var rig: CameraRig = pawn.get_node("CameraRig")
		var base := rig.base_fov
		var half_s := int(ceil(0.5 * Engine.physics_ticks_per_second))
		assert_true(is_equal_approx(rig.get_fov(), base), "%s: starts at base FOV" % ctx["tag"])
		await _tap(ctx, "aim")
		await _frames(half_s)
		assert_true(pawn.aiming, "%s: still aiming 0.5 s after the tap's release" % ctx["tag"])
		assert_true(rig.get_fov() < base, "%s: FOV stays zoomed (%s < %s)" % [ctx["tag"], rig.get_fov(), base])
		assert_true(pawn.get_spread_mult() < 1.0, "%s: aim tightens spread" % ctx["tag"])
		await _tap(ctx, "aim")
		await _frames(half_s)
		assert_true(not pawn.aiming, "%s: second tap ends aiming" % ctx["tag"])
		assert_true(is_equal_approx(rig.get_fov(), base), "%s: FOV back to base (%s vs %s)" % [ctx["tag"], rig.get_fov(), base])
		assert_true(is_equal_approx(pawn.get_spread_mult(), 1.0), "%s: spread back to normal" % ctx["tag"]))


## OQ-AIM: Fire does not cancel ADS. A Fire-button tap and a look-zone tap-to-fire both spend ammo while aiming.
func test_fire_while_aim_latched_keeps_ads() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var w := pawn.loadout.get_active()
		await _tap(ctx, "aim")
		assert_true(pawn.aiming, "%s: Aim tap latched ADS" % ctx["tag"])
		var before := w.ammo_in_mag
		await _tap(ctx, "fire")
		assert_true(w.ammo_in_mag < before, "%s: Fire button spent ammo while aiming (%d -> %d)" % [ctx["tag"], before, w.ammo_in_mag])
		assert_true(pawn.aiming, "%s: Fire button did not cancel ADS" % ctx["tag"])
		await _frames(int(ceil((w.def.fire_interval_s + 0.1) * Engine.physics_ticks_per_second)))
		before = w.ammo_in_mag
		var look: Vector2 = (ctx["touch"] as Control)._zone_hit_rect("look_zone").get_center()
		_touch(LOOK_TOUCH, look, true)
		_touch(LOOK_TOUCH, look, false)
		await _frames(4)
		assert_true(w.ammo_in_mag < before, "%s: look-zone tap fired while aiming (%d -> %d)" % [ctx["tag"], before, w.ammo_in_mag])
		assert_true(pawn.aiming, "%s: tap-to-fire did not cancel ADS" % ctx["tag"]))


## OQ-AIM: only Aim flips the latch. Reload, Swap, Jump, Shoulder and Sprint-lock taps and a look drag keep ADS on.
func test_other_controls_keep_the_aim_latch() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		var touch: Control = ctx["touch"]
		var w := pawn.loadout.get_active()
		await _tap(ctx, "aim")
		assert_true(pawn.aiming, "%s: Aim tap latched ADS" % ctx["tag"])
		await _tap(ctx, "fire")
		await _frames(15)  # let the burst finish so Reload has room
		await _tap(ctx, "reload")
		assert_true(w.reloading and pawn.aiming, "%s: reload runs and ADS stays on" % ctx["tag"])
		var slot := pawn.loadout.active
		await _tap(ctx, "swap_weapon")
		assert_true(pawn.loadout.active != slot and pawn.aiming, "%s: weapon swap keeps ADS" % ctx["tag"])
		await _tap(ctx, "jump")
		assert_true(pawn.aiming, "%s: jump keeps ADS" % ctx["tag"])
		await _tap(ctx, "swap_shoulder")
		assert_true(pawn.aiming, "%s: shoulder swap keeps ADS" % ctx["tag"])
		var lock: Vector2 = touch.get_lock_button_rect().get_center()
		_touch(BUTTON_TOUCH, lock, true)
		await _frames(2)
		_touch(BUTTON_TOUCH, lock, false)
		await _frames(2)
		assert_true(pawn.aiming, "%s: sprint-lock tap keeps ADS" % ctx["tag"])
		var look: Vector2 = touch._zone_hit_rect("look_zone").get_center()
		_touch(LOOK_TOUCH, look, true)
		for k in range(1, 4):
			_drag(LOOK_TOUCH, look + Vector2(30, 20) * k, Vector2(30, 20))
			await _frames(2)
		_touch(LOOK_TOUCH, look + Vector2(90, 60), false)
		await _frames(2)
		assert_true(pawn.aiming, "%s: look drag keeps ADS" % ctx["tag"]))


func test_jump_button_lifts_pawn() -> void:
	await _each_combo(func(ctx: Dictionary) -> void:
		var pawn: Pawn = ctx["pawn"]
		assert_true(pawn.is_on_floor(), "%s: pawn on floor before jump" % ctx["tag"])
		_press(ctx, "jump")
		await _frames(2)
		assert_true(pawn.velocity.y > 0.0, "%s: velocity.y > 0 after jump (%s)" % [ctx["tag"], pawn.velocity.y])
		_release(ctx, "jump"))


func test_hit_marker_shows_on_a_hit_only() -> void:
	# GBTN2: real hitscan through the Fire button. Hit: an enemy pawn 4 m ahead. Miss: the only enemy is behind.
	for case in ["hit", "miss"]:
		var ctx: Dictionary = await _setup(SIZES[0], "custom", false)
		var hud: GameHud = ctx["hud"]
		var target: Pawn = await _Rig.add_target(ctx, 4.0 if case == "hit" else -4.0)
		var resolved: Array = []
		(ctx["pawn"] as Pawn).shot_resolved.connect(func(_o: Vector3, _e: Vector3, h: Dictionary) -> void: resolved.append(h))
		assert_true(not hud.hit_marker.visible, "%s: no marker before firing" % case)
		_press(ctx, "fire")
		await _frames(2)
		if case == "hit":
			assert_true(hud.hit_marker.visible, "hit shows the hit marker")
			assert_true(resolved.size() > 0 and resolved[0].get("target") == target, "the real hitscan hit the target pawn")
		else:
			assert_true(resolved.size() > 0 and resolved[0].get("target") == null, "the real hitscan hit no pawn")
			assert_true(not hud.hit_marker.visible, "miss shows no hit marker")
		_release(ctx, "fire")
		await _teardown(ctx)
