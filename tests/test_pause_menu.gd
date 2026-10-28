extends "res://tests/test_case.gd"
## In-match menu (gear, top-right): opens only from the gear, never on Android Back; offline it pauses the tree,
## online it only zeroes the local InputFrame; the settings panel is the main menu's own scene.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _PauseScene := preload("res://scenes/ui/pause_menu.tscn")
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const TEST_SIZE := Vector2(1152, 648)
const PROFILE_PATH := "user://test_pause_menu_profile.json"
const BUTTON_ACTIONS := ["fire", "reload", "jump", "melee", "swap"]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func _push(e: InputEvent) -> void:
	_root().push_input(e, true)  # local coordinates, as tests/test_touch_controls.gd _deliver


func _tap(pos: Vector2, idx: int = 0) -> void:
	var down := InputEventScreenTouch.new()
	down.index = idx
	down.position = pos
	down.pressed = true
	_push(down)
	var up := InputEventScreenTouch.new()
	up.index = idx
	up.position = pos
	up.pressed = false
	_push(up)


## A click as the emulated mouse delivers it on a device (hover first, then press and release).
func _click(pos: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	_push(move)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = pos
		e.global_position = pos
		e.pressed = pressed
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		_push(e)


func _click_button(b: Button) -> void:
	await _tree().process_frame  # containers sort on the idle frame
	await _tree().process_frame
	_click(b.get_global_rect().get_center())
	await _frames(1)


func _new_match(online: bool) -> Dictionary:
	var tree := _tree()
	# The headless root window is 64x64; give it a real size so UiScale (px per canvas unit) behaves as on a device.
	var out := {"session": null, "window": _root().size}
	_root().size = Vector2i(TEST_SIZE)
	await tree.process_frame
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	if online:
		var s := NetSession.new()
		s.name = "TPauseHost"
		s.isolated = true
		tree.root.add_child(s)
		s.host_game()
		s.lobby.host_open(2, 3, "Host")
		assert_true(s.lobby.start_match(), "host lobby starts")
		m.session_override = s
		m.lobby_override = s.lobby.state
		m.seed_override = s.lobby.match_seed
		out["session"] = s
	else:
		m.fill_bots = false
	var went: Array[String] = []
	m.go_scene = func(path: String) -> void: went.append(path)
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 0.0
	assert_true(m.begin(), "match begins")
	await _frames(3)
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = TEST_SIZE
	m.pause_menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	m.pause_menu.size = TEST_SIZE
	m.pause_menu.settings.save = SaveService.new(PROFILE_PATH)
	await _frames(1)
	out["match"] = m
	out["went"] = went
	return out


func _finish(ctx: Dictionary) -> void:
	var m: MatchRoot = ctx["match"]
	m.queue_free()
	var s: NetSession = ctx["session"]
	if s != null:
		s.leave()
		s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	_root().size = ctx["window"]
	await _tree().process_frame
	await _tree().process_frame


func test_gear_center_tap_opens_menu() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	var gear: Rect2 = m.pause_menu.get_gear_touch_rect()
	assert_true(not m.pause_menu.is_open, "closed at start")
	_tap(gear.get_center())
	assert_true(m.pause_menu.is_open, "tapping the gear centre opens the menu")
	assert_true(m.menu_open, "match knows the menu is open")
	await _finish(ctx)


func test_icon_edge_and_touch_rect_corner_open_menu() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	var icon: Rect2 = m.pause_menu.get_gear_icon_rect()
	var touch: Rect2 = m.pause_menu.get_gear_touch_rect()
	assert_true(touch.encloses(icon), "icon inside the touch rect")
	_tap(Vector2(icon.end.x - 1.0, icon.get_center().y))
	assert_true(m.pause_menu.is_open, "drawn icon's right edge opens the menu")
	m.pause_menu.close()
	_tap(touch.position + Vector2.ONE)
	assert_true(m.pause_menu.is_open, "touch rect corner (outside the drawn icon) opens the menu")
	m.pause_menu.close()
	_tap(touch.position - Vector2(4, 4))
	assert_true(not m.pause_menu.is_open, "just outside the touch rect does nothing")
	await _finish(ctx)


func test_resume_closes_menu() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	_tap(m.pause_menu.get_gear_touch_rect().get_center())
	await _frames(1)
	await _click_button(m.pause_menu.resume_button)
	assert_true(not m.pause_menu.is_open, "Resume closes the menu")
	assert_true(not m.menu_open, "match resumes")
	await _finish(ctx)


func test_quit_asks_for_confirmation() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	var went: Array = ctx["went"]
	m.pause_menu.open()
	await _frames(1)
	await _click_button(m.pause_menu.quit_button)
	assert_true(m.pause_menu.confirm_button.is_visible_in_tree(), "Confirm shown after Quit")
	assert_true(m.pause_menu.cancel_button.is_visible_in_tree(), "Cancel shown after Quit")
	assert_true(went.is_empty(), "nothing left yet")
	await _click_button(m.pause_menu.cancel_button)
	assert_true(m.pause_menu.is_open and went.is_empty(), "Cancel stays in the menu")
	assert_true(m.pause_menu.resume_button.is_visible_in_tree(), "back at the main menu list")
	await _click_button(m.pause_menu.quit_button)
	await _click_button(m.pause_menu.confirm_button)
	assert_eq(went, [AppFlow.MENU_SCENE], "Confirm goes to the main menu")
	assert_true(not _tree().paused, "tree unpaused on the way out")
	await _finish(ctx)


func test_offline_pauses_tree_and_freezes_pawn() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	m.pause_menu.open()
	assert_true(_tree().paused, "offline: tree paused while the menu is open")
	assert_eq(m.pause_menu.process_mode, Node.PROCESS_MODE_ALWAYS, "menu keeps processing")
	assert_eq(m.pause_menu.settings.process_mode, Node.PROCESS_MODE_ALWAYS, "settings panel keeps processing")
	var before := m.local_player.global_position
	var elapsed: float = m.director.rules.elapsed_s
	await _frames(30)
	assert_eq(m.local_player.global_position, before, "pawn position unchanged over 30 physics frames")
	assert_eq(m.director.rules.elapsed_s, elapsed, "match clock stopped")
	await _click_button(m.pause_menu.resume_button)
	assert_true(not _tree().paused, "unpaused after Resume")
	await _finish(ctx)


func test_online_overlay_keeps_sim_running_with_zero_input() -> void:
	var ctx := await _new_match(true)
	var m: MatchRoot = ctx["match"]
	var hud: Control = m.get_node("Hud/TouchHud")
	var weapon: Weapon = m.local_player.loadout.get_active()
	# Control run: with the menu closed the same held input moves the pawn and fires.
	var start := m.local_player.global_position
	var mag := weapon.ammo_in_mag
	Input.action_press("move_forward")
	Input.action_press("fire")
	await _frames(15)
	var moved := (m.local_player.global_position - start) * Vector3(1, 0, 1)
	assert_true(moved.length() > 0.05, "closed: held move input moves the pawn, got %s" % moved.length())
	assert_true(weapon.ammo_in_mag < mag, "closed: held fire spends ammo")
	# Open: hold the stick and fire again (touches are ignored; the zero frame is what is under test).
	m.pause_menu.open()
	assert_true(not _tree().paused, "online: tree NOT paused")
	assert_true(not hud.provider.sprint_locked, "sprint lock cleared")
	Input.action_press("move_forward")
	Input.action_press("fire")
	await _frames(10)
	var settled := m.local_player.global_position
	var ammo := weapon.ammo_in_mag
	var elapsed: float = m.director.rules.elapsed_s
	await _frames(30)
	var drift := (m.local_player.global_position - settled) * Vector3(1, 0, 1)
	assert_true(drift.length() < 0.001, "open: no motion, drift %s" % drift.length())
	assert_eq(weapon.ammo_in_mag, ammo, "open: ammo unchanged")
	assert_true(m.director.rules.elapsed_s > elapsed, "sim tick still advances online")
	Input.action_release("move_forward")
	Input.action_release("fire")
	m.pause_menu.close()
	await _finish(ctx)


func test_go_back_does_not_open_menu() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	_root().propagate_notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	m.pause_menu.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	_push(cancel)
	var key := InputEventKey.new()
	key.keycode = KEY_ESCAPE
	key.pressed = true
	_push(key)
	await _frames(2)
	assert_true(not m.pause_menu.is_open, "Back / ui_cancel never open the menu")
	assert_true(not _tree().paused, "tree not paused by Back")
	await _finish(ctx)


func test_settings_panel_is_shared_and_persists() -> void:
	var ctx := await _new_match(false)
	var m: MatchRoot = ctx["match"]
	var main_menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	_root().add_child(main_menu)
	var panel_path := "res://scenes/ui/settings_panel.tscn"
	assert_eq(main_menu.settings.scene_file_path, panel_path, "main menu uses the shared scene")
	assert_eq(m.pause_menu.settings.scene_file_path, main_menu.settings.scene_file_path, "same scene in both menus")
	var old_profile: Dictionary = AppFlow.profile
	var start: bool = m.pause_menu.settings.gyro_enabled
	m.pause_menu.open()
	await _click_button(m.pause_menu.settings_button)
	assert_true(m.pause_menu.settings.is_visible_in_tree(), "Settings shows the panel")
	await _click_button(m.pause_menu.settings.gyro_button)
	assert_eq(SaveService.new(PROFILE_PATH).load_profile()["gyro_enabled"], not start, "in-match change saved to the profile")
	m.pause_menu.settings.sprint_slider.value = 35.0
	assert_eq(SaveService.new(PROFILE_PATH).load_profile()["sprint_sensitivity"], 35.0, "slider saved too")
	main_menu.free()
	AppFlow.profile = old_profile
	await _finish(ctx)


## Offline match at a Fold 7 size (cases as tests/test_ui.gd test_lobby_buttons_inside_viewport_at_both_fold_sizes),
## the gear menu filling the view. dpi_override is set first so every dp size is built for that screen; the caller
## resets it before _finish (which restores the window and removes the temp profile).
func _new_fold_match(size: Vector2i, dpi: float) -> Dictionary:
	PlatformServices.dpi_override = dpi
	var ctx := await _new_match(false)
	_root().size = size
	(ctx["match"] as MatchRoot).pause_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for i in 4:
		await _tree().process_frame
	return ctx


## Fold 7 sizes: in-match Settings (shared panel + Back) is taller than the folded cover, so it scrolls in its own
## full-screen ScrollContainer that is shown only with Settings (left visible it would take the Resume/Settings/Quit
## taps). Every button and the slider, Left Fire / HUD layout / Haptics / Back included, scrolls fully inside the scroll
## AND the viewport at >= 48 dp, while the offline match is paused; then a real click on Back returns to the list.
func test_settings_view_scrolls_every_control_into_view_at_both_fold_sizes() -> void:
	var old_profile: Dictionary = AppFlow.profile
	for case in [[Vector2i(2520, 1080), 420.0], [Vector2i(2176, 1812), 373.0]]:
		var size: Vector2i = case[0]
		var dpi: float = case[1]
		var at := "%s/%d dpi" % [size, int(dpi)]
		var ctx := await _new_fold_match(size, dpi)
		var m: MatchRoot = ctx["match"]
		var pm := m.pause_menu
		var scroll := pm.settings_scroll
		assert_true(scroll.is_ancestor_of(pm.settings) and scroll.is_ancestor_of(pm.back_button), "panel and Back inside the settings scroll")
		assert_eq(scroll.horizontal_scroll_mode, ScrollContainer.SCROLL_MODE_DISABLED, "no sideways scroll")
		assert_eq(scroll.vertical_scroll_mode, ScrollContainer.SCROLL_MODE_AUTO, "vertical scroll when needed")
		var n: Node = scroll
		while n != null:
			assert_true(not (n is CenterContainer), "no CenterContainer at or above the settings scroll: %s" % n)
			n = n.get_parent()
		assert_eq(pm.back_button.mouse_filter, Control.MOUSE_FILTER_PASS, "Back passes touch drags to the scroll")
		pm.open()
		await _frames(1)
		assert_true(not scroll.visible, "settings scroll hidden while the list shows at %s" % at)
		await _click_button(pm.settings_button)
		assert_true(scroll.is_visible_in_tree() and pm.settings.is_visible_in_tree(), "Settings shows its scroll at %s" % at)
		assert_true(_tree().paused and scroll.can_process(), "offline match paused, the settings scroll still processes")
		var bar := scroll.get_v_scroll_bar()
		if size == Vector2i(2520, 1080):
			var max_scroll := int(bar.max_value - bar.page)
			assert_true(max_scroll > 0, "folded cover: Settings overflows so it can scroll (max %d)" % max_scroll)
		assert_eq(scroll.scroll_vertical, 0, "starts at the top at %s" % at)
		var vp := _root().get_visible_rect()
		var px_scale := _root().get_screen_transform().get_scale().y
		var dp_scale := PlatformServices.new().get_dp_scale()
		var checked := {}
		for c: Control in scroll.find_children("*", "Control", true, false):
			if not (c is Button or c is HSlider) or not c.is_visible_in_tree():
				continue
			scroll.ensure_control_visible(c)
			await _tree().process_frame  # containers sort on the idle frame
			await _tree().process_frame
			var r := c.get_global_rect()
			var what := "%s at %s" % [(c as Button).text if c is Button else c.get_class(), at]
			assert_true(scroll.get_global_rect().encloses(r), "%s fully inside the scroll: %s in %s" % [what, r, scroll.get_global_rect()])
			assert_true(vp.encloses(r), "%s fully inside the viewport: %s in %s" % [what, r, vp])
			if c is Button:
				assert_true(r.size.y * px_scale / dp_scale >= 48.0 - 0.5, "%s >= 48 dp" % what)
			checked[c] = true
		for b: Button in [pm.settings.left_fire_button, pm.settings.layout_button, pm.settings.haptics_button, pm.back_button]:
			assert_true(checked.has(b), "%s scrolled into view and checked at %s" % [b.text, at])
		scroll.ensure_control_visible(pm.back_button)
		await _click_button(pm.back_button)
		assert_true(pm.is_open and pm.resume_button.is_visible_in_tree(), "Back returns to the list at %s" % at)
		assert_true(not scroll.visible, "settings scroll hidden again at %s" % at)
		pm.close()
		PlatformServices.dpi_override = 0.0
		AppFlow.profile = old_profile
		await _finish(ctx)


## Folded cover, in-match Settings: a touch drag that starts ON a settings button must reach the settings scroll (the
## button must not swallow it), as tests/test_ui.gd test_lobby_roster_scrolls_by_touch_drag_from_a_row. The release
## lands 240 units up, off the button: nothing opens.
func test_settings_view_scrolls_by_touch_drag_from_a_settings_button() -> void:
	var old_profile: Dictionary = AppFlow.profile
	var ctx := await _new_fold_match(Vector2i(2520, 1080), 420.0)
	var m: MatchRoot = ctx["match"]
	var pm := m.pause_menu
	pm.open()
	await _frames(1)
	await _click_button(pm.settings_button)
	var scroll := pm.settings_scroll
	var max_scroll := int(scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page)
	assert_true(max_scroll > 0, "folded in-match Settings overflows so it can scroll (max %d)" % max_scroll)
	assert_eq(scroll.scroll_vertical, 0, "starts at the top")
	var button: Button = pm.settings.sensitivity_button
	var start := button.get_global_rect()
	assert_true(_root().get_visible_rect().encloses(start) and scroll.get_global_rect().encloses(start),
			"the drag starts on an on-screen settings button: %s" % start)
	# is_touchscreen_available() is false headless, so the scroll itself only moves on a touch device; what must hold
	# everywhere is that the press and drags REACH the scroll.
	var seen := {"touch": 0, "drag": 0}
	scroll.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventScreenTouch:
			seen["touch"] += 1
		elif e is InputEventScreenDrag:
			seen["drag"] += 1)
	var xf := _root().get_screen_transform()
	var from := start.get_center()
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.position = xf * from
	press.pressed = true
	Input.parse_input_event(press)
	await _tree().process_frame
	var prev_pos := from
	for step in 12:
		var to := from + Vector2(0.0, -20.0 * float(step + 1))
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = xf * to
		drag.relative = xf * to - xf * prev_pos
		Input.parse_input_event(drag)
		prev_pos = to
		await _tree().process_frame
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.position = xf * prev_pos
	release.pressed = false
	Input.parse_input_event(release)
	await _tree().process_frame
	assert_true(seen["touch"] >= 2 and seen["drag"] == 12, "settings button does not swallow touch: scroll saw %s" % str(seen))
	assert_true(pm.settings.sensitivity_layer == null, "released off the button: the Sensitivity screen did not open")
	if DisplayServer.is_touchscreen_available():
		assert_true(scroll.scroll_vertical > 0, "touch drag starting on a settings button scrolled Settings (scroll_vertical=%d)" % scroll.scroll_vertical)
	pm.close()
	PlatformServices.dpi_override = 0.0
	AppFlow.profile = old_profile
	await _finish(ctx)


