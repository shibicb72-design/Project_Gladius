class_name WorldKitMeshes
extends RefCounted
## M2W1: the world kit's Blender looks (tools/blender/m2w1_world_kit.py -> a glb, data/art_world_kit.json says
## which types, node names and LOD swap distances; placeholders, OQ-ART-WORLD). WorldKit.mesh_for(type) hands the
## near mesh to the map batches when the type has an entry and the switch is on (data/graphics_presets.json
## art_world_kit_enabled); MapChunks draws the far mesh ("<type>_lod1") beyond lod_swap_m.
## Each imported mesh is rebuilt as ONE ArrayMesh surface with WorldKit.material(), so a batch stays one draw with
## the one shared material, and with the vertex data the world shader reads (LowpolyKit._triangle): COLOR = the
## paint in sRGB, as the glb stores it (not linear as glTF says: Godot keeps vertex colours as 8 bits and 8-bit
## linear loses the dark paints; tests/test_m2w1_world_kit.gd checks the round trip), UV = metres on the face's plane,
## UV2 = (surface id, shade), TANGENT along +u (made here from the UVs), flat normals. A type missing from the
## json, a missing glb or node: the kit look stays, and one error line says why.

const PATH := "res://data/art_world_kit.json"
const LOD1_SUFFIX := "_lod1"
static var _registry := DataRegistry.new()
static var _meshes := {}  # "<type>/<level>" -> ArrayMesh or null (null = not available, already reported)
static var _scenes := {}  # glb path -> {node name: Mesh} (empty when the glb does not load)
## Tests: -1 = the graphics preset decides, 0 = off, 1 = on.
static var enabled_override := -1
## Tests capture the fallback error line here instead of push_error.
static var error_sink: Callable = Callable()


## Tests: a whole art_world_kit.json stand-in (empty = the file).
static var config_override := {}


static func config() -> Dictionary:
	return config_override if not config_override.is_empty() else _registry.load_file(PATH)


static func enabled() -> bool:
	if enabled_override >= 0:
		return enabled_override == 1
	return bool(GraphicsPresets.new().get_preset().get("art_world_kit_enabled", false))


static func entry(type: String) -> Dictionary:
	return (config().get("types", {}) as Dictionary).get(type, {})


static func has_entry(type: String) -> bool:
	return not entry(type).is_empty()


## The near / far swap distance of a type (0 = no LOD pair).
static func swap_m(type: String) -> float:
	return float(entry(type).get("lod_swap_m", 0.0))


## Splits "<type>_lod1" into [type, 1]; any other name is [name, 0].
static func split_level(name: String) -> Array:
	if name.ends_with(LOD1_SUFFIX):
		return [name.trim_suffix(LOD1_SUFFIX), 1]
	return [name, 0]


## Whether the type's entry names a far mesh (M2W1 item 2: a light type may have none: no lod1_node, lod_swap_m 0).
static func has_lod1(type: String) -> bool:
	return String(entry(type).get("lod1_node", "")) != ""


## The type's mesh at `level` (0 near, 1 far), or null when the type has no usable entry (reported once). A far
## mesh of a type without lod1_node is null and not an error (that type draws no LOD pair).
static func mesh(type: String, level: int) -> ArrayMesh:
	var key := "%s/%d" % [type, level]
	if _meshes.has(key):
		return _meshes[key]
	var made: ArrayMesh = null
	var e := entry(type)
	if e.is_empty():
		_report("WorldKitMeshes: %s has no entry in %s; its kit look stays" % [type, PATH])
	elif level == 1 and not has_lod1(type):
		pass
	else:
		var glb := String(e.get("glb", config().get("glb", "")))
		var node_name := String(e["node"] if level == 0 else e["lod1_node"])
		var source := _source_mesh(glb, node_name)
		if source == null:
			_report("WorldKitMeshes: %s: no mesh node %s in %s; its kit look stays" % [type, node_name, glb])
		else:
			made = rebuild(source, kit_custom(type), type if bake_enabled() else "")
			made.resource_name = "M2W1_" + node_name
	_meshes[key] = made
	return made


