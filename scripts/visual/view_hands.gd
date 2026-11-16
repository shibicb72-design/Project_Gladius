class_name ViewHands
extends RefCounted
## M2 AN1: the first-person gloved hands and forearms. Each arm is ONE skinned mesh (one draw call) on a small
## code-built Skeleton3D with rigid per-segment weights (the SoldierRig technique): hand (root, at the wrist),
## forearm, four fingers of three segments and a thumb of three. Shapes and finger poses are data/art_soldier.json
## "hands" (OQ-ART-SOLDIER placeholders). The right arm is authored; the left is its mirror in x.
## Hand frame (right hand): origin at the wrist, fingers along -z, back of the hand +y, thumb on -x; the forearm
## runs from the wrist along +z at rest and is turned toward the elbow by aim_forearm.
## Finger poses are per-joint curl angles in degrees (flexion toward the palm), blendable (blend_poses).

const FINGERS: Array[String] = ["index", "middle", "ring", "pinky", "thumb"]
const SEGMENTS := 3

static var _cache := {}  # side -> {"mesh", "rests", "verts", "bones", "triangles"}


static func cfg() -> Dictionary:
	return ViewMesh.config()["hands"]


static func bone_names() -> Array[String]:
	var out: Array[String] = ["hand", "forearm"]
	for f in FINGERS:
		for s in SEGMENTS:
			out.append("%s_%d" % [f, s])
	return out


static func _parent_of(bone: String) -> String:
	if bone == "hand":
		return ""
	if bone == "forearm":
		return "hand"
	var parts := bone.split("_")
	var seg := int(parts[1])
	return "hand" if seg == 0 else "%s_%d" % [parts[0], seg - 1]


## Local rest transforms (right hand), by bone name.
static func _right_rests() -> Dictionary:
	var c := cfg()
	var rests := {"hand": Transform3D.IDENTITY, "forearm": Transform3D.IDENTITY}
	for f in FINGERS:
		var fd: Dictionary = c["fingers"][f]
		var lengths: Array = fd["lengths"]
		rests["%s_0" % f] = Transform3D(_finger_basis(fd), ViewMesh.vec(fd["base"]))
		for s in range(1, SEGMENTS):
			rests["%s_%d" % [f, s]] = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -float(lengths[s - 1])))
	return rests


## A finger's base frame: "dir" (where the straight finger points) and "up" (its back; curling bends it toward -up),
## or a "rot" euler in degrees.
static func _finger_basis(fd: Dictionary) -> Basis:
	if not fd.has("dir"):
		return ViewMesh.euler_deg(fd.get("rot", [0, 0, 0]))
	var z := -ViewMesh.vec(fd["dir"]).normalized()
	var up := ViewMesh.vec(fd.get("up", [0, 1, 0]))
	var y := (up - z * up.dot(z)).normalized()
	return Basis(y.cross(z), y, z)


## A hand's placement basis: "fingers" (where the straight fingers point) and "back" (the back of the hand), or a
## "rot" euler with an optional "turn" euler applied after it, in degrees.
static func placement_basis(h: Dictionary) -> Basis:
	if h.has("fingers"):
		return _finger_basis({"dir": h["fingers"], "up": h.get("back", [0, 1, 0])})
	return ViewMesh.euler_deg(h.get("turn", [0, 0, 0])) * ViewMesh.euler_deg(h.get("rot", [0, 0, 0]))


## x-mirror of a transform: M * t * M with M = diag(-1, 1, 1).
static func mirror_xf(t: Transform3D) -> Transform3D:
	var m := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	return Transform3D(m * t.basis * m, Vector3(-t.origin.x, t.origin.y, t.origin.z))


static func mirror_q(q: Quaternion) -> Quaternion:
	return Quaternion(q.x, -q.y, -q.z, q.w)


static func _side_data(side: String) -> Dictionary:
	if _cache.has(side):
		return _cache[side]
	var names := bone_names()
	var local := _right_rests()
	var global := {}
	for n in names:
		var p := _parent_of(n)
		global[n] = (global[p] as Transform3D) * (local[n] as Transform3D) if p != "" else local[n]
	var b := ViewMesh.Builder.new()
	b.skinned = true
	b.mirror = side == "l"
	var c := cfg()
	for part: Dictionary in c["parts"]:
		b.bone = names.find(String(part.get("bone", "hand")))
		ViewMesh.add_part(b, part)
	var sides := int(c.get("finger_sides", 6))
	var flat: Array = c.get("finger_scale", [1.0, 0.85])
	for f in FINGERS:
		var fd: Dictionary = c["fingers"][f]
		var lengths: Array = fd["lengths"]
		var radii: Array = fd["radius"]
		var overlap := float(c.get("finger_overlap_m", 0.004))
		for s in SEGMENTS:
			var bone := "%s_%d" % [f, s]
			b.bone = names.find(bone)
			var length := float(lengths[s])
			var r0 := lerpf(float(radii[0]), float(radii[1]), float(s) / SEGMENTS)
			var r1 := lerpf(float(radii[0]), float(radii[1]), float(s + 1) / SEGMENTS)
			var profile: Array = [[r0, overlap], [r0 * 1.04, -length * 0.35], [r1, -length]]
			if s == SEGMENTS - 1:
				profile = [[r0, overlap], [r1, -length * 0.7], [r1 * 0.55, -length]]
			b.use_material(String(fd.get("mat", "leather")))
			b.xf = global[bone]
			ViewMesh.lathe(b, profile, sides, "z", false, Vector2(float(flat[0]), float(flat[1])))
			# A bronze knuckle cap on the back of each finger's first segment (not the thumb).
			if s == 0 and f != "thumb" and c.has("finger_cap"):
				var cap: Dictionary = (c["finger_cap"] as Dictionary).duplicate()
				ViewMesh.add_part(b, cap, global[bone])
	b.xf = Transform3D.IDENTITY
	var rests := {}
	for n in names:
		rests[n] = mirror_xf(local[n]) if side == "l" else local[n]
	var vb := b.vertices_and_bones()
	var data := {"mesh": b.finish(), "rests": rests, "verts": vb[0], "bones": vb[1], "triangles": b.triangle_count()}
	_cache[side] = data
	return data


