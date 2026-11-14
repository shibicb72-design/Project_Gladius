extends "res://tests/test_case.gd"
## M2L1 stage A: the 1 km Alesia grey-box as DATA (no 1 km scene is built here; tests/test_alesia_1km.gd builds it
## once). The generator (tools/gen_alesia.gd) is deterministic and its committed output unchanged, heights and
## paint included; the polygonal wall rings close (joint gaps at most 0.3 m on both face lines) and only wall
## types take a free yaw; the reserved J1 spots validate and bad ones are rejected; a binary heights file is
## validated from its header only; flat maps paint exactly as before through the new per-map paint code path.

const _Gen := preload("res://tools/gen_alesia.gd")
const MAP := "res://data/maps/alesia_1km.json"
const ALESIA := "res://data/maps/alesia_section.json"
const TEST_300 := "res://data/maps/test_300.json"
const TMP_DIR := "user://l1_alesia_tmp/"
## sha256 of test_300's paint bytes, measured before M2L1 changed ground_paint.gd (480 px).
const TEST_300_PAINT_SHA := "1069c5ea0c1c40bbcfa35e3bae4b5f721cb28b2495738607f3d7d09327035bff"


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


func _file_text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _write(name: String, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var path := TMP_DIR + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func _clean() -> void:
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)


func _ring(prefix: String) -> Array:
	var out: Array = []
	for entry: Dictionary in DataRegistry.parse_quiet(String(_def()["structure_data"]))["pieces"]:
		if String(entry["id"]).begins_with(prefix):
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out


