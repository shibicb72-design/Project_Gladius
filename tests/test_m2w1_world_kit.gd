extends "res://tests/test_case.gd"
## M2W1: the world kit's Blender looks (tools/blender/m2w1_world_kit.py -> assets/generated/world/*.glb,
## scripts/visual/world_kit_meshes.gd, data/art_world_kit.json). Each listed type: near and far meshes load as one
## surface with the shared material and the shader's vertex data; every vertex fits the type's colliders (what you
## see is what blocks), the open volumes stay open, nothing stands on a walk surface; budgets; the switch and the
## fallback; MapChunks LOD pairs. The 1 km map is built at most once in this file (a static, freed by test_zz).
const Perf := preload("res://tests/test_astra_perf.gd")
const MAP_1KM := "res://data/maps/alesia_1km.json"

static var _built: Node3D


func _cfg() -> Dictionary:
	return WorldKitMeshes.config()


func _types() -> Array:
	var out: Array = []
	for type: String in _cfg()["types"]:
		if not type.begins_with("_"):
			out.append(type)
	return out


## M2W1 astraA: the cover look entries (data/art_world_kit.json "cover").
func _cover_types() -> Array:
	var out: Array = []
	for type: String in (_cfg().get("cover", {}) as Dictionary):
		if not type.begins_with("_"):
			out.append(type)
	return out


func _kit_types() -> Dictionary:
	return WorldKit.config()["types"]


## The LOD levels a type has: [0, 1], or [0] for a type without a far mesh (M2W1 item 2).
func _levels(type: String) -> Array:
	return [0, 1] if WorldKitMeshes.has_lod1(type) else [0]


func _reset() -> void:
	WorldKitMeshes.enabled_override = -1
	WorldKitMeshes.config_override = {}
	WorldKitMeshes.error_sink = Callable()
	WorldKitMeshes.clear_cache()
	WorldKit.clear_mesh_cache()


# --- geometry helpers ---

## Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
static func _closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


## Per collider entry: {"xf_inv": piece -> collider space, "half": box half size} for a box, or {"tris": the
## wedge's triangles in piece space, "planes": its face planes (outward)} for a wedge (its exact convex hull, the
## shape WorldKit.collider_shape builds).
static func _solids(type_def: Dictionary) -> Array:
	var out: Array = []
	for entry: Dictionary in type_def["colliders"]:
		var xf := LowpolyShapes.transform_of(entry)
		if String(entry.get("shape", "box")) == "wedge":
			var tris := PackedVector3Array()
			for p in LowpolyShapes.triangles({"shape": "wedge", "size": entry["size"], "ridge": entry.get("ridge", 1.0)}, LowpolyKit.config()["kit"]["shapes"]):
				tris.append(xf * p)
			var centre := Vector3.ZERO
			for p in tris:
				centre += p
			centre /= float(tris.size())
			var planes: Array[Plane] = []
			for t in tris.size() / 3:
				var pl := Plane(tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2])
				if pl.normal == Vector3.ZERO:
					continue
				if pl.distance_to(centre) > 0.0:
					pl = -pl
				planes.append(pl)
			out.append({"tris": tris, "planes": planes})
		else:
			out.append({"xf_inv": xf.affine_inverse(), "half": LowpolyKit.vec(entry["size"]) * 0.5})
	return out


static func _distance(p: Vector3, solid: Dictionary) -> float:
	if solid.has("half"):
		var q: Vector3 = solid["xf_inv"] * p
		var h: Vector3 = solid["half"]
		var d := Vector3(maxf(absf(q.x) - h.x, 0.0), maxf(absf(q.y) - h.y, 0.0), maxf(absf(q.z) - h.z, 0.0))
		return d.length()
	var inside := true
	for pl: Plane in solid["planes"]:
		if pl.distance_to(p) > 1e-6:
			inside = false
			break
	if inside:
		return 0.0
	var tris: PackedVector3Array = solid["tris"]
	var best := INF
	for t in tris.size() / 3:
		best = minf(best, p.distance_to(_closest_on_triangle(p, tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2])))
	return best


## How far each vertex lies outside the nearest collider solid: [max, the vertex].
static func _overshoot(mesh: Mesh, solids: Array) -> Array:
	var worst := 0.0
	var at := Vector3.ZERO
	var seen := {}
	for v: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		if seen.has(v):
			continue
		seen[v] = true
		var best := INF
		for solid: Dictionary in solids:
			best = minf(best, _distance(v, solid))
			if best <= 0.0:
				break
		if best > worst:
			worst = best
			at = v
	return [worst, at]


static func _unique_vertices(mesh: Mesh) -> PackedVector3Array:
	var seen := {}
	var out := PackedVector3Array()
	for v: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		if not seen.has(v):
			seen[v] = true
			out.append(v)
	return out


# --- the meshes ---

func test_every_listed_type_has_near_and_far_meshes_with_the_shader_data() -> void:
	_reset()
	var order: Array = WorldSurface.config()["surface_order"]
	assert_true(bool(_cfg()["_placeholder"]) and String(_cfg()["_todo"]).contains("OQ-ART-WORLD"), "placeholder data with its OQ id")
	assert_true(_types().size() >= 2, "nonvacuous: types listed")
	# Review blocker (Lanista): EVERY world kit type must have a look entry, so a type dropped from
	# art_world_kit.json cannot silently fall back to the old kit look.
	var kit: Array = []
	for type: String in _kit_types():
		if not type.begins_with("_"):
			kit.append(type)
	kit.sort()
	var listed := _types().duplicate()
	listed.sort()
	assert_eq(listed, kit, "every world kit type (alesia_structures.json) has an entry in art_world_kit.json, and no extra")
	for type: String in _types():
		assert_true(_kit_types().has(type), type + ": a world kit type")
		for level: int in _levels(type):
			var tag := "%s level %d" % [type, level]
			var mesh := WorldKitMeshes.mesh(type, level)
			assert_true(mesh != null, tag + ": loads")
			if mesh == null:
				continue
			if bool(WorldKitMeshes.entry(type).get("textured", false)):
				_assert_textured(mesh, level, tag)
				continue
			assert_true(mesh.get_surface_count() == 1 and mesh.surface_get_material(0) == WorldKit.material(), tag + ": one surface, the shared kit material")
			var arrays := mesh.surface_get_arrays(0)
			for slot: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
				assert_true(arrays[slot] != null and (arrays[slot] as Variant).size() > 0, "%s: array %d present" % [tag, slot])
			var bad := 0
			for uv2: Vector2 in arrays[Mesh.ARRAY_TEX_UV2]:
				if absf(uv2.x - roundf(uv2.x)) > 1e-4 or uv2.x < 0.0 or uv2.x >= float(order.size()) or uv2.y < 0.0 or uv2.y > 1.0:
					bad += 1
			assert_eq(bad, 0, tag + ": UV2.x a whole surface id inside surface_order, UV2.y a shade 0..1")
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			var skew := 0
			for i in normals.size():
				var t := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
				if absf(t.length() - 1.0) > 1e-3 or absf(t.dot(normals[i])) > 1e-3:
					skew += 1
			assert_eq(skew, 0, tag + ": unit tangents in the face plane")
	_reset()


