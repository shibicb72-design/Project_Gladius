extends "res://tests/test_case.gd"
## W1: world kit pieces (scripts/visual/world_kit.gd, data/maps/alesia_structures.json). Each type is checked
## alone, far from the map: deterministic mesh, colliders under every walkable surface, open volumes free,
## raised surfaces reachable on a baked navmesh. Then the pieces placed on the real map.
const Perf := preload("res://tests/test_astra_perf.gd")
const FAR := Vector3(0, 0, -3000)  # test stage, well away from anything another test left near the origin


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _types() -> Dictionary:
	return WorldKit.config()["types"]


func _rules() -> Dictionary:
	return WorldKit.config()["rules"]


func _stage_body(type: String) -> StaticBody3D:
	var body := WorldKit.build_body("Probe_" + type, type, _types()[type], FAR, 0.0)
	_tree().root.add_child(body)
	return body


## Points of a walk surface in piece space: a grid inset from the edges, on the plane the data describes.
func _walk_points(surface: Dictionary) -> PackedVector3Array:
	var steps := int(_rules()["walk_sample_steps"])
	var inset := float(_rules()["walk_edge_inset_m"])
	var size: Array = surface["size"]
	var half := Vector2(float(size[0]) * 0.5 - inset, float(size[1]) * 0.5 - inset)
	var rise := float(surface.get("rise", 0.0))
	var xf := LowpolyShapes.transform_of(surface)
	var out := PackedVector3Array()
	for ix in steps:
		for iz in steps:
			var x := lerpf(-half.x, half.x, float(ix) / (steps - 1))
			var z := lerpf(-half.y, half.y, float(iz) / (steps - 1))
			out.append(xf * Vector3(x, rise * z / float(size[1]), z))
	return out


func test_kit_data_is_placeholder_and_every_type_builds_a_deterministic_mesh() -> void:
	var cfg := WorldKit.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-WORLD-DENSE") and String(cfg["_todo"]).contains("OQ-ART-ASTRA"), "kit data is placeholder data with its OQ ids")
	var types := _types()
	for wanted in ["wall_walk", "wall_stair", "gate", "watchtower", "column", "colonnade", "pediment_front", "aqueduct_span",
			"aqueduct_ramp", "barracks", "tent", "stake_row", "eagle_standard", "ramp_block", "terrace_block"]:
		assert_true(types.has(wanted), "the kit has a " + wanted)
	var counts := {}
	var margin := float(_rules()["visual_margin_m"])
	for type: String in types:
		var definition: Dictionary = types[type]
		var mesh := WorldKit.build_mesh(definition)
		assert_true(mesh.get_surface_count() == 1 and Perf.triangles(mesh) > 0, type + ": one surface with triangles")
		assert_eq(mesh.surface_get_arrays(0), WorldKit.build_mesh(definition).surface_get_arrays(0), type + ": deterministic")
		assert_true(mesh.surface_get_material(0) == WorldKit.material(), type + ": the one shared kit material")
		assert_true(not (definition["colliders"] as Array).is_empty(), type + ": has colliders")
		# What you see is what blocks: the look stays inside the colliders' bounds plus a small margin.
		var solid := AABB()
		var first := true
		for entry: Dictionary in definition["colliders"]:
			for corner in WorldKit.collider_corners(entry):
				solid = AABB(corner, Vector3.ZERO) if first else solid.expand(corner)
				first = false
		assert_true(solid.grow(margin).encloses(mesh.get_aabb()), "%s: look %s within its colliders %s plus %s m" % [type, mesh.get_aabb(), solid, margin])
		assert_true(is_zero_approx(solid.position.y), type + ": stands on the ground (lowest collider at y 0)")
		counts[type] = Perf.triangles(mesh)
	# S2: the kit material is the textured world shader (was a StandardMaterial3D): still vertex paint, lit, opaque.
	var shared := WorldKit.material()
	var code := shared.shader.code
	assert_true(is_equal_approx(float(shared.get_shader_parameter("paint_mix")), 1.0) and WorldSurface.is_lit(shared)
			and not code.contains("ALPHA") and not code.contains("blend_"), "kit material: vertex paint, lit, opaque")
	for type: String in types:
		var arrays := WorldKit.mesh_for(type).surface_get_arrays(0)
		assert_true(arrays[Mesh.ARRAY_TEX_UV] != null and arrays[Mesh.ARRAY_TEX_UV2] != null and arrays[Mesh.ARRAY_TANGENT] != null, type + ": every vertex carries UV, surface id and tangent for the textures")
		for uv2: Vector2 in arrays[Mesh.ARRAY_TEX_UV2]:
			if uv2.x < 0.0 or uv2.x >= float((WorldSurface.config()["surface_order"] as Array).size()):
				assert_true(false, type + ": a vertex names a surface outside surface_order")
				break
	print("WORLD_KIT types=", types.size(), " triangles ", counts)


