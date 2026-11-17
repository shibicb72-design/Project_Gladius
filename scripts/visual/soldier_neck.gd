class_name SoldierNeck
extends SkeletonModifier3D
## M2 AN3 (OQ-ANIM-HEAD): the neck follows the chest, so the head does not bobble on a body that moves under it.
## Runs after SoldierGait, SoldierPose and SoldierCrawl (SoldierModel keeps it last). The Neck (a root bone) points
## from the chest top to the helmet centre and takes neck_follow of the chest's yaw (following the chest's whole
## turn pitched the helmet about its centre and swung the neck base away from a hunched chest: measured, M2 AN3),
## never more than neck_max_deg [pitch, yaw, roll] away from the chest, low-passed
## (1 - exp(-dt / neck_smooth_s), at most neck_max_rate_dps: no spring, no overshoot). It turns about the head hitbox
## centre (the Head bone's origin, where the layers below put it), so the helmet and its hitbox never part; the neck
## base swings toward the chest top instead. The Head keeps its own turn but stays within head_max_deg of the chest.
## Crouched in cover the limits move toward exceptions.cover_crouch. Numbers: data/anim_third_person.json "head".
## Under SoldierRig.head_legacy it does nothing. Presentation only: bones of the visual skeleton, never the hitbox.

var gait: SoldierGait  # for the cover crouch weight (may be null)
var pose: SoldierPose  # for the downed / revive weights (may be null)
## The shown Neck rotation (model frame) and its target this frame (tests).
var shown := Quaternion.IDENTITY
var target := Quaternion.IDENTITY
var _started := false
var _neck := -1
var _head := -1
var _chest := -1
var _neck_from_chest := Transform3D.IDENTITY


func setup() -> void:
	var skeleton := get_skeleton()
	_neck = skeleton.find_bone("Neck")
	_head = skeleton.find_bone("Head")
	_chest = skeleton.find_bone("Chest")
	_neck_from_chest = skeleton.get_bone_global_rest(_chest).affine_inverse() * skeleton.get_bone_global_rest(_neck)


static func _clamp(q: Quaternion, limits: Vector3) -> Quaternion:
	var e := Basis(q).get_euler()
	e = Vector3(clampf(e.x, -limits.x, limits.x), clampf(e.y, -limits.y, limits.y), clampf(e.z, -limits.z, limits.z))
	return Basis.from_euler(e).get_rotation_quaternion()


func _limits(cfg: Dictionary, key: String) -> Vector3:
	var base := LowpolyKit.vec(cfg[key])
	var crouch := clampf(maxf(gait.cover_crouch, gait.free_crouch), 0.0, 1.0) if gait != null else 0.0  # stage C: the free crouch too
	var exceptions: Dictionary = cfg.get("exceptions", {})
	if crouch > 0.0 and exceptions.has("cover_crouch") and (exceptions["cover_crouch"] as Dictionary).has(key):
		base = base.lerp(LowpolyKit.vec(exceptions["cover_crouch"][key]), crouch)
	return base * (PI / 180.0)


func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	var cfg := SoldierRig.head_cfg()
	if skeleton == null or cfg.is_empty() or _neck < 0 or _head < 0 or _chest < 0:
		_started = false
		return
	# Downed and reviving already carry the neck on the chest (SoldierCrawl, SoldierPose._carry_neck): this fades out.
	var weight := 1.0
	if pose != null:
		weight = 1.0 - clampf(maxf(float(pose.weights["downed"]), float(pose.weights["revive"])), 0.0, 1.0)
	if weight <= 0.0:
		_started = false
		return
	var neck := skeleton.get_bone_global_pose(_neck)
	var head_local := skeleton.get_bone_pose(_head)
	var centre := (neck * head_local).origin  # the helmet's centre: stays where it is
	var chest := skeleton.get_bone_global_pose(_chest)
	var chest_q := chest.basis.get_rotation_quaternion()
	var neck_limits := _limits(cfg, "neck_max_deg")
	# The neck points from the chest top to the helmet centre (so its base sits on the chest), and takes neck_follow
	# of the chest's yaw; then it stays within neck_max_deg of the chest.
	var along := centre - (chest * _neck_from_chest).origin
	var swing := Quaternion(Vector3.UP, along.normalized()) if along.length() > 0.0001 else Quaternion.IDENTITY
	var chest_yaw := Quaternion(0.0, chest_q.y, 0.0, chest_q.w)
	chest_yaw = chest_yaw.normalized() if chest_yaw.length_squared() > 0.000001 else Quaternion.IDENTITY
	target = swing * Quaternion.IDENTITY.slerp(chest_yaw, float(cfg["neck_follow"]))
	target = (chest_q * _clamp(chest_q.inverse() * target, neck_limits)).normalized()
	# The neck's own tilt from upright stays within neck_tilt_max_deg (the neck and neck guard keep their clearance
	# under the head hitbox), except where the whole body turns or folds: the fall and landing poses, the crouched hug.
	var free := clampf(maxf(gait.cover_crouch, gait.free_crouch), 0.0, 1.0) if gait != null else 0.0
	if pose != null:
		free = maxf(free, maxf(float(pose.weights["fall"]), float(pose.weights["land"])))
	var tilt_max := lerpf(deg_to_rad(float(cfg["neck_tilt_max_deg"])), PI, free)
	var up := target * Vector3.UP
	var tilt := up.angle_to(Vector3.UP)
	if tilt > tilt_max and tilt > 0.000001:
		var swing_up := Quaternion(Vector3.UP, up.normalized())
		target = (Quaternion.IDENTITY.slerp(swing_up, tilt_max / tilt) * swing_up.inverse() * target).normalized()
	if not _started:
		shown = target
		_started = true
	else:
		var gap := shown.angle_to(target)
		if gap > 0.000001:
			var tau := float(cfg["neck_smooth_s"])
			var step := gap * ((1.0 - exp(-delta / tau)) if tau > 0.0 else 1.0)
			step = minf(step, deg_to_rad(float(cfg["neck_max_rate_dps"])) * delta)
			shown = shown.slerp(target, step / gap).normalized()
	# The hard limit against the chest (a fast chest may outrun the low-pass).
	shown = (chest_q * _clamp(chest_q.inverse() * shown, neck_limits)).normalized()
	var layer_head := neck.basis.get_rotation_quaternion() * head_local.basis.get_rotation_quaternion()
	var neck_q := neck.basis.get_rotation_quaternion().slerp(shown, weight).normalized()
	skeleton.set_bone_pose_rotation(_neck, neck_q)
	skeleton.set_bone_pose_position(_neck, centre - neck_q * head_local.origin)
	# The Head keeps its own turn, within head_max_deg of the chest (turning about its own origin: the hitbox centre).
	var head_q := shown * head_local.basis.get_rotation_quaternion()
	var limited := layer_head.slerp(chest_q * _clamp(chest_q.inverse() * head_q, _limits(cfg, "head_max_deg")), weight)
	skeleton.set_bone_pose_rotation(_head, (neck_q.inverse() * limited).normalized())
