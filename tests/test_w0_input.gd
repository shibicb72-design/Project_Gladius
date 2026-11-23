extends "res://tests/test_case.gd"
## W0 (PC browser, keyboard and mouse; brief items 2, 3 and 6, binding fixes 3-8, 13, 14): the PC key map, the press
## paths (E interact / revive hold, F cover, the wheel through the router latch), Shift sprint (and out of cover),
## mouse look sensitivity from data through the Camera / ADS tables, the touch HUD hidden without a touchscreen with
## the HUD info and one crosshair kept, and the mouse capture state machine (MouseCapture, owned by PauseMenu).
## The mouse mode is always a fake through the seam (MouseCapture.get_mode / set_mode): headless ignores the real one.

const _MatchScene := preload("res://scenes/match/match.tscn")

## action -> the physical keycodes / mouse buttons W0 binds (fix 4). Gamepad events are not listed.
const KEYS := {
	"move_forward": [KEY_W], "move_left": [KEY_A], "move_back": [KEY_S], "move_right": [KEY_D],
	"sprint": [KEY_SHIFT], "jump": [KEY_SPACE], "crouch": [KEY_C, KEY_CTRL], "prone": [KEY_Z],
	"interact": [KEY_E], "cover": [KEY_F], "swap_shoulder": [KEY_V], "reload": [KEY_R],
	"swap_weapon": [KEY_Q, KEY_1, KEY_2], "pause": [KEY_ESCAPE],
}
const BUTTONS := {
	"fire": [MOUSE_BUTTON_LEFT], "aim": [MOUSE_BUTTON_RIGHT],
	"swap_weapon": [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN],
}

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame
		await tree().process_frame


func _key(code: int, pressed: bool) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code as Key
	k.pressed = pressed
	return k


func _mouse(button: int, pressed: bool, pos: Vector2 = Vector2(400, 300)) -> InputEventMouseButton:
	var b := InputEventMouseButton.new()
	b.button_index = button as MouseButton
	b.pressed = pressed
	b.position = pos
	b.global_position = pos
	return b


## A fake mouse mode for one MouseCapture: [mode, set_mode calls]. grant=false refuses capture (a browser re-lock refusal).
func _fake(c: MouseCapture, grant: bool = true) -> Array:
	var st := [Input.MOUSE_MODE_VISIBLE, 0]
	c.get_mode = func() -> int: return st[0]
	c.set_mode = func(v: int) -> void:
		st[1] += 1
		if grant or v != Input.MOUSE_MODE_CAPTURED:
			st[0] = v
	return st


