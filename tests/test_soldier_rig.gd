extends "res://tests/test_case.gd"

const BONES := ["Hips", "Spine", "Chest", "Neck", "Head", "LeftUpperArm", "LeftForeArm", "LeftHand", "RightUpperArm", "RightForeArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]


func test_rigid_weight_skin_shared_mesh_and_cpu_bounds() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var a: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	var b: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(a)
	tree.root.add_child(b)
	a.set_physics_process(false)
	b.set_physics_process(false)
	var model := a.get_node("SoldierModel") as SoldierModel
	var other := b.get_node("SoldierModel") as SoldierModel
	model.sway_enabled = false
	assert_eq(model.skeleton.get_bone_count(), BONES.size(), "complete humanoid rig")
	for name in BONES:
		assert_true(model.skeleton.find_bone(name) >= 0, "bone " + name)
	assert_true(model.skeleton != other.skeleton, "per-pawn skeleton")
	assert_true(model.armor.mesh == other.armor.mesh and model.armor.skin == other.armor.skin, "shared mesh and Skin")
	assert_eq(model.armor.mesh.get_surface_count(), 1, "single body surface")
	var arrays := (model.armor.mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	assert_eq(weights.size(), vertices.size() * 4, "four weights per vertex")
	for i in vertices.size():
		assert_eq(weights[i * 4], 1.0, "rigid part weight")
		assert_true(indices[i * 4] >= 0 and indices[i * 4] < BONES.size(), "valid bone index")
	var bounds: Array[AABB] = []
	bounds.resize(model.part_bounds.size())
	model.posed_bounds(bounds)
	for i in bounds.size():
		assert_true(bounds[i].position.is_equal_approx(model.part_bounds[i].position), "CPU bind pose position")
		assert_true(bounds[i].size.is_equal_approx(model.part_bounds[i].size), "CPU bind pose size")
	for node in model.find_children("*", "", true, false):
		assert_true(not node is CollisionObject3D and not node is CollisionShape3D, "rig collider-free")
	print("RIG bones=", model.skeleton.get_bone_count(), " mesh_tris=", vertices.size() / 3, " shared=true surfaces=1")
	a.free()
	b.free()
