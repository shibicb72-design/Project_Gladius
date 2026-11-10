class_name Backdrop
extends Node3D
## S6: what stands beyond the playable ground so the map has a horizon: a ground skirt, the outer wall ring
## with towers, far spires, the aqueduct's run towards the hills, and two rings of hills. Data:
## data/art_backdrop.json (placeholders, OQ-GFX-BACKDROP). Looks only: no body, no collider, nothing under the
## map's Nav node, and every piece is outside the ground square (tests/test_backdrop.gd), so it changes
## nowhere a player can walk, hide or shoot. One batch per kind of piece.

const PATH := "res://data/art_backdrop.json"
static var _registry := DataRegistry.new()
static var _meshes := {}

## For the tests: [{kind, at: Vector3, half: Vector2}] of everything placed (half = footprint half extents).
var placed: Array[Dictionary] = []


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func _mesh(key: String, parts: Array) -> ArrayMesh:
	if not _meshes.has(key):
		var kit_parts: Array = []
		for part: Dictionary in parts:
			kit_parts.append(WorldKit._kit_part(part))
		_meshes[key] = LowpolyKit.merge(kit_parts)
	return _meshes[key]


func build(ground_material: Material) -> void:
	var cfg := config()
	_build_skirt(cfg["skirt"], ground_material)
	_build_wall(cfg["outer_wall"])
	_build_spires(cfg["spires"])
	_build_aqueduct(cfg["aqueduct_run"])
	_build_hills(cfg["hills"])


func _batch(batch_name: String, mesh: Mesh, transforms: Array[Transform3D], shadows: bool) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i in transforms.size():
		multi.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.name = batch_name
	node.multimesh = multi
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _note(kind: String, at: Vector3, half: Vector2, turn: Basis = Basis.IDENTITY) -> void:
	placed.append({"kind": kind, "at": at, "half": half, "basis": turn})


func _build_skirt(cfg: Dictionary, ground_material: Material) -> void:
	if ground_material == null:
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * float(cfg["size_m"])
	var node := MeshInstance3D.new()
	node.name = "GroundSkirt"
	node.mesh = plane
	node.material_override = ground_material
	node.position.y = float(cfg["y_m"])
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _build_wall(cfg: Dictionary) -> void:
	var radius := float(cfg["radius_m"])
	var count := int(cfg["segments"])
	var every := int(cfg["tower_every"])
	var walls: Array[Transform3D] = []
	var towers: Array[Transform3D] = []
	for i in count:
		var angle := TAU * (float(i) + 0.5) / count
		var at := Vector3(cos(angle), 0.0, sin(angle)) * radius
		walls.append(Transform3D(Basis.looking_at(-at.normalized()), at))  # -Z, the decorated face, looks at the map
		_note("wall", at, Vector2(float(cfg["segment_length_m"]) * 0.5, 2.4), walls[-1].basis)
		if every > 0 and i % every == 0:
			var joint := TAU * float(i) / count
			var tower_at := Vector3(cos(joint), 0.0, sin(joint)) * (radius + 0.6)
			towers.append(Transform3D(Basis.looking_at(-tower_at.normalized()), tower_at))
			_note("tower", tower_at, Vector2(4.2, 4.2), towers[-1].basis)
	var shadows := bool(cfg["cast_shadows"])
	_batch("OuterWall", _mesh("wall", cfg["segment_parts"]), walls, shadows)
	_batch("OuterTowers", _mesh("tower", cfg["tower_parts"]), towers, shadows)


