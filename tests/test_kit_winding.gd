extends "res://tests/test_case.gd"
## F1: kit triangles must face the way the engine draws them. Godot's front face is clockwise, and
## Plane(a, b, c).normal is that front side. LowpolyKit stores the outward normal with every corner, so both must
## agree; otherwise back-face culling removes the outside of every kit mesh and shows the inside of its far side.


## [front-facing triangles, triangles] for one surface.
func _front_facing(mesh: Mesh) -> Vector2i:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	else:
		for i in vertices.size():
			indices.append(i)
	var agree := 0
	for i in range(0, indices.size(), 3):
		var front := Plane(vertices[indices[i]], vertices[indices[i + 1]], vertices[indices[i + 2]]).normal
		if front.dot(normals[indices[i]]) > 0.0:
			agree += 1
	return Vector2i(agree, indices.size() / 3)


func test_engine_box_confirms_the_front_face_rule() -> void:
	var box := BoxMesh.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	var result := _front_facing(mesh)
	assert_true(result.y == 12 and result.x == 12, "control: the engine's own box is front-facing by this reading: %s" % result)


func test_every_kit_mesh_is_front_facing_with_outward_normals() -> void:
	var meshes := {}
	for kind: String in ["pillar", "rock", "rubble", "arch", "sandbags", "wall", "low_wall", "barrier", "crate", "camp", "box"]:
		meshes["build/" + kind] = LowpolyKit.build(kind, Vector3(2, 1, 1))
	meshes["soldier"] = LowpolyKit.merge(LowpolyKit.config()["soldier"]["parts"])
	meshes["rifle"] = LowpolyKit.merge(LowpolyKit.config()["rifle"]["parts"])
	var bones := PackedInt32Array()
	bones.resize((LowpolyKit.config()["soldier"]["parts"] as Array).size())
	meshes["soldier skinned"] = LowpolyKit.merge_skinned(LowpolyKit.config()["soldier"]["parts"], bones)
	for shape in LowpolyShapes.SHAPES:
		meshes["shape/" + shape] = LowpolyKit.merge([{"name": shape, "shape": shape, "size": [0.6, 0.4, 0.3], "at": [0, 0, 0], "color": "armor"}])
	var total := 0
	var front := 0
	for label: String in meshes:
		var result := _front_facing(meshes[label])
		total += result.y
		front += result.x
		assert_true(result.y > 0 and result.x == result.y, "%s: %d of %d triangles front-facing" % [label, result.x, result.y])
	# Outward too, on a shape where "outward" is unambiguous: a convex box centred on the origin.
	var arrays := (meshes["build/box"] as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in range(0, vertices.size(), 3):
		assert_true(normals[i].dot((vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0) > 0.0, "stored normal points out of the box")
	print("KIT_WINDING meshes=", meshes.size(), " triangles=", total, " front_facing=", front)
