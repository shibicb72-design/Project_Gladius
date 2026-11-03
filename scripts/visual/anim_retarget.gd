class_name AnimRetarget
extends RefCounted
## Bake full local poses via source globals and rest-shape alignment.
static var _baked: Dictionary = {}
const TARGET_MAP = preload("res://assets/anim/soldier_bone_map.tres")

static func _name(profile: String, mapping: BoneMap) -> String:
	return String(mapping.get_skeleton_bone_name(profile))

static func _rests(skeleton: Skeleton3D) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		result.append(skeleton.get_bone_global_rest(i))
	return result

static func _parents(skeleton: Skeleton3D) -> Array[int]:
	var result: Array[int] = []
	for i in skeleton.get_bone_count():
		result.append(skeleton.get_bone_parent(i))
	return result

static func _global_at(i: int, local: Array[Transform3D], parents: Array[int], cache: Dictionary) -> Transform3D:
	if not cache.has(i):
		cache[i] = local[i] if parents[i] < 0 else _global_at(parents[i], local, parents, cache) * local[i]
	return cache[i]

static func sample_globals(clip: Animation, skeleton: Skeleton3D, time: float) -> Array[Transform3D]:
	var local: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		local.append(skeleton.get_bone_rest(i))
	for track in clip.get_track_count():
		var path := clip.track_get_path(track)
		if not clip.track_is_enabled(track) or path.get_subname_count() == 0 or clip.track_get_key_count(track) == 0:
			continue
		var index := skeleton.find_bone(path.get_subname(0))
		if index < 0:
			continue
		var pose := local[index]
		match clip.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				var rotation: Quaternion = clip.rotation_track_interpolate(track, time)
				pose.basis = Basis(rotation)
			Animation.TYPE_POSITION_3D:
				pose.origin = clip.position_track_interpolate(track, time)
		local[index] = pose
	var result: Array[Transform3D] = []
	var parents := _parents(skeleton)
	var cache: Dictionary = {}
	for i in skeleton.get_bone_count():
		result.append(_global_at(i, local, parents, cache))
	return result

static func basis_change(source: Skeleton3D, target: Skeleton3D, mapping: BoneMap = TARGET_MAP) -> Dictionary:
	var frames: Array[Basis] = []
	for rig in [source, target]:
		var source_rig: bool = rig == source
		var hip: int = rig.find_bone("Hips" if source_rig else _name("Hips", mapping))
		var has_toes: bool = source_rig and rig.find_bone("LeftToes") >= 0 and rig.find_bone("RightToes") >= 0
		var left: int = rig.find_bone("LeftToes" if has_toes else "LeftFoot" if source_rig else _name("LeftFoot", mapping))
		var right: int = rig.find_bone("RightToes" if has_toes else "RightFoot" if source_rig else _name("RightFoot", mapping))
		var left_thigh: int = rig.find_bone("LeftUpperLeg" if source_rig else _name("LeftUpperLeg", mapping))
		var right_thigh: int = rig.find_bone("RightUpperLeg" if source_rig else _name("RightUpperLeg", mapping))
		if mini(mini(hip, left), mini(right, mini(left_thigh, right_thigh))) < 0:
			return {"valid": false}
		var front: Vector3 = (rig.get_bone_global_rest(left).origin + rig.get_bone_global_rest(right).origin) * 0.5 - rig.get_bone_global_rest(hip).origin
		front.y = 0.0
		var across: Vector3 = rig.get_bone_global_rest(right_thigh).origin - rig.get_bone_global_rest(left_thigh).origin
		across.y = 0.0
		if front.is_zero_approx() or across.is_zero_approx() or front.cross(Vector3.UP).normalized().dot(across.normalized()) <= 0.0:
			return {"valid": false}
		front = front.normalized()
		frames.append(Basis(front.cross(Vector3.UP), Vector3.UP, -front))
	return {"valid": true, "rotation": (frames[1] * frames[0].inverse()).get_rotation_quaternion()}

