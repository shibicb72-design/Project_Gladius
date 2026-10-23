extends "res://tests/test_case.gd"

## G2e: HUD layout editor. Move / size / opacity reach the live touch HUD, the 48 dp floor, off-screen detection at
## the four checked sizes (landscape only, OQ-PORTRAIT), Save blocked while off-screen, three independent slots,
## Reset = the G2L default layout exactly, save/load round trip, and the overlap policy (warn only).
## Every test saves to a temp user:// profile and restores AppFlow.profile, so no saved layout leaks out.

const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const COVER := Vector2i(2520, 1080)
const INNER := Vector2i(2176, 1812)
const SMALL_COVER := Vector2i(1512, 648)
const SMALL_INNER := Vector2i(1152, 959)
const SIZES := [COVER, INNER, SMALL_COVER, SMALL_INNER]
const TMP := "user://test_layout_editor_profile.json"
const EPS := 0.01

var _saved_profile: Dictionary = {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_saved_profile = AppFlow.profile
	AppFlow.profile = {}
	_rm()


func _end() -> void:
	AppFlow.profile = _saved_profile
	PlatformServices.dpi_override = 0.0
	PlatformServices.safe_insets_override = null
	_rm()


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


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


func _issues_of(ed: Control, kind: String, element: String) -> Array:
	var out: Array = []
	for it in ed.issues:
		if it["kind"] == kind and it["element"] == element and it["slot"] == ed.model.active:
			out.append(it["size"])
	return out


func test_move_size_alpha_applied_to_live_hud() -> void:
	_begin()
	var ed := await _editor(COVER)
	for key in ed.preview.get_element_keys():
		ed.select_element(key)
		var before: Rect2 = ed.preview.get_element_rect(key)
		ed.move_selected_to(Vector2(0.4, 0.3))
		var moved: Rect2 = ed.preview.get_element_rect(key)
		assert_true(absf(moved.get_center().x - 0.4 * COVER.x) < EPS and absf(moved.get_center().y - 0.3 * COVER.y) < EPS, "%s moved to the dragged position, got %s" % [key, moved])
		ed.size_slider.value = 150.0
		var bigger: Rect2 = ed.preview.get_element_rect(key)
		assert_true(absf(bigger.size.x - before.size.x * 1.5) < 0.6, "%s size 150%%: %s vs default %s" % [key, bigger.size.x, before.size.x])
		ed.alpha_slider.value = 40.0
		assert_true(absf(_alpha_of(ed.preview, key) - 0.4) < EPS, "%s opacity 40%%, got %s" % [key, _alpha_of(ed.preview, key)])
	ed.free()
	_end()


func _alpha_of(hud: Control, key: String) -> float:
	if key == "move_stick":
		return hud.move_stick.modulate.a
	if key == "look_stick":
		return hud.look_stick.modulate.a
	if key == "sprint_lock":
		return hud.lock_button.modulate.a
	return (hud._buttons[key] as Control).modulate.a


func test_real_hud_applies_the_active_slot_from_the_profile() -> void:
	_begin()
	var model := HudLayoutModel.new()
	model.set_pos(1, "jump", Vector2(0.5, 0.25))
	model.set_alpha_pct(1, "jump", 30.0)
	model.set_pos(0, "jump", Vector2(0.1, 0.1))
	model.set_active(1)
	AppFlow.profile = {"hud_layouts": model.to_dict()}
	var hud: Control = _TouchScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(COVER)
	hud.relayout()
	var c: Vector2 = hud.get_button_rect("jump").get_center()
	assert_true(absf(c.x - 0.5 * COVER.x) < EPS and absf(c.y - 0.25 * COVER.y) < EPS, "active slot 2 position applied over the data default, got %s" % c)
	assert_true(absf(_alpha_of(hud, "jump") - 0.3) < EPS, "active slot opacity applied")
	var untouched: Rect2 = hud.get_button_rect("fire")
	assert_true(untouched.get_center().x > 0.5 * COVER.x, "an element the slot does not mention keeps its data default")
	hud.free()
	_end()


func test_size_never_below_48dp() -> void:
	for dpi in [0.0, 420.0]:
		_begin()
		PlatformServices.dpi_override = dpi
		var dp := PlatformServices.new().get_dp_scale()
		var ed := await _editor(SMALL_COVER)
		for key in ed.preview.get_element_keys():
			ed.select_element(key)
			var base: float = ed.preview.get_element_base_px(key)
			assert_true(ed.size_slider.min_value * base / 100.0 >= 48.0 * dp - EPS, "%s slider lower end %s%% is >= 48 dp at dpi %s" % [key, ed.size_slider.min_value, dpi])
			ed.size_slider.value = 0.0  # the slider clamps to its lower end
			assert_true(ed.size_slider.value >= ed.size_slider.min_value, "%s slider clamped" % key)
			var side: float = (ed.preview.get_element_rect(key) as Rect2).size.x
			assert_true(side >= 48.0 * dp - EPS, "%s target %s px >= 48 dp (%s px) at dpi %s" % [key, side, 48.0 * dp, dpi])
			# A stored value below the floor (older profile, other device) is still drawn at 48 dp or more.
			ed.model.set_size_pct(ed.model.active, key, 50.0)
			ed.preview.apply_slot_layout(ed.model.active_slot())
			side = (ed.preview.get_element_rect(key) as Rect2).size.x
			assert_true(side >= 48.0 * dp - EPS, "%s stored 50%% still >= 48 dp at dpi %s, got %s" % [key, dpi, side])
		ed.free()
		_end()


func test_offscreen_detected_at_the_four_sizes() -> void:
	_begin()
	for sz in SIZES:
		var ed := await _editor(sz)
		ed.select_element("fire")
		ed.move_selected_to(Vector2(0.995, 0.5))
		var off: Array = _issues_of(ed, "offscreen", "fire")
		for s in SIZES:
			assert_true(off.has(s), "fire at x=0.995 is off-screen at %s (editor at %s)" % [s, sz])
		assert_true(ed.warn_label.text.contains("Fire"), "warning names the element: %s" % ed.warn_label.text)
		ed.free()
	# A layout fitted on one screen may fall off another: x = 0.96 fits the cover screen but not the narrow ones.
	var ed2 := await _editor(COVER)
	ed2.select_element("fire")
	ed2.move_selected_to(Vector2(0.96, 0.5))
	var off2: Array = _issues_of(ed2, "offscreen", "fire")
	assert_true(not off2.has(COVER), "x=0.96 fits the cover screen")
	assert_true(not off2.has(SMALL_COVER), "x=0.96 fits 1512x648")
	assert_true(off2.has(SMALL_INNER), "x=0.96 falls off 1152x959")
	assert_true(off2.has(INNER), "x=0.96 falls off the inner screen")
	assert_true(ed2.is_blocked(), "a layout off-screen at any checked size blocks Save")
	ed2.free()
	_end()


func test_safe_area_is_used_when_the_platform_reports_one() -> void:
	_begin()
	var ed := await _editor(COVER)
	ed.select_element("fire")
	ed.move_selected_to(Vector2(0.97, 0.5))
	assert_true(not _issues_of(ed, "offscreen", "fire").has(COVER), "inside the cover viewport, no safe area: fine")
	PlatformServices.safe_insets_override = Vector4(0.0, 0.0, 0.05, 0.0)
	ed.refresh()
	assert_true(_issues_of(ed, "offscreen", "fire").has(COVER), "partly outside the platform safe area at the cover size")
	ed.free()
	_end()


func test_save_blocked_while_offscreen_until_fixed_or_reset() -> void:
	_begin()
	var ed := await _editor(COVER)
	ed.select_element("fire")
	ed.move_selected_to(Vector2(0.995, 0.5))
	assert_true(ed.save_button.disabled, "Save button disabled while off-screen")
	assert_true(not ed.save_layout(), "save_layout refuses while off-screen")
	assert_true(not FileAccess.file_exists(TMP), "nothing was written")
	ed.move_selected_to(Vector2(0.7, 0.5))
	assert_true(not ed.save_button.disabled, "fixed: Save enabled")
	ed.move_selected_to(Vector2(0.995, 0.5))
	ed.reset_current()
	assert_true(not ed.is_blocked(), "Reset also unblocks")
	assert_true(ed.save_layout(), "Save works after Reset")
	ed.free()
	_end()


func test_three_slots_are_independent() -> void:
	_begin()
	var ed := await _editor(COVER)
	var default_jump: Rect2 = ed.preview.get_element_rect("jump")
	ed.select_element("jump")
	ed.move_selected_to(Vector2(0.5, 0.2))
	ed.select_slot(1)
	assert_true(ed.preview.get_element_rect("jump").is_equal_approx(default_jump), "slot 2 starts at the defaults")
	ed.alpha_slider.value = 40.0
	ed.move_selected_to(Vector2(0.45, 0.35))
	ed.select_slot(2)
	assert_true(ed.preview.get_element_rect("jump").is_equal_approx(default_jump), "slot 3 untouched")
	assert_true(ed.model.slots[2].is_empty(), "slot 3 data empty")
	ed.select_slot(0)
	assert_true(absf(ed.preview.get_element_rect("jump").get_center().y - 0.2 * COVER.y) < EPS, "slot 1 kept its move")
	assert_true(absf(_alpha_of(ed.preview, "jump") - 1.0) < EPS, "slot 1 opacity not changed by slot 2")
	ed.select_slot(1)
	assert_true(absf(_alpha_of(ed.preview, "jump") - 0.4) < EPS, "slot 2 kept its opacity")
	assert_true(ed.save_layout(), "saved")
	var p := SaveService.new(TMP).load_profile()
	var loaded := HudLayoutModel.from_dict(p["hud_layouts"])
	assert_eq(loaded.active, 1, "active slot persisted")
	assert_true(loaded.slots[2].is_empty() and not loaded.slots[0].is_empty() and not loaded.slots[1].is_empty(), "three slots persisted independently")
	ed.free()
	_end()


## Resets after editing every element and compares each to the data/input.json touch_layout default.
func test_reset_restores_the_g2l_default_exactly() -> void:
	_begin()
	var ed := await _editor(COVER)
	var layout: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	var area := Vector2(COVER)
	var s: float = maxf(float(layout["button_size_frac_of_height"]) * area.y, float(layout["button_min_dp"]) * PlatformServices.new().get_dp_scale())
	var look := Vector2(layout["look_stick_rest"][0] * area.x, layout["look_stick_rest"][1] * area.y)
	for key in ed.preview.get_element_keys():
		ed.select_element(key)
		ed.move_selected_to(Vector2(0.37, 0.41))
		ed.size_slider.value = 180.0
		ed.alpha_slider.value = 35.0
	assert_true(ed.model.active_slot().size() == ed.preview.get_element_keys().size(), "every element was edited")
	ed.reset_current()
	assert_true(ed.model.active_slot().is_empty(), "slot data is empty after Reset")
	var expect_center := {
		"move_stick": Vector2(layout["move_stick_rest"][0] * area.x, layout["move_stick_rest"][1] * area.y),
		"look_stick": look,
		"sprint_lock": Vector2(layout["sprint_lock_pos"][0] * area.x, layout["sprint_lock_pos"][1] * area.y)}
	for action in layout["buttons"]:
		var o: Array = layout["buttons"][action]["offset"]
		expect_center[action] = look + Vector2(o[0], o[1]) * s
	for key in ed.preview.get_element_keys():
		var r: Rect2 = ed.preview.get_element_rect(key)
		assert_true(r.get_center().distance_to(expect_center[key]) < EPS, "%s centre %s is the data default %s" % [key, r.get_center(), expect_center[key]])
		var st: Dictionary = ed.preview.get_element_state(key)
		assert_eq(st["size_pct"], 100.0, "%s size back to 100%%" % key)
		assert_eq(st["alpha_pct"], 100.0, "%s opacity back to 100%%" % key)
		assert_true(absf(_alpha_of(ed.preview, key) - 1.0) < EPS, "%s drawn opaque" % key)
	# Same rects as a HUD that never saw an editor.
	var fresh: Control = _TouchScene.instantiate()
	_tree().root.add_child(fresh)
	fresh.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	fresh.size = area
	fresh.relayout()
	for key in ed.preview.get_element_keys():
		assert_true((ed.preview.get_element_rect(key) as Rect2).is_equal_approx(fresh.get_element_rect(key)), "%s rect equals a default HUD" % key)
	fresh.free()
	# Reset + Save also clears the mirrored Sprint lock position, so the data default applies in the game.
	assert_true(ed.save_layout(), "saved after Reset")
	assert_eq(SaveService.new(TMP).load_profile()["sprint_lock_pos"], [], "profile sprint_lock_pos cleared")
	ed.free()
	_end()


func test_save_load_round_trip() -> void:
	_begin()
	var ed := await _editor(COVER)
	ed.select_element("reload")
	ed.move_selected_to(Vector2(0.3, 0.55))
	ed.size_slider.value = 120.0
	ed.select_element("look_stick")
	ed.alpha_slider.value = 55.0
	ed.select_element("sprint_lock")
	ed.move_selected_to(Vector2(0.62, 0.3))
	ed.select_slot(2)
	ed.select_element("aim")
	ed.alpha_slider.value = 70.0
	ed.select_slot(0)
	var want: Dictionary = ed.model.to_dict()
	assert_true(ed.save_layout(), "saved")
	ed.free()
	var p := SaveService.new(TMP).load_profile()
	var got: Dictionary = p["hud_layouts"]
	assert_eq(got["active"], 0, "active slot")
	for i in 3:
		assert_eq(got["slots"][i].keys().size(), want["slots"][i].keys().size(), "slot %d element count" % (i + 1))
	var pos: Array = got["slots"][0]["reload"]["pos"]
	assert_true(absf(pos[0] - 0.3) < 0.0001 and absf(pos[1] - 0.55) < 0.0001, "position survives the file")
	assert_eq(got["slots"][0]["reload"]["size_pct"], 120.0, "size survives")
	assert_eq(got["slots"][2]["aim"]["alpha_pct"], 70.0, "slot 3 survives")
	assert_eq(p["sprint_lock_pos"].size(), 2, "profile sprint_lock_pos mirrors the active slot's lock button")
	# A restart: a new editor from the same file, and the game HUD from the loaded profile.
	var ed2 := await _editor(COVER)
	var c: Vector2 = ed2.preview.get_element_rect("reload").get_center()
	assert_true(absf(c.x - 0.3 * COVER.x) < 0.5 and absf(c.y - 0.55 * COVER.y) < 0.5, "reloaded editor shows the saved layout, got %s" % c)
	ed2.free()
	AppFlow.profile = p
	var hud: Control = _TouchScene.instantiate()
	_tree().root.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(COVER)
	hud.relayout()
	var lock_c: Vector2 = hud.get_lock_button_rect().get_center()
	assert_true(absf(lock_c.x - 0.62 * COVER.x) < 0.5 and absf(lock_c.y - 0.3 * COVER.y) < 0.5, "game HUD lock button at the saved position, got %s" % lock_c)
	hud.free()
	_end()


func test_editor_never_edits_the_data_default_lock_position() -> void:
	_begin()
	var before: Array = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]["sprint_lock_pos"].duplicate()
	var ed := await _editor(COVER)
	ed.select_element("sprint_lock")
	ed.move_selected_to(Vector2(0.62, 0.3))
	assert_true(ed.save_layout(), "saved")
	ed.free()
	assert_eq(DataRegistry.new().load_file("res://data/input.json")["touch_layout"]["sprint_lock_pos"], before, "data default untouched")
	var lock: Array = SaveService.new(TMP).load_profile()["sprint_lock_pos"]
	assert_true(lock.size() == 2 and absf(lock[0] - 0.62) < 0.0001 and absf(lock[1] - 0.3) < 0.0001, "the profile sprint_lock_pos holds the edit: %s" % [lock])
	_end()


