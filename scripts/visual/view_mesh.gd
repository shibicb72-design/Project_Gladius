class_name ViewMesh
extends RefCounted
## M2 AN1: flat-shaded, faceted geometry for the first-person view model (hands and weapons), built in code from the
## part lists of data/art_soldier.json (OQ-ART-SOLDIER: placeholder looks). Presentation only.
## M2 AN2 item 4a: when a data switch names a Blender-built .glb (hands.mesh_source, weapons.<id>.mesh_source) the
## meshes come from it instead (glb_view_mesh / from_glb below); the part lists stay as the fallback.
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
uniform vec3 fill_dir = vec3(-0.4, 0.75, 0.55);
uniform vec3 fill_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float fill = 0.3;
uniform float lift = 0.04;
uniform float rim = 0.35;
uniform float rim_tint = 0.65;
void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = UV2.x;
	ROUGHNESS = UV2.y;
	// M2 AN1 3b: a view-model fill light fixed to the camera (NORMAL is view space), so the facets of the gun and
	// the arms separate and the gunmetal stays neutral grey whatever the map's sky tints the ambient light.
	float facing = max(dot(NORMAL, normalize(fill_dir)), 0.0);
	EMISSION = COLOR.rgb * UV.x + COLOR.rgb * fill_color * (fill * facing + lift);
	RIM = rim;
	RIM_TINT = rim_tint;
}
"""
const _GLASS_SHADER := """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
	METALLIC = 0.0;
	ROUGHNESS = UV2.y;
	SPECULAR = 0.25;
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
		else:
			# The view-model fill and rim (art_soldier.json lighting): presentation presets, data not code.
			var l: Dictionary = config().get("lighting", {})
			for key in ["fill", "lift", "rim", "rim_tint"]:
				if l.has(key):
					mat.set_shader_parameter(key, float(l[key]))
			if l.has("fill_dir"):
				mat.set_shader_parameter("fill_dir", vec(l["fill_dir"]))
			if l.has("fill_color"):
				mat.set_shader_parameter("fill_color", vec(l["fill_color"]))
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


## --- M2 AN2 item 4a: Blender-built meshes (tools/blender/build_view_arms.py, build_weapons.py) ---------------------
## A view-model .glb carries the same stream as the part builder, except COLOR, which is sRGB there (8-bit sRGB keeps
## the dark classes precise) and becomes linear here, and UV.y, which names the pass (0 opaque, 1 glass, 2 glow). Each
## mesh is rebuilt once: one surface per pass in PASSES order with this file's ShaderMaterials (no imported material
## is left on any surface).

static var _glb_nodes := {}  # path -> {node name: {"xf": Transform3D, "mesh": Mesh or null}}
static var _glb_meshes := {}  # path:node -> ArrayMesh (view stream)


## True when `path` names an imported resource (a data switch such as mesh_source is set and the file is there).
static func has_source(path: String) -> bool:
	return path != "" and ResourceLoader.exists(path)


## The nodes of a .glb scene by name: their transform (in the scene root's frame) and mesh. Cached; the instanced
## scene is freed after reading. Empty when the file does not load.
static func glb_nodes(path: String) -> Dictionary:
	if _glb_nodes.has(path):
		return _glb_nodes[path]
	var out := {}
	var packed := load(path) as PackedScene if has_source(path) else null
	if packed == null:
		push_error("ViewMesh: %s does not load" % path)
	else:
		var scene := packed.instantiate() as Node3D
		for n: Node in scene.find_children("*", "Node3D", true, false):
			var n3 := n as Node3D
			var entry := {"xf": _scene_xf(n3, scene), "mesh": null}
			if n3 is MeshInstance3D:
				entry["mesh"] = (n3 as MeshInstance3D).mesh
			out[String(n3.name)] = entry
		scene.free()
	_glb_nodes[path] = out
	return out


static func _scene_xf(n: Node3D, root: Node3D) -> Transform3D:
	var xf := n.transform
	var p := n.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## The view-model mesh of node `node_name` in the .glb at `path` (cached), or null when it is not there.
static func glb_view_mesh(path: String, node_name: String) -> ArrayMesh:
	var key := path + ":" + node_name
	if _glb_meshes.has(key):
		return _glb_meshes[key]
	var nodes := glb_nodes(path)
	var src: Mesh = (nodes.get(node_name, {}) as Dictionary).get("mesh", null)
	var mesh: ArrayMesh = from_glb(src) if src != null else null
	_glb_meshes[key] = mesh
	return mesh


