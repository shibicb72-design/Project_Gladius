extends "res://tests/test_case.gd"
## D1 (spec G1.5): crouch input plumbing. InputMap crouch (prone/interact reserved), InputFrame bits 6-8 with
## backward-compatible serialization, and the cover Crouch control routed through the input layer.

const OLD_BUTTONS: Array[String] = ["fire", "aim", "reload", "swap_weapon", "jump", "pause"]
const NEW_BUTTONS: Array[String] = ["crouch", "prone", "interact"]


# ---- T1 InputMap ------------------------------------------------------------------------------

## D2 adds keyboard/gamepad bindings for crouch and may update the "no events" assertion.
func test_t1_inputmap_has_crouch_prone_interact_without_events() -> void:
	for a in NEW_BUTTONS:
		assert_true(InputMap.has_action(a), "InputMap has %s" % a)
		assert_eq(InputMap.action_get_events(a).size(), 0, "%s has no bindings yet (D2)" % a)


# ---- T2 BUTTONS order -------------------------------------------------------------------------

func test_t2_buttons_keep_old_order_and_append_new_bits() -> void:
	assert_eq(InputFrame.BUTTONS.size(), 9, "nine net buttons")
	for i in OLD_BUTTONS.size():
		assert_eq(InputFrame.BUTTONS[i], OLD_BUTTONS[i], "bit %d unchanged" % i)
	for i in NEW_BUTTONS.size():
		assert_eq(InputFrame.BUTTONS[6 + i], NEW_BUTTONS[i], "bit %d is %s" % [6 + i, NEW_BUTTONS[i]])
		assert_true(not InputFrame.LOCAL_BUTTONS.has(NEW_BUTTONS[i]), "%s is sent, not local" % NEW_BUTTONS[i])


# ---- T3 round trip ----------------------------------------------------------------------------

func _roundtrip(held: Array, just: Array) -> InputFrame:
	var f := InputFrame.new()
	f.move = Vector2(0.25, -0.5)
	for a in NEW_BUTTONS:
		f.set_button(a, held.has(a), just.has(a))
	var arr := f.to_array()
	assert_eq(arr.size(), 11, "to_array stays 11 elements")
	return InputFrame.from_array(arr)


func test_t3_new_bits_roundtrip_alone_and_together() -> void:
	var cases: Array = []
	for a in NEW_BUTTONS:
		cases.append([[a], []])
		cases.append([[a], [a]])
		cases.append([[], [a]])
	cases.append([NEW_BUTTONS.duplicate(), []])
	cases.append([NEW_BUTTONS.duplicate(), NEW_BUTTONS.duplicate()])
	for c in cases:
		var g := _roundtrip(c[0], c[1])
		for a in NEW_BUTTONS:
			assert_eq(g.is_pressed(a), (c[0] as Array).has(a), "%s held for %s" % [a, str(c)])
			assert_eq(g.is_just_pressed(a), (c[1] as Array).has(a), "%s just for %s" % [a, str(c)])
		for a in OLD_BUTTONS:
			assert_true(not g.is_pressed(a) and not g.is_just_pressed(a), "%s untouched for %s" % [a, str(c)])
		assert_eq(g.move, Vector2(0.25, -0.5), "move intact")


# ---- T4 legacy frames -------------------------------------------------------------------------

func test_t4_legacy_arrays_parse_as_before() -> void:
	# As an old client sends it: fire+jump held (bits 0, 4), jump just (bit 4), aim point, sprint.
	var legacy: Array = [0.5, -1.0, 0.1, -0.2, 0b010001, 0b010000, true, 1.0, 2.0, 3.0, true]
	var f := InputFrame.from_array(legacy)
	assert_eq(f.move, Vector2(0.5, -1.0), "legacy move")
	assert_eq(f.look, Vector2(0.1, -0.2), "legacy look")
	assert_true(f.fire_pressed and not f.fire_just_pressed, "legacy fire")
	assert_true(f.jump_pressed and f.jump_just_pressed, "legacy jump")
	for a in ["aim", "reload", "swap_weapon", "pause"]:
		assert_true(not f.is_pressed(a) and not f.is_just_pressed(a), "legacy %s false" % a)
	for a in NEW_BUTTONS:
		assert_true(not f.is_pressed(a) and not f.is_just_pressed(a), "legacy frame has %s false" % a)
	assert_true(f.has_aim_point and f.aim_point == Vector3(1, 2, 3), "legacy aim point")
	assert_true(f.sprint, "legacy sprint")
	# 10 elements: aim point but no sprint.
	var ten := InputFrame.from_array(legacy.slice(0, 10))
	assert_true(ten.has_aim_point and ten.aim_point == Vector3(1, 2, 3) and not ten.sprint, "10-element frame")
	assert_true(ten.fire_pressed and ten.jump_just_pressed and not ten.crouch_pressed, "10-element buttons")
	# 6 elements: buttons only.
	var six := InputFrame.from_array(legacy.slice(0, 6))
	assert_true(not six.has_aim_point and six.aim_point == Vector3.ZERO and not six.sprint, "6-element frame")
	assert_true(six.fire_pressed and six.jump_just_pressed and not six.crouch_pressed, "6-element buttons")
	# Shorter than 6: an empty frame.
	var short := InputFrame.from_array(legacy.slice(0, 5))
	assert_eq(short.move, Vector2.ZERO, "short frame move zero")
	for a in InputFrame.BUTTONS:
		assert_true(not short.is_pressed(a) and not short.is_just_pressed(a), "short frame %s false" % a)
