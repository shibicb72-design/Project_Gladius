class_name SoldierGait
extends SkeletonModifier3D
## M2 AN1 commit 4: runs right after the AnimationTree (before SoldierPose, SoldierCrawl, the hand sync and the
## left-hand IK).
## 1. Strafe and back-pedal: the library has no strafe clips, so the legs keep their forward (or reversed) jog and
##    the hips turn toward the motion, bounded by strafe.hip_yaw_max_deg; the spine takes back part of the turn
##    and the chest the rest, so the chest, the arms and the rifle keep facing the aim.
## 2. The helmet is locked on the head hitbox (the neck is a root bone; tests/test_soldier_model.gd), so the body
##    under it may not bob as deep as the library clips do (the jog dips the pelvis ~20 cm). The pelvis keeps
##    hips_bob_scale of the clip's vertical motion (never above its rest height) and each leg is re-solved
##    (two-bone, in the clip's own knee plane) so its foot stays exactly where the clip put it: the feet keep
##    their ground contact and stride, the torso stays under the helmet. No foot goes under the floor (the cover
##    crouch lowers the pelvis below the library crouch's). The helmet sinks with the chest by at most
##    neck_drop_max_m (its box still encloses the hitbox's: the crest gives the room).
## 3. The library spine motion (Spine) is kept at spine_follow; the aimed chest keeps chest_upright of its own
##    orientation against the library lean.
## Presentation only: visual bones, never the pawn, its collider or its hitboxes. Numbers: data/anim_third_person.json "gait".

var cfg: Dictionary = {}
## Wanted hip yaw (radians, + = toward the soldier's left) and the shown one.
var target_yaw := 0.0
var yaw := 0.0
## The motion is in the back half (the strafe slots play the reversed cycle).
var backward := false
var _hips := -1
var _spine := -1
var _chest := -1
var _hips_rest := Vector3.ZERO
var _foot_floor := 0.0
var _neck := -1
var _chest_rest_y := 0.0
## 0..1: how far the pelvis is lifted out of the clip's dip (SoldierModel lowers it in cover, whose clips place
## the hips at the crouched hitbox height on purpose).
var lift_weight := 1.0
var _legs: Array = []  # per side [upper, lower, foot, thigh length, shin length]


func setup() -> void:
	cfg = SoldierRig.config()["gait"]
	var skeleton := get_skeleton()
	_hips = skeleton.find_bone("Hips")
	_spine = skeleton.find_bone("Spine")
	_chest = skeleton.find_bone("Chest")
	_hips_rest = skeleton.get_bone_global_rest(_hips).origin
	_neck = skeleton.find_bone("Neck")
	_chest_rest_y = skeleton.get_bone_global_rest(_chest).origin.y
	_foot_floor = skeleton.get_bone_global_rest(skeleton.find_bone("LeftFoot")).origin.y - float(cfg["foot_floor_slack_m"])
	for side in ["Left", "Right"]:
		var upper := skeleton.find_bone(side + "UpperLeg")
		var lower := skeleton.find_bone(side + "LowerLeg")
		var foot := skeleton.find_bone(side + "Foot")
		_legs.append([upper, lower, foot, skeleton.get_bone_rest(lower).origin.length(), skeleton.get_bone_rest(foot).origin.length()])


## `move`: the pawn-local ground velocity over the move speed (x right, y back), as the locomotion blend.
## Returns true when the back half changed (the model then swaps the strafe clips).
func steer(move: Vector2) -> bool:
	if cfg.is_empty():
		return false
	var strafe: Dictionary = cfg["strafe"]
	var speed := move.length()
	var was := backward
	if speed < 0.0001:
		target_yaw = 0.0
		return false
	var direction := move / speed
	var hysteresis := sin(deg_to_rad(float(strafe["back_hysteresis_deg"])))
	if backward and direction.y < -hysteresis:
		backward = false
	elif not backward and direction.y > hysteresis:
		backward = true
	var wanted := atan2(direction.x, direction.y) if backward else atan2(-direction.x, -direction.y)
	var limit := deg_to_rad(float(strafe["hip_yaw_max_deg"]))
	target_yaw = clampf(wanted, -limit, limit) * smoothstep(0.0, float(strafe["fade_speed"]), speed)
	return was != backward


