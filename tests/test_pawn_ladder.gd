extends "res://tests/test_case.gd"
## M2 L1c commit 5: climbing a ladder (the "M2 L1c ladder" block of scripts/classes/pawn.gd, scripts/props/ladder.gd,
## data/props.json "ladder", OQ-PROPS-LADDER). Small fixtures with real physics and the real pawn scene: a real
## barracks body (WorldKit.build_body of the kit type, its end wall, eave and roof) with the ladder the generator puts
## on its +x end (tools/gen_alesia.gd ladder_spot), and a 3.3 m cover wall (group cover_wall) with a ladder flush on its
## face. Every pawn tick goes through set_frame and _physics_process (so the real _apply_movement and _apply_weapon
## paths run); a physics frame is awaited where the trigger's overlap must update.

const MAP := "res://data/maps/alesia_1km.json"
const Gen := preload("res://tools/gen_alesia.gd")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const DT := 1.0 / 60.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _ladder_cfg() -> Dictionary:
	return WorldProps.config()["ladder"]


func _box(parent: Node, at: Vector3, size: Vector3, cover := false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	if cover:
		body.add_to_group(&"cover_wall")
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = at
	return body


## The ladder entry the generator makes for a barracks at the origin (yaw 0) on its +x end.
func _barracks_entry(id := "Ladder_T") -> Dictionary:
	var cfg: Dictionary = DataRegistry.parse_quiet(MAP)["generator"]["ladders"]
	var spot := Gen.ladder_spot(WorldKit.config()["types"]["barracks"], 1.0, cfg)
	var foot: Vector3 = spot["foot"]
	var top: Vector3 = spot["top"]
	return {"id": id, "piece": "Barracks_T", "at": [foot.x, foot.y, foot.z], "yaw": 90.0, "height": float(spot["height"]),
		"width": float(cfg["width_m"]), "top": [top.x, top.y, top.z]}


## A 60 m ground (top y 0) with a real barracks at the origin and its ladder (foot x 4.7, facing -x, roof top 3.3).
func _barracks_world() -> Node3D:
	var root := Node3D.new()
	_tree().root.add_child(root)
	_box(root, Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	root.add_child(WorldKit.build_body("Barracks_T", "", WorldKit.config()["types"]["barracks"], Vector3.ZERO, 0.0))
	var ladder := Ladder.make(_barracks_entry(), _ladder_cfg())
	root.add_child(ladder)
	return root


## A ground and a 4 x 3.3 x 1 m COVER wall (group cover_wall), its face on z 0 (normal +z), with a ladder flush on the
## face at x 0 (facing -z, the ledge = the wall's top).
func _cover_world() -> Node3D:
	var root := Node3D.new()
	_tree().root.add_child(root)
	_box(root, Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	_box(root, Vector3(0, 1.65, -0.5), Vector3(4, 3.3, 1), true)
	root.add_child(Ladder.make({"id": "Ladder_C", "piece": "", "at": [0, 0, 0], "yaw": 0.0, "height": 3.3, "width": 0.6, "top": [0, 3.3, -0.6]}, _ladder_cfg()))
	return root


func _ladder(root: Node) -> Ladder:
	return root.get_tree().get_nodes_in_group(Ladder.GROUP)[0] as Ladder


func _pawn(parent: Node, at: Vector3, facing: Vector3) -> Pawn:
	var pawn: Pawn = _PawnScene.instantiate()
	parent.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_transform = Transform3D(Basis.looking_at(Vector3(facing.x, 0.0, facing.z).normalized()), at)
	pawn.velocity = Vector3.ZERO
	return pawn


func _frame(move := Vector2.ZERO) -> InputFrame:
	var f := InputFrame.new()
	f.move = move
	return f


func _tick(pawn: Pawn, frame: InputFrame) -> void:
	pawn.set_frame(frame)
	pawn._physics_process(DT)


## Ticks with `move`, a physics frame awaited after each tick, until the pawn climbs; the ticks it took or -1.
func _walk_on(pawn: Pawn, move: Vector2, max_ticks := 90) -> int:
	for i in max_ticks:
		_tick(pawn, _frame(move))
		if pawn.climbing:
			return i + 1
		await _tree().physics_frame
	return -1


func _settle() -> void:
	await _tree().physics_frame
	await _tree().physics_frame


## The stick that moves the pawn along the world direction `dir` (its yaw as it stands).
func _stick_for(pawn: Pawn, dir: Vector3) -> Vector2:
	var local := pawn.global_transform.basis.inverse() * dir.normalized()
	return Vector2(local.x, local.z)


# ---- Climbing ----

func test_climbing_state_is_a_plain_pawn_property() -> void:
	var root := _barracks_world()
	var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
	await _settle()
	var names := {}
	for p: Dictionary in pawn.get_property_list():
		names[String(p["name"])] = int(p["type"])
	assert_eq(names.get("climbing", -1), TYPE_BOOL, "climbing is a bool property on the pawn")
	assert_eq(names.get("ladder_id", -1), TYPE_STRING, "ladder_id is a String property on the pawn")
	assert_eq(names.get("can_climb", -1), TYPE_BOOL, "can_climb is a bool property on the pawn")
	assert_true(not pawn.get("climbing") and String(pawn.get("ladder_id")) == "" and pawn.get("can_climb"), "at rest: not climbing, no ladder, may climb")
	assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, "walking into the ladder grabs it")
	assert_true(pawn.get("climbing") == true and String(pawn.get("ladder_id")) == "Ladder_T", "climbing: the state names the ladder by its cover-file id")
	assert_true(pawn.current_ladder() == _ladder(root), "current_ladder is the trigger")
	root.free()


func test_climb_up_at_climb_speed_and_the_top_step_onto_the_roof() -> void:
	var root := _barracks_world()
	var ladder := _ladder(root)
	var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
	await _settle()
	var took := await _walk_on(pawn, Vector2(0, -1))
	assert_true(took > 0, "walking into the ladder (stick forward, facing it) grabs it after %d ticks" % took)
	var speed := float(_ladder_cfg()["climb_speed_mps"])
	assert_true(speed < pawn.get_move_speed(), "the climb (%.2f m/s) is slower than the walk (%.2f m/s)" % [speed, pawn.get_move_speed()])
	var steady := 0
	var off_line := 0.0
	var ticks := 0
	while pawn.climbing and ticks < 400:
		var y0 := pawn.global_position.y
		_tick(pawn, _frame(Vector2(0, -1)))
		ticks += 1
		if pawn.climbing and ticks > 15:
			assert_true(absf(pawn.global_position.y - y0 - speed * DT) < 0.002, "tick %d: up at climb speed (dy %.4f)" % [ticks, pawn.global_position.y - y0])
			off_line = maxf(off_line, Vector2(pawn.global_position.x - 5.2, pawn.global_position.z).length())
			steady += 1
	assert_true(steady > 60, "nonvacuous: %d steady climbing ticks (the eave never stops the climber)" % steady)
	assert_true(off_line < 0.01, "held on the climb line x 5.2 (climb_offset_m out from the plane): off by %.3f" % off_line)
	assert_true(not pawn.climbing and pawn.ladder_id == "", "the top step ends the climb")
	var top := ladder.top_point()
	assert_true(pawn.global_position.distance_to(top) < 0.01, "the feet are set on the top point %s (at %s)" % [top, pawn.global_position])
	for i in 20:
		_tick(pawn, _frame())
	assert_true(pawn.is_on_floor() and absf(pawn.global_position.y - 3.3) < 0.03, "standing on the roof (y %.3f, on floor)" % pawn.global_position.y)
	assert_true(absf(pawn.global_position.x - 4.0) < 0.05, "0.7 m in from the eave (x %.3f)" % pawn.global_position.x)
	for i in 40:
		_tick(pawn, _frame(Vector2(0, -1)))
	assert_true(not pawn.climbing and pawn.global_position.y > 3.2, "walking on over the roof (into the wall direction) does not grab again")
	root.free()


func test_stop_holds_and_stick_back_climbs_down_and_lets_go_on_the_ground() -> void:
	var root := _barracks_world()
	var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
	await _settle()
	assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, "grabbed")
	for i in 60:
		_tick(pawn, _frame(Vector2(0, -1)))
	var held := pawn.global_position.y
	assert_true(held > 1.5, "nonvacuous: up the ladder (y %.2f)" % held)
	for i in 60:
		_tick(pawn, _frame())
	assert_true(pawn.climbing and absf(pawn.global_position.y - held) < 0.001, "no input: holds (no gravity), y %.3f -> %.3f" % [held, pawn.global_position.y])
	var y0 := pawn.global_position.y
	_tick(pawn, _frame(Vector2(0, 1)))
	assert_true(absf(y0 - pawn.global_position.y - float(_ladder_cfg()["climb_speed_mps"]) * DT) < 0.002, "stick back: down at climb speed")
	var ticks := 0
	while pawn.climbing and ticks < 300:
		_tick(pawn, _frame(Vector2(0, 1)))
		ticks += 1
	assert_true(not pawn.climbing, "reaching the bottom while moving down lets go")
	assert_true(pawn.is_on_floor() and absf(pawn.global_position.y) < 0.03, "standing on the ground (y %.3f)" % pawn.global_position.y)
	for i in 30:
		_tick(pawn, _frame(Vector2(0, 1)))
	assert_true(not pawn.climbing and pawn.global_position.x > 5.4, "the stick still back walks away from the ladder (x %.2f)" % pawn.global_position.x)
	root.free()


func test_jump_lets_go_the_pawn_falls_lands_and_takes_no_damage() -> void:
	var root := _barracks_world()
	var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
	await _settle()
	assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, "grabbed")
	for i in 75:
		_tick(pawn, _frame(Vector2(0, -1)))
	assert_true(pawn.climbing and pawn.global_position.y > 2.0, "nonvacuous: 2 m up (y %.2f)" % pawn.global_position.y)
	var health := pawn.bridge.state.health
	var shield := pawn.bridge.state.shield
	var jump := _frame(Vector2(0, -1))
	jump.jump_pressed = true
	jump.jump_just_pressed = true
	_tick(pawn, jump)
	assert_true(not pawn.climbing and pawn.ladder_id == "", "Jump lets go")
	assert_true(pawn.velocity.x > 0.5, "with a push away from the ladder (+x): %s" % pawn.velocity)
	var lowest := 99.0
	for i in 120:
		_tick(pawn, _frame())
		lowest = minf(lowest, pawn.global_position.y)
	assert_true(pawn.is_on_floor() and absf(pawn.global_position.y) < 0.03, "fell and landed on the ground (y %.3f)" % pawn.global_position.y)
	assert_true(not pawn.climbing, "not climbing after the fall (no grab in the air, the stick released)")
	assert_eq([pawn.bridge.state.health, pawn.bridge.state.shield], [health, shield], "no fall damage")
	assert_true(pawn.is_alive(), "alive")
	root.free()


