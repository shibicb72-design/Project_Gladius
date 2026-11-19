extends "res://tests/test_case.gd"
## M2 AN2 item 4a: the Blender-built first-person arms and weapons (assets/generated/characters/view_arms.glb,
## assets/generated/weapons/<id>.glb; tools/blender/build_view_arms.py, build_weapons.py) against the game's own rig
## and data. The arm's armature equals the runtime arm skeleton ViewHands builds from data/art_soldier.json hands (names,
## parents, local rests within 0.1 mm), its weights are normalized (at most 4), the arm is one surface; each weapon file
## has its pieces (Mesh with an opaque and a glass pass, Cell and Charge at the data's rests, the third-person LODs) and
## its anchor copies sit on the data's points; triangle counts stay within the item's targets; at runtime every surface
## carries the game's pass material and its colours are data material classes.

const REST_TOLERANCE_M := 0.0001
const BASIS_TOLERANCE := 0.0001
const GUNS: Array[String] = ["pilum_br", "sagittarii_rifle"]
const IDS: Array[String] = ["pilum_br", "sagittarii_rifle", "gladius_lux"]


func _art() -> Dictionary:
	return ViewMesh.config()


## The caps on the Blender files: data/art_soldier.json budget.blender (placeholders). gun = first person Mesh + Cell + Charge.
func _cap(key: String) -> int:
	return int(_art()["budget"]["blender"][key])


func _triangles(mesh: Mesh) -> int:
	return ViewMesh.triangle_count(mesh) if mesh != null else 0


func test_arm_glb_rig_equals_the_runtime_arm_skeleton() -> void:
	var source := ViewHands.mesh_source()
	assert_true(source.ends_with("view_arms.glb"), "hands.mesh_source names the Blender arm: %s" % source)
	var packed := load(source) as PackedScene
	assert_true(packed != null, "view_arms.glb imports as a scene")
	if packed == null:
		return
	var scene := packed.instantiate()
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	assert_eq(skeletons.size(), 1, "one armature")
	var arm_mi := scene.find_child("Arm", true, false) as MeshInstance3D
	assert_true(arm_mi != null and arm_mi.skin != null, "a skinned mesh Arm")
	if skeletons.is_empty() or arm_mi == null:
		scene.free()
		return
	var theirs := skeletons[0] as Skeleton3D
	var runtime := ViewHands.build_arm("r")
	var ours := runtime.get_node("Skeleton") as Skeleton3D
	assert_eq(ours.get_bone_count(), 18, "the runtime arm includes the cuff bone")
	assert_eq(theirs.get_bone_count(), ours.get_bone_count(), "the .glb carries the same bones (no superset)")
	var worst_origin := 0.0
	var worst_basis := 0.0
	for i in ours.get_bone_count():
		var name := ours.get_bone_name(i)
		var j := theirs.find_bone(name)
		assert_true(j >= 0, "the .glb has bone " + name)
		if j < 0:
			continue
		var p_ours := ours.get_bone_parent(i)
		var p_theirs := theirs.get_bone_parent(j)
		assert_eq(theirs.get_bone_name(p_theirs) if p_theirs >= 0 else "", ours.get_bone_name(p_ours) if p_ours >= 0 else "", "parent of " + name)
		var a := ours.get_bone_rest(i)
		var b := theirs.get_bone_rest(j)
		worst_origin = maxf(worst_origin, a.origin.distance_to(b.origin))
		for axis in 3:
			worst_basis = maxf(worst_basis, (a.basis[axis] - b.basis[axis]).length())
	assert_true(worst_origin <= REST_TOLERANCE_M, "local rests equal the runtime ones within 0.1 mm (worst %.6f m)" % worst_origin)
	assert_true(worst_basis <= BASIS_TOLERANCE, "rest bases equal the runtime ones (worst axis error %.6f)" % worst_basis)
	# Weights: at most 4 influences, normalized, every joint bound to an arm bone.
	var arrays := arm_mi.mesh.surface_get_arrays(0)
	assert_eq(arm_mi.mesh.get_surface_count(), 1, "one primitive: one draw call")
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var wrist_bind := -1
	for k in arm_mi.skin.get_bind_count():
		var bname := String(arm_mi.skin.get_bind_name(k))
		if bname == "":
			bname = theirs.get_bone_name(arm_mi.skin.get_bind_bone(k))
		assert_true(ViewHands.bone_names().has(bname), "bind %d is an arm bone (%s)" % [k, bname])
		if bname == "wrist":
			wrist_bind = k
	var n := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per := weights.size() / maxi(n, 1)
	assert_eq(per, 4, "4 influences per vertex")
	var worst_sum := 0.0
	var blended := 0
	var cuff := 0
	var mixed_cuff := 0
	for v in n:
		var s := 0.0
		var used := 0
		var has_wrist := false
		for k in per:
			s += weights[v * per + k]
			if weights[v * per + k] > 0.001:
				used += 1
				has_wrist = has_wrist or joints[v * per + k] == wrist_bind
		worst_sum = maxf(worst_sum, absf(s - 1.0))
		if used > 1:
			blended += 1
		if has_wrist:
			cuff += 1
			mixed_cuff += int(used > 1)
	assert_true(worst_sum < 0.002, "weights sum to 1 (worst %.5f)" % worst_sum)
	assert_true(blended > n / 10, "blended weights at the knuckles (%d of %d vertices)" % [blended, n])
	assert_true(cuff > 0 and mixed_cuff == 0, "the cuff rings follow the wrist bone rigidly")
	ViewHands.aim_forearm(runtime, Vector3.RIGHT)
	var cuff_turn := ours.get_bone_pose_rotation(ours.find_bone("wrist")).get_angle()
	assert_true(is_equal_approx(cuff_turn, PI / 4.0), "the wrist cuff takes half the forearm's 90 degree turn")
	var tris := _triangles(arm_mi.mesh)
	assert_true(tris > 0 and tris <= _cap("arm_max_triangles"), "arm: %d triangles <= %d" % [tris, _cap("arm_max_triangles")])
	scene.free()
	runtime.free()


