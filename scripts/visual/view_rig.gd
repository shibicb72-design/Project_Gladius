class_name ViewRig
extends RefCounted
## M2 AN1: assembles a first-person weapon with its arms (ViewWeapons + ViewHands) and, every frame, poses its moving
## parts from ViewMotion: the energy cell and charging handle during the reload, and the left hand's reach (to the cell,
## to the charging handle, to the pickup point) with its finger pose. Presentation only; called by ViewModel.


## One weapon's node: hold pose (meta "hold", camera.json view_model weapons.<id>), for guns the red dot and the ADS
## pose (meta "ads"), and the arms placed by art_soldier.json weapons.<id>.hands (meta "rest" = the placed transform,
## "elbow", "pose"; a camera-frame hand also keeps "view_xf" and "elbow_view").
static func build_weapon(id: String, wc: Dictionary, fallback: String, dot_radius: float, dot_color: Color) -> Node3D:
	var node := ViewWeapons.build(id, fallback)
	var hold := Transform3D(ViewMesh.euler_deg(wc["hold_rot_deg"]), ViewMesh.vec(wc["hold_m"]))
	node.set_meta(&"hold", hold)
	node.transform = hold
	var art_id := String(node.get_meta(&"art_id"))
	var anchor := node.get_node_or_null("SightAnchor") as Marker3D
	if anchor != null:
		# Fix 8: the red dot in the sight window (art dot_m), and the ADS pose that puts it on the camera's centre ray
		# at ads_dot_m (camera frame) with the gun turned by ads_rot_deg (0 = straight ahead).
		var dot_at := ViewWeapons.dot_position(art_id)
		_add_red_dot(anchor, dot_at - anchor.position, dot_radius, dot_color)
		if wc.has("ads_dot_m"):
			var ads_basis := ViewMesh.euler_deg(wc.get("ads_rot_deg", [0.0, 0.0, 0.0]))
			node.set_meta(&"ads", Transform3D(ads_basis, ViewMesh.vec(wc["ads_dot_m"]) - ads_basis * dot_at))
	for side in ["r", "l"]:
		var h := ViewWeapons.hand(art_id, side)
		if h.is_empty():
			continue
		var arm := ViewHands.build_arm(side)
		node.add_child(arm)
		var xf := Transform3D(ViewHands.placement_basis(h), ViewMesh.vec(h["at"]))
		var elbow := ViewMesh.vec(h["elbow"])
		if String(h.get("frame", "weapon")) == "view":
			arm.set_meta(&"view_xf", xf)  # placed in the camera frame: apply_parts keeps it there as the weapon moves
			arm.set_meta(&"elbow_view", elbow)
			xf = hold.affine_inverse() * xf
			elbow = hold.affine_inverse() * elbow
		if h.has("elbow_view") and String(h.get("frame", "weapon")) != "view":
			# M2 AN1 3b: the elbow belongs to the body, not the gun: kept in the pivot (camera) frame, so a tilted or
			# raised gun (reload, sprint, ADS) swings the forearm about a fixed elbow instead of carrying the elbow along.
			arm.set_meta(&"elbow_pivot", ViewMesh.vec(h["elbow_view"]))
			elbow = hold.affine_inverse() * ViewMesh.vec(h["elbow_view"])
		arm.transform = xf
		arm.set_meta(&"rest", xf)
		arm.set_meta(&"elbow", elbow)
		arm.set_meta(&"pose", String(h.get("pose", "grip")))
		ViewHands.apply_pose(arm, ViewHands.pose(String(h.get("pose", "grip"))))
		ViewHands.aim_forearm(arm, xf.affine_inverse() * elbow)
	return node


## A small unshaded, glowing disc (a low sphere, the same from every side) for the sight; colour and size are data.
static func _add_red_dot(anchor: Node3D, at: Vector3, r: float, color: Color) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	sphere.material = mat
	var dot := MeshInstance3D.new()
	dot.name = "RedDot"
	dot.mesh = sphere
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dot.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	anchor.add_child(dot)
	dot.position = at


