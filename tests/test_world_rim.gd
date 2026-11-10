extends "res://tests/test_case.gd"
## W2: the rim decor of data/maps/alesia_cover.json is solid where it should be. Arches: two piers and a lintel,
## the way under them open (for a soldier and on the baked navmesh). Rocks: the hull of their mesh. Paving: none.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _map() -> Node3D:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	return map


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/maps/alesia_cover.json")


func _solid(map: Node3D, id: String) -> StaticBody3D:
	return map.get_node_or_null("Nav/" + id + "_Solid") as StaticBody3D


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Hitscan.MASK_WORLD))


func test_rim_arches_have_piers_and_a_lintel_and_the_way_under_is_open() -> void:
	var map := _map()
	await _tree().physics_frame
	await _tree().physics_frame
	var cfg := _cfg()
	assert_true(bool(cfg["decor_colliders"]["_placeholder"]) and String(cfg["decor_colliders"]["_todo"]).contains("OQ-WORLD-DENSE"), "the choice of solid decor is placeholder data")
	var k: Dictionary = LowpolyKit.config()["kit"]
	var space := map.get_world_3d().direct_space_state
	var ground := map.get_node("Nav/Ground") as StaticBody3D
	var arches := 0
	for entry: Dictionary in cfg["decor"]:
		if entry["kind"] != "arch":
			continue
		arches += 1
		var id := String(entry["id"])
		var body := _solid(map, id)
		assert_true(body != null and body.get_child_count() == 3, id + ": two piers and a lintel")
		if body == null:
			continue
		assert_true(body.is_in_group(WorldKit.GROUP) and not body.is_in_group(&"cover_wall") and body.collision_layer == 1, id + ": solid, not cover")
		var size := LowpolyKit.vec(entry["size"])
		var leg: Vector3 = size * LowpolyKit.vec(k["arch_leg_fraction"])
		var lintel: Vector3 = size * LowpolyKit.vec(k["arch_lintel_fraction"])
		var at := LowpolyKit.vec(entry["at"])
		var lintel_bottom := at.y + size.y * float(k["arch_lintel_y"]) - lintel.y * 0.5  # metres above the ground
		var inner := size.x - leg.x * 2.0
		var pawn_cfg: Dictionary = DataRegistry.new().get_movement_cfg()
		assert_true(inner >= 2.0 and lintel_bottom >= 2.5, "%s: the way under is %.2f m wide and %.2f m high" % [id, inner, lintel_bottom])
		assert_true(pawn_cfg.has("muzzle_height_m") and lintel_bottom > float(pawn_cfg["muzzle_height_m"]), id + ": higher than a soldier's muzzle")
		# Open: a box filling the way (a little short of the piers, the lintel and the ground) touches nothing.
		var free := BoxShape3D.new()
		free.size = Vector3(inner - 0.1, lintel_bottom - 0.1, size.z)
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = free
		query.collision_mask = Hitscan.MASK_WORLD
		query.exclude = [ground.get_rid()]
		query.transform = Transform3D(body.basis, Vector3(at.x, lintel_bottom * 0.5, at.z))
		assert_true(space.intersect_shape(query).is_empty(), id + ": the way under the arch is open")
		# Nonvacuous: the same box, widened into the piers, touches this arch.
		free.size = Vector3(inner + 0.4, lintel_bottom - 0.1, size.z)
		var touched := space.intersect_shape(query)
		assert_true(not touched.is_empty() and touched[0]["collider"] == body, id + ": the piers are solid")
		# Solid from the ground up: rays through the depth of the arch at knee height hit each pier, and a ray
		# from above lands on the lintel's top.
		for sign_x: float in [-1.0, 1.0]:
			var pier := body.transform * Vector3(sign_x * (size.x - leg.x) * 0.5, 0.0, 0.0)
			var along := body.basis * Vector3(0.0, 0.0, size.z)
			var hit := _ray(space, Vector3(pier.x, 0.4, pier.z) - along, Vector3(pier.x, 0.4, pier.z) + along)
			assert_true(not hit.is_empty() and hit["collider"] == body, id + ": pier solid at knee height (down to the ground)")
		var top := _ray(space, Vector3(at.x, 40.0, at.z), Vector3(at.x, -1.0, at.z))
		assert_true(not top.is_empty() and top["collider"] == body and is_equal_approx(float(top["position"].y), at.y + size.y * float(k["arch_lintel_y"]) + lintel.y * 0.5), id + ": lintel solid on top")
	assert_true(arches >= 1, "nonvacuous: the rim has arches (%d)" % arches)
	print("WORLD_RIM arches=", arches)
	map.free()