func test_get_on_from_the_roof_and_climb_down_to_the_ground() -> void:
	var root := _barracks_world()
	var ladder := _ladder(root)
	var pawn := _pawn(root, Vector3(2.0, 3.32, 0), Vector3.RIGHT)  # on the roof, facing out over the ladder's end
	await _settle()
	for i in 10:
		_tick(pawn, _frame())
	assert_true(pawn.is_on_floor() and absf(pawn.global_position.y - 3.3) < 0.03, "standing on the roof")
	var took := await _walk_on(pawn, Vector2(0, -1), 120)
	assert_true(took > 1, "walking out towards the edge over the ladder grabs it at the top (after %d ticks)" % took)
	assert_true(Vector2(pawn.global_position.x - 5.2, pawn.global_position.z).length() < 0.01 and absf(pawn.global_position.y - ladder.top_y()) < 0.001,
			"on the climb line at the ledge top: %s" % pawn.global_position)
	var ticks := 0
	var y_prev := pawn.global_position.y
	var monotonic := true
	while pawn.climbing and ticks < 300:
		_tick(pawn, _frame(Vector2(0, -1)))  # facing away from the wall, forward = out = down
		monotonic = monotonic and pawn.global_position.y <= y_prev + 0.0001
		y_prev = pawn.global_position.y
		ticks += 1
	assert_true(monotonic and ticks > 60, "the stick forward (facing away) climbs down all the way (%d ticks)" % ticks)
	assert_true(not pawn.climbing and pawn.is_on_floor() and absf(pawn.global_position.y) < 0.03, "let go standing on the ground (y %.3f)" % pawn.global_position.y)
	root.free()


