extends "res://tests/test_case.gd"
## M2 L1c commit 3: doors and gates (scripts/props/door.gd, WorldProps doors, data/props.json "door", the 1 km
## cover file's "doors" from tools/gen_alesia.gd). Small fixtures built here; the 1 km scene checks live in
## tests/test_alesia_1km.gd (the one file that builds that scene). Covered: the data (props.json, problems, the
## generator's counts, ids, determinism and start shares, no doors on alesia_section / test_300), the body (groups,
## layer, collider only while closed), blocking (a real physics walk, a Hitscan shot and the bots' sight query stop
## at a closed door and pass an open one), sliding and waiting (a pawn in the doorway: the door waits and retries,
## never moves the pawn, never switches its collider on over a pawn; a pawn right at the door, either side, never
## blocks it), WorldProps state (stored for every
## door, absolute, a client applies changed values), not cover (CoverProbe unchanged beside a door) and the bake
## (a door under a Props sibling of Nav leaves the mesh as without it).

const MAP := "res://data/maps/alesia_1km.json"
const Gen := preload("res://tools/gen_alesia.gd")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const DT := 1.0 / 60.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg(kind := Door.KIND_DOOR) -> Dictionary:
	return WorldProps.door_cfg(WorldProps.config(), kind)


func _entry(id: String, at: Vector3, start := "closed", kind := Door.KIND_DOOR, slide := "", yaw := 0.0) -> Dictionary:
	var size := [2.0, 2.3, 0.12] if kind == Door.KIND_DOOR else [4.0, 4.5, 0.25]
	if slide == "":
		slide = "right" if kind == Door.KIND_DOOR else "apart"
	return {"id": id, "kind": kind, "at": [at.x, at.y, at.z], "yaw": yaw, "size": size, "slide": slide, "start": start}


## A door whose threshold is at y 0, centred at (x, z); a door slides right (+x), a gate apart, unless told.
func _door(parent: Node, id: String, x: float, z: float, start := "closed", kind := Door.KIND_DOOR, slide := "") -> Door:
	var h := 2.3 if kind == Door.KIND_DOOR else 4.5
	var d := Door.make(_entry(id, Vector3(x, h * 0.5, z), start, kind, slide), _cfg(kind))
	parent.add_child(d)
	return d


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


