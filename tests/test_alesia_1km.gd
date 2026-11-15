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
	var lists := {"cover_bodies": cover["pieces"] + cover.get("breakables", []), "ring_bodies": cover["ring_pieces"], "structure_bodies": structures["pieces"]}
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


## M2 L1b: the cover file's breakables are built under ArtBuilder/Props (outside Nav: the bake never parses them),
## one Breakable per entry in file order right after the pieces in cover_bodies, each a named, drawn piece of the
## chunk batches; the builder's trodden points are the generator's (trodden_of), so the baked paint is not stale
## (no "painting the ground at load").
func test_breakables_are_built_under_props_and_the_paint_is_fresh() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var def := _def()
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var structures := DataRegistry.parse_quiet(String(def["structure_data"]))
	var entries: Array = cover.get("breakables", [])
	assert_eq(entries.size(), 26, "26 breakables in the cover file")
	var props := map.get_node_or_null("ArtBuilder/Props")
	assert_true(props != null, "ArtBuilder/Props exists")
	if props == null:
		return
	var nav := map.get_node("Nav")
	var pieces := (cover["pieces"] as Array).size()
	var chunks: MapChunks = builder.chunks
	for i in entries.size():
		var e: Dictionary = entries[i]
		var body := props.get_node_or_null(String(e["id"])) as Breakable
		assert_true(body != null, "%s is built under Props" % e["id"])
		if body == null:
			continue
		assert_true(not nav.is_ancestor_of(body), "%s is outside Nav" % e["id"])
		assert_true(pieces + i < builder.cover_bodies.size() and builder.cover_bodies[pieces + i] == body, "%s follows the pieces in cover_bodies" % e["id"])
		assert_true(body.is_in_group(&"cover_wall") and body.is_in_group(Breakable.GROUP), "%s: groups cover_wall and breakable" % e["id"])
		assert_true(chunks.has_piece(String(e["id"])) and not chunks.is_piece_hidden(String(e["id"])), "%s: a drawn piece of the batches" % e["id"])
	assert_eq(builder.breakable_bodies().size(), entries.size(), "breakable_bodies lists them all")
	var want := Gen.trodden_of(cover, structures)
	var have := PackedVector2Array()
	for group: Array in [builder.cover_bodies, builder.ring_bodies, builder.structure_bodies]:
		for body: StaticBody3D in group:
			have.append(Vector2(body.position.x, body.position.z))
	assert_eq(have, want, "the builder's trodden points are the generator's, in order")
	var settings := GroundPaint.settings_for(def)
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"])).get("landmarks", [])
	var px := GroundPaint.px_for(float(builder.ground_size_m), settings)
	var hash := GroundPaint.inputs_hash(float(builder.ground_size_m), landmarks, have, settings)
	assert_eq(GroundPaint.baked_problem(String(settings["baked"]), px, hash), "", "the baked paint matches the built map (no paint at load)")


