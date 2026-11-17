extends "res://tests/test_case.gd"
## M2 H1c item 4 (OQ-CROUCH): the free crouch and the radar rule. A Crouch press (the touch Crouch button through
## provider.trigger_action, or a keyboard / gamepad "crouch" key) reaches Pawn.handle_action_press through the router and
## MatchRoot and toggles Pawn.free_crouch; the physics tick never toggles from the InputFrame crouch bit. Crouched: the
## capsule and the head hitbox lower to data/cover.json crouch_height_m / crouch_head_y_m, the first-person eye and the
## muzzle by the same scale as the head, move speed by stats.json movement.crouch.speed_multiplier. Sprint and jump stand
## up first (a jump press only stands); standing needs CoverProbe.standing_clear. Cleared on the carrier, falling, downed,
## dead, on a ladder, in cover and at respawn. Offline only (not in a LAN session). The radar hides an enemy whose
## Pawn.crouch_amount() reaches radar.cover_crouch_min. The real match (match.tscn) drives the local pawn by manual ticks
## fed by the real router, as tests/test_crouch_action_d1.gd does.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _TouchScene := preload("res://scenes/ui/touch_hud.tscn")
const _PauseScene := preload("res://scenes/ui/pause_menu.tscn")
const _H1a := preload("res://tests/test_h1a_layout.gd")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const DT := 1.0 / 60.0
const TMP := "user://test_h1c_crouch_profile.json"

var m: MatchRoot
var local: Pawn
var touch: Control
var _old_size: Vector2i
var _old_profile: Dictionary
var _floor: Node3D


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


# ---- fixture --------------------------------------------------------------------------------------------------------

func _begin_match() -> void:
	_old_size = _tree().root.size
	_old_profile = AppFlow.profile
	AppFlow.profile = {}
	_tree().root.size = Vector2i(1512, 648)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.fill_bots = false
	m.bake_navmesh = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	assert_true(m.begin(), "real match begins")
	await _frames(2)
	local = m.local_player
	local.set_physics_process(false)
	touch = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	m.router.set_physics_process(false)  # the test's update_frame() calls are the only consumers of the router latch
	touch.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	touch.size = Vector2(1512, 648)
	touch.relayout()
	# A flat floor far from the map; the pawn stands on it facing -z.
	_floor = Node3D.new()
	_floor.position = Vector3(1000, 0, 0)
	m.add_child(_floor)
	_add_box(_floor, Vector3(0, -0.1, 0), Vector3(40, 0.2, 40), false)
	local.global_position = _floor.position
	local.rotation = Vector3.ZERO
	local.pitch = 0.0
	local.velocity = Vector3.ZERO
	local.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	for i in 10:
		await _tick()


func _end_match() -> void:
	m.queue_free()
	_tree().root.size = _old_size
	AppFlow.profile = _old_profile
	await _frames(2)


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


## One manual tick fed by the real router frame. opts: sprint, jump, crouch_bit (sets the frame's crouch bits only).
func _tick(move: Vector2 = Vector2.ZERO, opts: Dictionary = {}) -> InputFrame:
	var f := m.router.update_frame(DT)
	f.move = move
	f.sprint = bool(opts.get("sprint", false))
	if opts.get("jump", false):
		f.set_button("jump", true, true)
	if opts.get("crouch_bit", false):
		f.set_button("crouch", true, true)
	local.set_frame(f)
	local._physics_process(DT)
	await _tree().physics_frame
	return f


func _ticks(n: int, move: Vector2 = Vector2.ZERO, opts: Dictionary = {}) -> void:
	for i in n:
		await _tick(move, opts)


func _settle() -> void:
	await _ticks(ceili(_blend_s() / DT) + 3)


func _crouch_cfg() -> Dictionary:
	return DataRegistry.new().get_movement_cfg()["crouch"]


func _blend_s() -> float:
	return float(_crouch_cfg()["blend_s"])


func _cover_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")