## A fixture world: a 60 m ground (top at y 0) under a fresh root.
func _world() -> Node3D:
	var root := Node3D.new()
	_tree().root.add_child(root)
	_box(root, Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	return root


func _pawn(parent: Node, at: Vector3, facing := Vector3.FORWARD) -> Pawn:
	var pawn: Pawn = _PawnScene.instantiate()
	parent.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_transform = Transform3D(Basis.looking_at(Vector3(facing.x, 0.0, facing.z).normalized()), at)
	pawn.velocity = Vector3.ZERO
	return pawn


## One pawn tick through the normal input path (InputFrame -> set_frame -> _physics_process).
func _tick(pawn: Pawn, move := Vector2.ZERO) -> void:
	var frame := InputFrame.new()
	frame.move = move
	pawn.set_frame(frame)
	pawn._physics_process(DT)


func _settle() -> void:
	await _tree().physics_frame
	await _tree().physics_frame


## Drives `door` by hand for `ticks` ticks (its own processing off), ticking `pawn` (no input) alongside, so a
## collider pushing it would show as a moved pawn.
func _run(door: Door, ticks: int, pawn: Pawn = null) -> void:
	door.set_physics_process(false)
	for i in ticks:
		door.step(DT)
		if pawn != null:
			_tick(pawn)


func _ticks(seconds: float) -> int:
	return ceili(seconds / DT) + 2


# ---- Data ----

func test_props_json_door_block_and_gate_variant() -> void:
	var cfg := WorldProps.config()
	assert_eq(WorldProps.problems({}, cfg), PackedStringArray(), "props.json (with the door block) has no problem")
	var door := _cfg(Door.KIND_DOOR)
	var gate := _cfg(Door.KIND_GATE)
	assert_true(not door.has("gate") and not gate.has("gate"), "the gate block is merged, not kept")
	assert_true(String(cfg["door"]["_todo"]).begins_with("OQ-PROPS-DOOR"), "the door block carries OQ-PROPS-DOOR")
	assert_eq(float(gate["interact_range_m"]), float(cfg["door"]["gate"]["interact_range_m"]), "a gate takes its own range")
	assert_eq(float(gate["blocked_retry_s"]), float(cfg["door"]["blocked_retry_s"]), "and the door's retry where it has none")
	var stuck := float(DataRegistry.new().load_file("res://data/bots.json")["brain"]["stuck_window_s"])
	for c: Dictionary in [door, gate]:
		assert_true(float(c["bot_open_delay_s"]) + float(c["move_time_s"]) < stuck, "bot delay + move time under stuck_window_s %.1f" % stuck)
	var bad := cfg.duplicate(true)
	bad["door"]["move_time_s"] = 0
	bad["door"]["gate"]["look"] = {"parts": []}
	bad["door"]["blocked_retry_s"] = -1.0
	var lines := WorldProps.problems({}, bad)
	# The gate keeps its own move_time_s, so the zero shows for the door only; the retry is shared by both.
	assert_eq(lines.size(), 4, "a zero door move time, a negative retry (both kinds) and an empty gate look: %s" % str(lines))


func test_problems_for_bad_doors_entries() -> void:
	var cfg := WorldProps.config()
	var good := {"doors": [_entry("Door_000", Vector3(1, 1.15, 2)), _entry("Door_001", Vector3(1, 1.15, 9), "open", Door.KIND_DOOR, "left"),
		_entry("Gate_000", Vector3(5, 2.25, 2), "open", Door.KIND_GATE)]}
	assert_eq(WorldProps.problems(good, cfg), PackedStringArray(), "good doors pass")
	var cases := {
		"not a list": {"doors": {}},
		"not a dictionary": {"doors": [3]},
		"duplicate id with a piece": {"pieces": [{"id": "Door_000"}], "doors": [_entry("Door_000", Vector3.ZERO)]},
		"duplicate id with a chest": {"chests": [{"id": "X", "at": [0, 0, 0], "size": [1, 1, 1], "yaw": 0.0}], "doors": [_entry("X", Vector3.ZERO)]},
		"two doors one id": {"doors": [_entry("D", Vector3.ZERO), _entry("D", Vector3.ONE)]},
		"empty id": {"doors": [_entry("", Vector3.ZERO)]},
	}
	var broken := {"kind": "hatch", "at": [0, 0], "size": [2, 0, 0.1], "yaw": "north", "slide": "up", "start": "ajar"}
	for key: String in broken:
		var e := _entry("D", Vector3.ZERO)
		e[key] = broken[key]
		cases["bad " + key] = {"doors": [e]}
	for what: String in cases:
		assert_true(not WorldProps.problems(cases[what], cfg).is_empty(), what + " is reported")


func test_generator_places_24_doors_and_8_gates_deterministically() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	var a: Dictionary = Gen.generate(def)
	var b: Dictionary = Gen.generate(DataRegistry.parse_quiet(MAP))
	assert_eq(Gen.text_of({"d": a["cover"]["doors"]}), Gen.text_of({"d": b["cover"]["doors"]}), "two runs give the same doors")
	assert_eq((a["problems"] as PackedStringArray), PackedStringArray(), "the generator reports no problem")
	var committed := DataRegistry.parse_quiet(String(def["cover_data"]))
	assert_eq(Gen.text_of({"d": committed["doors"]}), Gen.text_of({"d": a["cover"]["doors"]}), "the committed doors are the generator's")
	var structures := {}
	for p: Dictionary in DataRegistry.parse_quiet(String(def["structure_data"]))["pieces"]:
		structures[String(p["id"])] = p
	var gen: Dictionary = def["generator"]["doors"]
	assert_true(String(gen["_todo"]).begins_with("OQ-PROPS-DOOR"), "the generator block carries OQ-PROPS-DOOR")
	var barracks := 0
	var gate_pieces := 0
	for id: String in structures:
		barracks += 1 if String(structures[id]["type"]) == "barracks" else 0
		gate_pieces += 1 if String(structures[id]["type"]) == "gate" else 0
	assert_eq(barracks, 12, "12 barracks blocks on the map")
	assert_eq(gate_pieces, 8, "8 gates on the map")
	var ids := {}
	var by_kind := {"door": 0, "gate": 0}
	var open := {"door": 0, "gate": 0}
	var per_piece := {}
	var kit: Dictionary = WorldKit.config()["types"]
	for e: Dictionary in committed["doors"]:
		var id := String(e["id"])
		assert_true(not ids.has(id), id + " is unique")
		ids[id] = true
		var kind := String(e["kind"])
		by_kind[kind] = int(by_kind[kind]) + 1
		open[kind] = int(open[kind]) + (1 if String(e["start"]) == "open" else 0)
		var piece: Dictionary = structures.get(String(e["piece"]), {})
		assert_eq(String(piece.get("type", "")), "barracks" if kind == "door" else "gate", id + " sits in its kit type")
		per_piece[e["piece"]] = int(per_piece.get(e["piece"], 0)) + 1
		# The opening: the kit type's "open" box turned by the piece's yaw, its width and height.
		var o: Dictionary = (kit[String(piece["type"])]["open"] as Array)[0 if kind == "gate" else (0 if int(per_piece[e["piece"]]) == 1 else 1)]
		var want := LowpolyKit.vec(piece["at"]) + Basis(Vector3.UP, deg_to_rad(float(piece["yaw"]))) * LowpolyKit.vec(o["at"])
		assert_true(LowpolyKit.vec(e["at"]).distance_to(want) < 0.002, "%s at its opening %s (got %s)" % [id, want, str(e["at"])])
		assert_true(is_equal_approx(float(e["size"][0]), float(o["size"][0])) and is_equal_approx(float(e["size"][1]), float(o["size"][1])), id + ": the opening's width and height")
		# Slides towards the piece's centre (a door) or apart (a gate), and every pocket lies inside the piece's walls.
		assert_eq(String(e["slide"]), "apart" if kind == "gate" else ("right" if float(o["at"][0]) < 0.0 else "left"), id + ": slide")
		assert_eq(Gen.door_pocket_problem(kit[String(piece["type"])], LowpolyKit.vec(o["at"]), LowpolyKit.vec(o["size"]), String(e["slide"])), "", id + ": its pocket is inside the wall")
		if kind == "gate":
			var far := Vector2(float(e["size"][0]), float(e["size"][2]) * 0.5).length()
			assert_true(far <= float(def["generator"]["gates"]["clear_m"]), "%s: an open leaf within gates.clear_m (%.2f m)" % [id, far])
	var door0: Dictionary = (kit["barracks"]["open"] as Array)[0]
	assert_true(Gen.door_pocket_problem(kit["barracks"], LowpolyKit.vec(door0["at"]), LowpolyKit.vec(door0["size"]), "left") != "",
			"nonvacuous: door 0 sliding outwards would leave the barracks (only 1 m of wall there)")
	assert_eq(int(by_kind["door"]), 24, "24 doors (two per barracks)")
	assert_eq(int(by_kind["gate"]), 8, "8 gates")
	for piece: Variant in per_piece:
		assert_eq(int(per_piece[piece]), 2 if String(piece).contains("Barracks") else 1, "%s: every opening once" % piece)
	assert_eq(a["doors"], {"door": 24, "gate": 8, "open": int(open["door"]) + int(open["gate"]), "closed": 32 - int(open["door"]) - int(open["gate"])}, "the generator's counts")
	# The start shares: seeded draws, so only a loose band around the share (24 and 8 draws).
	var door_share := float(int(open["door"])) / 24.0
	assert_true(absf(door_share - float(gen["door"]["start_open_share"])) <= 0.3, "door start share %.2f near %s" % [door_share, str(gen["door"]["start_open_share"])])
	assert_true(int(open["gate"]) >= 1 and int(open["gate"]) <= 8, "some gates start open: %d" % int(open["gate"]))
	assert_eq(WorldProps.problems(committed, WorldProps.config()), PackedStringArray(), "WorldProps.problems is clean on the committed cover file")
	print("DOORS_1KM doors=%d gates=%d open_doors=%d open_gates=%d" % [by_kind["door"], by_kind["gate"], open["door"], open["gate"]])
	# The same entry gives the same door on every peer (host and client build from this file).
	for e: Dictionary in committed["doors"]:
		var d1 := Door.make(e, _cfg(String(e["kind"])))
		var d2 := Door.make(e, _cfg(String(e["kind"])))
		assert_true(d1.open == d2.open and d1.open == (String(e["start"]) == "open") and d1.blocks() == (not d1.open),String(e["id"]) + ": the start state from the file")
		d1.free()
		d2.free()


func test_generator_without_the_block_and_the_fixture_maps_have_no_doors() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	(def["generator"] as Dictionary).erase("doors")
	var out: Dictionary = Gen.generate(def)
	assert_true(not (out["cover"] as Dictionary).has("doors"), "no doors block, no doors key")
	var with_doors: Dictionary = Gen.generate(DataRegistry.parse_quiet(MAP))
	var plain := (with_doors["cover"] as Dictionary).duplicate()
	plain.erase("doors")
	assert_eq(Gen.text_of(plain), Gen.text_of(out["cover"]), "the doors pass changes nothing else in the cover file")
	assert_eq(Gen.text_of(with_doors["structures"]), Gen.text_of(out["structures"]), "nor the structures")
	for path: String in ["res://data/maps/alesia_cover.json", "res://data/maps/test_300_cover.json"]:
		if FileAccess.file_exists(path):
			assert_true(not DataRegistry.parse_quiet(path).has("doors"), path + ": no doors")
	for map_path: String in ["res://data/maps/alesia_section.json", "res://data/maps/test_300.json"]:
		var m := DataRegistry.parse_quiet(map_path)
		var cover := String(m.get("cover_data", "res://data/maps/alesia_cover.json"))
		assert_true(not DataRegistry.parse_quiet(cover).has("doors"), map_path + ": its cover file has no doors")
		assert_true(not (m.get("generator", {}) as Dictionary).has("doors"), map_path + ": no doors generator block")


# ---- The body ----

func test_body_groups_layer_and_collider_by_state() -> void:
	var closed := Door.make(_entry("Door_900", Vector3(0, 1.15, 0)), _cfg())
	var open := Door.make(_entry("Gate_900", Vector3(9, 2.25, 0), "open", Door.KIND_GATE), _cfg(Door.KIND_GATE))
	for d: Door in [closed, open]:
		assert_true(d.is_in_group(Door.GROUP) and not d.is_in_group(&"cover_wall") and not d.is_in_group(&"structure"), "%s: group door only, never cover_wall" % d.prop_id)
		assert_true(d.collision_layer == Hitscan.MASK_WORLD and d.collision_mask == 0, "%s: layer 1 (Hitscan.MASK_WORLD), no mask" % d.prop_id)
		var shape := d.get_node("Shape") as CollisionShape3D
		assert_true((shape.shape as BoxShape3D).size.is_equal_approx(d.size), "%s: the box is the cover file's size" % d.prop_id)
		assert_true(d.settled(), "%s starts settled" % d.prop_id)
	assert_true(closed.blocks() and closed.phase == 0.0 and closed.leaves.size() == 1, "a closed door: collider on, one leaf")
	assert_true(not open.blocks() and open.phase == 1.0 and open.leaves.size() == 2, "an open gate: collider off, two leaves")
	assert_true(closed.get_node("Leaf0/Look") is MeshInstance3D and (closed.get_node("Leaf0/Look") as MeshInstance3D).mesh != null, "a leaf look")
	# The open gate's half leaves (2 m each) slid apart into the pillars: centres at x -3 and +3, in the leaf plane.
	assert_true(open.leaves[0].position.is_equal_approx(Vector3(-3, 0, 0)) and open.leaves[1].position.is_equal_approx(Vector3(3, 0, 0)), "open gate leaves at x -3 / +3: %s %s" % [open.leaves[0].position, open.leaves[1].position])
	assert_true(closed.leaves[0].position.is_equal_approx(Vector3.ZERO), "the closed door's leaf fills the opening")
	closed.free()
	open.free()


func test_closed_door_stops_a_walk_a_shot_and_bot_sight_an_open_one_none() -> void:
	var root := _world()
	var back := _box(root, Vector3(0, 1.5, -9.0), Vector3(6, 3, 0.4))
	var door := _door(root, "Door_901", 0.0, -3.0)
	var pawn := _pawn(root, Vector3(0, 0.02, 0))
	await _settle()
	var space := root.get_world_3d().direct_space_state
	var rifle := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	var none: Array[RID] = [pawn.get_rid()]
	var eye := Vector3(0, 1.6, 0)
	var target := Vector3(0, 1.2, -6.0)
	for state: String in ["closed", "open"]:
		if state == "open":
			door.set_open(true)
			_run(door, _ticks(door.move_time_s))
			await _settle()
			assert_true(door.settled() and not door.blocks() and door.phase == 1.0, "the door is open and settled")
		pawn.global_position = Vector3(0, 0.02, 0)
		pawn.velocity = Vector3.ZERO
		for i in 150:
			_tick(pawn, Vector2(0, -1))
		var walked_z := pawn.global_position.z
		pawn.global_position = Vector3(12, 0.02, 12)  # out of the line of fire
		await _settle()
		var shot := Hitscan.cast(space, eye, Vector3.FORWARD, rifle, none)
		var sight := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, target, Hitscan.MASK_WORLD))  # bot_brain _find_target's query
		if state == "closed":
			assert_true(walked_z > -3.0 + 0.06 + 0.3, "a closed door stops the walk (z %.2f)" % walked_z)
			assert_true(shot.get("collider") == door, "a closed door stops the shot")
			assert_true(not sight.is_empty() and sight["collider"] == door, "a closed door blocks bot sight")
		else:
			assert_true(walked_z < -4.0, "an open door lets the walk through (z %.2f)" % walked_z)
			assert_true(shot.get("collider") == back, "an open door lets the shot through to the wall behind")
			assert_true(sight.is_empty(), "an open door does not block bot sight")
	root.free()


