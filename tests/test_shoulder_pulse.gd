extends "res://tests/test_case.gd"
## Path A2 C: visual press/release contract, independent of the layout cell and camera ease.

const _Rig := preload("res://tests/button_rig.gd")
const _HudScene := preload("res://scenes/ui/touch_hud.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_shoulder_pulse_keys_are_locked_industry_defaults() -> void:
	var layout: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	assert_true(layout["_placeholder"], "layout block keeps its existing placeholder")
	for key: String in ["shoulder_pulse_scale", "shoulder_pulse_release_s"]:
		assert_true(layout.has(key), "touch_layout has %s" % key)
		assert_true(not layout[key].has("_placeholder"), "%s wrapper is locked" % key)
	assert_true(is_equal_approx(float(layout["shoulder_pulse_scale"]["value"]), 0.97), "locked scale 0.97")
	assert_true(is_equal_approx(float(layout["shoulder_pulse_release_s"]["value"]), 0.12), "locked release 0.12 s")


func test_shoulder_pulse_in_match_is_centred_monotonic_and_keeps_the_layout_cell() -> void:
	for sz in _Rig.SIZES:
		var ctx: Dictionary = await _Rig.setup(sz, "virtual")
		var touch: Control = ctx["touch"]
		var b: Button = touch._buttons["swap_shoulder"]
		var rect0: Rect2 = touch.get_button_rect("swap_shoulder")
		var c0 := b.get_global_transform() * (b.size * 0.5)
		var alpha0 := b.modulate.a
		var scale_key := float(touch._layout["shoulder_pulse_scale"]["value"])
		var release_s := float(touch._layout["shoulder_pulse_release_s"]["value"])
		print("SHOULDER_PULSE %s: b.size=%s rect0.size=%s" % [sz, b.size, rect0.size])
		_Rig.press(ctx, "swap_shoulder", true)
		# No await: push_input dispatches the press synchronously.
		assert_true(b.scale.is_equal_approx(Vector2.ONE * scale_key), "%s: immediate data press scale" % sz)
		var previous := b.scale.x
		var deadline := Engine.get_physics_frames() + int(ceil(release_s * Engine.physics_ticks_per_second)) + 2
		while Engine.get_physics_frames() < deadline:
			assert_true(b.scale.x >= previous - 1e-6, "%s: scale never decreases during release" % sz)
			assert_true(b.scale.x >= scale_key - 1e-6 and b.scale.x <= 1.0 + 1e-6, "%s: release stays in bounds" % sz)
			assert_true(is_equal_approx(b.scale.x, b.scale.y), "%s: uniform scale" % sz)
			assert_true((b.get_global_transform() * (b.size * 0.5)).distance_to(c0) < 0.5, "%s: visual centre stays pinned" % sz)
			assert_eq(touch.get_button_rect("swap_shoulder"), rect0, "%s: layout cell is unchanged" % sz)
			assert_eq(b.self_modulate, Color.WHITE, "%s: no colour pulse" % sz)
			assert_eq(b.modulate.a, alpha0, "%s: alpha is unchanged" % sz)
			assert_true(is_equal_approx(b.modulate.a, touch._alpha("swap_shoulder")), "%s: slot alpha retained" % sz)
			previous = b.scale.x
			await _tree().process_frame
		assert_eq(b.scale, Vector2.ONE, "%s: exact ONE after release plus two physics frames" % sz)
		assert_true(Input.is_action_pressed("swap_shoulder"), "release completes while finger remains held")
		var held_style := b.get_theme_stylebox("normal") as StyleBoxFlat
		assert_true(is_equal_approx(held_style.bg_color.a, float(touch._layout["button_held_alpha"])), "held style remains")
		_Rig.press(ctx, "swap_shoulder", false)
		await _Rig.teardown(ctx)


func _touch(hud: Control, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 1
	event.position = hud.get_button_rect("swap_shoulder").get_center()
	event.pressed = pressed
	hud._input(event)


func test_shoulder_pulse_pins_quadratic_curve_reads_data_restarts_and_suspends() -> void:
	var hud: Control = _HudScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(1152, 648)
	hud.relayout()
	hud.set_process(false)  # only explicit deltas advance this fixture
	var b: Button = hud._buttons["swap_shoulder"]
	var scale_key := float(hud._layout["shoulder_pulse_scale"]["value"])
	var release_s := float(hud._layout["shoulder_pulse_release_s"]["value"])
	_touch(hud, true)
	assert_true(b.scale.is_equal_approx(Vector2.ONE * scale_key), "press uses shipped data scale")
	hud._process(release_s * 0.5)  # no await between press and half-release sample
	assert_true(is_equal_approx(b.scale.x, 1.0 - (1.0 - scale_key) * 0.25), "quadratic half-release (0.9925 shipped); linear fails")
	_touch(hud, false)
	_touch(hud, true)
	assert_true(b.scale.is_equal_approx(Vector2.ONE * scale_key), "a new press mid-pulse restarts at data scale")
	hud._process(release_s)
	assert_eq(b.scale, Vector2.ONE, "full duration gives exact ONE")
	_touch(hud, false)
	# Local fixture override proves scale and duration are read from data, not copied constants.
	hud._layout = hud._layout.duplicate(true)
	var fixture_scale := scale_key * scale_key
	var fixture_release := release_s * 2.0
	hud._layout["shoulder_pulse_scale"]["value"] = fixture_scale
	hud._layout["shoulder_pulse_release_s"]["value"] = fixture_release
	_touch(hud, true)
	assert_true(b.scale.is_equal_approx(Vector2.ONE * fixture_scale), "press reads fixture scale")
	hud._process(fixture_release * 0.5)
	assert_true(is_equal_approx(b.scale.x, 1.0 - (1.0 - fixture_scale) * 0.25), "release reads fixture duration")
	hud.set_suspended(true)
	assert_eq(b.scale, Vector2.ONE, "suspend snaps immediately to ONE")
	assert_true(not Input.is_action_pressed("swap_shoulder"), "suspend releases the held action")
	hud._process(fixture_release)
	assert_eq(b.scale, Vector2.ONE, "cancelled pulse stays at rest")
	hud.queue_free()