func _capsule(p: Pawn) -> CapsuleShape3D:
	return (p.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D


func _head_y(p: Pawn) -> float:
	return (p.get_node("Head") as Node3D).position.y


func _near(a: float, b: float, eps: float = 1e-3) -> bool:
	return absf(a - b) <= eps


# ---- data -----------------------------------------------------------------------------------------------------------

func test_data_block_is_a_placeholder_with_its_oq() -> void:
	var c := _crouch_cfg()
	assert_true(bool(c["_placeholder"]), "movement.crouch is a placeholder")
	assert_true(str(c["_todo"]).contains("OQ-CROUCH"), "names OQ-CROUCH")
	assert_eq(c["enabled"], true, "the switch ships on")
	assert_eq(float(c["spread_multiplier"]), 1.0, "spread bonus ships at 1.0 (no effect)")
	assert_true(float(c["speed_multiplier"]) > 0.0 and float(c["speed_multiplier"]) < 1.0, "crouched is slower")
	assert_true(float(c["blend_s"]) > 0.0, "an ease time")
	var b: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]["buttons"]["crouch"]
	assert_true(str(b["_todo"]).contains("OQ-CROUCH") and bool(b["ring"]), "the Crouch button is a ring button with its OQ")


# ---- the press, the shapes, the eye and the muzzle ------------------------------------------------------------------

func test_press_toggles_and_shapes_eye_muzzle_and_head_move_together() -> void:
	await _begin_match()
	var cov := _cover_cfg()
	var stand_h := local.cover_standing_height()
	var stand_head := local.cover_standing_head_y()
	var ratio := float(cov["crouch_head_y_m"]) / stand_head
	var eye := float(DataRegistry.new().load_file("res://data/camera.json")["first_person"]["eye_height_m"]["value"])
	var muzzle := float(DataRegistry.new().get_movement_cfg()["muzzle_height_m"])
	var rig := local.get_node("CameraRig") as CameraRig
	assert_true(rig.is_first_person(), "fixture: first person")
	# Standing: crouch_amount 0, scale 1.
	assert_eq(local.crouch_amount(), 0.0, "standing: crouch_amount 0")
	assert_true(_near(_capsule(local).height, stand_h) and _near(_head_y(local), stand_head), "standing shapes")
	assert_true(_near(local.get_muzzle_position().y - local.global_position.y, muzzle), "standing muzzle at muzzle_height_m")
	assert_true(_near(rig.position.y, eye), "standing eye at eye_height_m (%.3f)" % rig.position.y)
	# One press: crouched at once (the toggle), eased down over blend_s.
	local.handle_action_press("crouch")
	assert_true(local.free_crouch, "a press crouches")
	await _tick()
	assert_true(local.crouch_amount() > 0.0 and local.crouch_amount() < 1.0, "eases (%.3f after one tick)" % local.crouch_amount())
	await _settle()
	assert_eq(local.crouch_amount(), 1.0, "fully crouched after blend_s")
	assert_true(_near(_capsule(local).height, maxf(float(cov["crouch_height_m"]), _capsule(local).radius * 2.0)), "capsule at crouch_height_m")
	assert_true(_near(_head_y(local), float(cov["crouch_head_y_m"])), "head at crouch_head_y_m")
	assert_true(_near(local.get_muzzle_position().y - local.global_position.y, muzzle * ratio), "muzzle scaled with the head")
	await _tree().physics_frame
	assert_true(_near(rig.position.y, eye * ratio), "eye scaled with the head (%.3f vs %.3f)" % [rig.position.y, eye * ratio])
	assert_true(_near(local.crouch_height_scale(), ratio), "crouch_height_scale is the head ratio")
	# Second press: stands (nothing overhead).
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "a second press stands up")
	await _settle()
	assert_eq(local.crouch_amount(), 0.0, "standing again")
	assert_true(_near(_capsule(local).height, stand_h) and _near(_head_y(local), stand_head), "standing shapes back")
	assert_true(_near(local.get_muzzle_position().y - local.global_position.y, muzzle), "muzzle back")
	await _tree().physics_frame
	assert_true(_near(rig.position.y, eye), "eye back")
	await _end_match()


func test_frame_crouch_bit_alone_never_toggles() -> void:
	await _begin_match()
	for i in 10:
		await _tick(Vector2.ZERO, {"crouch_bit": true})
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "the InputFrame crouch bit does nothing in the tick")
	await _end_match()


