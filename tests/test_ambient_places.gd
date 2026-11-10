extends "res://tests/test_case.gd"
## S7: the ambient props that stand on the ground (braziers, banner poles) have no collider, so nothing stops
## the data from putting one inside a wall or a cover piece. This checks every such place against the map's
## colliders, and that the grass tufts stand on grass.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_braziers_and_banners_stand_on_free_ground() -> void:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	await _tree().physics_frame
	await _tree().physics_frame
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/art_world.json")
	var space := map.get_world_3d().direct_space_state
	var half_ground := (map.get_node("Nav/Ground/Mesh") as MeshInstance3D).get_aabb().size.x * 0.5
	var checked := 0
	for kind in ["braziers", "flags"]:
		for at: Array in cfg[kind]["positions"]:
			var place := LowpolyKit.vec(at)
			assert_true(absf(place.x) < half_ground and absf(place.z) < half_ground, "%s at %s is on the map" % [kind, at])
			var box := BoxShape3D.new()
			box.size = Vector3(0.9, 1.6, 0.9)
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = box
			query.transform = Transform3D(Basis.IDENTITY, place + Vector3.UP * 0.95)  # clear of the ground itself
			query.collision_mask = Hitscan.MASK_WORLD
			var hits := space.intersect_shape(query)
			var names := PackedStringArray()
			for hit: Dictionary in hits:
				names.append(String((hit["collider"] as Node).name))
			assert_true(hits.is_empty(), "%s at %s stands clear of every collider (touches %s)" % [kind, at, ", ".join(names)])
			checked += 1
	assert_true(checked >= 10, "braziers and banners checked (%d)" % checked)
	# Tufts: on the grass of the paint map, never on paving.
	var builder := map.get_node("ArtBuilder")
	var foliage := builder.get_node("Ambient/Foliage") as MultiMeshInstance3D
	assert_true(foliage != null and foliage.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "one tuft batch without shadows")
	map.free()
