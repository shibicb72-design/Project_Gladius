extends "res://tests/test_case.gd"

## M2 H1a step 3: the in-match touch layout. A main look area (data touch_layout.look_area) with no control in it on the
## six test sizes; every control >= 48 dp, on screen and clear of every other; Fire below Aim, Reload the bottom-right-
## most button, the Sprint lock above the move stick; the look stick only in look mode "stick"; a saved layout in the
## look area is warned, not blocked; the one-time reset of layouts saved for the old placement.

const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _PauseScene := preload("res://scenes/ui/pause_menu.tscn")
const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
## Fold cover, Fold inner, the two small test sizes (layout_editor.check_sizes) and the two Ultra sizes.
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const DPIS := [420.0, 373.0]
const TMP := "user://test_h1a_layout_profile.json"
const FIXTURE := "res://tests/fixtures/h1a_old_layout_profile.json"

var _saved_profile: Dictionary = {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin(profile: Dictionary = {}) -> void:
	_saved_profile = AppFlow.profile
	AppFlow.profile = profile
	_rm()


func _end() -> void:
	AppFlow.profile = _saved_profile
	PlatformServices.dpi_override = 0.0
	_TouchHud.move_stick_override = ""
	HudArrangement.placement_override = ""
	_rm()


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _new_touch(sz: Vector2) -> Control:
	var touch: Control = _TouchScene.instantiate()
	touch.save = SaveService.new(TMP)
	_tree().root.add_child(touch)
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = sz
	touch.relayout()
	return touch


## Every control the match shows on the touch screen, as the real nodes place them: the touch HUD buttons (incl. the
## optional Left Fire), the Sprint lock button and its target, the Interact button (InteractButton.get_touch_rect on
## this HUD), the fire-mode button (FireModeButton.touch_rect, what its node uses) and the pause gear (a PauseMenu).
func _controls(touch: Control, pm: PauseMenu, sz: Vector2) -> Dictionary:
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	# M2 H1b: the reserved minimap's tap target (HudArrangement.minimap_tap_rect) is a touch target too; the gear is at
	# its H1b place under the reserved panel (pm.get_gear_touch_rect follows data pause_gear.below_panel).
	var out := {"sprint_lock": touch.get_lock_button_rect(), "lock_target": touch.get_lock_target_rect(),
		"gear": pm.get_gear_touch_rect(), "fire_mode": FireModeButton.touch_rect(ui["fire_mode_button"], sz),
		"minimap_tap": HudArrangement.minimap_tap_rect(sz)}
	for key in touch.get_button_actions():
		out[key] = touch.get_button_rect(key)
	var interact := InteractButton.new()
	interact.cfg = ui["interact_button"]
	interact.touch_hud = touch
	out["interact"] = interact.get_touch_rect()
	interact.free()
	return out


func _pause(sz: Vector2) -> PauseMenu:
	var pm: PauseMenu = _PauseScene.instantiate()
	_tree().root.add_child(pm)
	pm.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pm.size = sz
	return pm


## Runs `check` on every HUD arrangement (M2 H1b: above_row, split_row) x size x dpi x shooting mode x Left Fire x cover
## slot state.
func _each_state(check: Callable) -> void:
	for placement in [HudArrangement.ABOVE_ROW, HudArrangement.SPLIT_ROW]:
		HudArrangement.placement_override = placement
		for dpi in DPIS:
			PlatformServices.dpi_override = dpi
			for sz in SIZES:
				for mode in ["advanced", "simple"]:
					for lf in [false, true]:
						AppFlow.profile = {"shooting_mode": mode, "left_fire_enabled": lf}
						var touch := _new_touch(sz)
						var pm := _pause(sz)
						for cover in [false, true]:
							touch.set_cover_slot(cover, cover, false)
							touch.relayout()
							check.call(touch, pm, sz, "%s %s dpi %d %s left_fire=%s cover=%s" % [HudArrangement.placement_for(sz), sz, dpi, mode, lf, cover])
						pm.free()
						touch.free()
	HudArrangement.placement_override = ""


func test_no_control_in_the_look_area() -> void:
	_begin()
	_each_state(func(touch: Control, pm: PauseMenu, sz: Vector2, tag: String) -> void:
		var look: Rect2 = touch.get_look_area_rect()
		assert_true(look.get_area() > 0.25 * sz.x * sz.y, "%s: look area %s is over a quarter of the screen" % [tag, look])
		var ctrls := _controls(touch, pm, sz)
		assert_eq(ctrls.has("fire_right"), tag.contains("advanced"), "%s: right Fire only in Advanced" % tag)
		assert_eq(ctrls.has("fire_left"), tag.contains("left_fire=true"), "%s: Left Fire only when on" % tag)
		for key in ctrls:
			assert_true(not (ctrls[key] as Rect2).intersects(look), "%s: %s %s clear of the look area %s" % [tag, key, ctrls[key], look]))
	_end()


func test_controls_48dp_on_screen_and_apart() -> void:
	_begin()
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		_each_state(func(touch: Control, pm: PauseMenu, sz: Vector2, tag: String) -> void:
			var dp := PlatformServices.new().get_dp_scale()
			var ctrls := _controls(touch, pm, sz)
			var move: Rect2 = touch.get_move_visual_rect()
			var view := Rect2(Vector2.ZERO, sz)
			var names: Array = ctrls.keys()
			for i in names.size():
				var r: Rect2 = ctrls[names[i]]
				assert_true(r.size.x / dp >= 48.0 - 1e-3 and r.size.y / dp >= 48.0 - 1e-3, "%s %s: %s %.1f dp >= 48" % [stick, tag, names[i], r.size.x / dp])
				assert_true(view.encloses(r), "%s %s: %s %s fully on screen" % [stick, tag, names[i], r])
				assert_true(not r.intersects(move), "%s %s: %s %s clear of the move stick %s" % [stick, tag, names[i], r, move])
				for j in range(i + 1, names.size()):
					assert_true(not r.intersects(ctrls[names[j]]), "%s %s: %s %s overlaps %s %s" % [stick, tag, names[i], r, names[j], ctrls[names[j]]])
			assert_true(move.size.x / dp >= 48.0 - 1e-3 and view.encloses(move), "%s %s: move stick %s >= 48 dp, on screen" % [stick, tag, move]))
	_end()


## Structural rules that survive retuning the numbers.
func test_fire_below_aim_reload_bottom_right_lock_above_stick() -> void:
	_begin()
	_each_state(func(touch: Control, pm: PauseMenu, sz: Vector2, tag: String) -> void:
		var aim: Rect2 = touch.get_button_rect("aim")
		var reload: Rect2 = touch.get_button_rect("reload")
		if touch.get_button_actions().has("fire_right"):
			var fire: Rect2 = touch.get_button_rect("fire_right")
			assert_true(fire.position.y >= aim.end.y and fire.position.x < aim.end.x and aim.position.x < fire.end.x, "%s: Fire %s directly below Aim %s" % [tag, fire, aim])
			assert_true(fire.end.x >= sz.x - 0.15 * fire.size.x, "%s: Fire %s at the right edge" % [tag, fire])
		# Bottom-right-most: no right-side button sits lower, and of the bottom row Reload is the right-most.
		for key in touch.get_button_actions():
			var r: Rect2 = touch.get_button_rect(key)
			if r.get_center().x <= 0.5 * sz.x or key == "reload":
				continue
			assert_true(r.get_center().y <= reload.get_center().y + 0.5, "%s: %s %s not lower than Reload %s" % [tag, key, r, reload])
			if absf(r.get_center().y - reload.get_center().y) < 0.5:
				assert_true(r.get_center().x < reload.get_center().x, "%s: Reload right of %s on the bottom row" % [tag, key])
		assert_true(reload.end.y >= sz.y - 0.15 * reload.size.y, "%s: Reload %s on the bottom edge" % [tag, reload])
		var lock: Rect2 = touch.get_lock_button_rect()
		var stick: Rect2 = touch.get_move_visual_rect()
		assert_true(lock.end.y <= stick.position.y and lock.position.x < stick.end.x and stick.position.x < lock.end.x, "%s: Sprint lock %s above the move stick %s" % [tag, lock, stick])
		var target: Rect2 = touch.get_lock_target_rect()
		assert_true(target.end.y <= stick.position.y, "%s: lock target %s above the move stick" % [tag, target]))
	_end()


## The Fire button left the spot where the look thumb rests (the pre-H1a look stick rest [0.88, 0.78], which the old
## Fire offset [-1.65, -0.15] hung off).
const OLD_LOOK_REST := Vector2(0.88, 0.78)


func test_fire_moved_off_the_look_rest() -> void:
	_begin()
	for dpi in DPIS:
		PlatformServices.dpi_override = dpi
		for sz in SIZES:
			var touch := _new_touch(sz)
			var rest: Vector2 = OLD_LOOK_REST * sz
			var fire: Rect2 = touch.get_button_rect("fire_right")
			var s: float = touch._button_size()
			var old_fire := Rect2(rest + Vector2(-1.65, -0.15) * s - Vector2.ONE * s * 0.5, Vector2.ONE * s)
			assert_true(not fire.has_point(rest), "%s dpi %d: Fire %s is not on the old look rest %s" % [sz, dpi, fire, rest])
			assert_true(not fire.intersects(old_fire), "%s dpi %d: Fire %s shares nothing with its old rect %s" % [sz, dpi, fire, old_fire])
			assert_true(fire.get_center().x > rest.x and fire.get_center().y > rest.y - 0.5 * s, "%s dpi %d: Fire %s is right of and not above the old rest %s" % [sz, dpi, fire, rest])
			touch.free()
	_end()


## Swap (and its fire-mode / Interact neighbours, Left Fire, the Sprint lock) sit in the left half, the floating
## VirtualJoystick's touch area: a press on a touch HUD button is consumed and never also spawns the move stick.
func test_button_in_the_move_zone_does_not_spawn_the_joystick() -> void:
	_begin()
	_TouchHud.move_stick_override = "virtual"
	var touch := _new_touch(Vector2(1152, 648))
	assert_eq(touch.move_mode, "virtual", "fixture: the VirtualJoystick move stick")
	var c: Vector2 = touch.get_button_rect("swap_weapon").get_center()
	assert_true(touch._zone_hit_rect("move_zone").has_point(c), "fixture: Swap is in the move zone")
	var down := InputEventScreenTouch.new()
	down.index = 3
	down.pressed = true
	down.position = c
	_tree().root.push_input(down, true)
	assert_true(Input.is_action_pressed("swap_weapon"), "the press reached Swap")
	var drag := InputEventScreenDrag.new()
	drag.index = 3
	drag.position = c + Vector2(0, -200)
	drag.relative = Vector2(0, -200)
	_tree().root.push_input(drag, true)
	touch._process(1.0 / 60.0)
	assert_eq(touch.provider.move_value, Vector2.ZERO, "no move: the joystick never took the touch")
	var up := InputEventScreenTouch.new()
	up.index = 3
	up.pressed = false
	up.position = drag.position
	_tree().root.push_input(up, true)
	assert_true(not Input.is_action_pressed("swap_weapon"), "released")
	# Control: the same touch path off any button does move (so the check above can fail).
	var free_point: Vector2 = touch.get_move_rest()
	down.position = free_point
	_tree().root.push_input(down, true)
	drag.position = free_point + Vector2(0, -200)
	_tree().root.push_input(drag, true)
	touch._process(1.0 / 60.0)
	assert_true(touch.provider.move_value.y < 0.0, "control: a move-zone touch off the buttons moves, got %s" % touch.provider.move_value)
	up.position = drag.position
	_tree().root.push_input(up, true)
	touch.free()
	_end()


func test_look_stick_only_in_stick_mode() -> void:
	_begin()
	var touch := _new_touch(Vector2(2520, 1080))
	assert_eq(touch.provider.look_mode, "drag", "data default look mode is drag")
	assert_true(touch.look_stick == null, "drag: no look stick node")
	assert_true(touch.get_node_or_null("look_stick") == null, "drag: nothing drawn for the look stick")
	assert_true(not touch.get_element_keys().has("look_stick"), "drag: not an editor element")
	touch.provider.look_mode = "stick"
	touch.refresh_look_stick()
	assert_true(touch.look_stick != null and touch.get_node_or_null("look_stick") != null, "stick: the look stick is drawn")
	assert_true(touch.get_element_keys().has("look_stick"), "stick: an editor element")
	assert_true(touch.get_element_rect("look_stick").size.x > 0.0, "stick: it has a rect")
	touch.provider.look_mode = "drag"
	touch.refresh_look_stick()
	assert_true(touch.look_stick == null and not touch.get_element_keys().has("look_stick"), "back to drag: removed again")
	touch.free()
	_end()


func test_editor_has_no_look_stick_in_drag_mode() -> void:
	_begin()
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	await _tree().process_frame
	assert_true(not ed.preview.get_element_keys().has("look_stick"), "editor preview has no look stick element in drag mode")
	ed.free()
	_end()


## A saved layout may put a button in the look area: the editor flags it and still saves; the match HUD places it there.
func test_layout_in_look_area_is_warned_not_blocked() -> void:
	_begin()
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(2520, 1080)
	await _tree().process_frame
	await _tree().process_frame
	ed.refresh()
	for it in ed.issues:
		assert_true(it["kind"] != "look_area", "the default layout has no look-area warning: %s" % it["text"])
	ed.select_element("jump")
	ed.move_selected_to(Vector2(0.75, 0.45))
	var flagged := false
	for it in ed.issues:
		flagged = flagged or (it["kind"] == "look_area" and it["element"] == "jump")
	assert_true(flagged, "Jump in the look area is flagged")
	assert_true(not ed.is_blocked(), "a look-area warning does not block Save")
	assert_true(ed.warn_label.visible and ed.warn_label.text.contains("look area"), "the warning is shown: %s" % ed.warn_label.text)
	assert_true(ed.save_layout(), "Save succeeds")
	var p := SaveService.new(TMP).load_profile()
	var pos: Array = p["hud_layouts"]["slots"][0]["jump"]["pos"]
	assert_true(absf(pos[0] - 0.75) < 1e-4 and absf(pos[1] - 0.45) < 1e-4, "the saved position loads unchanged: %s" % [pos])
	ed.free()
	AppFlow.profile = p
	var touch := _new_touch(Vector2(2520, 1080))
	assert_true(touch.get_look_area_rect().intersects(touch.get_button_rect("jump")), "the match HUD puts Jump where the player saved it")
	touch.free()
	_end()


func _copy_fixture() -> void:
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(FIXTURE))
	f.close()


