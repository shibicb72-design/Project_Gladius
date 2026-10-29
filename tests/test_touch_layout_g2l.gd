extends "res://tests/test_case.gd"

## G2L: the default touch layout. Look stick bottom-right, the six buttons smaller and north-west of it,
## one data default for the Sprint lock button (touch_layout.sprint_lock_pos), 48 dp targets, no overlaps.

const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _PauseScene := preload("res://scenes/ui/pause_menu.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const SIZES := [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]
const OLD_BUTTON_SIZE_FRAC := 0.16  # data/input.json touch_layout.button_size_frac_of_height at f793f1a


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _new_touch(sz: Vector2) -> Control:
	var touch: Control = _TouchScene.instantiate()
	_root().add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = sz
	touch.relayout()
	return touch


func _modes() -> Array:
	return ["custom", "virtual"]


func test_look_stick_bottom_right_and_buttons_north_west() -> void:
	for mode in _modes():
		_TouchHud.move_stick_override = mode
		for sz in SIZES:
			var touch := _new_touch(sz)
			var look: Vector2 = touch.look_stick.get_global_rect().get_center()
			assert_true(look.x > 0.5 * sz.x and look.y > 0.5 * sz.y, "%s %s: look stick centre %s in the bottom-right quadrant" % [mode, sz, look])
			for action in touch.get_button_actions():
				var c: Vector2 = touch.get_button_rect(action).get_center()
				assert_true(c.x < look.x and c.y < look.y, "%s %s: %s centre %s north-west of look centre %s" % [mode, sz, action, c, look])
			touch.free()
	_TouchHud.move_stick_override = ""


func test_buttons_smaller_than_before_and_data_driven() -> void:
	var touch := _new_touch(Vector2(2520, 1080))
	var frac: float = touch.cfg["touch_layout"]["button_size_frac_of_height"]
	assert_true(frac < OLD_BUTTON_SIZE_FRAC, "button size frac %s < old %s" % [frac, OLD_BUTTON_SIZE_FRAC])
	assert_true(touch.cfg["touch_layout"]["_placeholder"], "touch_layout is marked placeholder")
	assert_eq(touch.get_button_actions().size(), 5, "five buttons after F1 main Fire removal")
	touch.free()


func test_targets_at_least_48dp_at_dpi_0_and_420() -> void:
	for dpi in [0.0, 420.0]:
		PlatformServices.dpi_override = dpi
		var dp := PlatformServices.new().get_dp_scale()
		for sz in SIZES:
			var touch := _new_touch(sz)
			var rects := {"look_stick": touch.look_stick.get_global_rect(), "move_stick": touch.get_move_visual_rect(),
				"lock_button": touch.get_lock_button_rect()}
			for action in touch.get_button_actions():
				rects["button_" + action] = touch.get_button_rect(action)
			for n in rects:
				var r: Rect2 = rects[n]
				assert_true(r.size.x / dp >= 48.0 - 1e-3 and r.size.y / dp >= 48.0 - 1e-3, "%s %.1f dp >= 48 at %s dpi %s" % [n, r.size.x / dp, sz, dpi])
			touch.free()
	PlatformServices.dpi_override = 0.0


## Every control (both sticks, six buttons, Sprint lock button and target, gear) is clear of each other and of the HUD labels.
func _check_pairwise(sz: Vector2) -> void:
	var touch := _new_touch(sz)
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
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var items := {"move_stick": touch.get_move_visual_rect(), "look_stick": touch.look_stick.get_global_rect(),
		"lock_button": touch.get_lock_button_rect(), "lock_target": touch.get_lock_target_rect(),
		"gear": pm.get_gear_touch_rect()}
	for action in touch.get_button_actions():
		items["button_" + action] = touch.get_button_rect(action)
	var names: Array = items.keys()
	var view := Rect2(Vector2.ZERO, sz)
	for i in names.size():
		assert_true(view.encloses(items[names[i]]), "%s inside the viewport at %s, got %s" % [names[i], sz, items[names[i]]])
		for j in range(i + 1, names.size()):
			assert_true(not items[names[i]].intersects(items[names[j]]), "%s %s overlaps %s %s at %s" % [names[i], items[names[i]], names[j], items[names[j]], sz])
	pm.free()
	game.free()
	touch.free()


func test_pairwise_no_overlap_four_sizes_both_modes() -> void:
	for mode in _modes():
		_TouchHud.move_stick_override = mode
		for sz in SIZES:
			await _check_pairwise(sz)
	_TouchHud.move_stick_override = ""


## Same pairwise check at dpi 420 (the 48 dp minimums grow, so the layout is tightest here). Landscape only (OQ-PORTRAIT).
func test_pairwise_no_overlap_four_sizes_both_modes_dpi_420() -> void:
	PlatformServices.dpi_override = 420.0
	for mode in _modes():
		_TouchHud.move_stick_override = mode
		for sz in SIZES:
			await _check_pairwise(sz)
	_TouchHud.move_stick_override = ""
	PlatformServices.dpi_override = 0.0


func test_lock_default_only_in_touch_layout_and_profile_overrides() -> void:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/input.json"))
	assert_true(not cfg["sprint"]["lock_button"].has("pos"), "no lock default in sprint.lock_button")
	assert_true(not str(cfg["sprint"]).contains("0.56"), "old lock default value gone from the sprint block")
	var def: Array = cfg["touch_layout"]["sprint_lock_pos"]
	assert_eq(def.size(), 2, "touch_layout.sprint_lock_pos is [x, y]")
	assert_true(cfg["touch_layout"]["_placeholder"], "touch_layout (incl. the lock default) is placeholder")
	# The only reader of the default is TouchHud._lock_button_center (git grep lock_button / sprint_lock_pos: the
	# other readers, save_service.gd, settings_panel.gd, main_menu.gd, only carry the profile value, [] = default).
	var sz := Vector2(1512, 648)
	var old_profile: Dictionary = AppFlow.profile
	var prof := old_profile.duplicate()
	prof["sprint_lock_pos"] = []
	AppFlow.profile = prof
	var touch := _new_touch(sz)
	assert_true(touch.get_lock_button_rect().get_center().is_equal_approx(Vector2(float(def[0]) * sz.x, float(def[1]) * sz.y)), "default comes from touch_layout.sprint_lock_pos")
	prof["sprint_lock_pos"] = [0.25, 0.5]
	touch.relayout()
	assert_true(touch.get_lock_button_rect().get_center().is_equal_approx(Vector2(0.25 * sz.x, 0.5 * sz.y)), "profile value overrides the default")
	touch.free()
	AppFlow.profile = old_profile