func _event_id(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		return "key %d" % (k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode)
	if e is InputEventMouseButton:
		return "mouse %d" % (e as InputEventMouseButton).button_index
	if e is InputEventJoypadButton:
		return "pad %d" % (e as InputEventJoypadButton).button_index
	if e is InputEventJoypadMotion:
		var j := e as InputEventJoypadMotion
		return "axis %d %s" % [j.axis, "+" if j.axis_value > 0.0 else "-"]
	return e.as_text()


# ---- InputMap ----------------------------------------------------------------------------------

func test_pc_bindings_are_in_the_input_map() -> void:
	for action: String in KEYS:
		assert_true(InputMap.has_action(action), "InputMap has %s" % action)
		for code: int in KEYS[action]:
			assert_true(_key(code, true).is_action(action), "%s bound to %s" % [action, OS.get_keycode_string(code as Key)])
	for action: String in BUTTONS:
		for b: int in BUTTONS[action]:
			assert_true(_mouse(b, true).is_action(action), "%s bound to mouse button %d" % [action, b])
	# Left Shift / Left Ctrl as asked; the binding leaves the location unspecified, so a browser that reports no key
	# location still matches (the right-hand keys also match).
	var left_shift := _key(KEY_SHIFT, true)
	left_shift.location = KEY_LOCATION_LEFT
	assert_true(left_shift.is_action("sprint"), "Left Shift sprints")
	var left_ctrl := _key(KEY_CTRL, true)
	left_ctrl.location = KEY_LOCATION_LEFT
	assert_true(left_ctrl.is_action("crouch"), "Left Ctrl crouches")


## A conflict: the same physical key, mouse button, pad button or pad axis direction in two different gameplay
## actions. The engine's ui_* built-ins are excluded (they share keys with gameplay by design: ui_cancel = Esc,
## ui_accept / ui_select = Space, the ui_ arrows = look_* arrows), and so are editor-namespaced actions ("a/b").
func test_no_event_is_bound_to_two_gameplay_actions() -> void:
	var owner := {}
	var conflicts: Array[String] = []
	for action: StringName in InputMap.get_actions():
		var a := str(action)
		if a.begins_with("ui_") or a.contains("/"):
			continue
		for e in InputMap.action_get_events(action):
			var id := _event_id(e)
			if owner.has(id) and owner[id] != a:
				conflicts.append("%s in %s and %s" % [id, owner[id], a])
			owner[id] = a
	assert_eq(conflicts, [] as Array[String], "no event in two gameplay actions")


# ---- provider: sensitivity, look seam, sprint, wheel latch --------------------------------------

func test_mouse_look_sensitivity_comes_from_data_and_scales_look() -> void:
	var data: float = float(DataRegistry.new().load_file("res://data/input.json")["sensitivity"]["mouse_look"])
	var p := KeyboardMouseProvider.new()
	assert_true(is_equal_approx(p.mouse_sensitivity, data), "mouse_sensitivity = input.json sensitivity.mouse_look (%s)" % data)
	p.configure({"sensitivity": {"mouse_look": 0.004}})
	assert_true(is_equal_approx(p.mouse_sensitivity, 0.004), "configure reads the key")
	p.configure({"sensitivity": {"mouse_look": data}})
	var mode := [Input.MOUSE_MODE_VISIBLE]
	p.get_mouse_mode = func() -> int: return mode[0]
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(10, -4)
	p.handle_event(motion)
	assert_eq(p.get_look(), Vector2.ZERO, "no look while the mouse is not captured (seam says visible)")
	mode[0] = Input.MOUSE_MODE_CAPTURED
	p.handle_event(motion)
	assert_true(p.get_look().is_equal_approx(Vector2(10, -4) * data), "captured: pixels x mouse_look")
	# Through the router: the Camera table (no scope row) and the ADS table scale it (input_router.gd look_percent).
	var r := InputRouter.new()
	r.add_provider(p)
	var row := r.sens.row_for_state("no_scope")
	r.sens.set_value("camera", row, 50.0)
	r.sens.set_value("ads", row, 200.0)
	p.handle_event(motion)
	assert_true(r.update_frame().look.is_equal_approx(Vector2(10, -4) * data * 0.5), "Camera 50 % halves mouse look")
	r.set_ads(true)
	p.handle_event(motion)
	assert_true(r.update_frame().look.is_equal_approx(Vector2(10, -4) * data * 2.0), "ADS 200 % doubles it while aiming")
	r.free()


func test_shift_sprints_through_is_sprinting() -> void:
	var p := KeyboardMouseProvider.new()
	var r := InputRouter.new()
	r.add_provider(p)
	assert_true(not p.is_sprinting() and not r.update_frame().sprint, "no sprint at rest")
	Input.action_press("sprint")
	assert_true(p.is_sprinting(), "Shift held: is_sprinting")
	assert_true(r.update_frame().sprint, "InputFrame.sprint (no new BUTTONS bit)")
	Input.action_release("sprint")
	assert_true(not r.update_frame().sprint, "released: no sprint")
	assert_eq(InputFrame.BUTTONS.size(), 9, "still nine net buttons")
	r.free()


func test_wheel_and_keys_toggle_swap_once_through_the_latch() -> void:
	var r := InputRouter.new()
	r.add_provider(KeyboardMouseProvider.new())
	r.update_frame()
	for b: int in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		r._input(_mouse(b, true))
		r._input(_mouse(b, false))  # a notch is press + release before the tick: polling alone never sees it
		var f := r.update_frame()
		assert_true(f.swap_weapon_just_pressed, "wheel %d: one swap edge through the latch" % b)
		assert_true(not r.update_frame().swap_weapon_just_pressed, "wheel %d: only once" % b)
	r._input(_mouse(MOUSE_BUTTON_LEFT, true))
	r._input(_mouse(MOUSE_BUTTON_LEFT, false))
	assert_true(not r.update_frame().swap_weapon_just_pressed, "a left click is not a swap")
	Input.action_press("swap_weapon")  # Q / 1 / 2: held keys, polled as before
	assert_true(r.update_frame().swap_weapon_just_pressed, "a key press is one edge")
	assert_true(not r.update_frame().swap_weapon_just_pressed, "held: no repeat")
	Input.action_release("swap_weapon")
	r.update_frame()
	r.free()


func test_interact_and_cover_keys_emit_press_and_release() -> void:
	var p := KeyboardMouseProvider.new()
	var r := InputRouter.new()
	r.add_provider(p)
	var got: Array = []
	r.action_triggered.connect(func(a: String) -> void: got.append(["press", a]))
	r.action_released.connect(func(a: String, c: bool) -> void: got.append(["release", a, c]))
	r._input(_key(KEY_E, true))
	var echo := _key(KEY_E, true)
	echo.echo = true
	r._input(echo)
	r._input(_key(KEY_E, false))
	r._input(_key(KEY_F, true))
	r._input(_key(KEY_F, false))
	assert_eq(got, [["press", "interact"], ["release", "interact", false], ["press", "cover"]], "E press/release, F press")
	r.free()


# ---- real match ---------------------------------------------------------------------------------

func _begin(mode: String = "squads", bots: bool = true) -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(1512, 648)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.fill_bots = bots
	m.ground_loot = true
	tree().root.add_child(m)
	await tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	m.director.match_cfg["spawn_protection_s"] = 0.0
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	await frames(3)


func _end() -> void:
	for a in ["sprint", "move_forward", "fire", "interact", "cover"]:
		Input.action_release(a)
	if m.menu_open:
		m.pause_menu.close()
	m.queue_free()
	await tree().process_frame
	tree().paused = false
	tree().root.size = old_size
	AppFlow.profile = old_profile


func test_e_picks_up_then_holds_and_releases_a_revive() -> void:
	await _begin()
	var me := m.local_player
	me.apply_start_kit({"secondary": "gladius_lux"})  # empty gun slots: the pickup fills one
	for id in m.loot.items.keys():
		var pos: Vector3 = m.loot.items[id]["pos"]
		if Vector2(pos.x - me.global_position.x, pos.z - me.global_position.z).length() < 6.0:
			m.loot.take(id)
	for b in m.bots:
		b.global_position = me.global_position + Vector3(0.0, 0.0, 30.0)  # the director's bot pickup would take it first
	m.loot.drop({"item_id": "pilum_br", "ammo_in_mag": 3, "reserve": 9}, me.global_position)
	assert_true(m.loot.nearest(me.global_position, 2.0) >= 0, "fixture: the gun lies at the pawn's feet")
	m.router._input(_key(KEY_E, true))
	m.router._input(_key(KEY_E, false))
	assert_true(me.loadout.slots[0] != null and me.loadout.slots[0].def.id == "pilum_br", "E picked up the Pilum BR")
	# Revive: a downed squad mate next to the pawn; E held revives, the E release ends it.
	var mate: Pawn = null
	var enemy: Pawn = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == me:
			continue
		if p.squad_id == me.squad_id and mate == null:
			mate = p
		elif p.squad_id != me.squad_id and enemy == null:
			enemy = p
	assert_true(mate != null and enemy != null, "fixture: a mate and an enemy")
	if mate != null and enemy != null:
		mate.global_position = me.global_position + me.global_transform.basis.x * 1.0
		mate.bridge.state.shield = 0.0
		mate.bridge.state.health = 1.0
		mate.receive_hit(DataRegistry.new().get_weapon_def("sagittarii_rifle"), false, enemy.squad_id, enemy.player_id)
		await frames(2)
		assert_true(mate.is_downed(), "fixture: mate downed")
		m.router._input(_key(KEY_E, true))
		assert_true(m.director.is_reviving(me.player_id), "E press starts the revive (begin_revive)")
		await frames(3)
		assert_true(m.director.is_reviving(me.player_id), "held: still reviving")
		m.router._input(_key(KEY_E, false))
		assert_true(not m.director.is_reviving(me.player_id), "E release ends it (end_revive)")
	await _end()


func test_shift_leaves_cover_and_sprints() -> void:
	await _begin("solo", false)
	var pawn := m.local_player
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(1000, -0.1, 0)
	var fs := CollisionShape3D.new()
	fs.name = "Shape"
	var fb := BoxShape3D.new()
	fb.size = Vector3(30, 0.2, 30)
	fs.shape = fb
	floor_body.add_child(fs)
	m.add_child(floor_body)
	var wall := StaticBody3D.new()
	wall.position = Vector3(1000, 1.1, -0.5)
	var ws := CollisionShape3D.new()
	ws.name = "Shape"  # the cover_wall contract (cover_probe.gd reads the wall's "Shape")
	var wb := BoxShape3D.new()
	wb.size = Vector3(4, 2.2, 1)
	ws.shape = wb
	wall.add_child(ws)
	wall.add_to_group(&"cover_wall")
	m.add_child(wall)
	pawn.position = Vector3(1000, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await frames(2)
	m.router._input(_key(KEY_F, true))  # F: the Cover press path (action_triggered -> Pawn.handle_action_press)
	m.router._input(_key(KEY_F, false))
	for i in 90:
		await frames(1)
		if pawn.cover.state == CoverController.State.IN_COVER and not pawn.is_cover_turning():
			break
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "F entered cover")
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await frames(2)
	assert_true(pawn.cover.state != CoverController.State.IN_COVER, "Shift (sprint rising edge) leaves cover")
	for i in 60:
		if pawn.cover.state == CoverController.State.FREE and pawn.sprint_factor > 1.0:
			break
		await frames(1)
	assert_eq(pawn.cover.state, CoverController.State.FREE, "the exit completes")
	assert_true(pawn.sprint_factor > 1.0, "and sprints (sprint_factor %s)" % pawn.sprint_factor)
	await _end()


func test_touch_hud_hidden_without_a_touchscreen_and_the_hud_info_stays() -> void:
	await _begin("solo", false)
	var touch: Control = m.get_node("Hud/TouchHud")
	assert_true(not PlatformServices.new().is_touch_device(), "headless: no touchscreen")
	assert_true(not touch.should_show() and not touch.visible, "touch HUD hidden (buttons, sticks, look area)")
	var ev := InputEventScreenTouch.new()
	ev.index = 3
	ev.pressed = true
	ev.position = tree().root.get_screen_transform() * touch.get_move_rest()
	tree().root.push_input(ev, false)
	await frames(1)
	assert_eq(touch.provider.move_value, Vector2.ZERO, "a touch on the stick area moves nothing")
	assert_true(not touch.provider.is_sprinting(), "and starts no sprint")
	for a in ["fire", "jump", "reload", "crouch", "swap_weapon", "aim"]:
		assert_true(not Input.is_action_pressed(a), "no touch button holds %s" % a)
	ev = ev.duplicate() as InputEventScreenTouch
	ev.pressed = false
	tree().root.push_input(ev, false)
	var hud := m.hud
	for w: Control in [hud.health_bar, hud.ammo_label, hud.crosshair]:
		assert_true(w != null and w.is_visible_in_tree(), "HUD info shown: %s" % w)
	for w: Control in [hud.health_bar, hud.ammo_label, hud.crosshair, hud.banner_label, hud.minimap]:
		if w != null:
			assert_true(not touch.is_ancestor_of(w), "%s is not part of the touch HUD" % w)
	if hud.minimap != null:
		assert_true(hud.minimap.is_visible_in_tree(), "minimap shown")
	var game_huds := 0
	for n in m.find_children("*", "Control", true, false):
		if n is GameHud:
			game_huds += 1
	assert_eq(game_huds, 1, "one GameHud: exactly one crosshair")
	await _end()


# ---- mouse capture state machine ----------------------------------------------------------------

func test_capture_state_machine_unit() -> void:
	var c := MouseCapture.new()
	var st := _fake(c)
	var pauses := [0]
	c.pause_requested.connect(func() -> void: pauses[0] += 1)
	c.on_click()
	assert_eq(st[0], Input.MOUSE_MODE_CAPTURED, "click captures")
	assert_eq(c.state, MouseCapture.State.CAPTURED, "CAPTURED")
	c.on_escape()
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "Esc releases")
	assert_eq(pauses[0], 1, "and asks for the menu")
	assert_eq(c.state, MouseCapture.State.MENU, "MENU")
	c.on_click()
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "a click on the open menu does not capture")
	c.on_menu_closed()
	for i in 5:
		c.poll()
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "resume never recaptures by itself")
	assert_eq(c.state, MouseCapture.State.FREE, "FREE")
	c.on_click()
	assert_eq(c.state, MouseCapture.State.CAPTURED, "the next click recaptures")
	# Capture lost with no key event (the browser ate Esc, or the tab lost focus).
	st[0] = Input.MOUSE_MODE_VISIBLE
	c.poll()
	assert_eq(pauses[0], 2, "capture loss asks for the menu")
	c.poll()
	assert_eq(pauses[0], 2, "once")
	c.on_menu_opened()
	c.on_menu_closed()
	# A refused re-lock (Chrome right after Esc) is never stuck: FREE, and every click asks again.
	var c2 := MouseCapture.new()
	var st2 := _fake(c2, false)
	c2.on_click()
	c2.poll()
	assert_eq(c2.state, MouseCapture.State.FREE, "refused: stays FREE")
	c2.on_click()
	assert_eq(st2[1], 2, "each click asks again")


