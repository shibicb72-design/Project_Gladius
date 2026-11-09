class_name LowpolyShapes
extends RefCounted
## C1 kit primitives beyond the chamfered box, chosen by a part's "shape" key: taper (tapered box), wedge,
## plate (curved plate: an arc of a prism) and lathe (a profile turned around the Y axis). Deterministic, flat
## shaded and vertex coloured like the box. Every shape fills its part's `size` box centred on `at`; an optional
## "rot" [x, y, z] in degrees then turns it around `at`. Defaults: data/art_astra.json kit.shapes (OQ-3D-KIT).
## Front is -Z: a plate bulges forward and an arc is centred on the front.

const SHAPES: Array[String] = ["taper", "wedge", "plate", "lathe"]
const _EPSILON := 0.0000001  # numerical guard for zero-area triangles, not a tunable


static func is_custom(part: Dictionary) -> bool:
	return SHAPES.has(String(part.get("shape", "box")))


static func transform_of(part: Dictionary) -> Transform3D:
	var basis := Basis.IDENTITY
	if part.has("rot"):
		var r := LowpolyKit.vec(part["rot"])
		basis = Basis.from_euler(Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z)))
	return Transform3D(basis, LowpolyKit.vec(part["at"]))


## Mesh-space bounds of any part. A box, or a shape that fills its size box unturned, is that box; a turned or
## axis-centred shape is measured from its own corners (exact, so an arc claims only the space it covers).
static func bounds_of(part: Dictionary, defaults: Dictionary) -> AABB:
	var size := LowpolyKit.vec(part["size"])
	if not is_custom(part) or not (part.has("rot") or bool(part.get("axis", false))):
		return AABB(LowpolyKit.vec(part["at"]) - size * 0.5, size)
	var points := triangles(part, defaults)
	var xf := transform_of(part)
	var box := AABB(xf * points[0], Vector3.ZERO)
	for p in points:
		box = box.expand(xf * p)
	return box


## Adds the part to the surface with the kit's own triangle writer (same normals and colour stream as the box).
static func add(st: SurfaceTool, part: Dictionary, color: Color, defaults: Dictionary) -> void:
	var points := triangles(part, defaults)
	var xf := transform_of(part)
	for i in range(0, points.size(), 3):
		LowpolyKit._triangle(st, xf * points[i], xf * points[i + 1], xf * points[i + 2], color)


## Triangle corners (three per triangle) in the part's own space: centred on the origin, before "rot" and "at".
## Each triangle (a, b, c) faces outward along (b - a) x (c - a), the order LowpolyKit._triangle expects.
static func triangles(part: Dictionary, defaults: Dictionary) -> PackedVector3Array:
	var size := LowpolyKit.vec(part["size"])
	match String(part.get("shape", "box")):
		"taper":
			return _taper(size, part, defaults)
		"wedge":
			return _wedge(size, float(part.get("ridge", defaults["wedge_ridge"])))
		"plate":
			var inner := 1.0 - clampf(float(part.get("thickness", defaults["plate_thickness"])), 0.01, 0.99)
			return _lathe(size, [[inner, 0.0], [1.0, 0.0], [1.0, 1.0], [inner, 1.0]], int(part.get("segments", defaults["plate_segments"])),
					float(part.get("arc_deg", defaults["plate_arc_deg"])), bool(part.get("axis", false)))
		"lathe":
			return _lathe(size, part.get("profile", defaults["lathe_profile"]), int(part.get("segments", defaults["lathe_segments"])),
					float(part.get("sweep_deg", defaults["lathe_sweep_deg"])), bool(part.get("axis", false)))
	return PackedVector3Array()


