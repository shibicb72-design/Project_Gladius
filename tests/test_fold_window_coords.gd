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


func _setup(size: Vector2i) -> Dictionary:
	_TouchHud.move_stick_override = "virtual"
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
