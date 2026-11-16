extends "res://tests/test_case.gd"
## M2 L1c commit 5: ladders, the data and the body (scripts/props/ladder.gd, data/props.json "ladder", the 1 km cover
## file's "ladders" from tools/gen_alesia.gd _ladders, WorldProps.problems; OQ-PROPS-LADDER). Climbing is
## tests/test_pawn_ladder.gd; the 1 km scene check is tests/test_alesia_1km.gd (the one file that builds that scene).
## Covered: props.json and the problems of bad config and bad entries, the generator (12 ladders, one per barracks,
## on an end wall, ids unique, two runs identical, the committed file is the generator's, nothing else changes, the
## foot-clearance check and the end-wall rules are not vacuous, no ladders on alesia_section / test_300), the body
## (layer 0, mask pawns, group ladder only, never cover_wall), blocking nothing (a Hitscan shot and the bots' sight
## query pass through the trigger) and the bake (a ladder under a Props sibling of Nav, or even under Nav, leaves the
## mesh as without it).

const MAP := "res://data/maps/alesia_1km.json"
const Gen := preload("res://tools/gen_alesia.gd")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return WorldProps.config()["ladder"]


func _entry(id: String, at := Vector3.ZERO, yaw := 0.0, height := 3.3) -> Dictionary:
	var top := at + Basis(Vector3.UP, deg_to_rad(yaw)) * Vector3(0, height, -0.7)
	return {"id": id, "piece": "P", "at": [at.x, at.y, at.z], "yaw": yaw, "height": height, "width": 0.6, "top": [top.x, top.y, top.z]}


