class_name SoldierCrawl
extends SkeletonModifier3D
## M2 AN1 commit 4: the downed knee-crawl, code-built (the UAL has no crawl). Runs after SoldierPose and takes
## over the hips, legs and neck by the downed weight. CX1 adds an alternating reach to the existing downed
## upper-body pose. Both knees kneel on the ground with the shins laid back and the toes pointed; the knees step in
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
var _arm_motion := 0.0
## A3 item 1: the hands plant like the knees (crawl.hands, OQ-A3-CONTACT): each hand is the diagonal partner of the
## opposite knee (the right hand steps with the left knee), stands where it touched while the body moves over it and
## swings ahead in the other half of the cycle; the arm is a two-bone solve from the shoulder, the hand keeps the
## planted orientation, and the elbow bends back and out. Standing still, both hands are down.
var _hands: Dictionary = {}
var _arm_len := {}  # side -> Vector2(upper arm, forearm) lengths


## A3: whether this hand is on the ground now (the plant is on and fully shown, and the hand is in its stance half).
func hand_planted(side: String) -> bool:
	if _hands.is_empty() or not bool(_hands.get("plant", false)) or weight < 1.0:
		return false
	return _hand_offset(_hand_phase(side)).y <= 0.0


func _hand_phase(side: String) -> float:
	return phase if side == "Right" else fposmod(phase + 0.5, 1.0)


## Like knee_offset (same step, so a planted hand moves with the ground), with the hands' own lift.
func _hand_offset(p: float) -> Vector2:
	var step := float(cfg["step_m"])
	if p < 0.5:
		return Vector2(step * (0.5 - p * 2.0), 0.0)
	var s := (p - 0.5) * 2.0
	return Vector2(lerpf(-0.5, 0.5, smoothstep(0.0, 1.0, s)) * step, float(_hands["lift_m"]) * sqrt(sin(PI * s)))


func setup() -> void:
	cfg = SoldierRig.config()["crawl"]
	var skeleton := get_skeleton()
	for name in ["Hips", "Spine", "Chest", "Neck", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
			"LeftUpperArm", "LeftForeArm", "RightUpperArm", "RightForeArm"]:
		_bones[name] = skeleton.find_bone(name)
	var hips := skeleton.get_bone_global_rest(_bones["Hips"])
	for side in ["Left", "Right"]:
		_joint[side] = skeleton.get_bone_global_rest(_bones[side + "UpperLeg"]).origin - hips.origin
	var knee := skeleton.get_bone_rest(_bones["LeftLowerLeg"]).origin
	_thigh = knee.length()
	_thigh_dir = knee.normalized()
	_shin_dir = skeleton.get_bone_rest(_bones["LeftFoot"]).origin.normalized()
	_neck_from_chest = skeleton.get_bone_global_rest(_bones["Chest"]).affine_inverse() * skeleton.get_bone_global_rest(_bones["Neck"])
	_hands = cfg.get("hands", {})
	for side in ["Left", "Right"]:
		_bones[side + "Hand"] = skeleton.find_bone(side + "Hand")
		_arm_len[side] = Vector2(skeleton.get_bone_rest(_bones[side + "ForeArm"]).origin.length(), skeleton.get_bone_rest(_bones[side + "Hand"]).origin.length())


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
		_arm_motion = 0.0
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
	if bool(_hands.get("plant", false)):
		# A3: the upper body takes back hands.counter_roll of the pelvis roll, so the hiking side's shoulder stays within
		# reach of its planted hand (the waddle stays in the pelvis and legs).
		var back := float(_hands.get("counter_roll", 0.0)) * w
		var level := hips_basis.inverse() * Basis(Vector3.BACK, -roll * back) * hips_basis
		var spine := int(_bones["Spine"])
		skeleton.set_bone_pose_rotation(spine, (level.get_rotation_quaternion() * skeleton.get_bone_pose_rotation(spine)).normalized())
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
	var chest := new_hips * skeleton.get_bone_pose(_bones["Spine"]) * skeleton.get_bone_pose(_bones["Chest"])
	if bool(_hands.get("plant", false)):
		for side in ["Left", "Right"]:
			_plant_hand(skeleton, chest, side, w)
	else:
		_move_arms(skeleton, speed, delta, w)
	# The neck rides on the chest top (the head hitbox note: downed head about poses.downed.head_height_m).
	var carried := chest * _neck_from_chest
	var neck := skeleton.get_bone_pose(_bones["Neck"])
	skeleton.set_bone_pose_position(_bones["Neck"], neck.origin.lerp(carried.origin, w))
	skeleton.set_bone_pose_rotation(_bones["Neck"], neck.basis.get_rotation_quaternion().slerp(carried.basis.get_rotation_quaternion(), w))


