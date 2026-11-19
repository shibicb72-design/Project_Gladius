extends "res://tests/test_case.gd"
## M2 L2a: the 500 m Alesia (data/maps/alesia_500.json, OQ-ALESIA-500 placeholders) as DATA, no scene. The generator
## (tools/gen_alesia.gd -- --map=alesia_500) is deterministic and its committed output is unchanged (heights and
## paint included); the map validates; the three wall rings close; the town, camp and farmstead pieces keep their
## gaps and the barracks doorways their aprons; doors and ladders follow the id patterns; the landmarks and reserved
## spots stand on open ground. The 1 km map's byte identity is pinned by tests/test_alesia_1km_data.gd
## (test_generator_is_deterministic_and_matches_the_files), which runs generate() on alesia_1km after this change.

const _Gen := preload("res://tools/gen_alesia.gd")
const MAP := "res://data/maps/alesia_500.json"


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


## The file's text with every "\r" removed (a CRLF checkout compares equal to the tool's LF output).
func _file_text(path: String) -> String:
	return FileAccess.get_file_as_string(path).replace("\r", "")


func test_map_validates_and_is_a_placeholder() -> void:
	var def := _def()
	assert_eq(String(def.get("id", "")), "alesia_500", "the map's id")
	assert_eq(float(def["play_radius_m"]), 240.0, "play radius 240 m")
	assert_eq(float(def["terrain"]["size_m"]), 500.0, "a 500 m ground")
	assert_true(bool(def["_placeholder"]) and String(def["_todo"]).contains("OQ-ALESIA-500"), "the map is a placeholder (OQ-ALESIA-500)")
	assert_true(String(def["generator"]["_todo"]).contains("OQ-ALESIA-500"), "the generator numbers are placeholders")
	var problems := DataRegistry.new().validate_map(MAP)
	assert_eq(problems.size(), 0, "alesia_500 validates: " + ", ".join(problems))
	assert_eq(float(def["overrides"]["br"]["zone"]["start_radius_m"]), 240.0, "the zone starts on the play circle")
	assert_true((def["overrides"]["br"]["zone"]["phases"] as Array).size() == (def["zone_gen"]["phases"] as Array).size(), "the zone phases are gen_zone's")


