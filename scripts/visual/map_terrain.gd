class_name MapTerrain
extends RefCounted
## M2P1B: a map's height field (map json "terrain"), one object for the look (chunk meshes), the collider and
## piece placement. Samples sit on a square grid centred on the origin; the surface between them is the
## triangulated grid (two triangles per quad, split along SPLIT_ANTI_DIAGONAL), never bilinear, so height_at,
## the meshes and a HeightMapShape3D agree. Generation uses only +, *, floor, sqrt and integer hashing (no
## trig, no FastNoiseLite), so a phone and the desktop that bakes the navigation mesh get the same heights.

## true: each quad splits along (ix+1, iz)-(ix, iz+1), how Godot triangulates a HeightMapShape3D for
## navigation parsing and how Jolt collides with it (tests/test_terrain_physics.gd: rays land within 0.00001 m,
## the other split is about 3 mm off on the hill); false: along (ix, iz)-(ix+1, iz+1).
const SPLIT_ANTI_DIAGONAL := true
## Hill falloff names (u = distance / radius, 1 at the centre to 0 at u >= 1).
const FALLOFFS := ["linear", "smoothstep", "smootherstep"]

static var _cache := {}  # content key -> MapTerrain

var size_m := 0.0
var resolution_m := 1.0
var samples := 0  # per side
var heights := PackedFloat32Array()  # row-major, index = iz * samples + ix
var max_piece_slope_deg := 0.0
## How far a piece's footprint corner may lie above or below the ground at its origin (map json "terrain"
## "max_piece_float_m"; no limit when absent).
var max_piece_float_m := INF
var _positions := PackedVector3Array()  # per sample, built on the first mesh request
var _normals := PackedVector3Array()  # per sample, from the whole grid so chunk edges share them
var _meshes := {}  # chunk key -> ArrayMesh
static var _indices := {}  # Vector3i(nx, nz, diagonal) -> PackedInt32Array


## The terrain of a map definition, or null when it has no valid "terrain" block. Cached on the block's
## content (a file source also on the file's modified time).
static func for_map(map_def: Dictionary) -> MapTerrain:
	var block: Variant = map_def.get("terrain")
	if typeof(block) != TYPE_DICTIONARY:
		return null
	var key := JSON.stringify(block) + "|" + str(map_def.get("ground_size_m", ""))
	var source: Variant = (block as Dictionary).get("height_source")
	if typeof(source) == TYPE_DICTIONARY and str(source.get("type", "")) == "file":
		key += "|" + str(FileAccess.get_modified_time(str(source.get("path", ""))))
	if not _cache.has(key):
		_cache[key] = from_block(block, map_def)
	return _cache[key]


## Uncached build from a "terrain" block; null when DataRegistry.validate_terrain reports a problem or the
## heights file does not fit the block.
static func from_block(block: Variant, map_def: Dictionary = {}) -> MapTerrain:
	if not DataRegistry.validate_terrain(block, map_def).is_empty():
		return null
	var t := MapTerrain.new()
	t.size_m = float(block["size_m"])
	t.resolution_m = float(block["resolution_m"])
	t.samples = roundi(t.size_m / t.resolution_m) + 1
	t.max_piece_slope_deg = float(block.get("max_piece_slope_deg", 90.0))
	t.max_piece_float_m = float(block.get("max_piece_float_m", INF))
	var source: Dictionary = block["height_source"]
	if String(source["type"]) == "file":
		t.heights = _load_heights(String(source["path"]), t)
		if t.heights.size() != t.samples * t.samples:
			return null
	else:
		t._generate(source)
	return t


func _generate(source: Dictionary) -> void:
	var half := size_m * 0.5
	var noise: Dictionary = source.get("noise", {})
	var amp := float(noise.get("amplitude_m", 0.0))
	var inv_wave := 1.0 / float(noise.get("wavelength_m", 1.0))
	var flat: Dictionary = source.get("flat_centre", {})
	var flat_r := float(flat.get("radius_m", 0.0))
	var flat_blend := float(flat.get("blend_m", 0.0))
	var edge_blend := float(source.get("edge_blend_m", 0.0))
	var salt := int(source["seed"]) & 0x7FFFFFFF
	heights.resize(samples * samples)
	for iz in samples:
		var z := -half + iz * resolution_m
		for ix in samples:
			var x := -half + ix * resolution_m
			var h := 0.0
			if amp > 0.0:
				var mask := _ramp(sqrt(x * x + z * z) - flat_r, flat_blend)
				if mask > 0.0:
					h = amp * mask * _value_noise(x * inv_wave, z * inv_wave, salt)
			heights[iz * samples + ix] = h
	for hill: Dictionary in source.get("hills", []):
		_add_hill(hill)
	for iz in samples:
		var z := -half + iz * resolution_m
		for ix in samples:
			var x := -half + ix * resolution_m
			var h := heights[iz * samples + ix] * _ramp(half - maxf(absf(x), absf(z)), edge_blend)
			heights[iz * samples + ix] = 0.0 if h == 0.0 else h  # no -0.0, so saved files compare bit-equal