## M2W1 astraA: the per-mesh CUSTOM0 of a world-kit look (glb structure or parts cover): x = its variation weight
## (data "variation" weights: the type's, else "cover" for a cover look, else "default"), y = the shade range the
## shader reads UV2.y over (data "shade_bake".shade_range) when the shade is baked (0 = the shader's own part_shade
## and grime, the old path), z = how much of the shader's world-height grime the look keeps (only read when y > 0),
## w = 0. Every other mesh has no CUSTOM0 (reads 0): no variation, the shader's own part_shade and grime.
static func kit_custom(type: String, cover := false) -> Vector4:
	var variation: Dictionary = config().get("variation", {})
	var weights: Dictionary = variation.get("weights", {})
	var w := float(weights.get(type, weights.get("cover", 1.0) if cover else weights.get("default", 0.0)))
	var bake := shade_bake()
	if cover:
		var c: Dictionary = config().get("cover_defaults", {})
		return Vector4(w, float(bake.get("shade_range", 0.5)), float(c.get("grime", 0.0)), 0.0)
	if not bake_enabled():
		return Vector4(w, 0.0, 0.0, 0.0)
	return Vector4(w, float(bake.get("shade_range", 0.5)), float(bake.get("grime", 0.0)), 0.0)


## M2W1 astraA (F5): data/art_world_kit.json "shade_bake" ({} = none).
static func shade_bake() -> Dictionary:
	return config().get("shade_bake", {})


## Whether the glb structure meshes get the load-time shade bake (off: their UV2 and the shader path as before).
static func bake_enabled() -> bool:
	return bool(shade_bake().get("enabled", false))


## M2W1 astraA (F4): the cover look entry of a one-box cover type ({} = none: the type keeps its kit look).
static func cover_entry(type: String) -> Dictionary:
	return (config().get("cover", {}) as Dictionary).get(type, {})


## The parts look of a one-box cover type (data/art_world_kit.json cover.<type>.parts, authored on the type's box,
## centred as its collider is), or null without an entry. Cached per type; one surface, the shared material.
static func cover_mesh(type: String) -> ArrayMesh:
	var key := "cover/" + type
	if _meshes.has(key):
		return _meshes[key]
	var made: ArrayMesh = null
	var parts := cover_parts(type)
	var node_name := cover_node(type)
	if node_name != "":
		# M2W1 r2a: a glb look (authored on the type's box, centred as its collider is): the same loader as the
		# structures (one surface, the shared material, CUSTOM0 as kit_custom for cover, the load-time bake)
		var glb := String(config().get("glb", ""))
		var source := _source_mesh(glb, node_name)
		if source == null:
			_report("WorldKitMeshes: cover %s: no mesh node %s in %s; its kit look stays" % [type, node_name, glb])
		else:
			made = rebuild(source, kit_custom(type, true), type if bake_enabled() else "")
			made.resource_name = "M2W1_cover_" + type
	elif not parts.is_empty():
		var e := cover_entry(type)
		var scale := float(e.get("shade_scale", cover_entry(String(e.get("same_as", type))).get("shade_scale", 1.0)))
		made = parts_mesh(parts, kit_custom(type, true), scale)
		made.resource_name = "M2W1_cover_" + type
	_meshes[key] = made
	return made


## M2W1 r2a: the glb node of a cover entry (its own "node", or its same_as entry's), "" for a parts look or none.
static func cover_node(type: String) -> String:
	var e := cover_entry(type)
	if e.has("same_as"):
		e = cover_entry(String(e["same_as"]))
	return String(e.get("node", ""))


## The parts of a cover entry: its own, or (same_as) another entry's, with x and z swapped when swap_xz is true
## (size, at and a taper's top / bottom / top_shift; the shapes are made from sizes, so this is no mirror of the
## winding). [] = no entry.
static func cover_parts(type: String) -> Array:
	var e := cover_entry(type)
	if e.has("same_as"):
		var parts: Array = cover_entry(String(e["same_as"])).get("parts", [])
		if not bool(e.get("swap_xz", false)):
			return parts
		var out: Array = []
		for part: Dictionary in parts:
			var p := part.duplicate(true)
			for k: String in ["size", "at"]:
				p[k] = [p[k][2], p[k][1], p[k][0]]
			for k: String in ["top", "bottom", "top_shift"]:
				if p.has(k):
					p[k] = [p[k][1], p[k][0]]
			out.append(p)
		return out
	return e.get("parts", [])


## A breakable's or chest's look parts (data/props.json) as a cover look (cover variation weight), cached by `key`.
static func prop_mesh(key: String, parts: Array) -> ArrayMesh:
	var cache_key := "prop/" + key
	if not _meshes.has(cache_key):
		var made := parts_mesh(parts, kit_custom(key, true))
		made.resource_name = "M2W1_prop_" + key
		_meshes[cache_key] = made
	return _meshes[cache_key]