## One imported mesh in the view stream -> a mesh with one surface per pass and the game's pass materials.
## `mirror` flips x (normals too) and turns every triangle round (the left arm from the right one).
static func from_glb(src: Mesh, mirror: bool = false) -> ArrayMesh:
	var by_pass := {}
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		for part: Array in _split_by_pass(arrays):
			var pass_name: String = part[0]
			if by_pass.has(pass_name):
				push_error("ViewMesh: two surfaces of pass %s in one imported mesh" % pass_name)
				continue
			by_pass[pass_name] = _view_arrays(part[1], mirror)
	var mesh := ArrayMesh.new()
	for pass_name in PASSES:
		if not by_pass.has(pass_name):
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, by_pass[pass_name])
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(pass_name))
	return mesh


## [[pass, arrays]]: the surface as it is when every triangle shares one pass (UV.y), else split per pass.
static func _split_by_pass(arrays: Array) -> Array:
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var tri_pass := PackedInt32Array()
	var count := idx.size() if idx.size() > 0 else uv.size()
	var seen := {}
	for t in range(0, count, 3):
		var v := idx[t] if idx.size() > 0 else t
		var p := clampi(int(roundf(uv[v].y)), 0, PASSES.size() - 1)
		tri_pass.append(p)
		seen[p] = true
	if seen.size() <= 1:
		return [[PASSES[tri_pass[0] if tri_pass.size() > 0 else 0], arrays]]
	var out: Array = []
	for p: int in seen.keys():
		var remap := {}
		var keep := PackedInt32Array()
		for t in tri_pass.size():
			if tri_pass[t] != p:
				continue
			for k in 3:
				var v := idx[t * 3 + k] if idx.size() > 0 else t * 3 + k
				if not remap.has(v):
					remap[v] = remap.size()
				keep.append(remap[v])
		var sub := []
		sub.resize(Mesh.ARRAY_MAX)
		var order := PackedInt32Array()
		order.resize(remap.size())
		for v: int in remap:
			order[remap[v]] = v
		for a in Mesh.ARRAY_MAX:
			if a == Mesh.ARRAY_INDEX or arrays[a] == null:
				continue
			sub[a] = _pick(arrays[a], order, _stride(a, arrays))
		sub[Mesh.ARRAY_INDEX] = keep
		out.append([PASSES[p], sub])
	return out


static func _stride(a: int, arrays: Array) -> int:
	if a == Mesh.ARRAY_TANGENT:
		return 4
	if a == Mesh.ARRAY_BONES or a == Mesh.ARRAY_WEIGHTS:
		var n := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		return (arrays[a] as Variant).size() / maxi(n, 1)
	return 1


static func _pick(src: Variant, order: PackedInt32Array, stride: int) -> Variant:
	var out: Variant = src.duplicate()
	out.resize(order.size() * stride)
	for i in order.size():
		for k in stride:
			out[i * stride + k] = src[order[i] * stride + k]
	return out


## sRGB COLOR -> linear, tangents dropped (the view shaders use none), and the optional x mirror.
static func _view_arrays(arrays: Array, mirror: bool) -> Array:
	var out := arrays.duplicate()
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var lin := PackedColorArray()
	lin.resize(cols.size())
	for i in cols.size():
		lin[i] = cols[i].srgb_to_linear()
	out[Mesh.ARRAY_COLOR] = lin
	out[Mesh.ARRAY_TANGENT] = null
	if mirror:
		var verts: PackedVector3Array = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
		var normals: PackedVector3Array = (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate()
		for i in verts.size():
			verts[i].x = -verts[i].x
			normals[i].x = -normals[i].x
		var idx: PackedInt32Array = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
		for t in range(0, idx.size(), 3):
			var swap := idx[t + 1]
			idx[t + 1] = idx[t + 2]
			idx[t + 2] = swap
		out[Mesh.ARRAY_VERTEX] = verts
		out[Mesh.ARRAY_NORMAL] = normals
		out[Mesh.ARRAY_INDEX] = idx
	return out


## Triangles in a mesh (all surfaces).
static func triangle_count(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		n += (idx.size() if idx.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n
