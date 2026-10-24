extends "res://tests/test_case.gd"
## P0 Fold touch regression: look drag and every action button through the real-device input path
## (window pixels -> Viewport.push_input(e, false) -> stretch transform), at both Fold sizes, mirroring the
## move-stick window-coord tests in test_touch_controls.gd. Also pins the P0 contrast and pawn-visibility data.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")

const SIZES: Array[Vector2i] = [Vector2i(2520, 1080), Vector2i(2176, 1812)]
const OLD_BUTTON_IDLE_ALPHA := 0.22
const OLD_RING_ALPHA := 0.35


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame


## Real-device order: canvas position -> window pixels, delivered with push_input(..., false).
func _deliver_window(e: InputEvent) -> void:
	var xf := _root().get_screen_transform()
	e.position = xf * e.position
	if e is InputEventScreenDrag:
		e.relative = xf.basis_xform(e.relative)
	_root().push_input(e, false)


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	_deliver_window(e)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_deliver_window(e)


func _setup(size: Vector2i, stick_mode: String = "virtual") -> Dictionary:
	_TouchHud.move_stick_override = stick_mode
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.begin()
	var prev := _root().size
	_root().size = size
	await _frames(25)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await _frames(3)
	return {"m": m, "touch": touch, "pawn": m.local_player, "prev": prev, "tag": str(size)}


func _teardown(ctx: Dictionary) -> void:
	(ctx["m"] as Node).queue_free()
	_root().size = ctx["prev"]
	await _frames(2)


func test_look_drag_window_coords_turns_pawn_folded_2520x1080() -> void:
	await _look_drag(SIZES[0])


func test_look_drag_window_coords_turns_pawn_unfolded_2176x1812() -> void:
	await _look_drag(SIZES[1])


func _look_drag(size: Vector2i) -> void:
	var ctx: Dictionary = await _setup(size)
	var touch: Control = ctx["touch"]
	var pawn: Pawn = ctx["pawn"]
	var start: Vector2 = touch._zone_hit_rect("look_zone").get_center()
	assert_eq(touch._button_at(start), "", "%s: look-zone centre is not on a button" % ctx["tag"])
	var yaw_before := pawn.rotation.y
	var pitch_before := pawn.pitch
	_touch(1, start, true)
	await _frames(1)
	assert_eq(touch._look_touch, 1, "%s: window-coord touch-down reached the look zone" % ctx["tag"])
	for k in range(1, 7):
		_drag(1, start + Vector2(30, 20) * k, Vector2(30, 20))
		await _frames(2)
	await _frames(10)
	var turned := absf(pawn.rotation.y - yaw_before) > 0.001
	var pitched := absf(pawn.pitch - pitch_before) > 0.001
	assert_true(turned and pitched, "%s: pawn yaw/pitch changed (yaw %s -> %s, pitch %s -> %s)" % [ctx["tag"], yaw_before, pawn.rotation.y, pitch_before, pawn.pitch])
	_touch(1, start, false)
	await _teardown(ctx)


func test_action_buttons_window_coords_folded_2520x1080() -> void:
	await _buttons(SIZES[0])


func test_action_buttons_window_coords_unfolded_2176x1812() -> void:
	await _buttons(SIZES[1])


func _buttons(size: Vector2i) -> void:
	var ctx: Dictionary = await _setup(size)
	var touch: Control = ctx["touch"]
	var pawn: Pawn = ctx["pawn"]
	var actions: Array = touch.get_button_actions()
	assert_true(actions.size() > 0, "%s: HUD has action buttons" % ctx["tag"])
	# Fire first: later buttons (swap, reload) change the weapon state its ammo check relies on.
	if actions.has("fire"):
		actions.erase("fire")
		actions.push_front("fire")
	for key in actions:
		var c: Vector2 = touch.get_button_rect(key).get_center()
		assert_eq(touch._button_at(c), key, "%s: %s centre hit-tests to itself" % [ctx["tag"], key])
		var act: String = touch._action_of(key)
		var ammo_before: int = pawn.loadout.get_active().ammo_in_mag
		_touch(1, c, true)
		await _frames(2)
		assert_true(Input.is_action_pressed(act), "%s: %s press drives InputMap action '%s'" % [ctx["tag"], key, act])
		if act == "fire":
			assert_true(pawn.loadout.get_active().ammo_in_mag < ammo_before, "%s: fire spent ammo" % ctx["tag"])
		elif act == "jump":
			assert_true(pawn.velocity.y > 0.0, "%s: jump lifted the pawn" % ctx["tag"])
		elif act == "aim":
			await _frames(20)
			assert_true(pawn.aiming, "%s: aim engaged" % ctx["tag"])
		_touch(1, c, false)
		await _frames(2)
		assert_true(not Input.is_action_pressed(act), "%s: %s release frees '%s'" % [ctx["tag"], key, act])
		await _frames(15)
	await _teardown(ctx)


