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
			made = rebuild(source)
			made.resource_name = "M2W1_" + node_name
	_meshes[key] = made
	return made


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
static func rebuild(source: Mesh) -> ArrayMesh:
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
	if not indices.is_empty():
		out[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.surface_set_material(0, WorldKit.material())
	return mesh


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