func _box(parent: Node, at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = at
	return body


# ---- Data ----

func test_props_json_ladder_block() -> void:
	var cfg := WorldProps.config()
	assert_eq(WorldProps.problems({}, cfg), PackedStringArray(), "props.json (with the ladder block) has no problem")
	var l: Dictionary = cfg["ladder"]
	assert_true(String(l["_todo"]).begins_with("OQ-PROPS-LADDER"), "the ladder block carries OQ-PROPS-LADDER")
	var walk := float(DataRegistry.new().load_file("res://data/stats.json")["movement"]["base_speed_mps"])
	assert_true(float(l["climb_speed_mps"]) < walk, "the climb (%s) is slower than the walk (%s)" % [str(l["climb_speed_mps"]), str(walk)])
	assert_true(float(l["climb_offset_m"]) >= Ladder.PAWN_RADIUS_M, "the climb line clears an eave at the plane")
	assert_true(not String(cfg["door"]["_todo"]).contains("hinge") and not String(cfg["door"]["_todo"]).contains("swing side"), "the door note no longer speaks of hinges or a swing side (doors slide)")
	var bad := cfg.duplicate(true)
	bad["ladder"]["climb_speed_mps"] = 0
	bad["ladder"]["grab_min_dot"] = 1.5
	bad["ladder"]["regrab_delay_s"] = -1.0
	bad["ladder"]["climb_offset_m"] = 0.1
	bad["ladder"]["look"] = {"parts": []}
	var lines := WorldProps.problems({}, bad)
	assert_eq(lines.size(), 5, "a zero speed, a dot over 1, a negative delay, an offset under the pawn radius and an empty look: %s" % str(lines))
	var none := cfg.duplicate(true)
	none.erase("ladder")
	assert_true(not WorldProps.problems({}, none).is_empty(), "a missing ladder block is reported")


func test_problems_for_bad_ladders_entries() -> void:
	var cfg := WorldProps.config()
	var good := {"ladders": [_entry("Ladder_000"), _entry("Ladder_001", Vector3(5, 0.5, 2), 90.0)]}
	assert_eq(WorldProps.problems(good, cfg), PackedStringArray(), "good ladders pass")
	var cases := {
		"not a list": {"ladders": {}},
		"not a dictionary": {"ladders": [3]},
		"duplicate id with a piece": {"pieces": [{"id": "Ladder_000"}], "ladders": [_entry("Ladder_000")]},
		"duplicate id with a door": {"doors": [{"id": "X", "kind": "door", "at": [0, 0, 0], "yaw": 0.0, "size": [2, 2, 0.1], "slide": "left", "start": "open"}], "ladders": [_entry("X")]},
		"two ladders one id": {"ladders": [_entry("L"), _entry("L", Vector3.ONE)]},
		"empty id": {"ladders": [_entry("")]},
	}
	var broken := {"piece": 3, "at": [0, 0], "yaw": "east", "height": 0, "width": -0.6, "top": [0, 0]}
	for key: String in broken:
		var e := _entry("L")
		e[key] = broken[key]
		cases["bad " + key] = {"ladders": [e]}
	var off := _entry("L")
	off["top"] = [0.0, 2.0, -0.7]
	cases["top not at the ledge"] = {"ladders": [off]}
	for what: String in cases:
		assert_true(not WorldProps.problems(cases[what], cfg).is_empty(), what + " is reported")


# ---- The generator ----

func test_generator_places_one_ladder_per_barracks_on_an_end_wall() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	var a: Dictionary = Gen.generate(def)
	var b: Dictionary = Gen.generate(DataRegistry.parse_quiet(MAP))
	assert_eq(Gen.text_of({"l": a["cover"]["ladders"]}), Gen.text_of({"l": b["cover"]["ladders"]}), "two runs give the same ladders")
	assert_eq((a["problems"] as PackedStringArray), PackedStringArray(), "the generator reports no problem")
	var committed := DataRegistry.parse_quiet(String(def["cover_data"]))
	assert_eq(Gen.text_of({"l": committed["ladders"]}), Gen.text_of({"l": a["cover"]["ladders"]}), "the committed ladders are the generator's")
	var gen: Dictionary = def["generator"]["ladders"]
	assert_true(String(gen["_todo"]).begins_with("OQ-PROPS-LADDER"), "the generator block carries OQ-PROPS-LADDER")
	var kit: Dictionary = WorldKit.config()["types"]
	var structures := {}
	var barracks := 0
	for p: Dictionary in DataRegistry.parse_quiet(String(def["structure_data"]))["pieces"]:
		structures[String(p["id"])] = p
		barracks += 1 if String(p["type"]) == "barracks" else 0
	var entries: Array = committed["ladders"]
	assert_eq(barracks, 12, "12 barracks blocks on the map")
	assert_eq(entries.size(), 12, "12 ladders")
	assert_eq(a["ladders"], {"ladders": 12, "blocks": 12, "first_end": 12, "other_end": 0, "none": 0}, "the generator's counts")
	var ids := {}
	var pieces := {}
	for e: Dictionary in entries:
		var id := String(e["id"])
		assert_true(not ids.has(id) and id.begins_with("Ladder_"), id + " is unique")
		ids[id] = true
		var piece: Dictionary = structures.get(String(e["piece"]), {})
		assert_eq(String(piece.get("type", "")), "barracks", id + " stands at a barracks")
		assert_true(not pieces.has(e["piece"]), "%s: one ladder per block" % e["piece"])
		pieces[e["piece"]] = true
		# In the piece's frame: the foot on the roof's edge at an end (x +-4.7, the eave in front of the end wall's
		# face at +-4.5), at the wall's middle, the climber facing into the wall, up to the roof top 3.3.
		var turn := Basis(Vector3.UP, deg_to_rad(float(piece["yaw"])))
		var foot := turn.inverse() * (LowpolyKit.vec(e["at"]) - LowpolyKit.vec(piece["at"]))
		var top := turn.inverse() * (LowpolyKit.vec(e["top"]) - LowpolyKit.vec(piece["at"]))
		assert_true(absf(absf(foot.x) - 4.7) < 0.002 and absf(foot.z) < 0.002 and absf(foot.y) < 0.002, "%s: foot at an end wall's eave, local %s" % [id, foot])
		var end := signf(foot.x)
		var facing := Basis(Vector3.UP, deg_to_rad(float(e["yaw"]))) * Vector3.FORWARD
		assert_true(facing.distance_to(turn * Vector3(-end, 0, 0)) < 0.001, "%s: the climber faces into the wall" % id)
		assert_true(is_equal_approx(float(e["height"]), 3.3) and is_equal_approx(float(e["width"]), float(gen["width_m"])), "%s: 3.3 m to the roof top, %s m wide" % [id, str(gen["width_m"])])
		assert_true(absf(top.x - end * (4.7 - float(gen["top_step_m"]))) < 0.002 and absf(top.y - 3.3) < 0.002, "%s: the top step %s m onto the roof, local %s" % [id, str(gen["top_step_m"]), top])
		# No doorway or window in that end wall.
		for o: Dictionary in kit["barracks"]["open"]:
			var oa := LowpolyKit.vec(o["at"])
			var os := LowpolyKit.vec(o["size"])
			assert_true(oa.x * end - os.x * 0.5 < 4.1 + 0.001, "%s: no opening reaches the end wall (opening at %s)" % [id, oa])
	assert_eq(WorldProps.problems(committed, WorldProps.config()), PackedStringArray(), "WorldProps.problems is clean on the committed cover file")
	print("LADDERS_1KM ladders=%d blocks=%d" % [entries.size(), barracks])


func test_generator_without_the_block_changes_nothing_else_and_fixture_maps_have_no_ladders() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	(def["generator"] as Dictionary).erase("ladders")
	var out: Dictionary = Gen.generate(def)
	assert_true(not (out["cover"] as Dictionary).has("ladders"), "no ladders block, no ladders key")
	var with_ladders: Dictionary = Gen.generate(DataRegistry.parse_quiet(MAP))
	var plain := (with_ladders["cover"] as Dictionary).duplicate()
	plain.erase("ladders")
	assert_eq(Gen.text_of(plain), Gen.text_of(out["cover"]), "the ladder pass changes nothing else in the cover file")
	assert_eq(Gen.text_of(with_ladders["structures"]), Gen.text_of(out["structures"]), "nor the structures")
	assert_eq(Gen.text_of(with_ladders["landmarks"]), Gen.text_of(out["landmarks"]), "nor the landmarks")
	assert_eq(with_ladders["spawns"], out["spawns"], "nor the spawns")
	assert_eq(int(with_ladders["cover_walls"]), int(out["cover_walls"]), "ladders are not counted as cover walls (%d)" % int(out["cover_walls"]))
	for path: String in ["res://data/maps/alesia_cover.json", "res://data/maps/test_300_cover.json"]:
		if FileAccess.file_exists(path):
			assert_true(not DataRegistry.parse_quiet(path).has("ladders"), path + ": no ladders")
	for map_path: String in ["res://data/maps/alesia_section.json", "res://data/maps/test_300.json"]:
		var m := DataRegistry.parse_quiet(map_path)
		var cover := String(m.get("cover_data", "res://data/maps/alesia_cover.json"))
		assert_true(not DataRegistry.parse_quiet(cover).has("ladders"), map_path + ": its cover file has no ladders")
		assert_true(not (m.get("generator", {}) as Dictionary).has("ladders"), map_path + ": no ladders generator block")


## The clearance check and the end-wall rules are not vacuous: a footprint in front of the first end sends the
## ladder to the other end; footprints at both ends leave the block without one (a problem naming it); an end with a
## doorway, a ladder wider than the wall and a top step off the roof are each refused.
func test_foot_clearance_and_end_wall_rules() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	var cfg: Dictionary = def["generator"]["ladders"]
	var kit: Dictionary = WorldKit.config()["types"]
	# A barracks where Castra1_Barracks_0 stands (flat ground), alone with the footprints each case adds.
	var o := Vector2(37.646, -221.674)
	var piece := {"id": "B", "type": "barracks", "at": [o.x, 0.0, o.y], "yaw": 0.0}
	var terrain := Gen.terrain_of(def)
	var run := func(rects: Array) -> Dictionary:
		var placed: Array[Rect2] = [WorldKit.footprint(kit["barracks"], Vector3(o.x, 0, o.y), 0.0)]
		for rect: Rect2 in rects:
			placed.append(Rect2(rect.position + o, rect.size))
		var s := {"gen": {"ladders": cfg}, "terrain": terrain, "problems": PackedStringArray(), "placed": placed}
		var result: Dictionary = Gen._ladders(s, [piece], kit)
		result["problems"] = s["problems"]
		return result
	var free: Dictionary = run.call([])
	assert_eq(free["counts"], {"ladders": 1, "blocks": 1, "first_end": 1, "other_end": 0, "none": 0}, "open ground: the first end")
	assert_eq(free["problems"], PackedStringArray(), "and no problem")
	assert_true(absf(float(free["entries"][0]["at"][0]) - (o.x + 4.7)) < 0.002, "at the +x end")
	var crate_east := Rect2(5.2, -0.5, 1.0, 1.0)  # 0.5 m in front of the +x end's plane
	var east: Dictionary = run.call([crate_east])
	assert_eq(east["counts"]["other_end"], 1, "a crate in front of the +x end: the ladder goes to the -x end")
	assert_true(absf(float(east["entries"][0]["at"][0]) - (o.x - 4.7)) < 0.002 and is_equal_approx(float(east["entries"][0]["yaw"]), 270.0), "at the -x end, facing +x: %s" % str(east["entries"][0]))
	var far_crate := Rect2(6.0, -0.5, 1.0, 1.0)  # 1.3 m out: past front_clear_m 1.0
	assert_eq(run.call([far_crate])["counts"]["first_end"], 1, "a crate past front_clear_m leaves the first end free")
	var side_crate := Rect2(4.8, 0.55, 0.5, 0.5)  # beside the ladder, inside side_clear_m
	assert_eq(run.call([side_crate])["counts"]["other_end"], 1, "a crate within side_clear_m of the ladder's side blocks that end")
	var both: Dictionary = run.call([crate_east, Rect2(-6.2, -0.5, 1.0, 1.0)])
	assert_eq(both["counts"]["none"], 1, "both ends blocked: no ladder")
	assert_true((both["problems"] as PackedStringArray).size() == 1 and String(both["problems"][0]).begins_with("B: no end wall can take a ladder"), "and a problem names the block: %s" % str(both["problems"]))
	# The end-wall rules on edited copies of the kit type.
	assert_true(not Gen.ladder_spot(kit["barracks"], 1.0, cfg).has("problem") and not Gen.ladder_spot(kit["barracks"], -1.0, cfg).has("problem"), "both barracks ends can take one")
	var door_end: Dictionary = kit["barracks"].duplicate(true)
	(door_end["open"] as Array).append({"at": [4.3, 1.15, 0.0], "size": [0.4, 2.3, 1.2]})
	assert_true(String(Gen.ladder_spot(door_end, 1.0, cfg).get("problem", "")).contains("opening"), "a doorway in the end wall is refused")
	var wide := cfg.duplicate(true)
	wide["width_m"] = 6.0
	assert_true(String(Gen.ladder_spot(kit["barracks"], 1.0, wide).get("problem", "")).contains("wider"), "a ladder wider than the wall is refused")
	var long_step := cfg.duplicate(true)
	long_step["top_step_m"] = 9.0
	assert_true(String(Gen.ladder_spot(kit["barracks"], 1.0, long_step).get("problem", "")).contains("roof"), "a top step off the roof is refused")


# ---- The body ----

func test_body_layer_mask_groups_and_shape() -> void:
	var l := Ladder.make(_entry("Ladder_900", Vector3(1, 0, 2), 90.0), _cfg())
	assert_true(l.is_in_group(Ladder.GROUP) and not l.is_in_group(&"cover_wall") and not l.is_in_group(&"structure"), "group ladder only, never cover_wall")
	assert_true(l is Area3D and l.collision_layer == 0 and l.collision_mask == Ladder.PAWN_MASK, "an Area3D on layer 0 (not Hitscan.MASK_WORLD), noticing pawns (mask 2)")
	assert_true(l.monitoring and not l.monitorable, "monitors pawns, is never itself found")
	assert_true((l.collision_layer & Hitscan.MASK_WORLD) == 0, "not on MASK_WORLD")
	var shape := (l.get_node("Shape") as CollisionShape3D).shape as BoxShape3D
	var c := _cfg()
	assert_true(shape.size.is_equal_approx(Vector3(0.6, 3.3 + float(c["rail_above_m"]), float(c["reach_m"]) + float(c["top_reach_m"]))), "the trigger box: width x (height + rail) x (reach + top reach): %s" % shape.size)
	assert_true(l.get_node("Look") is MeshInstance3D and (l.get_node("Look") as MeshInstance3D).mesh != null, "a grey-box look")
	assert_true(l.into_dir().is_equal_approx(Vector3.LEFT), "yaw 90: into the wall = -x")
	assert_true(l.climb_point(1.0).is_equal_approx(Vector3(1.0 + float(c["climb_offset_m"]), 1.0, 2.0)), "the climb line climb_offset_m out: %s" % l.climb_point(1.0))
	assert_true(l.top_point().is_equal_approx(Vector3(0.3, 3.3 + Ladder.TOP_LIFT_M, 2.0)), "the top point from the entry: %s" % l.top_point())
	l.free()


func test_the_trigger_blocks_no_shot_and_no_bot_sight() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var back := _box(root, Vector3(0, 1.5, -4.0), Vector3(6, 3, 0.4))
	var ladder := Ladder.make(_entry("Ladder_901", Vector3(0, 0, 0.5), 0.0), _cfg())
	root.add_child(ladder)
	await _tree().physics_frame
	await _tree().physics_frame
	var space := root.get_world_3d().direct_space_state
	var rifle := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	var eye := Vector3(0, 1.6, 3.0)
	var none: Array[RID] = []
	var shot := Hitscan.cast(space, eye, Vector3.FORWARD, rifle, none)
	assert_true(shot.get("collider") == back, "a shot through the trigger hits the wall behind it")
	var sight := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, Vector3(0, 1.2, -3.5), Hitscan.MASK_WORLD))
	assert_true(sight.is_empty(), "the bots' sight query passes the trigger")
	var any := PhysicsRayQueryParameters3D.create(eye, Vector3(0, 1.6, -4.5), 0xFFFFFFFF)
	any.collide_with_areas = true
	var hit := space.intersect_ray(any)
	assert_true(hit.get("collider") == back, "even an every-layer ray with areas meets the wall, not the trigger: %s" % str(hit.get("collider")))
	var probe := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new()
	ball.radius = 0.5
	probe.shape = ball
	probe.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0.6))  # inside the trigger box
	probe.collision_mask = 0xFFFFFFFF
	probe.collide_with_areas = true
	assert_true(space.intersect_shape(probe).is_empty(), "a shape query inside the trigger finds nothing (layer 0)")
	root.free()


## Bakes a 30 m ground with one ladder (the 1 km scene's NavigationMesh settings): "none", "props" (under a Props
## sibling of Nav) or "nav" (under Nav: an area is no static collider, so even there it is not parsed). [polygons,
## vertices].
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
		(nav if where == "nav" else props).add_child(Ladder.make(_entry("Ladder_960", Vector3(0, 0, 0), 0.0), _cfg()))
	_tree().root.add_child(root)
	await _tree().physics_frame
	nav.bake_navigation_mesh(false)
	var out := [mesh.get_polygon_count(), mesh.get_vertices().size()]
	root.free()
	return out


func test_a_ladder_does_not_change_the_bake() -> void:
	var none: Array = await _bake("none")
	var props: Array = await _bake("props")
	var under: Array = await _bake("nav")
	assert_true(int(none[0]) > 0, "nonvacuous: the ground bakes (%d polygons)" % int(none[0]))
	assert_eq(props, none, "a ladder under the Props sibling leaves the mesh as without it")
	assert_eq(under, none, "a ladder even under Nav leaves it unchanged (an area is not parsed)")
	print("LADDER_NAV none=", none, " props=", props, " under_nav=", under)
