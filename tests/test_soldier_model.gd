extends "res://tests/test_case.gd"
const Perf := preload("res://tests/test_astra_perf.gd")

func test_soldier_mesh_head_lock_and_rifle_tip() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	assert_true(model.get_parent() == pawn, "visual sibling of Body")
	assert_true(model.get_meta("parts").size() >= 10, "humanoid part manifest")
	assert_true(model.get_child(0) is Skeleton3D, "one rig group")
	var armor := model.skeleton.get_node("Armor") as MeshInstance3D
	assert_true(armor.mesh is ArrayMesh and armor.mesh.get_surface_count() == 1, "one vertex color surface")
	var head := pawn.get_node("Head/HeadMesh") as MeshInstance3D
	var body := pawn.get_node("Body") as MeshInstance3D
	assert_true(head.visible and head.mesh is SphereMesh, "visible locked helmet shell")
	assert_true(is_equal_approx((head.mesh as SphereMesh).radius, 0.22), "head radius")
	assert_eq((pawn.get_node("Head") as Node3D).position, Vector3(0, 1.75, 0), "head transform")
	assert_eq((head.material_override as StandardMaterial3D).albedo_color, Color(1, 0.9, 0.2, 1), "yellow exact")
	assert_eq((head.material_override as StandardMaterial3D).shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "head unshaded")
	assert_true(body.mesh is CapsuleMesh and not body.visible, "legacy capsule kept but hidden")
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.6
	assert_eq(body.mesh.get_aabb(), capsule.get_aabb(), "literal capsule baseline")
	assert_eq(body.transform, Transform3D(Basis.IDENTITY, Vector3(0, 0.8, 0)), "body transform locked")
	var head_bounds: AABB = (pawn.get_node("Head") as Node3D).transform * head.get_aabb()
	for bounds in model.part_bounds:
		assert_true(not head_bounds.grow(0.02).intersects(bounds), "part clear of yellow shell and margin")
	var motion: Dictionary = LowpolyKit.config()["soldier"]
	for vertical in [-1, 1]:
		for roll in [-1, 1]:
			model.position.y = vertical * float(motion["bob_amplitude_m"])
			model.rotation.z = roll * float(motion["idle_sway_rad"])
			for part_bounds in model.part_bounds:
				assert_true(not head_bounds.grow(0.02).intersects(model.transform * part_bounds), "shell clearance at motion extremes")
	model.transform = Transform3D.IDENTITY
	var rifle := pawn.shot_fx.weapon_mesh.get_node("RifleModel") as MeshInstance3D
	assert_true(rifle.mesh is ArrayMesh and rifle.mesh.get_surface_count() == 1, "merged rifle present")
	assert_true(pawn.shot_fx.weapon_mesh.mesh is BoxMesh and pawn.shot_fx.weapon_mesh.visible, "legacy box contract kept; children visible")
	assert_eq(pawn.shot_fx.weapon_mesh.layers, 0, "only legacy box draw suppressed")
	var bounds := rifle.mesh.get_aabb()
	assert_true(absf(bounds.position.z + (pawn.shot_fx.weapon_mesh.mesh as BoxMesh).size.z * 0.5) < 0.0001, "barrel ends at unchanged muzzle tip")
	var tris := Perf.triangles(armor.mesh) + Perf.triangles(head.mesh) + Perf.triangles(rifle.mesh)
	assert_true(tris > 0 and tris <= int(LowpolyKit.config()["performance"]["pawn_triangle_budget"]), "pawn model triangle budget")
	print("ASTRA_PAWN model triangles=", tris, " parts=", model.get_meta("parts").size())
	pawn.velocity = Vector3(2, 0, 3)
	var before := pawn.velocity
	model._process(0.1)
	assert_eq(pawn.velocity, before, "sway never changes velocity")
	pawn.free()