## Kit parts (LowpolyKit's part format and shapes) merged into ONE surface with the shared material, with the
## vertex data of every kit mesh (each part is LowpolyKit.merge([part]); the arrays are joined in part order).
## A part's optional "shade" is its value multiplier (1 = its paint as is; < 1 darker), written as UV2.y over
## custom.y; a part without it keeps its hashed kit shade at the shader's part_shade strength. custom (CUSTOM0) as
## kit_custom; shade_scale multiplies every part's "shade" (a whole look one step darker or lighter). Deterministic.
static func parts_mesh(parts: Array, custom: Vector4, shade_scale := 1.0) -> ArrayMesh:
	var range_m := custom.y
	var part_shade := float(shade_bake().get("part_shade", 0.08))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	for part: Dictionary in parts:
		var a := LowpolyKit.merge([part]).surface_get_arrays(0)
		var start := uv2s.size()
		verts.append_array(a[Mesh.ARRAY_VERTEX])
		normals.append_array(a[Mesh.ARRAY_NORMAL])
		tangents.append_array(a[Mesh.ARRAY_TANGENT])
		colors.append_array(a[Mesh.ARRAY_COLOR])
		uvs.append_array(a[Mesh.ARRAY_TEX_UV])
		uv2s.append_array(a[Mesh.ARRAY_TEX_UV2])
		if range_m <= 0.0:
			continue
		for i in range(start, uv2s.size()):
			var uv2 := uv2s[i]
			var m := float(part["shade"]) * shade_scale if part.has("shade") else 1.0 + (uv2.y - 0.5) * 2.0 * part_shade
			uv2.y = _encode(m, range_m)
			uv2s[i] = uv2
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TANGENT] = tangents
	out[Mesh.ARRAY_COLOR] = colors
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_TEX_UV2] = uv2s
	return _commit(out, verts.size(), custom)


## A value multiplier m as the UV2.y the shader reads over `range_m` (1 + (UV2.y - 0.5) * 2 * range_m = m).
static func _encode(m: float, range_m: float) -> float:
	return clampf(0.5 + (m - 1.0) / (2.0 * range_m), 0.0, 1.0)


## Forgets the built meshes (tests switch data or the toggle).
static func clear_cache() -> void:
	_meshes.clear()
	_scenes.clear()


static func _report(message: String) -> void:
	if error_sink.is_valid():
		error_sink.call(message)
	else:
		push_error(message)


## The mesh of node `node_name` in the imported glb (the scene is instantiated once, its meshes kept by node
## name, the instance freed).
static func _source_mesh(glb: String, node_name: String) -> Mesh:
	if not _scenes.has(glb):
		var found := {}
		var scene: PackedScene = load(glb) if ResourceLoader.exists(glb) else null
		if scene != null:
			var root := scene.instantiate()
			for node: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
				found[String(node.name)] = node.mesh
			root.free()
		_scenes[glb] = found
	return (_scenes[glb] as Dictionary).get(node_name, null)


## One surface with WorldKit.material(): vertices, normals, colours and UVs as imported, tangents along +u. Deterministic (same input arrays -> same output arrays).
## M2W1 astraA: `custom` (not zero) is written to every vertex as CUSTOM0 (RGBA float; kit_custom); `bake_type`
## (not "") replaces UV2.y with the load-time shade bake of that type (bake_shade; custom.y must be its range).
static func rebuild(source: Mesh, custom := Vector4.ZERO, bake_type := "") -> ArrayMesh:
	var arrays := source.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	var tangents := PackedFloat32Array()
	tangents.resize(verts.size() * 4)
	var count := indices.size() if not indices.is_empty() else verts.size()
	for t in count / 3:
		var ids := [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]] if not indices.is_empty() else [t * 3, t * 3 + 1, t * 3 + 2]
		var tangent := _face_tangent(verts, uvs, normals, ids)
		for i: int in ids:
			tangents[i * 4] = tangent.x
			tangents[i * 4 + 1] = tangent.y
			tangents[i * 4 + 2] = tangent.z
			tangents[i * 4 + 3] = tangent.d
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TANGENT] = tangents
	out[Mesh.ARRAY_COLOR] = arrays[Mesh.ARRAY_COLOR]
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV2]
	if bake_type != "" and custom.y > 0.0:
		out[Mesh.ARRAY_TEX_UV2] = bake_shade(bake_type, verts, normals, arrays[Mesh.ARRAY_COLOR], arrays[Mesh.ARRAY_TEX_UV2], indices, custom.y)
	if not indices.is_empty():
		out[Mesh.ARRAY_INDEX] = indices
	return _commit(out, verts.size(), custom)


## Adds CUSTOM0 (when `custom` is not zero) and makes the one-surface mesh with WorldKit.material().
static func _commit(out: Array, count: int, custom: Vector4) -> ArrayMesh:
	var flags := 0
	if custom != Vector4.ZERO:
		var c := PackedFloat32Array()
		c.resize(count * 4)
		for i in count:
			c[i * 4] = custom.x
			c[i * 4 + 1] = custom.y
			c[i * 4 + 2] = custom.z
			c[i * 4 + 3] = custom.w
		out[Mesh.ARRAY_CUSTOM0] = c
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, flags)
	mesh.surface_set_material(0, WorldKit.material())
	return mesh