## 0 at d <= 0, smoothstep to 1 over `blend` (blend 0: a step just past 0).
static func _ramp(d: float, blend: float) -> float:
	if d <= 0.0:
		return 0.0
	if blend <= 0.0 or d >= blend:
		return 1.0
	var t := d / blend
	return t * t * (3.0 - 2.0 * t)


## Smooth value noise in [-1, 1]: integer-hashed lattice values, quintic fade.
static func _value_noise(u: float, v: float, salt: int) -> float:
	var i := floori(u)
	var j := floori(v)
	var fu := u - i
	var fv := v - j
	fu = fu * fu * fu * (fu * (fu * 6.0 - 15.0) + 10.0)
	fv = fv * fv * fv * (fv * (fv * 6.0 - 15.0) + 10.0)
	var a := _lattice(i, j, salt)
	var b := _lattice(i + 1, j, salt)
	var c := _lattice(i, j + 1, salt)
	var d := _lattice(i + 1, j + 1, salt)
	var top := a + (b - a) * fu
	return top + (c + (d - c) * fu - top) * fv


## Every product stays below 2^63, so the hash is the same on every platform.
static func _lattice(i: int, j: int, salt: int) -> float:
	var h := (i * 374761393 + j * 668265263 + salt * 1442695041) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFFFF) / 16777215.0 * 2.0 - 1.0


## Adds height_m * falloff(d / radius); radius is radius_m on the half facing the origin and blends to
## outer_radius_m pointing straight away from it.
func _add_hill(hill: Dictionary) -> void:
	var half := size_m * 0.5
	var cx := float(hill["centre"][0])
	var cz := float(hill["centre"][1])
	var height := float(hill["height_m"])
	var r := float(hill["radius_m"])
	var outer := float(hill.get("outer_radius_m", r))
	var falloff := String(hill.get("falloff", "smoothstep"))
	var reach := maxf(r, outer)
	var c_len := sqrt(cx * cx + cz * cz)
	var ox := -cx / c_len if c_len > 0.0 else 0.0  # unit vector from the hill to the origin
	var oz := -cz / c_len if c_len > 0.0 else 0.0
	var ix0 := clampi(floori((cx - reach + half) / resolution_m), 0, samples - 1)
	var ix1 := clampi(ceili((cx + reach + half) / resolution_m), 0, samples - 1)
	var iz0 := clampi(floori((cz - reach + half) / resolution_m), 0, samples - 1)
	var iz1 := clampi(ceili((cz + reach + half) / resolution_m), 0, samples - 1)
	for iz in range(iz0, iz1 + 1):
		var dz := -half + iz * resolution_m - cz
		for ix in range(ix0, ix1 + 1):
			var dx := -half + ix * resolution_m - cx
			var d := sqrt(dx * dx + dz * dz)
			if d >= reach:
				continue
			var radius := r
			if d > 0.0:
				var away := clampf(-(dx * ox + dz * oz) / d, 0.0, 1.0)
				radius = r + (outer - r) * away * away * (3.0 - 2.0 * away)
			var u := d / radius
			if u < 1.0:
				heights[iz * samples + ix] += height * _falloff(falloff, u)


static func _falloff(kind: String, u: float) -> float:
	match kind:
		"linear":
			return 1.0 - u
		"smootherstep":
			return 1.0 - u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
	return 1.0 - u * u * (3.0 - 2.0 * u)


func sample(ix: int, iz: int) -> float:
	return heights[clampi(iz, 0, samples - 1) * samples + clampi(ix, 0, samples - 1)]


## The quad under (x, z) clamped to the ground: [ix, iz, fx, fz] with fx, fz in [0, 1].
func _cell(x: float, z: float) -> Array:
	var half := size_m * 0.5
	var u := (clampf(x, -half, half) + half) / resolution_m
	var v := (clampf(z, -half, half) + half) / resolution_m
	var ix := clampi(floori(u), 0, samples - 2)
	var iz := clampi(floori(v), 0, samples - 2)
	return [ix, iz, u - ix, v - iz]


