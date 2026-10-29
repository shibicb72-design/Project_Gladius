extends "res://tests/test_case.gd"

## G3e: optional left Fire button. Off by default (no button, not an editable element); when the profile flag is on
## it is built at the same size as Fire (at least 48 dp), presses and releases the one "fire" action, keeps firing
## while either Fire button is held, round-trips through the profile, and saves per layout slot like any element.
## Every test restores AppFlow.profile and removes its temp profile.

const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const KEY := "fire_left"
const COVER := Vector2i(2520, 1080)
const INNER := Vector2i(2176, 1812)
const TMP := "user://test_left_fire_profile.json"
const EPS := 0.01

var _saved_profile: Dictionary = {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin(enabled: bool) -> void:
	_saved_profile = AppFlow.profile
	AppFlow.profile = {"left_fire_enabled": true} if enabled else {}
	_rm()


func _end() -> void:
	AppFlow.profile = _saved_profile
	PlatformServices.dpi_override = 0.0
	Input.action_release("fire")
	_rm()


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _hud(sz: Vector2i) -> Control:
	var hud: Control = _TouchScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(sz)
	hud.relayout()
	return hud


func test_off_by_default() -> void:
	_begin(false)
	var hud := _hud(COVER)
	assert_true(not hud.get_element_keys().has(KEY), "left Fire is not an element while disabled")
	assert_true(not hud.get_button_actions().has(KEY), "no left Fire button is built while disabled")
	assert_true(not bool(SaveService.defaults()["left_fire_enabled"]), "profile default is off")
	hud.free()
	_end()


func test_enabled_builds_button_at_fire_size_and_min_dp() -> void:
	_begin(true)
	PlatformServices.dpi_override = 160.0  # dp scale 1.0
	var hud := _hud(COVER)
	assert_true(hud.get_element_keys().has(KEY), "left Fire is an element while enabled")
	var left: Rect2 = hud.get_button_rect(KEY)
	var fire: Rect2 = hud.get_button_rect("aim")
	assert_true(absf(left.size.x - fire.size.x) < EPS and absf(left.size.y - fire.size.y) < EPS, "same size as Fire: %s vs %s" % [left.size, fire.size])
	assert_true(left.size.x >= hud.get_element_min_px(KEY) - EPS, "at least the 48 dp floor, got %s" % left.size.x)
	assert_true(absf(hud.get_element_min_px(KEY) - 48.0 * PlatformServices.new().get_dp_scale()) < EPS, "min target is button_min_dp via the platform layer")
	assert_true(left.get_center().x < 0.5 * COVER.x, "on the left half")
	var inner := _hud(INNER)
	assert_true(inner.get_button_rect(KEY).size.x >= inner.get_element_min_px(KEY) - EPS, "floor holds on the inner screen")
	inner.free()
	hud.free()
	_end()


func test_press_and_release_drive_fire() -> void:
	_begin(true)
	var hud := _hud(COVER)
	var pos: Vector2 = hud.get_button_rect(KEY).get_center()
	hud._on_down(1, pos)
	assert_true(Input.is_action_pressed("fire"), "pressing left Fire presses fire")
	hud._on_up(1)
	assert_true(not Input.is_action_pressed("fire"), "releasing left Fire releases fire")
	hud.free()
	_end()


func test_both_fire_buttons_release_one_keeps_firing() -> void:
	_begin(true)
	var hud := _hud(COVER)
	var left: Vector2 = hud.get_button_rect(KEY).get_center()
	var right: Vector2 = hud.get_element_rect("look_stick").get_center()
	hud._on_down(1, left)
	hud._on_down(2, right)
	hud._process(float(hud._layout["look_hold_fire"]["hold_min_s"]) + 0.01)
	hud._on_up(1)
	assert_true(Input.is_action_pressed("fire"), "still firing after releasing the left Fire")
	hud._on_up(2)
	assert_true(not Input.is_action_pressed("fire"), "released once both are up")
	hud._on_down(1, left)
	hud._on_down(2, right)
	hud._process(float(hud._layout["look_hold_fire"]["hold_min_s"]) + 0.01)
	hud._on_up(2)
	assert_true(Input.is_action_pressed("fire"), "still firing after releasing the right Fire")
	hud._on_up(1)
	assert_true(not Input.is_action_pressed("fire"), "released once both are up (other order)")
	hud.free()
	_end()


func test_toggle_round_trips_through_save_service() -> void:
	_begin(false)
	var svc := SaveService.new(TMP)
	assert_true(not bool(svc.load_profile()["left_fire_enabled"]), "default false with no file")
	var p := svc.load_profile()
	p["left_fire_enabled"] = true
	assert_true(svc.save_profile(p), "saved")
	assert_true(svc.load_profile()["left_fire_enabled"] == true, "true survives a reload")
	p["left_fire_enabled"] = "yes"
	svc.save_profile(p)
	var v: Variant = svc.load_profile()["left_fire_enabled"]
	assert_true(v is bool and v == false, "a non-bool is sanitized to the false default")
	_end()


func test_settings_panel_toggle_persists() -> void:
	_begin(false)
	var panel := SettingsPanel.new()
	panel.save = SaveService.new(TMP)
	_tree().root.add_child(panel)
	assert_true(panel.left_fire_button.text.ends_with("Off"), "shows Off by default")
	panel.toggle_left_fire()
	assert_true(panel.save.load_profile()["left_fire_enabled"] == true, "the toggle is stored in the profile")
	assert_true(panel.left_fire_button.text.ends_with("On"), "shows On")
	panel.free()
	_end()


func _editor(sz: Vector2i) -> Control:
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(sz)
	await _tree().process_frame
	await _tree().process_frame
	ed.refresh()
	return ed


func test_editor_hides_it_while_disabled() -> void:
	_begin(false)
	var ed := await _editor(COVER)
	assert_true(not ed.preview.get_element_keys().has(KEY), "no Left Fire element in the editor while disabled")
	ed.free()
	_end()


func test_slot_position_saved_reloaded_applied_and_reset() -> void:
	_begin(true)
	var ed := await _editor(COVER)
	assert_eq(ed.element_name(KEY), "Left Fire", "editor name")
	var default_c: Vector2 = ed.preview.get_element_rect(KEY).get_center()
	ed.select_element(KEY)
	ed.move_selected_to(Vector2(0.4, 0.3))
	ed.size_slider.value = 150.0
	ed.alpha_slider.value = 40.0
	assert_true(ed.save_layout(), "saved (nothing off-screen)")
	var stored: Dictionary = ed.save.load_profile()["hud_layouts"]["slots"][0][KEY]
	assert_true(absf(float(stored["pos"][0]) - 0.4) < EPS and absf(float(stored["pos"][1]) - 0.3) < EPS, "slot holds the position, got %s" % str(stored))
	assert_true(float(stored["size_pct"]) == 150.0 and float(stored["alpha_pct"]) == 40.0, "slot holds size and opacity")
	# Reload into a real HUD from the saved profile.
	AppFlow.profile = ed.save.load_profile()
	AppFlow.profile["left_fire_enabled"] = true
	var hud := _hud(COVER)
	var c: Vector2 = hud.get_button_rect(KEY).get_center()
	assert_true(absf(c.x - 0.4 * COVER.x) < EPS and absf(c.y - 0.3 * COVER.y) < EPS, "saved slot position applied, got %s" % c)
	assert_true(absf((hud._buttons[KEY] as Control).modulate.a - 0.4) < EPS, "saved opacity applied")
	hud.free()
	# Reset returns it to the data default.
	ed.reset_current()
	var back: Vector2 = ed.preview.get_element_rect(KEY).get_center()
	assert_true(back.distance_to(default_c) < EPS, "Reset restores the data default %s, got %s" % [default_c, back])
	var pos: Array = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]["left_fire"]["pos"]
	assert_true(absf(back.x - float(pos[0]) * COVER.x) < EPS and absf(back.y - float(pos[1]) * COVER.y) < EPS, "default is touch_layout.left_fire.pos")
	ed.free()
	_end()


func test_default_position_is_inside_every_checked_size_and_clear_of_lock() -> void:
	_begin(true)
	var ed := await _editor(COVER)
	for sz in ed.check_sizes():
		for it in ed.check_slot(0, sz):
			assert_true(it["element"] != KEY or it["kind"] != "offscreen", "left Fire default stays on screen at %s" % str(sz))
	var hud := _hud(COVER)
	assert_true(not hud.get_button_rect(KEY).intersects(hud.get_lock_button_rect()), "clear of the Sprint lock button")
	assert_true(not hud.get_button_rect(KEY).intersects(hud.get_lock_target_rect()), "clear of the Sprint lock target")
	hud.free()
	ed.free()
	_end()