func _raw(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## An old-format profile (G2e hud_layouts with no version, a legacy sprint_lock_pos) is reset once, written back in the
## new format, and the next load leaves it alone.
func test_old_format_layout_resets_once() -> void:
	_begin()
	_copy_fixture()
	var old_raw := _raw(TMP)
	assert_true(not (old_raw["hud_layouts"] as Dictionary).has("version"), "fixture is the old format (no version)")
	var save := SaveService.new(TMP)
	var p := save.load_profile()
	assert_eq(p["hud_layouts"]["version"], HudLayoutModel.current_version(), "loaded in the new format")
	for slot in p["hud_layouts"]["slots"]:
		assert_true((slot as Dictionary).is_empty(), "every slot back to the defaults")
	assert_eq(p["hud_layouts"]["active"], 0, "slot 1 active")
	assert_eq(p["sprint_lock_pos"], [], "legacy sprint_lock_pos reset")
	assert_true(p["layout_notice_pending"], "the one-time notice is pending")
	assert_eq(p["gamertag"], "OldLayout", "the rest of the profile survives")
	var raw := _raw(TMP)
	assert_eq(int(raw["hud_layouts"]["version"]), HudLayoutModel.current_version(), "written back at once in the new format")
	assert_eq(raw["sprint_lock_pos"], [], "written back without the legacy lock position")
	# After that load a new edit survives every later load.
	p["hud_layouts"]["slots"][0] = {"jump": {"pos": [0.6, 0.9]}}
	p["layout_notice_pending"] = false
	save.save_profile(p)
	var again := save.load_profile()
	assert_eq(again["hud_layouts"]["slots"][0], {"jump": {"pos": [0.6, 0.9]}}, "a new-format layout is never reset again")
	assert_true(not again["layout_notice_pending"], "no second notice")
	_end()


func test_old_format_without_edits_resets_silently() -> void:
	_begin()
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"gamertag": "Plain", "sprint_lock_pos": [], "hud_layouts": {"active": 0, "slots": [{}, {}, {}]}}))
	f.close()
	var p := SaveService.new(TMP).load_profile()
	assert_true(not p["layout_notice_pending"], "nothing was lost: no notice")
	assert_eq(int(_raw(TMP)["hud_layouts"]["version"]), HudLayoutModel.current_version(), "still written in the new format")
	_end()