## The triangle under (x, z) as its plane: [height, dh/dx, dh/dz].
func _plane(x: float, z: float) -> Vector3:
	var c := _cell(x, z)
	var ix: int = c[0]
	var iz: int = c[1]
	var fx: float = c[2]
	var fz: float = c[3]
	var ha := sample(ix, iz)
	var hb := sample(ix + 1, iz)
	var hc := sample(ix, iz + 1)
	var hd := sample(ix + 1, iz + 1)
	var gx: float
	var gz: float
	var h: float
	if SPLIT_ANTI_DIAGONAL:
		if fx + fz <= 1.0:  # triangle a, b, c
			gx = hb - ha
			gz = hc - ha
			h = ha + gx * fx + gz * fz
		else:  # triangle b, d, c
			gx = hd - hc
			gz = hd - hb
			h = hd - gx * (1.0 - fx) - gz * (1.0 - fz)
	else:
		if fx >= fz:  # triangle a, b, d
			gx = hb - ha
			gz = hd - hb
		else:  # triangle a, d, c
			gx = hd - hc
			gz = hc - ha
		h = ha + gx * fx + gz * fz
	return Vector3(h, gx / resolution_m, gz / resolution_m)


## Height of the triangulated surface, clamped to the ground square.
func height_at(x: float, z: float) -> float:
	return _plane(x, z).x


## Up-facing normal of the triangle under the point (the exact surface, not smoothed).
func normal_at(x: float, z: float) -> Vector3:
	var p := _plane(x, z)
	return Vector3(-p.y, 1.0, -p.z).normalized()


func slope_deg_at(x: float, z: float) -> float:
	var p := _plane(x, z)
	return rad_to_deg(atan(sqrt(p.y * p.y + p.z * p.z)))


## Positions and smooth vertex normals (central differences of the whole grid) of every sample.
func _build_vertices() -> void:
	var half := size_m * 0.5
	var n := samples
	_positions.resize(n * n)
	_normals.resize(n * n)
	for iz in n:
		var z0 := maxi(iz - 1, 0)
		var z1 := mini(iz + 1, n - 1)
		for ix in n:
			var x0 := maxi(ix - 1, 0)
			var x1 := mini(ix + 1, n - 1)
			var i := iz * n + ix
			var gx := (heights[iz * n + x1] - heights[iz * n + x0]) / ((x1 - x0) * resolution_m)
			var gz := (heights[z1 * n + ix] - heights[z0 * n + ix]) / ((z1 - z0) * resolution_m)
			_positions[i] = Vector3(-half + ix * resolution_m, heights[i], -half + iz * resolution_m)
			_normals[i] = Vector3(-gx, 1.0, -gz).normalized()


## First and last quad (inclusive) along one axis whose centre lies in chunk `cell` (MapChunks.index_for).
func _quad_range(cell: int, chunk_size_m: float, per_side: int) -> Vector2i:
	var half := size_m * 0.5
	var first := -1
	var last := -2
	for q in samples - 1:
		var centre := -half + (q + 0.5) * resolution_m
		if MapChunks.index_for(centre, -half, half, chunk_size_m, per_side).x == cell:
			if first < 0:
				first = q
			last = q
	return Vector2i(first, last)


## The terrain surface of one chunk-grid cell: every grid quad whose centre lies in the cell, so cells tile
## the ground with no gap or overlap. Indexed triangles; the winding makes the top the front face (Godot's
## front faces are clockwise seen from the front). Cached per cell and grid.
func chunk_mesh(index: Vector2i, chunk_size_m: float, per_side: int) -> ArrayMesh:
	var key := "%d_%d_%s_%d" % [index.x, index.y, str(chunk_size_m), per_side]
	if _meshes.has(key):
		return _meshes[key]
	if _positions.is_empty():
		_build_vertices()
	var mesh := ArrayMesh.new()
	_meshes[key] = mesh
	var rx := _quad_range(index.x, chunk_size_m, per_side)
	var rz := _quad_range(index.y, chunk_size_m, per_side)
	if rx.y < rx.x or rz.y < rz.x:
		return mesh
	var nx := rx.y - rx.x + 2
	var nz := rz.y - rz.x + 2
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	positions.resize(nx * nz)
	normals.resize(nx * nz)
	for j in nz:
		var row := (rz.x + j) * samples + rx.x
		for i in nx:
			positions[j * nx + i] = _positions[row + i]
			normals[j * nx + i] = _normals[row + i]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = _grid_indices(nx, nz)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## M2P1C stop 5: why `step_m` cannot be a far-mesh step on this grid ("" = it can): it must be a whole multiple