## P0b: the same hit-tests with the HUD NOT at the viewport origin. Every expected touch point is built from
## the known offset plus HUD-space layout (zone rect, child Button node rects), never from the get_*_rect /
## _zone_hit_rect helpers, so a hit rect that forgets global_position cannot agree with the test.
func test_offset_hud_look_and_buttons_folded_2520x1080() -> void:
	await _offset_look_buttons(SIZES[0])


func test_offset_hud_look_and_buttons_unfolded_2176x1812() -> void:
	await _offset_look_buttons(SIZES[1])


func _offset_look_buttons(size: Vector2i) -> void:
	var ctx: Dictionary = await _setup(size)
	var touch: Control = ctx["touch"]
	var tag: String = ctx["tag"]
	# Shift left by more than any button is wide: a hit rect left in HUD space then misses the shifted button.
	var d := 0.0
	for key in touch.get_button_actions():
		d = maxf(d, (touch._buttons[key] as Button).size.x)
	var offset := Vector2(-(d + 20.0), 0.0)
	touch.position = offset
	await _frames(2)
	assert_true(touch.global_position != Vector2.ZERO and touch.global_position.is_equal_approx(offset), "%s: HUD sits at a non-zero offset %s" % [tag, touch.global_position])
	var canvas := touch.get_viewport_rect()
	# Look zone: just inside its (shifted) left edge, which is outside the unshifted look zone.
	var zone: Rect2 = touch._zone_rect("look_zone")
	var pt := offset + zone.position + Vector2(2.0, zone.size.y * 0.5)
	for key in touch.get_button_actions():
		assert_true(not (touch._buttons[key] as Button).get_global_rect().has_point(pt), "%s: look point is not on %s" % [tag, key])
	_touch(1, pt, true)
	await _frames(1)
	assert_eq(touch._look_touch, 1, "%s: window touch at the shifted look-zone edge reaches look (offset %s)" % [tag, offset])
	_touch(1, pt, false)
	await _frames(2)
	# Buttons: the centre of each child Button node (engine global rect), pressed through the window path.
	for key in touch.get_button_actions():
		var c: Vector2 = (touch._buttons[key] as Button).get_global_rect().get_center()
		assert_true(canvas.has_point(c), "%s: %s centre %s is on screen" % [tag, key, c])
		var act: String = touch._action_of(key)
		_touch(1, c, true)
		await _frames(2)
		assert_eq(touch._button_at(c), key, "%s: %s node centre hit-tests to itself at offset %s" % [tag, key, offset])
		assert_true(Input.is_action_pressed(act), "%s: %s press at the shifted node centre drives '%s'" % [tag, key, act])
		_touch(1, c, false)
		await _frames(2)
		assert_true(not Input.is_action_pressed(act), "%s: %s release frees '%s'" % [tag, key, act])
	await _teardown(ctx)


func test_offset_hud_lock_target_and_button_folded_2520x1080() -> void:
	await _offset_lock(SIZES[0])


func test_offset_hud_lock_target_and_button_unfolded_2176x1812() -> void:
	await _offset_lock(SIZES[1])


