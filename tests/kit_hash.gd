extends RefCounted
## C1 guard: SHA-256 of the mesh arrays (vertices, normals, indices) LowpolyKit builds from a frozen copy of the
## part data at commit d74333e (tests/fixtures/kit_baseline.json). Recorded before the kit gained new shapes;
## tests/test_kit_baseline.gd fails if the default chamfered-box path stops being byte-identical.
## Colours are left out on purpose: the palette may change without changing a shape.
## Two hashes per mesh: "exact" (array bytes as stored) and "canonical" (the set of triangles with their
## normals, whatever the vertex order). The canonical one separates "same geometry, other winding" from a real change.

const FIXTURE := "res://tests/fixtures/kit_baseline.json"


static func mesh_hash(mesh: ArrayMesh, with_skin: bool = false) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var streams: Array[int] = [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_INDEX]
	if with_skin:
		streams.append_array([Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS])
	for stream in streams:
		ctx.update(var_to_bytes(arrays[stream]))  # a missing stream (null) hashes as null: also locked
	return ctx.finish().hex_encode()


## Order-free: each triangle's three corners sorted, then all triangles sorted, each with its stored normal.
static func mesh_canonical_hash(mesh: ArrayMesh) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	else:
		indices.resize(vertices.size())
		for i in vertices.size():
			indices[i] = i
	var rows: PackedStringArray = []
	for i in range(0, indices.size(), 3):
		var corners: Array[Vector3] = [vertices[indices[i]], vertices[indices[i + 1]], vertices[indices[i + 2]]]
		corners.sort()
		rows.append(var_to_bytes([corners[0], corners[1], corners[2], normals[indices[i]]]).hex_encode())
	rows.sort()
	return "\n".join(rows).sha256_text()


## name -> hash for every baseline mesh: each soldier and rifle part alone, both merged, the skinned merge,
## every cover type, and every build() kind at each probe size.
static func compute(fixture: Dictionary, canonical: bool = false) -> Dictionary:
	var out := {}
	for group: String in ["soldier_parts", "rifle_parts"]:
		var parts: Array = fixture[group]
		for part: Dictionary in parts:
			out["%s/%s" % [group, part["name"]]] = _hash(LowpolyKit.merge([part]), canonical)
		out["%s/*merged" % group] = _hash(LowpolyKit.merge(parts), canonical)
	var soldier: Array = fixture["soldier_parts"]
	var bones := PackedInt32Array()
	for i in soldier.size():
		bones.append(i % int(fixture["skin_bone_count"]))
	out["soldier_parts/*skinned"] = _hash(LowpolyKit.merge_skinned(soldier, bones), canonical, true)
	var types: Dictionary = fixture["cover_types"]
	for type: String in types:
		out["cover_types/%s" % type] = _hash(LowpolyKit.build_cover(types[type]), canonical)
	for kind: String in fixture["kinds"]:
		for size: Array in fixture["probe_sizes"]:
			var label := "%sx%sx%s" % [float(size[0]), float(size[1]), float(size[2])]  # JSON turns ints into floats
			out["build/%s/%s" % [kind, label]] = _hash(LowpolyKit.build(kind, LowpolyKit.vec(size)), canonical)
	return out


static func _hash(mesh: ArrayMesh, canonical: bool, with_skin: bool = false) -> String:
	return mesh_canonical_hash(mesh) if canonical else mesh_hash(mesh, with_skin)
