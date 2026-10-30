extends "res://tests/test_case.gd"
## A2 T1: real menu, drawn slider grabbers, window-pixel mouse drags, persisted results.
const TMP := "user://test_a2_gyro_sliders.json"
const ROWS := ["tpp_fpp_no_scope", "red_dot", "2x", "4x", "8x", "16x"]
const TITLES := ["TPP / FPP, no scope", "Red dot", "2x", "4x", "8x", "16x"]

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame

func _remove_tmp() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))

func _screen() -> SensitivityScreen:
	var screen: SensitivityScreen = load("res://scenes/ui/sensitivity_screen.tscn").instantiate()
	screen.save = SaveService.new(TMP)
	_tree().root.add_child(screen)
	return screen

func _mouse_move(point: Vector2, held: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _tree().root.get_screen_transform() * point
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	_tree().root.push_input(event, false)

func _mouse_button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = _tree().root.get_screen_transform() * point
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	_tree().root.push_input(event, false)

func _audit_and_drag(size: Vector2i, dpi: float) -> void:
	_remove_tmp()
	PlatformServices.dpi_override = dpi
	_tree().root.size = size
	await _frames(4)
	var screen := _screen()
	await _frames(4)
	assert_eq(screen.sliders.size(), 26, "existing table count")
	var scrolls := screen.find_children("*", "ScrollContainer", true, false)
	assert_eq(scrolls.size(), 1, "one scroll list")
	var scroll := scrolls[0] as ScrollContainer
	var list := scroll.get_child(0)
	for table in ["gyro", "ads_gyro"]:
		var section_rows: Array[String] = []
		var in_section := false
		for child in list.get_children():
			if child is Label:
				in_section = child.text == SensitivityScreen.TITLES[table]
			elif in_section and child is HBoxContainer:
				section_rows.append((child.get_child(0) as Label).text)
		assert_eq(section_rows, TITLES, table + " six titles in order")
		for row in ROWS:
			var slider: HSlider = screen.sliders[table + "/" + row]
			var camera: HSlider = screen.sliders["camera/" + row]
			var box := slider.get_parent() as HBoxContainer
			assert_true(box != null and box.get_child_count() == 3, "shared name/slider/value HBox")
			assert_true(box.get_child(0) is Label and box.get_child(1) == slider and box.get_child(2) is Label, "row child types")
			assert_eq((box.get_child(0) as Label).text, TITLES[ROWS.find(row)], "row title")
			assert_eq((box.get_child(0) as Control).size_flags_stretch_ratio, 1.0, "name ratio")
			assert_eq(slider.size_flags_stretch_ratio, 2.0, "slider ratio")
			for index in 3:
				var control := box.get_child(index) as Control
				var reference := camera.get_parent().get_child(index) as Control
				assert_eq(control.size_flags_horizontal, reference.size_flags_horizontal, "Camera horizontal flags")
				assert_eq(control.size_flags_stretch_ratio, reference.size_flags_stretch_ratio, "Camera stretch ratio")
				assert_eq(control.custom_minimum_size, reference.custom_minimum_size, "Camera minimum size")
			var range_cfg := screen.settings.range_of(table)
			assert_eq([slider.min_value, slider.max_value, slider.step], [1.0, 400.0, 1.0], "gyro range")
			assert_eq([slider.min_value, slider.max_value, slider.step], [range_cfg["min"], range_cfg["max"], range_cfg["step"]], "data range")
			var dp := slider.get_global_rect().size.y * _tree().root.get_screen_transform().get_scale().y / PlatformServices.new().get_dp_scale()
			assert_true(dp >= 47.5, "%s/%s at %s: %f dp" % [table, row, size, dp])
	var first: HSlider = screen.sliders["gyro/tpp_fpp_no_scope"]
	assert_true(first.get_global_rect().position.y >= scroll.get_global_rect().end.y, "Gyro starts below visible scroll")
	for key in ["gyro/red_dot", "gyro/16x", "ads_gyro/red_dot", "ads_gyro/16x"]:
		var slider: HSlider = screen.sliders[key]
		scroll.ensure_control_visible(slider)
		await _frames(2)
		var rect := slider.get_global_rect()
		# Integer scroll offsets can leave a fractional-height row <1 canvas unit clipped.
		# Move by the measured remainder so the entire drawn rect is inside before input.
		if rect.end.y > scroll.get_global_rect().end.y:
			scroll.scroll_vertical += ceili(rect.end.y - scroll.get_global_rect().end.y)
			await _frames(2)
			rect = slider.get_global_rect()
		assert_true(scroll.get_global_rect().encloses(rect), "%s fully in scroll at %s: %s inside %s" % [key, size, rect, scroll.get_global_rect()])
		assert_true(_tree().root.get_visible_rect().encloses(rect), key + " fully in viewport")
		var before := screen.settings.to_dict()
		var previous := slider.value
		# Slider's drawn grabber travels over width minus its own width.
		var grabber := slider.get_theme_icon("grabber")
		var half := grabber.get_width() * 0.5
		var start := Vector2(rect.position.x + half + slider.get_as_ratio() * (rect.size.x - 2.0 * half), rect.get_center().y)
		var target := Vector2(rect.position.x + half + 0.73 * (rect.size.x - 2.0 * half), start.y)
		_mouse_move(start, false)
		_mouse_button(start, true)
		_mouse_move(target, true)
		_mouse_button(target, false)
		await _frames(2)
		assert_true(slider.value != previous, key + " drawn grabber drag changes value")
		assert_eq((screen.value_labels[key] as Label).text, "%d%%" % int(slider.value), key + " percent label")
		assert_eq(screen.settings.preset, "custom", key + " Custom preset")
		assert_true((screen.preset_buttons["custom"] as Button).button_pressed, "Custom indicator")
		var saved := SaveService.new(TMP).load_profile()
		var parts: PackedStringArray = str(key).split("/")
		assert_eq(saved["sensitivity"]["values"][parts[0]][parts[1]], slider.value, key + " persisted")
		for table in screen.settings.all_tables():
			for row in screen.settings.rows_of(table):
				if table + "/" + row != key:
					assert_eq(screen.settings.percent(table, row), before["values"][table][row], key + " leaves " + table + "/" + row)
					assert_eq(saved["sensitivity"]["values"][table][row], before["values"][table][row], "persisted other row unchanged")
		var changed_value := slider.value
		screen.free()
		screen = _screen()
		await _frames(4)
		scroll = screen.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
		assert_eq((screen.sliders[key] as HSlider).value, changed_value, key + " rebuilt from saved profile")
	screen.free()
	AppFlow.profile = {}
	PlatformServices.dpi_override = 0.0
	_remove_tmp()

func test_a2_gyro_slider_layout_and_mouse_persistence_both_fold_sizes() -> void:
	var previous_size := _tree().root.size
	await _audit_and_drag(Vector2i(2520, 1080), 420.0)
	await _audit_and_drag(Vector2i(2176, 1812), 373.0)
	_tree().root.size = previous_size
	await _frames(4)