func test_generator_is_deterministic_and_matches_the_files() -> void:
	var def := _def()
	assert_true(bool(def["_placeholder"]) and String(def["_todo"]).contains("OQ-ALESIA-LAYOUT"), "the map is a placeholder proposal (OQ-ALESIA-LAYOUT)")
	assert_true(bool(def["generator"]["_placeholder"]) and String(def["generator"]["_todo"]).contains("OQ-ALESIA-LAYOUT"), "the generator numbers are proposals")
	var started := Time.get_ticks_msec()
	var a: Dictionary = _Gen.generate(def)
	var gen_ms := Time.get_ticks_msec() - started
	var b: Dictionary = _Gen.generate(def)
	for key: String in ["cover", "structures", "landmarks"]:
		assert_eq(_Gen.text_of(a[key]), _Gen.text_of(b[key]), key + ": two runs give the same file")
	assert_true((a["problems"] as PackedStringArray).is_empty(), "the generator reports no problem: " + ", ".join(a["problems"]))
	assert_true((a["shortfalls"] as PackedStringArray).is_empty(), "every target count is placed: " + ", ".join(a["shortfalls"]))
	# Byte-identical committed files: the tool writes exactly text_of().
	assert_eq(_Gen.text_of(a["cover"]), _file_text(String(def["cover_data"])), "the committed cover file is the generator's output")
	assert_eq(_Gen.text_of(a["structures"]), _file_text(String(def["structure_data"])), "the committed structures file is the generator's output")
	assert_eq(_Gen.text_of(a["landmarks"]), _file_text(String(def["landmarks"])), "the committed landmarks file is the generator's output")
	# The map json's derived keys (the tool writes them; round-tripped like the file).
	assert_eq(JSON.stringify(a["spawns"]), JSON.stringify(JSON.parse_string(JSON.stringify(def["spawns"]))), "spawns are the generator's")
	assert_eq(JSON.stringify(JSON.parse_string(JSON.stringify(a["reserved_spots"]))), JSON.stringify(def["reserved_spots"]), "reserved_spots are the generator's")
	assert_eq(_Gen.text_of(def), _file_text(MAP), "the map json is in the tool's format (rerun the tool after a hand edit)")
	# Heights: regenerated in memory and compared with the committed binary file, sample for sample.
	var terrain: MapTerrain = a["terrain"]
	var committed := MapTerrain.from_block(def["terrain"], def)
	assert_true(committed != null and committed.samples == 501, "the committed heights load: 501 x 501")
	if committed != null:
		assert_true(committed.heights == terrain.heights, "the committed heights are the generator's")
	assert_eq(_Gen.sha256(terrain.heights.to_byte_array()), String(def["generator"]["heights_sha256"]), "heights_sha256 is current")
	# Paint: regenerated (about 1 s on the desktop) and compared with the committed bake.
	var paint_from := Time.get_ticks_msec()
	var paint: Dictionary = _Gen.paint_of(def, a)
	var paint_ms := Time.get_ticks_msec() - paint_from
	var settings := GroundPaint.settings_for(def)
	var baked := ResourceLoader.load(String(settings["baked"]), "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	assert_true(baked != null, "the baked paint is an Image resource")
	if baked != null:
		assert_eq(_Gen.sha256(baked.get_data()), _Gen.sha256((paint["image"] as Image).get_data()), "the committed paint is the generator's")
		assert_eq(String(baked.get_meta(&"inputs_sha256", "")), String(paint["hash"]), "the bake carries its inputs hash")
	assert_eq(_Gen.sha256((paint["image"] as Image).get_data()), String(def["generator"]["paint_sha256"]), "paint_sha256 is current")
	assert_true(String(settings["baked"]).ends_with(".res"), "the paint is a .res, never a PNG")
	print("ALESIA_1KM_GEN counts=", _Gen.counts_of(a), " gen_ms=", gen_ms, " paint_ms=", paint_ms, " max_joint_gap_m=", a["max_joint_gap_m"])


func test_wall_rings_close_and_only_walls_turn_freely() -> void:
	var kit: Dictionary = WorldKit.config()["types"]
	var gen: Dictionary = _def()["generator"]
	var limit := float(gen["wall"]["max_joint_gap_m"])
	assert_eq(limit, 0.3, "the joint bound is 0.3 m")
	for prefix: String in ["InnerRing_", "OuterRing_"]:
		var ring := _ring(prefix)
		assert_true(ring.size() > 50, "%s: nonvacuous (%d pieces)" % [prefix, ring.size()])
		var worst := 0.0
		var joints: Array = _Gen.joint_gaps(ring, kit, float(gen["wall"]["half_thickness_m"]))
		assert_eq(joints.size(), ring.size(), prefix + ": one joint per piece (the ring closes)")
		for joint: Dictionary in joints:
			worst = maxf(worst, maxf(float(joint["inner"]), float(joint["outer"])))
			assert_true(float(joint["inner"]) <= limit and float(joint["outer"]) <= limit, "%s/%s: joint gap inner %.3f outer %.3f m" % [joint["a"], joint["b"], joint["inner"], joint["outer"]])
		# Nonvacuous: take out one wall piece in the middle of a run (pieces overlap, so only a real hole shows) and
		# the measure sees the opening; turn a corner piece by 20 degrees and it sees that too.
		var holed := ring.duplicate(true)
		holed.remove_at(2)
		var opened := 0.0
		for joint: Dictionary in _Gen.joint_gaps(holed, kit, float(gen["wall"]["half_thickness_m"])):
			opened = maxf(opened, maxf(float(joint["inner"]), float(joint["outer"])))
		assert_true(opened > 3.0, "%s: a missing piece opens a joint (%.3f m)" % [prefix, opened])
		# And at a corner: the first piece of a side pulled 4 m along its side, away from the corner.
		var pulled := ring.duplicate(true)
		var first: Dictionary = pulled[0]
		var back := Basis(Vector3.UP, deg_to_rad(float(first["yaw"]))) * Vector3(4.0, 0.0, 0.0)  # past the overlap
		first["at"] = [float(first["at"][0]) + back.x, 0.0, float(first["at"][2]) + back.z]
		var corner := 0.0
		for joint: Dictionary in _Gen.joint_gaps(pulled, kit, float(gen["wall"]["half_thickness_m"])):
			if String(joint["b"]) == String(first["id"]):
				corner = maxf(float(joint["inner"]), float(joint["outer"]))
		assert_true(corner > limit, "%s: a corner piece pulled back opens the corner joint (%.3f m)" % [prefix, corner])
		var types := {}
		for entry: Dictionary in ring:
			types[entry["type"]] = int(types.get(entry["type"], 0)) + 1
			assert_true(DataRegistry.FREE_YAW_ALLOWED.has(entry["type"]), String(entry["id"]) + ": a ring piece is a wall type")
		var cfg: Dictionary = gen["inner_wall"] if prefix == "InnerRing_" else gen["outer_wall"]
		assert_eq(int(types.get("gate", 0)), (cfg["gate_bearings_deg"] as Array).size(), prefix + ": gates")
		assert_eq(int(types.get("watchtower", 0)), (cfg["tower_bearings_deg"] as Array).size(), prefix + ": towers")
		assert_true(int(types.get("wall_stair", 0)) >= 8, prefix + ": stairs up to the wall walk (%d)" % int(types.get("wall_stair", 0)))
		print("ALESIA_1KM_RING ", prefix, " pieces=", ring.size(), " types=", types, " max_joint_gap_m=", snappedf(worst, 0.0001))
	# Free yaw only on wall types; every other structure keeps the 90 degree step.
	var step := float(WorldKit.config()["rules"]["yaw_step_deg"])
	var free_turns := 0
	for entry: Dictionary in DataRegistry.parse_quiet(String(_def()["structure_data"]))["pieces"]:
		var off := fposmod(float(entry["yaw"]), step)
		if minf(off, step - off) > 0.0001:
			free_turns += 1
			assert_true(DataRegistry.FREE_YAW_ALLOWED.has(entry["type"]), String(entry["id"]) + ": only wall types take a free yaw")
	assert_true(free_turns > 100, "nonvacuous: %d free yaws" % free_turns)
	var def := _def()
	assert_eq(DataRegistry.yaw_problems(def).size(), 0, "the map's yaws are clean: " + ", ".join(DataRegistry.yaw_problems(def)))
	var no_permission := def.duplicate(true)
	no_permission.erase("free_yaw_types")
	assert_true(DataRegistry.yaw_problems(no_permission).size() > 100, "without free_yaw_types the turned walls are reported")
	var tent_free := def.duplicate(true)
	tent_free["free_yaw_types"].append("tent")
	assert_true(", ".join(DataRegistry.yaw_problems(tent_free)).contains("'tent'"), "a non-wall type cannot be given a free yaw")


func test_reserved_spots_validate_and_bad_ones_are_rejected() -> void:
	var def := _def()
	assert_eq(DataRegistry.validate_map_def(def).size(), 0, "alesia_1km is clean: " + ", ".join(DataRegistry.validate_map_def(def)))
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(MAP).size(), 0, "validate_map is clean: " + ", ".join(reg.validate_map(MAP)))
	var kinds := {}
	for spot: Dictionary in def["reserved_spots"]:
		kinds[spot["kind"]] = int(kinds.get(spot["kind"], 0)) + 1
	assert_true(int(kinds.get("jump_pad", 0)) >= 8 and int(kinds.get("jump_pad", 0)) <= 12, "8-12 jump pads (%d)" % int(kinds.get("jump_pad", 0)))
	assert_true(int(kinds.get("man_cannon", 0)) >= 4 and int(kinds.get("man_cannon", 0)) <= 6, "4-6 man cannons (%d)" % int(kinds.get("man_cannon", 0)))
	assert_true(int(kinds.get("lily_trap", 0)) >= 12 and int(kinds.get("lily_trap", 0)) <= 20, "12-20 lily traps (%d)" % int(kinds.get("lily_trap", 0)))
	var wall: Dictionary = _ring("OuterRing_")[0]
	var bad := {
		"unknown kind": [{"id": "x", "kind": "teleporter", "at": [400, 0]}, "kind 'teleporter'"],
		"outside the circle": [{"id": "x", "kind": "jump_pad", "at": [470, 200]}, "outside the play circle"],
		"inside a collider": [{"id": "x", "kind": "lily_trap", "at": [float(wall["at"][0]), float(wall["at"][2])]}, "inside the collider of " + String(wall["id"])],
		"inside a turned wall's end": [{"id": "x", "kind": "lily_trap", "at": [0, 0]}, ""],
		"bad at": [{"id": "x", "kind": "lily_trap", "at": [1]}, "[x, z] numbers"],
	}
	# A point 3.9 m along a turned outer wall piece from its centre (inside its 8 m) is inside; 4.3 m is not.
	var yaw := deg_to_rad(float(wall["yaw"]))
	var along := Basis(Vector3.UP, yaw) * Vector3.RIGHT
	var near_end := Vector2(float(wall["at"][0]) + along.x * 3.9, float(wall["at"][2]) + along.z * 3.9)
	bad["inside a turned wall's end"] = [{"id": "x", "kind": "lily_trap", "at": [near_end.x, near_end.y]}, "inside the collider of"]
	for label: String in bad:
		var copy := def.duplicate(true)
		copy["reserved_spots"] = [bad[label][0]]
		var problems := DataRegistry.reserved_spot_problems(copy)
		assert_true(problems.size() == 1 and problems[0].contains(bad[label][1]), "%s is reported: %s" % [label, ", ".join(problems)])
	var dup := def.duplicate(true)
	dup["reserved_spots"] = [def["reserved_spots"][0], def["reserved_spots"][0]]
	assert_true(", ".join(DataRegistry.reserved_spot_problems(dup)).contains("not unique"), "a duplicate id is reported")
	var no_radius := def.duplicate(true)
	no_radius.erase("play_radius_m")
	assert_true(DataRegistry.reserved_spot_problems(no_radius).size() == 1, "spots need a play radius")
	var past_end := Vector2(float(wall["at"][0]) + along.x * 30.0, float(wall["at"][2]) + along.z * 30.0) - Vector2(float(wall["at"][0]), float(wall["at"][2])).normalized() * 6.0
	var open := def.duplicate(true)
	open["reserved_spots"] = [{"id": "x", "kind": "jump_pad", "at": [past_end.x, past_end.y]}]
	assert_eq(DataRegistry.reserved_spot_problems(open).size(), 0, "open ground 6 m inside the wall is clean")
	# The other maps carry no spots: still clean.
	for path: String in [ALESIA, TEST_300]:
		assert_eq(DataRegistry.reserved_spot_problems(DataRegistry.parse_quiet(path)).size(), 0, path + ": no spots, no problem")
		assert_eq(DataRegistry.yaw_problems(DataRegistry.parse_quiet(path)).size(), 0, path + ": 90 degree yaws")