func test_pawn_in_the_doorway_waits_and_is_never_pushed() -> void:
	var root := _world()
	var door := _door(root, "Door_902", 0.0, 0.0, "open")  # slides right (+x) into the pocket
	var pawn := _pawn(root, Vector3(0.2, 0.02, 0.0))  # standing in the doorway
	await _settle()
	for i in 30:
		_tick(pawn)
	var rest := pawn.global_position
	assert_true(door.pawn_in_path() and door.pawn_in_closed(), "nonvacuous: the pawn stands in the door's path")
	door.set_open(false)
	_run(door, _ticks(door.blocked_retry_s * 3.0), pawn)
	assert_true(door.phase == 1.0 and not door.moving and not door.blocks(), "blocked: the door has not moved and its collider stays off")
	assert_true(door.waits >= 3, "it retried every blocked_retry_s (%d waits)" % door.waits)
	assert_true(pawn.global_position.distance_to(rest) < 0.001, "the pawn was not moved (%.4f m)" % pawn.global_position.distance_to(rest))
	pawn.global_position = Vector3(0.2, 0.02, 4.0)  # out of the way
	await _settle()
	_run(door, _ticks(door.blocked_retry_s + door.move_time_s), pawn)
	assert_true(door.phase == 0.0 and door.blocks() and door.settled(), "clear: it closed and its collider is on")
	# The opener standing right at the closed door (either side) is not in its path: it opens at once.
	for z: float in [0.55, -0.55]:
		pawn.global_position = Vector3(0.0, 0.02, z)
		await _settle()
		for i in 10:
			_tick(pawn)
		var waits := door.waits
		var at := pawn.global_position
		door.set_open(true)
		_run(door, _ticks(door.move_time_s), pawn)
		assert_true(door.phase == 1.0 and door.waits == waits and not door.blocks(), "a pawn at the door (z %.2f) does not block its opening" % z)
		assert_true(pawn.global_position.distance_to(at) < 0.001, "and is not moved")
		door.set_open(false)
		_run(door, _ticks(door.move_time_s), pawn)
		assert_true(door.phase == 0.0 and door.blocks() and door.waits == waits, "nor its closing (beside, not in, the doorway)")
	root.free()