## M2 L1b: the cover file's 11 chests are LootChest bodies under Nav (baked into the navigation), group loot_chest,
## never cover walls nor cover bodies, standing on the terrain, each with a drawn closed look and a hidden open look
## in the batches; every point of each chest's spill ring lies on open ground (outside every collider footprint:
## pieces, decor, structures, breakables and chests).
func test_chests_are_built_under_nav_and_spill_on_open_ground() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var def := _def()
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var entries: Array = cover.get("chests", [])
	var gen_cfg: Dictionary = def["generator"]["props"]["chests"]
	assert_eq(entries.size(), int(gen_cfg["camps"]) * (def["generator"]["camps"]["names"] as Array).size() + int(gen_cfg["arx"]) + int(gen_cfg["fields"]), "every chest is placed")
	assert_eq(entries.size(), 11, "11 chests in the cover file")
	var nav := map.get_node("Nav")
	var chunks: MapChunks = builder.chunks
	var terrain: MapTerrain = builder.terrain
	var tree: SceneTree = Engine.get_main_loop()
	var in_group := 0
	for node in tree.get_nodes_in_group(LootChest.GROUP):
		if map.is_ancestor_of(node):
			in_group += 1
	assert_eq(in_group, entries.size(), "group loot_chest holds every chest")
	assert_eq(builder.chest_bodies.size(), entries.size(), "chest_bodies lists them all")
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id := String(e["id"])
		var body := nav.get_node_or_null(id) as LootChest
		assert_true(body != null and builder.chest_bodies[i] == body, "%s is a LootChest under Nav, in order" % id)
		if body == null:
			continue
		assert_true(not body.is_in_group(&"cover_wall") and not (body in builder.cover_bodies), "%s: no cover wall, no cover body" % id)
		assert_true(body.collision_layer == 1 and body.has_meta(&"cover_palette"), "%s: layer 1 and a palette" % id)
		var shape := body.get_node_or_null("Shape") as CollisionShape3D
		assert_true(shape != null and shape.shape is BoxShape3D and (shape.shape as BoxShape3D).size.is_equal_approx(LowpolyKit.vec(e["size"])), "%s: the cover file's box" % id)
		var at := LowpolyKit.vec(e["at"])
		assert_true(absf(body.position.y - (at.y + terrain.height_at(at.x, at.z))) < 0.001, "%s stands on the terrain" % id)
		assert_true(is_equal_approx(fposmod(float(e["yaw"]), 90.0), 0.0) and body.basis.is_equal_approx(Basis(Vector3.UP, deg_to_rad(float(e["yaw"])))), "%s: a 90 degree yaw" % id)
		assert_true(chunks.has_piece(id) and not chunks.is_piece_hidden(id), "%s: the closed look is drawn" % id)
		assert_true(chunks.has_piece(LootChest.open_id(id)) and chunks.is_piece_hidden(LootChest.open_id(id)), "%s: the open look is hidden" % id)
	# Open ground: the spill ring of every chest (16 points, more than any roll) against every footprint.
	var footprints := DataRegistry.collider_footprints(def)
	for list: String in ["breakables", "chests"]:
		for e: Dictionary in cover.get(list, []):
			var size := LowpolyKit.vec(e["size"])
			footprints.append({"id": String(e["id"]), "at": Vector2(float(e["at"][0]), float(e["at"][2])), "yaw": deg_to_rad(float(e.get("yaw", 0.0))),
				"rect": Rect2(-size.x * 0.5, -size.z * 0.5, size.x, size.z)})
	var chest_cfg: Dictionary = WorldProps.config()["chest"]
	var checked := 0
	for body: StaticBody3D in builder.chest_bodies:
		var c := body as LootChest
		var centre := c.spill_centre(float(chest_cfg["spill_offset_m"]))
		for p: Vector3 in WorldProps.spill_points(centre, 16, float(chest_cfg["spill_radius_m"]), c.yaw_deg):
			var hit := DataRegistry.footprint_at(Vector2(p.x, p.z), footprints)
			assert_eq(hit, "", "%s: spill point %s on open ground" % [c.prop_id, p])
			assert_true(absf(terrain.height_at(p.x, p.z) - c.ground_point().y) < 0.5, "%s: spill point at the chest's ground height" % c.prop_id)
			checked += 1
	assert_true(checked == 16 * entries.size(), "nonvacuous: %d spill points" % checked)
	var problems := WorldProps.problems(cover, WorldProps.config())
	assert_eq(problems, PackedStringArray(), "WorldProps.problems is clean on the committed cover file")


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


## M2L1 stage B: the saved 1 km mesh (never re-baked in the suite) on the one built map's Nav region.
func _nav_map() -> RID:
	var nav := _map().get_node("Nav") as NavigationRegion3D
	if nav.navigation_mesh == null or nav.navigation_mesh.resource_path != MapNav.saved_path(MAP):
		nav.navigation_mesh = MapNav.load_fresh(MAP)
		# The server syncs regions over the next physics frames; wait (at most 2 s) until the Arx top is on the map.
		var tree: SceneTree = Engine.get_main_loop()
		for n in Engine.physics_ticks_per_second * 2:
			await tree.physics_frame
			if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 and _on_nav(nav.get_navigation_map(), Vector3(0, 25, 5)):
				break
	return nav.get_navigation_map()


