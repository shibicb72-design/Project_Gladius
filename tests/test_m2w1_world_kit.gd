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


func _kit_types() -> Dictionary:
	return WorldKit.config()["types"]


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
	for type: String in _types():
		assert_true(_kit_types().has(type), type + ": a world kit type")
		for level in 2:
			var tag := "%s level %d" % [type, level]
			var mesh := WorldKitMeshes.mesh(type, level)
			assert_true(mesh != null, tag + ": loads")
			if mesh == null:
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


func test_glb_holds_exactly_the_listed_nodes() -> void:
	_reset()
	var glb := String(_cfg()["glb"])
	var scene: PackedScene = load(glb)
	assert_true(scene != null, "the glb imports: " + glb)
	if scene == null:
		return
	var root := scene.instantiate()
	var names := {}
	for node: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		names[String(node.name)] = node.mesh.get_surface_count()
	root.free()
	var wanted := {}
	for type: String in _types():
		wanted[String(_cfg()["types"][type]["node"])] = true
		wanted[String(_cfg()["types"][type]["lod1_node"])] = true
	for node_name: String in wanted:
		assert_true(names.has(node_name), "glb has node " + node_name)
		assert_eq(int(names.get(node_name, 0)), 1, node_name + ": one surface")
	for node_name: String in names:
		assert_true(wanted.has(node_name), "glb node %s is listed in art_world_kit.json" % node_name)
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
	for type: String in _types():
		var def: Dictionary = _kit_types()[type]
		var solids := _solids(def)
		for level in 2:
			var mesh := WorldKitMeshes.mesh(type, level)
			if mesh == null:
				assert_true(false, "%s level %d: no mesh" % [type, level])
				continue
			var tag := "%s level %d" % [type, level]
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


func test_budgets_and_report() -> void:
	_reset()
	var budgets: Dictionary = _cfg()["budgets"]
	var lod1_max := int(_cfg()["lod1_max_tris"])
	for type: String in _types():
		var near := WorldKitMeshes.mesh(type, 0)
		var far := WorldKitMeshes.mesh(type, 1)
		if near == null or far == null:
			assert_true(false, type + ": meshes missing")
			continue
		var tn := Perf.triangles(near)
		var tf := Perf.triangles(far)
		var kit := Perf.triangles(WorldKit.build_mesh(_kit_types()[type]))
		assert_true(budgets["near_tris"].has(type) and tn <= int(budgets["near_tris"][type]), "%s: near %d triangles within %s" % [type, tn, budgets["near_tris"].get(type)])
		assert_true(budgets["lod1_tris"].has(type) and tf <= int(budgets["lod1_tris"][type]) and tf <= lod1_max, "%s: far %d triangles within %s and %d" % [type, tf, budgets["lod1_tris"].get(type), lod1_max])
		assert_true(tf < tn, type + ": the far mesh is lighter")
		var solids := _solids(_kit_types()[type])
		print("M2W1_KIT_REPORT type=%s kit_tris=%d near_tris=%d far_tris=%d near_overshoot=%.3f far_overshoot=%.3f swap_m=%.0f (uncovered collider faces: not computed)" % [
				type, kit, tn, tf, _overshoot(near, solids)[0], _overshoot(far, solids)[0], WorldKitMeshes.swap_m(type)])


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
		assert_true(WorldKit.mesh_for(type + "_lod1") == WorldKitMeshes.mesh(type, 1), type + ": on = the glb far mesh for <type>_lod1")
		assert_eq(WorldKit.lod_for(type).size(), 2, type + ": on = a far LOD")
	_reset()


func test_missing_entry_glb_or_node_falls_back_to_the_kit_with_one_error() -> void:
	_reset()
	var lines: Array[String] = []
	WorldKitMeshes.error_sink = func(message: String) -> void: lines.append(message)
	WorldKitMeshes.enabled_override = 1
	assert_true(WorldKitMeshes.mesh("column", 0) == null, "a type without an entry: no glb mesh")
	assert_true(WorldKitMeshes.mesh("column", 0) == null and lines.size() == 1, "reported once: %s" % str(lines))
	var cfg := _cfg().duplicate(true)
	var type: String = _types()[0]
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
