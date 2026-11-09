extends "res://tests/test_case.gd"
## C1: the kit's new shapes (taper, wedge, plate, lathe) behind a part's "shape" key.
const Perf := preload("res://tests/test_astra_perf.gd")

const SIZE := [0.6, 0.4, 0.3]
const TOLERANCE := 0.00001  # float comparison slack in metres, not a tunable


func _defaults() -> Dictionary:
	return LowpolyKit.config()["kit"]["shapes"]


func _part(shape: String, extra: Dictionary = {}) -> Dictionary:
	var part := {"name": shape, "shape": shape, "size": SIZE, "at": [0.2, 1.0, -0.1], "color": "armor"}
	part.merge(extra, true)
	return part


## Parts that exercise every shape and its options.
func _samples() -> Array[Dictionary]:
	return [
		_part("taper"),
		_part("taper", {"top": [0.5, 0.8], "top_shift": [0.25, -0.1], "bevel": 0.0}),
		_part("taper", {"top": [1, 1], "bottom": [0.4, 0.6]}),
		_part("wedge"),
		_part("wedge", {"ridge": 0.5}),
		_part("wedge", {"ridge": 1.0}),
		_part("plate"),
		_part("plate", {"arc_deg": 60, "segments": 2, "thickness": 0.4}),
		_part("plate", {"arc_deg": 270, "segments": 9}),
		_part("lathe"),
		_part("lathe", {"segments": 5}),
		_part("lathe", {"segments": 10, "profile": [[0, 0], [0.6, 0], [1, 0.45], [0.8, 0.85], [0, 1]]}),
		_part("lathe", {"sweep_deg": 150, "segments": 4, "profile": [[0.8, 0], [1, 0], [0.7, 1], [0.6, 1]]}),
	]


func _bounds(points: PackedVector3Array) -> AABB:
	var box := AABB(points[0], Vector3.ZERO)
	for p in points:
		box = box.expand(p)
	return box


func test_shape_defaults_are_marked_placeholder_data() -> void:
	var shapes := _defaults()
	assert_true(bool(shapes["_placeholder"]) and String(shapes["_todo"]).contains("OQ-3D-KIT"), "shape defaults are placeholders with an OQ id")
	assert_eq(LowpolyShapes.SHAPES, ["taper", "wedge", "plate", "lathe"] as Array[String], "tapered box, wedge, curved plate, lathe")
	for group: Array in [LowpolyKit.config()["soldier"]["parts"], LowpolyKit.config()["rifle"]["parts"]]:
		for part: Dictionary in group:
			var shape := String(part.get("shape", "box"))
			assert_true(shape == "box" or LowpolyShapes.SHAPES.has(shape), "known shape on part %s: %s" % [part["name"], shape])


func test_shapes_are_deterministic_closed_outward_and_fill_their_size_box() -> void:
	var counts := {}
	for part in _samples():
		var label := "%s %s" % [part["shape"], str(part.keys().slice(5))]
		var points := LowpolyShapes.triangles(part, _defaults())
		assert_eq(points, LowpolyShapes.triangles(part, _defaults()), "deterministic vertices: " + label)
		assert_true(points.size() >= 12 and points.size() % 3 == 0, "whole triangles: " + label)
		var box := _bounds(points)
		var size := LowpolyKit.vec(part["size"])
		assert_true(box.position.is_equal_approx(-size * 0.5) and box.size.is_equal_approx(size), "bounds match size: %s got %s" % [label, box])
		# Closed and consistently wound: every directed edge is answered by its reverse, and the outward volume is positive.
		var edges := {}
		var volume := 0.0
		for i in range(0, points.size(), 3):
			var normal := (points[i + 1] - points[i]).cross(points[i + 2] - points[i])
			assert_true(normal.length() > 0.0, "no zero-area triangle: " + label)
			volume += points[i].dot(normal) / 6.0
			for k in 3:
				var key := "%s>%s" % [Vector3i((points[i + k] / TOLERANCE).round()), Vector3i((points[i + (k + 1) % 3] / TOLERANCE).round())]
				edges[key] = int(edges.get(key, 0)) + 1
		var open := 0
		for key: String in edges:
			var ends := key.split(">")
			if int(edges[key]) != int(edges.get("%s>%s" % [ends[1], ends[0]], 0)):
				open += 1
		assert_eq(open, 0, "closed surface, consistent winding: " + label)
		assert_true(volume > 0.0 and volume <= size.x * size.y * size.z + TOLERANCE, "faces point outward, volume inside the box: %s volume=%s" % [label, volume])
		if not counts.has(part["shape"]):
			counts[part["shape"]] = points.size() / 3
	print("KIT_SHAPES default triangles ", counts, " chamfered_box=", Perf.triangles(LowpolyKit.merge([{"name": "b", "size": SIZE, "at": [0, 0, 0], "color": "armor"}])))


