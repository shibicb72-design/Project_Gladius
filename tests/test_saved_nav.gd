extends "res://tests/test_case.gd"
## M2P1B commit 5: saved navigation meshes (MapNav, tools/bake_nav.gd). The committed meshes are fresh (the CI
## guard: change map data without re-baking and this fails), match a re-bake, are the ones a match uses, and
## bots path and walk on them; stale data falls back to the runtime bake.

const _MatchScene := preload("res://scenes/match/match.tscn")
const ALESIA := "res://data/maps/alesia_section.json"
const MAP := "res://data/maps/test_300.json"
const MAPS := [ALESIA, MAP]
## M2L1 (binding fix 12): the 1 km map is never re-baked or started here; it gets the hash checks only (its scene
## checks on the loaded mesh live in tests/test_alesia_1km.gd, the one file that builds it).
const BIG := "res://data/maps/alesia_1km.json"
const _BakeTool := preload("res://tools/bake_nav.gd")
## A temporary copy of alesia: it must sit in res://data/maps/ (DataRegistry.validate_map), so it is removed at
## the end of its test.
const TMP_MAP := "res://data/maps/_saved_nav_test_tmp.json"
const TMP_DIR := "user://p1b_saved_nav_tmp/"
const HILL := Vector2(90.0, 90.0)  # test_300.json "test_hill" centre (x, z)


## Every error and warning while it is attached (the runner's own logger only records script errors).
class _Catcher extends Logger:
	var lines: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		lines.append("%d %s (%s:%d in %s)" % [error_type, rationale if rationale != "" else code, file, line, function])


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


static func calm_zone() -> Dictionary:  # as tests/test_br_bots.gd
	return {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}


## A harmless zone on the hill top: a bot outside it walks to its spot there (bot_brain.gd _zone_pressure).
## M2P1C: kept on purpose, it is what makes the bot climb. Under calm_zone() the bot stands inside the target
## circle, so _goal() gives it no zone pressure: it seeks loot in range or holds, never the hill top. Zone
## pressure ranks above loot, so the hill zone makes the peak its goal; damage 0 keeps the zone harmless.
static func hill_zone() -> Dictionary:
	return {"start_center": [HILL.x, HILL.y], "start_radius_m": 3.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 1.0, "damage_per_s": 0.0}]}


func _start(map_path: String, bake: bool, bots: bool = false, zone: Dictionary = calm_zone()) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = bake
	m.fill_bots = bots
	m.seed_override = 2718
	m.map_path_override = map_path
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	assert_true(m.begin(), "begin on " + map_path)
	await frames(2)
	return m


func _region(m: MatchRoot) -> NavigationRegion3D:
	return m.map.get_node("Nav") as NavigationRegion3D


func _manifest(map_path: String) -> Dictionary:
	return DataRegistry.parse_quiet(MapNav.manifest_path(map_path))


## The map scene built and baked the way tools/bake_nav.gd does (a duplicate of the scene's own mesh).
func _bake_scene(map_path: String) -> NavigationMesh:
	var def := DataRegistry.parse_quiet(map_path)
	var map := (load(String(def["scene"])) as PackedScene).instantiate() as Node3D
	map.get_node("ArtBuilder").set("map_json", map_path)
	tree().root.add_child(map)
	await tree().physics_frame
	var nav := map.get_node("Nav") as NavigationRegion3D
	var mesh := nav.navigation_mesh.duplicate() as NavigationMesh
	nav.navigation_mesh = mesh
	nav.bake_navigation_mesh(false)
	map.queue_free()
	await tree().process_frame
	return mesh


## The path once the navigation map has synced past `after` (region updates may build over several physics
## frames); empty after 2 s of frames.
func _synced_path(nav: NavigationRegion3D, from: Vector3, to: Vector3, after: int = -1) -> PackedVector3Array:
	var nav_map := nav.get_navigation_map()
	for n in Engine.physics_ticks_per_second * 2:
		await frames(1)
		if NavigationServer3D.map_get_iteration_id(nav_map) <= after:
			continue
		var path := NavigationServer3D.map_get_path(nav_map, from, to, true)
		if path.size() >= 2:
			return path
	return PackedVector3Array()