## Policy (data layout_editor.overlap_policy = warn_only): an edited layout that overlaps the gear or the HUD bars
## is reported in the warning text but does not block Save. Only leaving the safe viewport blocks.
func test_overlap_with_gear_warns_and_does_not_block() -> void:
	_begin()
	assert_eq(HudLayoutModel.cfg()["overlap_policy"], "warn_only", "documented policy")
	PlatformServices.dpi_override = 420.0  # a big gear target, so a spot inside every checked viewport overlaps it
	var ed := await _editor(COVER)
	ed.select_element("jump")
	ed.move_selected_to(Vector2(0.94, 0.1))
	var found := false
	for it in ed.issues:
		if it["kind"] == "overlap" and it["element"] == "jump" and it["size"] == COVER and it["text"].contains("gear"):
			found = true
	assert_true(found, "overlap with the gear is reported by name: %s" % [ed.issues])
	assert_true(ed.warn_label.visible, "warning shown")
	assert_true(not ed.is_blocked(), "overlap alone does not block Save")
	ed.free()
	_end()


func test_default_layout_has_no_issues_at_the_four_sizes() -> void:
	_begin()
	var ed := await _editor(COVER)
	for sz in SIZES:
		assert_true(ed.check_slot(0, sz).is_empty(), "the G2L default layout is clean at %s: %s" % [sz, ed.check_slot(0, sz)])
	ed.free()
	_end()


func test_model_sanitizes_files() -> void:
	var m := HudLayoutModel.from_dict({"active": 9, "slots": [{"jump": {"pos": [2.0, -1.0], "size_pct": 9999, "alpha_pct": 0}, "": {"pos": [0.5, 0.5]}, "x": 5}, "junk"]})
	assert_eq(m.active, 2, "active clamped to the last slot")
	assert_eq(m.slots[0]["jump"]["pos"], [1.0, 0.0], "pos clamped to 0..1")
	assert_eq(m.slots[0]["jump"]["size_pct"], 250.0, "size clamped to the data range")
	assert_eq(m.slots[0]["jump"]["alpha_pct"], 10.0, "alpha clamped to the data range")
	assert_eq(m.slots[0].size(), 1, "empty key and non-dictionary entries dropped")
	assert_true(m.slots[1].is_empty() and m.slots[2].is_empty(), "bad slot data becomes empty")
	assert_true(HudLayoutModel.from_dict("nonsense").slots.size() == 3, "garbage gives three empty slots")
	var cfg := HudLayoutModel.cfg()
	assert_true(cfg["size_pct"]["_placeholder"] and cfg["alpha_pct"]["_placeholder"], "ranges are marked placeholders")