func test_on_the_roof_walking_along_the_edge_or_inside_the_room_never_grabs() -> void:
	var root := _barracks_world()
	var ladder := _ladder(root)
	var along := _pawn(root, Vector3(4.2, 3.32, -2.0), Vector3.BACK)  # on the roof by the eave, walking along it (+z)
	var inside := _pawn(root, Vector3(3.6, 0.02, 0), Vector3.LEFT)  # inside the barracks, by the end wall's inner face
	await _settle()
	var touched := [false, false]
	for i in 40:
		_tick(along, _frame(Vector2(0, -1)))
		_tick(inside, _frame(Vector2(0, -1)))  # away from the end wall: the bottom rule's direction (into the ladder)
		await _tree().physics_frame
		touched[0] = touched[0] or ladder.overlaps_body(along)
		touched[1] = touched[1] or ladder.overlaps_body(inside)
		assert_true(not along.climbing and not inside.climbing, "tick %d: no grab" % i)
	assert_true(touched[0] and touched[1], "nonvacuous: both touched the trigger (%s)" % str(touched))
	root.free()


# ---- No fire on a ladder ----

func test_no_gun_fire_and_no_melee_on_a_ladder_reload_and_swap_work() -> void:
	var root := _barracks_world()
	var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
	var fired := [0, 0]
	pawn.fired.connect(func() -> void: fired[0] += 1)
	pawn.fire_empty.connect(func() -> void: fired[1] += 1)
	await _settle()
	assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, "grabbed")
	for i in 30:
		_tick(pawn, _frame(Vector2(0, -1)))
	var gun := pawn.loadout.get_active()
	assert_true(gun != null and not gun.def.is_melee(), "nonvacuous: a gun in hand (%s)" % (gun.def.id if gun != null else "none"))
	var ammo := gun.ammo_in_mag
	for i in 40:
		var f := _frame()
		f.fire_pressed = true
		f.fire_just_pressed = i % 10 == 0
		_tick(pawn, f)
	assert_true(pawn.climbing, "still on the ladder")
	assert_eq(fired[0], 0, "no gun fire on a ladder")
	assert_eq(gun.ammo_in_mag, ammo, "no round spent")
	gun.ammo_in_mag = 0
	var f0 := _frame()
	f0.fire_pressed = true
	f0.fire_just_pressed = true
	_tick(pawn, f0)
	assert_eq(fired[1], 0, "an empty Fire press on a ladder signals nothing")
	# Reload works on the ladder and completes there.
	var reload := _frame()
	reload.reload_pressed = true
	reload.reload_just_pressed = true
	_tick(pawn, reload)
	assert_true(gun.reloading, "reload starts on the ladder")
	for i in ceili(gun.def.reload_s / DT) + 3:
		_tick(pawn, _frame())
	assert_true(not gun.reloading and gun.ammo_in_mag == gun.def.magazine, "and completes on the ladder (%d)" % gun.ammo_in_mag)
	# Swap works; the blade (melee) does not swing either.
	var swapped := [0]
	pawn.weapon_switched.connect(func(_slot: int) -> void: swapped[0] += 1)
	var melee := false
	for i in 3:
		var s := _frame()
		s.swap_weapon_pressed = true
		s.swap_weapon_just_pressed = true
		_tick(pawn, s)
		_tick(pawn, _frame())
		if pawn.loadout.get_active() != null and pawn.loadout.get_active().def.is_melee():
			melee = true
			break
	assert_true(swapped[0] >= 1, "weapon swap works on the ladder (%d)" % swapped[0])
	assert_true(melee, "nonvacuous: the blade is in hand")
	for i in 40:
		var f := _frame()
		f.fire_pressed = true
		f.fire_just_pressed = i % 10 == 0
		_tick(pawn, f)
	assert_eq(fired[0], 0, "no melee swing on a ladder")
	# Control: the same Fire input on the ground swings.
	var ticks := 0
	while pawn.climbing and ticks < 300:
		_tick(pawn, _frame(Vector2(0, 1)))
		ticks += 1
	assert_true(not pawn.climbing, "back on the ground")
	for i in 40:
		var f := _frame()
		f.fire_pressed = true
		f.fire_just_pressed = i % 10 == 0
		_tick(pawn, f)
	assert_true(fired[0] > 0, "control: on the ground the same Fire input swings (%d)" % fired[0])
	root.free()


