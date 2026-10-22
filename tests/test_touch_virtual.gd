extends "res://tests/test_case.gd"
## Move stick = Godot 4.7 VirtualJoystick (the default). Touches go through the viewport GUI path
## (Viewport.push_input), never through move_value or Input.action_press, so every test here fails if the
## joystick is removed or its actions are disconnected from TouchProvider.move_value.
## Moved here from tests/test_touch_controls.gd (G2): the multitouch, look-side, 48 dp and visibility tests.

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _Router := preload("res://scripts/input/input_router.gd")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Platform := preload("res://scripts/platform/platform_services.gd")

const TEST_SIZE := Vector2(1152, 648)
const FOLD_SIZES := [Vector2(2520, 1080), Vector2(2176, 1812)]
const CLEAR_SIZES := [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]
const LAYOUTS := ["floating", "fixed"]


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame


## A HUD with the VirtualJoystick forced on (override), in the given vjoy layout (set through cfg, then rebuilt).
func _hud(layout: String = "floating") -> Control:
	_TouchHud.move_stick_override = "virtual"
	var hud: Control = _HudScene.instantiate()
	_root().add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.cfg["look"]["mode"] = "stick"
	hud.cfg["touch_layout"]["vjoy_layout"] = layout
	hud.provider.configure(hud.cfg)
	hud.rebuild_move_stick()
	hud.refresh_visibility()
	_fix_size(hud, TEST_SIZE)
	return hud


func _fix_size(hud: Control, sz: Vector2) -> void:
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = sz
	hud.relayout()


func _router_for(hud: Control) -> InputRouter:
	var r: InputRouter = _Router.new()
	r.add_provider(hud.provider)
	return r


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	_root().push_input(e, true)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_root().push_input(e, true)


func _move(r: InputRouter) -> Vector2:
	return r.update_frame().move


func test_gui_routed_move_and_release() -> void:
	var hud := _hud()
	var r := _router_for(hud)
	var p := Vector2(200, 400)
	_touch(0, p, true)
	_drag(0, p + Vector2(0, -80), Vector2(0, -80))
	await _frames(2)
	var mv := _move(r)
	assert_true(mv != Vector2.ZERO and mv.y < 0.0, "dragged up through the GUI path gives forward move, got %s" % mv)
	assert_true(mv.length() <= 1.0001, "length <= 1, got %s" % mv.length())
	_touch(0, p + Vector2(0, -80), false)
	await _frames(2)
	assert_eq(_move(r), Vector2.ZERO, "zero after release")
	r.free()
	hud.free()


func _match_with_hud(layout: String) -> Array:
	_TouchHud.move_stick_override = "virtual"
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.begin()
	await _frames(3)
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.cfg["touch_layout"]["vjoy_layout"] = layout
	hud.rebuild_move_stick()
	hud.refresh_visibility()
	_fix_size(hud, TEST_SIZE)
	return [m, hud]


func test_virtual_stick_in_match_moves_pawn() -> void:
	var mh := await _match_with_hud("floating")
	var m: MatchRoot = mh[0]
	var hud: Control = mh[1]
	assert_eq(hud.move_mode, "virtual", "virtual mode")
	var before := m.local_player.global_position
	_touch(0, Vector2(200, 400), true)
	_drag(0, Vector2(200, 300), Vector2(0, -100))
	await _frames(10)
	var after := m.local_player.global_position
	var d := Vector2(after.x - before.x, after.z - before.z).length()
	assert_true(d > 0.01, "pawn moved horizontally, delta %s" % d)
	_touch(0, Vector2(200, 300), false)
	m.queue_free()


func test_fire_button_works_with_virtual_move_finger_held() -> void:
	var hud := _hud()
	_touch(0, Vector2(200, 400), true)
	_drag(0, Vector2(200, 320), Vector2(0, -80))
	var fire_c: Vector2 = hud.get_button_rect("fire").get_center()
	_touch(1, fire_c, true)
	await _frames(2)
	assert_true(Input.is_action_pressed("fire"), "fire pressed by second finger")
	assert_true(hud.provider.move_value != Vector2.ZERO, "move still non-zero")
	_touch(1, fire_c, false)
	await _frames(2)
	assert_true(not Input.is_action_pressed("fire"), "fire released")
	assert_true(hud.provider.move_value != Vector2.ZERO, "move still held")
	_touch(0, Vector2(200, 320), false)
	hud.free()