func test_speed_drops_by_the_data_multiplier() -> void:
	await _begin_match()
	var mult := float(_crouch_cfg()["speed_multiplier"])
	var move := Vector2(0, -0.6)
	await _ticks(20, move)
	var a := local.global_position
	await _ticks(30, move)
	var standing := (local.global_position - a).length()
	local.handle_action_press("crouch")
	await _ticks(20, move)
	assert_eq(local.crouch_amount(), 1.0, "fixture: fully crouched")
	var b := local.global_position
	await _ticks(30, move)
	var crouched := (local.global_position - b).length()
	assert_true(standing > 1.0, "fixture: the pawn walked (%.3f m)" % standing)
	assert_true(_near(crouched / standing, mult, 0.02), "crouched distance / standing = %.3f, data %.3f" % [crouched / standing, mult])
	await _end_match()


# ---- sprint, jump, the overhang -------------------------------------------------------------------------------------

func test_sprint_stands_up_then_sprints_and_a_crouch_press_while_sprinting_is_ignored() -> void:
	await _begin_match()
	local.handle_action_press("crouch")
	await _settle()
	await _tick(Vector2(0, -1), {"sprint": true})
	assert_true(not local.free_crouch, "a sprint while crouched stands up")
	await _ticks(30, Vector2(0, -1), {"sprint": true})
	assert_true(local.sprint_factor > 1.0, "then sprints (factor %.3f)" % local.sprint_factor)
	# Sprinting (the Sprint lock gives the same frame bit): a Crouch press is ignored.
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "a crouch press while sprinting is ignored")
	await _end_match()


func test_jump_while_crouched_only_stands_up() -> void:
	await _begin_match()
	var jump_v := float(DataRegistry.new().get_movement_cfg()["jump_velocity"])
	local.handle_action_press("crouch")
	await _settle()
	assert_true(local.is_on_floor(), "fixture: on the floor")
	await _tick(Vector2.ZERO, {"jump": true})
	assert_true(not local.free_crouch, "the jump press stands up")
	assert_true(local.velocity.y < jump_v * 0.5, "and does not jump (vy %.2f)" % local.velocity.y)
	await _settle()
	await _tick(Vector2.ZERO, {"jump": true})
	assert_true(local.velocity.y > jump_v * 0.5, "the next jump press jumps (vy %.2f)" % local.velocity.y)
	await _end_match()


func test_overhang_blocks_standing_for_the_press_sprint_and_jump() -> void:
	await _begin_match()
	local.handle_action_press("crouch")
	await _settle()
	# A ceiling the crouched shapes fit under and the standing capsule does not (bottom at 1.25 m).
	var ceiling := _add_box(_floor, Vector3(0, 1.35, 0), Vector3(8, 0.2, 8), false)
	await _ticks(2)
	assert_true(not local._cover_probe.standing_clear(local), "fixture: standing is blocked")
	local.handle_action_press("crouch")
	assert_true(local.free_crouch, "un-crouch press under the overhang: stays crouched")
	await _tick(Vector2(0, -1), {"sprint": true})
	assert_true(local.free_crouch, "sprint under the overhang: stays crouched")
	await _ticks(5, Vector2(0, -1), {"sprint": true})
	assert_true(local.free_crouch and local.sprint_factor == 1.0, "and no sprint (factor %.3f)" % local.sprint_factor)
	await _ticks(3)
	await _tick(Vector2.ZERO, {"jump": true})
	assert_true(local.free_crouch and local.velocity.y <= 0.0, "jump under the overhang: stays crouched, no jump")
	assert_eq(local.crouch_amount(), 1.0, "still fully crouched")
	ceiling.free()
	await _ticks(2)
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "out from under it: the press stands up")
	await _end_match()


# ---- other states ---------------------------------------------------------------------------------------------------

func test_downed_then_revived_stands_and_death_clears() -> void:
	await _begin_match()
	var stand_h := local.cover_standing_height()
	local.handle_action_press("crouch")
	await _settle()
	local.life = Pawn.Life.DOWNED
	assert_true(not local.free_crouch and local.free_crouch_amount == 0.0, "downed clears the free crouch")
	if local.downed_body_height_m > 0.0:
		assert_true(_near(_capsule(local).height, maxf(local.downed_body_height_m, _capsule(local).radius * 2.0)), "downed shapes win")
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "downed: a press is ignored")
	local.life = Pawn.Life.ALIVE
	assert_true(_near(_capsule(local).height, stand_h), "revived: standing")
	assert_eq(local.crouch_amount(), 0.0, "revived: crouch_amount 0")
	local.handle_action_press("crouch")
	await _settle()
	local.life = Pawn.Life.DEAD
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "death clears it")
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "dead: a press is ignored")
	# A new life (respawn, as a new match places the pawn) starts standing.
	local.respawn_at(Transform3D(Basis(), _floor.position))
	assert_true(not local.free_crouch and _near(_capsule(local).height, stand_h), "respawn: standing")
	local.handle_action_press("crouch")
	await _settle()
	local.respawn_at(Transform3D(Basis(), _floor.position))
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "respawn while crouched: reset")
	assert_true(_near(_capsule(local).height, stand_h), "respawn while crouched: standing shapes")
	await _end_match()


