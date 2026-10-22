extends "res://tests/test_case.gd"

const _TMP := "user://test_profile.json"


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _remove_tmp() -> void:
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))


func test_roman_numerals_1_to_100() -> void:
	var expect := {1: "I", 4: "IV", 9: "IX", 14: "XIV", 40: "XL", 49: "XLIX", 90: "XC", 99: "XCIX", 100: "C"}
	for n in expect:
		assert_eq(RomanNumerals.to_roman(n), expect[n], "roman %d" % n)
	assert_eq(RomanNumerals.to_roman(0), RomanNumerals.ZERO_TEXT, "zero")
	assert_eq(RomanNumerals.to_roman(0), "N", "zero placeholder")
	var seen := {}
	for n in range(1, 101):
		var s := RomanNumerals.to_roman(n)
		assert_true(not s.is_empty() and not seen.has(s), "unique non-empty %d" % n)
		seen[s] = true


func test_save_roundtrip_user_dir() -> void:
	_remove_tmp()
	var svc := SaveService.new(_TMP)
	assert_true(svc.path.begins_with("user://"), "user:// path")
	assert_true(svc.save_profile({"gamertag": "Marcus", "last_ip": "192.168.1.5"}), "save")
	var p := SaveService.new(_TMP).load_profile()
	assert_eq(p["gamertag"], "Marcus", "gamertag")
	assert_eq(p["last_ip"], "192.168.1.5", "ip")
	assert_eq(p["version"], SaveService.VERSION, "version")
	_remove_tmp()


func test_save_missing_or_corrupt_gives_defaults() -> void:
	_remove_tmp()
	var svc := SaveService.new(_TMP)
	assert_eq(svc.load_profile(), SaveService.defaults(), "missing file")
	var f := FileAccess.open(_TMP, FileAccess.WRITE)
	f.store_string("{ not json ][")
	f.close()
	assert_eq(svc.load_profile(), SaveService.defaults(), "corrupt file")
	f = FileAccess.open(_TMP, FileAccess.WRITE)
	f.store_string("[1, 2, 3]")
	f.close()
	assert_eq(svc.load_profile(), SaveService.defaults(), "wrong shape")
	_remove_tmp()


func test_hud_binds_and_updates_on_signals() -> void:
	var director := MatchDirector.new()
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	var hud := GameHud.new()
	hud.bind(director, pawn)
	director.score_changed.emit({0: 4, 1: 9})
	assert_eq(hud.scores_label.text, "Squad I: IV   Squad II: IX", "scores in Roman numerals")
	director.time_changed.emit(125.0)
	assert_eq(hud.timer_label.text, "2:05", "timer")
	hud.refresh_pawn()
	assert_true(hud.health_bar.max_value >= 1.0, "health bar range")
	assert_eq(hud.health_bar.value, pawn.bridge.state.health, "health value")
	assert_eq(hud.shield_bar.value, pawn.bridge.state.shield, "shield value")
	var w := pawn.loadout.get_active()
	assert_eq(hud.weapon_label.text, w.def.display_name, "weapon name")
	assert_eq(hud.ammo_label.text, "%d / %d" % [w.ammo_in_mag, w.reserve], "ammo")
	assert_true(not hud.respawn_label.visible, "no respawn text while alive")
	hud.free()
	pawn.free()
	director.free()


func test_menus_instantiate() -> void:
	var root := _root()
	for path in ["res://scenes/ui/main_menu.tscn", "res://scenes/ui/lobby.tscn", "res://scenes/ui/end_screen.tscn",
			"res://scenes/ui/hud.tscn"]:
		var scene: PackedScene = load(path)
		assert_true(scene != null, "load " + path)
		if scene == null:
			continue
		var n: Node = scene.instantiate()
		assert_true(n is Control, "root is Control " + path)
		root.add_child(n)
		n.free()
	AppFlow.lobby = null
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	root.add_child(menu)
	assert_true(menu.later_buttons.size() == MainMenu.LATER_ENTRIES.size(), "later entries present")
	for b in menu.later_buttons:
		assert_true(b.disabled, "later entry disabled")
	menu.free()
	var end: EndScreen = load("res://scenes/ui/end_screen.tscn").instantiate()
	root.add_child(end)
	end.show_result({"winner": 1, "draw": false, "scores": {0: 3, 1: 10}})
	assert_eq(end.title_label.text, "Squad II wins", "winner text")
	end.show_result({"winner": null, "draw": true, "scores": {0: 5, 1: 5}})
	assert_eq(end.title_label.text, "Draw", "draw text")
	end.free()
	AppFlow.lobby = null