func test_never_ends_closed_on_a_pawn_in_the_doorway() -> void:
	var root := _world()
	var door := _door(root, "Gate_901", 0.0, 0.0, "open", Door.KIND_GATE)  # two half leaves sliding apart
	var pawn := _pawn(root, Vector3(0.0, 0.02, 6.0))
	await _settle()
	door.set_open(false)
	_run(door, 3)
	assert_true(door.moving and not door.blocks(), "the gate is closing, its collider off while it moves")
	pawn.global_position = Vector3(0.5, 0.02, 0.0)  # steps into the doorway while it closes
	await _settle()
	for i in 30:
		_tick(pawn)  # lands on the ground; the door is driven by hand only, so it does not move meanwhile
	var rest := pawn.global_position
	_run(door, _ticks(door.move_time_s + door.blocked_retry_s * 2.0), pawn)
	assert_true(door.phase == 0.0 and not door.moving, "the leaves reached the closed pose")
	assert_true(not door.blocks(), "but the collider stays off with a pawn in the doorway")
	assert_true(door.waits >= 2, "and it retries (%d waits)" % door.waits)
	assert_true(pawn.global_position.distance_to(rest) < 0.001, "the pawn was not moved")
	pawn.global_position = Vector3(0.5, 0.02, 6.0)
	await _settle()
	_run(door, _ticks(door.blocked_retry_s), pawn)
	assert_true(door.blocks() and door.settled(), "clear: the collider switches on")
	root.free()


