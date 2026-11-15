class_name LootChest
extends StaticBody3D
## M2 L1b: a loot chest (data/props.json "chest", OQ-PROPS-CHEST). A permanent body under Nav (baked into the
## navigation mesh), group "loot_chest", never "cover_wall" and never in the builder's cover_bodies. Closed and open
## looks are two named pieces of the map's chunk batches (source "cover"): the closed one (piece id = prop_id) is
## drawn, the open one (open_id(prop_id)) starts hidden; opening swaps them, so a chest costs no draw call of its own.
## Interact or a bot in range opens it through WorldProps.open_chest on the authority; a client applies the host's
## state (WorldProps.apply_state), which swaps the look only. The body stays: an open chest is still solid.

const GROUP := &"loot_chest"

var prop_id := ""
var size := Vector3.ONE
var yaw_deg := 0.0
var is_open := false
## The batches drawing the looks (MapChunks: hide_piece / show_piece); null = no look (tests, tools).
var chunks: Node


## A body for one cover-file entry {id, at, size, yaw}; `palette` (data/props.json chest.palette) is its impact
## material. The position is the file's `at`; the builder lifts it onto the terrain.
static func make(entry: Dictionary, palette: String) -> LootChest:
	var body := LootChest.new()
	body.name = String(entry["id"])
	body.prop_id = String(entry["id"])
	body.size = LowpolyKit.vec(entry["size"])
	body.yaw_deg = float(entry.get("yaw", 0.0))
	body.set_meta(&"cover_palette", palette)
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group(GROUP)
	body.position = LowpolyKit.vec(entry["at"])
	body.rotation.y = deg_to_rad(body.yaw_deg)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = body.size
	shape.shape = box
	body.add_child(shape)
	return body


## The piece id of a chest's open look in the chunks.
static func open_id(id: String) -> String:
	return id + "/open"


## Shows the open look (once). Returns false when it was already open.
func open_look() -> bool:
	if is_open:
		return false
	is_open = true
	if chunks != null and chunks.has_method(&"hide_piece"):
		chunks.call(&"hide_piece", prop_id)
		chunks.call(&"show_piece", open_id(prop_id))
	return true


## The ground point under the chest's centre (the height its loot lands at).
func ground_point() -> Vector3:
	return _xform().origin - Vector3(0.0, size.y * 0.5, 0.0)


## The unit direction the chest opens towards on the ground (its local -z turned by its yaw).
func front() -> Vector3:
	var f := _xform().basis * Vector3.FORWARD
	return Vector3(f.x, 0.0, f.z).normalized()


## The centre of the spill: `offset_m` in front of the front face, at the ground height.
func spill_centre(offset_m: float) -> Vector3:
	return ground_point() + front() * (size.z * 0.5 + offset_m)


func _xform() -> Transform3D:
	return global_transform if is_inside_tree() else transform
