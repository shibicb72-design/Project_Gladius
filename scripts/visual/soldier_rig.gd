class_name SoldierRig
extends RefCounted
## One shared skin and mesh per rest skeleton; independent pose state per pawn.
## M2 AN2 item 1: the skeleton is built from data as before (data/anim.json "bones" plus data/anim_third_person.json
## "bones_add": toes, finger curls and a prop bone, 22 in all). The mesh comes from the Blender-built
## assets/generated/characters/soldier.glb when data/art_soldier.json soldier.mesh_source names it (two LODs,
## SoldierNear and SoldierFar, blended weights), else from the part data (LowpolyKit.merge_skinned, the fallback).
## After build(), `mesh`, `mesh_far` (null for the code mesh) and `skin` are the ones for that skeleton's rests:
## meshes and skins are cached per rest set, so a caller that builds from other parts (tests) cannot leave a
## stale skin or mesh for the next one (the first-call-wins statics of before).

static var mesh: ArrayMesh
static var mesh_far: ArrayMesh
static var skin: Skin
static var _rest_bounds: Array[AABB] = []
static var _by_rests: Dictionary = {}  # rest signature -> [near ArrayMesh, far ArrayMesh or null, Skin]


static var _config: Dictionary = {}
## M2 AN3: true restores the pre-AN3 head and body paths exactly (data/anim_third_person.json "head" is ignored). Tools
## set it (--legacy-head) to record "before" sequences; the game never does.
static var head_legacy := false


## M2 AN3: data/anim_third_person.json "head" (OQ-ANIM-HEAD), or {} under head_legacy (every caller then takes its old path).
static func head_cfg() -> Dictionary:
	if head_legacy:
		return {}
	return config().get("head", {})


## data/anim.json with data/anim_third_person.json laid over it (M2 AN1 commit 4: a deep merge, the overlay's keys
## win, dictionaries merge). Read once; every soldier shares it.
static func config() -> Dictionary:
	if _config.is_empty():
		var registry := DataRegistry.new()
		var merged: Dictionary = registry.load_file("res://data/anim.json").duplicate(true)
		var overlay: Dictionary = registry.load_file("res://data/anim_third_person.json").duplicate(true)
		for key: String in overlay.keys():
			if key.begins_with("_"):  # the overlay's own notes, not anim.json's
				overlay.erase(key)
		_merge(merged, overlay)
		_config = merged
	return _config


static func _merge(into: Dictionary, over: Dictionary) -> void:
	for key in over:
		if into.get(key) is Dictionary and over[key] is Dictionary:
			_merge(into[key], over[key])
		else:
			into[key] = (over[key] as Variant).duplicate(true) if over[key] is Dictionary or over[key] is Array else over[key]


## The skeleton's bone rows in order: anim.json "bones", then anim_third_person.json "bones_add" (M2 AN2).
static func bone_rows() -> Array:
	var cfg := config()
	var rows: Array = (cfg["bones"] as Array).duplicate()
	rows.append_array(cfg.get("bones_add", []))
	return rows


## data/art_soldier.json soldier.mesh_source: the .glb the soldier's mesh comes from, "" = built from the parts.
static func mesh_source() -> String:
	return String(SoldierLook.config().get("mesh_source", ""))


static func build(parts: Array, head_at: Vector3) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var cfg := config()
	var by_name: Dictionary = {}
	for part: Dictionary in parts:
		by_name[part["name"]] = part
	var global_rest: Dictionary = {}
	for bone: Dictionary in bone_rows():
		var index := skeleton.add_bone(bone["name"])
		var part: Dictionary = by_name[bone["part"]]
		var pivot := LowpolyKit.vec(part["at"])
		if bone["pivot"] == "top":
			pivot.y += float(part["size"][1]) * 0.5
		elif bone["pivot"] == "head_shell":
			pivot = head_at
		elif bone["pivot"] == "offset":
			pivot += LowpolyKit.vec(bone["offset_m"])
		var rest := Transform3D(Basis.IDENTITY, pivot)
		global_rest[bone["name"]] = rest
		var parent := skeleton.find_bone(bone["parent"])
		if parent >= 0:
			skeleton.set_bone_parent(index, parent)
			rest = (global_rest[bone["parent"]] as Transform3D).affine_inverse() * rest
		skeleton.set_bone_rest(index, rest)
	skeleton.reset_bone_poses()
	var source := mesh_source()
	var key := source + "|" + str(parts.size()) + "|" + _signature(skeleton)
	if not _by_rests.has(key):
		var built := _glb_meshes(source, skeleton) if source != "" else []
		if built.is_empty():
			var indices := PackedInt32Array()
			for part: Dictionary in parts:
				indices.append(skeleton.find_bone(cfg["part_bones"][part["name"]]))
			built = [LowpolyKit.merge_skinned(parts, indices), null]
		built.append(skeleton.create_skin_from_rest_transforms())
		_by_rests[key] = built
	var entry: Array = _by_rests[key]
	mesh = entry[0]
	mesh_far = entry[1]
	skin = entry[2]
	return skeleton


