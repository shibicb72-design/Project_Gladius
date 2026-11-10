extends "res://tests/test_case.gd"
## S6: the backdrop (scripts/visual/backdrop.gd, data/art_backdrop.json). It must stay a look: no body, no
## collider, nothing under the map's Nav node, and nothing on or near the playable ground square.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _colliders(node: Node) -> int:
	var count := 1 if (node is CollisionObject3D or node is CollisionShape3D) else 0
	for child in node.get_children():
		count += _colliders(child)
	return count


func test_backdrop_is_a_look_outside_the_playable_square() -> void:
	var cfg := Backdrop.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-GFX-BACKDROP"), "backdrop numbers are placeholders with an OQ id")
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var backdrop := map.get_node_or_null("ArtBuilder/Backdrop") as Backdrop
	assert_true(backdrop != null, "the default preset builds the backdrop")
	if backdrop == null:
		map.free()
		return
	assert_eq(_colliders(backdrop), 0, "the backdrop has no body and no collider")
	for body in map.get_node("Nav").get_children():
		assert_true(not String(body.name).begins_with("Outer") and not backdrop.is_ancestor_of(body), "nothing of the backdrop sits under Nav")
	var ground := map.get_node("Nav/Ground/Mesh") as MeshInstance3D
	var half := ground.get_aabb().size.x * 0.5
	var clear := float(cfg["clear_of_ground_m"])
	var kinds := {}
	for piece: Dictionary in backdrop.placed:
		kinds[piece["kind"]] = int(kinds.get(piece["kind"], 0)) + 1
		var at: Vector3 = piece["at"]
		var reach: Vector2 = piece["half"]
		var turn: Basis = piece["basis"]
		# Corners, edge middles and centre of the piece's footprint all stay clear of the ground square.
		var nearest := INF
		for sx: float in [-1.0, 0.0, 1.0]:
			for sz: float in [-1.0, 0.0, 1.0]:
				var p := at + turn * Vector3(reach.x * sx, 0.0, reach.y * sz)
				var on_square := Vector2(clampf(p.x, -half, half), clampf(p.z, -half, half))
				nearest = minf(nearest, Vector2(p.x, p.z).distance_to(on_square))
		assert_true(nearest >= clear, "%s at %s keeps clear of the ground square (%.1f m, need %.1f)" % [piece["kind"], at, nearest, clear])
	for kind in ["wall", "tower", "spire", "aqueduct"]:
		assert_true(int(kinds.get(kind, 0)) > 0, "the backdrop places " + kind)
	assert_eq(int(kinds["wall"]), int(cfg["outer_wall"]["segments"]), "one wall segment per data segment: the ring is closed")
	# One batch per kind, no shadows unless the data asks.
	var batches := 0
	for child in backdrop.get_children():
		if child is MultiMeshInstance3D:
			batches += 1
			assert_true((child as MultiMeshInstance3D).multimesh.instance_count > 0, String(child.name) + " draws something")
			assert_true(WorldSurface.is_lit((child as MultiMeshInstance3D).multimesh.mesh.surface_get_material(0)), String(child.name) + " uses the lit world material")
	assert_eq(batches, 4, "outer wall, towers, spires, aqueduct run: one batch each")
	var skirt := backdrop.get_node_or_null("GroundSkirt") as MeshInstance3D
	assert_true(skirt != null and skirt.position.y < 0.0 and skirt.material_override == ground.material_override, "the ground skirt lies just under the ground and shares its material")
	var segment := float(cfg["outer_wall"]["segment_length_m"])
	var chord := 2.0 * float(cfg["outer_wall"]["radius_m"]) * sin(PI / float(cfg["outer_wall"]["segments"]))
	assert_true(segment >= chord - 0.05, "wall segments are long enough to meet (%.2f m for a %.2f m chord)" % [segment, chord])
	print("GFX_BACKDROP pieces ", kinds)
	map.free()


func test_backdrop_follows_the_graphics_preset() -> void:
	assert_true(GraphicsPresets.new().get_preset().has("art_backdrop_enabled"), "the backdrop is a preset switch")
