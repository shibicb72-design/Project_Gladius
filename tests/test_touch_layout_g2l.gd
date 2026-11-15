extends "res://tests/test_case.gd"

## G2L: the default touch layout, as re-arranged by M2 H1a (tests/test_h1a_layout.gd has the six-size checks): the
## buttons at the screen edges out of the main look area, one data default for the Sprint lock button
## (touch_layout.sprint_lock_offset), 48 dp targets, no overlaps.

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


## M2 H1a: replaces test_look_stick_bottom_right_and_buttons_north_west (the buttons no longer cluster north-west of the
## look stick, they sit at the screen edges). In look mode "stick" the drawn look stick sits in the main look area,
## right of the screen centre, and no button covers it.
func test_look_stick_in_the_look_area_and_clear_of_buttons() -> void:
	for mode in _modes():
		_TouchHud.move_stick_override = mode
		for sz in SIZES:
			var touch := _new_touch(sz)
			touch.provider.look_mode = "stick"
			touch.refresh_look_stick()
			var look: Rect2 = touch.look_stick.get_global_rect()
			assert_true(look.get_center().x > 0.5 * sz.x and touch.get_look_area_rect().has_point(look.get_center()), "%s %s: look stick centre %s in the look area" % [mode, sz, look.get_center()])
			for action in touch.get_button_actions():
				assert_true(not touch.get_button_rect(action).intersects(look), "%s %s: %s clear of the look stick %s" % [mode, sz, action, look])
			touch.free()
	_TouchHud.move_stick_override = ""


func test_buttons_smaller_than_before_and_data_driven() -> void:
	var touch := _new_touch(Vector2(2520, 1080))
	var frac: float = touch.cfg["touch_layout"]["button_size_frac_of_height"]
	assert_true(frac < OLD_BUTTON_SIZE_FRAC, "button size frac %s < old %s" % [frac, OLD_BUTTON_SIZE_FRAC])
	assert_true(touch.cfg["touch_layout"]["_placeholder"], "touch_layout is marked placeholder")
	assert_eq(touch.get_button_actions().size(), 6, "six buttons: the five after F1 plus the right Fire button (step 3, Shibi Nov 9 2026)")
	touch.free()


func test_targets_at_least_48dp_at_dpi_0_and_420() -> void:
	for dpi in [0.0, 420.0]:
		PlatformServices.dpi_override = dpi
		var dp := PlatformServices.new().get_dp_scale()
		for sz in SIZES:
			var touch := _new_touch(sz)
			var rects := {"move_stick": touch.get_move_visual_rect(), "lock_button": touch.get_lock_button_rect()}  # M2 H1a: no look stick in drag mode
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
	game.alive_label.text = "Squad VIII: XXXVIII   Squad II: XXIX"
	game.zone_label.text = "10:00"
	game.downed_label.text = "DOWNED 0:24"
	game.weapon_label.text = "Gladius Rifle"
	game.ammo_label.text = "120 / 360"
	var pm: PauseMenu = _PauseScene.instantiate()
	_root().add_child(pm)
	pm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pm.size = sz
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	# M2 H1a: the main look area takes the drawn look stick's place (no look stick in look mode "drag").
	var items := {"move_stick": touch.get_move_visual_rect(), "look_area": touch.get_look_area_rect(),
		"lock_button": touch.get_lock_button_rect(), "lock_target": touch.get_lock_target_rect(),
		"gear": pm.get_gear_touch_rect()}
	for action in touch.get_button_actions():
		items["button_" + action] = touch.get_button_rect(action)
	# Step 3 review (Nov 9 2026): the contextual Interact (Revive / Pick up) button takes touches before TouchHud, so it
	# must not cover any control, the right Fire button above all.
	var interact := InteractButton.new()
	interact.cfg = DataRegistry.new().load_file("res://data/ui.json")["interact_button"]
	interact.touch_hud = touch
	items["interact"] = interact.get_touch_rect()
	interact.free()
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
	# M2 H1a: the default is touch_layout.sprint_lock_offset (lock sides from the lock target's rest centre); the old
	# screen-fraction default sprint_lock_pos is gone from the data (the profile key of that name stays the override).
	assert_true(not cfg["touch_layout"].has("sprint_lock_pos"), "old fraction default removed")
	var def: Array = cfg["touch_layout"]["sprint_lock_offset"]
	assert_eq(def.size(), 2, "touch_layout.sprint_lock_offset is [dx, dy]")
	assert_true(cfg["touch_layout"]["_placeholder"], "touch_layout (incl. the lock default) is placeholder")
	# The only reader of the default is TouchHud._lock_default_center (the other readers, save_service.gd,
	# settings_panel.gd, main_menu.gd, only carry the profile value, [] = default).
	var sz := Vector2(1512, 648)
	var old_profile: Dictionary = AppFlow.profile
	var prof := old_profile.duplicate()
	prof["sprint_lock_pos"] = []
	AppFlow.profile = prof
	var touch := _new_touch(sz)
	var side: float = touch.get_lock_button_rect().size.x
	var target_c: Vector2 = touch.get_lock_target_rect().get_center()
	assert_true(touch.get_lock_button_rect().get_center().is_equal_approx(target_c + Vector2(float(def[0]), float(def[1])) * side), "default comes from touch_layout.sprint_lock_offset")
	prof["sprint_lock_pos"] = [0.25, 0.5]
	touch.relayout()
	assert_true(touch.get_lock_button_rect().get_center().is_equal_approx(Vector2(0.25 * sz.x, 0.5 * sz.y)), "profile value overrides the default")
	touch.free()
	AppFlow.profile = old_profile
