extends "res://tests/test_case.gd"
## M2L1: the ONE suite file that builds the 1 km Alesia scene (binding fix 16: no normal-suite test builds it more
## than once). The runner makes a new instance per test method, so the built map is a static, built by the first
## method that asks (_map()) and freed by the last method of this file (test_zz_free_the_map). Stages B and C add
## their scene checks here, before test_zz_free_the_map. Data-only checks live in tests/test_alesia_1km_data.gd.

const MAP := "res://data/maps/alesia_1km.json"
const Gen := preload("res://tools/gen_alesia.gd")
const _Builder := preload("res://scripts/visual/astra_map.gd")

static var _built: Node3D
static var _build_ms := 0


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


## The built map, built once per run (MatchRoot's hand-off: ArtBuilder.map_json is set before it enters the tree).
func _map() -> Node3D:
	if is_instance_valid(_built):
		return _built
	var tree: SceneTree = Engine.get_main_loop()
	var started := Time.get_ticks_msec()
	_built = load(String(_def()["scene"])).instantiate()
	_built.get_node("ArtBuilder").set("map_json", MAP)
	tree.root.add_child(_built)
	_build_ms = Time.get_ticks_msec() - started
	return _built


func test_the_scene_builds_on_its_terrain() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var def := _def()
	assert_eq(float(builder.ground_size_m), 1000.0, "a 1000 m ground")
	var terrain: MapTerrain = builder.terrain
	assert_true(terrain != null and terrain.samples == 501 and is_equal_approx(terrain.resolution_m, 2.0), "a 501 x 501 terrain at 2 m")
	var shape := map.get_node_or_null("Nav/Ground/Shape") as CollisionShape3D
	var height_map := shape.shape as HeightMapShape3D if shape != null else null
	assert_true(height_map != null and height_map.map_width == 501 and height_map.map_depth == 501, "the terrain collider: one 501 x 501 height map under Nav/Ground")
	if shape != null:
		assert_true(shape.scale.is_equal_approx(Vector3(2, 1, 2)), "the height map is scaled to 2 m samples")
	var hill: Dictionary = def["generator"]["hill"]
	assert_eq(terrain.height_at(0.0, 0.0), float(hill["height_m"]), "the hill top is at its height")
	assert_eq(terrain.height_at(float(hill["top_radius_m"]) - 2.0, 0.0), float(hill["height_m"]), "the top is flat")
	assert_eq(terrain.height_at(float(hill["radius_m"]) + 2.0, 0.0), 0.0, "flat past the hill")
	assert_eq(terrain.height_at(330.0, 0.0), 0.0, "the outer wall stands on flat ground")
	var steepest := 0.0
	for r in range(0, int(hill["radius_m"]) + 2, 1):
		steepest = maxf(steepest, terrain.slope_deg_at(float(r) + 0.3, 0.7))
	var nav := (map.get_node("Nav") as NavigationRegion3D).navigation_mesh
	assert_true(steepest < nav.agent_max_slope and steepest < float(WorldKit.config()["rules"]["max_walk_slope_deg"]), "the hill is walkable: steepest %.1f deg" % steepest)
	# A ray from above lands on the hill top (the collider is where the data says).
	await (Engine.get_main_loop() as SceneTree).physics_frame
	var space := map.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0, 80, 5), Vector3(0, -10, 5), Hitscan.MASK_WORLD))  # Arx's anchor: open ground
	assert_true(not hit.is_empty() and hit["collider"] == map.get_node("Nav/Ground") and absf(hit["position"].y - 25.0) < 0.01, "a ray lands on the hill top at 25 m: " + str(hit.get("position")))
	# Pieces stand on the terrain: every body's y is its file y plus the ground under its origin.
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var structures := DataRegistry.parse_quiet(String(def["structure_data"]))
	var lists := {"cover_bodies": cover["pieces"], "ring_bodies": cover["ring_pieces"], "structure_bodies": structures["pieces"]}
	var on_hill := 0
	for list: String in lists:
		var bodies: Array = builder.get(list)
		var entries: Array = lists[list]
		assert_eq(bodies.size(), entries.size(), list + ": one body per piece")
		for i in mini(bodies.size(), entries.size()):
			var body: StaticBody3D = bodies[i]
			var at := LowpolyKit.vec(entries[i]["at"])
			var ground_y := terrain.height_at(at.x, at.z)
			if ground_y > 0.5:
				on_hill += 1
			assert_true(absf(body.position.y - (at.y + ground_y)) < 0.001, "%s stands on the terrain (%.2f vs %.2f)" % [body.name, body.position.y, at.y + ground_y])
	assert_true(on_hill >= 15, "nonvacuous: %d pieces on the hill" % on_hill)
	assert_true(map.get_node_or_null("ArtBuilder/Terrain/Chunk_0_0/Far") != null, "far terrain is built (the map's own far_step_m)")
	# Load costs apart from the build (report): the heights file alone, uncached.
	var t0 := Time.get_ticks_usec()
	var heights := MapTerrain.from_block(def["terrain"], def)
	var heights_us := Time.get_ticks_usec() - t0
	assert_true(heights != null and heights.heights == terrain.heights, "the heights file loads alone")
	print("ALESIA_1KM_BUILD build_ms=", _build_ms, " heights_load_us=", heights_us, " on_hill=", on_hill, " steepest_deg=", snappedf(steepest, 0.1))