## The global rests rounded to 0.1 mm, as text: equal for skeletons built from the same data.
static func _signature(skeleton: Skeleton3D) -> String:
	var out := PackedStringArray()
	for i in skeleton.get_bone_count():
		var o := skeleton.get_bone_global_rest(i).origin
		out.append("%s%d,%d,%d" % [skeleton.get_bone_name(i), roundi(o.x * 10000.0), roundi(o.y * 10000.0), roundi(o.z * 10000.0)])
	return ",".join(out)


## [near, far] from the Blender-built .glb, their bone indices remapped by bone NAME onto `skeleton` (bind i = bone
## i, the skin create_skin_from_rest_transforms() makes), the imported material replaced by the one soldier material.
## Empty when the file or its meshes are missing (the caller falls back to the code-built mesh).
static func _glb_meshes(path: String, skeleton: Skeleton3D) -> Array:
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("SoldierRig: mesh_source %s does not load" % path)
		return []
	var scene := packed.instantiate()
	var result: Array = []
	for mesh_name: String in ["SoldierNear", "SoldierFar"]:
		var instance := scene.find_child(mesh_name, true, false) as MeshInstance3D
		if instance == null or instance.mesh == null or instance.skin == null:
			push_error("SoldierRig: %s has no skinned mesh %s" % [path, mesh_name])
			scene.free()
			return []
		var source_skeleton := instance.get_node_or_null(instance.skeleton) as Skeleton3D
		result.append(_remapped(instance.mesh as ArrayMesh, instance.skin, source_skeleton, skeleton, mesh_name))
		if result[-1] == null:
			scene.free()
			return []
	scene.free()
	return result


static func _remapped(source: ArrayMesh, source_skin: Skin, source_skeleton: Skeleton3D, skeleton: Skeleton3D, mesh_name: String) -> ArrayMesh:
	var bind_to_bone := PackedInt32Array()
	for k in source_skin.get_bind_count():
		var bone_name := String(source_skin.get_bind_name(k))
		if bone_name == "" and source_skeleton != null:
			bone_name = String(source_skeleton.get_bone_name(source_skin.get_bind_bone(k)))
		var bone := skeleton.find_bone(bone_name)
		if bone < 0:
			push_error("SoldierRig: %s binds %s, a bone the soldier skeleton lacks" % [mesh_name, bone_name])
			return null
		bind_to_bone.append(bone)
	var arrays := source.surface_get_arrays(0)
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	for i in bones.size():
		bones[i] = bind_to_bone[bones[i]]
	arrays[Mesh.ARRAY_BONES] = bones
	var result := ArrayMesh.new()
	result.resource_name = mesh_name
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	result.surface_set_material(0, SoldierSquadColour.material())
	return result


## Mesh-space bounds of every part in the bind pose, measured once: a box is its size box, a turned or
## axis-centred shape is measured from its own corners (LowpolyShapes.bounds_of).
static func rest_bounds(parts: Array) -> Array[AABB]:
	if _rest_bounds.size() != parts.size():
		_rest_bounds.clear()
		var defaults: Dictionary = LowpolyKit.config()["kit"]["shapes"]
		for part: Dictionary in parts:
			_rest_bounds.append(LowpolyShapes.bounds_of(part, defaults))
	return _rest_bounds


## CPU truth, including under the dummy renderer. Bounds are rigid bone-local AABBs.
static func part_local_bounds(parts: Array, skeleton: Skeleton3D) -> Array[AABB]:
	var result: Array[AABB] = []
	var mapping: Dictionary = config()["part_bones"]
	var rest := rest_bounds(parts)
	for i in parts.size():
		var bone := skeleton.find_bone(mapping[parts[i]["name"]])
		result.append(skeleton.get_bone_global_rest(bone).affine_inverse() * rest[i])
	return result


## Analytic authoring helper: rotate the two rest segments to a reachable hand target.
static func arm_rotations(skeleton: Skeleton3D, side: String, target: Vector3, pole: Vector3, epsilon: float) -> Array[Quaternion]:
	var upper := skeleton.find_bone(side + "UpperArm")
	var fore := skeleton.find_bone(side + "ForeArm")
	var hand := skeleton.find_bone(side + "Hand")
	var root := skeleton.get_bone_global_rest(upper).origin
	var first := skeleton.get_bone_rest(fore).origin
	var second := skeleton.get_bone_rest(hand).origin
	var a := first.length()
	var b := second.length()
	var distance := clampf(root.distance_to(target), absf(a - b) + epsilon, a + b - epsilon)
	var direction := (target - root).normalized()
	var bend := (pole - direction * pole.dot(direction)).normalized()
	var along := (a * a + distance * distance - b * b) / (2.0 * distance)
	var elbow := root + direction * along + bend * sqrt(maxf(a * a - along * along, 0.0))
	var end := root + direction * distance
	var upper_rotation := Quaternion(first.normalized(), (elbow - root).normalized())
	var fore_rotation := Quaternion(second.normalized(), (end - elbow).normalized())
	return [upper_rotation, upper_rotation.inverse() * fore_rotation, fore_rotation.inverse()]