## Appends (a, b, c) turned to face away from `inside`; drops zero-area triangles. For convex shapes.
static func _push_convex(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < _EPSILON * _EPSILON:
		return
	if normal.dot((a + b + c) / 3.0 - inside) < 0.0:
		out.append_array([a, c, b])
	else:
		out.append_array([a, b, c])


## Appends (a, b, c) turned to face along `facing`; drops zero-area triangles.
static func _push_facing(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, facing: Vector3) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < _EPSILON * _EPSILON:
		return
	if normal.dot(facing) < 0.0:
		out.append_array([a, c, b])
	else:
		out.append_array([a, b, c])


## Rectangle outline (4 corners, or 8 with chamfered corners) around `center` at height y.
static func _outline(half: Vector2, center: Vector2, y: float, bevel: float) -> Array[Vector3]:
	var cut := minf(half.x, half.y) * 2.0 * clampf(bevel, 0.0, 0.49)
	var flat: Array[Vector2] = [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]
	if cut > 0.0:
		flat = [
			Vector2(-half.x + cut, -half.y), Vector2(half.x - cut, -half.y), Vector2(half.x, -half.y + cut), Vector2(half.x, half.y - cut),
			Vector2(half.x - cut, half.y), Vector2(-half.x + cut, half.y), Vector2(-half.x, half.y - cut), Vector2(-half.x, -half.y + cut)]
	var ring: Array[Vector3] = []
	for p in flat:
		ring.append(Vector3(center.x + p.x, y, center.y + p.y))
	return ring


## Box whose top and bottom faces are scaled ("top", "bottom": [x, z] fractions of the size, at most 1) and whose
## top may slide ("top_shift": [x, z] fractions, clamped so the shape stays inside its size box).
static func _taper(size: Vector3, part: Dictionary, defaults: Dictionary) -> PackedVector3Array:
	var half := size * 0.5
	var top: Array = part.get("top", defaults["taper_top"])
	var bottom: Array = part.get("bottom", [1.0, 1.0])
	var shift: Array = part.get("top_shift", [0.0, 0.0])
	var bevel := float(part.get("bevel", defaults["taper_bevel"]))
	var top_scale := Vector2(clampf(float(top[0]), 0.0, 1.0), clampf(float(top[1]), 0.0, 1.0))
	var bottom_scale := Vector2(clampf(float(bottom[0]), 0.0, 1.0), clampf(float(bottom[1]), 0.0, 1.0))
	var room := (Vector2.ONE - top_scale) * 0.5
	var top_center := Vector2(clampf(float(shift[0]), -room.x, room.x) * size.x, clampf(float(shift[1]), -room.y, room.y) * size.z)
	var low := _outline(Vector2(half.x, half.z) * bottom_scale, Vector2.ZERO, -half.y, bevel)
	var high := _outline(Vector2(half.x, half.z) * top_scale, top_center, half.y, bevel)
	var low_center := Vector3(0.0, -half.y, 0.0)
	var high_center := Vector3(top_center.x, half.y, top_center.y)
	var inside := (low_center + high_center) * 0.5
	var out := PackedVector3Array()
	for i in low.size():
		var j := (i + 1) % low.size()
		_push_convex(out, low[i], high[i], high[j], inside)
		_push_convex(out, low[i], high[j], low[j], inside)
		_push_convex(out, low_center, low[i], low[j], inside)
		_push_convex(out, high_center, high[j], high[i], inside)
	return out


## Triangular prism along X: a full base and a top edge at `ridge` (0 = front edge, 1 = back edge, 0.5 = roof).
static func _wedge(size: Vector3, ridge: float) -> PackedVector3Array:
	var half := size * 0.5
	var z := lerpf(-half.z, half.z, clampf(ridge, 0.0, 1.0))
	var base: Array[Vector3] = [Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z), Vector3(half.x, -half.y, half.z), Vector3(-half.x, -half.y, half.z)]
	var left := Vector3(-half.x, half.y, z)
	var right := Vector3(half.x, half.y, z)
	var inside := Vector3(0.0, -half.y * 0.5, z * 0.25)
	var out := PackedVector3Array()
	_push_convex(out, base[0], base[1], base[2], inside)
	_push_convex(out, base[0], base[2], base[3], inside)
	_push_convex(out, base[0], base[1], right, inside)  # front slope
	_push_convex(out, base[0], right, left, inside)
	_push_convex(out, base[2], base[3], left, inside)  # back slope
	_push_convex(out, base[2], left, right, inside)
	_push_convex(out, base[3], base[0], left, inside)  # ends
	_push_convex(out, base[1], base[2], right, inside)
	return out


