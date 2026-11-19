extends "res://tests/test_case.gd"
## M2 L2a: the ONE suite file that builds the 500 m Alesia scene (data/maps/alesia_500.json, OQ-ALESIA-500
## placeholders) for its scene checks, as tests/test_alesia_1km.gd does for the 1 km map: the built map is a static,
## built by the first method that asks (_map()) and freed by the last method (test_zz_free_the_map). Data-only checks
## live in tests/test_alesia_500_data.gd; tests/test_ground_contact.gd measures the visuals once more on its own.
## Checks: the scene builds on its terrain (every body on the ground, its far terrain and far backdrop), the landmarks,
## built counts against the data, the play space against the pinned collider snapshot
## (data/maps/snapshots/alesia_500_colliders.json, tools/m2w1_collider_snapshot.gd -- --map=res://data/maps/alesia_500.json),
## and paths on the SAVED navigation mesh: through every gate of the three rings, through every barracks doorway and
## from each spawn to the Arx top. Report only: sight lines, proxies and visible counts (data/map_build.json limits).
## M2 L2a stage 3: real matches load alesia_500 (data/map_select.json): test_real_match_entry_plays_the_500_map, moved
## here from tests/test_alesia_1km.gd.

const MAP := "res://data/maps/alesia_500.json"
const Gen := preload("res://tools/gen_alesia.gd")
const _Builder := preload("res://scripts/visual/astra_map.gd")
const _Contact := preload("res://tests/test_ground_contact.gd")
const _Snap := preload("res://tools/m2w1_collider_snapshot.gd")
const _Sight := preload("res://tools/sight_lines.gd")
const PlaceMap := preload("res://scripts/visual/place_map.gd")

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


func test_validates_and_builds_on_its_terrain() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var def := _def()
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(MAP).size(), 0, "validate_map is clean: " + ", ".join(reg.validate_map(MAP)))
	assert_eq(float(builder.ground_size_m), 500.0, "a 500 m ground")
	var terrain: MapTerrain = builder.terrain
	assert_true(terrain != null and terrain.samples == 251 and is_equal_approx(terrain.resolution_m, 2.0), "a 251 x 251 terrain at 2 m")
	var shape := map.get_node_or_null("Nav/Ground/Shape") as CollisionShape3D
	var height_map := shape.shape as HeightMapShape3D if shape != null else null
	assert_true(height_map != null and height_map.map_width == 251 and height_map.map_depth == 251, "the terrain collider: one 251 x 251 height map under Nav/Ground")
	var hill: Dictionary = def["generator"]["hill"]
	assert_eq(terrain.height_at(0.0, 0.0), float(hill["height_m"]), "the hill top is at its height")
	assert_eq(terrain.height_at(float(hill["radius_m"]) + 2.0, 0.0), 0.0, "flat past the hill")
	assert_true(map.get_node_or_null("ArtBuilder/Terrain/Chunk_0_0/Far") != null, "far terrain is built (the map's own far_step_m %s)" % str(def["terrain"]["far_step_m"]))
	assert_true(builder.get_node_or_null("Backdrop/Hills") != null and builder.get_node_or_null("Backdrop/OuterWall") == null, "the far backdrop (art_backdrop.json maps.alesia_500), no small-map wall ring")
	# Every body stands on the terrain: its y is its file y plus the ground under its origin.
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
	# Every drawn piece touches the ground (the ground-contact measure of tests/test_ground_contact.gd).
	var tol := float(def["terrain"]["max_visual_float_m"])
	var report: Dictionary = _Contact.contact_report(map, def)
	assert_true(int((report["families"]["all"] as Dictionary)["n"]) > 1000, "nonvacuous: visuals measured")
	var worst: Array = (report["floating"] as Array)[0] if not (report["floating"] as Array).is_empty() else [0.0, "", ""]
	assert_true(float(worst[0]) <= tol, "every visual within max_visual_float_m %.2f: worst %.3f m (%s %s)" % [tol, float(worst[0]), worst[1], worst[2]])
	var t0 := Time.get_ticks_usec()
	var heights := MapTerrain.from_block(def["terrain"], def)
	var heights_us := Time.get_ticks_usec() - t0
	assert_true(heights != null and heights.heights == terrain.heights, "the heights file loads alone")
	print("ALESIA_500_BUILD build_ms=", _build_ms, " heights_load_us=", heights_us, " on_hill=", on_hill, " worst_float_m=", snappedf(float(worst[0]), 0.001),
			" terrain_tris=", report["terrain_tris"])