static func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func test_committed_meshes_are_fresh() -> void:
	# M2 L2b: alesia_500 like BIG: hash checks only here (tests/test_alesia_500.gd builds it).
	var mid := "res://data/maps/alesia_500.json"
	assert_eq(_BakeTool.DEFAULT_MAPS, [ALESIA, MAP, BIG, mid] as Array[String], "tools/bake_nav.gd bakes the four maps by default, named explicitly")
	for map_path: String in MAPS + [BIG, mid]:
		assert_true(FileAccess.file_exists(MapNav.saved_path(map_path)), "saved mesh " + MapNav.saved_path(map_path))
		assert_true(FileAccess.file_exists(MapNav.manifest_path(map_path)), "manifest " + MapNav.manifest_path(map_path))
		var reasons := MapNav.stale_reasons(map_path, true)
		assert_true(reasons.is_empty(), "%s: saved navigation is stale, re-run tools/bake_nav.gd: %s" % [map_path, "; ".join(reasons)])


func test_input_files_of_both_maps() -> void:
	var alesia := MapNav.input_files(ALESIA)
	assert_eq(alesia["runtime"], PackedStringArray(["res://data/art_astra.json", "res://data/maps/alesia_cover.json",
			ALESIA, "res://data/maps/alesia_structures.json"]), "alesia runtime inputs")
	assert_eq(alesia["tool"], PackedStringArray(["res://scenes/maps/alesia_section.tscn"]), "alesia tool inputs")
	var big := MapNav.input_files(MAP)
	assert_eq(big["runtime"], PackedStringArray(["res://data/art_astra.json", "res://data/maps/alesia_cover.json",
			"res://data/maps/alesia_structures.json", MAP, "res://data/maps/test_300_cover.json",
			"res://data/maps/test_300_structures.json"]), "test_300 runtime inputs")
	assert_eq(big["tool"], PackedStringArray(["res://scenes/maps/test_300.tscn"]), "test_300 tool inputs")
	# M2L1 (binding fixes 6, 13): the 1 km map's binary heights and baked paint are tool inputs (hashed here and by
	# the bake tool, never by the runtime), and the manifest holds their current sha256.
	var km := MapNav.input_files(BIG)
	var km_tool := PackedStringArray(["res://data/maps/alesia_1km_heights.res", "res://data/maps/alesia_1km_paint.res", "res://scenes/maps/alesia_1km.tscn"])
	assert_eq(km["tool"], km_tool, "alesia_1km tool inputs: heights .res, paint .res, scene")
	assert_eq(km["runtime"], PackedStringArray(["res://data/art_astra.json", BIG, "res://data/maps/alesia_1km_cover.json",
			"res://data/maps/alesia_1km_structures.json", "res://data/maps/alesia_cover.json", "res://data/maps/alesia_structures.json"]), "alesia_1km runtime inputs")
	var saved_tool: Dictionary = _manifest(BIG).get("tool_inputs", {})
	for path in km_tool:
		assert_true(MapNav.file_hash(path) != "" and str(saved_tool.get(path, "")) == MapNav.file_hash(path), "alesia_1km manifest holds the current sha256 of " + path)
	# The runtime check (MatchRoot.begin -> MapNav.load_fresh) compares JSON only, and finds the 1 km mesh fresh.
	assert_eq(MapNav.stale_reasons(BIG).size(), 0, "alesia_1km fresh for the runtime")
	var loaded := MapNav.load_fresh(BIG)
	assert_true(loaded != null and loaded.get_polygon_count() > 0 and loaded.get_polygon_count() == int(_manifest(BIG).get("polygons", -1)), "the saved 1 km mesh loads with the manifest's polygons")
	# A heights file: json is a runtime input, a binary .res a tool input.
	var def := {"scene": "res://s.tscn", "terrain": {"height_source": {"type": "file", "path": "res://h.res"}}}
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var path := TMP_DIR + "map.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(def))
	f.close()
	assert_true("res://h.res" in MapNav.input_files(path)["tool"], "a .res heights file is a tool input")
	def["terrain"]["height_source"]["path"] = "res://h.json"
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(def))
	f.close()
	assert_true("res://h.json" in MapNav.input_files(path)["runtime"], "a .json heights file is a runtime input")
	_clean_tmp()


