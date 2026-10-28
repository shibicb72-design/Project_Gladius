extends "res://tests/test_case.gd"

const _Frame := preload("res://scripts/input/input_frame.gd")
const _Provider := preload("res://scripts/input/input_provider.gd")
const _Router := preload("res://scripts/input/input_router.gd")
const _KbProvider := preload("res://scripts/input/providers/keyboard_mouse_provider.gd")
const _Platform := preload("res://scripts/platform/platform_services.gd")

const ACTIONS := [
	"move_left", "move_right", "move_forward", "move_back",
	"look_left", "look_right", "look_up", "look_down",
	"fire", "aim", "reload", "swap_weapon", "jump", "pause",
]


class FakeProvider extends InputProvider:
	var mv := Vector2.ZERO
	var held := false

	func get_move() -> Vector2:
		return mv

	func is_pressed(_a: String) -> bool:
		return held


func test_actions_exist_in_inputmap() -> void:
	for a in ACTIONS:
		assert_true(InputMap.has_action(a), "missing action " + a)


func test_router_merges_providers() -> void:
	var r: InputRouter = _Router.new()
	var a := FakeProvider.new()
	var b := FakeProvider.new()
	a.mv = Vector2(1, 0)
	b.mv = Vector2(1, 1)
	r.add_provider(a)
	r.add_provider(b)
	var f: InputFrame = r.update_frame()
	assert_true(f.move.length() <= 1.0001, "move not clamped")
	assert_true(f.move.x > 0.0 and f.move.y > 0.0, "move not summed")
	r.free()


func test_action_press_reaches_frame() -> void:
	var r: InputRouter = _Router.new()
	r.add_provider(_KbProvider.new())
	Input.action_press("fire")
	var f: InputFrame = r.update_frame()
	assert_true(f.fire_pressed, "fire not pressed")
	assert_true(f.fire_just_pressed, "fire not just pressed")
	f = r.update_frame()
	assert_true(f.fire_pressed and not f.fire_just_pressed, "just_pressed should clear")
	Input.action_release("fire")
	r.free()


func test_input_frame_roundtrip_serialization() -> void:
	var f := InputFrame.new()
	f.move = Vector2(0.5, -0.25)
	f.look = Vector2(0.125, 1.0)
	f.set_button("jump", true, true)
	f.set_button("reload", true, false)
	var g: InputFrame = _Frame.from_array(f.to_array())
	assert_eq(g.move, f.move, "move")
	assert_eq(g.look, f.look, "look")
	assert_true(g.jump_pressed and g.jump_just_pressed, "jump")
	assert_true(g.reload_pressed and not g.reload_just_pressed, "reload")
	assert_true(not g.fire_pressed, "fire")


## Path A phase 2: LOCAL_BUTTONS (swap_shoulder) are this device's view only, so they never reach the host.
func test_local_buttons_stay_out_of_the_net_frame() -> void:
	var f := InputFrame.new()
	f.move = Vector2(0.5, -0.25)
	f.set_button("fire", true, true)
	var plain: Array = f.to_array()
	f.set_button("swap_shoulder", true, true)
	assert_true(f.swap_shoulder_pressed and f.swap_shoulder_just_pressed, "swap_shoulder is set on the local frame")
	assert_eq(f.to_array(), plain, "to_array() is the same with swap_shoulder pressed")
	var g: InputFrame = _Frame.from_array(f.to_array())
	assert_true(not g.swap_shoulder_pressed and not g.swap_shoulder_just_pressed, "from_array() gives swap_shoulder false")
	assert_true(g.fire_pressed and g.fire_just_pressed, "BUTTONS still round-trip")
	for action in InputFrame.LOCAL_BUTTONS:
		assert_true(not InputFrame.BUTTONS.has(action), "%s is not a net button" % action)


func test_touch_hud_scene_instantiates() -> void:
	var scene: PackedScene = load("res://scenes/ui/touch_hud.tscn")
	assert_true(scene != null, "scene failed to load")
	if scene == null:
		return
	var n: Node = scene.instantiate()
	assert_true(n is Control, "root not Control")
	n.free()


func test_platform_services_noop_on_headless() -> void:
	var p := _Platform.new()
	assert_true(not p.has_gyro(), "gyro on headless")
	assert_eq(p.get_gyro_rate(), Vector3.ZERO, "gyro rate")
	p.vibrate(10)