func test_landmarks() -> void:
	var landmarks: Array = DataRegistry.parse_quiet(String(_def()["landmarks"]))["landmarks"]
	assert_eq(landmarks.size(), 18, "18 landmarks")
	assert_eq(String(landmarks[0]["id"]), "arx", "the first landmark is the Arx")
	var districts := landmarks.filter(func(l: Dictionary) -> bool: return String(l["kind"]) == "district")
	assert_eq(districts.size(), 5, "five districts")
	var ids: Array = districts.map(func(l: Dictionary) -> String: return String(l["id"]))
	ids.sort()
	assert_eq(ids, ["fabricae", "forum", "horreum", "templum", "thermae"], "the five districts")
	var terrain: MapTerrain = _map().get_node("ArtBuilder").terrain
	for l: Dictionary in landmarks:
		var a := LowpolyKit.vec(l["anchor"])
		assert_true(Vector2(a.x, a.z).length() <= float(_def()["play_radius_m"]), "%s inside the play circle" % l["id"])
		assert_true(absf(a.y - terrain.height_at(a.x, a.z)) < 0.5, "%s's anchor is on the ground (%.2f vs %.2f)" % [l["id"], a.y, terrain.height_at(a.x, a.z)])


func test_counts_and_the_collider_snapshot() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var tree: SceneTree = Engine.get_main_loop()
	var def := _def()
	var walls := 0
	for node in tree.get_nodes_in_group(&"cover_wall"):
		if map.is_ancestor_of(node):
			walls += 1
	var structure_walls := 0
	for body: StaticBody3D in builder.structure_bodies:
		if body.is_in_group(&"cover_wall"):
			structure_walls += 1
	var rings := {"ArxRing_": 0, "InnerRing_": 0, "OuterRing_": 0}
	for body: StaticBody3D in builder.structure_bodies:
		for prefix: String in rings:
			if String(body.name).begins_with(prefix):
				rings[prefix] = int(rings[prefix]) + 1
	var cap := int(def["generator"]["max_cover_walls"])
	assert_true(walls > 100 and walls <= cap, "cover walls within max_cover_walls: %d (cap %d)" % [walls, cap])
	assert_eq(walls, builder.cover_bodies.size() + builder.ring_bodies.size(), "cover walls are the cover and ring pieces")
	assert_eq(structure_walls, 0, "structure pieces are not cover walls")
	for prefix: String in rings:
		assert_true(int(rings[prefix]) >= 16, "%s built: %d pieces" % [prefix, int(rings[prefix])])
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	assert_eq(builder.chest_bodies.size(), (cover.get("chests", []) as Array).size(), "one chest body per chest")
	assert_eq(builder.door_bodies.size(), (cover.get("doors", []) as Array).size(), "one door body per door")
	assert_eq(builder.ladders.size(), (cover.get("ladders", []) as Array).size(), "one ladder per ladder")
	# The play space against the pinned snapshot (tools/m2w1_collider_snapshot.gd -- --map=<this map>).
	var saved := DataRegistry.parse_quiet(_Snap.snapshot_path(MAP))
	assert_true(not saved.is_empty() and saved.has("entries"), "the snapshot %s reads" % _Snap.snapshot_path(MAP))
	var now := _Snap.snapshot(map, MAP)
	if not saved.is_empty():
		assert_eq((now["entries"] as Array).size(), (saved["entries"] as Array).size(), "as many collision shapes as the snapshot")
		assert_eq(String(now["entries_sha256"]), String(saved["entries_sha256"]), "the canonical entries hash (rerun the snapshot tool after an intended change)")
		assert_eq((now["cover_wall"] as Array).size(), (saved["cover_wall"] as Array).size(), "as many cover walls as the snapshot")
		for g: String in (saved["group_counts"] as Dictionary):
			assert_eq(int((now["group_counts"] as Dictionary).get(g, 0)), int(saved["group_counts"][g]), "group %s count" % g)
		for list: String in _Snap.LISTS:
			assert_eq(now["builder_lists"][list], (saved["builder_lists"] as Dictionary).get(list, []), "builder.%s as the snapshot" % list)
	var decor := (cover["decor"] as Array).size()
	print("ALESIA_500_COUNTS cover=", builder.cover_bodies.size(), " ring=", builder.ring_bodies.size(), " decor=", decor, " decor_bodies=", builder.decor_bodies.size(),
		" structures=", builder.structure_bodies.size(), " rings=", rings, " cover_wall=", walls, " chests=", builder.chest_bodies.size(), " doors=", builder.door_bodies.size(),
		" ladders=", builder.ladders.size(), " collider_shapes=", (now["entries"] as Array).size(), " entries_sha256=", now["entries_sha256"])


