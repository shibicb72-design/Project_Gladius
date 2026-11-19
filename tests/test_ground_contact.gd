extends "res://tests/test_case.gd"
## M2 L2a (OQ-ALESIA-500): does every drawn piece of a map touch the ground? Builds the map scene headless (as
## tests/test_alesia_1km.gd does, once per map, freed at the end of its method) and measures every visual a player can
## see standing on the ground: the chunk batches (structure near looks, cover, ring cover, decor, breakables, chests,
## clutter; far LOD batches and the hidden open-chest looks are skipped) and the Props node's own looks (door and gate
## leaves, ladders). A visual's bottom is the lowest corner of its mesh AABB under its instance transform; its
## footprint is that AABB's ground rectangle, sampled at the four corners, the four edge middles and the centre. At
## each sample the gap is bottom - ground: the largest positive gap is how far the piece floats, the largest negative
## one how deep it sinks. The backdrop's seam (its skirt against the ground square's edge) is reported when the map has
## a far backdrop block.
## alesia_500 ASSERTS terrain.max_visual_float_m (placeholder, OQ-ALESIA-500) on every piece; alesia_1km (read-only)
## only REPORTS. One line per map and family: GROUND_CONTACT map=<id> family=<f> n=<n> max_float_m=<x> max_sink_m=<y>,
## then the ten worst floating pieces per map.

const MAP_500 := "res://data/maps/alesia_500.json"
const MAP_1KM := "res://data/maps/alesia_1km.json"
const WORST := 10


func test_alesia_500_pieces_touch_the_ground() -> void:
	var def := DataRegistry.parse_quiet(MAP_500)
	var tol := float(def["terrain"]["max_visual_float_m"])
	var report := await _build_and_measure(MAP_500)
	var families: Dictionary = report["families"]
	assert_true(int((families["all"] as Dictionary)["n"]) > 1000, "nonvacuous: %d visuals measured" % int((families["all"] as Dictionary)["n"]))
	for key: String in ["structure", "cover", "ring", "decor", "props"]:
		assert_true(families.has(key), "the %s family is measured" % key)
	for key: String in ["floating", "far_floating"]:
		for piece: Array in report[key]:
			assert_true(float(piece[0]) <= tol, "%s %s floats %.3f m above the ground (max_visual_float_m %.2f)" % [piece[1], piece[2], float(piece[0]), tol])


func test_alesia_1km_report_only() -> void:
	var report := await _build_and_measure(MAP_1KM)
	assert_true(int((report["families"]["all"] as Dictionary)["n"]) > 2000, "nonvacuous")


## Builds the map, measures it, prints the report lines, frees it.
func _build_and_measure(path: String) -> Dictionary:
	var def := DataRegistry.parse_quiet(path)
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", path)
	tree.root.add_child(map)
	var report := contact_report(map, def)
	for line: String in report_lines(String(def["id"]), report):
		print(line)
	map.queue_free()
	await tree.process_frame
	await tree.process_frame
	return report


## The measure of a built map: {families: {family -> {n, max_float_m, max_sink_m}}, floating: [[float, family, where]]
## sorted worst first (every visual), backdrop: {} or {n, max_float_m, max_sink_m}}. Families: "<source>/<type>" and
## the totals "structure", "cover", "ring", "decor", "props", "clutter", "all".
static func contact_report(map: Node, def: Dictionary) -> Dictionary:
	var builder := map.get_node("ArtBuilder")
	var terrain: MapTerrain = builder.get("terrain")
	var chunks: MapChunks = builder.get("chunks")
	var ids := _ids_by_spot(def)
	var families := {}
	var floating: Array = []
	# The ground at long range uses each chunk's actual far or full-resolution mesh.
	var far_families := {}
	var far_floating: Array = []
	var far_step := 0.0
	if terrain != null:
		far_step = float((def["terrain"] as Dictionary).get("far_step_m", MapChunks.config()["terrain"].get("far_step_m", 0.0)))
	var near_only := {}
	if far_step > 0.0:
		for iz in chunks.per_side:
			for ix in chunks.per_side:
				if builder.get_node_or_null("Terrain/Chunk_%d_%d/Far" % [ix, iz]) == null:
					near_only[Vector2i(ix, iz)] = true
	var step_at := func(p: Vector3) -> float:
		return 0.0 if near_only.has(chunks.index_of(p)) else far_step
	for batch: MultiMeshInstance3D in chunks.batches():
		if int(batch.get_meta(&"lod_level", 0)) == 1:
			continue  # the far look of a near piece
		var source := String(batch.get_meta(&"source", ""))
		var type := String(batch.get_meta(&"type", ""))
		if type == "loot_chest_open":
			continue  # hidden until the chest opens; the closed look stands on the same spot
		var top := source
		if source == "cover" and (type.begins_with("breakable_") or type == "loot_chest"):
			top = "props"
		var aabb := batch.multimesh.mesh.get_aabb()
		for xform: Transform3D in batch.get_meta(&"transforms"):
			var m := measure(terrain, xform, aabb)
			var where := "%s at (%.1f, %.1f, %.1f)" % [ids.get(_spot_key(xform.origin), type), xform.origin.x, xform.origin.y, xform.origin.z]
			_add(families, floating, [top + "/" + type, top, "all"], m, where)
			if far_step > 0.0 and source != "clutter":
				_add(far_families, far_floating, ["far/" + top], measure(terrain, xform, aabb, step_at), where)
	var props := builder.get_node_or_null("Props")
	if props != null:
		for node: Node in props.find_children("*", "MeshInstance3D", true, false):
			var owner_node := node.get_parent()
			while owner_node != null and not (owner_node is Door or owner_node is Ladder):
				owner_node = owner_node.get_parent()
			if owner_node == null:
				continue  # breakables draw as chunk instances
			var kind := ("props/" + String(owner_node.get("kind"))) if owner_node is Door else "props/ladder"
			var look := node as MeshInstance3D
			var m := measure(terrain, look.global_transform, look.mesh.get_aabb())
			var at := look.global_transform.origin
			_add(families, floating, [kind, "props", "all"], m, "%s at (%.1f, %.1f, %.1f)" % [String(owner_node.get("prop_id")), at.x, at.y, at.z])
	floating.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	far_floating.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	return {"families": families, "floating": floating, "backdrop": _backdrop_seam(builder, terrain),
		"far_families": far_families, "far_floating": far_floating, "far_step_m": far_step, "terrain_tris": terrain_tris(builder)}