## The reload's cell and charging handle, and the left hand's reach (reload anchors from art_soldier.json, the pickup
## reach from anim.json, in the camera frame: `pivot_xf` is the view model's pivot) with its finger pose blended.
static func apply_parts(weapon: Node3D, motion: ViewMotion, pivot_xf: Transform3D) -> void:
	var cell := weapon.get_node_or_null("Cell") as Node3D
	if cell != null:
		var rest: Transform3D = cell.get_meta(&"rest")
		var off := motion.cell_offset()
		cell.transform = Transform3D(off.basis * rest.basis, rest.origin + off.origin)
	var charge := weapon.get_node_or_null("Charge") as Node3D
	if charge != null:
		var crest: Transform3D = charge.get_meta(&"rest")
		charge.transform = Transform3D(crest.basis, crest.origin + motion.charge_offset())
	var right := weapon.get_node_or_null("RightArm") as Node3D
	if right != null and right.has_meta(&"elbow_pivot"):
		var r_elbow := weapon.transform.affine_inverse() * (right.get_meta(&"elbow_pivot") as Vector3)
		ViewHands.aim_forearm(right, right.transform.affine_inverse() * r_elbow)
	var arm := weapon.get_node_or_null("LeftArm") as Node3D
	if arm == null:
		return
	var rest_xf: Transform3D = arm.get_meta(&"rest")
	var elbow: Vector3 = arm.get_meta(&"elbow")
	if arm.has_meta(&"elbow_pivot"):
		elbow = weapon.transform.affine_inverse() * (arm.get_meta(&"elbow_pivot") as Vector3)
	if arm.has_meta(&"view_xf"):
		# A camera-frame hand (the blade's free left hand) stays put while the weapon swings and turns; it only follows
		# the weapon's lowering.
		var hold: Transform3D = weapon.get_meta(&"hold")
		var drop := Transform3D(Basis.IDENTITY, Vector3(0.0, minf(weapon.transform.origin.y - hold.origin.y, 0.0), 0.0))
		var to_weapon := weapon.transform.affine_inverse() * drop * motion.swing_xf().affine_inverse()
		rest_xf = to_weapon * (arm.get_meta(&"view_xf") as Transform3D)
		elbow = to_weapon * (arm.get_meta(&"elbow_view") as Vector3)
	var lh := motion.left_hand()
	var xf := rest_xf
	var w := float(lh["weight"])
	var target: Variant = _left_target(weapon, String(lh["target"]), cell, charge, motion, pivot_xf)
	if w > 0.0 and target != null:
		xf = rest_xf.interpolate_with(target, w)
		# M2 AN1 3b: a reach anchor may carry its own elbow, so the forearm swings down and out with the hand instead
		# of pointing from the cell back at the eye.
		var reach_elbow: Variant = _left_elbow(weapon, String(lh["target"]), motion, pivot_xf)
		if reach_elbow != null:
			elbow = elbow.lerp(reach_elbow, clampf(w, 0.0, 1.0))
	arm.transform = xf
	var rest_pose := String(arm.get_meta(&"pose"))
	var pose := ViewHands.pose(rest_pose)
	if String(lh["pose"]) != "":
		var from := ViewHands.pose(String(lh["pose_from"]) if String(lh["pose_from"]) != "" else rest_pose)
		pose = ViewHands.blend_poses(from, ViewHands.pose(String(lh["pose"])), clampf(float(lh["pose_t"]), 0.0, 1.0))
		pose = ViewHands.blend_poses(ViewHands.pose(rest_pose), pose, clampf(w, 0.0, 1.0))
	ViewHands.apply_pose(arm, pose)
	ViewHands.aim_forearm(arm, xf.affine_inverse() * elbow)


## M2 AN2 item 4b: a clip frame (ViewMotion.clip_frame bones) copied onto the weapon's parts: Cell / Charge local
## transforms, each arm's placement (R_hand / L_hand; a root hand is in the camera frame and kept there), its finger
## bones (R_<finger>_<s> -> the arm skeleton's <finger>_<s>) and its forearm aimed at the clip's elbow (camera frame).
static func apply_clip(weapon: Node3D, bones: Dictionary, cs: ViewMotion.ClipSet) -> void:
	for sub in ["Cell", "Charge"]:
		var n := weapon.get_node_or_null(sub) as Node3D
		if n != null and bones.has(sub):
			n.transform = bones[sub]
	for side in ["r", "l"]:
		var arm := weapon.get_node_or_null("RightArm" if side == "r" else "LeftArm") as Node3D
		var pre := String(side).to_upper() + "_"
		if arm == null or not bones.has(pre + "hand"):
			continue
		var xf: Transform3D = bones[pre + "hand"]
		if String(cs.parents.get(pre + "hand", "")) == "":
			xf = weapon.transform.affine_inverse() * xf  # a camera-frame hand (the blade's free hand) stays in the view
		arm.transform = xf
		var skel := arm.get_node("Skeleton") as Skeleton3D
		for n in ViewHands.bone_names():
			if n != "hand" and n != "forearm" and bones.has(pre + n):
				skel.set_bone_pose_rotation(skel.find_bone(n), (bones[pre + n] as Transform3D).basis.get_rotation_quaternion())
		if bones.has(pre + "elbow"):
			var elbow: Vector3 = (bones[pre + "elbow"] as Transform3D).origin
			ViewHands.aim_forearm(arm, (weapon.transform * xf).affine_inverse() * elbow)