## The saved 500 m mesh on the one built map's Nav region.
func _nav_map() -> RID:
	var nav := _map().get_node("Nav") as NavigationRegion3D
	var top := Vector3(0, float(_def()["generator"]["hill"]["height_m"]), 5)
	if nav.navigation_mesh == null or nav.navigation_mesh.resource_path != MapNav.saved_path(MAP):
		nav.navigation_mesh = MapNav.load_fresh(MAP)
		var tree: SceneTree = Engine.get_main_loop()
		for n in Engine.physics_ticks_per_second * 2:
			await tree.physics_frame
			if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 and _on_nav(nav.get_navigation_map(), top):
				break
	return nav.get_navigation_map()


## True when the mesh has a polygon at the walkable surface point p (within `across` m across, 0.75 m up or down).
static func _on_nav(nav_map: RID, p: Vector3, across: float = 1.0) -> bool:
	var q := NavigationServer3D.map_get_closest_point(nav_map, p)
	return Vector2(q.x, q.z).distance_to(Vector2(p.x, p.z)) < across and absf(q.y - p.y) < 0.75


static func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


## The least horizontal distance from c to the path's segments.
static func _passes(path: PackedVector3Array, c: Vector3) -> float:
	var best := INF
	var p := Vector2(c.x, c.z)
	for i in range(1, path.size()):
		var a := Vector2(path[i - 1].x, path[i - 1].z)
		var b := Vector2(path[i].x, path[i].z)
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


## "" when a path from a to b on the mesh reaches b (within 1 m across, 0.75 m height), no longer than max_len and
## passing within pass_m of `via`; else the reason.
static func _path_problem(nav_map: RID, a: Vector3, b: Vector3, via: Vector3, max_len: float, pass_m: float) -> String:
	if not _on_nav(nav_map, a, 1.5):
		return "start %s is off the mesh (closest %s)" % [a, NavigationServer3D.map_get_closest_point(nav_map, a)]
	if not _on_nav(nav_map, b, 1.5):
		return "end %s is off the mesh (closest %s)" % [b, NavigationServer3D.map_get_closest_point(nav_map, b)]
	var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
	if path.size() < 2 or Vector2(path[path.size() - 1].x, path[path.size() - 1].z).distance_to(Vector2(b.x, b.z)) > 1.5:
		return "no path (ends at %s)" % (str(path[path.size() - 1]) if path.size() > 0 else "nothing")
	if _length(path) > max_len:
		return "a detour: %.0f m (max %.0f)" % [_length(path), max_len]
	if _passes(path, via) > pass_m:
		return "does not pass through (%.1f m off)" % _passes(path, via)
	return ""


## The point at horizontal (x, z) on the walkable surface: the terrain height plus a little.
static func _ground(terrain: MapTerrain, x: float, z: float) -> Vector3:
	return Vector3(x, terrain.height_at(x, z) + 0.1, z)


