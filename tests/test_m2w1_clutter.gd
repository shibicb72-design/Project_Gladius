extends "res://tests/test_case.gd"
## M2W1 item 5: clutter and field scatter (data/art_clutter.json, scripts/visual/world_clutter.gd,
## tools/blender/m2w1_clutter.py -> assets/generated/world/m2w1_clutter.glb). Looks only: MapChunks instances (source
## "clutter"), no body, no collider, nothing under Nav, no shadows. Every built instance keeps every rule of the data
## (the doorway lanes here are the REAL navigation paths on the saved mesh between points lane_half_m either side of
## each doorway, gate and ground-level opening; the builder used straight lines), budgets hold, placement is
## deterministic, the switch off and the fixture maps build none. The 1 km map is built once as a static (freed by
## test_zz), plus one build with the switch off and one more with it on (determinism).
const Perf := preload("res://tests/test_astra_perf.gd")
const MAP_1KM := "res://data/maps/alesia_1km.json"
const FIXTURES := ["res://data/maps/alesia_section.json", "res://data/maps/test_300.json"]

static var _built: Node3D


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return WorldClutter.config()


func _build(map_path: String) -> Node3D:
	var def := DataRegistry.parse_quiet(map_path)
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", map_path)
	_tree().root.add_child(map)
	return map


func _map() -> Node3D:
	WorldClutter.enabled_override = 1
	if not is_instance_valid(_built):
		_built = _build(MAP_1KM)
	return _built


func _batches(map: Node) -> Array[MultiMeshInstance3D]:
	return (map.get_node("ArtBuilder/Chunks") as MapChunks).batches(WorldClutter.SOURCE)


## [type, Transform3D] of every built clutter instance (from the batches' transforms meta: a headless renderer keeps
## no instance data to read back).
func _instances(map: Node) -> Array:
	var out: Array = []
	for b in _batches(map):
		for t: Transform3D in b.get_meta(&"transforms"):
			out.append([String(b.get_meta(&"type")), t])
	return out


func test_meshes_load_with_the_kit_vertex_data_low_and_within_caps() -> void:
	var cap_h := float(WorldClutter.rules()["max_height_m"])
	var types := WorldClutter.types()
	assert_true(types.size() >= 14 and types.size() <= 20, "14 to 20 clutter types (%d)" % types.size())
	for type: String in types:
		var m := WorldClutter.mesh(type)
		assert_true(m != null, "%s: mesh loads from the glb" % type)
		if m == null:
			continue
		assert_eq(m.get_surface_count(), 1, "%s: one surface" % type)
		var arrays := m.surface_get_arrays(0)
		for slot: int in [Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_TANGENT, Mesh.ARRAY_NORMAL]:
			assert_true(arrays[slot] != null and (arrays[slot] as Variant).size() > 0, "%s: vertex array %d present (the kit's vertex data)" % [type, slot])
		var want: Material = WorldClutter.foliage_material() if WorldClutter.uses_foliage(type) else WorldKit.material()
		assert_true(m.surface_get_material(0) == want, "%s: the %s material" % [type, "foliage" if WorldClutter.uses_foliage(type) else "world"])
		var tris := Perf.triangles(m)
		var info := WorldClutter.info(type)
		# M2W1 astraB: a composed group (data "compose", merged at load from glb meshes) may pass 250 up to its own cap.
		var composed := WorldClutter.type_cfg(type).has("compose")
		assert_true(tris >= 12 and tris <= int(WorldClutter.type_cfg(type)["max_tris"]) and (tris <= 250 or composed), "%s: %d triangles within its cap" % [type, tris])
		assert_true(float(info["top"]) <= cap_h, "%s: top %.3f m <= %.2f (upright: instances turn about y only)" % [type, info["top"], cap_h])
		print("M2W1_CLUTTER_TYPE %s kind=%s tris=%d top=%.3f radius=%.2f footprint=%s" % [type, WorldClutter.type_cfg(type)["kind"], tris, info["top"], info["radius"], str((info["half"] as Vector2) * 2.0)])


