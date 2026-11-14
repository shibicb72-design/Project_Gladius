class_name MapChunks
extends Node3D
## M2P1A: the map's looks batched per chunk, so a later step can cull a chunk by distance on a 1 km map.
## The grid is square with its origin at the map centre; a piece's body origin decides its chunk. A chunk holds
## one MultiMesh batch per source ("cover", "ring", "structure", "decor") and type; a decor type is
## "<kind>_<n>", one per kind and size (the builder's decor_types). Bodies and colliders stay per piece
## under Nav; this node draws only. This node and its chunk nodes keep identity transforms, so an instance
## transform equals its body's transform. Data: data/map_build.json (placeholder, OQ-MAP-CHUNK).
## M2P1C: the placement at the origin is kept on purpose. Godot 4.7.2 (Mobile renderer, measured by
## tools/vis_range_probe.gd) measures visibility_range_begin/end from the camera to the centre of the instance's
## WORLD AABB (for a MultiMeshInstance3D: the AABB of all its instances), not from the node origin and not from
## the nearest point. So an origin-placed batch already measures from its own content: range_centre(batch).
## With fade disabled the end margin is hysteresis: a drawn instance hides beyond end + margin, a hidden one
## shows again within end - margin.
## M2P1C stop 2: each batch gets a visibility range from its class (data/map_build.json "classes", placeholders,
## OQ-MAP-CULL). The data range_m means "every piece of the batch is drawn at least out to this camera
## distance", so visibility_range_end = range_m + radius + margin, with radius = half the diagonal of the batch's
## world AABB (every piece point lies within it of the AABB centre the renderer measures from) and
## visibility_range_end_margin = margin (so even a hidden batch shows again by range_m + radius). range_m 0 =
## never culled (end 0). BINDING: a batch whose pieces have colliders (add(..., collides = true)) never gets a
## range_m below sight_floor_m; effective_range() raises it in code whatever the data says. Fade stays disabled.
## Metas per batch: "class", "collides", "range_m" (the effective data meaning), "radius_m".
## M2P1C stop 4: a batch's cast_shadow comes from its class's "cast_shadows" (required; class_problems reports a
## missing one, and a batch without a known class casts none). This replaces the builders' old settings: cover
## and ring always on (astra_map.gd), alesia_structures.json "batches.cast_shadows" (world_kit.gd). Terrain
## shadows stay map_build.json "terrain.cast_shadows" (astra_map.gd).

const CFG_PATH := "res://data/map_build.json"
static var _registry := DataRegistry.new()

var chunk_size_m := 50.0
var half_m := 0.0
var per_side := 1
var _pending := {}  # Vector2i -> {"source/type" -> batch entry}, in first-add order
## M2P1C: the "classes" block build() uses; empty = data/map_build.json's (tests pass their own).
var classes_override := {}


static func config() -> Dictionary:
	return _registry.load_file(CFG_PATH)


## Chunks per side for a square ground: at least one.
## (Parameter names differ from the members so they do not shadow them.)
static func count_for(ground_m: float, size_m: float) -> int:
	if ground_m <= 0.0 or size_m <= 0.0:
		return 1
	return maxi(1, ceili(ground_m / size_m))


## The chunk of a point on the ground plane; points outside the ground clamp to the edge chunks.
static func index_for(x: float, z: float, half: float, size_m: float, side: int) -> Vector2i:
	if size_m <= 0.0 or side <= 1:
		return Vector2i.ZERO
	var ix := clampi(floori((x + half) / size_m), 0, side - 1)
	var iz := clampi(floori((z + half) / size_m), 0, side - 1)
	return Vector2i(ix, iz)


## M2P1C: a chunk size that wins over data/map_build.json for every map built while it is > 0 (tests and
## tools measure other sizes without editing the json; whoever sets it resets it to 0).
static var size_override_m := 0.0


## Sets the grid for a square ground of `ground_size_m` (0 = no ground: one chunk).
func setup(ground_size_m: float) -> void:
	chunk_size_m = size_override_m if size_override_m > 0.0 else float(config()["chunk_size_m"])
	half_m = maxf(ground_size_m, 0.0) * 0.5
	per_side = count_for(ground_size_m, chunk_size_m)


func index_of(at: Vector3) -> Vector2i:
	return index_for(at.x, at.z, half_m, chunk_size_m, per_side)