# ---- No cover on a ladder ----

func test_a_pawn_climbing_a_ladder_on_a_cover_wall_never_enters_cover() -> void:
	var root := _cover_world()
	var pawn := _pawn(root, Vector3(0, 0.02, 1.6), Vector3.FORWARD)
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await _settle()
	assert_true(pawn.cover != null, "the pawn has cover")
	assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, "walking into the ladder on the cover wall grabs it")
	var ticks := 0
	var pressed := false
	while pawn.climbing and ticks < 400:
		_tick(pawn, _frame(Vector2(0, -1)))  # pushing into the wall the whole climb (the auto-snap's input)
		ticks += 1
		if ticks == 40:
			pawn.handle_action_press("cover")  # the Cover button mid-climb, at the wall
			pressed = true
		await _tree().physics_frame
		assert_eq(pawn.cover.state, CoverController.State.FREE, "tick %d: cover stays FREE on the ladder" % ticks)
	assert_true(pressed and ticks > 60, "nonvacuous: a long climb against the cover wall, the button pressed (%d ticks)" % ticks)
	assert_true(not pawn.climbing and pawn.global_position.y > 3.2, "the top step onto the wall's top")
	assert_eq(pawn.cover.state, CoverController.State.FREE, "and cover is still FREE there")
	root.free()
	# Control (the guards are what keeps it FREE): a pawn that may not climb, the same walk into the same wall, snaps
	# into cover; the Cover button at the same spot enters cover too.
	root = _cover_world()
	var walker := _pawn(root, Vector3(0, 0.02, 1.6), Vector3.FORWARD)
	walker.can_climb = false
	walker.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await _settle()
	var snapped := -1
	for i in 120:
		_tick(walker, _frame(Vector2(0, -1)))
		await _tree().physics_frame
		if walker.cover.state != CoverController.State.FREE:
			snapped = i
			break
	assert_true(snapped >= 0 and not walker.climbing, "control: without climbing the same walk auto-snaps into cover (tick %d)" % snapped)
	root.free()
	root = _cover_world()
	var presser := _pawn(root, Vector3(0, 0.02, 0.6), Vector3.FORWARD)
	presser.can_climb = false
	presser.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await _settle()
	_tick(presser, _frame())
	await _tree().physics_frame
	presser.handle_action_press("cover")
	assert_true(presser.cover.state != CoverController.State.FREE, "control: the Cover button at the wall enters cover")
	root.free()