## of `res_m` and divide `chunk_m` evenly into at least two steps.
static func far_step_problem(step_m: float, res_m: float, chunk_m: float) -> String:
	if step_m <= 0.0 or res_m <= 0.0 or chunk_m <= 0.0:
		return "far step, resolution and chunk size must be > 0"
	var k := step_m / res_m
	if absf(k - roundf(k)) > 1e-4 or roundi(k) < 2:
		return "far step %.3f m is not a multiple (>= 2) of the height-field resolution %.3f m" % [step_m, res_m]
	var n := chunk_m / step_m
	if absf(n - roundf(n)) > 1e-4 or roundi(n) < 2:
		return "far step %.3f m does not divide the chunk size %.3f m into at least two steps" % [step_m, chunk_m]
	return ""


## M2P1C stop 5: the FAR look of one chunk cell (same cell as chunk_mesh): the true heights on a coarser grid,
## every `step_m` / resolution_m samples, while the cell's BORDER keeps every full-resolution sample, so a far
## chunk's edge is the near chunk's edge vertex for vertex (no crack against a near or a far neighbour, no
## skirt). Inner coarse cells split like _plane; each coarse cell on the border is a fan from its inner corner.
## Null when the step is unusable (far_step_problem) or the cell's quads do not divide by it (a partial edge
## cell). Cached per cell, grid and step.
func far_chunk_mesh(index: Vector2i, chunk_size_m: float, per_side: int, step_m: float) -> ArrayMesh:
	var key := "far_%d_%d_%s_%d_%s" % [index.x, index.y, str(chunk_size_m), per_side, str(step_m)]
	if _meshes.has(key):
		return _meshes[key]
	_meshes[key] = null
	if far_step_problem(step_m, resolution_m, chunk_size_m) != "":
		return null
	if _positions.is_empty():
		_build_vertices()
	var k := roundi(step_m / resolution_m)
	var rx := _quad_range(index.x, chunk_size_m, per_side)
	var rz := _quad_range(index.y, chunk_size_m, per_side)
	var qx := rx.y - rx.x + 1
	var qz := rz.y - rz.x + 1
	if qx <= 0 or qz <= 0 or qx % k != 0 or qz % k != 0 or qx / k < 2 or qz / k < 2:
		return null
	var cx := qx / k
	var cz := qz / k
	# Arrays, not packed arrays: lambdas capture locals by value, and packed arrays are values.
	var positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var lookup := {}  # Vector2i(local sample) -> vertex index
	var vertex := func(i: int, j: int) -> int:
		var at := Vector2i(i, j)
		if not lookup.has(at):
			var s := (rz.x + j) * samples + rx.x + i
			lookup[at] = positions.size()
			positions.append(_positions[s])
			normals.append(_normals[s])
		return lookup[at]
	var indices: Array[int] = []
	# Front faces up: the same turn as _grid_indices' first triangle (i, j), (i+1, j), (i, j+1), which is > 0.
	var tri := func(a: Vector2i, b: Vector2i, c: Vector2i) -> void:
		var turn := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		if turn == 0:
			return
		var ia: int = vertex.call(a.x, a.y)
		var ib: int = vertex.call(b.x, b.y)
		var ic: int = vertex.call(c.x, c.y)
		if turn > 0:
			indices.append_array([ia, ib, ic])
		else:
			indices.append_array([ia, ic, ib])
	for cj in cz:
		for ci in cx:
			var x0 := ci * k
			var z0 := cj * k
			var x1 := x0 + k
			var z1 := z0 + k
			var low_z := cj == 0
			var high_x := ci == cx - 1
			var high_z := cj == cz - 1
			var low_x := ci == 0
			if not (low_z or high_x or high_z or low_x):
				var a := Vector2i(x0, z0)
				var b := Vector2i(x1, z0)
				var c := Vector2i(x0, z1)
				var d := Vector2i(x1, z1)
				if SPLIT_ANTI_DIAGONAL:
					tri.call(a, b, c)
					tri.call(b, d, c)
				else:
					tri.call(a, b, d)
					tri.call(a, d, c)
				continue
			# The cell's outline, corner to corner around it, with every sample on a border side.
			var ring: Array[Vector2i] = []
			for s in k:
				ring.append(Vector2i(x0 + s, z0) if low_z or s == 0 else Vector2i(x0, z0))
			for s in k:
				ring.append(Vector2i(x1, z0 + s) if high_x or s == 0 else Vector2i(x1, z0))
			for s in k:
				ring.append(Vector2i(x1 - s, z1) if high_z or s == 0 else Vector2i(x1, z1))
			for s in k:
				ring.append(Vector2i(x0, z1 - s) if low_x or s == 0 else Vector2i(x0, z1))
			var outline: Array[Vector2i] = []
			for p in ring:
				if outline.is_empty() or outline[outline.size() - 1] != p:
					outline.append(p)
			if outline.size() > 1 and outline[0] == outline[outline.size() - 1]:
				outline.pop_back()
			# Apex: a corner whose two sides are both inner sides (exists because the cell grid is >= 2 x 2).
			var corners := [[Vector2i(x0, z0), low_x or low_z], [Vector2i(x1, z0), low_z or high_x], [Vector2i(x1, z1), high_x or high_z], [Vector2i(x0, z1), high_z or low_x]]
			var apex := Vector2i(-1, -1)
			for c: Array in corners:
				if not bool(c[1]):
					apex = c[0]
					break
			var start := outline.find(apex)
			var n := outline.size()
			for s in range(1, n - 1):
				tri.call(apex, outline[(start + s) % n], outline[(start + s + 1) % n])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(positions)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(normals)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_meshes[key] = mesh
	return mesh