func _assert_textured(mesh: ArrayMesh, level: int, tag: String) -> void:
	assert_eq(mesh.get_surface_count(), 1, tag + ": one painted surface")
	if mesh.get_surface_count() != 1:
		return
	var arrays := mesh.surface_get_arrays(0)
	for slot: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV]:
		assert_true(arrays[slot] != null and (arrays[slot] as Variant).size() > 0, "%s: array %d present" % [tag, slot])
	var material := mesh.surface_get_material(0) as StandardMaterial3D
	assert_true(material != null, tag + ": imported StandardMaterial3D")
	if material == null:
		return
	var albedo_px := 2048 if level == 0 else 512
	_assert_texture(material.albedo_texture, albedo_px, tag + " albedo")
	if level != 0:
		return
	assert_true(material.normal_enabled and material.ao_enabled, tag + ": enabled normal and occlusion")
	_assert_texture(material.normal_texture, 1024, tag + " normal")
	_assert_texture(material.ao_texture, 1024, tag + " packed ORM")
	assert_eq(material.ao_texture, material.roughness_texture, tag + ": roughness shares ORM")
	assert_eq(material.ao_texture, material.metallic_texture, tag + ": metallic shares ORM")
	assert_eq(material.ao_texture_channel, BaseMaterial3D.TEXTURE_CHANNEL_RED, tag + ": occlusion uses red")
	assert_eq(material.roughness_texture_channel, BaseMaterial3D.TEXTURE_CHANNEL_GREEN, tag + ": roughness uses green")
	assert_eq(material.metallic_texture_channel, BaseMaterial3D.TEXTURE_CHANNEL_BLUE, tag + ": metallic uses blue")


func _assert_texture(texture: Texture2D, pixels: int, tag: String) -> void:
	assert_true(texture is CompressedTexture2D, tag + ": imported compressed texture")
	if texture != null:
		assert_eq(texture.get_size(), Vector2(pixels, pixels), tag + ": dimensions")


func test_glb_holds_exactly_the_listed_nodes() -> void:
	_reset()
	var default_glb := String(_cfg()["glb"])
	var expected := {default_glb: {}}
	for type: String in _types():
		var row: Dictionary = _cfg()["types"][type]
		var path := String(row.get("glb", default_glb))
		if not expected.has(path):
			expected[path] = {}
		expected[path][String(row["node"])] = true
		if WorldKitMeshes.has_lod1(type):
			expected[path][String(row["lod1_node"])] = true
	for type: String in _cover_types():
		var row: Dictionary = _cfg()["cover"][type]
		if row.has("node"):
			expected[default_glb][String(row["node"])] = true
	var dressing := "res://assets/generated/world/m2cx2_dressing.glb"
	for retired: String in _cfg().get("retired_nodes", []):
		assert_true(not expected[dressing].has(retired), retired + ": present only as a retired dressing node")
		expected[dressing][retired] = true
	for glb: String in expected:
		var scene := load(glb) as PackedScene
		assert_true(scene != null, "the glb imports: " + glb)
		if scene == null:
			continue
		var root := scene.instantiate()
		var names := {}
		for node: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			names[String(node.name)] = node.mesh.get_surface_count()
		root.free()
		for node_name: String in expected[glb]:
			assert_true(names.has(node_name), "%s has node %s" % [glb, node_name])
			assert_eq(int(names.get(node_name, 0)), 1, node_name + ": one surface")
		for node_name: String in names:
			assert_true(expected[glb].has(node_name), "%s node %s is listed in art_world_kit.json" % [glb, node_name])
		print("M2W1_KIT glb=%s nodes=%s" % [glb, str(names.keys())])


## The glb stores the paint as sRGB (see world_kit_meshes.gd): every vertex colour is a palette colour of
## data/art_astra.json within 1/255, and every surface id is the one that paint or the script's override gives.
func test_vertex_colours_round_trip_to_the_palette() -> void:
	_reset()
	var palette: Array[Color] = []
	var names: Array[String] = []
	var colors: Dictionary = LowpolyKit.config()["colors"]
	for key: String in colors:
		if not key.begins_with("_"):
			palette.append(GreyboxArt.color_value(colors[key]))
			names.append(key)
	var used := {}
	for type: String in _types():
		if bool(WorldKitMeshes.entry(type).get("textured", false)):
			continue
		for level in 2:
			var mesh := WorldKitMeshes.mesh(type, level)
			if mesh == null:
				continue
			var worst := 0.0
			for c: Color in mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]:
				var best := INF
				var best_i := -1
				for i in palette.size():
					var p := palette[i]
					var d := maxf(maxf(absf(c.r - p.r), absf(c.g - p.g)), maxf(absf(c.b - p.b), absf(c.a - p.a)))
					if d < best:
						best = d
						best_i = i
				worst = maxf(worst, best)
				used[names[best_i]] = true
			assert_true(worst <= 1.0 / 255.0 + 1e-6, "%s level %d: every vertex colour is a palette paint within 1/255 (worst %.5f)" % [type, level, worst])
	assert_true(used.has("visor") or used.has("rock"), "nonvacuous: a dark paint went through the round trip")
	print("M2W1_KIT paints used: ", used.keys())


