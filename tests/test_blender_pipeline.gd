extends "res://tests/test_case.gd"
## M2 AN2: the Blender to Godot pipeline proof. assets/generated/characters/pipeline_proof.glb is written by
## tools/blender/build_pipeline_proof.py (a box-man of 8 boxes on 8 bones named and parented as in data/anim.json
## "bones", one looping clip). This checks what the soldier and view-model .glb files will rely on: the skeleton
## and its bone names, identity rest bases (the soldier_rig.gd convention), the clip name with the _Loop suffix
## dropped and looping, a skinned mesh with blended weights, and the vertex stream the soldier shader reads:
## COLOR as the sRGB numbers written (alpha 0 = squad field), UV2 = (surface id, shade), tangents.

const PROOF := "res://assets/generated/characters/pipeline_proof.glb"
const BONES := ["Hips", "Spine", "Chest", "Neck", "Head", "RightUpperArm", "RightForeArm", "RightHand"]
# The paints and (surface id, shade) pairs build_pipeline_proof.py writes (PARTS there), sRGB numbers.
const PAINTS := [Color(0.42, 0.36, 0.3), Color(0.62, 0.64, 0.68), Color(0.5, 0.4, 0.33), Color(0.7, 0.7, 0.72), Color(0.55, 0.45, 0.35), Color(0.3, 0.25, 0.2)]
const UV2S := [Vector2(4, 0.5), Vector2(1, 0.4), Vector2(2, 0.6), Vector2(5, 0.5), Vector2(1, 0.75), Vector2(6, 0.5), Vector2(6, 0.25)]


