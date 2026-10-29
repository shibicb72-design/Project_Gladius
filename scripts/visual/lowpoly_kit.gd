class_name LowpolyKit
extends RefCounted
## Deterministic, flat shaded procedural geometry. Shape ratios are placeholder art data.
static var _registry := DataRegistry.new()

static func config() -> Dictionary:
	return _registry.load_file("res://data/art_astra.json")

static func vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for v in [a, b, c]:
		st.set_normal(normal)
		st.set_color(color)
		st.add_vertex(v)

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	_triangle(st, a, b, c, color)
	_triangle(st, a, c, d, color)

## Eight-sided chamfered rectangular prism, with inset bevelled top and bottom.
static func _box(st: SurfaceTool, size: Vector3, at: Vector3, color: Color, bevel: float) -> void:
	var half := size * 0.5
	var cut := minf(minf(size.x, size.y), size.z) * bevel
	var outline: Array[Vector2] = [
		Vector2(-half.x + cut, -half.z), Vector2(half.x - cut, -half.z),
		Vector2(half.x, -half.z + cut), Vector2(half.x, half.z - cut),
		Vector2(half.x - cut, half.z), Vector2(-half.x + cut, half.z),
		Vector2(-half.x, half.z - cut), Vector2(-half.x, -half.z + cut)]
	var rings: Array = []
	for level in 4:
		var ring: Array[Vector3] = []
		var inset := cut if level == 0 or level == 3 else 0.0
		var y: float = [-half.y, -half.y + cut, half.y - cut, half.y][level]
		for p in outline:
			ring.append(at + Vector3(p.x - signf(p.x) * inset, y, p.y - signf(p.y) * inset))
		rings.append(ring)
	for level in 3:
		for i in 8:
			var j := (i + 1) % 8
			_quad(st, rings[level][i], rings[level + 1][i], rings[level + 1][j], rings[level][j], color)
	for i in 8:
		var j := (i + 1) % 8
		_triangle(st, at + Vector3(0, -half.y, 0), rings[0][i], rings[0][j], color)
		_triangle(st, at + Vector3(0, half.y, 0), rings[3][j], rings[3][i], color)

static func _pillar(st: SurfaceTool, size: Vector3, at: Vector3, color: Color, sides: int) -> void:
	for i in sides:
		var a := TAU * i / sides
		var b := TAU * (i + 1) / sides
		var p := Vector3(cos(a) * size.x * 0.5, -size.y * 0.5, sin(a) * size.z * 0.5) + at
		var q := Vector3(cos(b) * size.x * 0.5, -size.y * 0.5, sin(b) * size.z * 0.5) + at
		var up := Vector3(0, size.y, 0)
		_quad(st, p, p + up, q + up, q, color)
		_triangle(st, at - up * 0.5, p, q, color)
		_triangle(st, at + up * 0.5, q + up, p + up, color)

static func _rock(st: SurfaceTool, size: Vector3, color: Color, k: Dictionary) -> void:
	var sides := int(k["rock_sides"])
	var radii: Array = k["rock_radius_fractions"]
	var heights: Array = k["rock_height_fractions"]
	var twists: Array = k["rock_twist_degrees"]
	var rings: Array = []
	for level in radii.size():
		var ring: Array[Vector3] = []
		for i in sides:
			var angle := TAU * i / sides + deg_to_rad(float(twists[level]))
			ring.append(Vector3(cos(angle) * size.x * 0.5 * float(radii[level]), size.y * float(heights[level]), sin(angle) * size.z * 0.5 * float(radii[level])))
		rings.append(ring)
	for level in rings.size() - 1:
		for i in sides:
			var j := (i + 1) % sides
			_quad(st, rings[level][i], rings[level + 1][i], rings[level + 1][j], rings[level][j], color)
	for i in sides:
		var j := (i + 1) % sides
		_triangle(st, Vector3(0, -size.y * 0.5, 0), rings[0][i], rings[0][j], color)
		_triangle(st, Vector3(0, size.y * 0.5, 0), rings[-1][j], rings[-1][i], color)