## Hosting lobby scene on an isolated loopback session (the way MainMenu hosts), added to the tree.
func _host_lobby() -> Lobby:
	var s := NetSession.new()
	s.name = "UiTestSession"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	s.host_game()
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	_root().add_child(lobby)
	return lobby


func _end_lobby(lobby: Lobby) -> void:
	lobby.free()
	AppFlow.end_session()


func test_lobby_bot_row_cycles_class() -> void:
	var lobby := _host_lobby()
	assert_true(lobby.is_host, "hosting")
	assert_eq(lobby.slot_buttons.size(), lobby.state.squad_count * lobby.state.squad_size, "one row per slot")
	var before := str(lobby.state.assign()[1]["class_id"])
	lobby.slot_buttons[1].pressed.emit()
	var after := str(lobby.state.assign()[1]["class_id"])
	assert_true(after != before and after in Lobby.CLASSES, "bot class changed in state")
	assert_true(lobby.slot_buttons[1].text.contains(after), "row shows the new class")
	lobby.slot_buttons[1].pressed.emit()
	assert_eq(str(lobby.state.assign()[1]["class_id"]), before, "second tap cycles back")
	# Own row cycles the host's class; the player stays human.
	var mine := str(lobby.state.humans[0]["class_id"])
	lobby.slot_buttons[0].pressed.emit()
	assert_true(str(lobby.state.humans[0]["class_id"]) != mine, "own row cycles own class")
	_end_lobby(lobby)


## Fold 7: cover 2520x1080 (window px per canvas unit 1.667) at 420 dpi; inner 2176x1812 (1.889) at 373 dpi.
func test_dp_floor_holds_at_420_and_373_dpi() -> void:
	var cfg := DataRegistry.new().load_file("res://data/ui.json")
	assert_true(float(cfg["min_touch_target_dp"]) >= 48.0, "dp floor is at least 48")
	for case in [[648.0, 1080.0 / 648.0, 420.0], [959.0, 1812.0 / 959.0, 373.0]]:
		var canvas_h: float = case[0]
		var px_scale: float = case[1]
		var dpi: float = case[2]
		PlatformServices.dpi_override = dpi
		var dp_scale := PlatformServices.new().get_dp_scale()
		PlatformServices.dpi_override = 0.0
		assert_true(is_equal_approx(dp_scale, dpi / 160.0), "dp scale from dpi %d" % int(dpi))
		var h := UiScale.min_button_height(canvas_h, px_scale, dp_scale, cfg)
		var dp := h * px_scale / dp_scale
		assert_true(dp >= 48.0 - 0.001, "button is %.1f dp at %d dpi, need >= 48" % [dp, int(dpi)])
		assert_true(h >= canvas_h * float(cfg["min_touch_target_frac_of_height"]) - 0.001, "height fraction still honoured")


func test_menu_buttons_meet_touch_target_height() -> void:
	var frac := float(DataRegistry.new().load_file("res://data/ui.json")["min_touch_target_frac_of_height"])
	assert_true(frac > 0.0, "touch target fraction present")
	var lobby := _host_lobby()
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	_root().add_child(menu)
	var end: EndScreen = load("res://scenes/ui/end_screen.tscn").instantiate()
	_root().add_child(end)
	for h in [1000.0, 1968.0]:
		for screen: Control in [lobby, menu, end]:
			UiScale.apply_to(screen, h)
			var n := 0
			for b in screen.find_children("*", "Button", true, false):
				n += 1
				assert_true((b as Button).custom_minimum_size.y >= frac * h - 0.001, "%s button height at %d" % [screen.name, int(h)])
			assert_true(n > 0, "%s has buttons" % screen.name)
	menu.free()
	end.free()
	_end_lobby(lobby)
	AppFlow.lobby = null