func test_every_vertex_fits_the_colliders_and_the_open_and_walk_rules() -> void:
	_reset()
	var tol := float(_cfg()["fit_tolerance_m"])
	var clear := float(_cfg()["walk_clear_m"])
	var head := float(_cfg()["walk_head_m"])
	var edge := float(_cfg()["walk_edge_m"])
	var exceptions: Dictionary = _cfg().get("prop_fit_exceptions", {})
	for type: String in _types():
		var def: Dictionary = _kit_types()[type]
		var solids := _solids(def)
		for level: int in _levels(type):
			var mesh := WorldKitMeshes.mesh(type, level)
			if mesh == null:
				assert_true(false, "%s level %d: no mesh" % [type, level])
				continue
			var tag := "%s level %d" % [type, level]
			if exceptions.has(type):
				_assert_prop_fit(mesh, solids, tol, exceptions[type], tag)
			else:
				var over := _overshoot(mesh, solids)
				assert_true(float(over[0]) <= tol + 1e-5, "%s: every vertex within %.2f m of a collider (worst %.3f at %s)" % [tag, tol, over[0], over[1]])
			var verts := _unique_vertices(mesh)
			# Open volumes (boxes, no rot): no vertex deeper than the tolerance inside.
			for open: Dictionary in def.get("open", []):
				var c := LowpolyKit.vec(open["at"])
				var h := LowpolyKit.vec(open["size"]) * 0.5
				var deepest := 0.0
				var where := Vector3.ZERO
				for v in verts:
					var q := (v - c).abs()
					if q.x < h.x and q.y < h.y and q.z < h.z:
						var depth := minf(minf(h.x - q.x, h.y - q.y), h.z - q.z)
						if depth > deepest:
							deepest = depth
							where = v
				assert_true(deepest <= tol + 1e-5, "%s: open volume %s stays open (deepest vertex %.3f m in, at %s)" % [tag, str(open["at"]), deepest, where])
			# Walk surfaces: nothing between walk_clear_m and walk_head_m above one inside its footprint.
			for surface: Dictionary in def.get("walk", []):
				var size: Array = surface["size"]
				var rise := float(surface.get("rise", 0.0))
				var inv := LowpolyShapes.transform_of(surface).affine_inverse()
				var worst := 0.0
				var at := Vector3.ZERO
				for v in verts:
					var q := inv * v
					if absf(q.x) >= float(size[0]) * 0.5 - edge or absf(q.z) >= float(size[1]) * 0.5 - edge:
						continue
					var above := q.y - rise * q.z / float(size[1])
					if above > clear and above <= head and above > worst:
						worst = above
						at = v
				assert_true(worst == 0.0, "%s: walk surface %s is clear (a vertex %.3f m above it at %s)" % [tag, str(surface["at"]), worst, at])
	_reset()


func _assert_prop_fit(mesh: Mesh, solids: Array, tolerance: float, exception: Dictionary, tag: String) -> void:
	var inverse_yaw := Basis(Vector3.UP, -deg_to_rad(float(exception["yaw_deg"])))
	var regions: Array[AABB] = []
	for area: Dictionary in (exception["regions"] as Dictionary).values():
		var lo := LowpolyKit.vec(area["min"])
		regions.append(AABB(lo, LowpolyKit.vec(area["max"]) - lo))
	var worst_excess := 0.0
	var where := Vector3.ZERO
	for vertex: Vector3 in _unique_vertices(mesh):
		var best := INF
		for solid: Dictionary in solids:
			best = minf(best, _distance(vertex, solid))
		if best <= tolerance:
			continue
		var limit := tolerance
		for region: AABB in regions:
			if region.has_point(inverse_yaw * vertex):
				limit = float(exception["tolerance_m"])
				break
		if best - limit > worst_excess:
			worst_excess = best - limit
			where = vertex
	assert_true(worst_excess <= 1e-5, "%s: vertices fit their collider or named exception (excess %.3f at %s)" % [tag, worst_excess, where])


func test_budgets_and_report() -> void:
	_reset()
	var budgets: Dictionary = _cfg()["budgets"]
	var lod1_max := int(_cfg()["lod1_max_tris"])
	var lod1_overrides: Dictionary = _cfg().get("lod1_max_tris_by_type", {})
	var lod_over := int(_cfg()["lod_required_over_tris"])
	var without: Array[String] = []
	for type: String in _types():
		var near := WorldKitMeshes.mesh(type, 0)
		var lod := WorldKitMeshes.has_lod1(type)
		var far := WorldKitMeshes.mesh(type, 1) if lod else null
		if near == null or (lod and far == null):
			assert_true(false, type + ": meshes missing")
			continue
		var tn := Perf.triangles(near)
		var kit := Perf.triangles(WorldKit.build_mesh(_kit_types()[type]))
		var solids := _solids(_kit_types()[type])
		assert_true(budgets["near_tris"].has(type) and tn <= int(budgets["near_tris"][type]), "%s: near %d triangles within %s" % [type, tn, budgets["near_tris"].get(type)])
		# M2W1 item 2: a far mesh is required above lod_required_over_tris; a type without one has no swap distance.
		assert_true(lod or tn <= lod_over, "%s: near %d triangles over %d needs a far mesh" % [type, tn, lod_over])
		assert_eq(lod, WorldKitMeshes.swap_m(type) > 0.0, type + ": a far mesh exactly when lod_swap_m > 0")
		if not lod:
			without.append(type)
			print("M2W1_KIT_REPORT type=%s kit_tris=%d near_tris=%d far_tris=none near_overshoot=%.3f swap_m=0 (no far mesh)" % [type, kit, tn, _overshoot(near, solids)[0]])
			continue
		var tf := Perf.triangles(far)
		var far_cap := int(lod1_overrides.get(type, lod1_max))
		assert_true(budgets["lod1_tris"].has(type) and tf <= int(budgets["lod1_tris"][type]) and tf <= far_cap, "%s: far %d triangles within %s and %d" % [type, tf, budgets["lod1_tris"].get(type), far_cap])
		assert_true(tf < tn, type + ": the far mesh is lighter")
		print("M2W1_KIT_REPORT type=%s kit_tris=%d near_tris=%d far_tris=%d near_overshoot=%.3f far_overshoot=%.3f swap_m=%.0f (uncovered collider faces: not computed)" % [
				type, kit, tn, tf, _overshoot(near, solids)[0], _overshoot(far, solids)[0], WorldKitMeshes.swap_m(type)])
	print("M2W1_KIT types without a far mesh: ", without)


# --- the switch, the fallback, the loader ---

func test_switch_off_builds_todays_kit_looks() -> void:
	_reset()
	WorldKitMeshes.enabled_override = 0
	for type: String in _types():
		assert_eq(WorldKit.mesh_for(type).surface_get_arrays(0), WorldKit.build_mesh(_kit_types()[type]).surface_get_arrays(0), type + ": off = the kit mesh")
		assert_true(WorldKit.lod_for(type).is_empty(), type + ": off = no far LOD")
	WorldKitMeshes.enabled_override = 1
	WorldKit.clear_mesh_cache()
	for type: String in _types():
		assert_true(WorldKit.mesh_for(type) == WorldKitMeshes.mesh(type, 0), type + ": on = the glb near mesh")
		if not WorldKitMeshes.has_lod1(type):
			assert_true(WorldKit.lod_for(type).is_empty(), type + ": on, no far mesh listed = no far LOD")
			continue
		assert_true(WorldKit.mesh_for(type + "_lod1") == WorldKitMeshes.mesh(type, 1), type + ": on = the glb far mesh for <type>_lod1")
		assert_eq(WorldKit.lod_for(type).size(), 2, type + ": on = a far LOD")
	_reset()


