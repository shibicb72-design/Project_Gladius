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
	var arm := weapon.get_node_or_null("LeftArm") as Node3D
	if arm == null:
		return
	var rest_xf: Transform3D = arm.get_meta(&"rest")
	var elbow: Vector3 = arm.get_meta(&"elbow")
	if arm.has_meta(&"view_xf"):
		# A camera-frame hand (the blade's free left hand) stays put while the weapon swings and turns; it only follows
		# the weapon's lowering.
		var hold: Transform3D = weapon.get_meta(&"hold")
		var drop := Transform3D(Basis.IDENTITY, Vector3(0.0, minf(weapon.transform.origin.y - hold.origin.y, 0.0), 0.0))
		var to_weapon := weapon.transform.affine_inverse() * drop
		rest_xf = to_weapon * (arm.get_meta(&"view_xf") as Transform3D)
		elbow = to_weapon * (arm.get_meta(&"elbow_view") as Vector3)
	var lh := motion.left_hand()
	var xf := rest_xf
	var w := float(lh["weight"])
	var target: Variant = _left_target(weapon, String(lh["target"]), cell, charge, motion, pivot_xf)
	if w > 0.0 and target != null:
		xf = rest_xf.interpolate_with(target, w)
	arm.transform = xf
	var rest_pose := String(arm.get_meta(&"pose"))
	var pose := ViewHands.pose(rest_pose)
	if String(lh["pose"]) != "":
		var from := ViewHands.pose(String(lh["pose_from"]) if String(lh["pose_from"]) != "" else rest_pose)
		pose = ViewHands.blend_poses(from, ViewHands.pose(String(lh["pose"])), clampf(float(lh["pose_t"]), 0.0, 1.0))
		pose = ViewHands.blend_poses(ViewHands.pose(rest_pose), pose, clampf(w, 0.0, 1.0))
	ViewHands.apply_pose(arm, pose)
	ViewHands.aim_forearm(arm, xf.affine_inverse() * elbow)


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
