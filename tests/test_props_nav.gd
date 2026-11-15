extends "res://tests/test_case.gd"
## M2 L1b (Lanista's binding: bots path as if breakables were not there): a breakable under a Props node that is a
## SIBLING of the Nav region is not parsed by the navigation bake, with the 1 km scene's own NavigationMesh settings
## (static colliders, the region's children). The same crate under Nav is parsed (nonvacuous). On the 1 km map the
## re-bake after the breakables exist keeps the saved polygon and vertex counts (tools/bake_nav.gd, the lead's run).


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## Bakes a 30 m ground with one 2 m crate: "none" (no crate), "props" (under a Props sibling of Nav) or "nav"
## (under Nav). Returns [polygons, vertices].
func _bake(where: String) -> Array:
	var scene: Node = load("res://scenes/maps/alesia_1km.tscn").instantiate()
	var mesh := (scene.get_node("Nav") as NavigationRegion3D).navigation_mesh.duplicate() as NavigationMesh
	scene.free()
	var root := Node3D.new()
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	nav.navigation_mesh = mesh
	root.add_child(nav)
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	nav.add_child(ground)
	var props := Node3D.new()
	props.name = "Props"
	root.add_child(props)
	if where != "none":
		var crate := Breakable.make({"id": "Breakable_960", "type": "breakable_crate", "at": [0.0, 0.6, 0.0], "size": [2.0, 1.2, 2.0]},
				WorldProps.config()["breakables"]["breakable_crate"])
		(nav if where == "nav" else props).add_child(crate)
	_tree().root.add_child(root)
	await _tree().physics_frame
	nav.bake_navigation_mesh(false)
	var out := [mesh.get_polygon_count(), mesh.get_vertices().size()]
	root.free()
	return out


func test_a_props_sibling_is_not_parsed_by_the_bake() -> void:
	var scene: Node = load("res://scenes/maps/alesia_1km.tscn").instantiate()
	var settings := (scene.get_node("Nav") as NavigationRegion3D).navigation_mesh
	assert_eq(settings.geometry_parsed_geometry_type, NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS, "the 1 km bake parses static colliders")
	assert_eq(settings.geometry_source_geometry_mode, NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN, "of the region's own children")
	scene.free()
	var none: Array = await _bake("none")
	var props: Array = await _bake("props")
	var under: Array = await _bake("nav")
	assert_true(int(none[0]) > 0, "nonvacuous: the ground bakes (%d polygons)" % int(none[0]))
	assert_eq(props, none, "a crate under the Props sibling leaves the mesh as without it")
	assert_true(under != none, "the same crate under Nav is parsed (%s vs %s)" % [str(under), str(none)])
	print("PROPS_NAV none=", none, " props=", props, " under_nav=", under)
