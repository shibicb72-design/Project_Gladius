extends "res://tests/test_case.gd"
## M2P1A: tree counts per map and per chunk (MapChunks.proxies), a proxy, not measured frame cost, checked
## against the placeholder limits in data/map_build.json "proxy_limits" (OQ-MAP-PROXY). One map is built at a
## time and freed before the next.

const MAPS := {
	"alesia_section": "res://scenes/maps/alesia_section.tscn",
	"test_300": "res://scenes/maps/test_300.tscn",
}
const KEYS := ["multimesh", "mesh_instances", "materials", "bodies"]


func _build(scene_path: String) -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(scene_path).instantiate()
	if scene_path.ends_with("test_300.tscn"):  # the scene names no map; the loader sets it, as MatchRoot does
		map.get_node("ArtBuilder").set("map_json", "res://data/maps/test_300.json")
	tree.root.add_child(map)
	return map


func _limits() -> Dictionary:
	return MapChunks.config().get("proxy_limits", {})


func _at(index: Vector2i) -> String:
	return "@(%d,%d)" % [index.x, index.y]


func test_limits_are_a_placeholder_from_data() -> void:
	var limits := _limits()
	assert_true(bool(limits.get("_placeholder", false)), "the proxy limits are a placeholder")
	assert_true(String(limits.get("_todo", "")).contains("OQ-MAP-PROXY"), "the limits name their open question")
	for scope: String in ["per_chunk", "per_map"]:
		for key: String in KEYS:
			assert_true(int((limits.get(scope, {}) as Dictionary).get(key, 0)) > 0, "a %s limit for %s" % [scope, key])


func test_counts_within_limits_on_both_maps() -> void:
	var limits := _limits()
	for id: String in MAPS:
		var map := _build(MAPS[id])
		var counts := MapChunks.proxies(map)
		map.free()
		var per_map: Dictionary = counts["per_map"]
		var per_chunk: Dictionary = counts["per_chunk"]
		var at: Dictionary = counts["per_chunk_at"]
		for key: String in KEYS:
			assert_true(int(per_map[key]) > 0, "%s: nonvacuous per-map %s" % [id, key])
			if key == "mesh_instances" and id == "test_300":
				# Stop 6: test_300 has no scene walls and its decor is batched, so no chunk holds an unbatched look.
				assert_eq(int(per_chunk[key]), 0, "%s: no unbatched look in any chunk" % id)
			else:
				assert_true(int(per_chunk[key]) > 0, "%s: nonvacuous per-chunk %s" % [id, key])
			assert_true(int(per_chunk[key]) <= int(per_map[key]), "%s: a chunk holds no more %s than the map" % [id, key])
		assert_true(int(per_map["chunks"]) > 1 and int(per_map["batches"]) > 0 and int(per_map["batch_instances"]) > 0, id + ": chunks and batches built")
		var problems := MapChunks.proxy_problems(counts, limits)
		assert_true(problems.is_empty(), "%s: within the proxy limits: %s" % [id, "; ".join(problems)])
		print("MAP_PROXY map=", id, " proxy, not measured: chunks=", per_map["chunks"], " batches=", per_map["batches"],
				" batch_instances=", per_map["batch_instances"], " multimesh=", per_map["multimesh"],
				" mesh_instances=", per_map["mesh_instances"], " materials=", per_map["materials"], " bodies=", per_map["bodies"],
				" chunk_max_multimesh=", per_chunk["multimesh"], _at(at["multimesh"]),
				" chunk_max_mesh_instances=", per_chunk["mesh_instances"], _at(at["mesh_instances"]),
				" chunk_max_materials=", per_chunk["materials"], _at(at["materials"]),
				" chunk_max_bodies=", per_chunk["bodies"], _at(at["bodies"]))


func test_limit_check_fails_when_a_limit_is_exceeded() -> void:
	var map := _build(MAPS["alesia_section"])
	var counts := MapChunks.proxies(map)
	map.free()
	var limits := _limits()
	assert_true(MapChunks.proxy_problems(counts, limits).is_empty(), "the real limits pass")
	for scope: String in ["per_map", "per_chunk"]:
		for key: String in KEYS:
			var tight := limits.duplicate(true)
			tight[scope][key] = 0
			var problems := MapChunks.proxy_problems(counts, tight)
			assert_eq(problems.size(), 1, "%s %s set to 0 gives one problem" % [scope, key])
			assert_true(problems.size() == 1 and problems[0].contains(key), "the problem names the count: " + key)
	var missing := {"per_map": {"no_such_count": 1}}
	assert_eq(MapChunks.proxy_problems(counts, missing).size(), 1, "a limit without a count is a problem")


