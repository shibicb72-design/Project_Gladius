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


class FakeBackend extends HapticsBackend:
	func is_supported() -> bool:
		return true

	func vibrate(_duration_ms: int, _amplitude: float) -> void:
		pass


## Fully inside the viewport and at least 48 dp high (no scrolling: for controls that do not live in a scroll).
func _assert_on_screen(c: Control, at: String) -> void:
	var px_scale := _root().get_screen_transform().get_scale().y
	var dp_scale := PlatformServices.new().get_dp_scale()
	var r := c.get_global_rect()
	var vp := _root().get_visible_rect()
	assert_true(vp.encloses(r), "%s fully inside the viewport at %s: %s in %s" % [_what(c), at, r, vp])
	assert_true(r.size.y * px_scale / dp_scale >= 48.0 - 0.5, "%s >= 48 dp at %s (%.1f dp)" % [_what(c), at,
			r.size.y * px_scale / dp_scale])


func _set_size(case: Array) -> String:
	var size: Vector2i = case[0]
	var dpi: float = case[1]
	PlatformServices.dpi_override = dpi
	_root().size = size
	return "%s/%d dpi" % [size, int(dpi)]


func _restore(prev: Vector2i, old_profile: Dictionary) -> void:
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	AppFlow.profile = old_profile
	_remove_profile()


func test_sensitivity_screen_reachable_at_every_phone_size() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	for case: Array in SIZES:
		var at := _set_size(case)
		var screen: SensitivityScreen = load("res://scenes/ui/sensitivity_screen.tscn").instantiate()
		screen.save = SaveService.new(_PROFILE)
		_root().add_child(screen)
		for i: int in 4:
			await tree.process_frame
		var n: int = await _check_reachable(screen, at)
		assert_true(n >= 12, "sensitivity: %d controls checked at %s" % [n, at])
		var br := screen.back_button.get_global_rect()
		assert_true(_root().get_visible_rect().encloses(br), "Back inside the viewport at %s: %s" % [at, br])
		screen.free()
	_restore(prev, old_profile)
	await tree.process_frame


func test_haptics_screen_reachable_at_every_phone_size() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	for case: Array in SIZES:
		var at := _set_size(case)
		var screen: HapticsScreen = load("res://scenes/ui/haptics_screen.tscn").instantiate()
		screen.save = SaveService.new(_PROFILE)
		screen.service = HapticsService.new({}, FakeBackend.new())
		_root().add_child(screen)
		for i: int in 4:
			await tree.process_frame
		var n: int = await _check_reachable(screen, at)
		assert_true(n >= 7, "haptics: %d controls checked at %s" % [n, at])
		var scrolls := screen.find_children("*", "ScrollContainer", true, false)
		assert_eq(scrolls.size(), 1, "haptics has one ScrollContainer at %s" % at)
		for b: Button in (scrolls[0] as Node).find_children("*", "Button", true, false):
			assert_eq(b.mouse_filter, Control.MOUSE_FILTER_PASS, "%s passes drags to the scroll at %s" % [_what(b), at])
		screen.free()
	_restore(prev, old_profile)
	await tree.process_frame


func test_pause_overlay_reachable_at_every_phone_size() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	for case: Array in SIZES:
		var at := _set_size(case)
		var pm: PauseMenu = load("res://scenes/ui/pause_menu.tscn").instantiate()
		_root().add_child(pm)
		pm.settings.save = SaveService.new(_PROFILE)
		pm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pm.open()
		for i: int in 3:
			await tree.process_frame
		var list: Array[Button] = [pm.resume_button, pm.settings_button, pm.quit_button]
		for b: Button in list:
			_assert_on_screen(b, "list " + at)
		for i: int in list.size():
			for j: int in range(i + 1, list.size()):
				assert_true(not list[i].get_global_rect().intersects(list[j].get_global_rect()),
						"%s and %s do not overlap at %s" % [_what(list[i]), _what(list[j]), at])
		pm.quit_button.pressed.emit()
		for i: int in 2:
			await tree.process_frame
		_assert_on_screen(pm.confirm_button, "confirm " + at)
		_assert_on_screen(pm.cancel_button, "confirm " + at)
		pm.cancel_button.pressed.emit()
		pm.settings_button.pressed.emit()
		for i: int in 3:
			await tree.process_frame
		var n: int = await _check_reachable(pm, "settings " + at)
		assert_true(n >= 9, "pause settings: %d controls checked at %s" % [n, at])
		pm.settings_scroll.scroll_vertical = 0
		await tree.process_frame
		await tree.process_frame
		assert_true(pm.back_button.get_global_rect().position.y < pm.settings.get_global_rect().position.y,
				"Back sits above the settings panel at %s" % at)
		pm.free()
	tree.paused = false
	_restore(prev, old_profile)
	await tree.process_frame


func test_layout_editor_panel_inside_viewport_at_every_phone_size() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	for case: Array in SIZES:
		var at := _set_size(case)
		var ed: LayoutEditor = load("res://scenes/ui/layout_editor.tscn").instantiate()
		ed.save = SaveService.new(_PROFILE)
		_root().add_child(ed)
		for i: int in 6:
			await tree.process_frame
		var top: Array[Control] = []
		for b: Button in ed.slot_buttons:
			top.append(b)
		top.append_array([ed.save_button, ed.reset_button, ed.back_button, ed.size_slider, ed.alpha_slider])
		assert_eq(top.size(), 8, "six top buttons and two sliders at %s" % at)
		for c: Control in top:
			_assert_on_screen(c, at)
		assert_eq(ed.save_button.theme_type_variation, &"PrimaryButton", "Save is the crimson control at %s" % at)
		assert_true(ed.preview.has_meta(MenuStyle.META_SKIP), "the HUD preview is skipped by the kit at %s" % at)
		ed.free()
	_restore(prev, old_profile)
	await tree.process_frame


## The action card keeps to its share: the hero column (logo) is never squeezed, so the boot screen's logo, laid
## out on the same ratios, lands exactly where the menu's does. Phone sizes plus a desktop window at default dpi.
func test_menu_card_never_squeezes_the_hero_column() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var prev := _root().size
	var old_profile: Dictionary = AppFlow.profile
	_remove_profile()
	var cases: Array = SIZES.duplicate()
	cases.append([Vector2i(1152, 648), 0.0])
	# Near-square (the headless test runner's own root): the widest later entry alone once outgrew the card's share.
	cases.append([Vector2i(1152, 1152), 0.0])
	for case: Array in cases:
		var at := _set_size(case)
		var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
		menu.save = SaveService.new(_PROFILE)
		_root().add_child(menu)
		for i: int in 4:
			await tree.process_frame
		var hero := menu.home.get_child(0) as Control
		var card := menu.home.get_child(1) as Control
		assert_eq(String(hero.name), "Hero", "first home child is the hero column at %s" % at)
		assert_eq(String(card.name), "HeroCard", "second home child is the action card at %s" % at)
		var ratio := hero.size.x / maxf(card.size.x, 1.0)
		var want := MainMenu.HERO_RATIO / MainMenu.CARD_RATIO
		assert_true(absf(ratio - want) <= want * 0.02, "hero / card width %.3f is %.1f within 2%% at %s (%s / %s)" % [
				ratio, want, at, hero.size.x, card.size.x])
		assert_true(menu.later_grid.columns == 1 or menu.later_grid.columns == 2,
				"later grid has 1 or 2 columns at %s (%d)" % [at, menu.later_grid.columns])
		menu.free()
	_restore(prev, old_profile)
	await tree.process_frame


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