func test_landmarks_spawns_and_scene() -> void:
	var def := _def()
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var ids := {}
	var footprints := DataRegistry.collider_footprints(def)
	var terrain := MapTerrain.from_block(def["terrain"], def)
	for landmark: Dictionary in landmarks:
		ids[landmark["id"]] = true
		var at := Vector2(float(landmark["at"][0]), float(landmark["at"][1]))
		var anchor := LowpolyKit.vec(landmark["anchor"])
		assert_true(Vector2(anchor.x, anchor.z).distance_to(at) <= float(landmark["radius_m"]), String(landmark["id"]) + ": anchor inside the place")
		assert_eq(DataRegistry.footprint_at(Vector2(anchor.x, anchor.z), footprints), "", String(landmark["id"]) + ": anchor on open ground")
		assert_true(absf(anchor.y - terrain.height_at(anchor.x, anchor.z)) < 0.002, String(landmark["id"]) + ": anchor y on the terrain")
		for other: Dictionary in landmarks:
			if other != landmark:
				assert_true(at.distance_to(Vector2(float(other["at"][0]), float(other["at"][1]))) >= float(landmark["radius_m"]) + float(other["radius_m"]), "%s and %s do not share ground" % [landmark["id"], other["id"]])
	for id: String in ["arx", "porta_aquilae", "porta_solis", "porta_martis", "porta_lunae", "castra_prima", "castra_sexta", "aquaeductus_magnus", "specula"]:
		assert_true(ids.has(id), "landmark " + id)
	var spawns: Dictionary = def["spawns"]
	assert_eq(spawns.size(), 6, "6 fallback spawns")
	var scene: Node = load(String(def["scene"])).instantiate()
	for id: String in spawns:
		var p := LowpolyKit.vec(spawns[id])
		var flat := Vector2(p.x, p.z)
		assert_true(flat.length() > float(def["generator"]["fields"]["from_m"]) and flat.length() < float(def["play_radius_m"]), id + ": on the outer fields")
		assert_eq(DataRegistry.footprint_at(flat, footprints), "", id + ": on open ground")
		assert_true(is_zero_approx(terrain.height_at(p.x, p.z)), id + ": on flat ground")
		var marker := scene.get_node_or_null("SquadSpawns/" + id) as Marker3D
		assert_true(marker != null and marker.position.distance_to(p) < 0.01, id + ": a scene marker at the json spawn")
	assert_eq(scene.get_node("SquadSpawns").get_child_count(), 6, "one marker per spawn")
	assert_eq(scene.get_node("ArtBuilder").get("map_json"), MatchRoot.MAP_PATH, "the scene names no map of its own (MatchRoot hands it the map)")
	var ground := scene.get_node("Nav/Ground") as StaticBody3D
	assert_true(ground != null and ground.get_child_count() == 0, "an empty Nav/Ground for the builder's height map")
	# The navigation settings are the other maps' (stage B bakes): every agent and cell value equal to test_300's.
	var other: Node = load("res://scenes/maps/test_300.tscn").instantiate()
	var mine := (scene.get_node("Nav") as NavigationRegion3D).navigation_mesh
	var theirs := (other.get_node("Nav") as NavigationRegion3D).navigation_mesh
	for prop: Dictionary in mine.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_STORAGE and not String(prop["name"]).begins_with("resource_"):
			assert_eq(mine.get(prop["name"]), theirs.get(prop["name"]), "navigation mesh %s as test_300" % prop["name"])
	print("ALESIA_1KM_NAV agent_max_slope=", mine.agent_max_slope, " agent_height=", mine.agent_height, " agent_radius=", mine.agent_radius, " cell_size=", mine.cell_size)
	scene.free()
	other.free()


