class_name SoldierCrawl
extends SkeletonModifier3D
## M2 AN1 commit 4: the downed knee-crawl, code-built (the UAL has no crawl). Runs after SoldierPose (which keeps the
## downed upper body: data/anim.json poses.downed bones) and takes over the hips, the legs and the neck by the
## downed weight. Both knees kneel on the ground with the shins laid back and the toes pointed; the knees step in
## turn: a planted knee stays where it touched while the body moves over it (its offset from the hip joint runs from
## +step/2 to -step/2 along the motion during the stance half of the cycle), then lifts and swings ahead. The cycle
## advances by ground distance / (2 x step_m), so a planted knee moves with the ground (no slide) at any speed; the
## hips ride on the planted thigh (height from its length and lean), the pelvis rolls with the step. Standing still,
## the cycle eases to a phase with both knees down. Numbers: data/anim_third_person.json "crawl" (OQ-ANIM placeholders).
## Presentation only: never the pawn, its collider or its (lowered) hitboxes.

var cfg: Dictionary = {}
## Pawn-local ground velocity (m/s), set by SoldierModel each frame.
var move_local := Vector3.ZERO
## 0..1, the downed blend (SoldierPose.weights["downed"]), set by SoldierModel each frame.
var weight := 0.0
## Cycle phase 0..1 (left leg: stance in [0, 0.5), right leg half a cycle later).
var phase := 0.0
var _bones := {}
var _joint := {}  # hip joint offset from the Hips bone, per side
var _thigh := 0.0
var _thigh_dir := Vector3.DOWN
var _shin_dir := Vector3.DOWN
var _neck_from_chest := Transform3D.IDENTITY
var _dir := Vector3.FORWARD


func setup() -> void:
	cfg = SoldierRig.config()["crawl"]
	var skeleton := get_skeleton()
	for name in ["Hips", "Spine", "Chest", "Neck", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]:
		_bones[name] = skeleton.find_bone(name)
	var hips := skeleton.get_bone_global_rest(_bones["Hips"])
	for side in ["Left", "Right"]:
		_joint[side] = skeleton.get_bone_global_rest(_bones[side + "UpperLeg"]).origin - hips.origin
	var knee := skeleton.get_bone_rest(_bones["LeftLowerLeg"]).origin
	_thigh = knee.length()
	_thigh_dir = knee.normalized()
	_shin_dir = skeleton.get_bone_rest(_bones["LeftFoot"]).origin.normalized()
	_neck_from_chest = skeleton.get_bone_global_rest(_bones["Chest"]).affine_inverse() * skeleton.get_bone_global_rest(_bones["Neck"])


## Offset of the knee from its hip joint along the motion (+ = ahead) and its lift, for a leg at phase p.
func knee_offset(p: float) -> Vector2:
	var step := float(cfg["step_m"])
	if p < 0.5:
		return Vector2(step * (0.5 - p * 2.0), 0.0)
	var s := (p - 0.5) * 2.0
	# The knee leaves the ground before it travels and lands after (lift rises like sqrt(sin), travel eases in/out).
	return Vector2(lerpf(-0.5, 0.5, smoothstep(0.0, 1.0, s)) * step, float(cfg["lift_m"]) * sqrt(sin(PI * s)))