func test_a_pawn_in_cover_does_not_grab() -> void:
	var root := _cover_world()
	var ladder := _ladder(root)
	var pawn := _pawn(root, Vector3(0, 0.02, 0.6), Vector3.FORWARD)
	pawn.can_climb = false
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await _settle()
	_tick(pawn, _frame())
	await _tree().physics_frame
	pawn.handle_action_press("cover")
	for i in 60:
		_tick(pawn, _frame())
		await _tree().physics_frame
	assert_true(pawn.in_cover(), "in cover at the ladder (%s)" % CoverController.State.keys()[pawn.cover.state])
	pawn.can_climb = true
	var touched := false
	for i in 40:
		_tick(pawn, _frame(_stick_for(pawn, Vector3.FORWARD)))  # into the wall = into the ladder
		await _tree().physics_frame
		touched = touched or ladder.overlaps_body(pawn)
		assert_true(not pawn.climbing, "tick %d: a pawn in cover does not grab" % i)
	assert_true(touched and pawn.in_cover(), "nonvacuous: touching the trigger, still in cover")
	root.free()


# ---- Letting go ----

func test_downed_dead_and_the_drop_state_let_go() -> void:
	for how: String in ["downed", "dead", "drop"]:
		var root := _barracks_world()
		var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
		await _settle()
		assert_true(await _walk_on(pawn, Vector2(0, -1)) > 0, how + ": grabbed")
		for i in 60:
			_tick(pawn, _frame(Vector2(0, -1)))
		var y := pawn.global_position.y
		assert_true(pawn.climbing and y > 1.5, how + ": up the ladder")
		match how:
			"downed":
				pawn.life = Pawn.Life.DOWNED
			"dead":
				pawn.life = Pawn.Life.DEAD
			"drop":
				pawn.drop_state = Pawn.Drop.FALLING
		if how != "dead":
			_tick(pawn, _frame(Vector2(0, -1)))
		assert_true(not pawn.climbing and pawn.ladder_id == "", how + ": let go")
		if how == "downed":
			for i in 90:
				_tick(pawn, _frame(Vector2(0, -1)))
			assert_true(pawn.global_position.y < 0.05 and not pawn.climbing, "downed: fell to the ground and does not grab (y %.2f)" % pawn.global_position.y)
		root.free()