func test_colliders_cover_the_walkable_surfaces() -> void:
	var rules := _rules()
	var tolerance := float(rules["walk_tolerance_m"])
	var min_normal_y := cos(deg_to_rad(float(rules["max_walk_slope_deg"])))
	var checked := {}
	for type: String in _types():
		var walk: Array = _types()[type].get("walk", [])
		if walk.is_empty():
			continue
		var body := _stage_body(type)
		await _tree().physics_frame
		await _tree().physics_frame
		var space := body.get_world_3d().direct_space_state
		var samples := 0
		for surface: Dictionary in walk:
			var size: Array = surface["size"]
			var rise := float(surface.get("rise", 0.0))
			if rise != 0.0:
				var slope := rad_to_deg(atan2(absf(rise), float(size[1])))
				assert_true(slope <= float(rules["max_walk_slope_deg"]), "%s: ramp slope %.1f deg within the walk limit" % [type, slope])
				assert_true(float(size[0]) + 0.00001 >= float(rules["min_walk_width_m"]), "%s: ramp at least %s m wide" % [type, rules["min_walk_width_m"]])
			for local in _walk_points(surface):
				var p := FAR + local
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p - Vector3.UP * 0.5, Hitscan.MASK_WORLD))
				samples += 1
				if hit.is_empty() or hit["collider"] != body:
					assert_true(false, "%s: no collider under walk point %s" % [type, local])
					continue
				assert_true(absf(float(hit["position"].y) - p.y) <= tolerance, "%s: collider top at walk point %s is %s, data says %s" % [type, local, hit["position"].y, p.y])
				assert_true((hit["normal"] as Vector3).y >= min_normal_y - 0.0001, "%s: walk point %s is walkable ground (normal %s)" % [type, local, hit["normal"]])
		checked[type] = samples
		body.free()
	assert_true(checked.size() >= 7, "nonvacuous: the raised pieces were sampled: " + str(checked))
	print("WORLD_KIT walk samples ", checked)


func test_open_volumes_stay_free_of_colliders() -> void:
	var checked := 0
	for type: String in _types():
		var open: Array = _types()[type].get("open", [])
		if open.is_empty():
			continue
		var body := _stage_body(type)
		await _tree().physics_frame
		await _tree().physics_frame
		var space := body.get_world_3d().direct_space_state
		for volume: Dictionary in open:
			var box := BoxShape3D.new()
			box.size = LowpolyKit.vec(volume["size"]) - Vector3.ONE * 0.04  # touching the frame is not blocking
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = box
			query.transform = Transform3D(Basis.IDENTITY, FAR + LowpolyKit.vec(volume["at"]))
			query.collision_mask = Hitscan.MASK_WORLD
			assert_true(space.intersect_shape(query).is_empty(), "%s: open volume at %s is free" % [type, volume["at"]])
			# Nonvacuous: the same probe, grown past the frame, does touch this piece.
			box.size = LowpolyKit.vec(volume["size"]) + Vector3.ONE * 0.2
			assert_true(not space.intersect_shape(query).is_empty(), "%s: the frame around %s is solid" % [type, volume["at"]])
			checked += 1
		body.free()
	assert_true(checked >= 8, "gate, colonnade bays, aqueduct arch, barracks doors, window and room checked (%d)" % checked)