func test_capture_in_a_match_click_esc_loss_and_resume() -> void:
	await _begin("solo", false)
	var pm := m.pause_menu
	var st := _fake(pm.capture)
	var centre := Vector2(tree().root.size) * 0.5
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, true, centre), true)
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, false, centre), true)
	Input.action_release("fire")
	assert_eq(st[0], Input.MOUSE_MODE_CAPTURED, "a click in the match captures")
	assert_eq(pm.capture.state, MouseCapture.State.CAPTURED, "CAPTURED")
	m.router.update_frame()
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(20, 0)
	m.router._input(motion)
	assert_true(m.router.update_frame().look.x > 0.0, "mouse look reads the same seam (captured)")
	# Esc while captured: release + pause (desktop delivers the key).
	tree().root.push_input(_key(KEY_ESCAPE, true), true)
	tree().root.push_input(_key(KEY_ESCAPE, false), true)
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "Esc releases")
	assert_true(pm.is_open and m.menu_open and tree().paused, "and pauses (offline: the tree)")
	# Esc in the menu resumes; no recapture until the next click.
	tree().root.push_input(_key(KEY_ESCAPE, true), true)
	tree().root.push_input(_key(KEY_ESCAPE, false), true)
	assert_true(not pm.is_open and not tree().paused, "Esc resumes")
	await frames(3)
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "resume does not recapture")
	m.router._input(motion)
	assert_eq(m.router.update_frame().look, Vector2.ZERO, "no mouse look while not captured")
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, true, centre), true)
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, false, centre), true)
	Input.action_release("fire")
	await frames(1)
	assert_eq(pm.capture.state, MouseCapture.State.CAPTURED, "the next click recaptures")
	# Capture lost with no key event: the mode changes under us; the next frame pauses.
	st[0] = Input.MOUSE_MODE_VISIBLE
	await tree().process_frame
	await tree().process_frame
	assert_true(pm.is_open and tree().paused, "capture loss opens the menu and pauses")
	pm.close()
	assert_true(not tree().paused, "resume unpauses")
	await frames(2)
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "and does not recapture")
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, true, centre), true)
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, false, centre), true)
	Input.action_release("fire")
	assert_eq(st[0], Input.MOUSE_MODE_CAPTURED, "captured again before leaving")
	await _end()
	assert_eq(st[0], Input.MOUSE_MODE_VISIBLE, "leaving the match leaves the cursor free")


func test_touch_device_ignores_esc_and_clicks_for_capture() -> void:
	var was := PlatformServices.simulate_touchscreen
	PlatformServices.simulate_touchscreen = true
	await _begin("solo", false)
	var st := _fake(m.pause_menu.capture)
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, true), true)
	tree().root.push_input(_mouse(MOUSE_BUTTON_LEFT, false), true)
	Input.action_release("fire")
	tree().root.push_input(_key(KEY_ESCAPE, true), true)
	tree().root.push_input(_key(KEY_ESCAPE, false), true)
	assert_eq(st[1], 0, "touch device: no capture request")
	assert_true(not m.pause_menu.is_open, "touch device: Esc does not open the menu (the gear does)")
	PlatformServices.simulate_touchscreen = was
	await _end()
