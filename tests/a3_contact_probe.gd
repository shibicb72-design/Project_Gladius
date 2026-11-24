extends RefCounted
## A3 item 1: ground contact probe (a helper, not a test: tests/run_tests.gd only collects files named test_*.gd).
## Given a soldier's skinned mesh, its Skin and the skeleton it is skinned to, it returns per body part the height
## of the part's LOWEST SKINNED VERTEX above a flat floor, from the live bone global poses (the vertex skinned on the
## CPU exactly as the GPU does: sum over its influences of weight x bone_global_pose x bind_pose x rest vertex).
##
## Vertex sets, by each vertex's DOMINANT influence (the bone with the largest weight; ties keep the first):
## - hand_l / hand_r: dominated by LeftHand or LeftFingers (RightHand or RightFingers).
## - heel_l / heel_r: dominated by LeftFoot (RightFoot), not the Toes bone, and in the rear half of the boot: the
##   rest vertex lies behind the Foot bone's rest origin (rest z >= the bone's rest z; the soldier faces -Z).
## - knee_l / knee_r: dominated by LeftUpperLeg or LeftLowerLeg (Right...) and within knee_radius_m (data:
##   anim_third_person.json contact.knee_radius_m) of the knee joint, the LowerLeg bone's rest origin.
## - hips: dominated by Hips.
## Left out of every set: the cape (the soldier shader's sway surface), which the vertex shader displaces.
## Duplicate vertices (same rest position and influences, split only for normals or UVs) are measured once.

const PARTS: Array[String] = ["hand_l", "hand_r", "knee_l", "knee_r", "heel_l", "heel_r", "hips"]

## Per part: rest positions, and per vertex 4 bind indices and 4 weights (flattened).
var _positions := {}
var _binds := {}
var _weights := {}
var _bind_bone := PackedInt32Array()
var _bind_pose: Array[Transform3D] = []
var _palette: Array[Transform3D] = []


static func make(mesh: Mesh, skin: Skin, skeleton: Skeleton3D, knee_radius_m: float):
	var probe = load("res://tests/a3_contact_probe.gd").new()
	probe._build(mesh, skin, skeleton, knee_radius_m)
	return probe


func _build(mesh: Mesh, skin: Skin, skeleton: Skeleton3D, knee_radius_m: float) -> void:
	for k in skin.get_bind_count():
		var bone := skin.get_bind_bone(k)
		if bone < 0:
			bone = skeleton.find_bone(skin.get_bind_name(k))
		_bind_bone.append(bone)
		_bind_pose.append(skin.get_bind_pose(k))
	_palette.resize(_bind_bone.size())
	var owner := {}  # bone name -> part
	for side in [["Left", "_l"], ["Right", "_r"]]:
		owner[side[0] + "Hand"] = "hand" + side[1]
		owner[side[0] + "Fingers"] = "hand" + side[1]
		owner[side[0] + "Foot"] = "heel" + side[1]
		owner[side[0] + "UpperLeg"] = "knee" + side[1]
		owner[side[0] + "LowerLeg"] = "knee" + side[1]
	owner["Hips"] = "hips"
	for part in PARTS:
		_positions[part] = PackedVector3Array()
		_binds[part] = PackedInt32Array()
		_weights[part] = PackedFloat32Array()
	var seen := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or bones.is_empty():
			continue
		# The cape (the soldier shader's sway surface, UV2.x) is cloth the vertex shader moves (cape_lift, ripple), so
		# the CPU skin is not where it is drawn: it is no part of a hand, knee, heel or the hips and is left out.
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
		var sway := -1
		var material := mesh.surface_get_material(surface) as ShaderMaterial
		if material != null and material.get_shader_parameter(&"sway_surface") != null:
			sway = int(material.get_shader_parameter(&"sway_surface"))
		var per: int = floori(float(bones.size()) / float(vertices.size()))
		for v in vertices.size():
			if sway >= 0 and not uv2.is_empty() and roundi(uv2[v].x) == sway:
				continue
			var best := -1
			var best_w := -1.0
			for j in per:
				if weights[v * per + j] > best_w:
					best_w = weights[v * per + j]
					best = bones[v * per + j]
			var bone_name := String(skeleton.get_bone_name(_bind_bone[best]))
			if not owner.has(bone_name):
				continue
			var part: String = owner[bone_name]
			var rest := vertices[v]
			if part.begins_with("heel") and rest.z < skeleton.get_bone_global_rest(_bind_bone[best]).origin.z:
				continue  # the boot's front half (toward the toes)
			if part.begins_with("knee"):
				var knee := skeleton.get_bone_global_rest(skeleton.find_bone(("Left" if part.ends_with("_l") else "Right") + "LowerLeg")).origin
				if rest.distance_to(knee) > knee_radius_m:
					continue
			# The four strongest influences (the soldier meshes carry at most 4; tests/test_soldier_glb.gd).
			var key := "%s|%.5f,%.5f,%.5f|" % [part, rest.x, rest.y, rest.z]
			var b4 := PackedInt32Array([0, 0, 0, 0])
			var w4 := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
			for j in mini(per, 4):
				b4[j] = bones[v * per + j]
				w4[j] = weights[v * per + j]
				key += "%d:%.4f," % [b4[j], w4[j]]
			if seen.has(key):
				continue
			seen[key] = true
			# Packed arrays are values: append to the stored one through a local copy and store it back.
			var positions: PackedVector3Array = _positions[part]
			positions.append(rest)
			_positions[part] = positions
			var binds: PackedInt32Array = _binds[part]
			binds.append_array(b4)
			_binds[part] = binds
			var weights_out: PackedFloat32Array = _weights[part]
			weights_out.append_array(w4)
			_weights[part] = weights_out


## Vertex count per part (a part with none would measure nothing: the test asserts every part has some).
func counts() -> Dictionary:
	var out := {}
	for part in PARTS:
		out[part] = (_positions[part] as PackedVector3Array).size()
	return out


## Per part, the lowest skinned vertex's height above the floor plane y = floor_y (metres; negative = below it).
## globals: every bone's global pose in the skeleton's frame (Skeleton3D.get_bone_global_pose, or SoldierModel's
## pose_cache, the drawn pose of the frame); to_world: the skeleton's global transform.
func lowest(globals: Array[Transform3D], to_world: Transform3D, floor_y: float) -> Dictionary:
	for k in _bind_bone.size():
		_palette[k] = to_world * globals[_bind_bone[k]] * _bind_pose[k]
	var out := {}
	for part in PARTS:
		var positions: PackedVector3Array = _positions[part]
		var binds: PackedInt32Array = _binds[part]
		var weights: PackedFloat32Array = _weights[part]
		var low := INF
		for v in positions.size():
			var y := 0.0
			for j in 4:
				var w := weights[v * 4 + j]
				if w > 0.0:
					y += w * (_palette[binds[v * 4 + j]] * positions[v]).y
			if y < low:
				low = y
				lowest_rest[part] = positions[v]
		out[part] = low - floor_y
	return out


## After lowest(): per part, the rest (mesh-space) position of the vertex that was lowest (diagnostics).
var lowest_rest := {}


## lowest() on a skeleton's current pose.
func lowest_of(skeleton: Skeleton3D, floor_y: float) -> Dictionary:
	var globals: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		globals.append(skeleton.get_bone_global_pose(i))
	return lowest(globals, skeleton.global_transform, floor_y)