func test_raised_surfaces_are_reachable_on_a_baked_navmesh() -> void:
	var tolerance := float(_rules()["reach_tolerance_m"])
	var reached := {}
	for type: String in _types():
		var anchors: Array = _types()[type].get("reach", [])
		if anchors.is_empty():
			continue
		var region := NavigationRegion3D.new()
		var navmesh := NavigationMesh.new()
		navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS  # as the map scene
		region.navigation_mesh = navmesh
		region.position = FAR
		var ground := StaticBody3D.new()
		var ground_shape := CollisionShape3D.new()
		var slab := BoxShape3D.new()
		slab.size = Vector3(40, 1, 40)
		ground_shape.shape = slab
		ground.add_child(ground_shape)
		ground.position = Vector3(0, -0.5, 0)
		region.add_child(ground)
		region.add_child(WorldKit.build_body("Probe_" + type, type, _types()[type], Vector3.ZERO, 0.0))
		_tree().root.add_child(region)
		region.bake_navigation_mesh(false)
		var start := FAR + Vector3(-17, 0, -17)
		# The server publishes the region in a later iteration; a query before the map's first one is an error.
		for frame in 120:
			await _tree().physics_frame
			if NavigationServer3D.map_get_iteration_id(region.get_navigation_map()) > 0 \
					and NavigationServer3D.map_get_closest_point_owner(region.get_navigation_map(), start) == region.get_rid():
				break
		assert_eq(NavigationServer3D.map_get_closest_point_owner(region.get_navigation_map(), start), region.get_rid(), type + ": baked region published")
		for anchor: Array in anchors:
			var goal := FAR + LowpolyKit.vec(anchor)
			var path := NavigationServer3D.map_get_path(region.get_navigation_map(), start, goal, true)
			var miss := INF if path.is_empty() else path[path.size() - 1].distance_to(goal)
			assert_true(miss <= tolerance, "%s: a ground path reaches %s (ends %.2f m away)" % [type, anchor, miss])
			reached[type] = snappedf(miss, 0.01)
		region.free()
		await _tree().physics_frame
	assert_true(reached.size() >= 5, "stair, tower, aqueduct ramp, barracks room and ramp block checked: " + str(reached))
	print("WORLD_KIT reach miss_m ", reached)


## The real map, baked as MatchRoot.begin does: a turned ramp still leads up to its deck (piece yaw on top of the
## ramp's own rot), and the bake time is printed for the report (desktop, not the phone).
func test_raised_decks_on_the_real_map_are_reachable_from_a_spawn_spot() -> void:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var nav := map.get_node("Nav") as NavigationRegion3D
	var started := Time.get_ticks_usec()
	nav.bake_navigation_mesh(false)
	var bake_ms := (Time.get_ticks_usec() - started) / 1000.0
	var start := (map.get_node("SquadSpawns/spot_0") as Marker3D).global_position
	for frame in 120:
		await _tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 \
				and NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), start) == nav.get_rid():
			break
	assert_eq(NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), start), nav.get_rid(), "baked region published")
	var cfg := WorldKit.config()
	var tolerance := float(cfg["rules"]["reach_tolerance_m"])
	var checked := 0
	for entry: Dictionary in cfg["pieces"]:
		var definition: Dictionary = cfg["types"][entry["type"]]
		# Decks of pieces without their own way up (a span, a plain wall) are reached through a neighbour.
		var anchors: Array = definition.get("reach", [])
		if anchors.is_empty() and definition.has("walk") and bool(entry.get("reach_deck", false)):
			anchors = [definition["walk"][0]["at"]]
		for anchor: Array in anchors:
			var goal := LowpolyKit.vec(entry["at"]) + Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw", 0.0)))) * LowpolyKit.vec(anchor)
			var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), start, goal, true)
			var miss := INF if path.is_empty() else path[path.size() - 1].distance_to(goal)
			assert_true(miss <= tolerance, "%s: a path from spot_0 reaches %s (ends %.2f m away)" % [entry["id"], goal, miss])
			checked += 1
	assert_true(checked >= 5, "nonvacuous: placed raised pieces were checked (%d)" % checked)
	print("WORLD_NAV bake_ms=%.1f polygons=%d reach_checked=%d" % [bake_ms, nav.navigation_mesh.get_polygon_count(), checked])
	map.free()