func test_missing_entry_glb_or_node_falls_back_to_the_kit_with_one_error() -> void:
	_reset()
	var lines: Array[String] = []
	WorldKitMeshes.error_sink = func(message: String) -> void: lines.append(message)
	WorldKitMeshes.enabled_override = 1
	# M2W1 item 2: every structure type has an entry now, so the entry is taken out of a stand-in config.
	var bare := _cfg().duplicate(true)
	(bare["types"] as Dictionary).erase("column")
	WorldKitMeshes.config_override = bare
	WorldKitMeshes.clear_cache()
	assert_true(WorldKitMeshes.mesh("column", 0) == null, "a type without an entry: no glb mesh")
	assert_true(WorldKitMeshes.mesh("column", 0) == null and lines.size() == 1, "reported once: %s" % str(lines))
	var cfg := _cfg().duplicate(true)
	var type := "wall_walk"
	cfg["types"][type]["node"] = "no_such_node"
	cfg["types"][type]["lod1_node"] = "no_such_node_lod1"
	WorldKitMeshes.config_override = cfg
	WorldKitMeshes.clear_cache()
	WorldKit.clear_mesh_cache()
	lines.clear()
	assert_eq(WorldKit.mesh_for(type).surface_get_arrays(0), WorldKit.build_mesh(_kit_types()[type]).surface_get_arrays(0), type + ": a missing node falls back to the kit mesh")
	WorldKit.mesh_for(type)
	assert_eq(lines.size(), 1, "one error line for the missing node: %s" % str(lines))
	assert_true(WorldKit.lod_for(type).is_empty(), "no far LOD without the glb meshes")
	cfg["types"][type]["node"] = type
	cfg["glb"] = "res://assets/generated/world/no_such_file.glb"
	WorldKitMeshes.config_override = cfg
	WorldKitMeshes.clear_cache()
	WorldKit.clear_mesh_cache()
	lines.clear()
	assert_eq(WorldKit.mesh_for(type).surface_get_arrays(0), WorldKit.build_mesh(_kit_types()[type]).surface_get_arrays(0), type + ": a missing glb falls back to the kit mesh")
	assert_eq(lines.size(), 1, "one error line for the missing glb: %s" % str(lines))
	_reset()


func test_loader_is_deterministic() -> void:
	_reset()
	for type: String in _types():
		var a := WorldKitMeshes.mesh(type, 0).surface_get_arrays(0)
		WorldKitMeshes.clear_cache()
		var b := WorldKitMeshes.mesh(type, 0).surface_get_arrays(0)
		assert_eq(a, b, type + ": the same arrays after a fresh load")
	_reset()


func test_a1_props_use_imported_meshes_without_changing_palette_arrays() -> void:
	_reset()
	var old_envelopes := {"forum_stall": Vector3(3.58, 2.95, 3.15), "farm_cart": Vector3(2.87, 1.21, 1.66)}
	for type: String in old_envelopes:
		var row := WorldKitMeshes.entry(type)
		var path := "res://assets/generated/world/a1_%s.glb" % type
		assert_eq(String(row["glb"]), path, type + ": separate repainted glTF")
		assert_true(bool(row.get("textured", false)), type + ": uses its imported material")
		assert_true(WorldKit.config()["types"][type]["colliders"].size() <= 8, type + ": up to eight fitted boxes")
		for level: int in [0, 1]:
			var node := String(row["node"] if level == 0 else row["lod1_node"])
			var source := WorldKitMeshes._source_mesh(path, node)
			var mesh := WorldKitMeshes.mesh(type, level)
			assert_true(mesh != null and mesh == source, "%s %d: original imported mesh" % [type, level])
			if mesh == null:
				continue
			var bounds := mesh.get_aabb()
			var ratio: Vector3 = bounds.size / old_envelopes[type]
			for axis in 3:
				assert_true(absf(ratio[axis] - 1.0) <= 0.2, "%s %d: axis %d remains in the original 20%% envelope" % [type, level, axis])
			var center := bounds.get_center()
			assert_true(absf(center.x) < 0.02 and absf(center.z) < 0.02 and absf(bounds.position.y) < 0.02, type + ": centered on its original ground origin")
	# Pinned at f50f96a (pre-A1): sha256 of var_to_bytes(surface_get_arrays) over every surface. wall_walk comes from
	# the default glb, waystation from m2cx2_dressing.glb (the glb A1 retired nodes from).
	var pinned := {
		"wall_walk": ["8196cd1476599bc04af1c820a3af0329b561650e9b21263ea578ac2fdbd222f2", "10ee1f64aeb1ce02fba68b060afb0455ae51c19822e5257d0ba0fe93c9d822a5"],
		"waystation": ["696422cae54757c55b8ae743232c0223fc4532ce2ed9ad504038b2e386c51dac", "1a456ca252add23237cc49fb7c3a530ff9a16aca146dd32661aeca7ea1c4cbfd"],
	}
	for type: String in pinned:
		for level: int in [0, 1]:
			var built := WorldKitMeshes.mesh(type, level)
			assert_true(built != null, "%s %d: still built" % [type, level])
			if built == null:
				continue
			var ctx := HashingContext.new()
			ctx.start(HashingContext.HASH_SHA256)
			for s in built.get_surface_count():
				ctx.update(var_to_bytes(built.surface_get_arrays(s)))
			assert_eq(ctx.finish().hex_encode(), String(pinned[type][level]), "%s %d: arrays byte-identical to f50f96a" % [type, level])
	_reset()


# --- M2W1 astraA: the cover looks (F4) and the baked shade (F5) ---

## The looks to check: every cover entry on its cover-file type box, and the props.json looks of the breakables
## (on the generator's box of their type) and of the chest (on look_size): [name, mesh, box size, fit limit, opaque
## inset, triangle cap].
func _cover_cases() -> Array:
	var out: Array = []
	var tol := float(_cfg()["fit_tolerance_m"])
	var caps: Dictionary = _cfg()["budgets"]["cover_tris"]
	var defaults: Dictionary = _cfg()["cover_defaults"]
	var cover_file: Dictionary = DataRegistry.parse_quiet("res://data/maps/alesia_cover.json")["types"]
	for type: String in _cover_types():
		var e: Dictionary = _cfg()["cover"][type]
		var inset := float(e.get("opaque_inset_m", WorldKitMeshes.cover_entry(String(e.get("same_as", type))).get("opaque_inset_m", defaults["opaque_inset_m"])))
		out.append([type, WorldKitMeshes.cover_mesh(type), LowpolyKit.vec(cover_file[type]["size"]), tol, inset, int(caps.get(type, caps["default"]))])
	var props := WorldProps.config()
	var gen_types: Dictionary = DataRegistry.parse_quiet(MAP_1KM)["generator"]["props"]["types"]
	var exceptions: Dictionary = defaults["prop_fit_exceptions"]
	var insets: Dictionary = defaults["prop_opaque_inset_m"]
	for type: String in props["breakables"]:
		var name := "breakables." + type
		out.append([name, WorldKitMeshes.parts_mesh(props["breakables"][type]["look"]["parts"], WorldKitMeshes.kit_custom(type, true)),
				LowpolyKit.vec(gen_types[type]["size"]), tol, float(insets.get(name, defaults["opaque_inset_m"])), int(caps["default"])])
	for key: String in ["look_closed", "look_open"]:
		var name := "chest." + key
		out.append([name, WorldKitMeshes.parts_mesh(props["chest"][key]["parts"], WorldKitMeshes.kit_custom(name, true)),
				LowpolyKit.vec(props["chest"]["look_size"]), float(exceptions.get(name, tol)), float(insets.get(name, defaults["opaque_inset_m"])), int(caps["default"])])
	return out


