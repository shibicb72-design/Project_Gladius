extends "res://tests/test_case.gd"
## M2 L1b: MapChunks' piece ids. add(..., piece_id) names an instance; after build() the id maps to the right batch
## and index (two chunks, two types); hide_piece sets a zero-scale basis at the same origin in the batch's
## "transforms" meta (and on the MultiMesh when the renderer keeps instance data, not headless) and show_piece
## restores it; other instances, pieces without an id and the batch's range_m / radius_m metas are untouched;
## unknown ids return false and a duplicate id is reported and keeps the first.

const CHUNK_M := 100.0


func _mesh() -> BoxMesh:
	var m := BoxMesh.new()
	m.size = Vector3(1, 1, 1)
	return m


## Ground 200 m at 100 m chunks: x -50 is chunk (0, *), x +50 chunk (1, *).
func _chunks() -> MapChunks:
	MapChunks.size_override_m = CHUNK_M
	var c := MapChunks.new()
	c.setup(200.0)
	MapChunks.size_override_m = 0.0
	return c


func _at(x: float, z: float) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(x, 0.5, z))


## The four named pieces and two unnamed ones, built: {chunks, mesh}.
func _built() -> Dictionary:
	var c := _chunks()
	var mesh := _mesh()
	c.add("cover", "crate", mesh, null, _at(-50, -50), true, "A")
	c.add("cover", "crate", mesh, null, _at(-40, -50), true)  # no id
	c.add("cover", "crate", mesh, null, _at(-30, -50), true, "B")
	c.add("cover", "barrier", mesh, null, _at(-50, -40), true, "C")
	c.add("cover", "crate", mesh, null, _at(50, -50), true, "D")
	c.add("cover", "crate", mesh, null, _at(60, -50), true)  # no id
	c.build()
	return {"chunks": c, "mesh": mesh}


func _meta(batch: MultiMeshInstance3D, i: int) -> Transform3D:
	return batch.get_meta(&"transforms")[i]


func test_ids_map_to_their_batch_and_index() -> void:
	var c: MapChunks = _built()["chunks"]
	var left := c.get_node("Chunk_0_0/Batch_cover_crate") as MultiMeshInstance3D
	var left_b := c.get_node("Chunk_0_0/Batch_cover_barrier") as MultiMeshInstance3D
	var right := c.get_node("Chunk_1_0/Batch_cover_crate") as MultiMeshInstance3D
	assert_true(left != null and left_b != null and right != null, "three batches in two chunks")
	for id: String in ["A", "B", "C", "D"]:
		assert_true(c.has_piece(id), id + " is known")
		assert_true(not c.is_piece_hidden(id), id + " starts shown")
	assert_true(not c.has_piece("E") and not c.has_piece(""), "unknown ids are not pieces")
	assert_true(c._ids["A"]["node"] == left and int(c._ids["A"]["index"]) == 0, "A: chunk 0 crate, index 0")
	assert_true(c._ids["B"]["node"] == left and int(c._ids["B"]["index"]) == 2, "B: chunk 0 crate, index 2 (after the unnamed piece)")
	assert_true(c._ids["C"]["node"] == left_b and int(c._ids["C"]["index"]) == 0, "C: chunk 0 barrier, index 0")
	assert_true(c._ids["D"]["node"] == right and int(c._ids["D"]["index"]) == 0, "D: chunk 1 crate, index 0")
	c.free()