func test_nav_paths_through_every_gate() -> void:
	var nav_map: RID = await _nav_map()
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	assert_eq((map.get_node("Nav") as NavigationRegion3D).navigation_mesh.resource_path, MapNav.saved_path(MAP), "the region runs on the saved 500 m mesh")
	var terrain: MapTerrain = builder.terrain
	var counts := {"ArxRing_": 0, "InnerRing_": 0, "OuterRing_": 0}
	var lines: Array[String] = []
	for body: StaticBody3D in builder.structure_bodies:
		if String(body.get_meta(&"structure_type", "")) != "gate":
			continue
		var prefix := ""
		for p: String in counts:
			if String(body.name).begins_with(p):
				prefix = p
		if prefix == "":
			continue
		counts[prefix] = int(counts[prefix]) + 1
		var t := body.global_transform
		var through := t.basis.orthonormalized() * Vector3.BACK
		through = Vector3(through.x, 0.0, through.z).normalized()
		var c := t.origin
		var a := _ground(terrain, c.x - through.x * 8.0, c.z - through.z * 8.0)
		var b := _ground(terrain, c.x + through.x * 8.0, c.z + through.z * 8.0)
		var why := _path_problem(nav_map, a, b, c, 16.0 * 1.6, 2.5)
		assert_true(why == "", "through gate %s: %s" % [body.name, why])
		lines.append("%s:%s" % [body.name, "ok" if why == "" else why])
	assert_eq(counts, {"ArxRing_": 2, "InnerRing_": 4, "OuterRing_": 4}, "the gates of the three rings")
	print("ALESIA_500_NAV_GATES ", " | ".join(lines))