## True when the mesh has a polygon at the walkable surface point p: within 1 m across and 0.75 m up or down (the
## baked mesh floats up to a few cell heights, 0.25 m each, over the collider top).
static func _on_nav(nav_map: RID, p: Vector3, across: float = 1.0) -> bool:
	var q := NavigationServer3D.map_get_closest_point(nav_map, p)
	return Vector2(q.x, q.z).distance_to(Vector2(p.x, p.z)) < across and absf(q.y - p.y) < 0.75


static func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


## "bearing@y" of every point where the path crosses the circle of radius r (bearing 0 = north = -z).
static func _crossings(path: PackedVector3Array, r: float) -> Array[String]:
	var out: Array[String] = []
	for i in range(1, path.size()):
		var a := Vector2(path[i - 1].x, path[i - 1].z)
		var b := Vector2(path[i].x, path[i].z)
		var la := a.length()
		var lb := b.length()
		if (la - r) * (lb - r) > 0.0 or la == lb:
			continue
		var t := (r - la) / (lb - la)  # the radius is close to linear along a short segment far from the centre
		var p := a.lerp(b, t)
		out.append("%d@%.1f" % [roundi(fposmod(rad_to_deg(atan2(p.x, -p.y)), 360.0)), lerpf(path[i - 1].y, path[i].y, t)])
	return out


func test_nav_paths_reach_the_arx_and_the_landmarks() -> void:
	var nav_map: RID = await _nav_map()
	var nav := _map().get_node("Nav") as NavigationRegion3D
	assert_eq(nav.navigation_mesh.resource_path, MapNav.saved_path(MAP), "the region runs on the saved 1 km mesh")
	var def := _def()
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var arx := LowpolyKit.vec(landmarks[0]["anchor"])
	assert_eq(String(landmarks[0]["id"]), "arx", "the first landmark is the Arx")
	# The citadel top has nav polygons: most points of a 5 m grid on the flat top (r < 20 m; the Arx's own pieces
	# take the rest) have the mesh right there.
	var top_points := 0
	var top_on_nav := 0
	for x in range(-20, 21, 5):
		for z in range(-20, 21, 5):
			if Vector2(x, z).length() >= 20.0:
				continue
			top_points += 1
			if _on_nav(nav_map, Vector3(x, 25.0, z)):
				top_on_nav += 1
	assert_true(top_on_nav >= top_points * 0.7 and _on_nav(nav_map, arx), "nav polygons on the citadel top: %d of %d grid points, and at the Arx anchor" % [top_on_nav, top_points])
	var lines: Array[String] = []
	for spot: String in def["spawns"]:
		var from := LowpolyKit.vec(def["spawns"][spot])
		var path := NavigationServer3D.map_get_path(nav_map, from, arx, true)
		var straight := Vector2(from.x, from.z).distance_to(Vector2(arx.x, arx.z))
		var length := _length(path)
		assert_true(path.size() >= 2 and path[path.size() - 1].distance_to(arx) < 1.0, "%s reaches the Arx top" % spot)
		assert_true(length >= straight and length < straight * 2.0, "%s to the Arx: a plausible length %.0f m (straight %.0f m)" % [spot, length, straight])
		lines.append("%s len=%d straight=%d outer=%s inner=%s" % [spot, roundi(length), roundi(straight), _crossings(path, 330.0), _crossings(path, 140.0)])
	for i in landmarks.size():
		var a := LowpolyKit.vec(landmarks[i]["anchor"])
		var b := LowpolyKit.vec(landmarks[(i + 1) % landmarks.size()]["anchor"])
		var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
		assert_true(path.size() >= 2 and path[path.size() - 1].distance_to(b) < 1.0 and _length(path) < 3.0 * a.distance_to(b) + 50.0,
				"a path from %s to %s (%.0f m)" % [landmarks[i]["id"], landmarks[(i + 1) % landmarks.size()]["id"], _length(path)])
	print("ALESIA_1KM_NAV_PATHS ", " | ".join(lines))