func test_motion_takes_move_time_and_reverses_without_a_check() -> void:
	var root := _world()
	var door := _door(root, "Door_903", 0.0, 0.0)
	await _settle()
	var sfx := _tree().root.get_node_or_null("Sfx")
	assert_true(sfx != null, "nonvacuous: the Sfx autoload is there")
	if sfx != null:
		for i in sfx._pool_until.size():
			sfx._pool_until[i] = 0
		sfx._last_play.clear()
		sfx.clear_log()
	door.set_open(true)
	var half := int(door.move_time_s / DT / 2.0)
	_run(door, half)
	if sfx != null:
		var ids: Array = sfx.played.map(func(e: Dictionary) -> String: return String(e["id"]))
		assert_eq(ids, ["impact_wood"], "the move starts with the existing wood impact sound (palette door -> by_palette.default)")
	assert_true(door.moving and door.phase > 0.3 and door.phase < 0.7 and not door.blocks(), "half way after half the move time (%.2f)" % door.phase)
	door.set_open(false)
	_run(door, _ticks(door.move_time_s))
	assert_true(door.phase == 0.0 and door.blocks(), "a reversed move goes back and closes")
	root.free()


# ---- WorldProps ----

func test_world_props_stores_every_door_and_sets_absolute_states() -> void:
	var root := _world()
	var a := _door(root, "Door_910", 0.0, -3.0, "closed")
	var b := _door(root, "Gate_910", 8.0, -3.0, "open", Door.KIND_GATE)
	var host := WorldProps.new()
	host.setup(WorldProps.config(), 7, true)
	root.add_child(host)
	host.collect(root)
	assert_eq(host.states, {"Door_910": WorldProps.CLOSED, "Gate_910": WorldProps.OPEN}, "every door is stored from the start")
	assert_eq(host.door_kind("Gate_910"), Door.KIND_GATE, "door_kind")
	var sent: Array = []
	host.prop_changed.connect(func(id: String, s: int) -> void: sent.append([id, s]))
	assert_true(not host.set_door("Door_910", WorldProps.CLOSED), "the state it has: nothing")
	assert_true(not host.set_door("Door_910", WorldProps.BROKEN), "a non-door state: nothing")
	assert_true(host.toggle_door("Door_910") and a.open, "toggle: CLOSED -> OPEN")
	assert_true(host.toggle_door("Door_910") and not a.open, "toggle: OPEN -> CLOSED")
	assert_eq(sent, [["Door_910", WorldProps.OPEN], ["Door_910", WorldProps.CLOSED]], "prop_changed carries the absolute values")
	# A client: nothing by itself; applies every CHANGED value; breakables / chests keep "first state wins".
	var client := WorldProps.new()
	client.setup(WorldProps.config(), 7, false)
	root.add_child(client)
	var c := Door.make(_entry("Door_911", Vector3(0, 1.15, -12)), _cfg())
	root.add_child(c)
	client.register_door(c)
	assert_true(not client.toggle_door("Door_911") and not client.set_door("Door_911", WorldProps.OPEN), "a client sets nothing")
	client.apply_state("Door_911", WorldProps.OPEN)
	assert_true(client.state_of("Door_911") == WorldProps.OPEN and c.open, "applies OPEN")
	client.apply_state("Door_911", WorldProps.CLOSED)
	assert_true(client.state_of("Door_911") == WorldProps.CLOSED and not c.open, "applies the changed CLOSED")
	client.apply_state("Door_911", WorldProps.BROKEN)
	assert_eq(client.state_of("Door_911"), WorldProps.CLOSED, "ignores a non-door state")
	var chest := LootChest.make({"id": "Chest_911", "at": [20, 0.45, 0], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	root.add_child(chest)
	client.register_chest(chest)
	client.apply_state("Chest_911", WorldProps.OPEN)
	client.apply_state("Chest_911", WorldProps.CLOSED)
	assert_eq(client.state_of("Chest_911"), WorldProps.OPEN, "a chest keeps its first applied state")
	root.free()


func test_door_near_picks_the_nearest_in_range_and_height() -> void:
	var root := _world()
	var props := WorldProps.new()
	props.setup(WorldProps.config(), 7, true)
	root.add_child(props)
	_door(root, "Door_920", 0.0, -1.5)
	_door(root, "Door_921", 0.0, 2.5, "open")
	_door(root, "Gate_920", 30.0, 0.0, "closed", Door.KIND_GATE)
	props.collect(root)
	var r := float(_cfg()["interact_range_m"])
	assert_eq(props.door_near(Vector3(0, 0, 0)), "Door_920", "the nearer door (1.44 m against 2.44 m)")
	assert_eq(props.door_near(Vector3(0, 0, 1.2)), "Door_921", "the other when nearer; open doors count too")
	assert_eq(props.door_near(Vector3(0, 0, -1.5 - 0.06 - r - 0.1)), "", "out of range: none")
	assert_eq(props.door_near(Vector3(0, float(_cfg()["height_limit_m"]) + 0.5, -1.0)), "", "too far above the threshold: none")
	var gr := float(_cfg(Door.KIND_GATE)["interact_range_m"])
	assert_eq(props.door_near(Vector3(30.0 + 1.9, 0, gr - 0.2)), "Gate_920", "a gate's own range from its leaves' footprint")
	root.free()


# ---- Not cover ----

func test_doors_are_not_cover_and_leave_the_cover_probe_unchanged() -> void:
	var cover_cfg: Dictionary = DataRegistry.new().load_file("res://data/cover.json")
	var root := _world()
	_box(root, Vector3(0, 1.0, -0.9), Vector3(4, 2, 0.6), true)
	var pawn := _pawn(root, Vector3(0, 0, 0))
	await _settle()
	var probe := CoverProbe.new()
	var before := probe.sample(pawn, cover_cfg, false)
	assert_true(bool(before["hit"]), "nonvacuous: the pawn is at a cover wall")
	var locked_before := probe.sample(pawn, cover_cfg, true)
	# A closed door flush with the wall's +x end, in its plane, and an open one at its -x end.
	_door(root, "Door_930", 3.0, -0.9)
	_door(root, "Door_931", -3.0, -0.9, "open")
	await _settle()
	var probe2 := CoverProbe.new()
	assert_eq(probe2.sample(pawn, cover_cfg, false), before, "the unlocked sample is the same with doors beside the wall")
	assert_eq(probe2.sample(pawn, cover_cfg, true), locked_before, "and the locked one")
	pawn.global_position = Vector3(3.0, 0, 0)
	await _settle()
	assert_true(not bool(CoverProbe.new().sample(pawn, cover_cfg, false)["hit"]), "facing the closed door: no cover")
	var walls := 0
	for node in _tree().get_nodes_in_group(&"cover_wall"):
		if root.is_ancestor_of(node):
			walls += 1
	assert_eq(walls, 1, "the doors add no cover wall")
	root.free()


# ---- Navigation ----

## Bakes a 30 m ground with the 1 km scene's own NavigationMesh settings and a closed door: "none", "props" (under
## a Props sibling of Nav, as the builder puts it) or "nav" (under Nav). Returns [polygons, vertices].
func _bake(where: String) -> Array:
	var scene: Node = load("res://scenes/maps/alesia_1km.tscn").instantiate()
	var mesh := (scene.get_node("Nav") as NavigationRegion3D).navigation_mesh.duplicate() as NavigationMesh
	scene.free()
	var root := Node3D.new()
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	nav.navigation_mesh = mesh
	root.add_child(nav)
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	nav.add_child(ground)
	var props := Node3D.new()
	props.name = "Props"
	root.add_child(props)
	if where != "none":
		var d := Door.make(_entry("Gate_960", Vector3(0, 2.25, 0), "closed", Door.KIND_GATE), _cfg(Door.KIND_GATE))
		(nav if where == "nav" else props).add_child(d)
	_tree().root.add_child(root)
	await _tree().physics_frame
	nav.bake_navigation_mesh(false)
	var out := [mesh.get_polygon_count(), mesh.get_vertices().size()]
	root.free()
	return out


func test_a_door_under_props_leaves_the_bake_unchanged() -> void:
	var none: Array = await _bake("none")
	var props: Array = await _bake("props")
	var under: Array = await _bake("nav")
	assert_true(int(none[0]) > 0, "nonvacuous: the ground bakes (%d polygons)" % int(none[0]))
	assert_eq(props, none, "a closed gate under the Props sibling leaves the mesh as without it")
	assert_true(under != none, "the same closed gate under Nav is parsed (%s vs %s)" % [str(under), str(none)])
	print("DOORS_NAV none=", none, " props=", props, " under_nav=", under)
