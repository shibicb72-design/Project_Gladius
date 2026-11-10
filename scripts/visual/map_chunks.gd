class_name MapChunks
extends Node3D
## M2P1A: the map's looks batched per chunk, so a later step can cull a chunk by distance on a 1 km map.
## The grid is square with its origin at the map centre; a piece's body origin decides its chunk. A chunk holds
## one MultiMesh batch per source ("cover", "ring", "structure") and type. Bodies and colliders stay per piece
## under Nav; this node draws only. This node and its chunk nodes keep identity transforms, so an instance
## transform equals its body's transform. Data: data/map_build.json (placeholder, OQ-MAP-CHUNK).

const CFG_PATH := "res://data/map_build.json"
static var _registry := DataRegistry.new()

var chunk_size_m := 50.0
var half_m := 0.0
var per_side := 1
var _pending := {}  # Vector2i -> {"source/type" -> batch entry}, in first-add order


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


## Sets the grid for a square ground of `ground_size_m` (0 = no ground: one chunk).
func setup(ground_size_m: float) -> void:
	chunk_size_m = float(config()["chunk_size_m"])
	half_m = maxf(ground_size_m, 0.0) * 0.5
	per_side = count_for(ground_size_m, chunk_size_m)


func index_of(at: Vector3) -> Vector2i:
	return index_for(at.x, at.z, half_m, chunk_size_m, per_side)


## Collects one instance; build() makes the nodes. `material` null keeps the mesh's own material.
func add(source: String, type: String, mesh: Mesh, material: Material, cast_shadow: GeometryInstance3D.ShadowCastingSetting, xform: Transform3D) -> void:
	var index := index_of(xform.origin)
	if not _pending.has(index):
		_pending[index] = {}
	var chunk: Dictionary = _pending[index]
	var key := source + "/" + type
	if not chunk.has(key):
		chunk[key] = {"source": source, "type": type, "mesh": mesh, "material": material, "shadow": cast_shadow, "transforms": []}
	(chunk[key]["transforms"] as Array).append(xform)


## Creates the chunk nodes (sorted by index) and their batches (in first-add order).
func build() -> void:
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
			node.cast_shadow = entry["shadow"]  # performance risk when on: one more shadow draw per batch and split
			node.set_meta(&"transforms", transforms)  # a headless renderer keeps no instance data to read back
			node.set_meta(&"source", entry["source"])
			node.set_meta(&"type", entry["type"])
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


## Instances drawn for one source, across chunks; `type` "" counts every type.
func instance_total(source: String, type: String = "") -> int:
	var total := 0
	for node in batches(source):
		if type == "" or String(node.get_meta(&"type", "")) == type:
			total += node.multimesh.instance_count
	return total