func test_counts_density_and_proxies() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var tree: SceneTree = Engine.get_main_loop()
	var walls := 0
	for node in tree.get_nodes_in_group(&"cover_wall"):
		if map.is_ancestor_of(node):
			walls += 1
	var structure_walls := 0
	for body: StaticBody3D in builder.structure_bodies:
		if body.is_in_group(&"cover_wall"):
			structure_walls += 1
	var statics := 0
	var inner := 0
	var outer := 0
	for node in map.find_children("*", "StaticBody3D", true, false):
		statics += 1
		if String(node.name).begins_with("InnerRing_"):
			inner += 1
		elif String(node.name).begins_with("OuterRing_"):
			outer += 1
	var cap := int(_def()["generator"]["max_cover_walls"])
	assert_true(walls > 100 and walls <= cap, "cover walls within the density cap: %d (cap %d)" % [walls, cap])
	assert_eq(walls, builder.cover_bodies.size() + builder.ring_bodies.size(), "cover walls are the cover and ring pieces")
	assert_eq(structure_walls, 0, "structure pieces (walls, towers, aqueducts) are not cover walls")
	assert_true(inner > 0 and outer > 0, "both wall rings built")
	var decor := (DataRegistry.parse_quiet(String(_def()["cover_data"]))["decor"] as Array).size()
	print("ALESIA_1KM_COUNTS cover=", builder.cover_bodies.size(), " ring=", builder.ring_bodies.size(), " decor=", decor, " decor_bodies=", builder.decor_bodies.size(),
		" structures=", builder.structure_bodies.size(), " walls_inner=", inner, " walls_outer=", outer, " cover_wall=", walls, " static_bodies=", statics)
	# Report only (binding fix 10): no limit is checked for this map.
	print("ALESIA_1KM_PROXY ", MapChunks.proxies(map))


func test_validates_and_has_no_backdrop() -> void:
	var map := _map()
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(MAP).size(), 0, "validate_map is clean: " + ", ".join(reg.validate_map(MAP)))
	var builder := map.get_node("ArtBuilder")
	assert_true(builder.get_node_or_null("Backdrop") == null, "no backdrop node on the 1 km map")
	assert_true(not _Builder.backdrop_wanted(_def(), true), "backdrop false wins over a preset that enables it")
	assert_true(_Builder.backdrop_wanted(DataRegistry.parse_quiet(DataRegistry.MAP_PATH), true), "a map without the key keeps the backdrop")
	assert_true(not _Builder.backdrop_wanted(DataRegistry.parse_quiet(DataRegistry.MAP_PATH), false), "a preset without it has none")


func test_baked_paint_loads_and_answers_footsteps() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var image: Image = builder.ground_paint
	assert_true(image != null and image.get_width() == 1024 and image.get_height() == 1024, "a 1024 px paint")
	assert_true(image != null and String(image.get_meta(&"inputs_sha256", "")) != "", "the paint is the baked file (it carries its inputs hash), not a paint at load")
	var def := _def()
	var settings := GroundPaint.settings_for(def)
	var t0 := Time.get_ticks_usec()
	var again := ResourceLoader.load(String(settings["baked"]), "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	var load_us := Time.get_ticks_usec() - t0
	assert_true(again != null and again.get_data() == image.get_data(), "the builder's paint equals the file")
	var gen: Dictionary = def["generator"]
	var camp := Gen.dir_of(float(gen["camps"]["first_bearing_deg"])) * float(gen["camps"]["radius_m"])
	var spawn := LowpolyKit.vec(def["spawns"]["spot_0"])
	var points := {
		"citadel top": [Vector3(0, 25, 10), "paving"],
		"citadel slope": [Vector3(0, 10, 60), "paving"],
		"camp ring": [Vector3(camp.x + 26.0, 0, camp.y + 26.0), "earth"],
		"between the rings": [Vector3(0, 0, 250), "earth"],
		"fields": [spawn, "grass"],
	}
	for label: String in points:
		var p: Array = points[label]
		assert_eq(GroundPaint.surface_at(image, float(builder.ground_size_m), p[0]), p[1], label + ": footsteps hear " + String(p[1]))
	print("ALESIA_1KM_PAINT px=", image.get_width(), " file_bytes=", FileAccess.get_file_as_bytes(String(settings["baked"])).size(), " load_us=", load_us)


## Last in this file: frees the shared 1 km map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
