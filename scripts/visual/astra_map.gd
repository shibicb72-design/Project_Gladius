extends Node3D
## Synchronous map construction: ready before MatchRoot bakes parsed static colliders.
var cover_bodies: Array[StaticBody3D] = []

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
		mesh.material_override = GreyboxArt.material_for("citadel")
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
	var decor := map.get_node("Decor") as Node3D
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
