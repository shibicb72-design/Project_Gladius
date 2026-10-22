extends "res://tests/test_case.gd"

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _LookMath := preload("res://scripts/input/look_math.gd")
const _Router := preload("res://scripts/input/input_router.gd")
const _Gamepad := preload("res://scripts/input/providers/gamepad_provider.gd")


# The headless root viewport is only 64x64, so the HUD is given a realistic size explicitly.
const TEST_SIZE := Vector2(1152, 648)


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _new_hud(mode: String = "stick") -> Control:
	var hud: Control = _HudScene.instantiate()
	_root().add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.cfg["look"]["mode"] = mode
	hud.provider.configure(hud.cfg)
	hud.refresh_visibility()
	_fix_size(hud)
	return hud


func _fix_size(hud: Control) -> void:
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = TEST_SIZE


func _touch(hud: Control, idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	hud._input(e)


func _drag(hud: Control, idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	hud._input(e)


func _cap_per_tick(hud: Control) -> float:
	return deg_to_rad(float(hud.cfg["look"]["max_turn_rate_deg_s"])) / _LookMath.tick_hz()


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame


func _router_for(hud: Control) -> InputRouter:
	var r: InputRouter = _Router.new()
	r.add_provider(hud.provider)
	return r


func test_move_stick_forward_and_release() -> void:
	var hud := _new_hud()
	var r := _router_for(hud)
	var start := Vector2(200, 400)
	_touch(hud, 0, start, true)
	_drag(hud, 0, start + Vector2(0, -80), Vector2(0, -80))
	var mv: Vector2 = r.update_frame().move
	assert_true(mv.y < 0.0, "move forward, got %s" % mv)
	assert_true(mv.length() > 0.0 and mv.length() <= 1.0001, "move length in (0,1], got %s" % mv.length())
	_touch(hud, 0, start + Vector2(0, -80), false)
	assert_eq(r.update_frame().move, Vector2.ZERO, "released")
	r.free()
	hud.free()


func test_move_stick_in_match_moves_pawn() -> void:
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
	hud.refresh_visibility()
	_fix_size(hud)
	var before := m.local_player.global_position
	_touch(hud, 0, Vector2(200, 400), true)
	_drag(hud, 0, Vector2(200, 300), Vector2(0, -100))
	await _frames(10)
	var after := m.local_player.global_position
	var d := Vector2(after.x - before.x, after.z - before.z).length()
	assert_true(d > 0.01, "pawn moved horizontally, delta %s" % d)
	_touch(hud, 0, Vector2(200, 300), false)
	m.queue_free()


## Delivers an event through the root viewport's input path (all nodes' _input, as on a device).
## Local coordinates: the headless root window is 64x64, so window->canvas stretching would otherwise
## scale positions out of the HUD zones. Input.parse_input_event is not used: under
## `--headless --script` it never reaches the scene tree (HUD stays at _move_touch == -1).
func _deliver(e: InputEvent, window_coords: bool = false) -> void:
	if window_coords:
		# Real-device order: window pixels in, the viewport's stretch transform maps them to canvas space.
		var xf := _root().get_screen_transform()
		if e is InputEventScreenTouch:
			e.position = xf * e.position
		elif e is InputEventScreenDrag:
			e.position = xf * e.position
			e.relative = xf.basis_xform(e.relative)
		_root().push_input(e, false)
	else:
		_root().push_input(e, true)


## T-MOVE: touch events through the viewport input path into the full HUD -> provider -> router -> pawn chain.
## `window_size` (if set) resizes the real root window first, so the HUD fills the actual viewport
## at that resolution (full-rect anchors + canvas_items stretch) instead of a fixed test size.
func _inject_move_walk(m: MatchRoot, window_size: Vector2i = Vector2i.ZERO, window_coords: bool = false) -> float:
	var tree: SceneTree = Engine.get_main_loop()
	await _frames(3)
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	if window_size != Vector2i.ZERO:
		_root().size = window_size
		await _frames(3)
		var vp := _root().get_visible_rect().size
		var want := float(window_size.x) / float(window_size.y)
		assert_true(absf(vp.x / vp.y - want) < 0.01, "viewport aspect matches window %s, got %s" % [window_size, vp])
		assert_true(hud.size.is_equal_approx(vp), "HUD fills the viewport at %s: hud %s vp %s" % [window_size, hud.size, vp])
		if window_coords:
			var xf_scale := _root().get_screen_transform().get_scale()
			assert_true(absf(xf_scale.y - 1.0) > 0.1, "window-coords variant runs through a non-identity screen transform at %s, scale %s" % [window_size, xf_scale])
	else:
		_fix_size(hud)
	var zone: Rect2 = hud._zone_rect("move_zone")
	var start := zone.get_center()
	var before := m.local_player.global_position
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.position = start
	down.pressed = true
	_deliver(down, window_coords)
	await tree.process_frame
	assert_eq(hud._move_touch, 0, "touch-down in the move zone reached the HUD via Viewport.push_input (%s coordinates)" % ("window" if window_coords else "canvas"))
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = start + Vector2(0, -hud._radius())
	drag.relative = Vector2(0, -hud._radius())
	_deliver(drag, window_coords)
	await _frames(20)
	var after := m.local_player.global_position
	var up := InputEventScreenTouch.new()
	up.index = 0
	up.position = drag.position
	up.pressed = false
	_deliver(up, window_coords)
	await tree.process_frame
	return Vector2(after.x - before.x, after.z - before.z).length()


func test_move_touch_events_move_pawn_offline() -> void:
	await _move_offline(Vector2i.ZERO)


func test_move_touch_offline_folded_2520x1080() -> void:
	await _move_offline(Vector2i(2520, 1080))


func test_move_touch_offline_unfolded_2176x1812() -> void:
	await _move_offline(Vector2i(2176, 1812))


func test_move_touch_host_folded_2520x1080() -> void:
	await _move_host(Vector2i(2520, 1080))


func test_move_touch_host_unfolded_2176x1812() -> void:
	await _move_host(Vector2i(2176, 1812))


func test_move_touch_events_move_pawn_as_host() -> void:
	await _move_host(Vector2i.ZERO)


func test_move_window_coords_offline_folded_2520x1080() -> void:
	await _move_offline(Vector2i(2520, 1080), true)


func test_move_window_coords_offline_unfolded_2176x1812() -> void:
	await _move_offline(Vector2i(2176, 1812), true)


func test_move_window_coords_host_folded_2520x1080() -> void:
	await _move_host(Vector2i(2520, 1080), true)


func test_move_window_coords_host_unfolded_2176x1812() -> void:
	await _move_host(Vector2i(2176, 1812), true)


func _move_offline(window_size: Vector2i, window_coords: bool = false) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	assert_true(m.begin(), "offline match begins")
	var d: float = await _inject_move_walk(m, window_size, window_coords)
	assert_true(d > 0.05, "offline %s (window_coords=%s): injected touch drag moved the pawn, delta %s" % [window_size, window_coords, d])
	m.queue_free()
	_root().size = prev
	await tree.process_frame


func _move_host(window_size: Vector2i, window_coords: bool = false) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var s := NetSession.new()
	s.name = "TMoveHost"
	s.isolated = true
	tree.root.add_child(s)
	s.host_game()
	s.lobby.host_open(2, 3, "Host")
	assert_true(s.lobby.start_match(), "host lobby starts")
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = s.lobby.match_seed
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 0.0
	assert_true(m.begin(), "host match begins")
	var d: float = await _inject_move_walk(m, window_size, window_coords)
	assert_true(d > 0.05, "host %s (window_coords=%s): injected touch drag moved the pawn, delta %s" % [window_size, window_coords, d])
	m.queue_free()
	_root().size = prev
	s.leave()
	s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await tree.process_frame
	await tree.process_frame


func test_look_is_capped_in_both_modes() -> void:
	for mode in ["stick", "drag"]:
		var hud := _new_hud(mode)
		var cap := _cap_per_tick(hud)
		var start := Vector2(900, 300)
		_touch(hud, 1, start, true)
		_drag(hud, 1, start + Vector2(10000, 10000), Vector2(10000, 10000))
		var v: Vector2 = hud.provider.get_look()
		assert_true(absf(v.x) <= cap + 1e-6 and absf(v.y) <= cap + 1e-6, "%s capped, got %s cap %s" % [mode, v, cap])
		assert_true(v.x > 0.0 and v.y > 0.0, "%s direction" % mode)
		hud.free()


func test_small_drag_is_small_and_directional() -> void:
	var hud := _new_hud("drag")
	var cap := _cap_per_tick(hud)
	_touch(hud, 1, Vector2(900, 300), true)
	_drag(hud, 1, Vector2(905, 300), Vector2(5, 0))
	var v: Vector2 = hud.provider.get_look()
	assert_true(v.x > 0.0 and v.x < cap and is_zero_approx(v.y), "small right drag, got %s" % v)
	assert_eq(hud.provider.get_look(), Vector2.ZERO, "accumulator consumed")
	hud.free()
	var hud2 := _new_hud("stick")
	var radius: float = hud2._radius()
	_touch(hud2, 1, Vector2(900, 300), true)
	_drag(hud2, 1, Vector2(900 + radius * 0.3, 300), Vector2(radius * 0.3, 0))
	var s: Vector2 = hud2.provider.get_look()
	assert_true(s.x > 0.0 and s.x < cap, "partial stick small, got %s" % s)
	hud2.free()


func test_gamepad_obeys_cap() -> void:
	var cfg := {"look": {"max_turn_rate_deg_s": 90.0, "stick_rate_deg_s": 720.0}}
	var cap := deg_to_rad(90.0) / _LookMath.tick_hz()
	var v := _LookMath.look_from_stick(Vector2(1, -1), cfg, _LookMath.tick_hz())
	assert_true(absf(v.x) <= cap + 1e-9 and absf(v.y) <= cap + 1e-9, "stick math capped, got %s" % v)
	var gp = _Gamepad.new()
	gp.configure(cfg)
	Input.action_press("look_right", 1.0)
	Input.action_press("look_down", 1.0)
	var g: Vector2 = gp.get_look()
	Input.action_release("look_right")
	Input.action_release("look_down")
	assert_true(g.x > 0.0 and g.x <= cap + 1e-9 and g.y <= cap + 1e-9, "gamepad capped, got %s cap %s" % [g, cap])


func test_tap_in_look_zone_pulses_fire() -> void:
	for mode in ["stick", "drag"]:
		var hud := _new_hud(mode)
		_touch(hud, 2, Vector2(900, 300), true)
		_touch(hud, 2, Vector2(900, 300), false)
		assert_true(Input.is_action_pressed("fire"), "%s tap presses fire" % mode)
		hud._process(1.0)
		assert_true(not Input.is_action_pressed("fire"), "%s fire released" % mode)
		hud.free()


func test_look_drag_is_not_a_tap() -> void:
	var hud := _new_hud("drag")
	_touch(hud, 2, Vector2(900, 300), true)
	_drag(hud, 2, Vector2(1000, 300), Vector2(100, 0))
	_touch(hud, 2, Vector2(1000, 300), false)
	assert_true(not Input.is_action_pressed("fire"), "drag does not fire")
	hud.free()


func test_move_touch_never_fires_or_aims() -> void:
	var hud := _new_hud()
	_touch(hud, 0, Vector2(200, 400), true)
	_drag(hud, 0, Vector2(250, 350), Vector2(50, -50))
	assert_true(not Input.is_action_pressed("fire"), "no fire from move stick")
	assert_true(not Input.is_action_pressed("aim"), "no aim from move stick")
	_touch(hud, 0, Vector2(250, 350), false)
	assert_true(not Input.is_action_pressed("fire"), "no fire after release")
	hud.free()


const BUTTON_LABELS := {"fire": "Fire", "aim": "Aim", "reload": "Reload", "swap_weapon": "Swap", "jump": "Jump"}


func test_each_button_presses_and_releases_its_action() -> void:
	var hud := _new_hud()
	for action in BUTTON_LABELS:
		var c: Vector2 = hud.get_button_rect(action).get_center()
		_touch(hud, 3, c, true)
		assert_true(Input.is_action_pressed(action), "%s pressed on touch down" % action)
		assert_eq(hud._move_touch, -1, "%s does not start move" % action)
		assert_eq(hud._look_touch, -1, "%s does not start look" % action)
		_touch(hud, 3, c, false)
		assert_true(not Input.is_action_pressed(action), "%s released on touch up" % action)
	hud.free()


func test_fire_button_works_with_move_finger_held() -> void:
	var hud := _new_hud()
	_touch(hud, 0, Vector2(200, 400), true)
	_drag(hud, 0, Vector2(200, 320), Vector2(0, -80))
	_touch(hud, 1, hud.get_button_rect("fire").get_center(), true)
	assert_true(Input.is_action_pressed("fire"), "fire pressed by second finger")
	assert_true(hud.provider.move_value != Vector2.ZERO, "move still non-zero")
	_touch(hud, 1, hud.get_button_rect("fire").get_center(), false)
	assert_true(not Input.is_action_pressed("fire"), "fire released")
	assert_true(hud.provider.move_value != Vector2.ZERO, "move still held")
	_touch(hud, 0, Vector2(200, 320), false)
	hud.free()


func test_hud_has_five_labelled_buttons_and_no_sprint() -> void:
	var hud := _new_hud()
	assert_true(hud.visible, "HUD visible with force_touch_hud")
	assert_eq(hud.get_button_actions().size(), 5, "five buttons")
	for action in BUTTON_LABELS:
		assert_true(hud.get_button_actions().has(action), "button %s" % action)
		assert_eq(hud.get_button_label(action), BUTTON_LABELS[action], "label of %s" % action)
		var b := hud._buttons[action] as Button
		assert_eq(b.mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s mouse_filter" % action)
		assert_eq(b.focus_mode, Control.FOCUS_NONE, "%s focus_mode" % action)
	assert_true(not InputMap.has_action("sprint"), "no sprint action")
	assert_true(not hud.get_button_actions().has("sprint"), "no sprint button")
	hud.free()


func test_relayout_folded_and_unfolded() -> void:
	var hud := _new_hud()
	var min_frac: float = hud.cfg["touch_layout"]["button_size_frac_of_height"]
	for sz in [Vector2(2316, 1000), Vector2(2184, 1968)]:
		hud.size = sz
		hud.relayout()
		var view := Rect2(Vector2.ZERO, sz)
		var move_zone: Rect2 = hud._zone_rect("move_zone")
		var rects: Array = []
		for action in BUTTON_LABELS:
			var r: Rect2 = hud.get_button_rect(action)
			assert_true(view.encloses(r), "%s inside %s, got %s" % [action, sz, r])
			assert_true(r.size.y >= min_frac * sz.y - 0.001, "%s height at %s" % [action, sz])
			assert_true(not r.intersects(move_zone), "%s clear of move zone at %s" % [action, sz])
			for other in rects:
				assert_true(not r.intersects(other), "%s overlaps another at %s" % [action, sz])
			rects.append(r)
	hud.free()


func _check_rest_sticks(sz: Vector2) -> void:
	var hud := _new_hud()
	hud.size = sz
	hud.relayout()
	var view := Rect2(Vector2.ZERO, sz)
	var sticks := {"move": hud.move_stick, "look": hud.look_stick}
	var rects: Array = []
	for name in sticks:
		var s: Control = sticks[name]
		assert_true(s != null and s.is_visible_in_tree(), "%s stick visible at rest at %s" % [name, sz])
		var r := s.get_global_rect()
		assert_true(r.size.x > 0.0 and r.size.y > 0.0, "%s stick has size at %s" % [name, sz])
		assert_true(view.encloses(r), "%s stick inside viewport %s, got %s" % [name, sz, r])
		for action in BUTTON_LABELS:
			assert_true(not r.intersects(hud.get_button_rect(action)), "%s stick clear of %s at %s" % [name, action, sz])
		for other in rects:
			assert_true(not r.intersects(other), "sticks overlap at %s" % sz)
		rects.append(r)
	assert_true(hud.move_stick.get_global_rect().get_center().x < hud.look_stick.get_global_rect().get_center().x, "move stick left of look stick at %s" % sz)
	hud.free()


func test_both_sticks_visible_at_rest_folded_2520x1080() -> void:
	_check_rest_sticks(Vector2(2520, 1080))


func test_both_sticks_visible_at_rest_unfolded_2176x1812() -> void:
	_check_rest_sticks(Vector2(2176, 1812))


## Nothing on the gameplay HUD (stat bars, labels, ammo text) may overlap a stick or a button.
func _check_hud_clear(sz: Vector2) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var touch := _new_hud()
	touch.size = sz
	touch.relayout()
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
	var touch_items := {"move_stick": touch.move_stick.get_global_rect(), "look_stick": touch.look_stick.get_global_rect()}
	for action in BUTTON_LABELS:
		touch_items["button_" + action] = touch.get_button_rect(action)
	var view := Rect2(Vector2.ZERO, sz)
	for hname in hud_items:
		var c: Control = hud_items[hname]
		var r := c.get_global_rect()
		assert_true(r.size.x > 0.0 and r.size.y > 0.0, "%s has size at %s" % [hname, sz])
		assert_true(view.encloses(r), "%s inside viewport %s, got %s" % [hname, sz, r])
		for tname in touch_items:
			assert_true(not r.intersects(touch_items[tname]), "%s %s overlaps %s %s at %s" % [hname, r, tname, touch_items[tname], sz])
	game.free()
	touch.free()


func test_hud_clear_of_sticks_and_buttons_folded() -> void:
	await _check_hud_clear(Vector2(1512, 648))
	await _check_hud_clear(Vector2(2520, 1080))


func test_hud_clear_of_sticks_and_buttons_unfolded() -> void:
	await _check_hud_clear(Vector2(1152, 959))
	await _check_hud_clear(Vector2(2176, 1812))


func test_move_stick_recentres_on_touch_and_returns_to_rest() -> void:
	var hud := _new_hud()
	var rest: Vector2 = hud.move_stick.get_global_rect().get_center()
	var p := Vector2(300, 400)
	_touch(hud, 0, p, true)
	assert_true(hud.move_stick.get_global_rect().get_center().is_equal_approx(p), "move stick centred under thumb")
	_touch(hud, 0, p, false)
	assert_true(hud.move_stick.get_global_rect().get_center().is_equal_approx(rest), "move stick back at rest")
	hud.free()


func test_mouse_emulation_off_while_hud_active_and_restored() -> void:
	Input.emulate_mouse_from_touch = true
	var hud := _new_hud()
	assert_true(not Input.emulate_mouse_from_touch, "emulation off while HUD active")
	hud.free()
	assert_true(Input.emulate_mouse_from_touch, "emulation restored after HUD freed")


# --- G2: VirtualJoystick trial. New tests run under both move_stick modes. ---

const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Platform := preload("res://scripts/platform/platform_services.gd")
const MOVE_MODES := ["virtual", "custom"]
const FOLD_SIZES := [Vector2(2520, 1080), Vector2(2176, 1812)]


## A HUD built with the move stick forced to `mode` (the previous override is restored afterwards).
func _hud_mode(mode: String) -> Control:
	var prev: String = _TouchHud.move_stick_override
	_TouchHud.move_stick_override = mode
	var hud := _new_hud()
	_TouchHud.move_stick_override = prev
	return hud


func test_move_stick_visible_with_no_touch_in_both_modes() -> void:
	for mode in MOVE_MODES:
		var hud := _hud_mode(mode)
		assert_eq(hud.move_mode, mode, "%s: mode applied" % mode)
		assert_true(hud.move_stick.is_visible_in_tree(), "%s: move stick visible with no touch" % mode)
		assert_eq(hud._move_touch, -1, "%s: no touch yet" % mode)
		if mode == "virtual":
			assert_true(hud.move_stick is VirtualJoystick, "virtual: move_stick is a VirtualJoystick")
			assert_eq(hud.move_stick.visibility_mode, VirtualJoystick.VISIBILITY_ALWAYS, "virtual: VISIBILITY_ALWAYS")
			assert_eq(hud.move_stick.joystick_mode, VirtualJoystick.JOYSTICK_DYNAMIC, "virtual: JOYSTICK_DYNAMIC")
		hud.free()


func test_move_stick_touch_target_at_least_48dp_at_fold_sizes() -> void:
	for mode in MOVE_MODES:
		for dpi in [0.0, 420.0]:  # 0 = platform default (160 dpi, 1 dp = 1 px); 420 = a Fold-class density
			_Platform.dpi_override = dpi
			for sz in FOLD_SIZES:
				var hud := _hud_mode(mode)
				hud.size = sz
				hud.relayout()
				var dp: float = hud.get_move_target_dp()
				assert_true(dp >= 48.0, "%s: move stick target %.1f dp >= 48 at %s, dpi %s" % [mode, dp, sz, dpi])
				hud.free()
	_Platform.dpi_override = 0.0


## Real viewport input path (not hud._input) so the VirtualJoystick receives its touch like on a device.
func test_multitouch_move_and_look_reach_one_input_frame() -> void:
	for mode in MOVE_MODES:
		var hud := _hud_mode(mode)
		var r := _router_for(hud)
		var move_c: Vector2 = hud._zone_rect("move_zone").get_center()
		var look_c: Vector2 = hud._zone_rect("look_zone").get_center()
		var t0 := InputEventScreenTouch.new()
		t0.index = 0
		t0.position = move_c
		t0.pressed = true
		_deliver(t0)
		var t1 := InputEventScreenTouch.new()
		t1.index = 1
		t1.position = look_c
		t1.pressed = true
		_deliver(t1)
		var d0 := InputEventScreenDrag.new()
		d0.index = 0
		d0.position = move_c + Vector2(0, -hud._radius())
		d0.relative = Vector2(0, -hud._radius())
		_deliver(d0)
		var d1 := InputEventScreenDrag.new()
		d1.index = 1
		d1.position = look_c + Vector2(hud._radius() * 0.8, 0)
		d1.relative = Vector2(hud._radius() * 0.8, 0)
		_deliver(d1)
		await _frames(2)
		var f: InputFrame = r.update_frame()
		assert_true(f.move != Vector2.ZERO, "%s: move non-zero with look held, got %s" % [mode, f.move])
		assert_true(f.look != Vector2.ZERO, "%s: look non-zero with move held, got %s" % [mode, f.look])
		for e in [t0, t1]:
			e.pressed = false
			_deliver(e)
		await _frames(2)
		assert_eq(r.update_frame().move, Vector2.ZERO, "%s: move released" % mode)
		r.free()
		hud.free()


func test_touch_started_on_look_side_never_grabs_move_stick() -> void:
	for mode in MOVE_MODES:
		var hud := _hud_mode(mode)
		var r := _router_for(hud)
		var look_c: Vector2 = hud._zone_rect("look_zone").get_center()
		var inside_move: Vector2 = hud.get_move_rest()
		var t := InputEventScreenTouch.new()
		t.index = 1
		t.position = look_c
		t.pressed = true
		_deliver(t)
		for p in [look_c.lerp(inside_move, 0.5), inside_move, inside_move + Vector2(0, -hud._radius())]:
			var d := InputEventScreenDrag.new()
			d.index = 1
			d.position = p
			d.relative = Vector2(-50, 0)
			_deliver(d)
		await _frames(2)
		assert_eq(r.update_frame().move, Vector2.ZERO, "%s: look-side finger dragged into the move zone gives no move" % mode)
		assert_eq(hud._move_touch, -1, "%s: move touch not grabbed" % mode)
		assert_eq(hud.provider.move_value, Vector2.ZERO, "%s: move_value stays zero" % mode)
		if mode == "custom":
			assert_true(hud.move_stick.get_global_rect().get_center().is_equal_approx(hud.get_move_rest()), "custom: move stick still at rest")
		t.pressed = false
		_deliver(t)
		r.free()
		hud.free()