## Collects one instance; build() makes the nodes. `material` null keeps the mesh's own material.
## `collides`: the piece has a collider (M2P1C: its batch never ends below the sight floor). The shadow is the
## batch class's (M2P1C stop 4), so the caller passes none.
func add(source: String, type: String, mesh: Mesh, material: Material, xform: Transform3D, collides := false) -> void:
	var index := index_of(xform.origin)
	if not _pending.has(index):
		_pending[index] = {}
	var chunk: Dictionary = _pending[index]
	var key := source + "/" + type
	if not chunk.has(key):
		chunk[key] = {"source": source, "type": type, "mesh": mesh, "material": material, "transforms": [], "collides": false}
	(chunk[key]["transforms"] as Array).append(xform)
	if collides:
		chunk[key]["collides"] = true


## M2P1C: the class name of a batch from a "classes" block: by_type "<source>/<type>", then "<source>/<kind>"
## (the type without a trailing "_<n>"), then by_source; "" when none matches.
static func class_of(source: String, type: String, classes: Dictionary) -> String:
	var by_type: Dictionary = classes.get("by_type", {})
	var key := source + "/" + type
	if by_type.has(key):
		return String(by_type[key])
	var cut := type.rfind("_")
	if cut > 0 and type.substr(cut + 1).is_valid_int():
		var kind_key := source + "/" + type.substr(0, cut)
		if by_type.has(kind_key):
			return String(by_type[kind_key])
	return String((classes.get("by_source", {}) as Dictionary).get(source, ""))


## M2P1C: the range a batch keeps (the data meaning: every piece drawn at least out to it). 0 stays never
## culled; a colliding batch is raised to the sight floor. Never below 0.
static func effective_range(range_m: float, collides: bool, floor_m: float) -> float:
	if range_m <= 0.0:
		return 0.0
	return maxf(range_m, floor_m) if collides else range_m


## M2P1C: the visibility_range_end for a batch with effective range `range_m` and bounding radius `radius_m`.
static func range_end_for(range_m: float, radius_m: float, margin_m: float) -> float:
	return 0.0 if range_m <= 0.0 else range_m + radius_m + margin_m