## Whether a ray from `from` along `dir` hits any triangle of the arrays.
static func _ray_hits(verts: PackedVector3Array, indices: PackedInt32Array, from: Vector3, dir: Vector3) -> bool:
	var count := indices.size() if not indices.is_empty() else verts.size()
	for t in count / 3:
		var a := verts[indices[t * 3]] if not indices.is_empty() else verts[t * 3]
		var b := verts[indices[t * 3 + 1]] if not indices.is_empty() else verts[t * 3 + 1]
		var c := verts[indices[t * 3 + 2]] if not indices.is_empty() else verts[t * 3 + 2]
		if Geometry3D.ray_intersects_triangle(from, dir, a, b, c) != null:
			return true
	return false


## Every cover look (art_world_kit.json cover, F4) and the props.json breakable and chest looks: one surface with the
## shared material and CUSTOM0 (cover variation weight, shade range); within the triangle cap; every vertex within
## fit_tolerance_m of the one box (the open chest's lid: its named prop_fit_exceptions entry); the base on the box
## bottom (at most base_sink_m below, never floating); palette paints, UV2 as the shader reads it; and no
## see-through gap: rays along x and along z through the box, on a grid inside opaque_inset_m of its faces, all hit
## the look. Reports the triangles, the overshoot and the inset per side.
func test_cover_looks_fit_their_one_box() -> void:
	_reset()
	var sink := float(_cfg()["cover_defaults"]["base_sink_m"])
	var range_m := float(_cfg()["shade_bake"]["shade_range"])
	var order: Array = WorldSurface.config()["surface_order"]
	var palette: Array[Color] = []
	var colors: Dictionary = LowpolyKit.config()["colors"]
	for key: String in colors:
		if not key.begins_with("_"):
			palette.append(GreyboxArt.color_value(colors[key]))
	var cases := _cover_cases()
	assert_true(cases.size() >= 18,"nonvacuous: cover and prop looks listed (%d)" % cases.size())
	var exceptions := 0
	for c: Array in cases:
		var type: String = c[0]
		var mesh: ArrayMesh = c[1]
		var size: Vector3 = c[2]
		var limit: float = c[3]
		assert_true(mesh != null, type + ": the parts look builds")
		if mesh == null:
			continue
		if limit > float(_cfg()["fit_tolerance_m"]):
			exceptions += 1
		assert_true(mesh.get_surface_count() == 1 and mesh.surface_get_material(0) == WorldKit.material(), type + ": one surface, the shared material")
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0] if arrays[Mesh.ARRAY_CUSTOM0] != null else PackedFloat32Array()
		assert_true(custom.size() == verts.size() * 4 and is_equal_approx(custom[1], range_m), type + ": CUSTOM0 carries the shade range")
		var tris := Perf.triangles(mesh)
		assert_true(tris <= int(c[5]), "%s: %d triangles within %d" % [type, tris, c[5]])
		var half := size * 0.5
		var worst := 0.0
		var lo := Vector3.INF
		var hi := -Vector3.INF
		for v: Vector3 in verts:
			var d := Vector3(maxf(absf(v.x) - half.x, 0.0), maxf(absf(v.y) - half.y, 0.0), maxf(absf(v.z) - half.z, 0.0))
			worst = maxf(worst, d.length())
			lo = lo.min(v)
			hi = hi.max(v)
		assert_true(worst <= limit + 1e-4, "%s: every vertex within %.2f m of the box (worst %.3f)" % [type, limit, worst])
		assert_true(lo.y <= -half.y + 0.005 and lo.y >= -half.y - sink - 1e-4, "%s: the base on the box bottom (lowest %.3f, bottom %.3f, sink at most %.2f)" % [type, lo.y, -half.y, sink])
		var bad := 0
		var worst_c := 0.0
		for uv2: Vector2 in arrays[Mesh.ARRAY_TEX_UV2]:
			if absf(uv2.x - roundf(uv2.x)) > 1e-4 or uv2.x < 0.0 or uv2.x >= float(order.size()) or uv2.y < 0.0 or uv2.y > 1.0:
				bad += 1
		for col: Color in arrays[Mesh.ARRAY_COLOR]:
			var best := INF
			for p in palette:
				best = minf(best, maxf(maxf(absf(col.r - p.r), absf(col.g - p.g)), maxf(absf(col.b - p.b), absf(col.a - p.a))))
			worst_c = maxf(worst_c, best)
		assert_eq(bad, 0, type + ": UV2.x a surface id, UV2.y a shade 0..1")
		assert_true(worst_c <= 1.0 / 255.0 + 1e-6, "%s: palette paints (worst %.5f)" % [type, worst_c])
		# no see-through gap: a 9 x 7 grid of rays along x and along z inside the opaque inset (y up to the box top
		# less the inset; the open chest: up to its body)
		var inset: float = c[4]
		var misses := 0
		var rays := 0
		var first_miss := ""
		var top := half.y - inset if limit <= float(_cfg()["fit_tolerance_m"]) else 0.1
		for axis in 2:
			var across := half.z if axis == 0 else half.x
			for i in 9:
				for j in 7:
					var u := lerpf(-across + inset, across - inset, i / 8.0)
					var y := lerpf(-half.y + inset, top, j / 6.0)
					var from := Vector3(-half.x - 1.0, y, u) if axis == 0 else Vector3(u, y, -half.z - 1.0)
					var dir := Vector3.RIGHT if axis == 0 else Vector3.BACK
					rays += 1
					if not _ray_hits(verts, indices, from, dir):
						misses += 1
						first_miss = "%s along %s" % [from, dir] if first_miss == "" else first_miss
		assert_eq(misses, 0, "%s: rays along x and z inside %.2f m of the faces all hit (%d of %d miss; first %s)" % [type, inset, misses, rays, first_miss])
		print("M2W1_COVER_REPORT type=%s tris=%d overshoot=%.3f limit=%.2f inset -x=%.2f +x=%.2f top=%.2f -z=%.2f +z=%.2f base=%.3f opaque_inset=%.2f misses=%d/%d" % [
				type, tris, worst, limit, lo.x + half.x, half.x - hi.x, half.y - hi.y, lo.z + half.z, half.z - hi.z, lo.y + half.y, inset, misses, rays])
	assert_eq(exceptions, 1, "one named fit exception (the open chest's lid)")
	_reset()


