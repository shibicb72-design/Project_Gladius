extends "res://tests/test_case.gd"
## D1: crouch input plumbing. InputMap crouch (prone/interact reserved), InputFrame bits 6-8 with
## backward-compatible serialization, and the cover Crouch control routed through the input layer.

const OLD_BUTTONS: Array[String] = ["fire", "aim", "reload", "swap_weapon", "jump", "pause"]
const NEW_BUTTONS: Array[String] = ["crouch", "prone", "interact"]
const DT := 1.0 / 60.0

var match_scene: MatchRoot
var local: Pawn
var touch: Control
var _old_size: Vector2i
var _old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


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


# ---- real match fixture (as tests/test_cover_crouch.gd:188-243) --------------------------------

func _begin_match() -> void:
	_old_size = tree().root.size
	_old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(1512, 648)
	match_scene = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	tree().root.add_child(match_scene)
	await tree().physics_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	await tree().process_frame
	await tree().process_frame
	local = match_scene.local_player
	local.set_physics_process(false)
	local.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	touch = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	# The test's update_frame() calls are the only consumers of the router latch.
	match_scene.router.set_physics_process(false)
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = Vector2(1512, 648)
	touch.relayout()


func _end_match() -> void:
	match_scene.queue_free()
	tree().root.size = _old_size
	AppFlow.profile = _old_profile
	await tree().process_frame
	await tree().process_frame


func _fake_cover(stand_clear: bool = true) -> void:
	local.cover.state = CoverController.State.IN_COVER
	local.cover._facts = {"height_m": 1.1, "muzzle_height_m": 1.3, "stand_clear": stand_clear}


## M2 C1b stage 3: the old cover Crouch square is no longer created by the HUD (its slot is the Sprint lock again), so
## the routed press is sent the way that button sent it: TouchProvider.trigger_action("crouch") (was: a real touch or
## mouse tap on the button). Returns crouched as seen right after the press.
func _tap_crouch() -> bool:
	touch.provider.trigger_action("crouch")
	return local.cover.crouched


# ---- T5 routed tap ----------------------------------------------------------------------------

func test_t5_real_tap_toggles_once_at_press_and_latches_one_frame_edge() -> void:
	await _begin_match()
	_fake_cover()
	var router: InputRouter = match_scene.router
	# M2 C1b stage 3: one routed press per pass (was: a touch pass and a mouse pass on the old Crouch square).
	for kind in ["first", "second"]:
		assert_true(not local.cover.crouched, "%s: starts standing" % kind)
		# M2 C1b stage 2 (decision 7): the routed press still reaches the router (edge below) but the pawn ignores
		# "crouch" in cover; the stance is automatic (was: crouched at press, one tap toggles once).
		assert_true(not _tap_crouch(), "%s: no stance change at press time" % kind)
		assert_true(not local.cover.crouched, "%s: the tap is ignored in cover" % kind)
		var f1 := router.update_frame()
		assert_true(f1.crouch_pressed and f1.crouch_just_pressed, "%s: next frame carries the latched crouch edge" % kind)
		var f2 := router.update_frame()
		assert_true(not f2.crouch_just_pressed and not f2.crouch_pressed, "%s: edge clears on the frame after" % kind)
		for i in 5:
			await tree().physics_frame
		assert_true(not local.cover.crouched, "%s: still no toggle after physics ticks" % kind)
		assert_true(not _tap_crouch() and not local.cover.crouched, "%s: a second tap is ignored too" % kind)
		router.update_frame()
		router.update_frame()
	# Gates: menu open, HUD suspended, dead. None may toggle.
	match_scene.pause_menu.open()
	_tap_crouch()  # the router path itself is gated while the menu is open
	assert_true(not local.cover.crouched, "menu open: no toggle")
	match_scene.pause_menu.close()
	touch.set_suspended(true)
	_tap_crouch()
	assert_true(not local.cover.crouched, "suspended: no toggle")
	touch.set_suspended(false)
	local.bridge.state.health = 0
	local.bridge.state.shield = 0
	_tap_crouch()  # the pawn gate refuses a dead pawn too
	assert_true(not local.cover.crouched, "dead: no toggle")
	router.update_frame()
	await _end_match()


func test_t5_router_latch_sets_edge_even_when_previous_frame_was_held() -> void:
	var r := InputRouter.new()
	var p := TouchProvider.new()
	r.add_provider(p)
	var seen: Array[String] = []
	r.action_triggered.connect(func(a: String) -> void: seen.append(a))
	p.trigger_action("crouch")
	assert_eq(seen, ["crouch"] as Array[String], "router re-emits at once")
	var f := r.update_frame()
	assert_true(f.crouch_pressed and f.crouch_just_pressed, "latched edge")
	p.trigger_action("crouch")
	f = r.update_frame()
	assert_true(f.crouch_pressed and f.crouch_just_pressed, "latched edge even after a held frame")
	p.trigger_action("not_an_action")
	assert_eq(seen.size(), 2, "unknown action ignored")
	r.remove_provider(p)
	p.trigger_action("crouch")
	assert_eq(seen.size(), 2, "removed provider disconnected")
	assert_true(not r.update_frame().crouch_pressed, "no latch from a removed provider")
	r.free()


