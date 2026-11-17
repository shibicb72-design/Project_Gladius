extends "res://tests/test_case.gd"

## M2 H1c item 3 (OQ-SPRINT-LOCK): Sprint lock on demand. The "Lock" target is as before (drawn only while the stick is
## pushed past the sprint trigger; lifting the thumb on it locks). The Sprint lock button is hidden unless sprint is
## locked, then drawn as "Locked"; a tap releases the lock and hides it. A hidden button catches no tap (a touch there is a
## move-stick touch). The old tap-to-lock while moving forward is gone. One rule: TouchHud.lock_button_shown() /
## lock_button_hit() reading TouchProvider.sprint_locked. In cover the Sprint-lock exit is the push and lift on the Lock
## target. Every touch goes through Viewport.push_input (the real path).

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const KINDS := ["virtual", "custom"]
const TEST_SIZE := Vector2(1152, 648)
const TMP := "user://test_h1c_sprint_lock_profile.json"

var _saved_profile: Dictionary = {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_saved_profile = AppFlow.profile
	AppFlow.profile = {}
	_rm()


func _end() -> void:
	AppFlow.profile = _saved_profile
	_TouchHud.move_stick_override = ""
	_rm()


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame
	await _tree().process_frame


func _hud(kind: String, sz: Vector2 = TEST_SIZE) -> Control:
	_TouchHud.move_stick_override = kind
	var hud: Control = _HudScene.instantiate()
	_tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.rebuild_move_stick()
	hud.refresh_visibility()
	_size(hud, sz)
	return hud


func _size(hud: Control, sz: Vector2) -> void:
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = sz
	hud.relayout()


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	_tree().root.push_input(e, true)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_tree().root.push_input(e, true)


func _tap(idx: int, pos: Vector2) -> void:
	_touch(idx, pos, true)
	await _frames(2)
	_touch(idx, pos, false)
	await _frames(2)


func _bubbles(hud: Control) -> String:
	return "button %s (%s), target %s" % [hud.lock_button.visible, hud.lock_button.text.replace("\n", " "), hud.lock_target.visible]


## A real move touch at `start` pushed to the forward extreme, then onto the Lock target (still held). Returns the
## target centre. Asserts the push shows the target and never the button.
func _push_to_target(hud: Control, idx: int, start: Vector2, tag: String) -> Vector2:
	_touch(idx, start, true)
	await _frames(1)
	var rad: float = hud._radius()
	_drag(idx, start + Vector2(0.0, -rad), Vector2(0.0, -rad))
	await _frames(3)
	assert_true(hud.provider.lock_target_visible() and hud.lock_target.visible, "%s: the push shows the Lock target (%s)" % [tag, _bubbles(hud)])
	assert_true(not hud.lock_button.visible, "%s: the Sprint lock button stays hidden during the push" % tag)
	var target: Vector2 = hud.get_lock_target_rect().get_center()
	_drag(idx, target, target - start - Vector2(0.0, -rad))
	await _frames(3)
	assert_true(hud.lock_target.visible and not hud.lock_button.visible, "%s: on the target, one bubble (%s)" % [tag, _bubbles(hud)])
	return target


## At rest the button is hidden (and the target too); a touch where it sits catches nothing and is a move touch.
func test_hidden_at_rest_and_a_touch_there_is_a_move_touch() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		await _frames(2)
		assert_true(not hud.lock_button.visible and not hud.lock_target.visible, "%s: nothing drawn at rest (%s)" % [kind, _bubbles(hud)])
		assert_true(not hud.lock_button_shown(), "%s: the rule says hidden" % kind)
		var p: Vector2 = hud.get_lock_button_rect().get_center()
		assert_true(hud._move_grab_rect().has_point(p), "%s: the button's rect sits in the move zone (the reason for the guard)" % kind)
		assert_true(not hud.lock_button_hit(p), "%s: a hidden button is not hit" % kind)
		_touch(0, p, true)
		await _frames(2)
		assert_eq(hud._lock_btn_touch, -1, "%s: the hidden button did not take the touch" % kind)
		assert_eq(hud._move_touch, 0, "%s: the touch is a move-stick touch" % kind)
		assert_true(not hud.provider.sprint_locked, "%s: no lock" % kind)
		_drag(0, p + Vector2(60, 0), Vector2(60, 0))
		await _frames(2)
		assert_true(hud.provider.move_value.x > 0.0, "%s: it moves like any move touch, got %s" % [kind, hud.provider.move_value])
		_touch(0, p + Vector2(60, 0), false)
		await _frames(2)
		assert_true(not hud.provider.sprint_locked and not hud.lock_button.visible, "%s: still unlocked and hidden" % kind)
		hud.free()
	_end()


## The push shows only the target; the lift on it locks: the button shows "Locked" and the target goes. Pushing forward
## again while locked (a new move touch) releases the lock first, so the bubbles never stack. A tap releases and hides.
func test_lift_on_target_locks_one_bubble_and_tap_releases() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		await _frames(1)
		var start := Vector2(200, 450)
		var target := await _push_to_target(hud, 0, start, kind)
		_touch(0, target, false)
		await _frames(2)
		assert_true(hud.provider.sprint_locked and hud.provider.is_sprinting(), "%s: the lift on the target locks sprint" % kind)
		assert_true(hud.lock_button.visible and hud.lock_button.text == "Locked", "%s: the button shows Locked (%s)" % [kind, _bubbles(hud)])
		assert_true(not hud.lock_target.visible and not hud.provider.lock_target_visible(), "%s: the target is not drawn while locked" % kind)
		# Pushing forward again while locked: today a new move touch ends the lock (TouchHud._on_down), so only the target
		# of the new push shows; never both.
		_touch(1, start, true)
		await _frames(1)
		assert_true(not hud.provider.sprint_locked, "%s: a new move touch while locked releases the lock" % kind)
		var rad: float = hud._radius()
		for k in range(1, 5):
			_drag(1, start + Vector2(0.0, -rad * 0.25 * k), Vector2(0.0, -rad * 0.25))
			await _frames(1)
			assert_true(not (hud.lock_button.visible and hud.lock_target.visible), "%s: never two bubbles during the second push (%s)" % [kind, _bubbles(hud)])
		assert_true(hud.lock_target.visible and not hud.lock_button.visible, "%s: the second push shows the target only (%s)" % [kind, _bubbles(hud)])
		# Lift on the target again, then release with a tap on the shown button.
		var t2: Vector2 = hud.get_lock_target_rect().get_center()
		_drag(1, t2, t2 - start - Vector2(0.0, -rad))
		await _frames(2)
		_touch(1, t2, false)
		await _frames(2)
		assert_true(hud.provider.sprint_locked and hud.lock_button.visible, "%s: locked again, button shown" % kind)
		var b: Vector2 = hud.get_lock_button_rect().get_center()
		_touch(2, b, true)
		await _frames(1)
		assert_eq(hud._lock_btn_touch, 2, "%s: the shown button takes the tap" % kind)
		assert_eq(hud._move_touch, -1, "%s: the tap is not a move touch" % kind)
		_touch(2, b, false)
		await _frames(2)
		assert_true(not hud.provider.sprint_locked and not hud.provider.is_sprinting(), "%s: the tap releases the lock" % kind)
		assert_true(not hud.lock_button.visible and not hud.lock_target.visible, "%s: the button hides again (%s)" % [kind, _bubbles(hud)])
		hud.free()
	_end()


## The removed path: a tap where the (hidden) button sits while the other thumb moves forward never locks.
func test_tap_on_hidden_button_while_moving_forward_does_not_lock() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		await _frames(1)
		var start := Vector2(200, 450)
		_touch(0, start, true)
		await _frames(1)
		_drag(0, start + Vector2(0.0, -hud._radius() * 0.5), Vector2(0.0, -hud._radius() * 0.5))
		await _frames(2)
		assert_true(hud.provider.move_value.y < 0.0, "%s: moving forward" % kind)
		await _tap(1, hud.get_lock_button_rect().get_center())
		assert_true(not hud.provider.sprint_locked, "%s: no tap-to-lock any more" % kind)
		assert_true(not hud.lock_button.visible, "%s: the button stays hidden" % kind)
		_touch(0, start, false)
		await _frames(2)
		hud.free()
	assert_true(not TouchProvider.new().has_method("toggle_sprint_lock"), "toggle_sprint_lock (lock while moving forward) is removed")
	_end()


## The profile's sprint_lock_pos fallback still places the button; the rule (hidden until locked) applies there too.
func test_profile_lock_fallback_position_still_works() -> void:
	_begin()
	AppFlow.profile = {"sprint_lock_pos": [0.25, 0.5]}
	var hud := _hud("custom")
	await _frames(1)
	assert_true(hud.use_profile_lock_fallback, "the match HUD uses the profile fallback")
	var c: Vector2 = hud.get_lock_button_rect().get_center()
	assert_true(c.is_equal_approx(Vector2(0.25 * TEST_SIZE.x, 0.5 * TEST_SIZE.y)), "the profile position places the button, got %s" % c)
	assert_true(not hud.lock_button.visible and not hud.lock_button_hit(c), "hidden and not hit at the profile position")
	hud.provider.lock_sprint()
	await _frames(1)
	assert_true(hud.lock_button.visible and hud.lock_button_hit(c), "shown and hit there while locked")
	assert_true((Vector2(hud.lock_button.position) + hud.global_position + hud.lock_button.size * 0.5).is_equal_approx(c), "the drawn button sits at the profile position")
	await _tap(3, c)
	assert_true(not hud.provider.sprint_locked and not hud.lock_button.visible, "a tap there releases and hides")
	hud.free()
	_end()


## The layout editor's preview always shows the Sprint lock entry so it can be placed; the match HUD hides it at rest.
func test_layout_editor_shows_the_sprint_lock_entry() -> void:
	_begin()
	var ed: Control = _EditorScene.instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(2520, 1080)
	await _tree().process_frame
	await _tree().process_frame
	ed.refresh()
	var preview: Control = ed.preview
	assert_true(preview.get_element_keys().has(HudLayoutModel.LOCK_KEY), "the Sprint lock is an editor entry")
	assert_true(not preview.provider.sprint_locked, "the preview is not locked")
	assert_true(preview.show_sprint_lock_for_editing and preview.lock_button_shown(), "the editor flag shows it")
	await _tree().process_frame
	assert_true(preview.lock_button.visible, "the editor draws the Sprint lock button")
	assert_true(not preview.lock_target.visible, "the editor does not draw the Lock target")
	ed.select_element(HudLayoutModel.LOCK_KEY)
	ed.move_selected_to(Vector2(0.3, 0.4))
	await _tree().process_frame
	assert_true(preview.lock_button.visible, "still drawn after a drag")
	assert_true((preview.get_element_rect(HudLayoutModel.LOCK_KEY) as Rect2).get_center().distance_to(Vector2(0.3 * 2520, 0.4 * 1080)) < 0.01, "the drag moves it")
	ed.free()
	var hud := _hud("virtual")
	await _frames(1)
	assert_true(not hud.lock_button.visible, "the match HUD with the same data hides it at rest")
	hud.free()
	_end()


func _match(drop: bool) -> MatchRoot:
	_TouchHud.move_stick_override = "custom"
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.fill_bots = false
	m.seed_override = 4242
	if drop:
		m.drop_from_sky = true
		m.ground_loot = true
		m.use_map_select = true
	else:
		m.bake_navmesh = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	if not drop:
		m.director.load_config()
	assert_true(m.begin(), "begin")
	await _frames(3)
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.rebuild_move_stick()
	hud.refresh_visibility()
	_size(hud, TEST_SIZE)
	return m


func _free_match(m: MatchRoot) -> void:
	m.queue_free()
	Input.action_release("jump")
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame
	await _tree().process_frame


## Point 6 [measured]: the drop's "Locked" bubble is this same button, driven by the real lock state, and a locked
## sprint does something in the fall (the glide runs straight forward with no finger), so it shows there; nothing is
## locked or shown at the start of a match.
func test_drop_lock_shows_only_while_locked_and_does_something() -> void:
	_begin()
	var m := await _match(true)
	var pawn := m.local_player
	var hud: Control = m.get_node("Hud/TouchHud")
	assert_eq(pawn.drop_state, Pawn.Drop.ABOARD, "on the carrier")
	assert_true(not hud.provider.sprint_locked, "no lock at the start of the match")
	assert_true(not hud.lock_button.visible and not hud.lock_target.visible, "nothing drawn on the carrier at rest (%s)" % _bubbles(hud))
	# A forward push on the carrier shows the target; the lift locks (the clip's "Locked" during the drop).
	var start := Vector2(200, 450)
	var target := await _push_to_target(hud, 0, start, "carrier")
	_touch(0, target, false)
	await _frames(2)
	assert_true(hud.provider.sprint_locked and hud.lock_button.visible and hud.lock_button.text == "Locked", "locked on the carrier: Locked shown (%s)" % _bubbles(hud))
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	for i in 120:
		await _tree().physics_frame
		if pawn.drop_state == Pawn.Drop.FALLING:
			break
	for i in 20:
		await _tree().physics_frame
	await _tree().process_frame
	assert_eq(pawn.drop_state, Pawn.Drop.FALLING, "falling")
	assert_true(hud.provider.sprint_locked and hud.lock_button.visible, "the lock carries into the fall and shows")
	var fwd := -pawn.global_basis.z
	var glide := Vector2(pawn.velocity.x, pawn.velocity.z)
	assert_true(glide.dot(Vector2(fwd.x, fwd.z)) > 0.5 * pawn.drop_glide_mps, "the locked fall glides forward with no finger (it does something), v %s" % glide)
	print("H1C LOCK DROP falling locked: horizontal glide %.3f m/s (drop_glide_mps %.3f)" % [glide.length(), pawn.drop_glide_mps])
	await _tap(2, hud.get_lock_button_rect().get_center())
	await _frames(2)
	assert_eq(pawn.drop_state, Pawn.Drop.FALLING, "still falling")
	assert_true(not hud.provider.sprint_locked and not hud.lock_button.visible, "a tap releases and hides it in the fall")
	assert_true(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.01, "released: no glide with no finger, v %s" % pawn.velocity)
	await _free_match(m)
	_end()


## In cover the Sprint lock button is hidden at rest; the exit is the push to the forward extreme (the target shows
## there although that push does not sprint) and the lift on the Lock target, which locks, exits and sprints.
func test_cover_exit_through_the_lock_target_with_the_button_hidden() -> void:
	_begin()
	var m := await _match(false)
	var pawn := m.local_player
	var hud: Control = m.get_node("Hud/TouchHud")
	for i in 30:
		await _tree().physics_frame
	assert_true(pawn.cover != null and pawn.cover_button_available(), "fixture: the pawn offers cover")
	pawn.rotation.y = 0.0
	var wall := StaticBody3D.new()
	wall.add_to_group(&"cover_wall")
	wall.position = pawn.global_position + Vector3.FORWARD * 1.6 + Vector3.UP * 1.1
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	wall.add_child(shape)
	m.add_child(wall)
	await _frames(3)
	hud.provider.trigger_action("cover")
	for i in 90:
		await _tree().physics_frame
		if pawn.cover.state == CoverController.State.IN_COVER and not pawn.is_cover_turning():
			break
	await _frames(2)
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "fixture: in cover")
	assert_true(not hud.lock_button.visible and not hud.lock_target.visible, "in cover at rest: nothing drawn (%s)" % _bubbles(hud))
	var target := await _push_to_target(hud, 0, Vector2(200, 450), "cover")
	assert_true(hud.provider.cover_suppress_sprint and not hud.provider.is_sprinting(), "the push does not sprint in cover")
	assert_true(pawn.cover.state != CoverController.State.FREE, "the push alone does not exit")
	_touch(0, target, false)
	await _frames(2)
	assert_true(hud.provider.sprint_locked and hud.lock_button.visible, "the lift locks and the button shows")
	assert_true(pawn.cover.state == CoverController.State.EXITING or pawn.cover.state == CoverController.State.FREE, "the lock exits cover")
	for i in 60:
		await _tree().physics_frame
		if pawn.cover.state == CoverController.State.FREE:
			break
	for i in 20:
		await _tree().physics_frame
	assert_eq(pawn.cover.state, CoverController.State.FREE, "the exit completes")
	assert_true(pawn.sprint_factor > 1.0, "and sprints, factor %s" % pawn.sprint_factor)
	hud.provider.cancel_sprint_lock()
	wall.queue_free()
	await _free_match(m)
	_end()
