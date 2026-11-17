extends "res://tests/test_case.gd"

## M2 H1c item 2 (OQ-STICK-VISIBLE): the move stick works as before but nothing is drawn. data/input.json
## touch_layout.move_stick_visible (default false) is read for both stick kinds: the VirtualJoystick stays visible (it
## takes its touches through the GUI) with self_modulate alpha 0; the custom StickVisual skips its _draw. true brings
## the old drawing back; the layout editor always shows it; the rects (layout checks, the coach) are unchanged.
## Headless runs use the dummy renderer, so no pixels can be read: the tests assert the mechanism (effective alpha 0 /
## draw skipped) and drive the real touch path (Viewport.push_input) to prove the input still works.

const _HudScene := preload("res://scenes/ui/touch_hud.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Router := preload("res://scripts/input/input_router.gd")
const KINDS := ["virtual", "custom"]
const SIZES := [Vector2(1152, 648), Vector2(2520, 1080), Vector2(2176, 1812)]
const TEST_SIZE := Vector2(1152, 648)
const TMP := "user://test_h1c_stick_profile.json"

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


## A touch HUD with the given stick kind and the shipped data (move_stick_visible from data/input.json).
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


## True when the move stick draws something: the VirtualJoystick's effective own alpha, or the StickVisual's flag.
func _draws(hud: Control) -> bool:
	var s: Control = hud.move_stick
	if s is StickVisual:
		return (s as StickVisual).drawn and s.modulate.a > 0.0
	return s.modulate.a * s.self_modulate.a > 0.0


## The switch is off in the shipped data (the default the player gets).
func test_data_default_is_hidden() -> void:
	_begin()
	var hud := _hud("virtual")
	assert_eq(hud.cfg["touch_layout"].get("move_stick_visible", null), false, "data/input.json touch_layout.move_stick_visible is false")
	assert_true(not hud.move_stick_drawn(), "the HUD reads it: stick not drawn")
	hud.free()
	_end()


## Nothing drawn at rest and while a thumb holds and drags it, for both kinds; the VirtualJoystick stays visible.
func test_nothing_drawn_at_rest_and_while_dragged() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		var s: Control = hud.move_stick
		assert_eq(hud.move_mode, kind, "%s: kind" % kind)
		assert_true(s.visible and s.is_visible_in_tree(), "%s: the stick node stays visible (input path)" % kind)
		assert_true(not _draws(hud), "%s: nothing drawn at rest" % kind)
		if s is VirtualJoystick:
			assert_eq(s.self_modulate.a, 0.0, "%s: self_modulate alpha 0" % kind)
			assert_eq(s.get_child_count(), 0, "%s: no child that could draw" % kind)
			assert_eq((s as VirtualJoystick).visibility_mode, VirtualJoystick.VISIBILITY_ALWAYS, "%s: visibility_mode unchanged" % kind)
		else:
			assert_eq((s as StickVisual).drawn, false, "%s: StickVisual draw skipped" % kind)
		var p := Vector2(200, 400)
		_touch(0, p, true)
		_drag(0, p + Vector2(0, -80), Vector2(0, -80))
		await _frames(2)
		assert_true(hud._move_touch == 0, "%s: the thumb holds the stick" % kind)
		assert_true(hud.provider.move_value != Vector2.ZERO, "%s: the drag gives move input, got %s" % [kind, hud.provider.move_value])
		assert_true(not _draws(hud), "%s: nothing drawn while dragged" % kind)
		_touch(0, p + Vector2(0, -80), false)
		await _frames(2)
		assert_true(not _draws(hud), "%s: nothing drawn after release" % kind)
		hud.free()
	_end()


## A real touch through the viewport moves the local pawn with the hidden stick, both kinds.
func test_hidden_stick_moves_the_pawn() -> void:
	_begin()
	for kind in KINDS:
		_TouchHud.move_stick_override = kind
		var m: MatchRoot = _MatchScene.instantiate()
		m.auto_start = false
		m.bake_navmesh = false
		m.fill_bots = false
		_tree().root.add_child(m)
		await _tree().physics_frame
		m.director.load_config()
		m.begin()
		await _frames(3)
		var hud: Control = m.get_node("Hud/TouchHud")
		hud.cfg["force_touch_hud"] = true
		hud.rebuild_move_stick()
		hud.refresh_visibility()
		_size(hud, TEST_SIZE)
		assert_eq(hud.move_mode, kind, "%s: kind" % kind)
		assert_true(not _draws(hud), "%s: stick not drawn in the match" % kind)
		var before := m.local_player.global_position
		_touch(0, Vector2(200, 400), true)
		_drag(0, Vector2(200, 300), Vector2(0, -100))
		await _frames(10)
		var after := m.local_player.global_position
		var d := Vector2(after.x - before.x, after.z - before.z).length()
		assert_true(d > 0.01, "%s: pawn moved horizontally with the hidden stick, delta %s" % [kind, d])
		assert_true(not _draws(hud), "%s: still nothing drawn while moving" % kind)
		_touch(0, Vector2(200, 300), false)
		m.queue_free()
		await _tree().process_frame
		await _tree().process_frame
	_end()


## move_stick_visible true: today's drawing is back (full own alpha / draw on, VISIBILITY_ALWAYS as before).
func test_switch_on_restores_the_drawing() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		hud.cfg["touch_layout"]["move_stick_visible"] = true
		hud.relayout()
		assert_true(hud.move_stick_drawn() and _draws(hud), "%s: drawn with the switch on" % kind)
		var s: Control = hud.move_stick
		if s is VirtualJoystick:
			assert_eq(s.self_modulate.a, 1.0, "%s: self_modulate alpha 1 (as before)" % kind)
			assert_eq((s as VirtualJoystick).visibility_mode, VirtualJoystick.VISIBILITY_ALWAYS, "%s: VISIBILITY_ALWAYS" % kind)
		else:
			assert_eq((s as StickVisual).drawn, true, "%s: StickVisual draws" % kind)
		# A rebuilt stick (Settings changing the kind) follows the switch too.
		hud.rebuild_move_stick()
		assert_true(_draws(hud), "%s: drawn after a rebuild" % kind)
		hud.cfg["touch_layout"]["move_stick_visible"] = false
		hud.relayout()
		assert_true(not _draws(hud), "%s: hidden again with the switch off" % kind)
		hud.free()
	_end()


## The hidden stick keeps its rects: the same as with the switch on, centred on the data rest point.
func test_rects_unchanged() -> void:
	_begin()
	for kind in KINDS:
		var hud := _hud(kind)
		for sz in SIZES:
			_size(hud, sz)
			hud.cfg["touch_layout"]["move_stick_visible"] = false
			hud.relayout()
			var hidden: Rect2 = hud.get_move_visual_rect()
			var hidden_el: Rect2 = hud.get_element_rect("move_stick")
			var hidden_node := Rect2(hud.move_stick.position, hud.move_stick.size)
			hud.cfg["touch_layout"]["move_stick_visible"] = true
			hud.relayout()
			var shown: Rect2 = hud.get_move_visual_rect()
			var tag := "%s %s" % [kind, sz]
			assert_eq(hidden, shown, "%s: visual rect unchanged" % tag)
			assert_eq(hidden_el, hud.get_element_rect("move_stick"), "%s: element rect unchanged" % tag)
			assert_eq(hidden_node, Rect2(hud.move_stick.position, hud.move_stick.size), "%s: node rect unchanged" % tag)
			var rest: Array = hud.cfg["touch_layout"]["move_stick_rest"]
			var want := Vector2(float(rest[0]) * sz.x, float(rest[1]) * sz.y)
			assert_true(hidden.get_center().distance_to(want) < 0.01, "%s: centred on move_stick_rest %s, got %s" % [tag, want, hidden.get_center()])
		hud.cfg["touch_layout"]["move_stick_visible"] = false
		hud.free()
	_end()


## The layout editor's preview draws the stick (only there), both kinds; the stick stays an editable entry.
func test_layout_editor_shows_the_stick() -> void:
	_begin()
	for kind in KINDS:
		_TouchHud.move_stick_override = kind
		var ed: Control = _EditorScene.instantiate()
		ed.save = SaveService.new(TMP)
		_tree().root.add_child(ed)
		ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		ed.size = Vector2(2520, 1080)
		await _tree().process_frame
		await _tree().process_frame
		ed.refresh()
		var preview: Control = ed.preview
		assert_eq(preview.move_mode, kind, "%s: editor kind" % kind)
		assert_true(preview.get_element_keys().has("move_stick"), "%s: the stick is an editor entry" % kind)
		assert_true(preview.move_stick_drawn() and _draws(preview), "%s: the editor draws the stick" % kind)
		ed.select_element("move_stick")
		ed.move_selected_to(Vector2(0.2, 0.7))
		assert_true(_draws(preview), "%s: still drawn after a drag" % kind)
		assert_true((preview.get_element_rect("move_stick") as Rect2).get_center().distance_to(Vector2(0.2 * 2520, 0.7 * 1080)) < 0.01, "%s: the drag moves its start area" % kind)
		ed.free()
		# The match HUD with the same data still hides it.
		var hud := _hud(kind)
		assert_true(not _draws(hud), "%s: the match HUD does not draw it" % kind)
		hud.free()
	_end()


## The coach's "Drag here to move" ring is the coach's own drawing, around the hidden stick's rest rect in the left half.
func test_coach_move_hint_points_left_with_the_stick_hidden() -> void:
	_begin()
	for kind in KINDS:
		var sz := Vector2(2520, 1080)
		var hud := _hud(kind, sz)
		var me := Pawn.new()
		me.setup("hastati", 0)
		me.player_id = 0
		var c := HudCoach.new()
		c.save = SaveService.new(TMP)
		_tree().root.add_child(c)
		c.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		c.size = sz
		c.bind(null, me, hud, null, null)
		c.set_process(false)
		c.tick(float(HudCoach.data()["start_delay_s"]) + 0.01)
		assert_true(c.showing_hint(), "%s: the first hint shows" % kind)
		assert_eq(c.current_id(), "move", "%s: the first hint is the move hint" % kind)
		assert_true(not _draws(hud), "%s: the stick is not drawn under it" % kind)
		var h: Dictionary = c.hint_layout(sz)
		var stick: Rect2 = hud.get_move_visual_rect()
		var ring_c: Vector2 = h["ring_c"]
		assert_true(ring_c.x < sz.x * 0.5, "%s: the ring is in the left half, %s" % [kind, ring_c])
		assert_true(ring_c.distance_to(stick.get_center()) < 0.5, "%s: the ring is centred on the stick's rest rect %s, got %s" % [kind, stick, ring_c])
		assert_true(float(h["ring_r"]) > 0.0, "%s: the coach draws its own ring (radius %s)" % [kind, h["ring_r"]])
		c.free()
		me.free()
		hud.free()
	_end()