## M2W1 astraA (F5), r2a: the load-time shade of a glb mesh, per vertex, as UV2.y over `range_m` (data
## "shade_bake", placeholders). The shade is baked in two places, one term each: tools/blender/m2w1_world_kit.py
## writes the geometry terms into the glb's UV2.y over the same shade_range (the part shade, threshold and tread
## wear, the foundation band, occlusion; shade_bake.glb), this adds the material terms: m = glb x paint x facing x
## type gain, paint = paint_value[paint name] (the vertex colour's art_astra.json colour), facing = up.gain on faces
## looking up, down.gain on faces looking down, gain = by_type.<type>.gain (and by_type.<type>.paint_gain.<paint>,
## r2a: ordinary pieces' marble trim one step down so the summit owns the brightest white). Paints in skip_paints (glow, visor) keep
## their raw part shade (the glb's UV2.y read at part_shade, as the old path drew it). Deterministic; near and far
## meshes get the same rules.
static func bake_shade(type: String, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		uv2s: PackedVector2Array, _indices: PackedInt32Array, range_m: float) -> PackedVector2Array:
	var b := shade_bake()
	var part_shade := float(b.get("part_shade", 0.08))
	var values: Dictionary = b.get("paint_value", {})
	var skip: Array = b.get("skip_paints", [])
	var up: Dictionary = b.get("up", {})
	var down: Dictionary = b.get("down", {})
	var by_type: Dictionary = (b.get("by_type", {}) as Dictionary).get(type, {})
	var gain := float(by_type.get("gain", 1.0))
	var paint_gain: Dictionary = by_type.get("paint_gain", {})
	var out := uv2s.duplicate()
	for i in verts.size():
		var paint := paint_of(colors[i])
		var m := 1.0 + (uv2s[i].y - 0.5) * 2.0 * part_shade
		if not skip.has(paint):
			m = (1.0 + (uv2s[i].y - 0.5) * 2.0 * range_m) * float(values.get(paint, 1.0)) * float(paint_gain.get(paint, 1.0)) * gain
			var n := normals[i]
			if n.y >= float(up.get("normal_y", 2.0)):
				m *= float(up.get("gain", 1.0))
			elif n.y <= float(down.get("normal_y", -2.0)):
				m *= float(down.get("gain", 1.0))
		out[i] = Vector2(uv2s[i].x, _encode(m, range_m))
	return out


static var _paint_cache := {}  # 8-bit colour key -> paint name


## The art_astra.json colour name of a vertex colour: the nearest palette colour within 2/255 (the glb keeps
## colours as 8 bits; the first name wins a tie), "" for none. Cached per colour.
static func paint_of(c: Color) -> String:
	var key := (roundi(c.r * 255.0) << 24) | (roundi(c.g * 255.0) << 16) | (roundi(c.b * 255.0) << 8) | roundi(c.a * 255.0)
	if not _paint_cache.has(key):
		var colors: Dictionary = LowpolyKit.config()["colors"]
		var best := 2.0 / 255.0 + 1e-6
		var found := ""
		for k: String in colors:
			if k.begins_with("_"):
				continue
			var p := GreyboxArt.color_value(colors[k])
			var d := maxf(maxf(absf(c.r - p.r), absf(c.g - p.g)), maxf(absf(c.b - p.b), absf(c.a - p.a)))
			if d < best:
				best = d
				found = k
		_paint_cache[key] = found
	return _paint_cache[key]


## The direction of +u in the triangle's plane, w = the bitangent sign (LowpolyKit._triangle: +1 when
## normal x tangent points along +v).
static func _face_tangent(verts: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array, ids: Array) -> Plane:
	var p0 := verts[ids[0]]
	var e1 := verts[ids[1]] - p0
	var e2 := verts[ids[2]] - p0
	var d1 := uvs[ids[1]] - uvs[ids[0]]
	var d2 := uvs[ids[2]] - uvs[ids[0]]
	var det := d1.x * d2.y - d2.x * d1.y
	var normal := normals[ids[0]]
	if absf(det) < 1e-12:
		var any := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
		return Plane(any, 1.0)
	var r := 1.0 / det
	var du := (e1 * d2.y - e2 * d1.y) * r  # dP/du
	var dv := (e2 * d1.x - e1 * d2.x) * r  # dP/dv
	var tangent := (du - normal * normal.dot(du)).normalized()
	var side := 1.0 if normal.cross(tangent).dot(dv) >= 0.0 else -1.0
	return Plane(tangent, side)