func test_shape_key_builds_into_the_shared_surface_and_box_stays_the_default() -> void:
	var plain := {"name": "plain", "size": SIZE, "at": [0, 1, 0], "color": "cloth"}
	var boxed := plain.duplicate()
	boxed["shape"] = "box"
	boxed["rot"] = [0, 45, 0]  # the box ignores "rot": old data can never pick it up by accident
	assert_eq(LowpolyKit.merge([boxed]).surface_get_arrays(0), LowpolyKit.merge([plain]).surface_get_arrays(0), "no shape key = chamfered box")
	assert_eq(LowpolyShapes.bounds_of(boxed, _defaults()), AABB(Vector3(-0.3, 0.8, -0.15), LowpolyKit.vec(SIZE)), "box bounds are its size box")
	var parts: Array = [plain]
	var expected := Perf.triangles(LowpolyKit.merge([plain]))
	for part in _samples():
		parts.append(part)
		expected += LowpolyShapes.triangles(part, _defaults()).size() / 3
	var mesh := LowpolyKit.merge(parts)
	assert_eq(mesh.get_surface_count(), 1, "one vertex colour surface")
	assert_eq(Perf.triangles(mesh), expected, "every part's triangles are in the surface")
	assert_eq(mesh.surface_get_arrays(0), LowpolyKit.merge(parts).surface_get_arrays(0), "deterministic mesh")
	var bones := PackedInt32Array()
	for i in parts.size():
		bones.append(i % 3)
	var skinned := LowpolyKit.merge_skinned(parts, bones)
	var arrays := skinned.surface_get_arrays(0)
	assert_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), expected * 3, "skinned merge has the same triangles")
	assert_eq((arrays[Mesh.ARRAY_BONES] as PackedInt32Array).size(), expected * 3 * 4, "four bone slots per vertex")
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in range(0, vertices.size(), 3):
		assert_true(normals[i].is_equal_approx(normals[i + 1]) and normals[i].is_equal_approx(normals[i + 2]) and normals[i].is_normalized(), "flat shaded unit normals")


func test_rot_turns_a_shape_around_its_centre_and_bounds_follow() -> void:
	var straight := _part("wedge")
	var turned := _part("wedge", {"rot": [0, 90, 0]})
	var mesh := LowpolyKit.merge([turned])
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var box := _bounds(vertices)
	var size := LowpolyKit.vec(SIZE)
	assert_true(box.get_center().is_equal_approx(LowpolyKit.vec(turned["at"])), "turned around its own centre")
	assert_true(box.size.is_equal_approx(Vector3(size.z, size.y, size.x)), "a quarter turn swaps width and depth: %s" % box.size)
	assert_true(LowpolyShapes.bounds_of(turned, _defaults()).grow(TOLERANCE).encloses(box), "bounds_of covers the turned mesh")
	assert_eq(LowpolyShapes.bounds_of(straight, _defaults()), AABB(LowpolyKit.vec(straight["at"]) - size * 0.5, size), "no rot: bounds are the size box")
	var tilted := _part("plate", {"rot": [20, 35, -10]})
	var tilted_box := _bounds(LowpolyKit.merge([tilted]).surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	var claimed := LowpolyShapes.bounds_of(tilted, _defaults())
	assert_true(claimed.grow(TOLERANCE).encloses(tilted_box) and tilted_box.grow(TOLERANCE).encloses(claimed), "bounds_of is exact for any turn")


## "axis": true keeps an arc on its turning axis, so arcs with one `at` share a centre and "rot" swings them around it.
func test_axis_arcs_share_a_centre_and_claim_only_their_own_space() -> void:
	var size := LowpolyKit.vec(SIZE)
	var at := Vector3(0.2, 1.0, -0.1)
	var ring := _part("plate", {"axis": true, "arc_deg": 360, "segments": 8})
	var ring_box := _bounds(LowpolyKit.merge([ring]).surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	assert_true(ring_box.position.is_equal_approx(at - size * 0.5) and ring_box.size.is_equal_approx(size), "a full turn fills the size box around the axis: %s" % ring_box)
	for yaw: float in [0.0, 90.0, 180.0, -90.0]:
		var arc := _part("plate", {"axis": true, "arc_deg": 60, "segments": 3, "rot": [0, yaw, 0]})
		var points := LowpolyShapes.triangles(arc, _defaults())
		var facing := Basis.from_euler(Vector3(0, deg_to_rad(yaw), 0)) * Vector3.FORWARD
		var box := _bounds(LowpolyKit.merge([arc]).surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
		for p in points:
			var flat := Vector2(p.x / (size.x * 0.5), p.z / (size.z * 0.5))
			assert_true(flat.length() <= 1.0 + TOLERANCE, "every corner is on or inside the full turn")
		assert_true((box.get_center() - at).dot(facing) > 0.0, "the arc sits on the side it is turned to (yaw %s)" % yaw)
		assert_true(ring_box.grow(TOLERANCE).encloses(box), "an arc stays inside the ring it is cut from")
		assert_true(box.get_volume() < ring_box.get_volume() * 0.5, "an arc claims only its own space, not the whole turn")
		assert_true(LowpolyShapes.bounds_of(arc, _defaults()).grow(TOLERANCE).encloses(box), "bounds_of follows the arc")