## Two triangles per quad of an nx x nz vertex grid, split like _plane; shared by chunks of one shape.
static func _grid_indices(nx: int, nz: int) -> PackedInt32Array:
	var key := Vector3i(nx, nz, 1 if SPLIT_ANTI_DIAGONAL else 0)
	if _indices.has(key):
		return _indices[key]
	var out := PackedInt32Array()
	out.resize((nx - 1) * (nz - 1) * 6)
	var k := 0
	for j in nz - 1:
		for i in nx - 1:
			var a := j * nx + i
			var b := a + 1
			var c := a + nx
			var d := c + 1
			var tri: Array = [a, b, c, b, d, c] if SPLIT_ANTI_DIAGONAL else [a, b, d, a, d, c]
			for v: int in tri:
				out[k] = v
				k += 1
	_indices[key] = out
	return out


## Writes the heights as JSON ({"size_m", "resolution_m", "heights"}) or, for ".res", as a binary
## HeightMapShape3D (map_width = map_depth = samples, map_data = heights) with size_m and resolution_m as
## metadata. Either is a "file" height_source.
static func save_heights(terrain: MapTerrain, path: String) -> Error:
	if path.ends_with(".json"):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return FileAccess.get_open_error()
		f.store_string(JSON.stringify({"size_m": terrain.size_m, "resolution_m": terrain.resolution_m, "heights": Array(terrain.heights)}, "", true, true))
		f.close()
		return OK
	if path.ends_with(".res"):
		var shape := HeightMapShape3D.new()
		shape.map_width = terrain.samples
		shape.map_depth = terrain.samples
		shape.map_data = terrain.heights
		shape.set_meta(&"size_m", terrain.size_m)
		shape.set_meta(&"resolution_m", terrain.resolution_m)
		return ResourceSaver.save(shape, path)
	return ERR_FILE_UNRECOGNIZED


## The heights in a saved file, or empty when it is unreadable or its grid differs from `t`'s.
static func _load_heights(path: String, t: MapTerrain) -> PackedFloat32Array:
	var size: Variant
	var res: Variant
	var data := PackedFloat32Array()
	if path.ends_with(".json"):
		var def := DataRegistry.parse_quiet(path)
		size = def.get("size_m")
		res = def.get("resolution_m")
		if typeof(def.get("heights")) == TYPE_ARRAY:
			data = PackedFloat32Array(def["heights"])
	else:
		var shape := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as HeightMapShape3D
		if shape == null:
			return data
		size = shape.get_meta(&"size_m", 0.0)
		res = shape.get_meta(&"resolution_m", 0.0)
		data = shape.map_data
	for value: Variant in [size, res]:
		if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
			return PackedFloat32Array()
	if not is_equal_approx(float(size), t.size_m) or not is_equal_approx(float(res), t.resolution_m):
		return PackedFloat32Array()
	return data