func test_rim_rocks_are_solid_hulls_and_paving_is_not() -> void:
	var map := _map()
	await _tree().physics_frame
	await _tree().physics_frame
	var cfg := _cfg()
	var space := map.get_world_3d().direct_space_state
	var ground := map.get_node("Nav/Ground") as StaticBody3D
	var rocks := 0
	var paving := 0
	for entry: Dictionary in cfg["decor"]:
		var id := String(entry["id"])
		var at := LowpolyKit.vec(entry["at"])
		var size := LowpolyKit.vec(entry["size"])
		var down := _ray(space, Vector3(at.x, 40.0, at.z), Vector3(at.x, -1.0, at.z))
		if entry["kind"] == "rock":
			rocks += 1
			var body := _solid(map, id)
			assert_true(body != null and body.get_child_count() == 1 and (body.get_child(0) as CollisionShape3D).shape is ConvexPolygonShape3D, id + ": one convex hull")
			if body == null:
				continue
			var look := map.get_node("Decor/" + id) as MeshInstance3D
			var bounds := look.mesh.get_aabb().grow(0.001)
			var points := ((body.get_child(0) as CollisionShape3D).shape as ConvexPolygonShape3D).points
			assert_true(points.size() >= 8, id + ": hull has points")
			for p in points:
				assert_true(bounds.has_point(p), id + ": hull point lies on the rock's mesh bounds")
			assert_true(not down.is_empty() and down["collider"] == body and is_equal_approx(float(down["position"].y), at.y + size.y * 0.5), id + ": solid up to the rock's top")
		elif not (cfg["decor_colliders"] as Dictionary).has(entry["kind"]):
			paving += 1
			assert_true(_solid(map, id) == null, id + ": no solid body")
			assert_true(not down.is_empty() and down["collider"] == ground, id + ": a ray from above lands on the ground through it")
	assert_true(rocks >= 1 and paving == 8, "nonvacuous: rocks %d, paving %d" % [rocks, paving])
	print("WORLD_RIM rocks=", rocks, " paving=", paving)
	map.free()


## The baked navmesh, as MatchRoot.begin bakes it: a walkable point under each arch, none inside a rock.
func test_baked_navmesh_passes_under_the_arches_and_around_the_rocks() -> void:
	var map := _map()
	var nav := map.get_node("Nav") as NavigationRegion3D
	nav.bake_navigation_mesh(false)
	var probe := Vector3(40, 0.1, 0)
	for frame in 120:
		await _tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 \
				and NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), probe) == nav.get_rid():
			break
	assert_eq(NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), probe), nav.get_rid(), "baked region published")
	var checked := 0
	for entry: Dictionary in _cfg()["decor"]:
		var at := LowpolyKit.vec(entry["at"])
		var under := Vector3(at.x, 0.0, at.z)
		var closest := NavigationServer3D.map_get_closest_point(nav.get_navigation_map(), under)
		var flat := Vector2(closest.x - under.x, closest.z - under.z).length()
		if entry["kind"] == "arch":
			assert_true(flat <= 0.3 and absf(closest.y) <= 0.5, "%s: the navmesh runs under the arch (nearest point %.2f m away, y %.2f)" % [entry["id"], flat, closest.y])
			# A path from one side of the arch to the other goes under it, not around a pier.
			var axis := _solid(map, String(entry["id"])).basis * Vector3(0.0, 0.0, 1.0)
			var goal := under + axis * 6.0
			var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), under - axis * 6.0, goal, true)
			var nearest := INF
			for i in range(1, path.size()):
				nearest = minf(nearest, Geometry3D.get_closest_point_to_segment(under, path[i - 1], path[i]).distance_to(under))
			assert_true(not path.is_empty() and path[path.size() - 1].distance_to(goal) <= 1.0 and nearest <= 1.0, "%s: the path through the arch passes %.2f m from its middle" % [entry["id"], nearest])
			checked += 1
		elif entry["kind"] == "rock":
			# A path from one side of the rock to the other goes around it. (The bake leaves a walkable patch
			# inside every closed collider taller than the agent, as inside the camp blocks: it rasterises
			# surfaces, not solids. Such a patch joins nothing, so "no navmesh inside" is not the check.)
			var radial := under.normalized()
			var goal := under + radial * 6.0
			var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), under - radial * 6.0, goal, true)
			var nearest := INF
			for i in range(1, path.size()):
				nearest = minf(nearest, Geometry3D.get_closest_point_to_segment(under, path[i - 1], path[i]).distance_to(under))
			assert_true(path.size() >= 3 and path[path.size() - 1].distance_to(goal) <= 1.0 and nearest >= 2.0, "%s: the path across goes around the rock (%d corners, %.2f m from its middle)" % [entry["id"], path.size(), nearest])
			checked += 1
	assert_eq(checked, 12, "twelve rim pieces checked")
	map.free()