## M2P1C: what is wrong with a "classes" block, one line each (empty: fine).
static func class_problems(classes: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var list: Dictionary = classes.get("list", {})
	if list.is_empty():
		problems.append("classes.list is empty")
	for cls: String in list:
		var range_v: Variant = (list[cls] as Dictionary).get("range_m") if list[cls] is Dictionary else null
		if not (range_v is float or range_v is int) or float(range_v) < 0.0:
			problems.append("class %s: range_m must be a number >= 0" % cls)
		if not (list[cls] is Dictionary and (list[cls] as Dictionary).get("cast_shadows") is bool):
			problems.append("class %s: cast_shadows must be true or false" % cls)
	for key: String in ["sight_floor_m", "margin_m"]:
		var v: Variant = classes.get(key)
		if not (v is float or v is int) or float(v) < 0.0 or (key == "sight_floor_m" and float(v) <= 0.0):
			problems.append("classes.%s must be a number > 0 (margin >= 0)" % key)
	for source: String in ["cover", "ring", "structure", "decor"]:
		if not (classes.get("by_source", {}) as Dictionary).has(source):
			problems.append("classes.by_source has no %s" % source)
	for group: String in ["by_source", "by_type"]:
		var map: Dictionary = classes.get(group, {})
		for key: String in map:
			if not list.has(String(map[key])):
				problems.append("classes.%s.%s names unknown class %s" % [group, key, map[key]])
	return problems


## The world AABB of a mesh placed at each of `transforms` (empty AABB for none).
static func _bounds(mesh: Mesh, transforms: Array) -> AABB:
	var local := mesh.get_aabb()
	var box := AABB()
	var first := true
	for xform: Transform3D in transforms:
		var placed := xform * local
		box = placed if first else box.merge(placed)
		first = false
	return box


## Creates the chunk nodes (sorted by index) and their batches (in first-add order).
func build() -> void:
	var classes: Dictionary = classes_override if not classes_override.is_empty() else config().get("classes", {})
	var list: Dictionary = classes.get("list", {})
	var floor_m := float(classes.get("sight_floor_m", 0.0))
	var margin_m := float(classes.get("margin_m", 0.0))
	var indices: Array = _pending.keys()
	indices.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	for index: Vector2i in indices:
		var chunk := Node3D.new()
		chunk.name = "Chunk_%d_%d" % [index.x, index.y]
		chunk.set_meta(&"index", index)
		add_child(chunk)
		var entries: Dictionary = _pending[index]
		for key: String in entries:
			var entry: Dictionary = entries[key]
			var transforms: Array = entry["transforms"]
			var batch := MultiMesh.new()
			batch.transform_format = MultiMesh.TRANSFORM_3D
			batch.mesh = entry["mesh"]
			batch.instance_count = transforms.size()
			for i in transforms.size():
				batch.set_instance_transform(i, transforms[i])
			var node := MultiMeshInstance3D.new()
			node.name = "Batch_%s_%s" % [entry["source"], entry["type"]]
			node.multimesh = batch
			if entry["material"] != null:
				node.material_override = entry["material"]
			node.set_meta(&"transforms", transforms)  # a headless renderer keeps no instance data to read back
			node.set_meta(&"source", entry["source"])
			node.set_meta(&"type", entry["type"])
			var cls := class_of(String(entry["source"]), String(entry["type"]), classes)
			if not list.has(cls):
				push_error("MapChunks: no visibility class for %s/%s; never culled, no shadow" % [entry["source"], entry["type"]])
			var spec: Dictionary = list.get(cls, {})
			# Performance risk when on: one more shadow draw per batch and split.
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(spec.get("cast_shadows", false)) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var collides: bool = entry["collides"]
			var range_m := effective_range(float(spec.get("range_m", 0.0)), collides, floor_m)
			var radius_m := _bounds(entry["mesh"], transforms).size.length() * 0.5
			node.visibility_range_end = range_end_for(range_m, radius_m, margin_m)
			node.visibility_range_end_margin = margin_m if range_m > 0.0 else 0.0
			node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED  # fading blends alpha on Mobile
			node.set_meta(&"class", cls)
			node.set_meta(&"collides", collides)
			node.set_meta(&"range_m", range_m)
			node.set_meta(&"radius_m", radius_m)
			chunk.add_child(node)
	_pending.clear()


## The built batches of one source ("" = all), chunk by chunk.
func batches(source: String = "") -> Array[MultiMeshInstance3D]:
	var result: Array[MultiMeshInstance3D] = []
	for chunk in get_children():
		for node in chunk.get_children():
			if node is MultiMeshInstance3D and (source == "" or String(node.get_meta(&"source", "")) == source):
				result.append(node)
	return result


## The batch that draws the piece at `xform`: the batch of `source` and `type` in that point's chunk, when it
## holds an instance there (null otherwise).
func batch_of(source: String, type: String, xform: Transform3D) -> MultiMeshInstance3D:
	var index := index_of(xform.origin)
	var batch := get_node_or_null("Chunk_%d_%d/Batch_%s_%s" % [index.x, index.y, source, type]) as MultiMeshInstance3D
	if batch == null:
		return null
	for placed: Transform3D in batch.get_meta(&"transforms"):
		if placed.is_equal_approx(xform):
			return batch
	return null


## M2P1C: the world point the renderer measures a batch's visibility range from: the centre of the union of
## its instances' world AABBs (mesh AABB moved by each world transform), derived from the "transforms" meta
## because a headless renderer keeps no instance data. Needs the batch's global transform (identity here).
static func range_centre(batch: MultiMeshInstance3D) -> Vector3:
	return batch.global_transform * _bounds(batch.multimesh.mesh, batch.get_meta(&"transforms", [])).get_center()


## M2P1C: what a camera at world `point` would draw of a built map (the root holding ArtBuilder) by the
## renderer's rule: a node is in range when its end is 0 or the distance from `point` to its world AABB centre
## is <= visibility_range_end (the hysteresis margin ignored; frustum, occlusion and the far plane ignored).
## {"batches", "colliding", "non_colliding", "shadow" (batches in range that cast shadows), "per_class"
## {class: n}, "batches_total", "terrain" (terrain chunks with a mesh in range), "terrain_near", "terrain_far"
## (near / far meshes in range, M2P1C stop 5), "terrain_tris" (their triangles), "terrain_total" (chunks)}.
## visibility_range_begin counts too (in_range). A proxy, not a frame time.
static func visible_at(map: Node, point: Vector3) -> Dictionary:
	var out := {"batches": 0, "colliding": 0, "non_colliding": 0, "shadow": 0, "per_class": {}, "batches_total": 0,
			"terrain": 0, "terrain_near": 0, "terrain_far": 0, "terrain_tris": 0, "terrain_total": 0}
	var chunks := map.get_node_or_null("ArtBuilder/Chunks") as MapChunks
	if chunks != null:
		for batch in chunks.batches():
			out["batches_total"] += 1
			var d := point.distance_to(range_centre(batch))
			if (batch.visibility_range_end > 0.0 and d > batch.visibility_range_end) or (batch.visibility_range_begin > 0.0 and d < batch.visibility_range_begin):
				continue
			out["batches"] += 1
			out["colliding" if bool(batch.get_meta(&"collides", false)) else "non_colliding"] += 1
			if batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				out["shadow"] += 1
			var cls := String(batch.get_meta(&"class", ""))
			out["per_class"][cls] = int(out["per_class"].get(cls, 0)) + 1
	var terrain := map.get_node_or_null("ArtBuilder/Terrain")
	if terrain != null:
		for chunk in terrain.get_children():
			out["terrain_total"] += 1
			var any := false
			for mi: MeshInstance3D in chunk.find_children("*", "MeshInstance3D", false, false):
				if not in_range(mi, point):
					continue
				any = true
				out["terrain_far" if mi.name == &"Far" else "terrain_near"] += 1
				for s in (mi.mesh.get_surface_count() if mi.mesh != null else 0):
					if mi.mesh is ArrayMesh:
						out["terrain_tris"] += (mi.mesh as ArrayMesh).surface_get_array_index_len(s) / 3
					else:
						out["terrain_tris"] += (mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			out["terrain"] += 1 if any else 0
	return out


## M2P1C stop 8: the camera height of the standard points (a standing soldier's eye above the ground).
const EYE_M := 1.7


## M2P1C stop 8: the two standard points of the visible-at-a-point proxies, defined once: "centre" = the play
## centre (the origin at eye height), "corner" = the ground corner (-half, -half) at eye height (the terrain is
## 0 at the ground's rim: edge_blend_m). Without a ground (one chunk) the corner is the centre.
static func standard_points(map: Node) -> Dictionary:
	var chunks := map.get_node_or_null("ArtBuilder/Chunks") as MapChunks
	var half := chunks.half_m if chunks != null else 0.0
	return {"centre": Vector3(0.0, EYE_M, 0.0), "corner": Vector3(-half, EYE_M, -half)}


## M2P1C stop 8: visible_at from each standard point: {"centre": {..}, "corner": {..}}.
static func visible_proxies(map: Node) -> Dictionary:
	var points := standard_points(map)
	var out := {}
	for point_name: String in points:
		out[point_name] = visible_at(map, points[point_name])
	return out


## M2P1C stop 8: every visible-at-a-point count (from visible_proxies) above its limit in `limits`
## (data/map_build.json proxy_limits "visible": {"centre": {"batches": n, "shadow": n}, "corner": {..}}), one
## line each; a limited point or count missing from `visible` is a problem too. Empty: all within limits.
static func visible_problems(visible: Dictionary, limits: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for point: String in limits:
		if point.begins_with("_"):
			continue
		var wanted: Dictionary = limits[point]
		var have: Dictionary = visible.get(point, {})
		for key: String in wanted:
			if not have.has(key):
				problems.append("visible %s %s: no count" % [point, key])
			elif int(have[key]) > int(wanted[key]):
				problems.append("visible %s %s=%d over the limit %d" % [point, key, int(have[key]), int(wanted[key])])
	return problems


## M2P1C: whether `node` is drawn for a camera at `point` by the renderer's rule (stop 1): d = distance from
## the point to the centre of its world AABB (custom_aabb when set); end 0 or d <= end, and begin 0 or
## d >= begin. Margins (hysteresis) ignored.
static func in_range(node: GeometryInstance3D, point: Vector3) -> bool:
	var box: AABB = node.custom_aabb if node.custom_aabb.has_volume() else node.get_aabb()
	var d := point.distance_to(node.global_transform * box.get_center())
	return (node.visibility_range_end <= 0.0 or d <= node.visibility_range_end) and (node.visibility_range_begin <= 0.0 or d >= node.visibility_range_begin)


## Instances drawn for one source, across chunks; `type` "" counts every type.
func instance_total(source: String, type: String = "") -> int:
	var total := 0
	for node in batches(source):
		if type == "" or String(node.get_meta(&"type", "")) == type:
			total += node.multimesh.instance_count
	return total


## Tree counts of a built map scene (the root that holds Nav, ArtBuilder and Decor); a proxy, not measured
## frame cost. "per_map": the whole scene tree (multimesh, mesh_instances, materials, bodies, chunks, batches,
## batch_instances). "per_chunk": the largest count of any chunk index, and "per_chunk_at" where it occurs
## (first in index order). A chunk holds its batches, plus any unbatched looks under Nav (not Nav/Ground) and
## Decor (the decor looks are batched, so Decor holds none) and the bodies under Nav (not Ground) whose origin
## maps to it. The map must be in the tree.
static func proxies(map: Node) -> Dictionary:
	var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
	var nav := map.get_node("Nav")
	var multimesh := map.find_children("*", "MultiMeshInstance3D", true, false)
	var meshes := map.find_children("*", "MeshInstance3D", true, false)
	var per_map := {
		"multimesh": multimesh.size(),
		"mesh_instances": meshes.size(),
		"materials": _unique_materials(multimesh + meshes).size(),
		"bodies": map.find_children("*", "StaticBody3D", true, false).size(),
		"chunks": chunks.get_child_count(),
		"batches": chunks.batches().size(),
		"batch_instances": 0,
	}
	var cells := {}  # Vector2i -> {"multimesh": [nodes], "meshes": [nodes], "bodies": int}
	for chunk in chunks.get_children():
		var cell := _cell(cells, chunk.get_meta(&"index"))
		for node in chunk.get_children():
			if node is MultiMeshInstance3D:
				(cell["multimesh"] as Array).append(node)
				per_map["batch_instances"] += (node as MultiMeshInstance3D).multimesh.instance_count
	var ground := nav.get_node_or_null("Ground")
	var loose := nav.find_children("*", "MeshInstance3D", true, false)
	var decor := map.get_node_or_null("Decor")
	if decor != null:
		loose.append_array(decor.find_children("*", "MeshInstance3D", true, false))
	for node: MeshInstance3D in loose:
		if ground != null and ground.is_ancestor_of(node):
			continue
		(_cell(cells, chunks.index_of(node.global_position))["meshes"] as Array).append(node)
	for body in nav.get_children():
		if body is StaticBody3D and body != ground:
			_cell(cells, chunks.index_of((body as StaticBody3D).global_position))["bodies"] += 1
	var per_chunk := {"multimesh": 0, "mesh_instances": 0, "materials": 0, "bodies": 0}
	var per_chunk_at := {"multimesh": Vector2i.ZERO, "mesh_instances": Vector2i.ZERO, "materials": Vector2i.ZERO, "bodies": Vector2i.ZERO}
	var indices: Array = cells.keys()
	indices.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	for index: Vector2i in indices:
		var cell: Dictionary = cells[index]
		var counts := {
			"multimesh": (cell["multimesh"] as Array).size(),
			"mesh_instances": (cell["meshes"] as Array).size(),
			"materials": _unique_materials((cell["multimesh"] as Array) + (cell["meshes"] as Array)).size(),
			"bodies": int(cell["bodies"]),
		}
		for key: String in counts:
			if int(counts[key]) > int(per_chunk[key]):
				per_chunk[key] = counts[key]
				per_chunk_at[key] = index
	return {"per_map": per_map, "per_chunk": per_chunk, "per_chunk_at": per_chunk_at}


## Every count in `counts` (from proxies) above its limit in `limits` ({"per_map": {..}, "per_chunk": {..}}),
## one line each; a limited key missing from the counts is a problem too. Empty: all within limits.
static func proxy_problems(counts: Dictionary, limits: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for scope: String in ["per_map", "per_chunk"]:
		var wanted: Dictionary = limits.get(scope, {})
		var have: Dictionary = counts.get(scope, {})
		for key: String in wanted:
			if not have.has(key):
				problems.append("%s %s: no count" % [scope, key])
			elif int(have[key]) > int(wanted[key]):
				var at := " at %s" % str(counts["per_chunk_at"][key]) if scope == "per_chunk" and counts.has("per_chunk_at") else ""
				problems.append("%s %s=%d over the limit %d%s" % [scope, key, int(have[key]), int(wanted[key]), at])
	return problems


static func _cell(cells: Dictionary, index: Vector2i) -> Dictionary:
	if not cells.has(index):
		cells[index] = {"multimesh": [], "meshes": [], "bodies": 0}
	return cells[index]


## Unique materials by resource identity: a node's material_override, otherwise each non-null surface
## material of its mesh (for a MultiMeshInstance3D, of multimesh.mesh).
static func _unique_materials(nodes: Array) -> Dictionary:
	var found := {}
	for node: GeometryInstance3D in nodes:
		if node.material_override != null:
			found[node.material_override] = true
			continue
		var mesh: Mesh = null
		if node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
		elif node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null:
			mesh = (node as MultiMeshInstance3D).multimesh.mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface)
			if material != null:
				found[material] = true
	return found