func test_new_format_layout_loads_unchanged() -> void:
	_begin()
	var m := HudLayoutModel.new()
	m.set_pos(0, "reload", Vector2(0.9, 0.95))
	m.set_size_pct(1, "aim", 120.0)
	m.set_alpha_pct(2, "jump", 60.0)
	m.set_active(2)
	var save := SaveService.new(TMP)
	var prof := SaveService.defaults()
	prof["hud_layouts"] = m.to_dict()
	prof["sprint_lock_pos"] = [0.2, 0.3]
	save.save_profile(prof)
	var p := save.load_profile()
	# Compared as JSON text: the file stores the float32 positions at JSON precision.
	assert_eq(JSON.stringify(p["hud_layouts"]), JSON.stringify(m.to_dict()), "every slot and the active slot load unchanged")
	assert_eq(p["sprint_lock_pos"], [0.2, 0.3], "the lock position too")
	assert_true(not p["layout_notice_pending"], "no notice")
	_end()


## The notice shows once, in the first live HUD; the layout editor's preview (suspended) never takes it.
func test_notice_shows_once() -> void:
	_begin()
	_copy_fixture()
	AppFlow.profile = SaveService.new(TMP).load_profile()
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	ed.preview.save = SaveService.new(TMP)
	await _tree().process_frame
	await _tree().process_frame
	assert_true(ed.preview.notice_label == null, "the editor preview shows no notice")
	assert_true(AppFlow.profile["layout_notice_pending"], "still pending after the editor")
	ed.free()
	var touch := _new_touch(Vector2(2520, 1080))
	await _tree().process_frame
	assert_true(touch.notice_label != null, "the first live HUD shows the notice")
	var text := str(DataRegistry.new().load_file("res://data/ui.json")["layout_reset_notice"]["text"])
	assert_eq(touch.notice_label.text, text, "text from data")
	assert_true(not AppFlow.profile["layout_notice_pending"], "cleared in memory")
	assert_true(not SaveService.new(TMP).load_profile()["layout_notice_pending"], "cleared in the profile file")
	touch.free()
	var second := _new_touch(Vector2(2520, 1080))
	await _tree().process_frame
	assert_true(second.notice_label == null, "the next HUD shows no notice")
	second.free()
	_end()


func test_reset_restores_the_new_defaults() -> void:
	_begin()
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(2520, 1080)
	await _tree().process_frame
	var default_fire: Rect2 = ed.preview.get_button_rect("fire_right")
	ed.select_element("fire_right")
	ed.move_selected_to(Vector2(0.7, 0.6))
	assert_true(not ed.preview.get_button_rect("fire_right").is_equal_approx(default_fire), "moved")
	ed.reset_current()
	assert_true(ed.preview.get_button_rect("fire_right").is_equal_approx(default_fire), "Reset puts Fire back at the new default")
	assert_true(ed.save_layout(), "saved")
	assert_true((SaveService.new(TMP).load_profile()["hud_layouts"]["slots"][0] as Dictionary).is_empty(), "the saved slot is the defaults")
	ed.free()
	_end()
