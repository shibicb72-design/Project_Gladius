extends "res://tests/test_case.gd"
## Step 3 (Shibi, Nov 9 2026): a right-side Fire button whose drag also aims, and swipe-look as the default.
## Real touches are pushed through the viewport at the button's on-screen centre (project UI test rule).

const _MatchScene := preload("res://scenes/match/match.tscn")
const _LookMath := preload("res://scripts/input/look_math.gd")

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame
		await tree().process_frame


func touch(idx: int, point: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.pressed = down
	e.position = tree().root.get_screen_transform() * point
	tree().root.push_input(e, false)


func drag(idx: int, point: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = tree().root.get_screen_transform() * point
	e.relative = rel
	tree().root.push_input(e, false)


func setup() -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 9090
	tree().root.add_child(m)
	await tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
		b.global_position = Vector3(60.0, 0.2, 60.0)  # out of the way
	var hud: Control = m.get_node("Hud/TouchHud")
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	await frames(3)


func cleanup() -> void:
	Input.action_release("fire")
	m.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile


func test_swipe_look_is_the_default() -> void:
	var cfg := DataRegistry.new().load_file("res://data/input.json")
	assert_eq(str(cfg["look"]["mode"]), "drag", "swipe-look (drag) is the default look mode")


func test_fire_button_fires_and_aims_with_the_same_touch() -> void:
	await setup()
	var hud: Control = m.get_node("Hud/TouchHud")
	assert_true(hud._buttons.has("fire_right"), "the right Fire button exists")
	var b: Button = hud._buttons["fire_right"]
	assert_true(b.visible, "it is visible")
	var c := b.get_global_rect().get_center()
	var me := m.local_player
	var shots := [0]
	me.fired.connect(func() -> void: shots[0] += 1)
	var yaw0 := me.rotation.y
	touch(5, c, true)
	await frames(2)
	assert_true(Input.is_action_pressed("fire"), "pressing the Fire button holds fire")
	for i in 8:
		drag(5, c + Vector2(25.0 * (i + 1), 0.0), Vector2(25.0, 0.0))
		await frames(1)
	assert_true(shots[0] > 0, "shots fired while held (%d)" % shots[0])
	assert_true(absf(wrapf(me.rotation.y - yaw0, -PI, PI)) > 0.05, "dragging the Fire button turned the view")
	touch(5, c + Vector2(200.0, 0.0), false)
	await frames(2)
	assert_true(not Input.is_action_pressed("fire"), "releasing it stops firing")
	await cleanup()


## Step 3 G4 (Shibi, Nov 9 2026: "real recoil you pull against"): holding Fire climbs the pawn's real pitch by
## recoil.pitch_deg per shot, and it stays up after the shots stop until the player pulls it down.
func test_recoil_climbs_the_real_aim_and_stays_until_pulled_down() -> void:
	await setup()
	var me := m.local_player
	var r: Dictionary = DataRegistry.new().load_file(DataRegistry.STATS_PATH)["weapons"][me.loadout.get_active().def.id]["recoil"]
	var shots := [0]
	me.fired.connect(func() -> void: shots[0] += 1)
	var pitch0 := me.pitch
	var aim0: Vector3 = me.get_node("CameraRig").get_aim_point([] as Array[RID])
	Input.action_press("fire")
	await frames(60)
	Input.action_release("fire")
	await frames(2)
	assert_true(shots[0] >= 3, "a burst or more fired (%d)" % shots[0])
	var want: float = deg_to_rad(float(r["pitch_deg"])) * shots[0]
	assert_true(absf((me.pitch - pitch0) - want) < 1e-4, "pitch climbed pitch_deg per shot (%.4f vs %.4f rad)" % [me.pitch - pitch0, want])
	var aim1: Vector3 = me.get_node("CameraRig").get_aim_point([] as Array[RID])
	assert_true(aim1.y > aim0.y, "the real aim point moved up (%s -> %s)" % [aim0, aim1])
	var held := me.pitch
	await frames(40)
	assert_true(absf(me.pitch - held) < 1e-6, "no automatic return: the aim stays up until the player pulls it down")
	await cleanup()


func test_every_gun_has_recoil_and_the_blade_has_none() -> void:
	var weapons: Dictionary = DataRegistry.new().load_file(DataRegistry.STATS_PATH)["weapons"]
	for id in weapons:
		var w: Dictionary = weapons[id]
		if str(w.get("kind", "")) == "melee":
			assert_true(not w.has("recoil"), "%s: melee has no recoil" % id)
		else:
			assert_true(w.has("recoil") and float(w["recoil"].get("pitch_deg", 0.0)) > 0.0, "%s: a gun climbs when fired" % id)


func test_a_fast_swipe_is_not_capped() -> void:
	var cfg := {"look": {"max_turn_rate_deg_s": 90.0, "drag_rad_per_screen_height": 3.14}}
	var cap: float = deg_to_rad(90.0) / _LookMath.tick_hz()
	var turn: Vector2 = _LookMath.drag_turn(Vector2(500.0, 0.0), 1000.0, cfg)
	assert_true(turn.x > cap * 2.0, "a big swipe in one tick turns more than the stick cap (%.3f vs %.3f)" % [turn.x, cap])
	assert_true(absf(turn.x - 1.57) < 1e-3, "half a screen height of travel = half of drag_rad_per_screen_height")