func test_carrier_fall_and_ladder_clear_and_ignore() -> void:
	await _begin_match()
	# Carrier.
	local.handle_action_press("crouch")
	await _settle()
	local.board_carrier()
	await _tick()
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "carrier: cleared")
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "carrier: a press is ignored")
	# Falling.
	local.start_fall(_floor.position + Vector3(0, 50, 0))
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "falling: a press is ignored")
	local.drop_state = Pawn.Drop.NONE
	local.global_position = _floor.position
	local.velocity = Vector3.ZERO
	await _ticks(5)
	# Ladder (the plain climbing state).
	local.handle_action_press("crouch")
	await _settle()
	local.climbing = true
	local.handle_action_press("crouch")
	assert_true(local.free_crouch, "fixture: the press on the ladder did not stand either")
	await _tick()
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "ladder: cleared")
	local.climbing = true
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "ladder: a press is ignored")
	local.climbing = false
	await _end_match()


func test_entering_cover_while_crouched_cover_owns_it_and_leaving_stands() -> void:
	await _begin_match()
	# A LOW 1.1 m cover wall whose face is 1.1 m ahead (cover crouches behind it).
	_add_box(_floor, Vector3(0, 0.55, -1.6), Vector3(4, 1.1, 1), true)
	await _ticks(2)
	local.handle_action_press("crouch")
	await _settle()
	assert_true(local.cover_button_valid(), "fixture: the Cover button would enter")
	local.handle_action_press("cover")
	await _tick()
	assert_true(local.in_cover(), "in cover")
	assert_true(not local.free_crouch, "entering cover clears the free crouch")
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "in cover a Crouch press is ignored (cover owns the crouch)")
	await _ticks(30)
	assert_eq(local.cover.state, CoverController.State.IN_COVER, "fixture: settled in cover")
	assert_eq(local.free_crouch_amount, 0.0, "the free crouch has eased out")
	assert_eq(local.crouch_amount(), local.cover.crouch_amount, "crouch_amount() is the cover crouch")
	assert_true(local.cover.crouch_amount > 0.5, "behind low cover: crouched by cover")
	assert_true(_near(local.get_muzzle_position().y - local.global_position.y, float(DataRegistry.new().get_movement_cfg()["muzzle_height_m"])), "in cover the muzzle is cover's (unchanged)")
	local.cover.request_exit()
	await _ticks(40)
	assert_true(not local.in_cover(), "left cover")
	assert_true(not local.free_crouch and local.crouch_amount() == 0.0, "after leaving cover: standing")
	assert_true(_near(_capsule(local).height, local.cover_standing_height()), "standing shapes")
	await _end_match()


# ---- the press path, keyboard / gamepad, the switch -----------------------------------------------------------------

func test_touch_button_press_reaches_the_pawn_through_the_router() -> void:
	await _begin_match()
	await _frames(2)
	assert_true(touch.get_button_actions().has("crouch"), "the HUD has the Crouch button")
	var b: Button = touch._buttons["crouch"]
	assert_true(b.visible and touch.crouch_button_shown(), "shown offline")
	var c: Vector2 = touch.get_button_rect("crouch").get_center()
	assert_eq(touch._button_at(c), "crouch", "its centre hit-tests to itself")
	var got: Array = []
	m.router.action_triggered.connect(func(a: String) -> void: got.append(a))
	touch._on_down(7, c)
	assert_true(got.has("crouch"), "the router re-emits crouch at press time")
	assert_true(local.free_crouch, "provider.trigger_action -> router -> MatchRoot -> Pawn.handle_action_press crouched")
	assert_true(Input.is_action_pressed("crouch"), "and holds the InputMap action like every button")
	touch._on_up(7)
	assert_true(not Input.is_action_pressed("crouch"), "released")
	await _tick()
	await _frames(1)
	assert_eq(touch.crouch_look, "held", "held look while crouched")
	var sb := b.get_theme_stylebox("normal") as StyleBoxFlat
	assert_true(_near(sb.bg_color.a, float(touch._layout["button_held_alpha"])), "the held fill")
	touch._on_down(7, c)
	touch._on_up(7)
	assert_true(not local.free_crouch, "a second tap stands")
	await _tick()
	await _frames(1)
	assert_eq(touch.crouch_look, "normal", "normal look standing")
	await _end_match()