# ---- Who never grabs, what is never caught ----

func test_a_bot_pawn_or_can_climb_false_walking_into_a_ladder_does_not_climb() -> void:
	for how: String in ["brain", "can_climb"]:
		var root := _barracks_world()
		var ladder := _ladder(root)
		var pawn := _pawn(root, Vector3(6.5, 0.02, 0), Vector3.LEFT)
		if how == "brain":
			var brain := Node.new()
			brain.name = "Brain"  # BotSpawner's name for a bot's BotBrain child (the cover gate's check)
			pawn.add_child(brain)
		else:
			pawn.can_climb = false
		await _settle()
		var touched := false
		for i in 60:
			_tick(pawn, _frame(Vector2(0, -1)))
			await _tree().physics_frame
			touched = touched or ladder.overlaps_body(pawn)
			assert_true(not pawn.climbing, "%s tick %d: never climbs" % [how, i])
		assert_true(touched, "%s: nonvacuous, it walked into the trigger" % how)
		assert_true(pawn.global_position.y < 0.05 and pawn.global_position.x < 5.0, "%s: it stands at the wall on the ground (%s)" % [how, pawn.global_position])
		root.free()


func test_walking_past_sideways_is_not_caught_and_the_diagonal_rule() -> void:
	var root := _barracks_world()
	var ladder := _ladder(root)
	var pawn := _pawn(root, Vector3(5.3, 0.02, -3.0), Vector3.BACK)  # along the end wall, through the trigger (+z)
	await _settle()
	var touched := false
	for i in 90:
		_tick(pawn, _frame(Vector2(0, -1)))
		await _tree().physics_frame
		touched = touched or ladder.overlaps_body(pawn)
		assert_true(not pawn.climbing, "tick %d: walking past is not caught" % i)
	assert_true(touched, "nonvacuous: it passed through the trigger")
	assert_true(pawn.global_position.z > 3.0, "the trigger blocks no movement (z %.2f)" % pawn.global_position.z)
	root.free()
	# The grab rule on diagonal input (grab_min_dot 0.6, about 53 degrees): 45 degrees into the ladder grabs, 60 does not.
	var min_dot := float(_ladder_cfg()["grab_min_dot"])
	for deg: float in [45.0, 60.0]:
		root = _barracks_world()
		# Facing the ladder (-x), the stick deg degrees to the right (local +x = world -z): the walk heads for the
		# ladder's middle, so the capsule meets the trigger (centre x 5.6) at z 0.
		var p := _pawn(root, Vector3(6.0, 0.02, 0.4 * tan(deg_to_rad(deg))), Vector3.LEFT)
		await _settle()
		var stick := Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg)))
		var seen := [false]
		var took := -1
		for i in 60:
			_tick(p, _frame(stick))
			if p.climbing:
				took = i + 1
				break
			await _tree().physics_frame
			seen[0] = seen[0] or _ladder(root).overlaps_body(p)
		if cos(deg_to_rad(deg)) >= min_dot:
			assert_true(took > 0, "%d degrees into the ladder grabs (cos %.2f >= %.2f)" % [deg, cos(deg_to_rad(deg)), min_dot])
		else:
			assert_true(took < 0 and seen[0], "%d degrees into the ladder touches it and does not grab (cos %.2f < %.2f)" % [deg, cos(deg_to_rad(deg)), min_dot])
		root.free()