func test_generator_is_deterministic_and_matches_the_files() -> void:
	var def := _def()
	var a: Dictionary = _Gen.generate(def)
	var b: Dictionary = _Gen.generate(def)
	for key: String in ["cover", "structures", "landmarks"]:
		assert_eq(_Gen.text_of(a[key]), _Gen.text_of(b[key]), key + ": two runs give the same file")
	assert_true((a["problems"] as PackedStringArray).is_empty(), "the generator reports no problem: " + ", ".join(a["problems"]))
	assert_eq(_Gen.text_of(a["cover"]), _file_text(String(def["cover_data"])), "the committed cover file is the generator's output")
	assert_eq(_Gen.text_of(a["structures"]), _file_text(String(def["structure_data"])), "the committed structures file is the generator's output")
	assert_eq(_Gen.text_of(a["landmarks"]), _file_text(String(def["landmarks"])), "the committed landmarks file is the generator's output")
	assert_eq(JSON.stringify(JSON.parse_string(JSON.stringify(a["reserved_spots"]))), JSON.stringify(def["reserved_spots"]), "reserved_spots are the generator's")
	assert_eq(_Gen.text_of(def), _file_text(MAP), "the map json is in the tool's format (rerun the tool after a hand edit)")
	var terrain: MapTerrain = a["terrain"]
	var committed := MapTerrain.from_block(def["terrain"], def)
	assert_true(committed != null and committed.samples == 251, "the committed heights load: 251 x 251")
	if committed != null:
		assert_true(committed.heights == terrain.heights, "the committed heights are the generator's")
	assert_eq(_Gen.sha256(terrain.heights.to_byte_array()), String(def["generator"]["heights_sha256"]), "heights_sha256 is current")
	var paint: Dictionary = _Gen.paint_of(def, a)
	var settings := GroundPaint.settings_for(def)
	var baked := ResourceLoader.load(String(settings["baked"]), "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	assert_true(baked != null, "the baked paint is an Image resource")
	if baked != null:
		assert_eq(_Gen.sha256(baked.get_data()), _Gen.sha256((paint["image"] as Image).get_data()), "the committed paint is the generator's")
	assert_eq(_Gen.sha256((paint["image"] as Image).get_data()), String(def["generator"]["paint_sha256"]), "paint_sha256 is current")
	assert_true(int(a["cover_walls"]) <= int(def["generator"]["max_cover_walls"]), "cover walls %d within max_cover_walls" % int(a["cover_walls"]))
	print("ALESIA_500_GEN counts=", _Gen.counts_of(a), " cover_walls=", a["cover_walls"], " max_joint_gap_m=", a["max_joint_gap_m"], " shortfalls=", a["shortfalls"])


func test_rings_close() -> void:
	var kit: Dictionary = WorldKit.config()["types"]
	var gen: Dictionary = _def()["generator"]
	var pieces: Array = DataRegistry.parse_quiet(String(_def()["structure_data"]))["pieces"]
	for prefix: String in ["ArxRing_", "InnerRing_", "OuterRing_"]:
		var ring: Array = pieces.filter(func(e: Dictionary) -> bool: return String(e["id"]).begins_with(prefix))
		assert_true(ring.size() >= 16, "%s: nonvacuous (%d pieces)" % [prefix, ring.size()])
		for joint: Dictionary in _Gen.joint_gaps(ring, kit, float(gen["wall"]["half_thickness_m"])):
			assert_true(maxf(float(joint["inner"]), float(joint["outer"])) <= float(gen["wall"]["max_joint_gap_m"]), "%s/%s: joint gap %.3f / %.3f m" % [joint["a"], joint["b"], joint["inner"], joint["outer"]])
		var cfg: Dictionary = gen[{"ArxRing_": "arx_wall", "InnerRing_": "inner_wall", "OuterRing_": "outer_wall"}[prefix]]
		assert_eq(ring.filter(func(e: Dictionary) -> bool: return e["type"] == "gate").size(), (cfg["gate_bearings_deg"] as Array).size(), prefix + ": gates")
		assert_eq(ring.filter(func(e: Dictionary) -> bool: return e["type"] == "watchtower").size(), (cfg["tower_bearings_deg"] as Array).size(), prefix + ": towers")
	# The Arx ring stays on the hill's flat top.
	var top := float(gen["hill"]["top_radius_m"])
	for entry: Dictionary in pieces:
		if String(entry["id"]).begins_with("ArxRing_"):
			var rect := WorldKit.footprint(kit[entry["type"]], LowpolyKit.vec(entry["at"]), float(entry["yaw"]))
			assert_true(rect.get_center().length() + 1.2 < top, "%s stands on the flat top" % entry["id"])


## Every laid-out piece (town, farmsteads, camp barracks and tents) keeps placement.minimum_gap_m from every other
## footprint; no footprint stands on a barracks doorway's apron; every piece stands on fit ground.
func test_laid_out_pieces_keep_gaps_and_doorways() -> void:
	var def := _def()
	var gen: Dictionary = def["generator"]
	var out: Dictionary = _Gen.generate(def)
	var kit: Dictionary = WorldKit.config()["types"]
	var cover_types: Dictionary = DataRegistry.parse_quiet(_Gen.COVER_TYPES)["types"]
	var gap := float(gen["placement"]["minimum_gap_m"])
	var terrain: MapTerrain = out["terrain"]
	var rects: Array = []  # [id, Rect2]
	for entry: Dictionary in out["structures"]["pieces"]:
		rects.append([String(entry["id"]), WorldKit.footprint(kit[entry["type"]], LowpolyKit.vec(entry["at"]), float(entry["yaw"]))])
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Dictionary in out["cover"][list]:
			rects.append([String(entry["id"]), _Gen._box_rect(Vector2(float(entry["at"][0]), float(entry["at"][2])), LowpolyKit.vec(cover_types[entry["type"]]["size"]), 0.0)])
	for entry: Dictionary in out["cover"]["breakables"]:
		rects.append([String(entry["id"]), _Gen._box_rect(Vector2(float(entry["at"][0]), float(entry["at"][2])), LowpolyKit.vec(entry["size"]), 0.0)])
	var laid := 0
	for r: Array in rects:
		var id := String(r[0])
		if not (id.begins_with("Oppidum") or id.begins_with("Villa")):
			continue
		laid += 1
		for other: Array in rects:
			if other[0] != id:
				assert_true(WorldRing.rect_gap(r[1], other[1]) >= gap - 0.001, "%s keeps %.1f m from %s (%.2f)" % [id, gap, other[0], WorldRing.rect_gap(r[1], other[1])])
	assert_true(laid > 100, "nonvacuous: %d laid-out structure pieces" % laid)
	var openings: Array = gen["doors"]["door"]["openings"]
	var aprons := 0
	for entry: Dictionary in out["structures"]["pieces"]:
		var indices: Array = openings if entry["type"] == "barracks" else kit[entry["type"]].get("doorway_indices", [])
		for apron: Rect2 in _Gen.doorway_aprons(entry, kit, indices, float(gen["doorway_apron_m"])):
			aprons += 1
			for other: Array in rects:
				if other[0] != entry["id"]:
					assert_true(not apron.intersects(other[1]), "%s: %s stands on a doorway apron %s" % [entry["id"], other[0], apron])
	assert_true(aprons > 100, "nonvacuous: %d doorway aprons" % aprons)
	for entry: Dictionary in out["structures"]["pieces"]:
		var at := Vector2(float(entry["at"][0]), float(entry["at"][2]))
		var rect := WorldKit.footprint(kit[entry["type"]], LowpolyKit.vec(entry["at"]), float(entry["yaw"]))
		assert_true(_Gen._GenTest.ground_fits(terrain, at, rect), "%s stands on fit ground" % entry["id"])


func test_town_landmarks_doors_and_ladders() -> void:
	var def := _def()
	var gen: Dictionary = def["generator"]
	var out: Dictionary = _Gen.generate(def)
	var l500: Dictionary = out["l500"]
	var cells: Array = l500["cells"]
	assert_true(cells.size() >= 24 and cells.size() <= 36, "about 30 town cells (%d)" % cells.size())
	var counts: Dictionary = l500["town_counts"]
	for name: String in ["forum", "taberna", "templum", "thermae"]:
		assert_eq(int(counts.get(name, 0)), 1, name + ": one cell")
	for name: String in ["fabrica", "horreum"]:
		assert_eq(int(counts.get(name, 0)), 2, name + ": two cells")
	var quarters := {}
	for cell: Dictionary in cells:
		if cell["template"] == "insula":
			quarters[cell["quarter"]] = true
	assert_eq(quarters.size(), 4, "the insulae take all four turns")
	var landmarks: Array = out["landmarks"]["landmarks"]
	var districts: Array = landmarks.filter(func(lm: Dictionary) -> bool: return lm["kind"] == "district")
	var district_ids: Array = districts.map(func(lm: Dictionary) -> String: return lm["id"])
	district_ids.sort()
	assert_eq(district_ids, ["fabricae", "forum", "horreum", "templum", "thermae"], "the five district landmarks (in the cells' bearing order)")
	assert_eq(String(landmarks[landmarks.size() - districts.size()]["kind"]), "district", "districts come last")
	var footprints := DataRegistry.collider_footprints(def)
	for lm: Dictionary in landmarks:
		assert_eq(DataRegistry.footprint_at(Vector2(float(lm["anchor"][0]), float(lm["anchor"][2])), footprints), "", "%s: the anchor is on open ground" % lm["id"])
	# Doors: only Castra / Villa barracks, every gate of the three rings.
	var doors: Array = out["cover"]["doors"]
	var gates := 0
	for d: Dictionary in doors:
		if d["kind"] == "gate":
			gates += 1
		else:
			assert_true(String(d["piece"]).begins_with("Castra") or String(d["piece"]).begins_with("Villa"), "%s is on a camp or farmstead barracks (%s)" % [d["id"], d["piece"]])
	assert_eq(gates, 10, "a gate in each of the 2 + 4 + 4 ring gates")
	var structure_ids: Array = out["structures"]["pieces"].filter(func(e: Dictionary) -> bool: return e["type"] == "barracks").map(func(e: Dictionary) -> String: return e["id"])
	var with_door := {}
	for d: Dictionary in doors:
		with_door[d["piece"]] = true
	var ladders := {}
	for l: Dictionary in out["cover"]["ladders"]:
		ladders[l["piece"]] = true
	for id: String in structure_ids:
		var camp_or_farm := id.begins_with("Castra") or id.begins_with("Villa")
		assert_eq(with_door.has(id), camp_or_farm, id + ": doors only on camp and farmstead barracks")
		assert_eq(ladders.has(id), camp_or_farm or id.match("Oppidum*_Domus_0"), id + ": ladders on camp and farmstead barracks and each cell's first house")
	assert_eq((l500["farms"] as Array).size(), 6 + (gen["farmsteads"]["small"]["spots"] as Array).size(), "six farmsteads and the small ones (M2 L2a density pass: twelve)")
	print("ALESIA_500_TOWN cells=%d per_template=%s dropped=%d doors=%d ladders=%d" % [cells.size(), str(counts), (l500["dropped"] as Array).size(), doors.size(), ladders.size()])


## M2 L2a density pass: every picket post, small farmstead and vineyard plot is placed whole (nothing dropped), the
## posts carry their sandbag nest, the fields keep no bare square of 40 m (density_check), no laid-out piece fails
## the ground-contact rule, and the generator reports no shortfall.
func test_density_pass() -> void:
	var def := _def()
	var gen: Dictionary = def["generator"]
	var out: Dictionary = _Gen.generate(def)
	var l500: Dictionary = out["l500"]
	assert_eq((l500["posts"] as Array).size(), 6, "a picket post behind each camp")
	assert_eq((l500["plots"] as Array).size(), (gen["vineae"]["plots"] as Array).size(), "every vineyard plot is placed")
	for list: String in ["posts", "plots"]:
		for block: Dictionary in l500[list]:
			assert_eq(int(block["dropped"]), 0, "%s drops nothing" % block["prefix"])
	for farm: Dictionary in l500["farms"]:
		assert_eq(int(farm["dropped"]), 0, "%s drops nothing" % farm["prefix"])
	var cover: Array = out["cover"]["pieces"]
	var nest := cover.filter(func(e: Dictionary) -> bool: return String(e["type"]).begins_with("sandbag_nest")).size()
	assert_true(nest >= 18, "the six posts' sandbag nests, three pieces each (%d pieces)" % nest)
	var tents := (out["structures"]["pieces"] as Array).filter(func(e: Dictionary) -> bool: return String(e["id"]).begins_with("Castra1_Tent")).size()
	assert_eq(tents, (gen["camps"]["tents"] as Array).size(), "each camp has its three rows of tents")
	var bare: Array = out["bare"]
	for sq: Array in bare:
		assert_true(float(sq[0]) < 40.0, "no bare square of 40 m in the fields: %.0f m at %s" % [float(sq[0]), str(sq[1])])
	assert_true((out["shortfalls"] as PackedStringArray).is_empty(), "no shortfall: " + ", ".join(out["shortfalls"]))
	print("ALESIA_500_DENSITY posts=%d plots=%d farms=%d fills=%d bare=%s cover_walls=%d" % [(l500["posts"] as Array).size(), (l500["plots"] as Array).size(), (l500["farms"] as Array).size(), (l500["fills"] as Array).size(), str(bare), int(out["cover_walls"])])


## The id filter of the door and ladder passes: absent = every piece (the 1 km map), else the globs.
func test_id_patterns() -> void:
	assert_true(_Gen.id_matches("Anything_1", null), "no patterns: every id")
	assert_true(_Gen.id_matches("Castra3_Barracks_1", ["Castra*", "Villa*"]), "a camp barracks matches")
	assert_true(not _Gen.id_matches("Oppidum07_Domus_1", ["Castra*", "Villa*", "Oppidum*_Domus_0"]), "a town cell's second house does not")
	assert_true(_Gen.id_matches("Oppidum07_Domus_0", ["Oppidum*_Domus_0"]), "a town cell's first house does")
	assert_eq(_Gen.map_path_of("alesia_500"), MAP, "--map=<id> names data/maps/<id>.json")
	assert_eq(_Gen.map_path_of(MAP), MAP, "--map=<res path> is kept")