func test_clutter_is_draw_only() -> void:
	var map := _map()
	var batches := _batches(map)
	assert_true(batches.size() > 0, "nonvacuous: %d clutter batches" % batches.size())
	var nav := map.get_node("Nav")
	for b in batches:
		assert_true(not nav.is_ancestor_of(b), "%s is not under Nav" % b.name)
		assert_eq(b.get_child_count(), 0, "%s has no children (no body, no shape)" % b.name)
		assert_eq(b.get_groups().size(), 0, "%s is in no group" % b.name)
		assert_eq(b.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s casts no shadow" % b.name)
		assert_true(String(b.get_meta(&"class")).begins_with("clutter_") and not bool(b.get_meta(&"collides")), "%s: a clutter class, not colliding" % b.name)
	for node in map.find_children("*", "", true, false):
		assert_true(not String(node.name).to_lower().contains("clutter") or node is MultiMeshInstance3D or node.get_parent() is MapChunks, "no other clutter node: %s" % node.get_path())


func test_built_instances_break_no_rule_on_the_real_lanes() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var def := DataRegistry.parse_quiet(MAP_1KM)
	var ctx := WorldClutter.context(builder, def)
	# The real lanes: the navigation path on the saved mesh between the two lane ends.
	# On the map's own Nav region and the world's navigation map, as tests/test_stuck_spots.gd does (a map made
	# with map_create printed an edge-merge warning for this mesh that the world's map does not print).
	var nav := map.get_node("Nav") as NavigationRegion3D
	nav.navigation_mesh = MapNav.load_saved(MAP_1KM)
	var nav_map := nav.get_navigation_map()
	var terrain: MapTerrain = builder.terrain
	var probe := Vector3(60.0, terrain.height_at(60.0, -200.0), -200.0)
	for n in 600:
		await _tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(nav_map) > 0 and NavigationServer3D.map_get_closest_point(nav_map, probe).distance_to(probe) < 5.0:
			break
	assert_true(NavigationServer3D.map_get_closest_point(nav_map, probe).distance_to(probe) < 5.0, "the saved mesh's navigation map synced (its polygons answer)")
	var lanes := 0
	var straight := 0
	for item: Dictionary in ctx["items"]:
		if String(item["kind"]) != "lane":
			continue
		var ends: PackedVector2Array = item["line"]
		var a := Vector3(ends[0].x, terrain.height_at(ends[0].x, ends[0].y) + 0.3, ends[0].y)
		var b := Vector3(ends[1].x, terrain.height_at(ends[1].x, ends[1].y) + 0.3, ends[1].y)
		var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
		lanes += 1
		if path.size() < 2:
			straight += 1  # no path (an opening the mesh does not cross): the straight line stays the lane
			continue
		var line := PackedVector2Array()
		for p in path:
			line.append(Vector2(p.x, p.z))
		item["line"] = line
	WorldClutter.index(ctx)
	assert_true(lanes >= 100, "nonvacuous: %d doorway lanes" % lanes)
	var scatter: Dictionary = _cfg()["scatter"]
	var bad := {}
	var checked := 0
	var shown := 0
	for inst: Array in _instances(map):
		var why := WorldClutter.instance_problem(ctx, inst[0], inst[1], scatter.has(inst[0]))
		checked += 1
		if why != "":
			bad[why] = int(bad.get(why, 0)) + 1
			if shown < 8:
				shown += 1
				print("M2W1_CLUTTER_VIOLATION %s %s at %s" % [why, inst[0], (inst[1] as Transform3D).origin])
	assert_true(checked > 1000, "nonvacuous: %d instances checked" % checked)
	assert_eq(bad, {}, "no built instance breaks a rule (navigation lanes)")
	print("M2W1_CLUTTER_RULES instances=%d lanes=%d lanes_without_path=%d violations=%s" % [checked, lanes, straight, str(bad)])


func test_rules_catch_what_they_should() -> void:
	# Nonvacuous rule check: a crate in a barracks' doorway, inside a wall and on a ladder foot breaks a rule.
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var ctx := WorldClutter.context(builder, DataRegistry.parse_quiet(MAP_1KM))
	var door := builder.door_bodies[0] as Door
	assert_true(WorldClutter.instance_problem(ctx, "supply_crate", Transform3D(Basis.IDENTITY, door.position)) != "", "a crate in a doorway breaks a rule")
	var wall: Node3D = builder.structure_bodies[0]
	assert_true(WorldClutter.instance_problem(ctx, "supply_crate", Transform3D(Basis.IDENTITY, wall.position)) != "", "a crate in a wall breaks a rule")
	var ladder: Node3D = builder.ladders[0]
	var foot := ladder.position + ladder.basis * Vector3(0, 0, 0.9)
	assert_true(WorldClutter.instance_problem(ctx, "cippus", Transform3D(Basis.IDENTITY, foot)) != "", "a stone at a ladder foot breaks a rule")
	# Only the ladder rule: a context holding just the ladder points.
	var only := {"items": [], "grid": {}, "terrain": ctx["terrain"], "rules": ctx["rules"]}
	for item: Dictionary in ctx["items"]:
		if String(item["what"]) == "ladder":
			(only["items"] as Array).append(item)
	WorldClutter.index(only)
	assert_eq(WorldClutter.instance_problem(only, "cippus", Transform3D(Basis.IDENTITY, foot)), "ladder", "the ladder rule itself catches it")


func test_dressing_mostly_survives() -> void:
	var report: Dictionary = _map().get_node("ArtBuilder").clutter_report
	var tried := 0
	var kept := 0
	var lines := PackedStringArray()
	for piece: String in report["dressing"]:
		var c: Array = report["dressing"][piece]
		tried += int(c[0])
		kept += int(c[1])
		lines.append("%s %d/%d" % [piece, c[1], c[0]])
	var share := float(kept) / maxf(float(tried), 1.0)
	assert_true(tried > 100, "nonvacuous: %d dressing instances tried" % tried)
	assert_true(share >= float(WorldClutter.rules()["min_kept_share"]), "%.2f of the dressing survives the rules (min %.2f)" % [share, WorldClutter.rules()["min_kept_share"]])
	print("M2W1_CLUTTER_DRESSING kept=%d/%d (%.2f) %s dropped=%s capped=%d" % [kept, tried, share, ", ".join(lines), str(report["dropped"]), int(report["capped"])])
	print("M2W1_CLUTTER_SCATTER %s instances=%d build_ms=%d" % [str(report["scatter"]), int(report["instances"]), int(report["ms"])])


## M2W1 r2b (C1): long supply edges instead of single props, foreground pockets along the roads, fewer lone patches
## mid-field, and "join" entries only where their type already has a batch.
func test_edges_pockets_and_no_single_props() -> void:
	var cfg := _cfg()
	var dressing: Dictionary = cfg["dressing"]
	var camp_groups := ["supply_row", "arms_trough", "fire_ring"]
	for piece: String in ["barracks", "gate"]:
		var n := 0
		for e: Dictionary in dressing[piece]:
			if camp_groups.has(String(e["type"])):
				n += 1
		assert_true(n >= 3, "%s: an edge run of %d camp groups" % [piece, n])
	for piece: String in dressing:
		if piece.begins_with("_"):
			continue
		for e: Dictionary in dressing[piece]:
			assert_true(not ["stores", "supply_crate", "ammo_case", "bedrolls", "brazier_bowl"].has(String(e["type"])), "%s: no single prop (%s)" % [piece, e["type"]])
	var report: Dictionary = _map().get_node("ArtBuilder").clutter_report
	assert_true(int(report.get("road_pockets", 0)) >= 150, "foreground pockets along the roads: %d" % int(report.get("road_pockets", 0)))
	assert_true(int((report["scatter"] as Dictionary).get("veg_patch", 0)) < 4654, "fewer lone veg patches than before r2b (4654): %d" % int((report["scatter"] as Dictionary).get("veg_patch", 0)))
	# Every chunk that draws a join-able group type draws it for a reason other than a join entry: the batch count
	# cap below (246, the count before r2b) is the proof that joins add none.
	print("M2W1_CLUTTER_R2B road_pockets=%d unjoined=%d" % [int(report.get("road_pockets", 0)), int(report.get("unjoined", 0))])


func test_budgets() -> void:
	var map := _map()
	var budgets: Dictionary = _cfg()["budgets"]
	var per_chunk := {}
	var instances := 0
	for b in _batches(map):
		per_chunk[b.get_parent().name] = int(per_chunk.get(b.get_parent().name, 0)) + 1
		instances += b.multimesh.instance_count
	var worst := 0
	for k: String in per_chunk:
		worst = maxi(worst, int(per_chunk[k]))
	assert_true(worst <= int(budgets["batches_per_chunk"]), "at most %d clutter batches in a chunk (%d)" % [budgets["batches_per_chunk"], worst])
	# M2W1 astraB: clutter batches map-wide (was 503 at 18bb0ab).
	assert_true(_batches(map).size() <= int(budgets["batches"]), "%d clutter batches, cap %d" % [_batches(map).size(), budgets["batches"]])
	assert_true(instances <= int(budgets["instances"]), "%d clutter instances, cap %d" % [instances, budgets["instances"]])
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var gate := preload("res://tools/gen_alesia.gd").dir_of(0.0) * float(DataRegistry.parse_quiet(MAP_1KM)["generator"]["outer_wall"]["radius_m"])
	var points := {
		"citadel_top": Vector3(0.0, terrain.height_at(0.0, 5.0) + MapChunks.EYE_M, 5.0),
		"porta_aquilae": Vector3(gate.x, terrain.height_at(gate.x, gate.y) + MapChunks.EYE_M, gate.y),
		"field_corner": MapChunks.standard_points(map)["corner"],
		"centre_standard": MapChunks.standard_points(map)["centre"],
	}
	for name: String in points:
		var p: Vector3 = points[name]
		var tris := 0
		var count := 0
		for b in _batches(map):
			if b.visibility_range_end > 0.0 and p.distance_to(MapChunks.range_centre(b)) > b.visibility_range_end:
				continue
			tris += Perf.triangles(b.multimesh.mesh) * b.multimesh.instance_count
			count += 1
		assert_true(tris <= int(budgets["visible_tris"]), "%s: %d clutter triangles in range, cap %d" % [name, tris, budgets["visible_tris"]])
		print("M2W1_CLUTTER_VISIBLE point=%s clutter_tris=%d clutter_batches=%d (cap %d; frustum ignored)" % [name, tris, count, budgets["visible_tris"]])
	var px: Dictionary = MapChunks.proxies(map)["per_map"]
	print("M2W1_CLUTTER_BUDGET instances=%d batches=%d chunks=%d max_per_chunk=%d map_multimesh=%d map_mesh_instances=%d" % [instances, _batches(map).size(), per_chunk.size(), worst, px["multimesh"], px["mesh_instances"]])


func test_switch_off_builds_none_and_the_same_bodies_deterministic_on() -> void:
	var map := _map()
	var on_bodies := map.find_children("*", "CollisionObject3D", true, false).size()
	var first := _instances(map)
	WorldClutter.enabled_override = 0
	var off := _build(MAP_1KM)
	assert_eq(_batches(off).size(), 0, "switch off: no clutter batch")
	assert_eq(off.find_children("*", "CollisionObject3D", true, false).size(), on_bodies, "the same CollisionObject3D count with and without clutter (%d)" % on_bodies)
	assert_eq(off.find_children("*", "CollisionShape3D", true, false).size(), map.find_children("*", "CollisionShape3D", true, false).size(), "the same CollisionShape3D count")
	off.free()
	WorldClutter.enabled_override = 1
	var again := _build(MAP_1KM)
	var second := _instances(again)
	again.free()
	assert_eq(second.size(), first.size(), "two builds place the same number of instances")
	var same := second.size() == first.size()
	for i in mini(first.size(), second.size()):
		if first[i][0] != second[i][0] or not (first[i][1] as Transform3D).is_equal_approx(second[i][1]):
			same = false
			break
	assert_true(same, "two builds place the same types at the same transforms")
	assert_true(bool(GraphicsPresets.new().get_preset().get("art_clutter_enabled", false)), "default preset: clutter on")


func test_fixture_maps_build_none() -> void:
	WorldClutter.enabled_override = 1
	for path: String in FIXTURES:
		assert_true(WorldClutter.map_block(path).is_empty(), "%s has no clutter block" % path)
		var map := _build(path)
		assert_eq(_batches(map).size(), 0, "%s: no clutter batch" % path)
		map.free()
	MapTerrain.clear_cache()


## Last in this file: frees the 1 km map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	WorldClutter.enabled_override = -1
	MapTerrain.clear_cache()
	assert_true(true, "freed")