## M2 L2a: the terrain's triangles as built (ArtBuilder/Terrain/Chunk_*/Mesh and Far): {chunks, near, far}.
static func terrain_tris(builder: Node) -> Dictionary:
	var out := {"chunks": 0, "near": 0, "far": 0}
	var root := builder.get_node_or_null("Terrain")
	if root == null:
		return out
	for chunk: Node in root.get_children():
		out["chunks"] = int(out["chunks"]) + 1
		for kind: String in ["Mesh", "Far"]:
			var node := chunk.get_node_or_null(kind) as MeshInstance3D
			if node == null or node.mesh == null:
				continue
			var n := 0
			for s in node.mesh.get_surface_count():
				var arrays := node.mesh.surface_get_arrays(s)
				var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				n += (idx.size() if idx.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			var key := "near" if kind == "Mesh" else "far"
			out[key] = int(out[key]) + n
	return out


## The far ground's height at (x, z): the terrain samples every `step_m` triangulated as MapTerrain._plane does
## (the inner coarse cells of far_chunk_mesh; a chunk's border fans are not modelled).
static func far_height(terrain: MapTerrain, x: float, z: float, step_m: float) -> float:
	var k := roundi(step_m / terrain.resolution_m)
	var half := terrain.size_m * 0.5
	var u := (clampf(x, -half, half) + half) / terrain.resolution_m
	var v := (clampf(z, -half, half) + half) / terrain.resolution_m
	var ix := clampi(floori(u / k) * k, 0, terrain.samples - 1 - k)
	var iz := clampi(floori(v / k) * k, 0, terrain.samples - 1 - k)
	var fx := (u - ix) / k
	var fz := (v - iz) / k
	var ha := terrain.sample(ix, iz)
	var hb := terrain.sample(ix + k, iz)
	var hc := terrain.sample(ix, iz + k)
	var hd := terrain.sample(ix + k, iz + k)
	if MapTerrain.SPLIT_ANTI_DIAGONAL:
		if fx + fz <= 1.0:
			return ha + (hb - ha) * fx + (hc - ha) * fz
		return hd - (hd - hc) * (1.0 - fx) - (hd - hb) * (1.0 - fz)
	if fx >= fz:
		return ha + (hb - ha) * fx + (hd - hb) * fz
	return ha + (hd - hc) * fx + (hc - ha) * fz


## One visual: {float, sink} of the AABB `aabb` (local) under `xform` against the terrain (null = flat 0), or against
## the far ground, using the render step at each sample when supplied.
static func measure(terrain: MapTerrain, xform: Transform3D, aabb: AABB, step_at := Callable()) -> Dictionary:
	var bottom := INF
	for i in 8:
		bottom = minf(bottom, (xform * aabb.get_endpoint(i)).y)
	var lo := aabb.position
	var hi := aabb.end
	var worst_float := -INF
	var worst_sink := -INF
	for u: float in [0.0, 0.5, 1.0]:
		for v: float in [0.0, 0.5, 1.0]:
			var p := xform * Vector3(lerpf(lo.x, hi.x, u), lo.y, lerpf(lo.z, hi.z, v))
			var ground := 0.0
			if terrain != null:
				var step_m: float = step_at.call(p) if step_at.is_valid() else 0.0
				ground = far_height(terrain, p.x, p.z, step_m) if step_m > 0.0 else terrain.height_at(p.x, p.z)
			worst_float = maxf(worst_float, bottom - ground)
			worst_sink = maxf(worst_sink, ground - bottom)
	return {"float": worst_float, "sink": worst_sink}


static func _add(families: Dictionary, floating: Array, keys: Array, m: Dictionary, where: String) -> void:
	for key: String in keys:
		if not families.has(key):
			families[key] = {"n": 0, "max_float_m": -INF, "max_sink_m": -INF}
		var f: Dictionary = families[key]
		f["n"] = int(f["n"]) + 1
		f["max_float_m"] = maxf(float(f["max_float_m"]), float(m["float"]))
		f["max_sink_m"] = maxf(float(f["max_sink_m"]), float(m["sink"]))
	floating.append([float(m["float"]), String(keys[0]), where])


## The backdrop's seam: its skirt height just outside the ground square's edge against the terrain just inside it,
## at 64 points per side ({} when the map has no far backdrop block or no backdrop).
static func _backdrop_seam(builder: Node, terrain: MapTerrain) -> Dictionary:
	var backdrop := builder.get_node_or_null("Backdrop")
	if backdrop == null or terrain == null or (backdrop.get("_far_cfg") as Dictionary).is_empty():
		return {}
	var half := terrain.size_m * 0.5
	var out := {"n": 0, "max_float_m": -INF, "max_sink_m": -INF}
	for side in 4:
		for k in 64:
			var t := lerpf(-half, half, (k + 0.5) / 64.0)
			var edge := [Vector2(t, -half), Vector2(half, t), Vector2(t, half), Vector2(-half, t)][side] as Vector2
			var outward := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][side] as Vector2
			var outside := edge + outward * 0.5
			var gap := float(backdrop.call("skirt_height", outside.x, outside.y)) - terrain.height_at(edge.x - outward.x * 0.01, edge.y - outward.y * 0.01)
			out["n"] = int(out["n"]) + 1
			out["max_float_m"] = maxf(float(out["max_float_m"]), gap)
			out["max_sink_m"] = maxf(float(out["max_sink_m"]), -gap)
	return out


