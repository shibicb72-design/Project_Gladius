class_name ViewMesh
extends RefCounted
## M2 AN1: flat-shaded, faceted geometry for the first-person view model (hands and weapons), built in code from the
## part lists of data/art_soldier.json (OQ-ART-SOLDIER: placeholder looks). Presentation only.
## Two primitives, both with flat face normals:
##   slab:  a 2D profile polygon extruded along one axis, with a chamfer on both faces (the profile's edges bevelled).
##   lathe: a [radius, height] profile turned around one axis with a few sides (octagonal scope tube, finger segments).
## "box" is a slab with a rectangular profile. Every part has "at" and an optional "rot" (degrees, XYZ euler).
## Material classes (gunmetal, bronze, leather, cloth, glass, energy, ...) come from art_soldier.json materials; the
## class's metallic / roughness / emission ride in the vertex stream (UV2 = metallic, roughness; UV.x = emission), so
## every opaque class shares one shader and one surface: a mesh costs one draw call per pass (opaque, glass, glow).

const ART_PATH := "res://data/art_soldier.json"
const PASSES: Array[String] = ["opaque", "glass", "glow"]
const _EPS := 0.0000001  # zero-area guard, not a tunable

const _OPAQUE_SHADER := """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;
void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = UV2.x;
	ROUGHNESS = UV2.y;
	EMISSION = COLOR.rgb * UV.x;
}
"""
const _GLASS_SHADER := """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
	METALLIC = 0.0;
	ROUGHNESS = UV2.y;
	SPECULAR = 0.9;
}
"""
const _GLOW_SHADER := """shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;
void fragment() {
	ALBEDO = COLOR.rgb * COLOR.a;
}
"""

static var _registry := DataRegistry.new()
static var _materials := {}


static func config() -> Dictionary:
	return _registry.load_file(ART_PATH)


static func material(pass_name: String) -> ShaderMaterial:
	if not _materials.has(pass_name):
		var shader := Shader.new()
		shader.code = {"opaque": _OPAQUE_SHADER, "glass": _GLASS_SHADER, "glow": _GLOW_SHADER}[pass_name]
		var mat := ShaderMaterial.new()
		mat.shader = shader
		if pass_name == "glass":
			mat.render_priority = 1
		elif pass_name == "glow":
			mat.render_priority = 2
		_materials[pass_name] = mat
	return _materials[pass_name]


static func vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func euler_deg(a: Array) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(float(a[0])), deg_to_rad(float(a[1])), deg_to_rad(float(a[2]))))


static func part_transform(part: Dictionary) -> Transform3D:
	var basis := euler_deg(part["rot"]) if part.has("rot") else Basis.IDENTITY
	return Transform3D(basis, vec(part.get("at", [0, 0, 0])))