func test_virtual_stick_visible_with_no_touch_at_4_sizes() -> void:
	for layout in LAYOUTS:
		var hud := _hud(layout)
		for sz in CLEAR_SIZES:
			_fix_size(hud, sz)
			var j := hud.move_stick as VirtualJoystick
			assert_true(j != null, "%s: move_stick is a VirtualJoystick" % layout)
			assert_eq(j.visibility_mode, VirtualJoystick.VISIBILITY_ALWAYS, "%s: VISIBILITY_ALWAYS" % layout)
			assert_true(j.is_visible_in_tree(), "%s: visible with no touch at %s" % [layout, sz])
			assert_eq(hud._move_touch, -1, "no touch yet")
			var want := VirtualJoystick.JOYSTICK_FIXED if layout == "fixed" else VirtualJoystick.JOYSTICK_DYNAMIC
			assert_eq(j.joystick_mode, want, "%s: joystick_mode" % layout)
			var vis: Rect2 = hud.get_move_visual_rect()
			assert_true(vis.size.x > 0.0 and Rect2(Vector2.ZERO, sz).encloses(vis), "%s: drawn base inside viewport at %s, got %s" % [layout, sz, vis])
		hud.free()


func test_move_stick_touch_target_at_least_48dp_at_fold_sizes() -> void:
	for layout in LAYOUTS:
		for dpi in [0.0, 420.0]:  # 0 = platform default (160 dpi, 1 dp = 1 px); 420 = a Fold-class density
			_Platform.dpi_override = dpi
			for sz in FOLD_SIZES:
				var hud := _hud(layout)
				_fix_size(hud, sz)
				var dp: float = hud.get_move_target_dp()
				assert_true(dp >= 48.0, "%s: move stick target %.1f dp >= 48 at %s, dpi %s" % [layout, dp, sz, dpi])
				hud.free()
	_Platform.dpi_override = 0.0


func test_multitouch_move_and_look_reach_one_input_frame() -> void:
	var hud := _hud()
	var r := _router_for(hud)
	var move_c: Vector2 = hud._zone_rect("move_zone").get_center()
	var look_c: Vector2 = hud._zone_rect("look_zone").get_center()
	var rad: float = hud._radius()
	_touch(0, move_c, true)
	_touch(1, look_c, true)
	_drag(0, move_c + Vector2(0, -rad), Vector2(0, -rad))
	_drag(1, look_c + Vector2(rad * 0.8, 0), Vector2(rad * 0.8, 0))
	await _frames(2)
	var f: InputFrame = r.update_frame()
	assert_true(f.move != Vector2.ZERO, "move non-zero with look held, got %s" % f.move)
	assert_true(f.look != Vector2.ZERO, "look non-zero with move held, got %s" % f.look)
	_touch(0, move_c, false)
	_touch(1, look_c, false)
	await _frames(2)
	assert_eq(_move(r), Vector2.ZERO, "move released")
	r.free()
	hud.free()


func test_touch_started_on_look_side_never_grabs_move_stick() -> void:
	for layout in LAYOUTS:
		var hud := _hud(layout)
		var r := _router_for(hud)
		var look_c: Vector2 = hud._zone_rect("look_zone").get_center()
		var inside_move: Vector2 = hud.get_move_rest()
		_touch(1, look_c, true)
		for p in [look_c.lerp(inside_move, 0.5), inside_move, inside_move + Vector2(0, -hud._radius())]:
			_drag(1, p, Vector2(-50, 0))
		await _frames(2)
		assert_eq(_move(r), Vector2.ZERO, "%s: look-side finger dragged into the move zone gives no move" % layout)
		assert_eq(hud._move_touch, -1, "%s: move touch not grabbed" % layout)
		assert_eq(hud.provider.move_value, Vector2.ZERO, "%s: move_value stays zero" % layout)
		_touch(1, look_c, false)
		r.free()
		hud.free()


func test_floating_spawn_in_left_half_only() -> void:
	var hud := _hud("floating")
	var r := _router_for(hud)
	var w := TEST_SIZE.x
	var side: float = (hud.move_stick as VirtualJoystick).joystick_size
	var rest: Vector2 = hud.get_move_rest()
	var centre_left := Vector2(0.25 * w, 0.4 * TEST_SIZE.y)
	for p in [Vector2(0.02 * w, 0.4 * TEST_SIZE.y), centre_left, Vector2(0.5 * w - 6.0, 0.4 * TEST_SIZE.y)]:
		_touch(0, p, true)
		_drag(0, p + Vector2(0, -side), Vector2(0, -side))
		await _frames(2)
		var mv := _move(r)
		assert_true(mv != Vector2.ZERO, "touch at %s grabs the stick, got %s" % [p, mv])
		if p == centre_left:
			# The base spawned under the thumb: a straight-up drag reads as straight up, which it would
			# not if the base had stayed at rest (rest is far to the lower left).
			assert_true(absf(mv.x) < 0.05 and mv.y < -0.9, "base under the thumb at %s, got %s (rest %s)" % [p, mv, rest])
		_touch(0, p + Vector2(0, -side), false)
		await _frames(2)
		assert_eq(_move(r), Vector2.ZERO, "released at %s" % p)
		assert_true(hud.get_move_visual_rect().get_center().is_equal_approx(rest), "base back at move_stick_rest after release")
	for p in [Vector2(0.5 * w, 0.4 * TEST_SIZE.y), Vector2(0.75 * w, 0.4 * TEST_SIZE.y)]:
		_touch(0, p, true)
		_drag(0, p + Vector2(0, -side), Vector2(0, -side))
		await _frames(2)
		assert_eq(_move(r), Vector2.ZERO, "touch at x >= 0.5 of the width at %s never grabs the stick" % p)
		_touch(0, p + Vector2(0, -side), false)
	r.free()
	hud.free()


