class_name WorldRing
extends RefCounted
## W3 helpers shared by the ring tests and tools/ring_report.gd (fixture code, like SpawnLane): the ground
## footprint of what stands on the map, and how far a route runs with nothing to hide behind near it.
## Decides nothing in a match.


## Corners (box) or hull points (convex shape) of a collision shape, in the shape's own space.
static func shape_points(shape: Shape3D) -> PackedVector3Array:
	if shape is ConvexPolygonShape3D:
		return (shape as ConvexPolygonShape3D).points
	var out := PackedVector3Array()
	if shape is BoxShape3D:
		var half := (shape as BoxShape3D).size * 0.5
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					out.append(Vector3(half.x * sx, half.y * sy, half.z * sz))
	return out


## {rect: Rect2 on the ground (x, z), top: highest point in metres} of a body that sits directly under Nav
## (Nav is at the origin, so the body's own transform is its place in the world).
static func footprint(body: Node3D) -> Dictionary:
	var rect := Rect2()
	var top := -INF
	var first := true
	for node in body.find_children("*", "CollisionShape3D", true, false):
		var shape := node as CollisionShape3D
		var xf := body.transform * shape.transform
		for p in shape_points(shape.shape):
			var q := xf * p
			var flat := Vector2(q.x, q.z)
			rect = Rect2(flat, Vector2.ZERO) if first else rect.expand(flat)
			first = false
			top = maxf(top, q.y)
	return {"rect": rect, "top": top}


## Every body under the map's Nav node except the ground: [{name, body, rect, top}].
static func solids(map: Node3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for body in map.get_node("Nav").get_children():
		if body.name == &"Ground" or not body is StaticBody3D:
			continue
		var entry := footprint(body)
		entry["name"] = String(body.name)
		entry["body"] = body
		out.append(entry)
	return out


## Footprints of everything at least `min_top` metres tall: what a soldier can break line of sight behind.
static func cover_rects(map: Node3D, min_top: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for solid in solids(map):
		if float(solid["top"]) + 0.00001 >= min_top:
			out.append(solid["rect"])
	return out


## Distance on the ground from a point to a rectangle (0 inside it).
static func rect_distance(p: Vector2, rect: Rect2) -> float:
	return Vector2(maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0), maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)).length()


## Gap on the ground between two rectangles (0 when they touch or overlap).
static func rect_gap(a: Rect2, b: Rect2) -> float:
	return Vector2(maxf(maxf(a.position.x - b.end.x, b.position.x - a.end.x), 0.0), maxf(maxf(a.position.y - b.end.y, b.position.y - a.end.y), 0.0)).length()


## Distance on the ground from a rectangle to the segment a-b (0 when the segment crosses it). Sampled every
## 0.25 m along the segment: enough for clearances of a metre or more.
static func rect_segment_distance(rect: Rect2, a: Vector2, b: Vector2) -> float:
	var steps := maxi(int(ceil(a.distance_to(b) / 0.25)), 1)
	var best := INF
	for i in steps + 1:
		best = minf(best, rect_distance(a.lerp(b, float(i) / steps), rect))
	return best


## Nearest and farthest distance from the map centre to any point of a rectangle.
static func radial_range(rect: Rect2) -> Vector2:
	var far := 0.0
	for corner in [rect.position, rect.end, Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
		far = maxf(far, (corner as Vector2).length())
	return Vector2(rect_distance(Vector2.ZERO, rect), far)


## Points every `step` metres along a path, on the ground plane.
static func resample(path: PackedVector3Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if path.is_empty():
		return out
	var carry := 0.0
	out.append(Vector2(path[0].x, path[0].z))
	for i in range(1, path.size()):
		var a := Vector2(path[i - 1].x, path[i - 1].z)
		var b := Vector2(path[i].x, path[i].z)
		var length := a.distance_to(b)
		var at := step - carry
		while at <= length:
			out.append(a.lerp(b, at / length))
			at += step
		carry = fmod(carry + length, step)
	return out


## Runs of consecutive route points with no rectangle within `reach` metres: [{from, to, length}], length in
## metres (points are `step` apart).
static func open_stretches(points: PackedVector2Array, rects: Array[Rect2], reach: float, step: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var run_start := -1
	for i in points.size() + 1:
		var open := false
		if i < points.size():
			open = true
			for rect in rects:
				if rect_distance(points[i], rect) <= reach:
					open = false
					break
		if open and run_start < 0:
			run_start = i
		elif not open and run_start >= 0:
			out.append({"from": points[run_start], "to": points[i - 1], "length": (i - run_start) * step})
			run_start = -1
	return out


static func longest(stretches: Array[Dictionary]) -> float:
	var best := 0.0
	for stretch in stretches:
		best = maxf(best, float(stretch["length"]))
	return best
