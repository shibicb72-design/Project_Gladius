extends "res://tests/test_case.gd"
## Front-end screens at real phone sizes (M2 U1): every control is reachable (scrolled into view where it scrolls),
## fully on screen and a touch target of at least 48 dp. These phone sizes live only here and in
## tools/menu_shots.gd, never in data/input.json. Later stops add screens; keep _check_reachable general.

const _PROFILE := "user://test_front_end_sizes_profile.json"
## [window size, dpi]: Fold 7 cover and inner screen, S24 Ultra and S25 Ultra class panels. The two 500 dpi values
## are guesses (S24/S25 Ultra), not measured.
const SIZES := [[Vector2i(2520, 1080), 420.0], [Vector2i(2176, 1812), 373.0], [Vector2i(2340, 1080), 500.0],
		[Vector2i(3120, 1440), 500.0]]


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _remove_profile() -> void:
	if FileAccess.file_exists(_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_PROFILE))


func _what(c: Control) -> String:
	if c is Button:
		return "%s '%s'" % [c.get_class(), (c as Button).text]
	if c is LineEdit:
		return "%s '%s'" % [c.get_class(), (c as LineEdit).placeholder_text]
	return c.get_class()


func _scroll_of(c: Control) -> ScrollContainer:
	var n := c.get_parent()
	while n != null:
		if n is ScrollContainer:
			return n as ScrollContainer
		n = n.get_parent()
	return null


## For every visible Button, LineEdit and HSlider under `screen`: scrolls it into view when it lives in a
## ScrollContainer, then asserts it is fully inside the root's visible rect and at least 48 dp high. Returns the
## number of controls checked.
func _check_reachable(screen: Control, at: String) -> int:
	var tree: SceneTree = Engine.get_main_loop()
	var px_scale := _root().get_screen_transform().get_scale().y
	var dp_scale := PlatformServices.new().get_dp_scale()
	var n := 0
	for c: Control in screen.find_children("*", "Control", true, false):
		if not (c is Button or c is LineEdit or c is HSlider) or not c.is_visible_in_tree():
			continue
		var scroll := _scroll_of(c)
		if scroll != null:
			scroll.ensure_control_visible(c)
			await tree.process_frame  # containers sort on the idle frame
			await tree.process_frame
		var r := c.get_global_rect()
		var vp := _root().get_visible_rect()
		assert_true(vp.encloses(r), "%s fully inside the viewport at %s: %s in %s" % [_what(c), at, r, vp])
		assert_true(r.size.y * px_scale / dp_scale >= 48.0 - 0.5, "%s >= 48 dp at %s (%.1f dp)" % [_what(c), at,
				r.size.y * px_scale / dp_scale])
		n += 1
	return n


func test_main_menu_home_and_settings_reachable_at_every_phone_size() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	for case in SIZES:
		var size: Vector2i = case[0]
		var dpi: float = case[1]
		var at := "%s/%d dpi" % [size, int(dpi)]
		PlatformServices.dpi_override = dpi
		_root().size = size
		var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
		menu.save = SaveService.new(_PROFILE)
		_root().add_child(menu)
		for i in 4:
			await tree.process_frame
		var lr := menu.logo.get_global_rect()
		assert_true(_root().get_visible_rect().encloses(lr), "logo inside the viewport at %s: %s" % [at, lr])
		assert_true(menu.logo.get_font_px() > 0, "logo has a size at %s" % at)
		var home_n: int = await _check_reachable(menu, "home " + at)
		assert_true(home_n >= 9, "home: %d controls checked at %s" % [home_n, at])
		menu.open_settings()
		for i in 4:
			await tree.process_frame
		var settings_n: int = await _check_reachable(menu, "settings " + at)
		assert_true(settings_n >= 9, "settings: %d controls checked at %s" % [settings_n, at])
		menu.free()
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	AppFlow.profile = old_profile
	_remove_profile()
	await tree.process_frame