## The runtime arms (both sides) use the .glb mesh: one surface, the opaque pass material, linear colours from data,
## and the left arm is the mirror of the right one (same triangle count, x flipped, outward winding kept).
func test_runtime_arms_use_the_glb_mesh() -> void:
	var right := ViewHands.build_arm("r")
	var left := ViewHands.build_arm("l")
	var rm := (right.get_node("Skeleton/Mesh") as MeshInstance3D).mesh
	var lm := (left.get_node("Skeleton/Mesh") as MeshInstance3D).mesh
	assert_eq(rm.get_surface_count(), 1, "right arm: one surface")
	assert_true(rm.surface_get_material(0) == ViewMesh.material("opaque"), "right arm: the game's opaque view material")
	assert_true(lm.surface_get_material(0) == ViewMesh.material("opaque"), "left arm: the game's opaque view material")
	assert_eq(_triangles(lm), _triangles(rm), "left = right triangle count")
	var ra := rm.surface_get_arrays(0)
	var la := lm.surface_get_arrays(0)
	var rv: PackedVector3Array = ra[Mesh.ARRAY_VERTEX]
	var lv: PackedVector3Array = la[Mesh.ARRAY_VERTEX]
	var mirrored := true
	for i in rv.size():
		if not lv[i].is_equal_approx(Vector3(-rv[i].x, rv[i].y, rv[i].z)):
			mirrored = false
			break
	assert_true(mirrored, "left vertices are the right ones mirrored in x")
	# Outward winding on both: every face normal (Godot front face = clockwise) agrees with the stored vertex normals.
	for pair: Array in [[ra, "right"], [la, "left"]]:
		var arr: Array = pair[0]
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var agree := 0
		for t in range(0, idx.size(), 3):
			var face := (v[idx[t + 2]] - v[idx[t]]).cross(v[idx[t + 1]] - v[idx[t]])
			if face.dot(nrm[idx[t]] + nrm[idx[t + 1]] + nrm[idx[t + 2]]) > 0.0:
				agree += 1
		assert_true(agree >= idx.size() / 3 * 0.97, "%s arm: faces wind outward (%d of %d)" % [pair[1], agree, idx.size() / 3])
	_assert_data_colours(rm, "arm")
	right.free()
	left.free()


