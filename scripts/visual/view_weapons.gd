class_name ViewWeapons
extends RefCounted
## M2 AN1: the first-person weapon models (Pilum BR, Sagittarii rifle, Gladius Lux), built from the part lists of
## data/art_soldier.json weapons.<id> (OQ-ART-SOLDIER placeholders). Presentation only: nothing here feeds a shot.
## A weapon node's origin is the right hand's grip point (the blade: the middle of the hilt); -z is forward, +y up.
## Children: "Mesh" (the static parts: one surface per pass), "Cell" and "Charge" (their own nodes, so the reload
## can take the energy cell out and pull the charging handle), "Muzzle" and "SightAnchor" markers (guns only).
## The red dot and the arms are added by ViewModel.


static func art(id: String) -> Dictionary:
	var all: Dictionary = ViewMesh.config()["weapons"]
	return all.get(id, {})


static func has_art(id: String) -> bool:
	return (ViewMesh.config()["weapons"] as Dictionary).has(id)


static func _mesh_node(node_name: String, mesh: Mesh, parent: Node) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	m.mesh = mesh
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(m)
	return m


## A sub-node (Cell, Charge) at its rest position with its own mesh; its rest transform is meta "rest".
static func _sub(node: Node3D, sub_name: String, id: String, sub: Dictionary) -> Node3D:
	var n := Node3D.new()
	n.name = sub_name
	n.transform = ViewMesh.part_transform(sub)
	n.set_meta(&"rest", n.transform)
	node.add_child(n)
	_mesh_node("Mesh", ViewMesh.build_parts("%s_%s" % [id, sub_name], sub["parts"]), n)
	return n


## The weapon node for `id` (no arms, no red dot). Unknown ids fall back to `fallback`.
static func build(id: String, fallback: String) -> Node3D:
	var key := id if has_art(id) else fallback
	var a := art(key)
	var node := Node3D.new()
	node.name = "Weapon_" + id
	node.set_meta(&"art_id", key)
	_mesh_node("Mesh", ViewMesh.build_parts(key, a["parts"]), node)
	if a.has("cell"):
		_sub(node, "Cell", key, a["cell"])
	if a.has("charge"):
		_sub(node, "Charge", key, a["charge"])
	if a.has("muzzle_m"):
		var muzzle := Marker3D.new()
		muzzle.name = "Muzzle"
		muzzle.position = ViewMesh.vec(a["muzzle_m"])
		node.add_child(muzzle)
	if a.has("dot_m"):
		var anchor := Marker3D.new()
		anchor.name = "SightAnchor"
		anchor.position = ViewMesh.vec(a.get("sight_m", a["dot_m"]))
		node.add_child(anchor)
	return node


## The red dot's position in the weapon frame.
static func dot_position(id: String) -> Vector3:
	return ViewMesh.vec(art(id)["dot_m"])


## Hand placement for side "r" / "l": {"at", "rot", "pose", "elbow"} in the weapon frame.
static func hand(id: String, side: String) -> Dictionary:
	return (art(id).get("hands", {}) as Dictionary).get(side, {})