const _PARTS: Array[String] = ["Cell", "Charge", "RightArm", "LeftArm"]


## The parts' current pose (node transforms and arm bone rotations) for a fade.
static func capture_parts(weapon: Node3D) -> Dictionary:
	var out := {}
	for p in _PARTS:
		var n := weapon.get_node_or_null(p) as Node3D
		if n == null:
			continue
		out[p] = n.transform
		var skel := n.get_node_or_null("Skeleton") as Skeleton3D
		if skel != null:
			var rots: Array[Quaternion] = []
			for i in skel.get_bone_count():
				rots.append(skel.get_bone_pose_rotation(i))
			out[p + ":bones"] = rots
	return out


## Blends the parts from a captured pose `from` toward their current pose by w (0 = from, 1 = as now).
static func blend_parts(weapon: Node3D, from: Dictionary, w: float) -> void:
	for p in _PARTS:
		var n := weapon.get_node_or_null(p) as Node3D
		if n == null or not from.has(p):
			continue
		n.transform = (from[p] as Transform3D).interpolate_with(n.transform, w)
		var skel := n.get_node_or_null("Skeleton") as Skeleton3D
		if skel != null and from.has(p + ":bones"):
			var rots: Array = from[p + ":bones"]
			for i in mini(rots.size(), skel.get_bone_count()):
				skel.set_bone_pose_rotation(i, (rots[i] as Quaternion).slerp(skel.get_bone_pose_rotation(i), w))


## The elbow (weapon frame) that goes with a reach target: art_soldier.json hands.l_cell / l_charge "elbow" (weapon
## frame), anim.json pickup "reach_elbow_view_m" (camera frame); null = keep the resting elbow.
static func _left_elbow(weapon: Node3D, target: String, motion: ViewMotion, pivot_xf: Transform3D) -> Variant:
	var hands: Dictionary = ViewWeapons.art(String(weapon.get_meta(&"art_id"))).get("hands", {})
	match target:
		"cell", "charge":
			var key := "l_" + target
			var h: Dictionary = hands.get(key, {})
			if h.has("elbow_view"):  # camera frame: the elbow stays low whatever the gun's tilt
				return weapon.transform.affine_inverse() * pivot_xf.affine_inverse() * ViewMesh.vec(h["elbow_view"])
			if h.has("elbow"):
				return ViewMesh.vec(h["elbow"])
		"reach":
			var p: Dictionary = motion.cfg["pickup"]
			if p.has("reach_elbow_view_m"):
				return weapon.transform.affine_inverse() * pivot_xf.affine_inverse() * ViewMesh.vec(p["reach_elbow_view_m"])
	return null


## The left hand's reach target in the weapon frame: on the cell (follows it out and in), on the charging handle, or
## the pickup reach point in front of the eye; null when the weapon has no such anchor.
static func _left_target(weapon: Node3D, target: String, cell: Node3D, charge: Node3D, motion: ViewMotion, pivot_xf: Transform3D) -> Variant:
	var hands: Dictionary = ViewWeapons.art(String(weapon.get_meta(&"art_id"))).get("hands", {})
	match target:
		"cell":
			if cell != null and hands.has("l_cell"):
				return cell.transform * Transform3D(ViewHands.placement_basis(hands["l_cell"]), ViewMesh.vec(hands["l_cell"]["at"]))
		"charge":
			if charge != null and hands.has("l_charge"):
				var crest: Transform3D = charge.get_meta(&"rest")
				return Transform3D(crest.basis, charge.position) * Transform3D(ViewHands.placement_basis(hands["l_charge"]), ViewMesh.vec(hands["l_charge"]["at"]))
		"reach":
			var p: Dictionary = motion.cfg["pickup"]
			var view := Transform3D(ViewHands.placement_basis({"fingers": p["reach_fingers"], "back": p["reach_back"]}), ViewMesh.vec(p["reach_view_m"]))
			return weapon.transform.affine_inverse() * pivot_xf.affine_inverse() * view  # camera frame, not lowered
	return null
