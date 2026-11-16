extends "res://tests/test_case.gd"
## M2 AN2 item 1: the Blender-built soldier (assets/generated/characters/soldier.glb, tools/blender/build_soldier.py)
## against the game's own rig and rules. The .glb's armature equals the runtime skeleton SoldierRig.build makes from
## data (names, parents, rests within 1 mm, identity bases); its two LODs are one indexed surface each within the
## body budgets; the vertex stream is the soldier shader's (normalized weights, at most 4 influences, COLOR alpha 0 or
## 1 with some squad fields, known surface ids, tangents); and, on the real vertices in the bind pose, the mesh is
## honest about the head hitbox (the Head-skinned shell encloses it, no other vertex enters its clearance box) and the
## part boxes the tests and the gait measurement read are a truthful proxy of the helmet and the boots.
const Checks := preload("res://tests/soldier_checks.gd")
const ADDED := ["LeftToes", "RightToes", "LeftFingers", "RightFingers", "Prop"]
const REST_TOLERANCE_M := 0.001
const PROXY_TOLERANCE_M := 0.02  # how far a part-box face may sit from the mesh region it stands for


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(pawn)
	pawn.set_physics_process(false)
	(pawn.get_node("SoldierModel") as SoldierModel).set_process(false)
	return pawn


func _body() -> Dictionary:
	return SoldierLook.config()["budgets"]["body"]


func test_glb_armature_equals_the_runtime_skeleton() -> void:
	var source := SoldierRig.mesh_source()
	assert_true(source.ends_with("soldier.glb"), "data/art_soldier.json soldier.mesh_source names the Blender soldier: %s" % source)
	var packed := load(source) as PackedScene
	assert_true(packed != null, "the soldier .glb imports as a scene")
	if packed == null:
		return
	var scene := packed.instantiate()
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	assert_eq(skeletons.size(), 1, "one armature")
	assert_eq(scene.find_children("*", "AnimationPlayer", true, false).size(), 0, "no animation in the soldier file (clips come separately)")
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var ours := model.skeleton
	var theirs := skeletons[0] as Skeleton3D
	assert_eq(ours.get_bone_count(), 17 + ADDED.size(), "the runtime skeleton: the 17 bones of data/anim.json and the added ones")
	assert_eq(theirs.get_bone_count(), ours.get_bone_count(), "the .glb carries the same number of bones")
	assert_true(ours.get_bone_count() <= 40, "within the 40-bone cap")
	for name: String in ADDED:
		assert_true(ours.find_bone(name) >= 0 and theirs.find_bone(name) >= 0, "added bone %s in both" % name)
	var worst_origin := 0.0
	var worst_basis := 0.0
	var parents_ok := true
	for i in ours.get_bone_count():
		var name := ours.get_bone_name(i)
		var j := theirs.find_bone(name)
		assert_true(j >= 0, "the .glb has bone " + name)
		if j < 0:
			continue
		var p_ours := ours.get_bone_parent(i)
		var p_theirs := theirs.get_bone_parent(j)
		var want := ours.get_bone_name(p_ours) if p_ours >= 0 else ""
		var got := theirs.get_bone_name(p_theirs) if p_theirs >= 0 else ""
		if want != got:
			parents_ok = false
			assert_eq(got, want, "parent of " + name)
		var a := ours.get_bone_global_rest(i)
		var b := theirs.get_bone_global_rest(j)
		worst_origin = maxf(worst_origin, a.origin.distance_to(b.origin))
		for axis in 3:
			worst_basis = maxf(worst_basis, (b.basis[axis] - Basis.IDENTITY[axis]).length())
			worst_basis = maxf(worst_basis, (a.basis[axis] - Basis.IDENTITY[axis]).length())
	assert_true(parents_ok, "every parent as in data (Hips and Neck the two roots)")
	assert_true(worst_origin <= REST_TOLERANCE_M, "rests equal the runtime ones within 1 mm (worst %.5f m)" % worst_origin)
	assert_true(worst_basis < 0.0001, "every rest basis is identity (worst %.6f)" % worst_basis)
	# The file's own bind poses are the inverse global rests of the same skeleton: its vertices sit where the
	# runtime skin (create_skin_from_rest_transforms) expects them.
	var worst_bind := 0.0
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		for k in mi.skin.get_bind_count():
			var name := String(mi.skin.get_bind_name(k))
			if name == "":
				name = theirs.get_bone_name(mi.skin.get_bind_bone(k))
			var bone := ours.find_bone(name)
			assert_true(bone >= 0, "bind %s is a soldier bone" % name)
			if bone >= 0:
				var want := ours.get_bone_global_rest(bone).affine_inverse()
				worst_bind = maxf(worst_bind, (mi.skin.get_bind_pose(k).origin - want.origin).length())
	assert_true(worst_bind <= REST_TOLERANCE_M, "the .glb bind poses match the runtime rests (worst %.5f m)" % worst_bind)
	scene.free()
	pawn.free()