## Fold 7 sizes: every lobby button fully on screen, action bar >= 48 dp, roster scrolls in the rest.
func test_lobby_buttons_inside_viewport_at_both_fold_sizes() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	for case in [[Vector2i(2520, 1080), 420.0], [Vector2i(2176, 1812), 373.0]]:
		var size: Vector2i = case[0]
		var dpi: float = case[1]
		PlatformServices.dpi_override = dpi
		_root().size = size
		var lobby := _host_lobby()
		for i in 4:
			await tree.process_frame
		var vp := _root().get_visible_rect()
		var px_scale := _root().get_screen_transform().get_scale().y
		var dp_scale := PlatformServices.new().get_dp_scale()
		var n := 0
		for b: Button in lobby.find_children("*", "Button", true, false):
			if not b.is_visible_in_tree():
				continue
			n += 1
			var r := b.get_global_rect()
			var is_row := b in lobby.slot_buttons
			if not is_row:
				assert_true(vp.encloses(r), "%s fully inside viewport at %s/%d dpi: %s in %s" % [b.text, size, int(dpi), r, vp])
				assert_true(r.size.y * px_scale / dp_scale >= 48.0 - 0.5, "%s >= 48 dp at %s/%d dpi" % [b.text, size, int(dpi)])
		assert_true(n >= 3, "lobby action buttons present")
		var bar: Control = lobby.find_child("ActionBar", true, false)
		assert_true(vp.encloses(bar.get_global_rect()), "action bar inside viewport at %s" % size)
		var scroll := lobby.rows_box.get_parent() as ScrollContainer
		assert_true(scroll.get_global_rect().end.y <= bar.get_global_rect().position.y + 0.5, "roster ends above the action bar")
		assert_true(scroll.size.y > lobby.slot_buttons[0].size.y * 2.0, "roster is not squeezed into a strip at %s: %s" % [size, scroll.size])
		_end_lobby(lobby)
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	await tree.process_frame


## Folded lobby: a touch drag that starts ON a slot row must scroll the roster (the row button must not swallow it).
func test_lobby_roster_scrolls_by_touch_drag_from_a_row() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	PlatformServices.dpi_override = 420.0
	_root().size = Vector2i(2520, 1080)
	var lobby := _host_lobby()
	for i in 4:
		await tree.process_frame
	var scroll := lobby.rows_box.get_parent() as ScrollContainer
	var max_scroll := int(scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page)
	assert_true(max_scroll > 0, "folded roster overflows so it can scroll (max %d)" % max_scroll)
	assert_eq(scroll.scroll_vertical, 0, "starts at the top")
	# The ScrollContainer only turns ScreenDrag into scrolling when the display reports a touchscreen
	# (DisplayServer.is_touchscreen_available(): false on desktop/headless). So this test also asserts the part that
	# does not depend on the host: the press and drags that start on a row REACH the ScrollContainer.
	var seen := {"touch": 0, "drag": 0}
	scroll.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventScreenTouch:
			seen["touch"] += 1
		elif e is InputEventScreenDrag:
			seen["drag"] += 1)
	var xf := _root().get_screen_transform()
	var row: Button = lobby.slot_buttons[2]
	var from := row.get_global_rect().get_center()
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.position = xf * from
	press.pressed = true
	Input.parse_input_event(press)
	await tree.process_frame
	var prev_pos := from
	for step in 12:
		var to := from + Vector2(0.0, -20.0 * float(step + 1))
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = xf * to
		drag.relative = xf * to - xf * prev_pos
		Input.parse_input_event(drag)
		prev_pos = to
		await tree.process_frame
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.position = xf * prev_pos
	release.pressed = false
	Input.parse_input_event(release)
	await tree.process_frame
	assert_true(seen["touch"] >= 2 and seen["drag"] == 12, "row does not swallow touch: roster saw %s" % str(seen))
	if DisplayServer.is_touchscreen_available():
		assert_true(scroll.scroll_vertical > 0, "touch drag starting on a slot row scrolled the roster (scroll_vertical=%d)" % scroll.scroll_vertical)
	_end_lobby(lobby)
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	await tree.process_frame


func test_touch_hud_hidden_when_not_touch() -> void:
	var n: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	_root().add_child(n)
	assert_true(not n.should_show(), "should_show false on a non-touch desktop/headless run")
	assert_true(not n.visible, "touch HUD hidden")
	n.free()


func test_graphics_preset_applied() -> void:
	var before := Engine.max_fps
	var presets := GraphicsPresets.new()
	var p := presets.get_preset()
	assert_true(not p.is_empty(), "default preset exists")
	var applied := presets.apply()
	assert_eq(Engine.max_fps, int(applied.get("max_fps", -1)), "fps cap applied")
	assert_eq(Engine.max_fps, 60, "60 fps cap placeholder")
	assert_true(presets.apply("no_such_preset").is_empty(), "unknown preset ignored")
	Engine.max_fps = before