func _build_spires(cfg: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	for entry: Array in cfg["at"]:
		var at := Vector3(float(entry[0]), 0.0, float(entry[1]))
		var scale := float(entry[3])
		transforms.append(Transform3D(Basis(Vector3.UP, deg_to_rad(float(entry[2]))).scaled(Vector3.ONE * scale), at))
		_note("spire", at, Vector2(4.5, 4.5) * scale, Basis(Vector3.UP, deg_to_rad(float(entry[2]))))
	_batch("Spires", _mesh("spire", cfg["parts"]), transforms, bool(cfg["cast_shadows"]))


func _build_aqueduct(cfg: Dictionary) -> void:
	var type := String(cfg["type"])
	if not (WorldKit.config()["types"] as Dictionary).has(type):
		return
	var transforms: Array[Transform3D] = []
	var turn := Basis(Vector3.UP, deg_to_rad(float(cfg["yaw_deg"])))
	var rect := WorldKit.footprint(WorldKit.config()["types"][type], Vector3.ZERO, float(cfg["yaw_deg"]))
	for run: Dictionary in cfg["runs"]:
		for i in int(run["count"]):
			var at := Vector3(float(run["first"][0]) + float(run["step"][0]) * i, 0.0, float(run["first"][1]) + float(run["step"][1]) * i)
			transforms.append(Transform3D(turn, at))
			_note("aqueduct", at, rect.size * 0.5)
	_batch("AqueductRun", WorldKit.mesh_for(type), transforms, bool(cfg["cast_shadows"]))


## Two rings of hills: a jagged ridge between an inner and an outer foot, flat shaded like the kit.
func _build_hills(cfg: Dictionary) -> void:
	if not _meshes.has("hills"):
		_meshes["hills"] = _hills_mesh(cfg)
	var node := MeshInstance3D.new()
	node.name = "Hills"
	node.mesh = _meshes["hills"]
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _hills_mesh(cfg: Dictionary) -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.seed = int(cfg["seed"])
	noise.frequency = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	LowpolyKit._surface = WorldSurface.surface_id(String(cfg["surface"]))
	var ring_index := 0
	for ring: Dictionary in cfg["rings"]:
		var segments := int(ring["segments"])
		var radius := float(ring["radius_m"])
		var depth := float(ring["depth_m"])
		var color := GreyboxArt.color_value(ring["color"])
		var inner: Array[Vector3] = []
		var ridge: Array[Vector3] = []
		var outer: Array[Vector3] = []
		for i in segments:
			var angle := TAU * float(i) / segments
			var out := Vector3(cos(angle), 0.0, sin(angle))
			var n := noise.get_noise_2d(cos(angle) * 1.7 + ring_index * 9.0, sin(angle) * 1.7) * 0.5 + 0.5
			var n2 := noise.get_noise_2d(cos(angle) * 9.3 + 3.0, sin(angle) * 9.3 + ring_index * 5.0) * 0.5 + 0.5
			# Peaks and saddles: every other ridge point is pulled down, the broad noise sets the range.
			var jag := 1.0 if i % 2 == 0 else 0.55
			var height := float(ring["height_m"]) * lerpf(1.0 - float(ring["rough"]), 1.0, clampf((n * 0.6 + n2 * 0.4) * 1.4 - 0.2, 0.0, 1.0)) * jag
			inner.append(out * radius - Vector3.UP * 2.0)
			ridge.append(out * (radius + depth * (0.35 + 0.2 * n2)) + Vector3.UP * height)
			outer.append(out * (radius + depth) - Vector3.UP * 2.0)
		for i in segments:
			var j := (i + 1) % segments
			LowpolyKit._shade = 0.5 + 0.5 * sin(float(i) * 12.9898 + ring_index)
			# Towards the map: inner foot up to the ridge. Away from it: ridge down to the outer foot.
			# Corner order: (b - a) x (c - a) points out of the hill (up and towards the viewer's side).
			LowpolyKit._triangle(st, inner[i], ridge[j], ridge[i], color)
			LowpolyKit._triangle(st, inner[i], inner[j], ridge[j], color)
			LowpolyKit._triangle(st, ridge[i], outer[j], outer[i], color)
			LowpolyKit._triangle(st, ridge[i], ridge[j], outer[j], color)
		ring_index += 1
	LowpolyKit._surface = -1
	var mesh := st.commit()
	mesh.surface_set_material(0, WorldSurface.material())
	return mesh