## Closed profile polygon of [radius, height] fractions turned around Y over `sweep_deg`, centred on the front.
## Edges on the axis add nothing; a sweep under 360 closes both ends with the profile itself. By default the
## result is rescaled to fill the size box exactly (the fractions are then relative to each other). With
## `on_axis` ("axis": true on the part) nothing is rescaled: `at` is the turning axis at mid height and `size`
## the box of the full turn, so several arcs can share one centre and "rot" turns them around it.
static func _lathe(size: Vector3, profile: Array, segments: int, sweep_deg: float, on_axis: bool) -> PackedVector3Array:
	var polygon := PackedVector2Array()
	for p: Array in profile:
		polygon.append(Vector2(maxf(float(p[0]), 0.0), float(p[1])))
	var area := 0.0
	for i in polygon.size():
		var q := polygon[(i + 1) % polygon.size()]
		area += polygon[i].x * q.y - q.x * polygon[i].y
	if area < 0.0:
		polygon.reverse()  # counter-clockwise: the right side of every edge is outside
	var sweep := deg_to_rad(clampf(sweep_deg, 1.0, 360.0))
	var full := sweep_deg >= 360.0
	var steps := maxi(segments, 3 if full else 1)
	var raw := PackedVector3Array()
	for s in steps:
		var a0 := -sweep * 0.5 + sweep * s / steps
		var a1 := -sweep * 0.5 + sweep * (s + 1) / steps
		for i in polygon.size():
			var p := polygon[i]
			var q := polygon[(i + 1) % polygon.size()]
			if p.x <= 0.0 and q.x <= 0.0:
				continue
			var a := _turn(p, a0)
			var b := _turn(q, a0)
			var c := _turn(q, a1)
			var d := _turn(p, a1)
			if q.x <= 0.0:
				_push_raw(raw, a, b, d)
			else:
				_push_raw(raw, a, b, c)
				if p.x > 0.0:
					_push_raw(raw, a, c, d)
	if not full:
		var cap := Geometry2D.triangulate_polygon(polygon)
		for side: float in [-1.0, 1.0]:
			var angle := sweep * 0.5 * side
			var facing := Vector3(cos(angle), 0.0, sin(angle)) * side
			for i in range(0, cap.size(), 3):
				_push_facing(raw, _turn(polygon[cap[i]], angle), _turn(polygon[cap[i + 1]], angle), _turn(polygon[cap[i + 2]], angle), facing)
	if not on_axis:
		return _fill(raw, size)
	for i in raw.size():
		raw[i] = Vector3(raw[i].x * size.x * 0.5, (raw[i].y - 0.5) * size.y, raw[i].z * size.z * 0.5)
	return raw


static func _turn(p: Vector2, angle: float) -> Vector3:
	return Vector3(p.x * sin(angle), p.y, -p.x * cos(angle))


static func _push_raw(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).length_squared() >= _EPSILON * _EPSILON:
		out.append_array([a, b, c])


## Rescales the points so their bounds are exactly the size box centred on the origin.
static func _fill(points: PackedVector3Array, size: Vector3) -> PackedVector3Array:
	if points.is_empty():
		return points
	var low := points[0]
	var high := points[0]
	for p in points:
		low = low.min(p)
		high = high.max(p)
	var span := high - low
	var middle := (low + high) * 0.5
	var scale := Vector3(
			size.x / span.x if span.x > _EPSILON else 1.0,
			size.y / span.y if span.y > _EPSILON else 1.0,
			size.z / span.z if span.z > _EPSILON else 1.0)
	var out := PackedVector3Array()
	out.resize(points.size())
	for i in points.size():
		out[i] = (points[i] - middle) * scale
	return out