func test_two_lods_one_indexed_surface_each_within_the_body_budget() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	assert_true(model.armor_far != null and model.armor_far.get_parent() == model.armor.get_parent(), "the far body is a sibling of the near one")
	if model.armor_far == null:
		pawn.free()
		return
	var body := _body()
	assert_true(String(body["_note"]).length() > 40, "the body budget carries its reason")
	var tris: Array[int] = []
	for mi: MeshInstance3D in [model.armor, model.armor_far]:
		var mesh := mi.mesh as ArrayMesh
		assert_eq(mesh.get_surface_count(), 1, "%s: one surface" % mi.name)
		var arrays := mesh.surface_get_arrays(0)
		assert_true(arrays[Mesh.ARRAY_INDEX] != null, "%s: indexed" % mi.name)
		tris.append((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if arrays[Mesh.ARRAY_INDEX] != null else 0)
		assert_true(mesh.surface_get_material(0) == SoldierSquadColour.material() and mi.material_override == null, "%s: the one soldier material on the surface" % mi.name)
		assert_true(mi.skin == model.armor.skin and mi.get_node(mi.skeleton) == model.skeleton, "%s: the shared skin on the pawn's skeleton" % mi.name)
	assert_true(tris[0] > 0 and tris[0] <= int(body["near_max_triangles"]), "near body within %s triangles: %d" % [body["near_max_triangles"], tris[0]])
	assert_true(tris[1] > 0 and tris[1] <= int(body["far_max_triangles"]) and tris[1] < tris[0], "far body within %s triangles and cheaper: %d" % [body["far_max_triangles"], tris[1]])
	var far_m := float(SoldierLook.config()["gun"]["far_m"])
	assert_true(is_equal_approx(model.armor.visibility_range_end, far_m) and is_equal_approx(model.armor_far.visibility_range_begin, far_m),
			"the body hands over at the gun's far distance (%s m)" % far_m)
	assert_eq(model.armor.custom_aabb, model.armor_far.custom_aabb, "near and far share one culling box (one hand-over centre)")
	print("SOLDIER_GLB near_triangles=%d far_triangles=%d bones=%d far_from_m=%.1f" % [tris[0], tris[1], model.skeleton.get_bone_count(), far_m])
	pawn.free()


func test_vertex_stream_is_the_soldier_shaders() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	if model.armor_far == null:
		assert_true(false, "the far body exists")
		pawn.free()
		return
	var order: Array = WorldSurface.config()["surface_order"]
	var squad_ids := [WorldSurface.surface_id("squad_plate"), WorldSurface.surface_id("squad_cloth"), WorldSurface.surface_id("squad_cape")]
	var sway := WorldSurface.surface_id(String(LowpolyKit.config()["soldier"]["material"]["cape"]["surface"]))
	var tier := WorldSurface.surface_id(String(LowpolyKit.config()["soldier"]["material"]["tier_surface"]))
	for mi: MeshInstance3D in [model.armor, model.armor_far]:
		var arrays := (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		assert_eq(weights.size(), vertices.size() * 4, "%s: at most four influences per vertex" % mi.name)
		assert_true(arrays[Mesh.ARRAY_TANGENT] != null and (arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).size() == vertices.size() * 4, "%s: tangents" % mi.name)
		assert_true(arrays[Mesh.ARRAY_TEX_UV] != null, "%s: UV (metres)" % mi.name)
		var bad_weights := 0
		var bad_bones := 0
		var blended := 0
		var squad := 0
		var bad_alpha := 0
		var bad_surface := 0
		var squad_off_field := 0
		var bad_hang := 0
		var tiers := 0
		for i in vertices.size():
			var total := 0.0
			for k in 4:
				total += weights[i * 4 + k]
				if weights[i * 4 + k] > 0.0 and (bones[i * 4 + k] < 0 or bones[i * 4 + k] >= model.skeleton.get_bone_count()):
					bad_bones += 1
			if absf(total - 1.0) > 0.002:
				bad_weights += 1
			if weights[i * 4] < 0.99:
				blended += 1
			var a := colors[i].a
			if a == 0.0:
				squad += 1
			elif a != 1.0:
				bad_alpha += 1
			var id := uv2[i].x
			if absf(id - roundf(id)) > 0.001 or int(roundf(id)) <= 0 or int(roundf(id)) >= order.size():
				bad_surface += 1
			if a == 0.0 and not squad_ids.has(int(roundf(id))):
				squad_off_field += 1
			if int(roundf(id)) == sway and (uv2[i].y < -0.001 or uv2[i].y > 1.001):
				bad_hang += 1
			if int(roundf(id)) == tier:
				tiers += 1
		assert_eq(bad_weights, 0, "%s: weights normalized" % mi.name)
		assert_eq(bad_bones, 0, "%s: every influencing bone index is a skeleton bone" % mi.name)
		assert_true(blended > 0, "%s: joints are blended (%d vertices)" % [mi.name, blended])
		assert_eq(bad_alpha, 0, "%s: COLOR alpha is exactly 0 or 1" % mi.name)
		assert_true(squad > 0 and squad * 2 < vertices.size(), "%s: some squad fields, not most (%d of %d)" % [mi.name, squad, vertices.size()])
		assert_eq(squad_off_field, 0, "%s: alpha 0 only on squad surfaces" % mi.name)
		assert_eq(bad_surface, 0, "%s: every UV2 surface id is a known surface" % mi.name)
		assert_eq(bad_hang, 0, "%s: the cape's UV2.y is a hang 0..1" % mi.name)
		assert_true(tiers > 0, "%s: the armor tier trim is on the mesh" % mi.name)
	pawn.free()


## Dominant bone of each vertex of `mesh` (bone indices of `skeleton`).
func _dominant(mesh: ArrayMesh) -> PackedInt32Array:
	var arrays := mesh.surface_get_arrays(0)
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var out := PackedInt32Array()
	out.resize(weights.size() / 4)
	for i in out.size():
		var best := 0
		for k in range(1, 4):
			if weights[i * 4 + k] > weights[i * 4 + best]:
				best = k
		out[i] = bones[i * 4 + best]
	return out


func test_mesh_is_honest_about_the_head_hitbox_in_the_bind_pose() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var centre := (pawn.get_node("Head") as Node3D).position
	var radius := Checks.head_radius(pawn)
	var hitbox := Checks.head_box(pawn)
	var head := model.skeleton.find_bone("Head")
	var margin := Checks.helmet_margin()
	var clearance := hitbox.grow(Checks.body_clearance())
	var directions: Array[Vector3] = []
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			for z in [-1, 0, 1]:
				if x != 0 or y != 0 or z != 0:
					directions.append(Vector3(x, y, z).normalized())
	for mi: MeshInstance3D in [model.armor, model.armor_far]:
		if mi == null:
			continue
		var vertices: PackedVector3Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var dominant := _dominant(mi.mesh as ArrayMesh)
		var helmet := AABB()
		var helmet_count := 0
		var reach: Array[float] = []
		reach.resize(directions.size())
		reach.fill(-INF)
		var intruders := 0
		var first_intruder := Vector3.ZERO
		var past_margin := 0
		var crest_top := 0.0
		for i in vertices.size():
			var p := vertices[i]
			if dominant[i] == head:
				helmet = AABB(p, Vector3.ZERO) if helmet_count == 0 else helmet.expand(p)
				helmet_count += 1
				for d in directions.size():
					reach[d] = maxf(reach[d], directions[d].dot(p - centre))
				# The crest (and its holder) may rise past the margin box, on the middle line only.
				var in_margin := hitbox.grow(margin + 0.0001).has_point(p)
				var crest := absf(p.x) <= 0.03 and p.y > hitbox.end.y
				if crest:
					crest_top = maxf(crest_top, p.y)
				elif not in_margin:
					past_margin += 1
			elif p.x > clearance.position.x + 0.0001 and p.x < clearance.end.x - 0.0001 and p.y > clearance.position.y + 0.0001 \
					and p.y < clearance.end.y - 0.0001 and p.z > clearance.position.z + 0.0001 and p.z < clearance.end.z - 0.0001:
				if intruders == 0:
					first_intruder = p
				intruders += 1
		var worst := INF
		for d in directions.size():
			worst = minf(worst, reach[d])
		assert_true(helmet_count > 0 and helmet.encloses(hitbox), "%s: the Head-skinned shell's box encloses the hitbox's: %s around %s" % [mi.name, helmet, hitbox])
		assert_true(worst >= radius, "%s: along each of 26 directions the helmet reaches at least the hitbox radius from its centre (least %.3f m, r %.2f)" % [mi.name, worst, radius])
		assert_eq(past_margin, 0, "%s: helmet vertices stay within the margin box (crest excepted)" % mi.name)
		assert_true(crest_top <= 2.1 + 0.0001, "%s: the crest top no higher than 2.10 m (%.3f)" % [mi.name, crest_top])
		assert_eq(intruders, 0, "%s: no body vertex inside the head hitbox grown by body_clearance (first %s)" % [mi.name, first_intruder])
		print("SOLDIER_GLB %s helmet_box=%s least_reach_m=%.3f body_intruders=%d crest_top=%.3f" % [mi.name, helmet, worst, intruders, crest_top])
	pawn.free()


func test_part_boxes_are_a_truthful_proxy_of_the_helmet_and_the_boots() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var names: Array = model.get_meta("parts")
	var vertices: PackedVector3Array = (model.armor.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var dominant := _dominant(model.armor.mesh as ArrayMesh)
	var regions := {
		"helmet": [model.skeleton.find_bone("Head")],
		"left boot": [model.skeleton.find_bone("LeftFoot"), model.skeleton.find_bone("LeftToes")],
		"right boot": [model.skeleton.find_bone("RightFoot"), model.skeleton.find_bone("RightToes")],
	}
	for region: String in regions.keys():
		var bones: Array = regions[region]
		var parts := AABB()
		var part_count := 0
		for i in model.part_bounds.size():
			if bones.has(model.part_bones[i]):
				parts = model.part_bounds[i] if part_count == 0 else parts.merge(model.part_bounds[i])
				part_count += 1
		var mesh := AABB()
		var count := 0
		for i in vertices.size():
			if bones.has(dominant[i]):
				mesh = AABB(vertices[i], Vector3.ZERO) if count == 0 else mesh.expand(vertices[i])
				count += 1
		assert_true(part_count > 0 and count > 0, "%s: part boxes and mesh vertices exist" % region)
		var worst := 0.0
		for axis in 3:
			worst = maxf(worst, absf(parts.position[axis] - mesh.position[axis]))
			worst = maxf(worst, absf(parts.end[axis] - mesh.end[axis]))
		assert_true(worst <= PROXY_TOLERANCE_M, "%s: the part boxes bound the mesh region within %.2f m (worst face %.3f m; parts %s, mesh %s)" % [region, PROXY_TOLERANCE_M, worst, parts, mesh])
		print("SOLDIER_GLB proxy %s parts=%s mesh=%s worst_face_m=%.3f" % [region, parts, mesh, worst])
	pawn.free()