## Exact counts are compared on the same machine: a different machine or engine build may bake slightly
## different meshes, so this is a CI-on-the-baking-machine check. It catches scene, wall and builder-code changes
## the input hashes cannot see.
func test_rebake_gives_the_saved_counts() -> void:
	for map_path: String in MAPS:
		var baked: NavigationMesh = await _bake_scene(map_path)
		var saved := MapNav.load_saved(map_path)
		var manifest := _manifest(map_path)
		assert_true(saved != null, "saved mesh loads: " + map_path)
		if saved == null:
			continue
		assert_eq(baked.get_polygon_count(), saved.get_polygon_count(), map_path + " polygons, re-bake vs saved")
		assert_eq(baked.get_vertices().size(), saved.get_vertices().size(), map_path + " vertices, re-bake vs saved")
		assert_eq(saved.get_polygon_count(), int(manifest.get("polygons", -1)), map_path + " polygons, saved vs manifest")
		assert_eq(saved.get_vertices().size(), int(manifest.get("vertices", -1)), map_path + " vertices, saved vs manifest")


func test_match_uses_the_saved_mesh() -> void:
	for map_path: String in MAPS:
		var first: MatchRoot = await _start(map_path, true)
		var mesh := _region(first).navigation_mesh
		assert_eq(mesh.resource_path, MapNav.saved_path(map_path), map_path + " region mesh is the saved one")
		assert_eq(first.nav_bakes, 0, map_path + " no runtime bake")
		assert_eq(mesh.get_polygon_count(), int(_manifest(map_path).get("polygons", -1)), map_path + " polygons as in the manifest")
		first.queue_free()
		await frames(1)
		var second: MatchRoot = await _start(map_path, true)
		var again := _region(second).navigation_mesh
		assert_true(not is_same(mesh, again), map_path + ": two matches do not share one NavigationMesh")
		assert_eq(again.resource_path, MapNav.saved_path(map_path), map_path + " second match also loads the saved one")
		second.queue_free()
		await frames(1)