## A builder collects triangles per pass; finish() makes the mesh. `xf` (set per part) places the part's points;
## `bone` (>= 0) skins the part rigidly to one bone; `mirror` flips x (the left arm from the right one).
class Builder:
	var mirror := false
	var tris := {}  # pass -> Array of [Vector3 a, b, c, Color, Vector2 uv, Vector2 uv2, int bone]
	var xf := Transform3D.IDENTITY
	var bone := -1
	var _pass := "opaque"
	var _color := Color.WHITE
	var _uv := Vector2.ZERO
	var _uv2 := Vector2(0.0, 0.8)
	var skinned := false

	func use_material(mat_name: String) -> void:
		var mats: Dictionary = ViewMesh.config()["materials"]
		var m: Dictionary = mats[mat_name]
		var c: Array = m["color"]
		_color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]) if c.size() > 3 else 1.0).srgb_to_linear()
		_pass = String(m.get("pass", "opaque"))
		_uv = Vector2(float(m.get("emission", 0.0)), 0.0)
		_uv2 = Vector2(float(m.get("metallic", 0.0)), float(m.get("roughness", 0.8)))

	## Triangle (a, b, c) in part space whose outward normal is (b - a) x (c - a).
	func tri(a: Vector3, b: Vector3, c: Vector3) -> void:
		var pa := xf * a
		var pb := xf * b
		var pc := xf * c
		if (pb - pa).cross(pc - pa).length_squared() < ViewMesh._EPS * ViewMesh._EPS:
			return
		if not tris.has(_pass):
			tris[_pass] = []
		(tris[_pass] as Array).append([pa, pb, pc, _color, _uv, _uv2, bone])

	## Like tri, but turned so its normal points along `outward` (part space).
	func tri_facing(a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
		if (b - a).cross(c - a).dot(outward) < 0.0:
			tri(a, c, b)
		else:
			tri(a, b, c)

	func triangle_count() -> int:
		var n := 0
		for p in tris:
			n += (tris[p] as Array).size()
		return n

	## One surface per pass in PASSES order. Vertex order a, c, b: Godot's front face is clockwise.
	func finish() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for pass_name in ViewMesh.PASSES:
			if not tris.has(pass_name):
				continue
			var st := SurfaceTool.new()
			if skinned:
				st.set_skin_weight_count(SurfaceTool.SKIN_4_WEIGHTS)
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for t: Array in tris[pass_name]:
				var a: Vector3 = t[0]
				var b: Vector3 = t[1]
				var c: Vector3 = t[2]
				if mirror:
					a.x = -a.x
					b.x = -b.x
					c.x = -c.x
					var swap := b
					b = c
					c = swap
				var n := (b - a).cross(c - a).normalized()
				for v: Vector3 in [a, c, b]:
					st.set_normal(n)
					st.set_color(t[3])
					st.set_uv(t[4])
					st.set_uv2(t[5])
					if skinned:
						st.set_bones(PackedInt32Array([maxi(int(t[6]), 0), 0, 0, 0]))
						st.set_weights(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
					st.add_vertex(v)
			st.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, ViewMesh.material(pass_name))
		return mesh

	## Every vertex (three per triangle, mesh space, mirrored like the mesh) and its bone, in surface order; for CPU
	## skinning in tests and reach checks.
	func vertices_and_bones() -> Array:
		var verts := PackedVector3Array()
		var bones := PackedInt32Array()
		for pass_name in ViewMesh.PASSES:
			if not tris.has(pass_name):
				continue
			for t: Array in tris[pass_name]:
				var order: Array = [0, 1, 2] if mirror else [0, 2, 1]
				for k: int in order:
					var v: Vector3 = t[k]
					if mirror:
						v.x = -v.x
					verts.append(v)
					bones.append(maxi(int(t[6]), 0))
		return [verts, bones]


## Adds one data part (slab, box or lathe) to the builder, placed by its at/rot on top of `base`.
static func add_part(b: Builder, part: Dictionary, base: Transform3D = Transform3D.IDENTITY) -> void:
	b.use_material(String(part.get("mat", "gunmetal")))
	b.xf = base * part_transform(part)
	match String(part.get("shape", "box")):
		"box":
			var s := vec(part["size"])
			var hz := s.z * 0.5
			var hy := s.y * 0.5
			slab(b, [[-hz, -hy], [hz, -hy], [hz, hy], [-hz, hy]], s.x, float(part.get("chamfer", 0.0)), "x")
		"slab":
			slab(b, part["profile"], float(part["width"]), float(part.get("chamfer", 0.0)), String(part.get("axis", "x")))
		"lathe":
			var sc: Array = part.get("scale", [1.0, 1.0])
			lathe(b, part["profile"], int(part.get("sides", 8)), String(part.get("axis", "z")), bool(part.get("closed", false)),
					Vector2(float(sc[0]), float(sc[1])), float(part.get("phase_deg", 0.0)))
	b.xf = Transform3D.IDENTITY


## (u, v, w) of a profile plane and its extrusion axis -> part space.
static func _map(axis: String, u: float, v: float, w: float) -> Vector3:
	match axis:
		"x":
			return Vector3(w, v, u)
		"y":
			return Vector3(u, w, v)
	return Vector3(u, v, w)


static func _poly(profile: Array) -> PackedVector2Array:
	var poly := PackedVector2Array()
	for p: Array in profile:
		poly.append(Vector2(float(p[0]), float(p[1])))
	var area := 0.0
	for i in poly.size():
		var q := poly[(i + 1) % poly.size()]
		area += poly[i].x * q.y - q.x * poly[i].y
	if area < 0.0:
		poly.reverse()  # counter-clockwise: the interior is on the left of every edge
	return poly


## The polygon moved inward by `d` along each corner's mitre (same vertex count; small d only).
static func _inset(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var e1 := (p - poly[(i - 1 + n) % n]).normalized()
		var e2 := (poly[(i + 1) % n] - p).normalized()
		var n1 := Vector2(-e1.y, e1.x)
		var n2 := Vector2(-e2.y, e2.x)
		var m := (n1 + n2)
		m = m.normalized() if m.length_squared() > _EPS else n1
		out.append(p + m * d / maxf(m.dot(n1), 0.35))
	return out


## Profile polygon (u, v) extruded along `axis` over `width`, both faces chamfered by `chamfer` (0 = sharp).
static func slab(b: Builder, profile: Array, width: float, chamfer: float, axis: String) -> void:
	var poly := _poly(profile)
	var n := poly.size()
	var hw := width * 0.5
	var c := clampf(chamfer, 0.0, hw * 0.95)
	var face := _inset(poly, c) if c > 0.0 else poly
	var layers: Array = []  # [polygon, w]
	if c > 0.0:
		layers = [[face, -hw], [poly, -hw + c], [poly, hw - c], [face, hw]]
	else:
		layers = [[poly, -hw], [poly, hw]]
	for l in layers.size() - 1:
		var pa: PackedVector2Array = layers[l][0]
		var pb: PackedVector2Array = layers[l + 1][0]
		var wa: float = layers[l][1]
		var wb: float = layers[l + 1][1]
		for i in n:
			var j := (i + 1) % n
			var e := poly[j] - poly[i]
			var out2 := Vector2(e.y, -e.x).normalized()  # right of a CCW edge = outside
			var dw := 0.0 if l == 1 or layers.size() == 2 else (-1.0 if l == 0 else 1.0)
			var outward := _map(axis, out2.x, out2.y, dw)
			var a := _map(axis, pa[i].x, pa[i].y, wa)
			var bb := _map(axis, pa[j].x, pa[j].y, wa)
			var cc := _map(axis, pb[j].x, pb[j].y, wb)
			var d := _map(axis, pb[i].x, pb[i].y, wb)
			b.tri_facing(a, bb, cc, outward)
			b.tri_facing(a, cc, d, outward)
	var cap := Geometry2D.triangulate_polygon(face)
	for side: float in [-1.0, 1.0]:
		var outward := _map(axis, 0.0, 0.0, side)
		for t in range(0, cap.size(), 3):
			var p0 := face[cap[t]]
			var p1 := face[cap[t + 1]]
			var p2 := face[cap[t + 2]]
			b.tri_facing(_map(axis, p0.x, p0.y, hw * side), _map(axis, p1.x, p1.y, hw * side), _map(axis, p2.x, p2.y, hw * side), outward)


## Profile of [radius, height] points turned around `axis` with `sides` facets (elliptical by `scale`). An open
## profile is a silhouette from one end to the other and is closed on the axis (a solid); `closed` takes the profile
## as a closed polygon (a hollow ring or tube: outer wall, lips and bore).
static func lathe(b: Builder, profile: Array, sides: int, axis: String, closed: bool, scale: Vector2 = Vector2.ONE, phase_deg: float = 0.0) -> void:
	var pts := PackedVector2Array()
	for p: Array in profile:
		pts.append(Vector2(maxf(float(p[0]), 0.0), float(p[1])))
	if not closed:
		pts.insert(0, Vector2(0.0, pts[0].y))
		pts.append(Vector2(0.0, pts[pts.size() - 1].y))
	pts = _poly_v(pts)
	var phase := deg_to_rad(phase_deg)
	var steps := maxi(sides, 3)
	for s in steps:
		var a0 := phase + TAU * s / steps
		var a1 := phase + TAU * (s + 1) / steps
		var mid := (a0 + a1) * 0.5
		for i in pts.size():
			var p := pts[i]
			var q := pts[(i + 1) % pts.size()]
			if p.x <= 0.0 and q.x <= 0.0:
				continue
			var e := q - p
			var out2 := Vector2(e.y, -e.x).normalized()  # (radial, axial) outward of a CCW polygon edge
			var outward := _ring(axis, out2.x, mid, out2.y * 1.0, scale, true)
			var pa := _ring(axis, p.x, a0, p.y, scale)
			var pb := _ring(axis, q.x, a0, q.y, scale)
			var pc := _ring(axis, q.x, a1, q.y, scale)
			var pd := _ring(axis, p.x, a1, p.y, scale)
			if q.x <= 0.0:
				b.tri_facing(pa, pb, pd, outward)
			elif p.x <= 0.0:
				b.tri_facing(pa, pb, pc, outward)
			else:
				b.tri_facing(pa, pb, pc, outward)
				b.tri_facing(pa, pc, pd, outward)


## Counter-clockwise in the (radius, height) plane.
static func _poly_v(pts: PackedVector2Array) -> PackedVector2Array:
	var area := 0.0
	for i in pts.size():
		var q := pts[(i + 1) % pts.size()]
		area += pts[i].x * q.y - q.x * pts[i].y
	if area < 0.0:
		pts.reverse()
	return pts


## Point at radius r, angle a around `axis`, height h along it (or a direction when `dir`).
static func _ring(axis: String, r: float, a: float, h: float, scale: Vector2, dir: bool = false) -> Vector3:
	var x := cos(a) * r * (1.0 if dir else scale.x)
	var y := sin(a) * r * (1.0 if dir else scale.y)
	match axis:
		"x":
			return Vector3(h, y, x)
		"y":
			return Vector3(x, h, y)
	return Vector3(x, y, h)


## Builds a part list (static meshes) into one mesh; cached by key.
static var _cache := {}


static func build_parts(key: String, parts: Array) -> ArrayMesh:
	if not _cache.has(key):
		var b := Builder.new()
		for part: Dictionary in parts:
			add_part(b, part)
		_cache[key] = b.finish()
	return _cache[key]


## Triangles in a mesh (all surfaces).
static func triangle_count(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		n += (idx.size() if idx.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n