## Report (stage A's open question): which wall-walk stretches and aqueduct decks the saved mesh reaches from the
## ground (the Arx top, which every spawn reaches). Printed, not limited: the one assert is that some stretch is
## reachable at all.
func test_wall_walks_and_aqueduct_decks_on_the_loaded_mesh() -> void:
	var nav_map: RID = await _nav_map()
	var arx := Vector3(0, 25, 5)
	var pieces: Array = DataRegistry.parse_quiet(String(_def()["structure_data"]))["pieces"]
	pieces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	var report: Array[String] = []
	var reachable_any := 0
	for ring: String in ["InnerRing_", "OuterRing_"]:
		# Five samples along each walk piece (local x -3 .. 3 on the walkway, 3 m up), in ring order. A stretch is a
		# run of consecutive samples on the mesh; a gate, a tower or an aqueduct deck over the walk ends one.
		var stretches: Array = []  # [first piece id, first sample point, has stair, samples]
		var current: Array = []
		var samples := 0
		var on_nav := 0
		var walk_pieces := 0
		for entry: Dictionary in pieces:
			if not String(entry["id"]).begins_with(ring):
				continue
			var kind := String(entry["type"])
			var walk := kind == "wall_walk" or kind == "wall_stair"
			if walk:
				walk_pieces += 1
			var turn := Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw", 0.0))))
			for x: float in ([-3.0, -1.5, 0.0, 1.5, 3.0] if walk else [0.0]):
				var top := LowpolyKit.vec(entry["at"]) + turn * Vector3(x, 3.0, 0.0)  # walkway top (collider 3 m)
				var has := walk and _on_nav(nav_map, top, 0.5)
				if walk:
					samples += 1
				if has:
					on_nav += 1
					if current.is_empty():
						current = [String(entry["id"]), top, false, 0]
					current[2] = bool(current[2]) or kind == "wall_stair"
					current[3] = int(current[3]) + 1
				elif not current.is_empty():
					stretches.append(current)
					current = []
		if not current.is_empty():
			stretches.append(current)
		var cut: Array[String] = []
		var reached_stretches := 0
		var without_stair := 0
		for s: Array in stretches:
			var top: Vector3 = s[1]
			var path := NavigationServer3D.map_get_path(nav_map, arx, top, true)
			if path.size() >= 2 and path[path.size() - 1].distance_to(top) < 1.2:
				reached_stretches += 1
			else:
				cut.append("%s(%d samples, stair=%s)" % [s[0], s[3], s[2]])
			if not bool(s[2]):
				without_stair += 1
		reachable_any += reached_stretches
		report.append("%s walk_pieces=%d samples=%d on_nav=%d stretches=%d reachable=%d without_own_stair=%d unreachable=%s" % [ring.trim_suffix("_"), walk_pieces, samples, on_nav,
				stretches.size(), reached_stretches, without_stair, cut])
	var decks := 0
	var deck_nav := 0
	var deck_reached := 0
	for entry: Dictionary in pieces:
		if String(entry["type"]) != "aqueduct_span":
			continue
		decks += 1
		var top := LowpolyKit.vec(entry["at"]) + Vector3(0, 5.0, 0)  # deck collider top
		if _on_nav(nav_map, top):
			deck_nav += 1
			var path := NavigationServer3D.map_get_path(nav_map, arx, top, true)
			if path.size() >= 2 and path[path.size() - 1].distance_to(top) < 1.2:
				deck_reached += 1
	report.append("aqueduct spans=%d with_nav=%d reachable=%d" % [decks, deck_nav, deck_reached])
	assert_true(reachable_any > 0, "nonvacuous: some wall-walk stretch is reachable from the ground")
	print("ALESIA_1KM_NAV_WALKS ", " | ".join(report))