func test_keyboard_and_gamepad_crouch_take_the_same_path() -> void:
	await _begin_match()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_C
	key.pressed = true
	m.router._input(key)
	assert_true(local.free_crouch, "C crouches (KeyboardMouseProvider -> router -> Pawn.handle_action_press)")
	var echo := key.duplicate() as InputEventKey
	echo.echo = true
	m.router._input(echo)
	assert_true(local.free_crouch, "a key echo is not a second press")
	var up := key.duplicate() as InputEventKey
	up.pressed = false
	m.router._input(up)
	assert_true(local.free_crouch, "the release does nothing")
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_B
	pad.pressed = true
	m.router._input(pad)
	assert_true(not local.free_crouch, "gamepad B toggles back")
	await _end_match()


func test_switch_off_press_does_nothing_and_button_hidden() -> void:
	await _begin_match()
	(local._movement["crouch"] as Dictionary)["enabled"] = false
	await _frames(2)
	local.handle_action_press("crouch")
	assert_true(not local.free_crouch, "switch off: the press does nothing")
	assert_true(not touch.crouch_button_shown() and not (touch._buttons["crouch"] as Button).visible, "switch off: hidden")
	var c: Vector2 = touch.get_button_rect("crouch").get_center()
	assert_true(touch._button_at(c) != "crouch", "a hidden button catches nothing")
	(local._movement["crouch"] as Dictionary)["enabled"] = true
	# The data switch itself (no pawn needed): off hides it on any HUD.
	touch._crouch_data_on = false
	assert_true(not touch.crouch_button_shown(), "data switch off: hidden")
	touch._crouch_data_on = true
	await _end_match()


func test_button_dimmed_in_cover_and_on_the_carrier() -> void:
	await _begin_match()
	_add_box(_floor, Vector3(0, 0.55, -1.6), Vector3(4, 1.1, 1), true)
	await _ticks(2)
	local.handle_action_press("cover")
	await _ticks(5)
	assert_true(local.in_cover(), "fixture: in cover")
	await _frames(1)
	assert_eq(touch.crouch_look, "dimmed", "dimmed in cover (a press does nothing there)")
	var b: Button = touch._buttons["crouch"]
	var dim: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["cover_fire_dim"]
	assert_true(_near((b.get_theme_stylebox("normal") as StyleBoxFlat).bg_color.a, float(dim["bg_alpha"])), "the cover_fire_dim style")
	assert_true(b.visible, "still shown")
	local.cover.reset()
	await _tick()
	await _frames(1)
	assert_eq(touch.crouch_look, "normal", "normal out of cover")
	local.board_carrier()
	await _frames(1)
	assert_eq(touch.crouch_look, "dimmed", "dimmed on the carrier")
	await _end_match()


# ---- LAN ------------------------------------------------------------------------------------------------------------

func test_lan_session_press_ignored_and_button_hidden() -> void:
	var s := NetSession.new()
	s.name = "TH1cCrouchHost"
	s.isolated = true
	_tree().root.add_child(s)
	assert_eq(s.host_game(), OK, "host_game")
	s.lobby.host_open(2, 3, "Host")
	assert_true(s.lobby.state.add_human(2, "Client"), "a second human joins the lobby")
	assert_true(s.lobby.start_match(), "host lobby starts")
	var mm: MatchRoot = _MatchScene.instantiate()
	mm.auto_start = false
	mm.session_override = s
	mm.lobby_override = s.lobby.state
	mm.seed_override = 4242
	mm.fill_bots = false
	mm.bake_navmesh = false
	_tree().root.add_child(mm)
	await _tree().physics_frame
	assert_true(mm.begin(), "begin")
	await _frames(3)
	var pawn := mm.local_player
	assert_true(pawn.in_lan_session(), "a LAN session (a remote human)")
	pawn.handle_action_press("crouch")
	assert_true(not pawn.free_crouch, "LAN: the press is ignored")
	assert_true(not pawn.crouch_button_available(), "LAN: no Crouch button")
	var t: Control = mm.get_node("Hud/TouchHud")
	t.cfg["force_touch_hud"] = true
	t.refresh_visibility()
	await _frames(2)
	assert_true(not t.crouch_button_shown() and not (t._buttons["crouch"] as Button).visible, "LAN: the button is hidden")
	mm.queue_free()
	s.leave()
	s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _frames(2)


