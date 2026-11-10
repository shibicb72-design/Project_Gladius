extends Node3D
## Synchronous map construction: ready before MatchRoot bakes parsed static colliders.
var cover_bodies: Array[StaticBody3D] = []
var structure_bodies: Array[StaticBody3D] = []  # W1 world kit pieces (group "structure")
var decor_bodies: Array[StaticBody3D] = []  # W2 colliders of the solid rim decor (group "structure")
var ring_bodies: Array[StaticBody3D] = []  # W3 cover of the outer ring (groups "ring_cover" and "cover_wall")

func _ready() -> void:
	var map := get_parent()
	var nav := map.get_node("Nav")
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	var meshes := {}
	for type: String in cfg["types"]:
		var definition: Dictionary = cfg["types"][type]
		meshes[type] = LowpolyKit.build_cover(definition)
	for entry: Dictionary in cfg["pieces"]:
		var definition: Dictionary = cfg["types"][entry["type"]]
		var body := StaticBody3D.new()
		body.name = entry["id"]
		body.set_meta(&"cover_palette", definition.get("palette", "citadel"))
		body.collision_layer = 1
		body.collision_mask = 0
		if bool(definition.get("coverable", false)):
			body.add_to_group(&"cover_wall")
		body.position = LowpolyKit.vec(entry["at"])
		var mesh := MeshInstance3D.new()
		mesh.name = "Mesh"
		mesh.mesh = meshes[entry["type"]]
		mesh.material_override = WorldSurface.palette_material(String(definition.get("palette", "citadel")))
		body.add_child(mesh)
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		var box := BoxShape3D.new()
		box.size = LowpolyKit.vec(definition["size"])
		shape.shape = box
		body.add_child(shape)
		nav.add_child(body)
		cover_bodies.append(body)
	for body in nav.get_children():
		if body in cover_bodies or body.name == &"Ground":
			continue
		body.add_to_group(&"cover_wall")
		var mesh := body.get_node("Mesh") as MeshInstance3D
		var size := (body.get_node("Shape").shape as BoxShape3D).size
		var kind := "camp" if String(body.name).begins_with("CampBlock") else "wall"
		# Vertical walls reuse the same long-axis profile, rotated on the visual only.
		var profile := Vector3(size.z, size.y, size.x) if size.z > size.x else size
		var key := kind + str(profile)
		if not meshes.has(key):
			meshes[key] = LowpolyKit.build(kind, profile)
		mesh.mesh = meshes[key]
		if size.z > size.x:
			mesh.rotation.y = PI * 0.5
	# W1: world kit pieces come after the loop above, which takes every other Nav child for a one-box wall.
	# They are bodies in group "structure" (never cover_wall); their look is one batch per type under this node.
	var structure_batches := Node3D.new()
	structure_batches.name = "Structures"
	add_child(structure_batches)
	structure_bodies = WorldKit.populate(nav, structure_batches, WorldKit.config()["pieces"])
	_build_ring(nav, cfg, meshes)
	var decor := map.get_node("Decor") as Node3D
	# W2: decor kinds listed in "decor_colliders" (rim arches and rocks) are solid; flat paving is not listed.
	var decor_solid: Dictionary = cfg.get("decor_colliders", {})
	for entry: Dictionary in cfg["decor"]:
		var mesh := MeshInstance3D.new()
		mesh.name = entry["id"]
		var key: String = entry["kind"] + str(entry["size"])
		if not meshes.has(key):
			meshes[key] = LowpolyKit.build(entry["kind"], LowpolyKit.vec(entry["size"]))
		mesh.mesh = meshes[key]
		mesh.position = LowpolyKit.vec(entry["at"])
		mesh.rotation.y = deg_to_rad(float(entry["yaw"]))
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		decor.add_child(mesh)
		if decor_solid.has(entry["kind"]):
			var solid := WorldKit.decor_body(entry, String(decor_solid[entry["kind"]]), meshes[key])
			nav.add_child(solid)
			decor_bodies.append(solid)
	_paint_ground(nav)
	# Attach below this builder: never add a sibling while the map root is in _ready.
	var ambient := WorldAmbient.new()
	ambient.name = "Ambient"
	ambient.configure(DataRegistry.new().load_file("res://data/art_world.json"), bool(GraphicsPresets.new().get_preset().get("art_ambient_enabled", false)))
	add_child(ambient)


## S2: the ground's blend material. The paint map comes from the map data (landmarks, cover and structure
## positions); `ground_paint` and `ground_size_m` stay readable for the footstep sounds (GroundPaint.surface_at).
var ground_paint: Image
var ground_size_m := 0.0

func _paint_ground(nav: Node) -> void:
	var ground_mesh := nav.get_node_or_null("Ground/Mesh") as MeshInstance3D
	if ground_mesh == null:
		return
	ground_size_m = ground_mesh.get_aabb().size.x
	var map_def := DataRegistry.new().load_file(MatchRoot.MAP_PATH)
	var landmark_path := String(map_def.get("landmarks", ""))
	var landmarks: Array = DataRegistry.new().load_file(landmark_path).get("landmarks", []) if landmark_path != "" else []
	var trodden := PackedVector2Array()
	for group: Array in [cover_bodies, ring_bodies, structure_bodies]:
		for body: StaticBody3D in group:
			trodden.append(Vector2(body.position.x, body.position.z))
	add_to_group(&"ground_paint")
	ground_paint = GroundPaint.build(MatchRoot.MAP_PATH, ground_size_m, landmarks, trodden)
	ground_mesh.material_override = WorldSurface.ground_material(GroundPaint.texture(MatchRoot.MAP_PATH), ground_size_m)


## W3: the outer ring's cover (cfg "ring_pieces"): the same one-box cover types as the inner band, in their own
## list with their own rules ("ring_rules"). A ring body holds its Shape only (groups ring_cover and, when the
## type is coverable, cover_wall); all pieces of a type draw as one batch with one material per palette.
func _build_ring(nav: Node, cfg: Dictionary, meshes: Dictionary) -> void:
	var batches := Node3D.new()
	batches.name = "RingCover"
	add_child(batches)
	var by_type := {}
	for entry: Dictionary in cfg.get("ring_pieces", []):
		var type := String(entry["type"])
		var definition: Dictionary = cfg["types"][type]
		var body := StaticBody3D.new()
		body.name = entry["id"]
		body.set_meta(&"cover_palette", definition.get("palette", "citadel"))
		body.collision_layer = 1
		body.collision_mask = 0
		body.add_to_group(&"ring_cover")
		if bool(definition.get("coverable", false)):
			body.add_to_group(&"cover_wall")
		body.position = LowpolyKit.vec(entry["at"])
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		var box := BoxShape3D.new()
		box.size = LowpolyKit.vec(definition["size"])
		shape.shape = box
		body.add_child(shape)
		nav.add_child(body)
		ring_bodies.append(body)
		if not by_type.has(type):
			by_type[type] = []
		(by_type[type] as Array).append(body.transform)
	var materials := {}
	for type: String in by_type:
		var palette := String(cfg["types"][type].get("palette", "citadel"))
		if not materials.has(palette):
			materials[palette] = WorldSurface.palette_material(palette)  # the inner cover pieces' material
		var transforms: Array = by_type[type]
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = meshes[type]
		batch.instance_count = transforms.size()
		for i in transforms.size():
			batch.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "Batch_" + type
		node.multimesh = batch
		node.material_override = materials[palette]
		node.set_meta(&"transforms", transforms)  # a headless renderer keeps no instance data to read back
		batches.add_child(node)  # casts shadows like the inner cover: one more shadow draw per type (performance risk)