## B2 (binding fixes 4, 23): loot with the map's merged loot config lands on the citadel hill. A LootField over the
## one built map, set up as MatchRoot.begin sets it up (merged loot and zone, the landmarks, the terrain height).
func _hill_loot(with_terrain: bool) -> LootField:
	var map := _map()
	var director := MatchDirector.new()
	director.load_config(MAP)
	var landmarks: Array = DataRegistry.parse_quiet(String(_def()["landmarks"]))["landmarks"]
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var field := LootField.new()
	field.setup(director.loot_cfg, 4242, director.mode_cfg["zone"], landmarks, terrain.height_at if with_terrain else Callable())
	director.free()
	map.add_child(field)
	var tree: SceneTree = Engine.get_main_loop()
	await tree.physics_frame
	await tree.physics_frame
	return field


## Named so that the usual --only filters of other files (test_loot, test_map_, test_match, test_br_) miss it: a
## method of this file run without test_zz_free_the_map leaves the 1 km map in the tree for the next files.
func test_hill_loot_lands_at_every_cluster() -> void:
	var map := _map()
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var director := MatchDirector.new()
	director.load_config(MAP)
	var loot_cfg := director.loot_cfg
	var zone: Dictionary = director.mode_cfg["zone"]
	director.free()
	var landmarks: Array = DataRegistry.parse_quiet(String(_def()["landmarks"]))["landmarks"]
	var started := Time.get_ticks_usec()
	var field: LootField = await _hill_loot(true)
	var place_us := Time.get_ticks_usec() - started
	assert_true(field.placed and field.items.size() > int(loot_cfg["count"]) * 0.8, "most of the %d items found ground (%d)" % [loot_cfg["count"], field.items.size()])
	var space := map.get_world_3d().direct_space_state
	var limit := float(zone["start_radius_m"]) - float(loot_cfg["zone_edge_margin_m"])
	var inside_collider := 0
	var outside := 0
	var off_ground := 0
	for id in field.items:
		var p: Vector3 = field.items[id]["pos"]
		if Vector2(p.x, p.z).length() > limit + 0.001:
			outside += 1
		var query := PhysicsPointQueryParameters3D.new()
		query.position = p
		query.collision_mask = Hitscan.MASK_WORLD
		if not space.intersect_point(query, 1).is_empty():
			inside_collider += 1
		var above := p.y - terrain.height_at(p.x, p.z)
		if above < 0.2 or above > float(loot_cfg["max_ground_y_m"]) + 0.25 + 0.01:
			off_ground += 1
	assert_eq(outside, 0, "no item outside the zone start circle less the edge margin (%.0f m)" % limit)
	assert_eq(inside_collider, 0, "no item inside a collider")
	assert_eq(off_ground, 0, "every item lies at most max_ground_y_m above the terrain under it")
	var by_landmark := {}
	var per: Array[String] = []
	for landmark: Dictionary in landmarks:
		var here := 0
		var high := 0
		for id in field.items:
			var p: Vector3 = field.items[id]["pos"]
			if Vector2(p.x, p.z).distance_to(Vector2(float(landmark["at"][0]), float(landmark["at"][1]))) <= float(landmark["radius_m"]):
				here += 1
				if p.y > 1.5:
					high += 1
		by_landmark[landmark["id"]] = [here, high]
		per.append("%s=%d" % [landmark["id"], here])
	for cluster: Dictionary in loot_cfg["clusters"]:
		var got: Array = by_landmark.get(cluster["landmark"], [0, 0])
		assert_true(int(got[0]) >= int(cluster["items"]) - 2, "%s gets its cluster: %d items (cluster of %d, a try may find no ground)" % [cluster["landmark"], got[0], cluster["items"]])
	assert_true(int(by_landmark["arx"][1]) >= int(by_landmark["arx"][0]) - 1 and int(by_landmark["arx"][1]) >= 10, "the Arx cluster sits on the hill, above absolute y 1.5: %s" % [by_landmark["arx"]])
	# Nonvacuous: the old absolute limit puts nothing on the hill.
	var flat: LootField = await _hill_loot(false)
	var flat_high := 0
	for id in flat.items:
		if float(flat.items[id]["pos"].y) > float(loot_cfg["max_ground_y_m"]) + 0.25 + 0.001:
			flat_high += 1
	assert_eq(flat_high, 0, "without the terrain height no item lies above the absolute limit (the old rule)")
	print("ALESIA_1KM_LOOT placed=", field.items.size(), " of ", loot_cfg["count"], " place_ms=", place_us / 1000, " arx_high=", by_landmark["arx"], " per_landmark=", " ".join(per))
	field.free()
	flat.free()