func test_stale_reasons_cover_each_case() -> void:
	var now := {"runtime": {"a": "1", "b": "2"}}
	var good := {"version": MapNav.VERSION, "map": "m", "inputs": {"a": "1", "b": "2"}}
	assert_eq(MapNav.manifest_reasons(good, "m", now).size(), 0, "matching manifest is fresh")
	var changed := good.duplicate(true)
	changed["inputs"]["b"] = "3"
	var r := MapNav.manifest_reasons(changed, "m", now)
	assert_true(r.size() == 1 and r[0].contains("b changed"), "a changed hash: %s" % r)
	var missing := good.duplicate(true)
	missing["inputs"].erase("b")
	r = MapNav.manifest_reasons(missing, "m", now)
	assert_true(r.size() == 1 and r[0].contains("b is not in the manifest"), "an input missing from the manifest: %s" % r)
	var extra := good.duplicate(true)
	extra["inputs"]["c"] = "9"
	r = MapNav.manifest_reasons(extra, "m", now)
	assert_true(r.size() == 1 and r[0].contains("c is no longer an input"), "an extra manifest entry: %s" % r)
	r = MapNav.manifest_reasons(good, "m", {"runtime": {"a": "1", "b": ""}})
	assert_true(r.size() == 1 and r[0].contains("b is missing"), "an input file gone: %s" % r)
	var old := good.duplicate(true)
	old["version"] = MapNav.VERSION + 1
	assert_eq(MapNav.manifest_reasons(old, "m", now).size(), 1, "another manifest version is stale")
	assert_eq(MapNav.manifest_reasons(good, "other", now).size(), 1, "a manifest of another map is stale")
	# Tool inputs count only when asked for.
	var tooled := good.duplicate(true)
	tooled["tool_inputs"] = {"s.tscn": "x"}
	assert_eq(MapNav.manifest_reasons(tooled, "m", now).size(), 0, "runtime check ignores the tool inputs")
	r = MapNav.manifest_reasons(tooled, "m", {"runtime": now["runtime"], "tool": {"s.tscn": "y"}})
	assert_true(r.size() == 1 and r[0].contains("tool input s.tscn changed"), "a changed tool input: %s" % r)
	# Files: a missing manifest and a missing mesh (the committed files are never touched).
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var none_mesh := TMP_DIR + "none.res"
	var none_manifest := TMP_DIR + "none.json"
	r = MapNav.stale_reasons_at(ALESIA, none_mesh, none_manifest)
	assert_true(r.size() == 2 and r[0].contains("saved mesh") and r[1].contains("manifest"), "missing mesh and manifest: %s" % r)
	var copy := TMP_DIR + "alesia_section.json"
	var f := FileAccess.open(copy, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(MapNav.manifest_path(ALESIA)))
	f.close()
	r = MapNav.stale_reasons_at(ALESIA, none_mesh, copy)
	assert_true(r.size() == 1 and r[0].contains("saved mesh"), "missing mesh only: %s" % r)
	assert_eq(MapNav.stale_reasons_at(ALESIA, MapNav.saved_path(ALESIA), copy, true).size(), 0, "the copied manifest is fresh")
	f = FileAccess.open(copy, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	r = MapNav.stale_reasons_at(ALESIA, MapNav.saved_path(ALESIA), copy)
	assert_true(r.size() == 1 and r[0].contains("manifest"), "an unreadable manifest: %s" % r)
	_clean_tmp()


func test_carriage_returns_do_not_change_hashes() -> void:
	assert_eq(MapNav.text_hash("{\r\n\t\"a\": 1\r\n}\r\n"), MapNav.text_hash("{\n\t\"a\": 1\n}\n"), "CRLF text hashes as LF")
	assert_true(MapNav.text_hash("{\"a\": 1}") != MapNav.text_hash("{\"a\": 2}"), "different text, different hash")
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var crlf := TMP_DIR + "crlf.json"
	var lf := TMP_DIR + "lf.json"
	for pair: Array in [[crlf, "{\r\n\"a\": 1\r\n}\r\n"], [lf, "{\n\"a\": 1\n}\n"]]:
		var f := FileAccess.open(String(pair[0]), FileAccess.WRITE)
		f.store_string(String(pair[1]))
		f.close()
	assert_eq(MapNav.file_hash(crlf), MapNav.file_hash(lf), "a CRLF and an LF json file hash the same")
	assert_eq(MapNav.file_hash(TMP_DIR + "nope.json"), "", "a missing file hashes as empty")
	_clean_tmp()


func test_map_without_saved_mesh_bakes_at_match_start() -> void:
	# M2P1C: a copy left by an aborted earlier run goes first (a test that dies mid-body skips its cleanup).
	if FileAccess.file_exists(TMP_MAP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MAP))
	assert_true(not FileAccess.file_exists(TMP_MAP), "no leftover temporary map")
	var f := FileAccess.open(TMP_MAP, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(ALESIA))
	f.close()
	assert_true(not MapNav.stale_reasons(TMP_MAP).is_empty(), "the copy has no saved mesh")
	var catcher := _Catcher.new()
	OS.add_logger(catcher)
	var m: MatchRoot = await _start(TMP_MAP, true)
	OS.remove_logger(catcher)
	assert_eq(m.map_path, TMP_MAP, "the match loaded the copy")
	assert_eq(m.nav_bakes, 1, "one runtime bake")
	var mesh := _region(m).navigation_mesh
	assert_true(mesh.get_polygon_count() > 0, "the baked region mesh has polygons")
	assert_true(mesh.resource_path != MapNav.saved_path(ALESIA), "not alesia's saved mesh")
	assert_true(catcher.lines.is_empty(), "no warning or error: %s" % "; ".join(catcher.lines))
	m.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MAP))
	assert_true(not FileAccess.file_exists(TMP_MAP), "temporary map removed")


func test_bake_navmesh_false_skips_load_and_bake() -> void:
	var m: MatchRoot = await _start(ALESIA, false)
	assert_eq(m.nav_bakes, 0, "no bake")
	var mesh := _region(m).navigation_mesh
	assert_true(mesh == null or mesh.resource_path != MapNav.saved_path(ALESIA), "the region keeps the scene's mesh, not the saved one")
	m.queue_free()