func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or cfg.is_empty() or _hips < 0:
		return
	var strafe: Dictionary = cfg["strafe"]
	yaw = move_toward(yaw, target_yaw, deg_to_rad(float(strafe["turn_deg_s"])) * delta)
	var hips := skeleton.get_bone_global_pose(_hips)
	var turn := Basis(Vector3.UP, yaw)
	# Where the clip puts each knee and foot, turned with the hips about the pelvis.
	var pivot := Vector3(hips.origin.x, 0.0, hips.origin.z)
	var goals: Array = []
	for leg: Array in _legs:
		var knee := skeleton.get_bone_global_pose(int(leg[1]))
		var foot := skeleton.get_bone_global_pose(int(leg[2]))
		var placed := turn * (foot.origin - pivot) + pivot
		# Never under the floor: a clip whose pelvis sits lower than its own (the cover crouch lowers the hips to
		# the crouched hitbox) bends the knees more instead of sinking the boots.
		placed.y = maxf(placed.y, _foot_floor)
		goals.append([turn * (knee.origin - pivot) + pivot, Transform3D(turn * foot.basis, placed)])
	var spine_local := skeleton.get_bone_pose(_spine)
	# M2 AN2: in cover (lift_weight 0) the keyed cover clips own the spine and chest as authored (the hunched low hug,
	# the lean): the library-follow scale and the upright chest fade out with the lift.
	var follow := lerpf(1.0, float(cfg["spine_follow"]), lift_weight)
	spine_local.basis = Basis(Quaternion.IDENTITY.slerp(spine_local.basis.get_rotation_quaternion(), follow))
	var spine := hips * spine_local
	var chest := spine * skeleton.get_bone_pose(_chest)
	# The aimed chest keeps chest_upright of its own (aim) orientation against the library hips and spine lean,
	# so the rifle does not dip with a jog's forward pitch.
	var aimed := skeleton.get_bone_pose(_chest).basis.get_rotation_quaternion()
	chest.basis = Basis(chest.basis.get_rotation_quaternion().slerp(aimed, float(cfg["chest_upright"]) * lift_weight))
	var height := _hips_rest.y + minf((hips.origin.y - _hips_rest.y) * float(cfg["hips_bob_scale"]), 0.0)
	# No higher than both feet can still be reached with the knees a little bent (leg_reach of the full leg).
	for i in _legs.size():
		var leg: Array = _legs[i]
		var joint := turn * (hips.basis * skeleton.get_bone_pose(int(leg[0])).origin)
		var target: Vector3 = goals[i][1].origin
		var flat := Vector2(hips.origin.x + joint.x - target.x, hips.origin.z + joint.z - target.z).length()
		var length := (float(leg[3]) + float(leg[4])) * float(cfg["leg_reach"])
		height = minf(height, target.y - joint.y + sqrt(maxf(length * length - flat * flat, 0.0)))
	var lifted := Vector3(hips.origin.x, lerpf(hips.origin.y, maxf(height, hips.origin.y), lift_weight), hips.origin.z)
	chest.origin += lifted - hips.origin
	var new_hips := Transform3D(turn * hips.basis, lifted)
	var new_spine := Transform3D(Basis(Vector3.UP, yaw * float(strafe["spine_share"])) * spine.basis, spine.origin + lifted - hips.origin)
	skeleton.set_bone_pose_position(_hips, new_hips.origin)
	skeleton.set_bone_pose_rotation(_hips, new_hips.basis.get_rotation_quaternion())
	var local_spine := new_hips.affine_inverse() * new_spine
	skeleton.set_bone_pose_position(_spine, local_spine.origin)
	skeleton.set_bone_pose_rotation(_spine, local_spine.basis.get_rotation_quaternion())
	var local_chest := new_spine.affine_inverse() * chest
	skeleton.set_bone_pose_position(_chest, local_chest.origin)
	skeleton.set_bone_pose_rotation(_chest, local_chest.basis.get_rotation_quaternion())
	for i in _legs.size():
		_solve_leg(skeleton, _legs[i], new_hips, goals[i][0], goals[i][1])
	# The helmet may sink with the chest by up to neck_drop_max_m (the helmet parts' box still encloses the head
	# hitbox's box: the crest gives that much room), so the head does not float above a dipping torso.
	var drop := clampf(chest.origin.y - _chest_rest_y, -float(cfg["neck_drop_max_m"]), 0.0) * lift_weight
	if _neck >= 0 and drop < 0.0:
		var neck := skeleton.get_bone_pose_position(_neck)
		skeleton.set_bone_pose_position(_neck, Vector3(neck.x, neck.y + drop, neck.z))


## Two-bone solve of one leg under the new hips: the foot bone reaches `foot.origin` with the foot's orientation,
## the knee bends toward `knee` (the clip's own knee, so the bend plane and direction are the clip's).
func _solve_leg(skeleton: Skeleton3D, leg: Array, hips: Transform3D, knee: Vector3, foot: Transform3D) -> void:
	var upper := int(leg[0])
	var lower := int(leg[1])
	var a := float(leg[3])
	var b := float(leg[4])
	var thigh_global := hips * skeleton.get_bone_pose(upper)
	var root := thigh_global.origin
	var to_foot := foot.origin - root
	var reach := clampf(to_foot.length(), absf(a - b) + 0.0001, a + b - 0.0001)
	var direction := to_foot.normalized()
	var bend := (knee - root) - direction * (knee - root).dot(direction)
	if bend.length_squared() < 0.000001:
		bend = thigh_global.basis * Vector3.FORWARD
	bend = bend.normalized()
	var along := (a * a + reach * reach - b * b) / (2.0 * reach)
	var elbow := root + direction * along + bend * sqrt(maxf(a * a - along * along, 0.0))
	var end := root + direction * reach
	var shin_local := skeleton.get_bone_pose(lower)
	var thigh_child := thigh_global.basis * shin_local.origin
	var thigh_rotation := Quaternion(thigh_child.normalized(), (elbow - root).normalized()) * thigh_global.basis.get_rotation_quaternion()
	var new_thigh := Transform3D(Basis(thigh_rotation), root)
	var shin_global := new_thigh * shin_local
	var shin_child := shin_global.basis * skeleton.get_bone_pose(int(leg[2])).origin
	var shin_rotation := Quaternion(shin_child.normalized(), (end - elbow).normalized()) * shin_global.basis.get_rotation_quaternion()
	skeleton.set_bone_pose_rotation(upper, (hips.basis.get_rotation_quaternion().inverse() * thigh_rotation).normalized())
	skeleton.set_bone_pose_rotation(lower, (thigh_rotation.inverse() * shin_rotation).normalized())
	skeleton.set_bone_pose_rotation(int(leg[2]), (shin_rotation.inverse() * foot.basis.get_rotation_quaternion()).normalized())
