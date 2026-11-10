class_name WorldKit
extends RefCounted
## W1: world kit pieces (wall with walkway and stair, gate, watchtower, columns, aqueduct, barracks, tent, stakes,
## eagle standard, ramp and terrace blocks). Data: data/maps/alesia_structures.json (placeholders,
## OQ-WORLD-DENSE / OQ-ART-ASTRA). A piece is one StaticBody3D in group "structure" under the map's Nav node, so
## the navmesh bake parses it; the body holds colliders only. All pieces of one type draw as one MultiMesh with
## one material shared by every type. Pieces are never in group cover_wall: the cover system reads
## single-box bodies (scripts/systems/cover_probe.gd).
## A type lists "parts" (the look, LowpolyKit parts; y is metres above the ground under the piece), "colliders"
## (boxes and wedges with the same size / at / rot keys as a part), "walk" (the surfaces meant to be walked on)
## and "open" (the volumes that must stay free, such as the way under an arch).

const PATH := "res://data/maps/alesia_structures.json"
const GROUP := &"structure"
static var _registry := DataRegistry.new()
static var _material: StandardMaterial3D
static var _meshes := {}
static var _shapes := {}


static func config() -> Dictionary:
	return _registry.load_file(PATH)


## The one material of every world kit mesh: vertex colours as paint, written as sRGB in data.
static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.resource_name = "WorldKit"
		_material.vertex_color_use_as_albedo = true
		_material.vertex_color_is_srgb = true
		_material.roughness = float(LowpolyKit.config()["kit"]["roughness"])
	return _material


## A "block" is the plain four-cornered box (16 triangles; the kit's chamfered box has 64).
static func _kit_part(part: Dictionary) -> Dictionary:
	if String(part.get("shape", "")) != "block":
		return part
	var plain := part.duplicate()
	plain["shape"] = "taper"
	plain["top"] = [1.0, 1.0]
	plain["bevel"] = 0.0
	return plain


## Builds a type's mesh from its parts (uncached; deterministic).
static func build_mesh(definition: Dictionary) -> ArrayMesh:
	var parts: Array = []
	for part: Dictionary in definition["parts"]:
		parts.append(_kit_part(part))
	var mesh := LowpolyKit.merge(parts)
	mesh.surface_set_material(0, material())
	return mesh


static func mesh_for(type: String) -> ArrayMesh:
	if not _meshes.has(type):
		_meshes[type] = build_mesh(config()["types"][type])
	return _meshes[type]


## The eight corners of a collider entry's size box (a wedge lies inside its box), in piece space.
static func collider_corners(entry: Dictionary) -> PackedVector3Array:
	var half := LowpolyKit.vec(entry["size"]) * 0.5
	var xf := LowpolyShapes.transform_of(entry)
	var out := PackedVector3Array()
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				out.append(xf * Vector3(half.x * sx, half.y * sy, half.z * sz))
	return out


## Collision shape of one collider entry: "box", or "wedge" (the kit's wedge as a convex solid; ridge 1 is a ramp
## that rises towards +Z before "rot").
static func collider_shape(entry: Dictionary) -> Shape3D:
	var size := LowpolyKit.vec(entry["size"])
	if String(entry.get("shape", "box")) == "wedge":
		var hull := ConvexPolygonShape3D.new()
		var seen := {}
		var points := PackedVector3Array()
		for p in LowpolyShapes.triangles({"shape": "wedge", "size": entry["size"], "ridge": entry.get("ridge", 1.0)}, LowpolyKit.config()["kit"]["shapes"]):
			if not seen.has(p):
				seen[p] = true
				points.append(p)
		hull.points = points
		return hull
	var box := BoxShape3D.new()
	box.size = size
	return box


static func _shapes_for(type: String, definition: Dictionary) -> Array:
	if not _shapes.has(type):
		var shapes: Array = []
		for entry: Dictionary in definition["colliders"]:
			shapes.append(collider_shape(entry))
		_shapes[type] = shapes
	return _shapes[type]


## One piece as a collider-only body. `type` keys the shape cache; pass "" to build fresh shapes.
static func build_body(id: String, type: String, definition: Dictionary, at: Vector3, yaw_deg: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = id
	body.add_to_group(GROUP)
	body.set_meta(&"structure_type", type)
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = at
	body.rotation.y = deg_to_rad(yaw_deg)
	var colliders: Array = definition["colliders"]
	var shapes: Array = _shapes_for(type, definition) if type != "" else []
	for i in colliders.size():
		var node := CollisionShape3D.new()
		node.name = "Shape_%d" % i
		node.shape = shapes[i] if type != "" else collider_shape(colliders[i])
		node.transform = LowpolyShapes.transform_of(colliders[i])
		body.add_child(node)
	return body


## Ground rectangle (x, z) a placed piece covers: the bounds of its colliders after the piece's yaw.
static func footprint(definition: Dictionary, at: Vector3, yaw_deg: float) -> Rect2:
	var turn := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var rect := Rect2()
	var first := true
	for entry: Dictionary in definition["colliders"]:
		for corner in collider_corners(entry):
			var p := turn * corner
			var q := Vector2(at.x + p.x, at.z + p.z)
			rect = Rect2(q, Vector2.ZERO) if first else rect.expand(q)
			first = false
	return rect


## Height of the tallest collider corner above the piece's ground.
static func height(definition: Dictionary) -> float:
	var top := 0.0
	for entry: Dictionary in definition["colliders"]:
		for corner in collider_corners(entry):
			top = maxf(top, corner.y)
	return top


## A single piece's look, for line-ups and tests (the map draws batches instead).
static func display(type: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = "Kit_" + type
	node.mesh = mesh_for(type)
	return node


## Adds every piece of `pieces` to `nav` as bodies and one MultiMesh batch per type to `visuals`.
static func populate(nav: Node, visuals: Node3D, pieces: Array) -> Array[StaticBody3D]:
	var cfg := config()
	var types: Dictionary = cfg["types"]
	var bodies: Array[StaticBody3D] = []
	var by_type := {}
	for entry: Dictionary in pieces:
		var type := String(entry["type"])
		var body := build_body(String(entry["id"]), type, types[type], LowpolyKit.vec(entry["at"]), float(entry.get("yaw", 0.0)))
		nav.add_child(body)
		bodies.append(body)
		if not by_type.has(type):
			by_type[type] = []
		(by_type[type] as Array).append(body.transform)
	var shadows := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(cfg["batches"]["cast_shadows"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for type: String in by_type:
		var transforms: Array = by_type[type]
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = mesh_for(type)
		batch.instance_count = transforms.size()
		for i in transforms.size():
			batch.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "Batch_" + type
		node.multimesh = batch
		node.set_meta(&"transforms", transforms)  # a headless renderer keeps no instance data to read back
		node.cast_shadow = shadows  # performance risk when on: one more shadow draw per type and split
		visuals.add_child(node)
	return bodies
