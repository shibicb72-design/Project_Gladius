class_name ViewWeapons
extends RefCounted
## M2 AN1: the first-person weapon models (Pilum BR, Sagittarii rifle, Gladius Lux), built from the part lists of
## data/art_soldier.json weapons.<id> (OQ-ART-SOLDIER placeholders). Presentation only: nothing here feeds a shot.
## A weapon node's origin is the right hand's grip point (the blade: the middle of the hilt); -z is forward, +y up.
## M2 AN2 item 4a: with weapons.<id>.mesh_source set the three meshes come from the Blender-built .glb (objects Mesh,
## Cell, Charge); the anchors (muzzle_m, dot_m, sight_m, the cell and charge rests) stay data, the .glb is modelled
## round them. The part lists below stay the fallback.
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


## M2 AN2 item 4a: the Blender-built .glb of weapon art `id` (art_soldier.json weapons.<id>.mesh_source,
## tools/blender/build_weapons.py), or "" when the key is absent or the file is not there (the part lists build it).
static func mesh_source(id: String) -> String:
	var path := String(art(id).get("mesh_source", ""))
	return path if ViewMesh.has_source(path) else ""


## The mesh of one piece ("Mesh", "Cell", "Charge"): the .glb's object of that name, else the part list.
static func _piece(id: String, piece: String, parts: Array, cache_key: String) -> Mesh:
	var src := mesh_source(id)
	if src != "":
		var m := ViewMesh.glb_view_mesh(src, piece)
		if m != null:
			return m
		push_error("ViewWeapons: %s has no %s; using the part list" % [src, piece])
	return ViewMesh.build_parts(cache_key, parts)


## A sub-node (Cell, Charge) at its rest position (from the data: the .glb's object sits there too) with its own
## mesh; its rest transform is meta "rest".
static func _sub(node: Node3D, sub_name: String, id: String, sub: Dictionary) -> Node3D:
	var n := Node3D.new()
	n.name = sub_name
	n.transform = ViewMesh.part_transform(sub)
	n.set_meta(&"rest", n.transform)
	node.add_child(n)
	_mesh_node("Mesh", _piece(id, sub_name, sub["parts"], "%s_%s" % [id, sub_name]), n)
	return n


## The weapon node for `id` (no arms, no red dot). Unknown ids fall back to `fallback`.
static func build(id: String, fallback: String) -> Node3D:
	var key := id if has_art(id) else fallback
	var a := art(key)
	var node := Node3D.new()
	node.name = "Weapon_" + id
	node.set_meta(&"art_id", key)
	_mesh_node("Mesh", _piece(key, "Mesh", a["parts"], key), node)
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