## The switch: off = no parts look (astra_map keeps LowpolyKit.build_cover, the props looks too); on = the parts
## look; a type without an entry keeps its kit look without an error line; same_as / swap_xz; deterministic; the
## data names no glb node for cover (the glb is unchanged).
func test_cover_switch_and_fallback() -> void:
	_reset()
	var lines: Array[String] = []
	WorldKitMeshes.error_sink = func(message: String) -> void: lines.append(message)
	WorldKitMeshes.enabled_override = 0
	assert_true(WorldKit.cover_mesh("crate") == null, "off: no parts look")
	assert_true(WorldKit.prop_look("breakable_crate", [{"size": [1, 1, 1], "at": [0, 0, 0], "color": "dark"}]) == null, "off: the props looks stay LowpolyKit's")
	WorldKitMeshes.enabled_override = 1
	assert_true(WorldKit.cover_mesh("crate") != null, "on: the parts look")
	assert_true(WorldKit.cover_mesh("wreck_apc") == null, "a type without an entry keeps its kit look")
	assert_eq(lines.size(), 0, "no error line: %s" % str(lines))
	# M2W1 r2a: an entry names parts (built at load) or a glb node, never both; the glb ones load as one surface
	var glb_looks := 0
	for type: String in _cover_types():
		var e: Dictionary = _cfg()["cover"][type]
		assert_true(not (e.has("node") and e.has("parts")), type + ": parts or a glb node, not both")
		if WorldKitMeshes.cover_node(type) != "":
			glb_looks += 1
			assert_true(WorldKitMeshes.cover_mesh(type) != null and WorldKitMeshes.cover_mesh(type).resource_name == "M2W1_cover_" + type, type + ": the glb look loads")
	assert_true(glb_looks >= 4, "nonvacuous: the sandbags, nests and cart are glb looks (%d)" % glb_looks)
	var a := WorldKitMeshes.cover_mesh("sandbags").get_aabb()
	var b := WorldKitMeshes.cover_mesh("sandbag_nest_side").get_aabb()
	assert_true(Vector3(a.size.z, a.size.y, a.size.x).is_equal_approx(b.size), "swap_xz: the side piece is the sandbags turned (%s / %s)" % [a, b])
	assert_true(WorldKitMeshes.cover_mesh("sandbag_nest") != null and WorldKitMeshes.cover_mesh("sandbag_nest").get_aabb().is_equal_approx(a), "same_as: the nest is the sandbags")
	var first := WorldKitMeshes.cover_mesh("barrier").surface_get_arrays(0)
	WorldKitMeshes.clear_cache()
	assert_eq(WorldKitMeshes.cover_mesh("barrier").surface_get_arrays(0), first, "deterministic")
	# a part's "shade" is its value multiplier over the shade range; a part without one keeps its kit shade
	var range_m := float(_cfg()["shade_bake"]["shade_range"])
	var part := {"shape": "taper", "top": [1, 1], "bevel": 0, "size": [1, 1, 1], "at": [0, 0, 0], "color": "rock"}
	var shaded := part.duplicate()
	shaded["shade"] = 0.7
	var uv_plain: PackedVector2Array = LowpolyKit.merge([part]).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var uv_kit: PackedVector2Array = WorldKitMeshes.parts_mesh([part], Vector4(0, range_m, 0, 0)).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var uv_shaded: PackedVector2Array = WorldKitMeshes.parts_mesh([shaded], Vector4(0, range_m, 0, 0)).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	assert_true(is_equal_approx(1.0 + (uv_shaded[0].y - 0.5) * 2.0 * range_m, 0.7), "shade 0.7 draws at 0.7")
	assert_true(is_equal_approx(1.0 + (uv_kit[0].y - 0.5) * 2.0 * range_m, 1.0 + (uv_plain[0].y - 0.5) * 2.0 * 0.08), "no shade: the kit shade at part_shade, as the old path drew it")
	_reset()