func test_per_map_counts_agree_with_a_recount_on_alesia() -> void:
	var map := _build(MAPS["alesia_section"])
	var counts: Dictionary = MapChunks.proxies(map)["per_map"]
	var recount := {"multimesh": 0, "mesh_instances": 0, "bodies": 0}
	var instances := 0
	var stack: Array[Node] = [map]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MultiMeshInstance3D:
			recount["multimesh"] += 1
		elif node is MeshInstance3D:
			recount["mesh_instances"] += 1
		elif node is StaticBody3D:
			recount["bodies"] += 1
		stack.append_array(node.get_children())
	for chunk in map.get_node("ArtBuilder/Chunks").get_children():
		for batch in chunk.get_children():
			instances += (batch as MultiMeshInstance3D).multimesh.instance_count
	map.free()
	for key: String in recount:
		assert_eq(int(counts[key]), int(recount[key]), "alesia per-map %s agrees with the recount" % key)
	assert_eq(int(counts["batch_instances"]), instances, "alesia batch instances agree with the recount")
	assert_true(int(counts["multimesh"]) > 0 and int(counts["mesh_instances"]) > 0 and int(counts["bodies"]) > 0, "nonvacuous recount")


# --- M2P1C stop 8: visible-at-a-point counts (MapChunks.visible_proxies) against proxy_limits "visible" ---

const POINTS := ["centre", "corner"]
const VISIBLE_KEYS := ["batches", "shadow"]


func test_visible_limits_are_placeholders_from_data() -> void:
	var limits := _limits()
	var visible: Dictionary = limits.get("visible", {})
	assert_true(String(limits.get("_visible_note", "")).contains("times 1.5"), "the visible limits state their rule")
	for point: String in POINTS:
		for key: String in VISIBLE_KEYS:
			assert_true(int((visible.get(point, {}) as Dictionary).get(key, 0)) > 0, "a visible %s limit for %s" % [point, key])


func test_standard_points_are_the_centre_and_the_ground_corner() -> void:
	for id: String in MAPS:
		var map := _build(MAPS[id])
		var half := (map.get_node("ArtBuilder/Chunks") as MapChunks).half_m
		var points := MapChunks.standard_points(map)
		map.free()
		assert_true(half > 0.0, id + ": the map has a ground")
		assert_eq(points["centre"], Vector3(0.0, MapChunks.EYE_M, 0.0), id + ": the centre is the origin at eye height")
		assert_eq(points["corner"], Vector3(-half, MapChunks.EYE_M, -half), id + ": the corner is the ground corner at eye height")


func test_visible_counts_within_limits_on_both_maps() -> void:
	var limits: Dictionary = _limits()["visible"]
	for id: String in MAPS:
		var map := _build(MAPS[id])
		var visible := MapChunks.visible_proxies(map)
		map.free()
		for point: String in POINTS:
			var v: Dictionary = visible[point]
			assert_true(int(v["batches"]) > 0 and int(v["shadow"]) > 0, "%s %s: nonvacuous" % [id, point])
			assert_true(int(v["shadow"]) <= int(v["batches"]) and int(v["batches"]) <= int(v["batches_total"]), "%s %s: shadow casters among the batches in range" % [id, point])
		var problems := MapChunks.visible_problems(visible, limits)
		assert_true(problems.is_empty(), "%s: within the visible limits: %s" % [id, "; ".join(problems)])
		print("MAP_VISIBLE map=", id, " proxy, not measured: centre batches=", visible["centre"]["batches"], " shadow=", visible["centre"]["shadow"],
				" corner batches=", visible["corner"]["batches"], " shadow=", visible["corner"]["shadow"], " of ", visible["centre"]["batches_total"])


func test_visible_limit_check_fails_when_a_limit_is_exceeded() -> void:
	var map := _build(MAPS["test_300"])
	var visible := MapChunks.visible_proxies(map)
	map.free()
	var limits: Dictionary = _limits()["visible"]
	assert_true(MapChunks.visible_problems(visible, limits).is_empty(), "the real limits pass")
	for point: String in POINTS:
		for key: String in VISIBLE_KEYS:
			var tight := limits.duplicate(true)
			tight[point][key] = 0
			var problems := MapChunks.visible_problems(visible, tight)
			assert_eq(problems.size(), 1, "%s %s set to 0 gives one problem" % [point, key])
			assert_true(problems.size() == 1 and problems[0].contains(point) and problems[0].contains(key), "the problem names the point and count")
	assert_eq(MapChunks.visible_problems(visible, {"centre": {"no_such_count": 1}}).size(), 1, "a limit without a count is a problem")
	assert_eq(MapChunks.visible_problems(visible, {"roof": {"batches": 1}}).size(), 1, "a limit at an unknown point is a problem")