func test_heights_header_only_validation() -> void:
	var def := _def()
	var path := String(def["terrain"]["height_source"]["path"])
	var t0 := Time.get_ticks_usec()
	var head := MapTerrain.res_header(path)
	var header_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var shape := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as HeightMapShape3D
	var load_us := Time.get_ticks_usec() - t0
	assert_true(not head.has("problem"), "the header reads: " + str(head))
	assert_eq(int(head.get("map_width", 0)), shape.map_width, "header map_width")
	assert_eq(int(head.get("map_depth", 0)), shape.map_depth, "header map_depth")
	assert_eq(int(head.get("map_data", 0)), shape.map_data.size(), "header sample count")
	assert_eq(float(head.get("size_m", 0)), float(shape.get_meta(&"size_m")), "header size_m")
	assert_eq(float(head.get("resolution_m", 0)), float(shape.get_meta(&"resolution_m")), "header resolution_m")
	assert_eq(MapTerrain.heights_header_problem(path, 1000.0, 2.0), "", "the committed heights fit the block")
	assert_eq(DataRegistry.validate_terrain(def["terrain"], def).size(), 0, "validate_terrain is clean")
	# Bad binary files are caught from the header.
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var small := MapTerrain.new()
	small.size_m = 20.0
	small.resolution_m = 2.0
	small.samples = 11
	small.heights.resize(121)
	var cases := {
		"good": [small, 20.0, 2.0, ""],
		"other size": [small, 22.0, 2.0, "is 20"],
		"other resolution": [small, 20.0, 1.0, "at 2"],
	}
	# A HeightMapShape3D keeps map_data at width x depth, so a short grid is one row short (11 x 10).
	var short := HeightMapShape3D.new()
	short.map_width = 11
	short.map_depth = 10
	short.set_meta(&"size_m", 20.0)
	short.set_meta(&"resolution_m", 2.0)
	cases["one row short"] = [short, 20.0, 2.0, "has 110 samples (11 x 10)"]
	var i := 0
	for label: String in cases:
		var c: Array = cases[label]
		var file := TMP_DIR + "h%d.res" % i
		i += 1
		var saved: Error = ResourceSaver.save(c[0], file) if c[0] is HeightMapShape3D else MapTerrain.save_heights(c[0], file)
		assert_eq(saved, OK, label + ": saved")
		var problem := MapTerrain.heights_header_problem(file, c[1], c[2])
		if String(c[3]) == "":
			assert_eq(problem, "", label + ": fits")
		else:
			assert_true(problem.contains(c[3]), "%s: the header says '%s': %s" % [label, c[3], problem])
			# The full read agrees with the header.
			assert_true(MapTerrain.heights_file_problem(file, c[1], c[2]) != "", label + ": the full read agrees")
	var junk := _write("junk.res", "not a resource")
	assert_true(MapTerrain.heights_header_problem(junk, 20.0, 2.0).contains("not an uncompressed binary resource"), "a non-resource is reported")
	_clean()
	print("ALESIA_1KM_HEIGHTS header_us=", header_us, " full_load_us=", load_us, " samples=", shape.map_data.size())


