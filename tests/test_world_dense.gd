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
	for body in map.get_node("Nav").get_children():
		if body.name != &"Ground":
			assert_true(body.is_in_group(&"cover_wall"), "original blocks also coverable")
	map.free()

func test_new_composite_meshes_share_data_and_are_deterministic() -> void:
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	for kind in ["tall_wall", "sandbag_nest", "sandbag_nest_side", "crate_stack", "barrier_line", "wreck_cart", "wreck_truck", "wreck_apc", "rubble_pile"]:
		var mesh := LowpolyKit.build_cover(cfg["types"][kind])
		assert_true(mesh.surface_get_array_len(0) > 0, "nonempty " + kind)
		assert_eq(mesh.surface_get_arrays(0), LowpolyKit.build_cover(cfg["types"][kind]).surface_get_arrays(0), "deterministic " + kind)