func test_bot_paths_and_walks_up_the_hill_on_the_loaded_mesh() -> void:
	var m: MatchRoot = await _start(MAP, true, true, hill_zone())
	var nav := _region(m)
	assert_eq(nav.navigation_mesh.resource_path, MapNav.saved_path(MAP), "test_300 runs on the loaded mesh")
	assert_eq(m.nav_bakes, 0, "no runtime bake")
	var builder := m.map.get_node("ArtBuilder")
	var terrain: MapTerrain = builder.terrain
	var chunks: MapChunks = builder.chunks
	var peak := Vector3(HILL.x, terrain.height_at(HILL.x, HILL.y), HILL.y)
	assert_true(peak.y > 12.0, "the hill top is about 12.3 m high: %s" % peak.y)
	var from := Vector3(30.0, 0.0, 30.0)
	var path: PackedVector3Array = await _synced_path(nav, from, peak)
	assert_true(path.size() >= 2, "a path from the flat centre to the peak exists (%d points)" % path.size())
	if path.size() < 2:
		m.queue_free()
		return
	assert_true(path[path.size() - 1].distance_to(peak) <= 1.5, "the path ends at the peak: %s vs %s" % [path[path.size() - 1], peak])
	var cells := {}
	var worst_off := -INF
	var lowest_off := INF
	var worst_drop := 0.0
	for i in path.size():
		var p := path[i]
		var off := p.y - terrain.height_at(p.x, p.z)
		worst_off = maxf(worst_off, off)
		lowest_off = minf(lowest_off, off)
		if i > 0:
			worst_drop = maxf(worst_drop, path[i - 1].y - p.y)
			var steps := ceili(path[i - 1].distance_to(p))
			for s in steps + 1:
				var q := path[i - 1].lerp(p, float(s) / float(maxi(steps, 1)))
				cells[MapChunks.index_for(q.x, q.z, chunks.half_m, chunks.chunk_size_m, chunks.per_side)] = true
	assert_true(cells.size() >= 2, "the path crosses chunk cells: %s" % [cells.keys()])
	assert_true(worst_drop <= 0.5, "the path rises up the gentle side (largest drop %.2f m)" % worst_drop)
	assert_true(path[path.size() - 1].y - path[0].y > 10.0, "the path climbs the hill")
	# The mesh rides on the voxelised ground: about +0.27 m on the flat (one cell_height up) and up to about
	# +0.63 m where one flat polygon spans the convex hillside; it never dips under the terrain.
	assert_true(lowest_off >= -0.1 and worst_off <= 0.7, "every path point lies on the terrain (%.2f to %.2f m above it)" % [lowest_off, worst_off])
	var loaded_length := _length(path)

	# A real bot walks it: the hill zone gives it the peak as its goal; everyone else is idle on the flat.
	var bot: Pawn = m.bots[0]
	var i := 0
	for b in m.bots:
		if b == bot:
			continue
		b.get_node("Brain").set_physics_process(false)
		b.global_position = Vector3(-50.0 + float(i % 6) * 4.0, 0.2, -50.0 + float(i / 6) * 4.0)
		i += 1
	m.local_player.global_position = Vector3(-50.0, 0.2, -30.0)
	var foot := Vector2(56.0, 56.0)
	bot.global_position = Vector3(foot.x, terrain.height_at(foot.x, foot.y) + 0.2, foot.y)
	bot.velocity = Vector3.ZERO
	var start_y := bot.global_position.y
	var lowest := INF
	var limit := Engine.physics_ticks_per_second * 20
	var n := 0
	while bot.global_position.y - start_y < 8.0 and n < limit:
		await frames(1)
		var at := bot.global_position
		lowest = minf(lowest, at.y - terrain.height_at(at.x, at.z))
		n += 1
	assert_true(bot.global_position.y - start_y >= 8.0, "the bot climbed %.1f m in %d frames (goal %s)" % [bot.global_position.y - start_y, n, bot.get_node("Brain").goal_kind])
	assert_true(lowest >= -0.3, "the bot never fell below the terrain (lowest %.2f m)" % lowest)

	# The same query on a freshly baked mesh of the same scene gives the same path.
	nav.navigation_mesh = nav.navigation_mesh.duplicate() as NavigationMesh
	var iteration := NavigationServer3D.map_get_iteration_id(nav.get_navigation_map())
	nav.bake_navigation_mesh(false)
	var baked_path: PackedVector3Array = await _synced_path(nav, from, peak, iteration)
	assert_true(absf(_length(baked_path) - loaded_length) <= 0.5, "baked path %.2f m vs loaded %.2f m" % [_length(baked_path), loaded_length])
	print("SAVED_NAV_HILL path_points=%d cells=%d above_terrain_m=%.2f..%.2f loaded_m=%.2f baked_m=%.2f climbed_m=%.1f frames=%d lowest_m=%.2f" % [
			path.size(), cells.size(), lowest_off, worst_off, loaded_length, _length(baked_path), bot.global_position.y - start_y, n, lowest])
	m.queue_free()


func _clean_tmp() -> void:
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)