## A new arm node: "RightArm" / "LeftArm" (origin = the wrist) > Skeleton3D "Skeleton" > MeshInstance3D "Mesh".
static func build_arm(side: String) -> Node3D:
	var data := _side_data(side)
	var arm := Node3D.new()
	arm.name = "RightArm" if side == "r" else "LeftArm"
	arm.set_meta(&"side", side)
	var skel := Skeleton3D.new()
	skel.name = "Skeleton"
	arm.add_child(skel)
	var names := bone_names()
	for n in names:
		var i := skel.add_bone(n)
		var p := _parent_of(n)
		if p != "":
			skel.set_bone_parent(i, skel.find_bone(p))
		skel.set_bone_rest(i, data["rests"][n])
	skel.reset_bone_poses()
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = data["mesh"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	skel.add_child(mi)
	mi.skin = skel.create_skin_from_rest_transforms()
	mi.skeleton = NodePath("..")
	mi.set_meta(&"skinned_arm", true)
	return arm


static func triangles_per_arm(side: String = "r") -> int:
	return int(_side_data(side)["triangles"])


## Named pose from data (hands.poses), as {finger: [curl deg x3], "spread": [deg x5], "thumb_swing": deg}.
static func pose(pose_name: String) -> Dictionary:
	var poses: Dictionary = cfg()["poses"]
	return poses.get(pose_name, poses["grip"])


static func pose_names() -> Array:
	return (cfg()["poses"] as Dictionary).keys()


## Per-joint blend of two poses (t = 0 -> a, 1 -> b).
static func blend_poses(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		if key.begins_with("_"):
			continue
		var va: Variant = a[key]
		var vb: Variant = b.get(key, va)
		if va is Array:
			var arr: Array = []
			for i in (va as Array).size():
				arr.append(lerpf(float(va[i]), float((vb as Array)[i]) if i < (vb as Array).size() else float(va[i]), t))
			out[key] = arr
		else:
			out[key] = lerpf(float(va), float(vb), t)
	return out


## Sets every finger bone of `arm` from `p` (curl about each bone's own x; spread about the base bone's y).
static func apply_pose(arm: Node3D, p: Dictionary) -> void:
	var skel := arm.get_node("Skeleton") as Skeleton3D
	var left := String(arm.get_meta(&"side", "r")) == "l"
	var local := _right_rests()
	var spread: Array = p.get("spread", [0, 0, 0, 0, 0])
	for fi in FINGERS.size():
		var f := FINGERS[fi]
		var curls: Array = p.get(f, [0, 0, 0])
		for s in SEGMENTS:
			var bone := "%s_%d" % [f, s]
			var q := (local[bone] as Transform3D).basis.get_rotation_quaternion()
			if s == 0:
				q = q * Quaternion(Vector3.UP, deg_to_rad(float(spread[fi])))
				if f == "thumb":
					q = q * Quaternion(Vector3.BACK, deg_to_rad(float(p.get("thumb_roll", 0.0))))
			q = q * Quaternion(Vector3.RIGHT, -deg_to_rad(float(curls[s])))
			skel.set_bone_pose_rotation(skel.find_bone(bone), mirror_q(q) if left else q)


## Turns the forearm (hand-frame direction from the wrist toward the elbow, in the arm node's space) and bends the
## hand at the wrist by `wrist` (Basis of the hand inside the arm node; identity = as placed).
static func aim_forearm(arm: Node3D, to_elbow: Vector3) -> void:
	var skel := arm.get_node("Skeleton") as Skeleton3D
	if to_elbow.length_squared() < 0.000001:
		return
	skel.set_bone_pose_rotation(skel.find_bone("forearm"), Quaternion(Vector3.BACK, to_elbow.normalized()))


## The arm's vertices posed on the CPU (rigid skinning), in the arm node's space: tests and reach checks see the
## pose the GPU draws.
static func posed_vertices(arm: Node3D) -> PackedVector3Array:
	var data := _side_data(String(arm.get_meta(&"side", "r")))
	var skel := arm.get_node("Skeleton") as Skeleton3D
	var mats: Array[Transform3D] = []
	for i in skel.get_bone_count():
		mats.append(skel.get_bone_global_pose(i) * skel.get_bone_global_rest(i).affine_inverse())
	var verts: PackedVector3Array = data["verts"]
	var bones: PackedInt32Array = data["bones"]
	var skel_xf := skel.transform
	var out := PackedVector3Array()
	out.resize(verts.size())
	for i in verts.size():
		out[i] = skel_xf * (mats[bones[i]] * verts[i])
	return out


## Fingertip positions (arm node space) for a quick contact check.
static func fingertips(arm: Node3D) -> Dictionary:
	var skel := arm.get_node("Skeleton") as Skeleton3D
	var c := cfg()
	var out := {}
	for f in FINGERS:
		var tip := skel.find_bone("%s_%d" % [f, SEGMENTS - 1])
		var length := float((c["fingers"][f]["lengths"] as Array)[SEGMENTS - 1])
		out[f] = skel.transform * (skel.get_bone_global_pose(tip) * Vector3(0, 0, -length))
	return out