func test_gear_touch_rect_at_least_48dp() -> void:
	var pm: PauseMenu = _PauseScene.instantiate()
	_root().add_child(pm)
	pm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pm.size = TEST_SIZE
	for dpi in [0.0, 420.0]:
		PlatformServices.dpi_override = dpi
		var dp := PlatformServices.new().get_dp_scale()
		var t := pm.get_gear_touch_rect()
		assert_true(t.size.x / dp >= 48.0 - 0.001 and t.size.y / dp >= 48.0 - 0.001, "touch rect >= 48 dp at dpi %s, got %s dp" % [dpi, t.size / dp])
		assert_true(pm.get_gear_icon_rect().size.x < t.size.x, "drawn icon smaller than its target at dpi %s" % dpi)
		assert_true(Rect2(Vector2.ZERO, TEST_SIZE).encloses(t), "touch rect on screen at dpi %s" % dpi)
		for b in [pm.resume_button, pm.settings_button, pm.quit_button, pm.confirm_button, pm.cancel_button, pm.back_button]:
			assert_true(b.custom_minimum_size.y / dp >= 48.0 - 0.001, "menu button >= 48 dp at dpi %s" % dpi)
	PlatformServices.dpi_override = 0.0
	pm.free()


func _check_gear_clear(sz: Vector2) -> void:
	var touch: Control = _TouchScene.instantiate()
	_root().add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = sz
	touch.relayout()
	var game: GameHud = _HudScene.instantiate()
	_root().add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = sz
	game.scores_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.timer_label.text = "10:00"
	game.hill_label.text = "Hill: contested"
	game.weapon_label.text = "Gladius Rifle"
	game.ammo_label.text = "120 / 360"
	var pm: PauseMenu = _PauseScene.instantiate()
	_root().add_child(pm)
	pm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pm.size = sz
	await _tree().process_frame
	await _tree().process_frame
	var items := {
		"shield_bar": game.shield_bar.get_global_rect(), "health_bar": game.health_bar.get_global_rect(),
		"weapon_label": game.weapon_label.get_global_rect(), "ammo_label": game.ammo_label.get_global_rect(),
		"scores_label": game.scores_label.get_global_rect(), "timer_label": game.timer_label.get_global_rect(),
		"hill_label": game.hill_label.get_global_rect(), "move_stick": touch.move_stick.get_global_rect(),
		"look_stick": touch.look_stick.get_global_rect(), "lock_button": touch.get_lock_button_rect()}
	for action in touch.get_button_actions():
		items["button_" + action] = touch.get_button_rect(action)
	var gear := {"icon": pm.get_gear_icon_rect(), "touch": pm.get_gear_touch_rect()}
	var view := Rect2(Vector2.ZERO, sz)
	for gname in gear:
		assert_true(view.encloses(gear[gname]), "gear %s inside viewport %s, got %s" % [gname, sz, gear[gname]])
		for iname in items:
			assert_true(not gear[gname].intersects(items[iname]), "gear %s %s overlaps %s %s at %s" % [gname, gear[gname], iname, items[iname], sz])
	pm.free()
	game.free()
	touch.free()


func test_gear_clear_of_hud_both_stick_modes() -> void:
	for mode in ["custom", "virtual"]:
		_TouchHud.move_stick_override = mode
		for sz in [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]:
			await _check_gear_clear(sz)