# ---- radar ----------------------------------------------------------------------------------------------------------

func _radar_pawn(squad: int, id: int, at: Vector3, floor_root: Node3D) -> Pawn:
	var p: Pawn = _PawnScene.instantiate()
	floor_root.add_child(p)
	p.set_physics_process(false)
	p.setup("hastati", squad)
	p.player_id = id
	p.global_position = at
	return p


func test_radar_hides_a_crouched_enemy_shows_a_standing_one_cover_crouch_still_hides() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	root.position = Vector3(-2000, 0, 0)
	_add_box(root, Vector3(0, -0.1, 0), Vector3(40, 0.2, 40), false)
	var me := Pawn.new()
	me.setup("hastati", 1)
	me.player_id = 0
	me.position = root.position
	var crouched := _radar_pawn(2, 1, root.position + Vector3(6, 0, -4), root)
	var standing := _radar_pawn(2, 2, root.position + Vector3(-6, 0, 4), root)
	var covered := _radar_pawn(3, 3, root.position + Vector3(4, 0, 8), root)
	await _tree().physics_frame
	assert_eq(HudRadar.classify(me, crouched), HudRadar.ENEMY, "standing: shows")
	# Crouched through the pawn API (the same entry the input layer uses), eased by its own physics ticks.
	crouched.handle_action_press("crouch")
	assert_true(crouched.free_crouch, "the second local pawn crouched")
	for i in ceili(_blend_s() / DT) + 3:
		crouched.set_frame(InputFrame.new())
		crouched._physics_process(DT)
		await _tree().physics_frame
	assert_eq(crouched.crouch_amount(), 1.0, "fixture: fully crouched")
	var min_c := float(HudArrangement.ui()["radar"]["cover_crouch_min"])
	assert_true(crouched.crouch_amount() >= min_c, "at least cover_crouch_min")
	assert_eq(HudRadar.classify(me, crouched), "", "a crouched enemy is off the radar")
	assert_true(HudRadar.in_cover_crouch(crouched), "in_cover_crouch reads Pawn.crouch_amount()")
	assert_eq(HudRadar.classify(me, standing), HudRadar.ENEMY, "a standing enemy still shows")
	# The cover crouch still hides (H1b case).
	covered.enable_cover(_cover_cfg())
	covered.cover.state = CoverController.State.IN_COVER
	covered.cover.crouch_amount = 1.0
	assert_eq(HudRadar.classify(me, covered), "", "the cover crouch still hides")
	covered.cover.crouch_amount = min_c - 0.01
	assert_eq(HudRadar.classify(me, covered), HudRadar.ENEMY, "below the threshold shows")
	# Standing up again: shows.
	crouched.handle_action_press("crouch")
	for i in ceili(_blend_s() / DT) + 3:
		crouched._physics_process(DT)
		await _tree().physics_frame
	assert_eq(HudRadar.classify(me, crouched), HudRadar.ENEMY, "stood up: shows again")
	me.free()
	root.queue_free()
	await _frames(1)


# ---- the button's place ---------------------------------------------------------------------------------------------