static func build(kind: String, size: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cfg := config()
	var k: Dictionary = cfg["kit"]
	var stone := GreyboxArt.color_value(cfg["colors"]["stone"])
	var trim := GreyboxArt.color_value(cfg["colors"]["trim"])
	var dark := GreyboxArt.color_value(cfg["colors"]["dark"])
	var bevel := float(k["bevel_fraction"])
	match kind:
		"pillar":
			_pillar(st, size, Vector3.ZERO, stone, int(k["pillar_sides"]))
		"rock", "rubble":
			_rock(st, size, dark, k)
		"arch":
			var leg: Vector3 = size * vec(k["arch_leg_fraction"])
			for sign_x in [-1, 1]:
				_box(st, leg, Vector3(sign_x * (size.x - leg.x) * 0.5, 0, 0), stone, bevel)
			_box(st, size * vec(k["arch_lintel_fraction"]), Vector3(0, size.y * float(k["arch_lintel_y"]), 0), trim, bevel)
		"sandbags":
			var count := int(k["bag_columns"])
			var rows := int(k["bag_rows"])
			for row in rows:
				for col in count:
					var bag := Vector3(size.x / count, size.y / rows, size.z)
					var at := Vector3(-size.x * 0.5 + bag.x * (col + 0.5), -size.y * 0.5 + bag.y * (row + 0.5), 0)
					_box(st, bag * float(k["bag_fill"]), at, stone, float(k["bag_bevel"]))
		"wall", "low_wall":
			var cap: Vector3 = size * vec(k["cap_fraction"])
			_box(st, size * vec(k["wall_core_fraction"]), Vector3.ZERO, stone, bevel)
			_box(st, cap, Vector3(0, (size.y - cap.y) * 0.5 - (cap.y if kind == "wall" else 0.0), 0), trim, bevel)
			if kind == "wall":
				var count := int(k["crenel_count"])
				for i in count:
					var block := Vector3(size.x / count * float(k["crenel_fill"]), cap.y, size.z)
					_box(st, block, Vector3(-size.x * 0.5 + size.x / count * (i + 0.5), size.y * 0.5 - cap.y * 0.5, 0), trim, bevel)
		"barrier":
			_box(st, size * vec(k["barrier_base_fraction"]), Vector3(0, -size.y * float(k["barrier_base_y"]), 0), dark, bevel)
			_box(st, size * vec(k["barrier_top_fraction"]), Vector3(0, size.y * float(k["barrier_top_y"]), 0), stone, bevel)
		"crate":
			_box(st, size * vec(k["crate_core_fraction"]), Vector3.ZERO, dark, bevel)
			var lid: Vector3 = size * vec(k["crate_lid_fraction"])
			for sign_y in [-1, 1]:
				_box(st, lid, Vector3(0, sign_y * (size.y - lid.y) * 0.5, 0), trim, bevel)
		"camp":
			var counts := vec(k["camp_grid"])
			var cell := size / counts
			var crate := cell * float(k["camp_fill"])
			for x in int(counts.x):
				for y in int(counts.y):
					for z in int(counts.z):
						var at := -size * 0.5 + cell * Vector3(x + 0.5, y + 0.5, z + 0.5)
						_box(st, crate * vec(k["crate_core_fraction"]), at, dark, bevel)
						var lid := crate * vec(k["crate_lid_fraction"])
						for sign_y in [-1, 1]:
							_box(st, lid, at + Vector3(0, sign_y * (crate.y - lid.y) * 0.5, 0), trim, bevel)
		_:
			_box(st, size, Vector3.ZERO, stone, bevel)
	var mesh := st.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = float(k["roughness"])
	mesh.surface_set_material(0, material)
	return mesh

## World composites are one static mesh and one box collider per JSON piece.
## The manifest stores every new dimension; the existing soldier merge stays unchanged.
static func build_cover(definition: Dictionary) -> ArrayMesh:
	if definition.has("parts"):
		return merge(definition["parts"])
	return build(definition["kind"], vec(definition["size"]))

## Soldier-only variant. Keep merge() below unchanged: map geometry has no bone streams.
static func merge_skinned(parts: Array, bones: PackedInt32Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in parts.size():
		var part: Dictionary = parts[i]
		st.set_bones(PackedInt32Array([bones[i], 0, 0, 0]))
		st.set_weights(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
		var color := GreyboxArt.color_value(config()["colors"][part["color"]])
		_box(st, vec(part["size"]), vec(part["at"]), color, float(config()["kit"]["bevel_fraction"]))
	var result := st.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = float(config()["kit"]["roughness"])
	result.surface_set_material(0, material)
	return result

## Merge static articulated-looking pieces into a single vertex-colour surface.
static func merge(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part: Dictionary in parts:
		var color := GreyboxArt.color_value(config()["colors"][part["color"]])
		_box(st, vec(part["size"]), vec(part["at"]), color, float(config()["kit"]["bevel_fraction"]))
	var mesh := st.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = float(config()["kit"]["roughness"])
	mesh.surface_set_material(0, material)
	return mesh