func _blend(skeleton: Skeleton3D, bone: String, rotation: Quaternion, w: float) -> void:
	var index := int(_bones[bone])
	skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(rotation.normalized(), w))


## A3: the hand on its ground point (skeleton frame = the pawn's, the floor at y 0). The ground point is fixed in the
## pawn frame (under the shoulder: ±width_m / 2, ahead_m) plus the step offset along the motion, at floor_m (the hand
## bone's height when the glove's lowest point is on the floor, in the planted orientation hand_deg). Out of reach,
## the arm straightens toward it (tests/test_a3_contact.gd measures what remains).
func _plant_hand(skeleton: Skeleton3D, chest: Transform3D, side: String, w: float) -> void:
	var sign_of_side := -1.0 if side == "Left" else 1.0
	var offset := _hand_offset(_hand_phase(side))
	var target := Vector3(sign_of_side * float(_hands["width_m"]) * 0.5, float(_hands["floor_m"]) + offset.y, float(_hands["ahead_m"])) + _dir * offset.x
	var upper := int(_bones[side + "UpperArm"])
	var fore := int(_bones[side + "ForeArm"])
	var hand := int(_bones[side + "Hand"])
	var root := (chest * skeleton.get_bone_pose(upper)).origin
	var lengths: Vector2 = _arm_len[side]
	var a := lengths.x
	var b := lengths.y
	var distance := clampf(root.distance_to(target), absf(a - b) + 0.001, a + b - 0.001)
	var direction := (target - root).normalized()
	var pole := LowpolyKit.vec(_hands["pole"]) * Vector3(sign_of_side, 1.0, 1.0)
	var bend := (pole - direction * pole.dot(direction)).normalized()
	var along := (a * a + distance * distance - b * b) / (2.0 * distance)
	var elbow := root + direction * along + bend * sqrt(maxf(a * a - along * along, 0.0))
	var end := root + direction * distance
	# Rest bases are identity, so a bone's global turn takes its rest offset direction onto the solved one.
	var first := skeleton.get_bone_rest(fore).origin.normalized()
	var second := skeleton.get_bone_rest(hand).origin.normalized()
	var upper_global := Quaternion(first, (elbow - root).normalized())
	var fore_global := Quaternion(second, (end - elbow).normalized())
	var degrees := LowpolyKit.vec(_hands["hand_deg"])
	var hand_global := Quaternion.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y * sign_of_side), deg_to_rad(degrees.z * sign_of_side)))
	_blend(skeleton, side + "UpperArm", chest.basis.get_rotation_quaternion().inverse() * upper_global, w)
	_blend(skeleton, side + "ForeArm", upper_global.inverse() * fore_global, w)
	_blend(skeleton, side + "Hand", fore_global.inverse() * hand_global, w)


func _move_arms(skeleton: Skeleton3D, speed: float, delta: float, weight_shown: float) -> void:
	var arms: Dictionary = cfg["arms"]
	var target := clampf(speed / float(arms["full_mps"]), 0.0, 1.0)
	_arm_motion = move_toward(_arm_motion, target, delta / float(arms["ease_s"]))
	var amount := _arm_motion * weight_shown
	if amount <= 0.0:
		return
	var cycle := phase * TAU
	for side in ["Left", "Right"]:
		var sign_of_side := -1.0 if side == "Left" else 1.0
		var reach := -sin(cycle) * sign_of_side
		var elbow := sin(cycle - PI / 6.0) * sign_of_side
		var shoulder := int(_bones[side + "UpperArm"])
		var forearm := int(_bones[side + "ForeArm"])
		var shoulder_offset := Quaternion.from_euler(Vector3(reach * float(arms["reach_deg"]), 0.0,
			sign_of_side * float(arms["clearance_deg"])) * deg_to_rad(amount))
		var elbow_offset := Quaternion(Vector3.RIGHT, deg_to_rad(elbow * float(arms["elbow_deg"]) * amount))
		skeleton.set_bone_pose_rotation(shoulder, (skeleton.get_bone_pose_rotation(shoulder) * shoulder_offset).normalized())
		skeleton.set_bone_pose_rotation(forearm, (skeleton.get_bone_pose_rotation(forearm) * elbow_offset).normalized())