func _offset_lock(size: Vector2i) -> void:
	var ctx: Dictionary = await _setup(size, "custom")
	var touch: Control = ctx["touch"]
	var tag: String = ctx["tag"]
	# Shift up by more than the lock button / target are tall, so a double shift or a missing shift misses.
	var e: float = maxf(touch._lock_side("lock_button"), touch._lock_side("lock_target")) + 20.0
	var offset := Vector2(0.0, -e)
	touch.position = offset
	await _frames(2)
	assert_true(touch.global_position.is_equal_approx(offset), "%s: HUD sits at a non-zero offset %s" % [tag, touch.global_position])
	var canvas := touch.get_viewport_rect()
	var rad: float = touch._radius()
	var start: Vector2 = offset + touch.get_move_rest()
	# Release on the lock target: its centre is built in HUD space from the finger origin, then shifted once.
	_touch(0, start, true)
	await _frames(1)
	assert_eq(touch._move_touch, 0, "%s: window touch at the shifted move rest grabs the move stick" % tag)
	var s: float = touch._lock_side("lock_target")
	var c: Vector2 = (start - offset) - Vector2(0.0, float(touch.cfg["sprint"]["lock_target"]["distance_radii"]) * rad)
	c = c.clamp(Vector2.ONE * s * 0.5, touch.size - Vector2.ONE * s * 0.5)
	var target_pt := c + offset
	assert_true(canvas.has_point(target_pt), "%s: lock target centre %s is on screen" % [tag, target_pt])
	_drag(0, start + Vector2(0.0, -rad), Vector2(0.0, -rad))
	await _frames(3)
	assert_true(touch.provider.lock_target_visible(), "%s: lock target shown past the trigger" % tag)
	_drag(0, target_pt, target_pt - start - Vector2(0.0, -rad))
	await _frames(3)
	_touch(0, target_pt, false)
	await _frames(2)
	assert_true(touch.provider.sprint_locked, "%s: release on the shifted lock target locks (offset %s)" % [tag, offset])
	# Tap the stick: cancels the lock.
	_touch(0, start, true)
	await _frames(1)
	_touch(0, start, false)
	await _frames(2)
	assert_true(not touch.provider.sprint_locked, "%s: new move touch cancels the lock" % tag)
	# Lock button: while pushed forward, a touch at its HUD-space centre plus the offset toggles the lock.
	var button_pt: Vector2 = offset + touch._lock_button_center()
	assert_true(canvas.has_point(button_pt), "%s: lock button centre %s is on screen" % [tag, button_pt])
	_touch(0, start, true)
	await _frames(1)
	_drag(0, start + Vector2(0.0, -rad), Vector2(0.0, -rad))
	await _frames(3)
	_touch(1, button_pt, true)
	await _frames(2)
	assert_eq(touch._lock_btn_touch, 1, "%s: touch at the shifted lock button centre reaches it (offset %s)" % [tag, offset])
	assert_true(touch.provider.sprint_locked, "%s: lock button press locks sprint" % tag)
	_touch(1, button_pt, false)
	_touch(0, start + Vector2(0.0, -rad), false)
	await _frames(2)
	_TouchHud.move_stick_override = ""
	await _teardown(ctx)


## P0 contrast: idle button fill and stick ring must stay above the faint pre-P0 values (data, no fallbacks).
func test_contrast_data_above_pre_p0_values() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var hud: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	tree.root.add_child(hud)
	var layout: Dictionary = hud.cfg["touch_layout"]
	assert_true(float(layout["button_idle_alpha"]) > OLD_BUTTON_IDLE_ALPHA, "button idle alpha > 0.22")
	assert_true(float(layout["ring_alpha"]) > OLD_RING_ALPHA, "stick ring alpha > 0.35")
	assert_true(float(layout["button_held_alpha"]) > float(layout["button_idle_alpha"]), "held brighter than idle")
	var b: Button = hud._buttons[hud.get_button_actions()[0]]
	var sb: StyleBoxFlat = b.get_theme_stylebox("normal")
	assert_true(sb.bg_color.a > OLD_BUTTON_IDLE_ALPHA, "styled idle button fill alpha %s > 0.22" % sb.bg_color.a)
	assert_true(hud.look_stick.ring_alpha > OLD_RING_ALPHA, "styled look ring alpha %s > 0.35" % hud.look_stick.ring_alpha)
	hud.free()


## P0 pawn visibility: Body and HeadMesh carry a material_override.
func test_pawn_meshes_have_material_override() -> void:
	var pawn: Node = load("res://scenes/player/pawn.tscn").instantiate()
	for path in ["Body", "Head/HeadMesh"]:
		var mi := pawn.get_node(path) as MeshInstance3D
		assert_true(mi != null and mi.material_override != null, "%s has a material_override" % path)
	pawn.free()
