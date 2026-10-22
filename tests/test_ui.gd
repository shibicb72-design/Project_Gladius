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