## M2W1 astraA (F5): the load-time shade bake of the glb meshes. Off (shade_bake.enabled false): every mesh keeps the
## glb's UV2 and has no shade range (the shader's old path). On: the shade range in CUSTOM0.y, the glow paints keep
## their part shade, the base course is darker than the marble trim, faces looking down darker than faces looking
## up, near and far meshes of a type get the same CUSTOM0 (variation weight), and the summit types are brighter.
func test_shade_bake_off_keeps_the_old_values_and_on_separates_values() -> void:
	_reset()
	WorldKitMeshes.enabled_override = 1
	var off := _cfg().duplicate(true)
	off["shade_bake"]["enabled"] = false
	WorldKitMeshes.config_override = off
	WorldKitMeshes.clear_cache()
	var glb := String(_cfg()["glb"])
	for type: String in _types():
		if bool(WorldKitMeshes.entry(type).get("textured", false)):
			continue
		for level: int in _levels(type):
			var e: Dictionary = _cfg()["types"][type]
			var source := WorldKitMeshes._source_mesh(String(e.get("glb", glb)), String(e["node"] if level == 0 else e["lod1_node"]))
			var arrays := WorldKitMeshes.mesh(type, level).surface_get_arrays(0)
			assert_eq(arrays[Mesh.ARRAY_TEX_UV2], source.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2], "%s %d: off = the glb's UV2" % [type, level])
			var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0] if arrays[Mesh.ARRAY_CUSTOM0] != null else PackedFloat32Array([0, 0, 0, 0])
			assert_true(custom[1] == 0.0, "%s %d: off = no shade range (the shader's part_shade and grime)" % [type, level])
	WorldKitMeshes.config_override = {}
	WorldKitMeshes.clear_cache()
	var b: Dictionary = _cfg()["shade_bake"]
	var range_m := float(b["shade_range"])
	var mean := {}
	for type: String in _types():
		if bool(WorldKitMeshes.entry(type).get("textured", false)):
			continue
		var weights := []
		for level: int in _levels(type):
			var arrays := WorldKitMeshes.mesh(type, level).surface_get_arrays(0)
			var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
			assert_true(is_equal_approx(custom[1], range_m) and is_equal_approx(custom[2], float(b["grime"])), "%s %d: CUSTOM0 = (weight, range, grime)" % [type, level])
			weights.append(custom[0])
			if level != 0:
				continue
			var entry: Dictionary = _cfg()["types"][type]
			var source_path := String(entry.get("glb", glb))
			var src: PackedVector2Array = WorldKitMeshes._source_mesh(source_path, String(entry["node"])).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
			var sum := 0.0
			for i in (arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size():
				var m: float = 1.0 + (arrays[Mesh.ARRAY_TEX_UV2][i].y - 0.5) * 2.0 * range_m
				var paint := WorldKitMeshes.paint_of(arrays[Mesh.ARRAY_COLOR][i])
				if (b["skip_paints"] as Array).has(paint):
					assert_true(absf(m - (1.0 + (src[i].y - 0.5) * 2.0 * float(b["part_shade"]))) < 0.002, "%s: %s keeps its part shade" % [type, paint])
				sum += m
			mean[type] = sum / maxf(float(src.size()), 1.0)
		assert_true(weights.size() < 2 or weights[0] == weights[1], type + ": near and far share the variation weight")
	# value separation on the wall: rock (base course) < travertine < marble; down faces < up faces
	var arrays := WorldKitMeshes.mesh("wall_walk", 0).surface_get_arrays(0)
	var by_paint := {}
	var up := [0.0, 0]
	var down := [0.0, 0]
	for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		var m: float = 1.0 + (arrays[Mesh.ARRAY_TEX_UV2][i].y - 0.5) * 2.0 * range_m
		var paint := WorldKitMeshes.paint_of(arrays[Mesh.ARRAY_COLOR][i])
		var acc: Array = by_paint.get(paint, [0.0, 0])
		by_paint[paint] = [acc[0] + m, acc[1] + 1]
		var n: Vector3 = arrays[Mesh.ARRAY_NORMAL][i]
		if n.y > 0.7 and arrays[Mesh.ARRAY_VERTEX][i].y > 1.0:
			up = [up[0] + m, up[1] + 1]
		elif n.y < -0.7:
			down = [down[0] + m, down[1] + 1]
	var avg := func(k: String) -> float: return by_paint[k][0] / by_paint[k][1]
	assert_true(avg.call("rock") < avg.call("travertine") and avg.call("travertine") < avg.call("marble"), "wall: rock %.3f < travertine %.3f < marble %.3f" % [avg.call("rock"), avg.call("travertine"), avg.call("marble")])
	assert_true(down[0] / down[1] < up[0] / up[1] - 0.2, "wall: faces looking down %.3f clearly darker than tops %.3f" % [down[0] / down[1], up[0] / up[1]])
	print("M2W1_BAKE_REPORT mean m per type: ", mean, " wall paints: ", by_paint)
	_reset()


## The shader stays the old one for every mesh without CUSTOM0 (soldier-free users: kit meshes, doors, ladders):
## the variation uniforms default to 0 and the new path is taken only when CUSTOM0.y > 0.
func test_shader_defaults_leave_other_meshes_unchanged() -> void:
	var code: String = load(WorldSurface.SHADER_PATH).code
	for line in ["uniform float variation_value = 0.0;", "uniform float variation_warm = 0.0;", "uniform float variation_broad = 0.0;", "bool kit = CUSTOM0.y > 0.0;",
			"v_grime = kit ? CUSTOM0.z : 1.0;", "if (CUSTOM0.x > 0.0) {", "vec3 origin = MODEL_MATRIX[3].xyz;"]:
		assert_true(code.contains(line), "shader: " + line)
	assert_true(is_equal_approx(float(_cfg()["shade_bake"]["part_shade"]), 0.08) and code.contains("uniform float part_shade = 0.08;"), "the bake's part shade is the shader's")
	var kit_mesh := LowpolyKit.build_cover({"kind": "crate", "size": [1.3, 1.2, 1.3]})
	assert_true(kit_mesh.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0] == null, "kit meshes carry no CUSTOM0 (old path)")
	# the variation uniforms: zero when the looks are off, the data's values when on
	var made := ShaderMaterial.new()
	made.shader = load(WorldSurface.SHADER_PATH)
	WorldKit.apply_variation(made, false)
	for u: String in ["variation_value", "variation_warm", "variation_broad"]:
		assert_true(float(made.get_shader_parameter(u)) == 0.0, u + ": off = 0")
	WorldKit.apply_variation(made, true)
	assert_true(is_equal_approx(float(made.get_shader_parameter("variation_value")), float(_cfg()["variation"]["value"])), "on = the data's value")
	# the variation input is the instance origin only (no vertex position), so near and far of one piece match
	var hash_block := code.substr(code.find("if (CUSTOM0.x > 0.0) {"), code.find("v_world = ") - code.find("if (CUSTOM0.x > 0.0) {"))
	assert_true(not hash_block.contains("VERTEX") and hash_block.contains("origin"), "the variation hashes the instance origin only")


## On the built 1 km map the cover batches draw the parts looks (types with an entry), the breakables and chests
## their props.json looks with the cover vertex data.
func test_built_map_draws_the_cover_looks() -> void:
	_reset()
	var map := _map_1km()
	var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
	var seen := {}
	for batch in chunks.batches("cover"):
		var type := String(batch.get_meta(&"type", ""))
		if type == "" or not WorldKitMeshes.enabled():
			continue
		var name := String(batch.multimesh.mesh.resource_name)
		if (_cfg()["cover"] as Dictionary).has(type):
			assert_true(name == "M2W1_cover_" + type, "%s: the parts look (%s)" % [type, name])
		elif type.begins_with("breakable_") or type.begins_with("loot_chest"):
			assert_true(name.begins_with("M2W1_prop_"), "%s: the props look with the cover vertex data (%s)" % [type, name])
		else:
			continue
		seen[type] = true
	assert_true(seen.size() >= 12, "nonvacuous: cover types on the 1 km map with parts looks: %s" % str(seen.keys()))
	var tris := 0
	for batch in chunks.batches("cover") + chunks.batches("ring"):
		tris += Perf.triangles(batch.multimesh.mesh) * batch.multimesh.instance_count
	print("M2W1_COVER_MAP types=%s cover_and_ring_tris_total=%d" % [str(seen.keys()), tris])


func _map_1km() -> Node3D:
	if not is_instance_valid(_built):
		var def := DataRegistry.parse_quiet(MAP_1KM)
		_built = load(String(def["scene"])).instantiate()
		_built.get_node("ArtBuilder").set("map_json", MAP_1KM)
		(Engine.get_main_loop() as SceneTree).root.add_child(_built)
	return _built


# --- MapChunks LOD pairs ---

func _lod_stage(enabled: int) -> Node3D:
	WorldKitMeshes.enabled_override = enabled
	WorldKit.clear_mesh_cache()
	var root := Node3D.new()
	root.name = "M2W1LodStage"
	root.position = Vector3(0, 0, -6000)
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	var builder := Node3D.new()
	builder.name = "ArtBuilder"
	root.add_child(builder)
	var chunks := MapChunks.new()
	chunks.name = "Chunks"
	builder.add_child(chunks)
	var nav := Node3D.new()
	nav.name = "Nav"
	root.add_child(nav)
	chunks.setup(0.0)
	var pieces: Array = []
	for i in _types().size():
		pieces.append({"id": "P%d" % i, "type": _types()[i], "at": [i * 20.0, 0.0, 0.0], "yaw": 0.0})
	WorldKit.populate(nav, chunks, pieces)
	chunks.build()
	return root