func test_hide_and_show_round_trip() -> void:
	var c: MapChunks = _built()["chunks"]
	var left := c.get_node("Chunk_0_0/Batch_cover_crate") as MultiMeshInstance3D
	var right := c.get_node("Chunk_1_0/Batch_cover_crate") as MultiMeshInstance3D
	# A renderer that keeps instance data reads back what build() set; headless (the test runner) does not.
	var keeps := left.multimesh.get_instance_transform(0).is_equal_approx(_at(-50, -50))
	var range_before: Variant = left.get_meta(&"range_m")
	var radius_before: Variant = left.get_meta(&"radius_m")
	var end_before := left.visibility_range_end
	var others := [_meta(left, 1), _meta(left, 2)]
	var right_before := [_meta(right, 0), _meta(right, 1)]
	assert_true(c.hide_piece("A"), "hide A")
	var hidden := _meta(left, 0)
	assert_eq(hidden.origin, Vector3(-50, 0.5, -50), "a hidden instance keeps its origin")
	assert_eq(hidden.basis, Basis.from_scale(Vector3.ZERO), "a hidden instance has a zero basis")
	assert_true(c.is_piece_hidden("A"), "A is hidden")
	if keeps:
		assert_true(left.multimesh.get_instance_transform(0).basis == Basis.from_scale(Vector3.ZERO), "the MultiMesh instance is zero-scaled too")
	assert_eq([_meta(left, 1), _meta(left, 2)], others, "the other instances of the batch are untouched")
	assert_eq([_meta(right, 0), _meta(right, 1)], right_before, "the other chunk's batch is untouched")
	assert_eq(left.get_meta(&"range_m"), range_before, "range_m unchanged")
	assert_eq(left.get_meta(&"radius_m"), radius_before, "radius_m unchanged")
	assert_eq(left.visibility_range_end, end_before, "the visibility range is unchanged")
	assert_eq((left.get_meta(&"transforms") as Array).size(), 3, "the instance keeps its slot")
	assert_eq(left.multimesh.instance_count, 3, "no reallocation")
	assert_true(c.hide_piece("A") and c.is_piece_hidden("A"), "hiding twice is fine")
	assert_true(c.show_piece("A"), "show A")
	assert_eq(_meta(left, 0), _at(-50, -50), "the original transform is back in the meta")
	assert_true(not c.is_piece_hidden("A"), "A is shown")
	if keeps:
		assert_true(left.multimesh.get_instance_transform(0).is_equal_approx(_at(-50, -50)), "and on the MultiMesh")
	assert_true(c.hide_piece("D") and c.is_piece_hidden("D") and not c.is_piece_hidden("B"), "hiding D in the other chunk leaves B shown")
	assert_eq(_meta(right, 1), right_before[1], "D's unnamed neighbour is untouched")
	c.free()


func test_unknown_and_duplicate_ids() -> void:
	var c := _chunks()
	var errors: Array = []
	c.error_sink = func(message: String) -> void: errors.append(message)
	var mesh := _mesh()
	c.add("cover", "crate", mesh, null, _at(-50, -50), true, "A")
	c.add("cover", "crate", mesh, null, _at(-20, -20), true, "A")
	c.build()
	assert_eq(errors.size(), 1, "a duplicate id is reported once")
	assert_true(errors.size() == 1 and String(errors[0]).contains("A"), "the report names the id")
	var batch := c.get_node("Chunk_0_0/Batch_cover_crate") as MultiMeshInstance3D
	assert_eq((batch.get_meta(&"transforms") as Array).size(), 2, "the duplicate's instance is still drawn")
	assert_eq(int(c._ids["A"]["index"]), 0, "the first keeps the id")
	c.hide_piece("A")
	assert_eq(_meta(batch, 1), _at(-20, -20), "hiding A leaves the duplicate's instance")
	assert_true(not c.hide_piece("nope") and not c.show_piece("nope") and not c.is_piece_hidden("nope"), "unknown ids return false")
	c.free()


func test_pieces_without_ids_build_as_before() -> void:
	var named := _chunks()
	var plain := _chunks()
	var mesh := _mesh()
	for i in 4:
		named.add("cover", "crate", mesh, null, _at(-50 + i * 30, 10), true, "P%d" % i)
		plain.add("cover", "crate", mesh, null, _at(-50 + i * 30, 10), true)
	named.build()
	plain.build()
	var a := named.batches()
	var b := plain.batches()
	assert_eq(a.size(), b.size(), "same batches with and without ids")
	for i in mini(a.size(), b.size()):
		assert_eq(String(a[i].name), String(b[i].name), "batch %d name" % i)
		for key: StringName in [&"transforms", &"source", &"type", &"class", &"collides", &"range_m", &"radius_m"]:
			assert_eq(a[i].get_meta(key), b[i].get_meta(key), "batch %d meta %s" % [i, key])
		assert_eq(a[i].visibility_range_end, b[i].visibility_range_end, "batch %d range end" % i)
	assert_true(plain._ids.is_empty(), "no id map without ids")
	named.free()
	plain.free()