## The report lines: one per family (totals first), the backdrop seam and the ten worst floating visuals.
static func report_lines(map_id: String, report: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var families: Dictionary = report["families"]
	var keys: Array = families.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ta := 0 if not a.contains("/") else 1
		var tb := 0 if not b.contains("/") else 1
		return ta < tb or (ta == tb and a < b))
	for key: String in keys:
		var f: Dictionary = families[key]
		lines.append("GROUND_CONTACT map=%s family=%s n=%d max_float_m=%.3f max_sink_m=%.3f" % [map_id, key, int(f["n"]), float(f["max_float_m"]), float(f["max_sink_m"])])
	var seam: Dictionary = report["backdrop"]
	if seam.is_empty():
		lines.append("GROUND_CONTACT map=%s family=backdrop n=0 (no far backdrop block: nothing drawn at the ground's edge)" % map_id)
	else:
		lines.append("GROUND_CONTACT map=%s family=backdrop n=%d max_float_m=%.3f max_sink_m=%.3f (skirt vs the ground square's edge)" % [map_id, int(seam["n"]), float(seam["max_float_m"]), float(seam["max_sink_m"])])
	var floating: Array = report["floating"]
	for i in mini(WORST, floating.size()):
		lines.append("GROUND_CONTACT_WORST map=%s rank=%d float_m=%.3f family=%s piece=%s" % [map_id, i + 1, float(floating[i][0]), floating[i][1], floating[i][2]])
	# The same pieces against the ground drawn beyond the terrain's far swap distance.
	var far: Dictionary = report["far_families"]
	for key: String in far:
		var f: Dictionary = far[key]
		lines.append("GROUND_CONTACT_FAR map=%s family=%s n=%d max_float_m=%.3f max_sink_m=%.3f (far ground, step %s m)" % [map_id, key, int(f["n"]), float(f["max_float_m"]), float(f["max_sink_m"]), str(report["far_step_m"])])
	var far_floating: Array = report["far_floating"]
	for i in mini(WORST, far_floating.size()):
		lines.append("GROUND_CONTACT_FAR_WORST map=%s rank=%d float_m=%.3f family=%s piece=%s" % [map_id, i + 1, float(far_floating[i][0]), far_floating[i][1], far_floating[i][2]])
	var tris: Dictionary = report.get("terrain_tris", {})
	if not tris.is_empty():
		lines.append("GROUND_CONTACT_TERRAIN_TRIS map=%s chunks=%d near_tris=%d far_tris=%d far_step_m=%s" % [map_id, int(tris["chunks"]), int(tris["near"]), int(tris["far"]), str(report["far_step_m"])])
	return lines


## Piece ids by their ground spot (x, z to 0.01 m) from the map's files, for the report.
static func _ids_by_spot(def: Dictionary) -> Dictionary:
	var out := {}
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var lists: Array = DataRegistry.parse_quiet(String(def["structure_data"])).get("pieces", [])
	for key: String in ["pieces", "ring_pieces", "decor", "breakables", "chests"]:
		lists = lists + (cover.get(key, []) as Array)
	for entry: Dictionary in lists:
		var at := LowpolyKit.vec(entry["at"])
		out[_spot_key(at)] = String(entry["id"])
	return out


static func _spot_key(at: Vector3) -> String:
	return "%.2f,%.2f" % [at.x, at.z]