func test_proof_glb_imports_with_rig_clip_and_vertex_stream() -> void:
	var packed := load(PROOF) as PackedScene
	assert_true(packed != null, "the proof .glb imports as a scene")
	if packed == null:
		return
	var scene := packed.instantiate()
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	assert_eq(skeletons.size(), 1, "one skeleton")
	var players := scene.find_children("*", "AnimationPlayer", true, false)
	assert_eq(players.size(), 1, "one AnimationPlayer")
	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	assert_eq(meshes.size(), 1, "one mesh")
	assert_eq(scene.find_children("*", "Camera3D", true, false).size() + scene.find_children("*", "Light3D", true, false).size(), 0, "no cameras or lights")
	if skeletons.size() != 1 or players.size() != 1 or meshes.size() != 1:
		scene.free()
		return
	var skeleton := skeletons[0] as Skeleton3D
	var anim_tables: Dictionary = DataRegistry.new().load_file("res://data/anim.json")
	var parents := {}
	for bone: Dictionary in anim_tables["bones"]:
		parents[String(bone["name"])] = String(bone["parent"])
	assert_eq(skeleton.get_bone_count(), BONES.size(), "bone count")
	var worst_basis := 0.0
	for name: String in BONES:
		var i := skeleton.find_bone(name)
		assert_true(i >= 0, "bone " + name)
		if i < 0:
			continue
		var parent := skeleton.get_bone_parent(i)
		assert_eq(skeleton.get_bone_name(parent) if parent >= 0 else "", parents[name], "parent of %s as in data/anim.json" % name)
		var basis := skeleton.get_bone_global_rest(i).basis
		for axis in 3:
			worst_basis = maxf(worst_basis, (basis[axis] - Basis.IDENTITY[axis]).length())
	assert_true(worst_basis < 0.0001, "every rest basis is identity (worst %.6f)" % worst_basis)
	var head := skeleton.get_bone_global_rest(skeleton.find_bone("Head")).origin
	assert_true(head.is_equal_approx(Vector3(0.0, 1.6, 0.0)), "Head rest at (0, 1.6, 0) in Godot metres, +Y up: %s" % head)
	var arm := skeleton.get_bone_global_rest(skeleton.find_bone("RightUpperArm")).origin
	assert_true(arm.is_equal_approx(Vector3(0.24, 1.41, 0.0)), "RightUpperArm rest at +X (the soldier's right): %s" % arm)

	var player := players[0] as AnimationPlayer
	assert_true(player.has_animation(&"proof_wave"), "the clip arrives as proof_wave (the _Loop suffix dropped): %s" % [player.get_animation_list()])
	var clip := player.get_animation(&"proof_wave") if player.has_animation(&"proof_wave") else null
	var length := clip.length if clip != null else 0.0
	assert_true(absf(length - 1.0) < 0.001, "clip length 1 s (%.3f)" % length)
	assert_true(clip != null and clip.loop_mode == Animation.LOOP_LINEAR, "the clip loops")
	var bone_tracks := 0
	var rotation_track := -1
	if clip != null:
		for t in clip.get_track_count():
			var path := clip.track_get_path(t)
			if path.get_subname_count() > 0 and skeleton.find_bone(path.get_subname(0)) >= 0:
				bone_tracks += 1
				if path.get_subname(0) == "RightForeArm" and clip.track_get_type(t) == Animation.TYPE_ROTATION_3D:
					rotation_track = t
	assert_true(bone_tracks > 0, "the clip drives skeleton bones by name")
	assert_true(rotation_track >= 0, "a RightForeArm rotation track")
	if rotation_track >= 0:
		var q0: Quaternion = clip.rotation_track_interpolate(rotation_track, 0.0)
		var q1: Quaternion = clip.rotation_track_interpolate(rotation_track, 0.25)
		var q2: Quaternion = clip.rotation_track_interpolate(rotation_track, 1.0)
		assert_true(q0.angle_to(q1) > deg_to_rad(30.0), "the forearm swings by a quarter cycle (%.1f deg)" % rad_to_deg(q0.angle_to(q1)))
		assert_true(q0.angle_to(q2) < deg_to_rad(0.5), "the cycle closes (%.2f deg)" % rad_to_deg(q0.angle_to(q2)))

	var mi := meshes[0] as MeshInstance3D
	assert_true(mi.skin != null and mi.skin.get_bind_count() == BONES.size(), "a Skin binding every bone")
	assert_true(mi.get_node_or_null(mi.skeleton) == skeleton, "the mesh is skinned to the skeleton")
	var mesh := mi.mesh as ArrayMesh
	assert_eq(mesh.get_surface_count(), 1, "one surface")
	var imported_material := mesh.surface_get_material(0)
	# The file has no material; Godot's importer gives the surface a default StandardMaterial3D kept inside the imported
	# scene (nothing extracted beside the .glb). The game replaces it with its own material.
	assert_true(imported_material == null or imported_material.resource_path.contains("::"), "no material file extracted: %s" % [imported_material])
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	var tris := (indices as PackedInt32Array).size() / 3 if indices != null else vertices.size() / 3
	assert_eq(tris, 96, "triangles")
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	assert_eq(weights.size(), vertices.size() * 4, "four weights per vertex")
	assert_eq(bones.size(), vertices.size() * 4, "four bone indices per vertex")
	var blended := 0
	for i in vertices.size():
		if weights[i * 4] < 0.99:
			blended += 1
	assert_true(blended > 0, "blended weights survive (the forearm's upper corners)")
	var colors: Variant = arrays[Mesh.ARRAY_COLOR]
	assert_true(colors != null and (colors as PackedColorArray).size() == vertices.size(), "COLOR survives")
	var alpha0 := 0
	var unmatched := 0
	var first_off := Color()
	if colors != null:
		for c: Color in colors as PackedColorArray:
			if c.a == 0.0:
				alpha0 += 1
			elif not is_equal_approx(c.a, 1.0):
				unmatched += 1
			else:
				var found := false
				for p: Color in PAINTS:
					if absf(c.r - p.r) <= 0.0045 and absf(c.g - p.g) <= 0.0045 and absf(c.b - p.b) <= 0.0045:  # one 8-bit step: COLOR is stored as RGBA8
						found = true
				if not found:
					unmatched += 1
					first_off = c
	assert_true(alpha0 > 0, "vertex alpha 0 (the squad field) survives")
	assert_eq(unmatched, 0, "every other vertex arrives with alpha 1 and the sRGB numbers written (no colour-space conversion; first off %s)" % first_off)
	var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
	var uv2_bad := 0
	if uv2 != null:
		for v: Vector2 in uv2 as PackedVector2Array:
			var found := false
			for want: Vector2 in UV2S:
				if v.distance_to(want) < 0.001:
					found = true
			if not found:
				uv2_bad += 1
	assert_true(uv2 != null and uv2_bad == 0, "UV2 = (surface id, shade) as written (%d off)" % uv2_bad)
	assert_true(arrays[Mesh.ARRAY_TEX_UV] != null, "UV survives")
	var tangents: Variant = arrays[Mesh.ARRAY_TANGENT]
	assert_true(tangents != null and (tangents as PackedFloat32Array).size() == vertices.size() * 4, "tangents (the soldier shader's normal map needs them)")
	print("BLENDER_PIPELINE bones=%d rest_identity=%s clip=proof_wave length=%.3f loop=%s tris=%d vertices=%d alpha0=%d colour_as_written=%s uv2_as_written=%s blended=%d tangents=%s" % [
		skeleton.get_bone_count(), worst_basis < 0.0001, length, clip != null and clip.loop_mode == Animation.LOOP_LINEAR,
		tris, vertices.size(), alpha0, unmatched == 0, uv2 != null and uv2_bad == 0, blended, tangents != null])
	scene.free()