## B3 wiring through the real entry point (docs/LESSONS.md): a match the way the menu and the lobby start one
## (auto_start) reads data/map_select.json and plays alesia_1km with its overrides, the saved mesh and the
## terrain-aware loot. The one begin() on this map in the normal suite (bots off to keep it short).
func test_real_match_entry_plays_the_1km_map() -> void:
	assert_true(not FileAccess.file_exists(MatchRoot.MAP_OVERRIDE_PATH), "no phone override file on this machine")
	var m: MatchRoot = (load("res://scenes/match/match.tscn") as PackedScene).instantiate()
	m.fill_bots = false
	m.seed_override = 4242
	var tree: SceneTree = Engine.get_main_loop()
	var started := Time.get_ticks_msec()
	tree.root.add_child(m)  # auto_start (the default): _ready runs begin()
	var begin_ms := Time.get_ticks_msec() - started
	assert_true(m.use_map_select, "the auto_start path reads the map selection")
	assert_eq(m.map_path, MAP, "a real match loads alesia_1km")
	assert_eq(m.nav_bakes, 0, "no runtime nav bake")
	var nav := m.map.get_node("Nav") as NavigationRegion3D
	assert_eq(nav.navigation_mesh.resource_path, MapNav.saved_path(MAP), "the saved 1 km mesh")
	var over: Dictionary = MatchDirector.map_overrides(MAP)
	assert_eq(float(m.director.mode_cfg["zone"]["start_radius_m"]), float(over["br"]["zone"]["start_radius_m"]), "the map's zone override is in the match config")
	assert_eq(int(m.director.loot_cfg["count"]), int(over["loot"]["count"]), "the map's loot override is in the loot config")
	assert_true(m.loot != null and m.loot._ground_height.is_valid(), "the loot field got the terrain height")
	await tree.physics_frame
	await tree.physics_frame
	assert_true(m.loot.placed and m.loot.items.size() > 100, "the match's loot is placed (%d)" % m.loot.items.size())
	assert_eq(m.world_props.chests.size(), (DataRegistry.parse_quiet(String(_def()["cover_data"]))["chests"] as Array).size(), "the match's WorldProps holds every chest")
	print("ALESIA_1KM_REAL_MATCH begin_ms=", begin_ms, " loot=", m.loot.items.size())
	m.queue_free()
	await tree.process_frame