## The H1a rules for the Crouch button on all six sizes, both dpi, both HUD arrangements, both shooting modes, Left Fire
## on and off, the cover slot either way: >= 48 dp, on screen, out of the look area, clear of the move stick and of every
## other control; and clear of the GameHud feedback widgets (crosshair, cues, toast, banners).
func test_button_place_passes_the_h1a_rules_on_all_sizes() -> void:
	var h1a: RefCounted = _H1a.new()
	h1a._begin()
	for placement in [HudArrangement.ABOVE_ROW, HudArrangement.SPLIT_ROW]:
		HudArrangement.placement_override = placement
		for dpi in _H1a.DPIS:
			PlatformServices.dpi_override = dpi
			var dp := PlatformServices.new().get_dp_scale()
			for sz in SIZES:
				for lf in [false, true]:
					AppFlow.profile = {"left_fire_enabled": lf}
					var t: Control = h1a._new_touch(sz)
					var pm: PauseMenu = h1a._pause(sz)
					for cover in [false, true]:
						t.set_cover_slot(cover, cover, false)
						t.relayout()
						var tag := "%s %s dpi %d lf=%s cover=%s" % [placement, sz, dpi, lf, cover]
						var r: Rect2 = t.get_button_rect("crouch")
						# The right thumb's cluster: right of the screen centre, on Jump's row directly left of it.
						var jump: Rect2 = t.get_button_rect("jump")
						assert_true(r.get_center().x > 0.5 * sz.x, "%s: Crouch centre %.0f right of the screen centre" % [tag, r.get_center().x])
						assert_true(absf(r.get_center().y - jump.get_center().y) < 0.5 and r.end.x <= jump.position.x, "%s: Crouch %s on Jump's row, left of Jump %s" % [tag, r, jump])
						assert_true(r.size.x / dp >= 48.0 - 1e-3, "%s: Crouch %.1f dp >= 48" % [tag, r.size.x / dp])
						assert_true(Rect2(Vector2.ZERO, sz).encloses(r), "%s: Crouch %s on screen" % [tag, r])
						assert_true(not r.intersects(t.get_look_area_rect()), "%s: Crouch %s out of the look area" % [tag, r])
						assert_true(not r.intersects(t.get_move_visual_rect()), "%s: Crouch clear of the move stick" % tag)
						for expanded in [false, true]:
							var ctrls: Dictionary = h1a._controls(t, pm, sz, expanded)
							for key in ctrls:
								if key != "crouch":
									assert_true(not r.intersects(ctrls[key]), "%s: Crouch %s clear of %s %s" % [tag, r, key, ctrls[key]])
					pm.free()
					t.free()
	HudArrangement.placement_override = ""
	h1a._end()
	AppFlow.profile = {}


func test_button_clear_of_the_feedback_widgets() -> void:
	for sz in [Vector2(1512, 648), Vector2(2520, 1080), Vector2(1152, 959), Vector2(2176, 1812)]:
		var t: Control = _TouchScene.instantiate()
		_tree().root.add_child(t)
		t.cfg["force_touch_hud"] = true
		t.refresh_visibility()
		t.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		t.size = sz
		t.relayout()
		var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
		_tree().root.add_child(game)
		game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		game.size = sz
		await _frames(1)
		game.show_cue("No reserve")
		game.show_toast("Gladius Rifle")
		game.show_hit_marker()
		game.show_banner("ZONE CLOSING")
		game.own_death_label.visible = true
		game.respawn_label.visible = true
		game.respawn_label.text = "Respawn in 5"
		game.reload_box.visible = true
		await _frames(2)
		var r: Rect2 = t.get_button_rect("crouch")
		for w: Control in [game.reload_box, game.cue_label, game.toast_label, game.hit_marker, game.crosshair, game.banner_label,
				game.own_death_label, game.respawn_label]:
			assert_true(not r.intersects(w.get_global_rect()), "%s: Crouch %s clear of %s %s" % [sz, r, w.name, w.get_global_rect()])
		game.free()
		t.free()


