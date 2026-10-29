extends RefCounted
## Shared rig for the GBTN2 tests: the match with the touch HUD at a Fold size, tapped through Viewport.push_input
## (same path as tests/test_action_buttons.gd). Not a test file (no test_ prefix).

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

const SIZES: Array[Vector2i] = [Vector2i(2520, 1080), Vector2i(2176, 1812)]
const MODES: Array[String] = ["virtual", "custom"]
const BUTTON_TOUCH := 1


static func root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


static func frames(n: int) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for i in n:
		await tree.physics_frame
	await tree.process_frame
	await tree.process_frame


static func touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	root().push_input(e, true)


static func setup(size: Vector2i, mode: String) -> Dictionary:
	_TouchHud.move_stick_override = mode
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.begin()
	var prev := root().size
	root().size = size
	await frames(25)
	var t: Control = m.get_node("Hud/TouchHud")
	t.cfg["force_touch_hud"] = true
	t.refresh_visibility()
	await frames(3)
	return {"m": m, "touch": t, "pawn": m.local_player, "hud": m.hud, "prev": prev,
			"tag": "%s mode=%s" % [size, mode]}


static func teardown(ctx: Dictionary) -> void:
	(ctx["m"] as Node).queue_free()
	root().size = ctx["prev"]
	await frames(2)


static func press(ctx: Dictionary, action: String, pressed: bool) -> void:
	if action == "fire":
		if pressed:
			var point: Vector2 = ctx["touch"].get_element_rect("look_stick").get_center()
			touch(BUTTON_TOUCH, point, true)
			touch(BUTTON_TOUCH, point, false)
		return
	touch(BUTTON_TOUCH, (ctx["touch"] as Control).get_button_rect(action).get_center(), pressed)


## Adds an inert enemy-squad pawn `dist_m` along the shooter's aim (negative = behind it); returns it.
static func add_target(ctx: Dictionary, dist_m: float) -> Pawn:
	var m: MatchRoot = ctx["m"]
	var shooter: Pawn = ctx["pawn"]
	var target: Pawn = _PawnScene.instantiate()
	target.squad_id = shooter.squad_id + 1
	m.add_child(target)
	target.set_physics_process(false)
	var flat := shooter.get_aim_direction()
	flat.y = 0.0
	target.global_position = shooter.global_position + flat.normalized() * dist_m
	m.director.add_player(99, target)
	await frames(2)
	return target