## M2L1 Proxies (report only, binding fix 10: no limit is asserted for this map): MapChunks.visible_at from the
## citadel top (the Arx anchor at eye height), an outer gate (standing in Porta Aquilae's gateway) and the field
## corner (MapChunks.standard_points "corner" = the ground corner (-500, -500), outside the play circle), plus the
## standard "centre" point; and which data/map_build.json limits the map-wide counts would exceed.
func test_visible_counts_from_three_points_report() -> void:
	var map := _map()
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var gate := Gen.dir_of(0.0) * float(_def()["generator"]["outer_wall"]["radius_m"])
	var corner: Vector3 = MapChunks.standard_points(map)["corner"]
	var points := {
		"citadel_top": Vector3(0.0, terrain.height_at(0.0, 5.0) + MapChunks.EYE_M, 5.0),
		"porta_aquilae": Vector3(gate.x, terrain.height_at(gate.x, gate.y) + MapChunks.EYE_M, gate.y),
		"field_corner": corner,
		"centre_standard": MapChunks.standard_points(map)["centre"],
	}
	for point_name: String in points:
		var v := MapChunks.visible_at(map, points[point_name])
		assert_true(int(v["batches_total"]) > 0, "nonvacuous: %s" % point_name)
		print("ALESIA_1KM_VISIBLE point=%s at=%s batches=%d/%d colliding=%d non_colliding=%d shadow=%d terrain=%d/%d near=%d far=%d terrain_tris=%d per_class=%s" % [
				point_name, str(points[point_name]), v["batches"], v["batches_total"], v["colliding"], v["non_colliding"], v["shadow"],
				v["terrain"], v["terrain_total"], v["terrain_near"], v["terrain_far"], v["terrain_tris"], v["per_class"]])
	var limits: Dictionary = MapChunks.config().get("proxy_limits", {})
	var over := MapChunks.proxy_problems(MapChunks.proxies(map), limits)
	var over_visible := MapChunks.visible_problems(MapChunks.visible_proxies(map), limits.get("visible", {}))
	print("ALESIA_1KM_LIMITS report only, not in the limits test: would exceed: %s; visible: %s" % [
			"; ".join(over) if not over.is_empty() else "none", "; ".join(over_visible) if not over_visible.is_empty() else "none"])


## M2 L1c: the cover file's 24 doors and 8 gates are Door bodies under ArtBuilder/Props (outside Nav: the bake never
## parses them), group door only (never cover_wall, in no body list the paint or the cover index reads), standing on
## the terrain at their openings, in their start state (the collider on exactly when closed), all settled (no door
## processes at rest); WorldProps.collect on the map stores every door's state.
func test_doors_are_built_under_props_outside_nav() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var cover := DataRegistry.parse_quiet(String(_def()["cover_data"]))
	var entries: Array = cover.get("doors", [])
	assert_eq(entries.size(), 32, "32 doors and gates in the cover file")
	var props := map.get_node_or_null("ArtBuilder/Props")
	var nav := map.get_node("Nav")
	var terrain: MapTerrain = builder.terrain
	assert_eq(builder.door_bodies.size(), entries.size(), "door_bodies lists them all")
	var lists: Array = [builder.cover_bodies, builder.ring_bodies, builder.structure_bodies, builder.decor_bodies, builder.chest_bodies]
	var closed := 0
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id := String(e["id"])
		var d := props.get_node_or_null(id) as Door if props != null else null
		assert_true(d != null and builder.door_bodies[i] == d, "%s is a Door under Props, in order" % id)
		if d == null:
			continue
		assert_true(not nav.is_ancestor_of(d), "%s is outside Nav" % id)
		assert_true(d.is_in_group(Door.GROUP) and not d.is_in_group(&"cover_wall"), "%s: group door, never cover_wall" % id)
		for list: Array in lists:
			assert_true(not (d in list), "%s is in no other body list" % id)
		var at := LowpolyKit.vec(e["at"])
		assert_true(absf(d.position.y - (at.y + terrain.height_at(at.x, at.z))) < 0.001, "%s stands on the terrain" % id)
		assert_eq(d.open, String(e["start"]) == "open", "%s: its start state" % id)
		assert_eq(d.blocks(), not d.open, "%s: the collider on exactly when closed" % id)
		assert_true(d.settled() and not d.is_physics_processing(), "%s rests (no processing)" % id)
		closed += 0 if d.open else 1
	assert_true(closed > 0 and closed < entries.size(), "nonvacuous: some closed (%d), some open" % closed)
	var wp := WorldProps.new()
	wp.setup(WorldProps.config(), 1, true)
	wp.collect(map)
	assert_eq(wp.doors.size(), entries.size(), "WorldProps.collect finds every door")
	for e: Dictionary in entries:
		assert_eq(wp.state_of(String(e["id"])), WorldProps.OPEN if String(e["start"]) == "open" else WorldProps.CLOSED, "%s: its state is stored" % e["id"])
	wp.free()


## Last in this file: frees the shared 1 km map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