func test_old_saved_layout_without_crouch_loads_with_the_default() -> void:
	var saved := AppFlow.profile
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	# A current-format (version 3) layout with no crouch entry (entries for other keys only): it loads unchanged and the
	# Crouch button takes its default. (A version-2 layout is reset: test_layout_version_3_resets_a_version_2_layout_once.)
	var model := HudLayoutModel.new()
	model.set_pos(0, "reload", Vector2(0.9, 0.95))
	model.set_size_pct(0, "aim", 120.0)
	var save := SaveService.new(TMP)
	var prof := SaveService.defaults()
	prof["hud_layouts"] = model.to_dict()
	save.save_profile(prof)
	var p := save.load_profile()
	assert_true(not (p["hud_layouts"]["slots"][0] as Dictionary).has("crouch"), "the saved slot has no crouch entry")
	assert_eq(JSON.stringify(p["hud_layouts"]), JSON.stringify(model.to_dict()), "the layout loads unchanged (no reset)")
	AppFlow.profile = {}
	var plain: Control = _TouchScene.instantiate()
	_tree().root.add_child(plain)
	plain.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	plain.size = Vector2(2520, 1080)
	plain.relayout()
	var default_rect: Rect2 = plain.get_button_rect("crouch")
	plain.free()
	AppFlow.profile = p
	var t: Control = _TouchScene.instantiate()
	_tree().root.add_child(t)
	t.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	t.size = Vector2(2520, 1080)
	t.relayout()
	assert_true(t.get_element_keys().has("crouch"), "the Crouch button is an editable element")
	assert_eq(t.get_button_rect("crouch"), default_rect, "the Crouch button sits at its default")
	assert_true(t.get_button_rect("reload") != plain_reload_default(), "the saved Reload position still applies")
	t.free()
	AppFlow.profile = saved
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## The Crouch button moved defaults (Cover / Shoulder, Swap, fire mode), so layout_version is 3. A layout saved at 2 (the
## H1a / H1b format, with edits) is reset ONCE through SaveService / HudLayoutModel: every slot back to the defaults,
## written back at 3, the one-time notice pending; the next load leaves it alone; the HUD then shows the new defaults.
func test_layout_version_3_resets_a_version_2_layout_once() -> void:
	var saved := AppFlow.profile
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	assert_eq(HudLayoutModel.current_version(), 3, "layout_version 3 (was 2)")
	var prof := SaveService.defaults()
	prof["gamertag"] = "OldTwo"
	prof["hud_layouts"] = {"version": 2, "active": 1, "slots": [{"swap_shoulder": {"pos": [0.55, 0.9]}},
		{"jump": {"pos": [0.7, 0.9], "size_pct": 120.0}}, {}]}
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify(prof))
	f.close()
	var save := SaveService.new(TMP)
	var p := save.load_profile()
	assert_eq(int(p["hud_layouts"]["version"]), 3, "loaded at version 3")
	for slot in p["hud_layouts"]["slots"]:
		assert_true((slot as Dictionary).is_empty(), "every slot back to the defaults")
	assert_true(bool(p["layout_notice_pending"]), "the one-time layout notice is pending (edits were lost)")
	assert_eq(p["gamertag"], "OldTwo", "the rest of the profile survives")
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TMP))
	assert_eq(int(raw["hud_layouts"]["version"]), 3, "written back at once at version 3")
	# A new edit at version 3 survives the next load (no second reset).
	p["hud_layouts"]["slots"][0] = {"crouch": {"pos": [0.6, 0.9]}}
	p["layout_notice_pending"] = false
	save.save_profile(p)
	var again := save.load_profile()
	assert_eq(again["hud_layouts"]["slots"][0], {"crouch": {"pos": [0.6, 0.9]}}, "a version-3 layout loads unchanged")
	assert_true(not bool(again["layout_notice_pending"]), "no second notice")
	# The reset profile's HUD shows the new defaults (Crouch left of Jump, Cover / Shoulder left of the centre).
	p["hud_layouts"]["slots"][0] = {}
	AppFlow.profile = p
	var t: Control = _TouchScene.instantiate()
	_tree().root.add_child(t)
	t.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	t.size = Vector2(2176, 1812)
	t.relayout()
	assert_true(t.get_button_rect("crouch").end.x <= t.get_button_rect("jump").position.x, "Crouch left of Jump")
	assert_true(t.get_button_rect("crouch").get_center().x > 1088.0, "Crouch right of the centre")
	assert_true(t.get_button_rect("swap_shoulder").end.x <= t.get_button_rect("crouch").position.x, "the Cover slot left of Crouch")
	t.free()
	AppFlow.profile = saved
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func plain_reload_default() -> Rect2:
	var saved := AppFlow.profile
	AppFlow.profile = {}
	var t: Control = _TouchScene.instantiate()
	_tree().root.add_child(t)
	t.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	t.size = Vector2(2520, 1080)
	t.relayout()
	var r: Rect2 = t.get_button_rect("reload")
	t.free()
	AppFlow.profile = saved
	return r


func test_layout_editor_preview_shows_the_button() -> void:
	var ed: Control = load("res://scenes/ui/layout_editor.tscn").instantiate()
	ed.save = SaveService.new(TMP)
	_tree().root.add_child(ed)
	await _frames(1)
	assert_true(ed.preview.show_crouch_for_editing, "the preview sets the editing flag")
	assert_true(ed.preview.get_element_keys().has("crouch"), "the Crouch button is an editor element")
	assert_true((ed.preview._buttons["crouch"] as Button).visible, "and is drawn there")
	ed.free()