func test_fixed_layout_stick_moves_pawn_base_stays_and_elsewhere_goes_to_look() -> void:
	var mh := await _match_with_hud("fixed")
	var m: MatchRoot = mh[0]
	var hud: Control = mh[1]
	var j := hud.move_stick as VirtualJoystick
	assert_eq(j.joystick_mode, VirtualJoystick.JOYSTICK_FIXED, "JOYSTICK_FIXED")
	var rest: Vector2 = hud.get_move_rest()
	var rect_before := j.get_global_rect()
	assert_true(rect_before.get_center().is_equal_approx(rest), "fixed stick sits at move_stick_rest")
	# A touch away from the stick, still in the left half: goes to look, never to the stick.
	var away := Vector2(30, 30)
	assert_true(not rect_before.has_point(away) and hud._zone_rect("move_zone").has_point(away), "test point is left half, off the stick")
	_touch(1, away, true)
	_drag(1, away + Vector2(0, 60), Vector2(0, 60))
	await _frames(2)
	assert_eq(hud._move_touch, -1, "touch away from the stick does not grab it")
	assert_eq(hud._look_touch, 1, "touch away from the stick goes to look")
	assert_eq(hud.provider.move_value, Vector2.ZERO, "no move from the away touch")
	_touch(1, away + Vector2(0, 60), false)
	# A touch on the stick moves the pawn and the base does not move.
	var before := m.local_player.global_position
	var side := j.joystick_size
	_touch(0, rest, true)
	_drag(0, rest + Vector2(0, -side * 0.5), Vector2(0, -side * 0.5))
	await _frames(10)
	var after := m.local_player.global_position
	assert_true(Vector2(after.x - before.x, after.z - before.z).length() > 0.01, "pawn moved from the fixed stick")
	assert_true(j.get_global_rect().is_equal_approx(rect_before), "fixed stick control did not move")
	assert_true(hud.get_move_visual_rect().get_center().is_equal_approx(rest), "fixed base did not move")
	_touch(0, rest + Vector2(0, -side * 0.5), false)
	m.queue_free()


## Nothing on the gameplay HUD (stat bars, labels, ammo text) may overlap a stick or a button.
## The move stick is its drawn base (get_move_visual_rect); the touch area is intentionally not drawn.
func _check_hud_clear(sz: Vector2, layout: String) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var touch := _hud(layout)
	_fix_size(touch, sz)
	var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
	_root().add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	game.scores_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.timer_label.text = "10:00"
	game.hill_label.text = "Hill: contested"
	game.weapon_label.text = "Gladius Rifle"
	game.ammo_label.text = "120 / 360"
	await tree.process_frame
	await tree.process_frame
	var hud_items := {
		"shield_bar": game.shield_bar, "health_bar": game.health_bar, "weapon_label": game.weapon_label,
		"ammo_label": game.ammo_label, "scores_label": game.scores_label, "timer_label": game.timer_label,
		"hill_label": game.hill_label}
	var move_rect: Rect2 = touch.get_move_visual_rect()
	var look_rect: Rect2 = touch.look_stick.get_global_rect()
	var touch_items := {"move_stick": move_rect, "look_stick": look_rect}
	for action in touch.get_button_actions():
		touch_items["button_" + action] = touch.get_button_rect(action)
	var view := Rect2(Vector2.ZERO, sz)
	assert_true(not move_rect.intersects(look_rect), "%s: move and look sticks overlap at %s" % [layout, sz])
	if layout == "fixed":
		assert_true(touch.move_stick.get_global_rect().is_equal_approx(move_rect), "fixed: the Control is exactly the stick at %s" % sz)
	for hname in hud_items:
		var c: Control = hud_items[hname]
		var r := c.get_global_rect()
		assert_true(r.size.x > 0.0 and r.size.y > 0.0, "%s has size at %s" % [hname, sz])
		assert_true(view.encloses(r), "%s inside viewport %s, got %s" % [hname, sz, r])
		for tname in touch_items:
			assert_true(not r.intersects(touch_items[tname]), "%s: %s %s overlaps %s %s at %s" % [layout, hname, r, tname, touch_items[tname], sz])
	game.free()
	touch.free()


func test_hud_clear_of_virtual_stick_and_buttons_folded() -> void:
	for layout in LAYOUTS:
		await _check_hud_clear(CLEAR_SIZES[0], layout)
		await _check_hud_clear(CLEAR_SIZES[1], layout)


func test_hud_clear_of_virtual_stick_and_buttons_unfolded() -> void:
	for layout in LAYOUTS:
		await _check_hud_clear(CLEAR_SIZES[2], layout)
		await _check_hud_clear(CLEAR_SIZES[3], layout)