## Every barracks and town room doorway has a saved-nav path from 2 m in front to the room
## behind it. Every room also reaches the Arx top.
func test_nav_paths_through_every_barracks_doorway() -> void:
	var nav_map: RID = await _nav_map()
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var terrain: MapTerrain = builder.terrain
	var def := _def()
	var kit: Dictionary = WorldKit.config()["types"]
	var barracks_openings: Array = def["generator"]["doors"]["door"]["openings"]
	var arx := LowpolyKit.vec((DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"] as Array)[0]["anchor"])
	var doorways := 0
	var rooms := 0
	var failed: Array[String] = []
	for body: StaticBody3D in builder.structure_bodies:
		var type := String(body.get_meta(&"structure_type", ""))
		var openings: Array = barracks_openings if type == "barracks" else kit[type].get("doorway_indices", [])
		if openings.is_empty():
			continue
		var opens: Array = kit[type]["open"]
		rooms += 1
		var t := body.global_transform
		var inside_any := Vector3.INF
		for index: Variant in openings:
			var o: Dictionary = opens[int(index)]
			var at := LowpolyKit.vec(o["at"])
			var size := LowpolyKit.vec(o["size"])
			var s := signf(at.z)
			var out_local := Vector3(at.x, 0.0, s * (absf(at.z) + size.z * 0.5 + 2.0))
			var in_local := Vector3(at.x, 0.0, 0.0)
			var outside := t * out_local
			var inside := t * in_local
			var door := t * Vector3(at.x, 0.0, at.z)
			var a := _ground(terrain, outside.x, outside.z)
			var b := Vector3(inside.x, t.origin.y + 0.1, inside.z)
			inside_any = b
			doorways += 1
			var why := _path_problem(nav_map, a, b, door, (absf(at.z) + size.z * 0.5 + 2.0) * 2.0 + 2.0, 1.2)
			if why != "":
				failed.append("%s doorway %d: %s" % [body.name, int(index), why])
		var path := NavigationServer3D.map_get_path(nav_map, inside_any, arx, true)
		if path.size() < 2 or path[path.size() - 1].distance_to(arx) > 1.0:
			failed.append("%s: the room does not reach the Arx top (ends at %s)" % [body.name, str(path[path.size() - 1]) if path.size() > 0 else "nothing"])
	assert_eq(rooms, (DataRegistry.parse_quiet(String(def["structure_data"]))["pieces"] as Array).filter(func(e: Dictionary) -> bool: return e["type"] == "barracks" or kit[e["type"]].has("doorway_indices")).size(), "every room checked")
	assert_true(rooms > 100, "nonvacuous: %d rooms" % rooms)
	assert_true(failed.is_empty(), "%d doorway/room problems (first 15): %s" % [failed.size(), "; ".join(failed.slice(0, 15))])
	print("ALESIA_500_NAV_DOORWAYS rooms=%d doorways=%d problems=%d %s" % [rooms, doorways, failed.size(), "; ".join(failed.slice(0, 30))])


func test_nav_paths_from_every_spawn_to_the_arx_top() -> void:
	var nav_map: RID = await _nav_map()
	var def := _def()
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var arx := LowpolyKit.vec(landmarks[0]["anchor"])
	# The citadel top has nav polygons: most points of a 5 m grid on the flat top (r < 20 m).
	var top_y := float(def["generator"]["hill"]["height_m"])
	var top_points := 0
	var top_on_nav := 0
	for x in range(-20, 21, 5):
		for z in range(-20, 21, 5):
			if Vector2(x, z).length() >= 20.0:
				continue
			top_points += 1
			if _on_nav(nav_map, Vector3(x, top_y, z)):
				top_on_nav += 1
	assert_true(top_on_nav >= top_points * 0.5 and _on_nav(nav_map, arx), "nav polygons on the citadel top: %d of %d grid points, and at the Arx anchor" % [top_on_nav, top_points])
	var lines: Array[String] = []
	assert_eq((def["spawns"] as Dictionary).size(), 6, "six spawns")
	for spot: String in def["spawns"]:
		var from := LowpolyKit.vec(def["spawns"][spot])
		var path := NavigationServer3D.map_get_path(nav_map, from, arx, true)
		var straight := Vector2(from.x, from.z).distance_to(Vector2(arx.x, arx.z))
		var length := _length(path)
		assert_true(path.size() >= 2 and path[path.size() - 1].distance_to(arx) < 1.0, "%s reaches the Arx top" % spot)
		assert_true(length >= straight and length < straight * 2.0, "%s to the Arx: a plausible length %.0f m (straight %.0f m)" % [spot, length, straight])
		lines.append("%s len=%d straight=%d" % [spot, roundi(length), roundi(straight)])
	for i in landmarks.size():
		var a := LowpolyKit.vec(landmarks[i]["anchor"])
		var b := LowpolyKit.vec(landmarks[(i + 1) % landmarks.size()]["anchor"])
		var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
		assert_true(path.size() >= 2 and path[path.size() - 1].distance_to(b) < 1.0 and _length(path) < 3.0 * a.distance_to(b) + 50.0,
				"a path from %s to %s (%.0f m)" % [landmarks[i]["id"], landmarks[(i + 1) % landmarks.size()]["id"], _length(path)])
	print("ALESIA_500_NAV_PATHS top=%d/%d " % [top_on_nav, top_points], " | ".join(lines))


## Report only (OQ-ALESIA-500): the sight-line measure (tools/sight_lines.gd) on the built map.
func test_sight_lines_report() -> void:
	var map := _map()
	await (Engine.get_main_loop() as SceneTree).physics_frame
	var def := _def()
	var result: Dictionary = _Sight.measure(map, def)
	assert_true(not result.is_empty(), "nonvacuous: sight lines measured")
	for line: String in _Sight.report_lines(String(def["id"]), result, def):
		print(line)


## Report only (as tests/test_alesia_1km.gd: no limit is asserted for this map yet): the map-wide proxies and the
## visible counts (MapChunks.visible_at) from the Arx top, an outer gate (Porta Aquilae's gateway), the Forum square
## and a camp centre (castra_prima's anchor), each against data/map_build.json proxy_limits.visible.centre, and which
## per-map and standard-point limits the map would exceed.
func test_proxies_and_visible_counts_report() -> void:
	var map := _map()
	var def := _def()
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var anchors := {}
	for l: Dictionary in landmarks:
		anchors[String(l["id"])] = LowpolyKit.vec(l["anchor"])
	var gate := Gen.dir_of(0.0) * float(def["generator"]["outer_wall"]["radius_m"])
	var forum: Vector3 = anchors["forum"]
	var camp: Vector3 = anchors["castra_prima"]
	var points := {
		"arx_top": Vector3(0.0, terrain.height_at(0.0, 5.0) + MapChunks.EYE_M, 5.0),
		"porta_aquilae": Vector3(gate.x, terrain.height_at(gate.x, gate.y) + MapChunks.EYE_M, gate.y),
		"forum": Vector3(forum.x, terrain.height_at(forum.x, forum.z) + MapChunks.EYE_M, forum.z),
		"castra_prima": Vector3(camp.x, terrain.height_at(camp.x, camp.z) + MapChunks.EYE_M, camp.z),
	}
	var limits: Dictionary = MapChunks.config().get("proxy_limits", {})
	var centre_limit: Dictionary = (limits.get("visible", {}) as Dictionary).get("centre", {})
	for point_name: String in points:
		var v := MapChunks.visible_at(map, points[point_name])
		assert_true(int(v["batches_total"]) > 0, "nonvacuous: %s" % point_name)
		var verdict := "batches %s, shadow %s" % [
				"pass" if int(v["batches"]) <= int(centre_limit.get("batches", 0)) else "OVER",
				"pass" if int(v["shadow"]) <= int(centre_limit.get("shadow", 0)) else "OVER"]
		print("ALESIA_500_VISIBLE point=%s at=%s batches=%d/%d colliding=%d non_colliding=%d shadow=%d terrain=%d/%d near=%d far=%d terrain_tris=%d vs centre limit %s: %s per_class=%s" % [
				point_name, str(points[point_name]), v["batches"], v["batches_total"], v["colliding"], v["non_colliding"], v["shadow"],
				v["terrain"], v["terrain_total"], v["terrain_near"], v["terrain_far"], v["terrain_tris"], str(centre_limit), verdict, v["per_class"]])
	var proxies := MapChunks.proxies(map)
	print("ALESIA_500_PROXY ", proxies)
	var clutter := {"batches": 0, "instances": 0}
	for batch: MultiMeshInstance3D in (map.get_node("ArtBuilder").get("chunks") as MapChunks).batches():
		if String(batch.get_meta(&"source", "")) == "clutter":
			clutter["batches"] = int(clutter["batches"]) + 1
			clutter["instances"] = int(clutter["instances"]) + batch.multimesh.instance_count
	print("ALESIA_500_CLUTTER batches=%d instances=%d" % [clutter["batches"], clutter["instances"]])
	var over := MapChunks.proxy_problems(proxies, limits)
	var over_visible := MapChunks.visible_problems(MapChunks.visible_proxies(map), limits.get("visible", {}))
	print("ALESIA_500_LIMITS report only, not in the limits test: would exceed: %s; visible (standard points): %s" % [
			"; ".join(over) if not over.is_empty() else "none", "; ".join(over_visible) if not over_visible.is_empty() else "none"])


## B3 wiring through the real entry point (docs/LESSONS.md): a match the way the menu and the lobby start one
## (auto_start) reads data/map_select.json and plays alesia_500 with its overrides, the saved mesh and the
## terrain-aware loot. The one begin() on this map in the normal suite (bots off to keep it short). Moved here from
## tests/test_alesia_1km.gd (test_real_match_entry_plays_the_1km_map) when real matches switched maps (M2 L2a).
func test_real_match_entry_plays_the_500_map() -> void:
	assert_true(not FileAccess.file_exists(MatchRoot.MAP_OVERRIDE_PATH), "no phone override file on this machine")
	var m: MatchRoot = (load("res://scenes/match/match.tscn") as PackedScene).instantiate()
	m.fill_bots = false
	m.seed_override = 4242
	var tree: SceneTree = Engine.get_main_loop()
	var started := Time.get_ticks_msec()
	tree.root.add_child(m)  # auto_start (the default): _ready runs begin()
	var begin_ms := Time.get_ticks_msec() - started
	assert_true(m.use_map_select, "the auto_start path reads the map selection")
	assert_eq(m.map_path, MAP, "a real match loads alesia_500")
	assert_eq(m.nav_bakes, 0, "no runtime nav bake")
	var nav := m.map.get_node("Nav") as NavigationRegion3D
	assert_eq(nav.navigation_mesh.resource_path, MapNav.saved_path(MAP), "the saved 500 m mesh")
	var over: Dictionary = MatchDirector.map_overrides(MAP)
	assert_eq(float(m.director.mode_cfg["zone"]["start_radius_m"]), float(over["br"]["zone"]["start_radius_m"]), "the map's zone override is in the match config")
	assert_eq(int(m.director.loot_cfg["count"]), int(over["loot"]["count"]), "the map's loot override is in the loot config")
	assert_true(m.loot != null and m.loot._ground_height.is_valid(), "the loot field got the terrain height")
	await tree.physics_frame
	await tree.physics_frame
	assert_true(m.loot.placed and m.loot.items.size() > 100, "the match's loot is placed (%d)" % m.loot.items.size())
	assert_eq(m.world_props.chests.size(), (DataRegistry.parse_quiet(String(_def()["cover_data"]))["chests"] as Array).size(), "the match's WorldProps holds every chest")
	print("ALESIA_500_REAL_MATCH begin_ms=", begin_ms, " loot=", m.loot.items.size())
	m.queue_free()
	await tree.process_frame


## M2 CX2 rank 6: the BUILT map stamps every gate's authored approach (place_map.maps.alesia_500.gate_approaches) at
## the real gate body, through astra_map.gd's add_gate_approaches: each strip's centre holds at least its value in the
## live place map. Nonvacuous: a rebuild without the approaches (PlaceMap.build alone) is lower at some strip centres.
func test_gate_approaches_are_stamped_at_the_built_gates() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var live: PlaceMap = builder.get("place_map")
	assert_true(live != null, "the 500 map builds a place map")
	if live == null:
		return
	var before: PlaceMap = PlaceMap.build(builder, float(builder.ground_size_m))
	var profiles: Dictionary = PlaceMap.config("alesia_500")["gate_approaches"]
	var bodies := {}
	for body: Node in builder.get("structure_bodies"):
		bodies[String(body.name)] = body
	var checked := 0
	var raised := 0
	for id: String in profiles:
		assert_true(bodies.has(id), id + " is a built gate body")
		if not bodies.has(id):
			continue
		var frame := WorldClutter.xform_to(bodies[id], map)
		var centre := Vector2(frame.origin.x, frame.origin.z)
		var across := Vector2(frame.basis.x.x, frame.basis.x.z).normalized()
		var inward := Vector2(-across.y, across.x)
		for strip: Array in profiles[id]:
			var ch := int(strip[0])
			var c := centre + across * float(strip[1]) + inward * float(strip[2])
			var want := float(strip[6])
			var got: float = live.sample(c)[ch]
			assert_true(got >= want - 0.01, "%s strip %s: channel %d at its centre %.3f >= %.3f" % [id, str(strip), ch, got, want])
			checked += 1
			if before.sample(c)[ch] < want - 0.05:
				raised += 1
	print("ALESIA_500_GATE_APPROACHES strips=", checked, " raised_over_build=", raised)
	assert_true(checked == 33 and raised >= 10, "nonvacuous: 33 strips checked (%d), %d raised over the map without them" % [checked, raised])


## M2 CX2 pass 3: the BUILT 500 m map's ground material carries the map-local compacted soil colour
## (place_map.maps.alesia_500.compacted_soil, alpha 1 switches it on in ground.gdshader); the shader default is off.
func test_built_map_uses_the_compacted_soil_colour() -> void:
	var builder := _map().get_node("ArtBuilder")
	var mat: ShaderMaterial = builder.get("ground_material")
	assert_true(mat != null, "the 500 map has a ground material")
	if mat == null:
		return
	var want: Array = PlaceMap.config("alesia_500")["compacted_soil"]
	var got: Color = mat.get_shader_parameter("compacted_soil")
	assert_eq(got.a, 1.0, "compacted_soil is switched on for alesia_500")
	assert_true(absf(got.r - float(want[0])) < 0.002 and absf(got.g - float(want[1])) < 0.002 and absf(got.b - float(want[2])) < 0.002, "compacted_soil is the data colour (%s)" % str(got))
	assert_true(not PlaceMap.config("alesia_1km").has("compacted_soil"), "alesia_1km keeps the shared trodden colour")


## Last in this file: frees the shared 500 m map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
