extends "res://tests/test_case.gd"
## Proxy, not measured: surface draws plus the shadow subset per split; geometry triangles.

static func triangles(mesh: Mesh) -> int:
	var total := 0
	if mesh is PrimitiveMesh:
		var arrays := (mesh as PrimitiveMesh).get_mesh_arrays()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		return indices.size() / 3 if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	for surface in mesh.get_surface_count():
		var array_mesh := mesh as ArrayMesh
		var indices: int = array_mesh.surface_get_array_index_len(surface)
		total += indices / 3 if indices > 0 else array_mesh.surface_get_array_len(surface) / 3
	return total

func _count(node: Node, splits: int) -> Vector2i:
	var result := Vector2i.ZERO
	var mesh: Mesh
	var instances := 1
	if node is GeometryInstance3D and node.is_visible_in_tree() and node.layers != 0:
		if node is MeshInstance3D:
			mesh = node.mesh
		elif node is MultiMeshInstance3D and node.multimesh != null:
			mesh = node.multimesh.mesh
			instances = node.multimesh.instance_count
		elif node is CPUParticles3D:
			mesh = node.mesh
			instances = node.amount
		if mesh != null:
			var tris := triangles(mesh)
			assert_true(tris > 0, "every counted mesh has triangles: " + String(node.name))
			var shadow_draws := splits if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else 0
			result.x += mesh.get_surface_count() * (1 + shadow_draws)
			result.y += tris * instances
	for child in node.get_children():
		result += _count(child, splits)
	return result

func test_whole_match_geometry_proxy_budget() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = false
	tree.root.add_child(match_scene)
	await tree.physics_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "representative match starts")
	var cfg: Dictionary = LowpolyKit.config()["performance"]
	assert_eq(match_scene.director.all_players().size(), int(cfg["representative_pawns"]), "six representative pawns")
	var splits := int(cfg["shadow_splits"]) if (match_scene.get_node("Light") as DirectionalLight3D).shadow_enabled else 0
	for pawn: Pawn in match_scene.director.all_players().values():
		pawn.set_physics_process(false)
		pawn.shot_fx.show_shot(pawn.get_muzzle_position(), pawn.global_position + Vector3(0, 1, -10))
	var counts := _count(match_scene, splits)
	assert_true(counts.x > 0 and counts.y > 0, "nonvacuous proxy")
	assert_true(counts.x <= int(cfg["draw_budget"]), "draw proxy within placeholder budget")
	assert_true(counts.y <= int(cfg["triangle_budget"]), "triangles within placeholder budget")
	print("ASTRA_PERF proxy, not measured: draw=", counts.x, " triangles=", counts.y)
	# Conservative additional envelope: six live models/FX plus six simultaneously lingering corpses.
	for pawn: Pawn in match_scene.director.all_players().values():
		var corpse := (pawn.get_node("SoldierModel") as SoldierModel).make_corpse()
		match_scene.add_child(corpse)
		corpse.global_transform = pawn.global_transform
	var with_corpses := _count(match_scene, splits)
	assert_true(with_corpses.x <= int(cfg["draw_budget"]) and with_corpses.y <= int(cfg["triangle_budget"]), "lingering corpse envelope within budget")
	print("ASTRA_PERF with six corpses, proxy, not measured: draw=", with_corpses.x, " triangles=", with_corpses.y)
	match_scene.free()