func test_ground_paint_follows_the_rings_and_flat_maps_are_unchanged() -> void:
	var def := _def()
	var g: Dictionary = WorldSurface.config()["ground"]
	var own: Dictionary = def["ground_paint"]
	for key: String in own:
		assert_true(key.begins_with("_") or g.has(key) or key in ["roads", "baked"], "ground_paint key %s is an art_materials ground key, roads or baked" % key)
	var gen: Dictionary = def["generator"]
	assert_eq(float(own["citadel_paving_m"]), float(gen["hill"]["radius_m"]), "the citadel (the hill) is paved")
	assert_true(float(own["ring_road_radius_m"]) < float(gen["inner_wall"]["radius_m"]) - 2.0 and float(own["ring_road_radius_m"]) > float(gen["hill"]["radius_m"]), "the ring road runs inside the inner wall")
	assert_true(float(own["grass_from_m"]) > float(gen["outer_wall"]["radius_m"]) and float(own["grass_full_m"]) <= float(gen["fields"]["from_m"]) + 5.0, "grass starts past the outer wall (the camp ring stays earth)")
	assert_true(not bool(own["roads"]), "no spokes")
	var settings := GroundPaint.settings_for(def)
	assert_eq(GroundPaint.px_for(1000.0, settings), 1024, "1 km paints 1024 px")
	assert_true(GroundPaint.px_for(1000.0, settings) <= int(g["paint_px_cap"]), "under the cap")
	assert_eq(float(settings["cover_trodden_m"]), float(g["cover_trodden_m"]), "keys the map leaves out come from the global block")
	# Flat maps: no ground_paint key, so the global dictionary itself (the exact old numbers and code path).
	for path: String in [ALESIA, TEST_300]:
		assert_true(is_same(GroundPaint.settings_for(DataRegistry.parse_quiet(path)), g), path + ": the global paint numbers")
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load("res://scenes/maps/test_300.tscn").instantiate()
	map.get_node("ArtBuilder").set("map_json", TEST_300)
	tree.root.add_child(map)
	var image: Image = map.get_node("ArtBuilder").ground_paint
	assert_true(image != null and image.get_width() == 480, "test_300 paints 480 px")
	if image != null:
		assert_eq(_Gen.sha256(image.get_data()), TEST_300_PAINT_SHA, "test_300 paint bytes unchanged")
	map.free()
	# A stale or missing bake is reported by baked_problem (the builder prints that one line and paints instead).
	var baked := String(settings["baked"])
	assert_eq(GroundPaint.baked_problem(baked, 1024, "not the hash"), "baked paint '%s' is stale (its inputs changed)" % baked, "a stale bake is named")
	assert_true(GroundPaint.baked_problem("res://data/maps/none.res", 1024, "").contains("missing"), "a missing bake is named")
	assert_true(GroundPaint.baked_problem(baked, 512, "").contains("not an RGBA8 image of 512 px"), "a bake of another size is named")
	assert_true(GroundPaint.load_baked("l1_test_stale", baked, 1024, "not the hash") == null, "a stale bake does not load")