func test_weapon_glbs_have_their_pieces_on_the_data_points() -> void:
	var weapons: Dictionary = _art()["weapons"]
	for id in IDS:
		var a: Dictionary = weapons[id]
		var src := ViewWeapons.mesh_source(id)
		assert_true(src.ends_with("%s.glb" % id), "%s: mesh_source names its .glb (%s)" % [id, src])
		if src == "":
			continue
		var nodes := ViewMesh.glb_nodes(src)
		assert_true(nodes.has("Mesh") and nodes["Mesh"]["mesh"] != null, "%s: object Mesh" % id)
		if a.has("muzzle_m"):
			assert_true(nodes.has("Muzzle"), "%s: Muzzle empty" % id)
			if nodes.has("Muzzle"):
				var at: Vector3 = (nodes["Muzzle"]["xf"] as Transform3D).origin
				assert_true(at.distance_to(ViewMesh.vec(a["muzzle_m"])) < 0.0001, "%s: muzzle on the data's muzzle_m (%s)" % [id, at])
		if a.has("dot_m"):
			assert_true(nodes.has("Dot") and nodes.has("SightAnchor"), "%s: Dot and SightAnchor empties" % id)
			if nodes.has("Dot"):
				var dot: Vector3 = (nodes["Dot"]["xf"] as Transform3D).origin
				assert_true(dot.distance_to(ViewMesh.vec(a["dot_m"])) < 0.0001, "%s: dot on the data's dot_m" % id)
			if nodes.has("SightAnchor"):
				var sight: Vector3 = (nodes["SightAnchor"]["xf"] as Transform3D).origin
				assert_true(sight.distance_to(ViewMesh.vec(a.get("sight_m", a["dot_m"]))) < 0.0001, "%s: sight anchor on the data's point" % id)
		var fp_tris := _triangles(ViewWeapons._piece(id, "Mesh", a["parts"], id))
		for piece: String in ["Cell", "Charge"]:
			var key := piece.to_lower()
			if not a.has(key):
				continue
			assert_true(nodes.has(piece) and nodes[piece]["mesh"] != null, "%s: object %s" % [id, piece])
			if not nodes.has(piece):
				continue
			var want := ViewMesh.part_transform(a[key])
			var got: Transform3D = nodes[piece]["xf"]
			assert_true(got.origin.distance_to(want.origin) < 0.0001 and got.basis.is_equal_approx(want.basis),
					"%s: %s object at the data's rest (%s vs %s)" % [id, piece, got.origin, want.origin])
			fp_tris += _triangles(ViewMesh.glb_view_mesh(src, piece))
		var limit := _cap("blade_max_triangles") if id == "gladius_lux" else _cap("gun_max_triangles")
		assert_true(fp_tris > 0 and fp_tris <= limit, "%s: first-person %d triangles <= %d" % [id, fp_tris, limit])
		var body := ViewMesh.glb_view_mesh(src, "Mesh")
		assert_true(body.get_surface_count() >= 2, "%s: Mesh has an opaque and a glass pass (%d surfaces)" % [id, body.get_surface_count()])
		for s in body.get_surface_count():
			var mat := body.surface_get_material(s)
			assert_true(mat == ViewMesh.material("opaque") or mat == ViewMesh.material("glass") or mat == ViewMesh.material("glow"),
					"%s: surface %d carries a game pass material" % [id, s])
		_assert_data_colours(body, id)
		var line := "VIEW_GLB %s fp_triangles=%d mesh_surfaces=%d" % [id, fp_tris, body.get_surface_count()]
		if GUNS.has(id):
			var near := _triangles(SoldierLook.gun_mesh(id, "near"))
			var far := _triangles(SoldierLook.gun_mesh(id, "far"))
			var nm := SoldierLook.gun_mesh(id, "near")
			assert_true(nodes.has("ThirdNear") and nodes.has("ThirdFar"), "%s: ThirdNear and ThirdFar" % id)
			assert_eq(nm.get_surface_count(), 1, "%s: third-person near is one surface" % id)
			assert_true(nm.surface_get_material(0) == SoldierSquadColour.material(), "%s: on the one soldier material" % id)
			assert_true(near > 0 and near <= _cap("third_max_triangles"), "%s: ThirdNear %d <= %d" % [id, near, _cap("third_max_triangles")])
			assert_true(far > 0 and far < near, "%s: ThirdFar %d under the near %d" % [id, far, near])
			var src_near: Mesh = nodes["ThirdNear"]["mesh"]
			assert_eq(_triangles(src_near), near, "%s: gun_mesh near is the .glb's ThirdNear" % id)
			line += " third_near=%d third_far=%d" % [near, far]
		print(line)
	print("VIEW_GLB arm triangles=%d" % ViewHands.triangles_per_arm())


## Every vertex colour of an opaque surface is one of the data's material classes made linear (within the 8-bit
## sRGB step of the file).
func _assert_data_colours(mesh: Mesh, label: String) -> void:
	var classes: Array[Color] = []
	var mats: Dictionary = _art()["materials"]
	for key: String in mats:
		if key.begins_with("_"):
			continue
		var c: Array = mats[key]["color"]
		classes.append(Color(float(c[0]), float(c[1]), float(c[2])).srgb_to_linear())
	var worst := 0.0
	var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	for col in cols:
		var best := INF
		for k in classes:
			best = minf(best, Vector3(col.r - k.r, col.g - k.g, col.b - k.b).length())
		worst = maxf(worst, best)
	assert_true(worst < 0.01, "%s: colours are data material classes, linear (worst %.4f)" % [label, worst])
