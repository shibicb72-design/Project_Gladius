extends "res://tests/test_case.gd"
## G2f2: the chosen haptics quality is visibly marked (text marker plus a pressed button style in the theme).

const PROFILE_PATH := "user://test_haptics_marker_profile.json"
const _Theme := preload("res://scenes/ui/theme.tres")
const _MenuTheme := preload("res://scenes/ui/menu_theme.tres")


class FakeBackend extends HapticsBackend:
	func is_supported() -> bool:
		return true

	func vibrate(_duration_ms: int, _amplitude: float) -> void:
		pass


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func test_selected_quality_has_marker_and_follows_selection() -> void:
	var holder := Control.new()
	_tree().root.add_child(holder)
	var screen: HapticsScreen = load("res://scenes/ui/haptics_screen.tscn").instantiate()
	screen.save = SaveService.new(PROFILE_PATH)
	screen.service = HapticsService.new({}, FakeBackend.new())
	holder.add_child(screen)
	await _tree().process_frame
	var chosen: String = screen.service.quality
	var other: String = "low" if chosen == "high" else "high"
	assert_true(screen.quality_buttons[chosen].text.begins_with(HapticsScreen.SELECTED_MARKER), "selected shows marker")
	assert_true(not screen.quality_buttons[other].text.contains(HapticsScreen.SELECTED_MARKER.strip_edges()),
			"unselected has no marker")
	screen.quality_buttons[other].pressed.emit()
	assert_true(screen.quality_buttons[other].text.begins_with(HapticsScreen.SELECTED_MARKER), "marker moved to new choice")
	assert_true(not screen.quality_buttons[chosen].text.contains(HapticsScreen.SELECTED_MARKER.strip_edges()),
			"marker removed from old choice")
	holder.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))


func test_theme_has_distinct_pressed_button_style() -> void:
	# The HUD theme and the front-end theme (M2U1) both mark the selected choice with a pressed style.
	var themes := {"theme.tres": _Theme, "menu_theme.tres": _MenuTheme}
	for theme_name: String in themes:
		var t: Theme = themes[theme_name]
		assert_true(t.has_stylebox("pressed", "Button"), "%s has Button pressed style" % theme_name)
		assert_true(t.has_stylebox("hover_pressed", "Button"), "%s has Button hover_pressed style" % theme_name)
		var normal: StyleBoxFlat = t.get_stylebox("normal", "Button")
		var pressed: StyleBoxFlat = t.get_stylebox("pressed", "Button")
		var hover_pressed: StyleBoxFlat = t.get_stylebox("hover_pressed", "Button")
		assert_true(pressed.bg_color != normal.bg_color, "%s pressed background differs from normal" % theme_name)
		assert_true(hover_pressed.bg_color != normal.bg_color,
				"%s hover_pressed background differs from normal" % theme_name)