static func bake(clip: Animation, source: Skeleton3D, target: Skeleton3D, cache_key: String = "") -> Animation:
	var mapping := TARGET_MAP as BoneMap
	var cfg: Dictionary = SoldierRig.config()["retarget"]
	var change := basis_change(source, target, mapping)
	if not change.get("valid", false):
		return null
	var source_rest := _rests(source)
	var target_rest := _rests(target)
	var key := str(clip.get_instance_id()) if cache_key.is_empty() else cache_key
	key += str(source_rest) + str(target_rest) + str(cfg)
	if _baked.has(key):
		return _baked[key]
	var rotation: Quaternion = change["rotation"]
	var profile_names: Dictionary = {}
	var source_bones: Dictionary = {}
	for i in mapping.profile.bone_size:
		var profile := String(mapping.profile.get_bone_name(i))
		var target_index := target.find_bone(_name(profile, mapping))
		var source_index := source.find_bone(profile)
		if target_index >= 0 and source_index >= 0:
			profile_names[target_index] = profile
			source_bones[target_index] = source_index
	var alignment: Dictionary = {}
	var tracks: Dictionary = {}
	var result := Animation.new()
	result.length = clip.length
	result.loop_mode = clip.loop_mode
	for i in target.get_bone_count():
		if not source_bones.has(i):
			continue
		var parent := target.get_bone_parent(i)
		var shape: Quaternion = alignment.get(parent, Quaternion.IDENTITY)
		var children: Array[int] = []
		for child in target.get_bone_count():
			if target.get_bone_parent(child) == i and source_bones.has(child):
				children.append(child)
		if profile_names[i] == "Hips":
			var spine := target.find_bone(_name("Spine", mapping))
			children.assign([spine] if spine >= 0 and source_bones.has(spine) else [])
		if children.size() == 1:
			var child := children[0]
			var ours := target_rest[child].origin - target_rest[i].origin
			var theirs := source_rest[source_bones[child]].origin - source_rest[source_bones[i]].origin
			if not ours.is_zero_approx() and not theirs.is_zero_approx():
				shape = Quaternion(ours.normalized(), (rotation * theirs).normalized())
		alignment[i] = shape
		var track := result.add_track(Animation.TYPE_ROTATION_3D)
		result.track_set_path(track, NodePath("Skeleton3D:" + target.get_bone_name(i)))
		tracks[i] = track
	var hips := target.find_bone(_name("Hips", mapping))
	var source_hips := source.find_bone("Hips")
	if hips < 0 or source_hips < 0 or is_zero_approx(source_rest[source_hips].origin.y):
		return null
	var hip_track := result.add_track(Animation.TYPE_POSITION_3D)
	result.track_set_path(hip_track, NodePath("Skeleton3D:" + target.get_bone_name(hips)))
	var scale := target_rest[hips].origin.y / source_rest[source_hips].origin.y
	var samples := maxi(1, ceili(clip.length * float(cfg["sample_hz"])))
	for sample in samples + 1:
		var time := clip.length * float(sample) / samples
		var poses := sample_globals(clip, source, time)
		var target_global: Dictionary = {}
		for i in target.get_bone_count():
			var parent := target.get_bone_parent(i)
			var rest_rotation := target_rest[i].basis.get_rotation_quaternion()
			var desired := rest_rotation
			if source_bones.has(i):
				var src: int = source_bones[i]
				desired = rotation * poses[src].basis.get_rotation_quaternion() * source_rest[src].basis.get_rotation_quaternion().inverse() * rotation.inverse() * alignment[i] * rest_rotation
			target_global[i] = desired.normalized()
			if tracks.has(i):
				var local_rotation: Quaternion = desired if parent < 0 else (target_global[parent] as Quaternion).inverse() * desired
				result.rotation_track_insert_key(tracks[i], time, local_rotation.normalized())
		var displacement := rotation * (poses[source_hips].origin - source_rest[source_hips].origin) * scale
		displacement.x = 0.0
		displacement.z = 0.0
		result.position_track_insert_key(hip_track, time, target_rest[hips].origin + displacement)
	_baked[key] = result
	return result
