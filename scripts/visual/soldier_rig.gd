class_name SoldierRig
extends RefCounted
## One shared rigid-weight skin and mesh; independent pose state per pawn.

static var mesh: ArrayMesh
static var skin: Skin


static func config() -> Dictionary:
	return DataRegistry.new().load_file("res://data/anim.json")


static func build(parts: Array, head_at: Vector3) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var cfg := config()
	var by_name: Dictionary = {}
	for part: Dictionary in parts:
		by_name[part["name"]] = part
	var global_rest: Dictionary = {}
	for bone: Dictionary in cfg["bones"]:
		var index := skeleton.add_bone(bone["name"])
		var part: Dictionary = by_name[bone["part"]]
		var pivot := LowpolyKit.vec(part["at"])
		if bone["pivot"] == "top":
			pivot.y += float(part["size"][1]) * 0.5
		elif bone["pivot"] == "head_shell":
			pivot = head_at
		var rest := Transform3D(Basis.IDENTITY, pivot)
		global_rest[bone["name"]] = rest
		var parent := skeleton.find_bone(bone["parent"])
		if parent >= 0:
			skeleton.set_bone_parent(index, parent)
			rest = (global_rest[bone["parent"]] as Transform3D).affine_inverse() * rest
		skeleton.set_bone_rest(index, rest)
	skeleton.reset_bone_poses()
	if skin == null:
		skin = skeleton.create_skin_from_rest_transforms()
	if mesh == null:
		var indices := PackedInt32Array()
		for part: Dictionary in parts:
			indices.append(skeleton.find_bone(cfg["part_bones"][part["name"]]))
		mesh = LowpolyKit.merge_skinned(parts, indices)
	return skeleton


## CPU truth, including under the dummy renderer. Bounds are rigid bone-local AABBs.
static func part_local_bounds(parts: Array, skeleton: Skeleton3D) -> Array[AABB]:
	var result: Array[AABB] = []
	var mapping: Dictionary = config()["part_bones"]
	for part: Dictionary in parts:
		var bone := skeleton.find_bone(mapping[part["name"]])
		var size := LowpolyKit.vec(part["size"])
		var bounds := AABB(LowpolyKit.vec(part["at"]) - size * 0.5, size)
		result.append(skeleton.get_bone_global_rest(bone).affine_inverse() * bounds)
	return result