func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or cfg.is_empty():
		return
	var ground := Vector2(move_local.x, move_local.z)
	var speed := ground.length()
	if speed > 0.05:
		_dir = Vector3(ground.x, 0.0, ground.y) / speed
		phase = fposmod(phase + speed * delta / (2.0 * float(cfg["step_m"])), 1.0)
	else:
		# Settle to both knees down (phase 0 or 0.5) at the settle rate.
		var goal := 0.5 if phase > 0.25 and phase <= 0.75 else (1.0 if phase > 0.75 else 0.0)
		phase = fposmod(move_toward(phase, goal, float(cfg["settle_cycles_s"]) * delta), 1.0)
	if weight <= 0.0:
		return
	var w := smoothstep(0.0, 1.0, weight)
	var lean := deg_to_rad(float(cfg["pelvis_pitch_deg"]))
	var stance := "Left" if phase < 0.5 else "Right"
	var swing := "Right" if stance == "Left" else "Left"
	# The planted thigh carries the hips: its joint sits at knee height + the thigh's vertical reach. The swing
	# side's hip hikes (the pelvis rolls) as far as its knee needs to clear the ground: a knee-walker's waddle.
	var planted := knee_offset(phase if stance == "Left" else fposmod(phase + 0.5, 1.0))
	var lifted := knee_offset(phase if swing == "Left" else fposmod(phase + 0.5, 1.0))
	var joint_y := float(cfg["knee_height_m"]) + sqrt(maxf(_thigh * _thigh - planted.x * planted.x, 0.0))
	var swing_y := float(cfg["knee_height_m"]) + lifted.y + sqrt(maxf(_thigh * _thigh - lifted.x * lifted.x, 0.0))
	var width := absf((_joint["Left"] as Vector3).x - (_joint["Right"] as Vector3).x)
	var roll := asin(clampf((swing_y - joint_y) / maxf(width, 0.01), -0.5, 0.5)) * (1.0 if swing == "Right" else -1.0)
	# Roll about the ground's forward axis (after the lean), so the hike moves the hip joints up and down only.
	var hips_basis := Basis(Vector3.BACK, roll) * Basis(Vector3.RIGHT, -lean)
	var hips_pos := Vector3(0.0, joint_y - (hips_basis * (_joint[stance] as Vector3)).y, float(cfg["body_back_m"]))
	var old_hips := skeleton.get_bone_global_pose(_bones["Hips"])
	var new_hips := Transform3D(Basis(old_hips.basis.get_rotation_quaternion().slerp(hips_basis.get_rotation_quaternion(), w)), old_hips.origin.lerp(hips_pos, w))
	skeleton.set_bone_pose_position(_bones["Hips"], new_hips.origin)
	skeleton.set_bone_pose_rotation(_bones["Hips"], new_hips.basis.get_rotation_quaternion())
	var crawl_hips := Transform3D(hips_basis, hips_pos)
	var shin_back := Vector3(0.0, sin(deg_to_rad(float(cfg["shin_rise_deg"]))), cos(deg_to_rad(float(cfg["shin_rise_deg"]))))
	for side in ["Left", "Right"]:
		var p := phase if side == "Left" else fposmod(phase + 0.5, 1.0)
		var offset := knee_offset(p)
		var joint := crawl_hips * (_joint[side] as Vector3)
		var knee := Vector3(joint.x, float(cfg["knee_height_m"]) + offset.y, joint.z) + _dir * offset.x
		var thigh := Quaternion(_thigh_dir, (knee - joint).normalized())
		var shin := Quaternion(_shin_dir, shin_back)
		_blend(skeleton, side + "UpperLeg", hips_basis.get_rotation_quaternion().inverse() * thigh, w)
		_blend(skeleton, side + "LowerLeg", thigh.inverse() * shin, w)
		_blend(skeleton, side + "Foot", Quaternion(Vector3.RIGHT, deg_to_rad(float(cfg["foot_point_deg"]))), w)
	# The neck rides on the chest top (the head hitbox note: downed head about poses.downed.head_height_m).
	var chest := new_hips * skeleton.get_bone_pose(_bones["Spine"]) * skeleton.get_bone_pose(_bones["Chest"])
	var carried := chest * _neck_from_chest
	var neck := skeleton.get_bone_pose(_bones["Neck"])
	skeleton.set_bone_pose_position(_bones["Neck"], neck.origin.lerp(carried.origin, w))
	skeleton.set_bone_pose_rotation(_bones["Neck"], neck.basis.get_rotation_quaternion().slerp(carried.basis.get_rotation_quaternion(), w))


func _blend(skeleton: Skeleton3D, bone: String, rotation: Quaternion, w: float) -> void:
	var index := int(_bones[bone])
	skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(rotation.normalized(), w))