# ---- T6 identical behaviour -------------------------------------------------------------------

## A real wall fixture (as tests/test_cover_crouch.gd:11-40), placed far from the map inside the real match.
func _wall_fixture() -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(1000, 0, 0)
	match_scene.add_child(root)
	_add_box(root, Vector3(0, -0.1, 0), Vector3(30, 0.2, 30), false)
	_add_box(root, Vector3(0, 0.55, -0.5), Vector3(4, 1.1, 1), true)
	local.position = root.position + Vector3(0, 0, 0.6)
	local.rotation = Vector3.ZERO
	local.pitch = 0.0
	local.velocity = Vector3.ZERO
	local.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await tree().physics_frame
	for i in 60:
		await _tick(Vector2(0, -1))
		if local.in_cover():
			local.cancel_cover_turn()  # M2 C1b stage 2: the view stays on the wall (as a look input would keep it)
	assert_eq(local.cover.state, CoverController.State.IN_COVER, "fixture snaps into cover (at %s)" % str(local.global_position))
	return root


func _add_box(root: Node3D, at: Vector3, dimensions: Vector3, cover_wall: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	if cover_wall:
		body.add_to_group(&"cover_wall")
	var shape := CollisionShape3D.new()
	shape.name = "Shape"  # CoverProbe reads the wall box from the "Shape" child
	var box := BoxShape3D.new()
	box.size = dimensions
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


## One manual pawn tick fed by the real router frame (so a latched crouch edge reaches the pawn).
func _tick(move: Vector2 = Vector2.ZERO) -> InputFrame:
	var f := match_scene.router.update_frame(DT)
	f.move = move
	local.set_frame(f)
	local._physics_process(DT)
	await tree().physics_frame
	return f


func _blend(routed: bool) -> Array[float]:
	var before := local.cover.crouched
	if routed:
		_tap_crouch()
	else:
		local.cover.toggle_crouch()
	# M2 C1b stage 2 (decision 7): both paths are ignored in cover (was: toggle at press).
	assert_eq(local.cover.crouched, before, "no toggle at press (routed=%s)" % routed)
	var amounts: Array[float] = []
	var n := ceili(float(local.cover.config["crouch_blend_s"]) / DT) + 2
	for i in n:
		var f: InputFrame = await _tick()
		if i == 0:
			assert_eq(f.crouch_just_pressed, routed, "only the routed press puts the edge in the frame")
		amounts.append(local.cover.crouch_amount)
	assert_eq(local.cover.crouched, before, "the frame edge does not toggle either (routed=%s)" % routed)
	return amounts


func test_t6_routed_tap_blends_identically_to_direct_toggle() -> void:
	await _begin_match()
	var root := await _wall_fixture()
	var routed_down := await _blend(true)
	var routed_up := await _blend(true)
	var direct_down := await _blend(false)
	var direct_up := await _blend(false)
	assert_eq(routed_down, direct_down, "routed and direct identical on every tick")
	assert_eq(routed_up, direct_up, "routed and direct identical on every tick (second press)")
	# M2 C1b stage 2: behind this LOW 1.1 m wall the automatic crouch holds (was: down blend 1.0, then up blend 0.0).
	assert_eq(routed_down[routed_down.size() - 1], 1.0, "low cover: crouched")
	assert_eq(routed_up[routed_up.size() - 1], 1.0, "low cover: still crouched after a second press")
	# Overhang (as tests/test_cover_crouch.gd:281-289): standing is refused on both paths.
	await _blend(true)
	_add_box(root, Vector3(0, 1.45, 0.5), Vector3(1.5, 0.2, 1.0), true)
	for i in 2:
		await _tick()
	assert_true(not bool(local.cover._facts.get("stand_clear", true)), "overhang blocks standing")
	assert_true(_tap_crouch(), "routed: still crouched at press (the press is ignored in cover)")
	for i in 20:
		await _tick()
	assert_true(local.cover.crouched and local.cover.crouch_amount == 1.0, "routed: still crouched under overhang")
	local.cover.toggle_crouch()
	for i in 20:
		await _tick()
	assert_true(local.cover.crouched and local.cover.crouch_amount == 1.0, "direct: still crouched under overhang")
	await _end_match()
