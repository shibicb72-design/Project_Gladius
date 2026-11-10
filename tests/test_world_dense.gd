extends "res://tests/test_case.gd"

func _gap(a: StaticBody3D, b: StaticBody3D) -> float:
	var sa: Vector3 = a.get_node("Shape").shape.size
	var sb: Vector3 = b.get_node("Shape").shape.size
	var d := (a.position - b.position).abs() - (sa + sb) * 0.5
	return Vector2(maxf(d.x, 0), maxf(d.z, 0)).length()

func test_dense_cover_structure_spacing_and_clusters() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	tree.root.add_child(map)
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	var rules: Dictionary = cfg["rules"]
	var bodies: Array = map.get_node("ArtBuilder").cover_bodies
	assert_true(bodies.size() >= 64, "dense cover floor cannot silently return to 24")
	var vehicles := 0
	var tall := [0, 0, 0, 0]
	var low := [0, 0, 0, 0]
	var muzzle := float(DataRegistry.new().get_movement_cfg()["muzzle_height_m"])
	for i in bodies.size():
		var body: StaticBody3D = bodies[i]
		var shape := body.get_node("Shape") as CollisionShape3D
		var size := (shape.shape as BoxShape3D).size
		assert_eq(body.basis, Basis.IDENTITY, "axis aligned body " + String(body.name))
		assert_eq(shape.transform, Transform3D.IDENTITY, "axis aligned centered shape")
		assert_eq(body.get_child_count(), 2, "one Mesh and one Shape only")
		assert_true(body.get_node("Mesh") is MeshInstance3D, "direct Mesh child")
		var definition: Dictionary = cfg["types"][cfg["pieces"][i]["type"]]
		if bool(definition["coverable"]):
			assert_true(body.is_in_group(&"cover_wall") and size.y + 0.000001 >= 0.9, "coverable registration and height")
		if String(cfg["pieces"][i]["type"]).begins_with("wreck_"):
			vehicles += 1
		var quadrant := (2 if body.position.x < 0 else 0) + (1 if body.position.z < 0 else 0)
		if size.y >= float(rules["tall_height_m"]):
			tall[quadrant] += 1
		else:
			low[quadrant] += 1
		for j in range(i):
			var other: StaticBody3D = bodies[j]
			var other_size: Vector3 = other.get_node("Shape").shape.size
			var gap := _gap(body, other)
			assert_true(is_zero_approx(gap) or gap + 0.00001 >= float(rules["minimum_gap_m"]), "navigable gap " + String(body.name) + "/" + String(other.name))
			var delta := (body.position - other.position).abs()
			var extent := (size + other_size) * 0.5
			assert_true(delta.x >= extent.x - 0.00001 or delta.z >= extent.z - 0.00001, "no cover overlap")
			if size.y >= muzzle and other_size.y >= muzzle:
				var x_join := is_equal_approx(delta.x, extent.x) and delta.z < extent.z
				var z_join := is_equal_approx(delta.z, extent.z) and delta.x < extent.x
				assert_true(not x_join and not z_join, "no inaccessible joined high-wall ends")
	assert_true(vehicles >= 3, "cart, truck and APC wreck hulls")
	for q in 4:
		assert_true(tall[q] >= int(rules["quadrant_tall_minimum"]), "tall cover each quadrant")
		assert_true(low[q] >= int(rules["quadrant_low_minimum"]), "low cover each quadrant")
	for spot: Node3D in map.get_node("SquadSpawns").get_children():
		var count := 0
		for body: StaticBody3D in bodies:
			var d := Vector2(body.position.x - spot.position.x, body.position.z - spot.position.z).length()
			if d >= float(rules["spawn_cluster_near_m"]) and d <= float(rules["spawn_cluster_far_m"]) and body.position.length() < spot.position.length():
				count += 1
		assert_true(count >= int(rules["spawn_cluster_minimum"]), String(spot.name) + " approach cluster")
		print("WORLD_CLUSTER ", spot.name, " pieces=", count)
	# Was "every Nav child except Ground is cover_wall". W1: a Nav child is either cover (one box, cover_wall) or
	# a world kit piece (group "structure", several colliders, never cover_wall); never both, never neither.
	var structures := 0
	for body in map.get_node("Nav").get_children():
		if body.name != &"Ground":
			var is_structure: bool = body.is_in_group(WorldKit.GROUP)
			assert_true(body.is_in_group(&"cover_wall") != is_structure, String(body.name) + " is cover or a structure, exactly one")
			if is_structure:
				structures += 1
				assert_true(not body in bodies, String(body.name) + ": a structure is not in the cover list")
	# W2: the solid rim decor (arches, rocks) is in the same group: solid, parsed by the bake, never cover.
	var builder := map.get_node("ArtBuilder")
	assert_eq(structures, (builder.structure_bodies as Array).size() + (builder.decor_bodies as Array).size(), "every structure under Nav is a kit piece or a solid decor body the builder placed")
	map.free()