func test_placed_pieces_are_structure_bodies_under_nav_drawn_as_one_batch_per_type() -> void:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var cfg := WorldKit.config()
	var pieces: Array = cfg["pieces"]
	var builder := map.get_node("ArtBuilder")
	var bodies: Array = builder.structure_bodies
	assert_true(pieces.size() > 0 and bodies.size() == pieces.size(), "one body per placed piece")
	var per_type := {}
	var step := float(cfg["rules"]["yaw_step_deg"])
	for i in bodies.size():
		var body: StaticBody3D = bodies[i]
		var entry: Dictionary = pieces[i]
		assert_true(cfg["types"].has(entry["type"]), "known type " + String(entry["type"]))
		assert_true(body.get_parent() == map.get_node("Nav"), String(body.name) + " is under Nav, so the bake parses it")
		assert_eq(String(body.name), entry["id"], "piece id")
		assert_eq(body.position, LowpolyKit.vec(entry["at"]), "piece position mirror")
		assert_true(body.is_in_group(WorldKit.GROUP) and not body.is_in_group(&"cover_wall"), String(body.name) + ": structure, never cover_wall")
		assert_true(body.collision_layer == 1 and body.collision_mask == 0, "world collision only")
		assert_true(is_zero_approx(fposmod(float(entry.get("yaw", 0.0)), step)), String(body.name) + ": yaw in steps of %s" % step)
		assert_true(body.get_node_or_null("Mesh") == null and body.get_node_or_null("Shape") == null, String(body.name) + ": colliders only, not a one-box cover body")
		assert_eq(body.get_child_count(), (cfg["types"][entry["type"]]["colliders"] as Array).size(), String(body.name) + ": one shape per collider entry")
		per_type[entry["type"]] = int(per_type.get(entry["type"], 0)) + 1
	var batches := builder.get_node("Structures").get_children()
	assert_eq(batches.size(), per_type.size(), "one batch per placed type")
	var triangles := 0
	for node: MultiMeshInstance3D in batches:
		var type := String(node.name).trim_prefix("Batch_")
		assert_eq(node.multimesh.instance_count, int(per_type.get(type, 0)), type + ": one instance per piece")
		assert_true(node.multimesh.mesh == WorldKit.mesh_for(type) and node.multimesh.mesh.surface_get_material(0) == WorldKit.material(), type + ": shared mesh and material")
		assert_true(node.material_override == null, type + ": no per-batch material")
		triangles += Perf.triangles(node.multimesh.mesh) * node.multimesh.instance_count
		# The instance transforms as the builder set them (a headless renderer keeps none to read back; the
		# line-up and overview shots show the batches drawn).
		var placed: Array = node.get_meta(&"transforms")
		var seen := 0
		for i in bodies.size():
			if pieces[i]["type"] == type:
				assert_true((placed[seen] as Transform3D).is_equal_approx((bodies[i] as StaticBody3D).transform), type + ": batch instance sits on its body")
				seen += 1
		assert_eq(seen, placed.size(), type + ": no stray instance")
	print("WORLD_KIT placed=", bodies.size(), " batches=", batches.size(), " triangles=", triangles)
	map.free()