func test_lod_pairs_swap_once_at_the_same_centre() -> void:
	_reset()
	var classes: Dictionary = MapChunks.config()["classes"]
	var margin := float(classes["margin_m"])
	var root := _lod_stage(1)
	var chunks := root.get_node("ArtBuilder/Chunks") as MapChunks
	for type: String in _types():
		var near := chunks.get_node_or_null("Chunk_0_0/Batch_structure_" + type) as MultiMeshInstance3D
		var far := chunks.get_node_or_null("Chunk_0_0/Batch_structure_%s_lod1" % type) as MultiMeshInstance3D
		if not WorldKitMeshes.has_lod1(type):
			# M2W1 item 2: a type without a far mesh draws one batch to its class range
			assert_true(near != null and far == null, type + ": one batch, no far batch")
			if near != null:
				assert_true(near.visibility_range_begin == 0.0 and not near.has_meta(&"lod_swap_m"), type + ": not part of a LOD pair")
				assert_true(near.multimesh.mesh == WorldKitMeshes.mesh(type, 0), type + ": the glb near mesh")
			continue
		assert_true(near != null and far != null, type + ": a near and a far batch")
		if near == null or far == null:
			continue
		var radius := float(near.get_meta(&"radius_m"))
		var range_m := float(near.get_meta(&"range_m"))
		var swap := WorldKitMeshes.swap_m(type)
		var e := MapChunks.range_end_for(swap, radius, margin)
		assert_true(is_equal_approx(near.visibility_range_end, e) and near.visibility_range_begin == 0.0, type + ": near ends at swap + radius + margin")
		assert_true(is_equal_approx(far.visibility_range_begin, e) and is_equal_approx(far.visibility_range_begin_margin, margin), type + ": far begins there")
		assert_true(is_equal_approx(far.visibility_range_end, MapChunks.range_end_for(range_m, radius, margin)), type + ": far ends at the class range")
		assert_true(range_m >= float(classes["sight_floor_m"]), type + ": the pair keeps the sight floor")
		assert_true(MapChunks.range_centre(near).is_equal_approx(MapChunks.range_centre(far)), type + ": both measure from the same centre")
		assert_true(far.multimesh.mesh == WorldKitMeshes.mesh(type, 1) and near.multimesh.mesh == WorldKitMeshes.mesh(type, 0), type + ": the glb meshes")
		if bool(WorldKitMeshes.entry(type).get("textured", false)):
			assert_true(near.material_override == null and far.material_override == null, type + ": batches keep the painted surfaces")
		assert_eq(far.cast_shadow, near.cast_shadow, type + ": the far batch casts like its class")
		assert_eq(String(far.get_meta(&"class")), String(near.get_meta(&"class")), type + ": the far batch has the near type's class")
		assert_eq(far.get_meta(&"transforms"), near.get_meta(&"transforms"), type + ": the same pieces")
		assert_eq(chunks.instance_total("structure", type), 1, type + ": counted once")
		# At most one of the pair, never neither, at any distance out to the class range.
		var centre := MapChunks.range_centre(near)
		var d := 0.0
		while d < far.visibility_range_end - 1.0:
			var point := centre + Vector3(d, 0.0, 0.0)
			var v := MapChunks.visible_at(root, point)
			var drawn := 0
			for batch: MultiMeshInstance3D in [near, far]:
				var dd := point.distance_to(MapChunks.range_centre(batch))
				if (batch.visibility_range_end <= 0.0 or dd <= batch.visibility_range_end) and (batch.visibility_range_begin <= 0.0 or dd >= batch.visibility_range_begin):
					drawn += 1
			assert_eq(drawn, 1, "%s: exactly one of the pair at %.0f m" % [type, d])
			assert_true(int(v["batches"]) >= 1, "visible_at counts a batch at %.0f m" % d)
			d += 7.0
	root.free()
	root = _lod_stage(0)
	chunks = root.get_node("ArtBuilder/Chunks") as MapChunks
	for batch in chunks.batches("structure"):
		assert_true(not String(batch.name).ends_with("_lod1"), "switch off: no far batches (%s)" % batch.name)
	root.free()
	_reset()


func test_visible_structure_triangles_at_the_1km_perf_points() -> void:
	_reset()
	var tree: SceneTree = Engine.get_main_loop()
	if not is_instance_valid(_built):
		var def := DataRegistry.parse_quiet(MAP_1KM)
		_built = load(String(def["scene"])).instantiate()
		_built.get_node("ArtBuilder").set("map_json", MAP_1KM)
		tree.root.add_child(_built)
	var map := _built
	var terrain: MapTerrain = map.get_node("ArtBuilder").terrain
	var Gen := preload("res://tools/gen_alesia.gd")
	var gate := Gen.dir_of(0.0) * float(DataRegistry.parse_quiet(MAP_1KM)["generator"]["outer_wall"]["radius_m"])
	var points := {
		"citadel_top": Vector3(0.0, terrain.height_at(0.0, 5.0) + MapChunks.EYE_M, 5.0),
		"porta_aquilae": Vector3(gate.x, terrain.height_at(gate.x, gate.y) + MapChunks.EYE_M, gate.y),
		"field_corner": MapChunks.standard_points(map)["corner"],
		"centre_standard": MapChunks.standard_points(map)["centre"],
	}
	var cap := int(_cfg()["budgets"]["visible_structure_tris"])
	var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
	for point_name: String in points:
		var p: Vector3 = points[point_name]
		var tris := 0
		var near_b := 0
		var far_b := 0
		for batch in chunks.batches("structure"):
			var d := p.distance_to(MapChunks.range_centre(batch))
			if not batch.visible or (batch.visibility_range_end > 0.0 and d > batch.visibility_range_end) or (batch.visibility_range_begin > 0.0 and d < batch.visibility_range_begin):
				continue
			tris += Perf.triangles(batch.multimesh.mesh) * batch.multimesh.instance_count
			if int(batch.get_meta(&"lod_level", 0)) == 1:
				far_b += 1
			elif batch.has_meta(&"lod_level"):
				near_b += 1
		assert_true(tris <= cap, "%s: %d structure triangles in range, cap %d" % [point_name, tris, cap])
		print("M2W1_KIT_VISIBLE point=%s structure_tris=%d near_batches=%d far_batches=%d (cap %d; frustum ignored)" % [point_name, tris, near_b, far_b, cap])


## Last in this file: frees the 1 km map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	_reset()
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