## W3: the outer ring. Its cover list (ring_pieces) and the world kit pieces share one band and one set of
## clearances (ring_rules); the inner band's list, rules and checks above are untouched.
func test_outer_ring_band_gaps_and_clearances() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	tree.root.add_child(map)
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	var rules: Dictionary = cfg["ring_rules"]
	assert_true(bool(rules["_placeholder"]) and String(rules["_todo"]).contains("OQ-WORLD-DENSE"), "ring rules are placeholder data with their OQ id")
	assert_true(float(rules["min_radius_m"]) > float(cfg["rules"]["max_radius_m"]), "the ring's band starts outside the inner band")
	var builder := map.get_node("ArtBuilder")
	var ring: Array = builder.ring_bodies
	var pieces: Array = cfg["ring_pieces"]
	assert_true(ring.size() >= int(rules["minimum_count"]), "at least %s ring cover pieces (%d)" % [rules["minimum_count"], ring.size()])
	assert_eq(ring.size(), pieces.size(), "ring bodies mirror the ring list")
	var gap_min := float(rules["minimum_gap_m"])
	var muzzle := float(DataRegistry.new().get_movement_cfg()["muzzle_height_m"])
	var spawns: Dictionary = DataRegistry.new().load_file(DataRegistry.MAP_PATH)["spawns"]
	var spot_ids := spawns.keys()
	spot_ids.sort()
	var spots: Array[Vector2] = []
	for id: String in spot_ids:
		spots.append(Vector2(float(spawns[id][0]), float(spawns[id][2])))
	# Everything else that stands on the map: inner cover, the scene's walls and camp blocks, kit pieces, solid decor.
	var others: Array[Dictionary] = []
	for solid in WorldRing.solids(map):
		if not solid["body"] in ring:
			others.append(solid)
	var rects: Array[Rect2] = []
	var quadrant := [0, 0, 0, 0]
	var band := Vector2(INF, 0.0)
	for i in ring.size():
		var body: StaticBody3D = ring[i]
		var entry: Dictionary = pieces[i]
		var id := String(body.name)
		assert_eq(id, String(entry["id"]), "ring id")
		assert_eq(body.position, LowpolyKit.vec(entry["at"]), id + ": position mirror")
		assert_eq(body.basis, Basis.IDENTITY, id + ": axis aligned")
		assert_true(body.is_in_group(&"ring_cover") and body.is_in_group(&"cover_wall") and not body.is_in_group(WorldKit.GROUP), id + ": ring cover is cover, not a structure")
		assert_true(not body in builder.cover_bodies, id + ": not in the inner band's list")
		assert_true(body.get_child_count() == 1 and body.get_node("Shape").transform == Transform3D.IDENTITY, id + ": one centred box")
		var size: Vector3 = (body.get_node("Shape").shape as BoxShape3D).size
		assert_eq(size, LowpolyKit.vec(cfg["types"][entry["type"]]["size"]), id + ": collider size mirror")
		assert_true(is_equal_approx(body.position.y, size.y * 0.5), id + ": stands on the ground")
		var rect: Rect2 = WorldRing.footprint(body)["rect"]
		var radial := WorldRing.radial_range(rect)
		band = Vector2(minf(band.x, radial.x), maxf(band.y, radial.y))
		assert_true(radial.x >= float(rules["min_radius_m"]) and radial.y <= float(rules["max_radius_m"]), "%s: entire footprint in the ring band (r %.1f to %.1f)" % [id, radial.x, radial.y])
		quadrant[(2 if body.position.x < 0 else 0) + (1 if body.position.z < 0 else 0)] += 1
		for j in range(i):
			var gap := WorldRing.rect_gap(rect, rects[j])
			assert_true(is_zero_approx(gap) or gap + 0.00001 >= gap_min, "navigable gap %s/%s (%.2f m)" % [id, ring[j].name, gap])
			assert_true(not rect.grow(-0.001).intersects(rects[j]), "no ring cover overlap %s/%s" % [id, ring[j].name])
			var other_size: Vector3 = (ring[j].get_node("Shape").shape as BoxShape3D).size
			if size.y >= muzzle and other_size.y >= muzzle:
				assert_true(gap + 0.00001 >= gap_min, "no joined high pieces %s/%s" % [id, ring[j].name])
		rects.append(rect)
		for other in others:
			var gap := WorldRing.rect_gap(rect, other["rect"])
			assert_true(gap + 0.00001 >= gap_min, "%s keeps a walkable gap from %s (%.2f m)" % [id, other["name"], gap])
		for s in spots.size():
			assert_true(WorldRing.rect_distance(spots[s], rect) + 0.00001 >= float(rules["spawn_clear_m"]), "%s keeps clear of %s" % [id, spot_ids[s]])
			var lane := WorldRing.rect_segment_distance(rect, spots[s], spots[(s + 1) % spots.size()])
			assert_true(lane + 0.00001 >= float(rules["lane_clear_m"]), "%s keeps clear of the lane %s-%s (%.2f m)" % [id, spot_ids[s], spot_ids[(s + 1) % spots.size()], lane])
	for q in 4:
		assert_true(quadrant[q] >= int(rules["quadrant_minimum"]), "ring cover in every quadrant (%s)" % str(quadrant))
	# The kit pieces stand in the same band with the same clearances; two of them may touch (a wall on a gate,
	# a ramp on a span) but not overlap, and they keep the gap from everything that is not a kit piece.
	var kit: Array = builder.structure_bodies
	var kit_rects: Array[Rect2] = []
	for i in kit.size():
		var body: StaticBody3D = kit[i]
		var id := String(body.name)
		var rect: Rect2 = WorldRing.footprint(body)["rect"]
		var radial := WorldRing.radial_range(rect)
		assert_true(radial.x >= float(rules["min_radius_m"]) and radial.y <= float(rules["max_radius_m"]), "%s: entire footprint in the ring band (r %.1f to %.1f)" % [id, radial.x, radial.y])
		for j in range(i):
			assert_true(not rect.grow(-0.01).intersects(kit_rects[j]), "kit pieces %s/%s do not overlap" % [id, kit[j].name])
		kit_rects.append(rect)
		for other in others:
			if not other["body"] in kit:
				var gap := WorldRing.rect_gap(rect, other["rect"])
				assert_true(gap + 0.00001 >= gap_min, "%s keeps a walkable gap from %s (%.2f m)" % [id, other["name"], gap])
		for s in spots.size():
			assert_true(WorldRing.rect_distance(spots[s], rect) + 0.00001 >= float(rules["spawn_clear_m"]), "%s keeps clear of %s" % [id, spot_ids[s]])
			assert_true(WorldRing.rect_segment_distance(rect, spots[s], spots[(s + 1) % spots.size()]) + 0.00001 >= float(rules["lane_clear_m"]), "%s keeps clear of the lane from %s" % [id, spot_ids[s]])
	# One batch per ring cover type draws the pieces.
	var drawn := 0
	for batch: MultiMeshInstance3D in builder.get_node("RingCover").get_children():
		assert_true(batch.multimesh.mesh is ArrayMesh and batch.material_override is StandardMaterial3D, String(batch.name) + ": kit mesh with the cover material")
		drawn += batch.multimesh.instance_count
	assert_eq(drawn, ring.size(), "every ring piece is drawn by its type's batch")
	print("WORLD_RING cover=", ring.size(), " kit_pieces=", kit.size(), " footprint_radius_min=", snappedf(band.x, 0.01), " max=", snappedf(band.y, 0.01), " quadrants=", quadrant)
	map.free()

func test_new_composite_meshes_share_data_and_are_deterministic() -> void:
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	for kind in ["tall_wall", "sandbag_nest", "sandbag_nest_side", "crate_stack", "barrier_line", "wreck_cart", "wreck_truck", "wreck_apc", "rubble_pile"]:
		var mesh := LowpolyKit.build_cover(cfg["types"][kind])
		assert_true(mesh.surface_get_array_len(0) > 0, "nonempty " + kind)
		assert_eq(mesh.surface_get_arrays(0), LowpolyKit.build_cover(cfg["types"][kind]).surface_get_arrays(0), "deterministic " + kind)
