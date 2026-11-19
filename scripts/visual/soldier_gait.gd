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
var _head_hitbox: Node3D
var _neck_to_helmet_y := 0.0
var _chest_rest_y := 0.0
## 0..1: how far the pelvis is lifted out of the clip's dip (SoldierModel lowers it in cover, whose clips place
## the hips at the crouched hitbox height on purpose).
var lift_weight := 1.0
## M2 AN3: 0..1, crouched in the cover hug (CoverAnim sets it: crouch_amount x the cover layer's weight).
var cover_crouch := 0.0
## M2 AN3 stage C (SoldierModel sets them): how far the pawn's Head node is below its standing height out of cover
## (the free crouch), and how far that lowers the pelvis's lift target. The neck pin drops with the head.
var head_drop := 0.0
var hips_drop := 0.0
var free_crouch := 0.0  # the free crouch clip's blend as shown (SoldierNeck lifts its tilt cap by it)
var pivot_allowed := false
var _legs: Array = []  # per side [upper, lower, foot, thigh length, shin length]
var _neck_from_chest := Transform3D.IDENTITY
var _pivot_initialized := false
var _pivot_turning := false
var _pivot_origin := Vector3.ZERO
var _pivot_yaw := 0.0
var _pivot_feet: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _pivot_headings: Array[float] = [0.0, 0.0]
var _swing_foot := -1
var _swing_time := 0.0
var _swing_heading := 0.0
var _swing_target := Transform3D.IDENTITY
## 1 while a stationary turn holds the feet; fades to 0 over pivot.release_s once the pawn moves off.
var _pivot_weight := 0.0
var _release_goals: Array = []


func setup(head_hitbox: Node3D) -> void:
	cfg = SoldierRig.config()["gait"]
	var skeleton := get_skeleton()
	_hips = skeleton.find_bone("Hips")
	_spine = skeleton.find_bone("Spine")
	_chest = skeleton.find_bone("Chest")
	_hips_rest = skeleton.get_bone_global_rest(_hips).origin
	_neck = skeleton.find_bone("Neck")
	_head_hitbox = head_hitbox
	_neck_to_helmet_y = skeleton.get_bone_rest(skeleton.find_bone("Head")).origin.y
	_chest_rest_y = skeleton.get_bone_global_rest(_chest).origin.y
	_neck_from_chest = skeleton.get_bone_global_rest(_chest).affine_inverse() * skeleton.get_bone_global_rest(_neck)
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
	var head := SoldierRig.head_cfg()
	var cover_pin := not head.is_empty() and cover_crouch > 0.0 and _head_hitbox != null
	var cover_drop := 0.0
	if _neck >= 0 and (head_drop > 0.0 or cover_pin):
		var pin := skeleton.get_bone_pose_position(_neck)
		pin.y -= head_drop
		if cover_pin:
			# The hitbox takes the larger crouch while the tree mixes both presentation layers.
			# Keep the difference on the upper body and solve the legs to their existing goals.
			var hitbox_y := skeleton.to_local(_head_hitbox.global_position).y - _neck_to_helmet_y
			cover_drop = pin.y - hitbox_y
			pin.y = hitbox_y
		skeleton.set_bone_pose_position(_neck, pin)
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
	if pivot_allowed:
		_turn_feet(skeleton.global_transform, goals, pivot, delta)
		_pivot_weight = 1.0 if _pivot_turning else 0.0
		_release_goals = goals.duplicate(true)
	else:
		_pivot_initialized = false
		_pivot_turning = false
		_swing_foot = -1
		if _pivot_weight > 0.0:
			# Hand the planted feet (and the hip clamp below) back to the clip over release_s, not in one frame.
			_pivot_weight = move_toward(_pivot_weight, 0.0, delta / float((cfg["pivot"] as Dictionary)["release_s"]))
			var held_share := smoothstep(0.0, 1.0, _pivot_weight)
			for i in goals.size():
				var held: Array = _release_goals[i]
				goals[i] = [(goals[i][0] as Vector3).lerp(held[0], held_share), (goals[i][1] as Transform3D).interpolate_with(held[1], held_share)]
	if not head.is_empty():
		# M2 AN3: the pelvis keeps hips_keep of the clip's swing (pitch and roll; its yaw stays), so the torso is not
		# thrown ahead of the head on the hitbox. The feet keep the clip's goals above; the legs are re-solved below.
		var keep := lerpf(1.0, float(head["hips_keep"]), lift_weight)
		keep = lerpf(keep, float(head["cover_crouch_hips_keep"]), clampf(cover_crouch, 0.0, 1.0))
		hips.basis = Basis(_scale_swing(hips.basis.get_rotation_quaternion(), keep))
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
	var rest_y := _hips_rest.y - hips_drop  # M2 AN3 stage C: the free crouch lowers the pelvis's target
	var height := rest_y + minf((hips.origin.y - rest_y) * float(cfg["hips_bob_scale"]), 0.0)
	# No higher than both feet can still be reached with the knees a little bent (leg_reach of the full leg).
	for i in _legs.size():
		var leg: Array = _legs[i]
		var joint := turn * (hips.basis * skeleton.get_bone_pose(int(leg[0])).origin)
		var target: Vector3 = goals[i][1].origin
		var flat := Vector2(hips.origin.x + joint.x - target.x, hips.origin.z + joint.z - target.z).length()
		var length := (float(leg[3]) + float(leg[4])) * float(head.get("leg_reach", cfg["leg_reach"]))  # M2 AN3: head's unless legacy
		height = minf(height, target.y - joint.y + sqrt(maxf(length * length - flat * flat, 0.0)))
	var lifted := Vector3(hips.origin.x, lerpf(hips.origin.y, maxf(height, hips.origin.y), lift_weight), hips.origin.z)
	if _pivot_weight > 0.0:
		lifted.y = lerpf(lifted.y, minf(lifted.y, height), smoothstep(0.0, 1.0, _pivot_weight))
	if free_crouch > 0.0 and hips_drop > 0.0:
		# M2 AN3 stage C: in the free crouch the pelvis goes down to its head-driven target even below the clip's own
		# (the knees bend more; the feet keep the clip's goals), so the torso can reach the lowered head.
		lifted.y = lerpf(lifted.y, minf(lifted.y, rest_y), clampf(free_crouch, 0.0, 1.0))
	if cover_drop != 0.0:
		lifted.y -= cover_drop
	chest.origin += lifted - hips.origin
	var new_hips := Transform3D(turn * hips.basis, lifted)
	var new_spine := Transform3D(Basis(Vector3.UP, yaw * float(strafe["spine_share"])) * spine.basis, spine.origin + lifted - hips.origin)
	if not head.is_empty() and _neck >= 0:
		# M2 AN3: the spine leans (at most torso_reach_max_deg) so the chest top points at the neck on the head hitbox;
		# the chest keeps its aimed orientation (only its position follows the spine).
		var neck_at := skeleton.get_bone_pose_position(_neck)
		var from := (chest * _neck_from_chest).origin - new_spine.origin
		var to := neck_at - new_spine.origin
		var axis := from.cross(to)
		if axis.length() > 0.000001:
			var reach_max := lerpf(float(head["torso_reach_max_deg"]), float((head.get("free_crouch", {}) as Dictionary).get("reach_max_deg", head["torso_reach_max_deg"])), clampf(free_crouch, 0.0, 1.0))
			var reach := Basis(axis.normalized(), minf(from.angle_to(to), deg_to_rad(reach_max)))
			new_spine.basis = reach * new_spine.basis
			chest.origin = new_spine.origin + reach * (chest.origin - new_spine.origin)
		# What the reach cannot close is the chest top hanging below the neck (the pelvis is held down by the legs'
		# reach): the chest rises along the spine by at most torso_stretch_max_m.
		var up := new_spine.basis.y.normalized()
		chest.origin += up * clampf((neck_at - (chest * _neck_from_chest).origin).dot(up), 0.0, float(head.get("torso_stretch_max_m", 0.0)))
		if cover_crouch > 0.0 and free_crouch > 0.0:
			# The free pose eases toward standing as its layer fades. During the
			# overlap, keep its shoulders below the lowered helmet.
			var chest_above_pin := (chest * _neck_from_chest).origin.y - neck_at.y
			var lower := maxf(chest_above_pin, 0.0) * smoothstep(0.0, 0.2, free_crouch)
			new_hips.origin.y -= lower
			new_spine.origin.y -= lower
			chest.origin.y -= lower
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
	var drop_max := float(head.get("neck_drop_max_m", cfg["neck_drop_max_m"]))  # M2 AN3: head's value unless legacy
	var drop := clampf(chest.origin.y - _chest_rest_y, -drop_max, 0.0) * lift_weight
	if _neck >= 0 and drop < 0.0:
		var neck := skeleton.get_bone_pose_position(_neck)
		skeleton.set_bone_pose_position(_neck, Vector3(neck.x, neck.y + drop, neck.z))


## Keep stance transforms in world space. Move the swing foot only after it has
## cleared the contact band, and stop translating it before it bears weight again.
func _turn_feet(world: Transform3D, goals: Array, pivot: Vector3, delta: float) -> void:
	var heading := world.basis.get_euler().y
	var turn := angle_difference(_pivot_yaw, heading)
	_pivot_yaw = heading
	if not _pivot_initialized or _pivot_origin.distance_squared_to(world.origin) > 0.04 * 0.04:
		_pivot_initialized = true
		_pivot_origin = world.origin
		_pivot_turning = false
		_swing_foot = -1
		turn = 0.0
	if not _pivot_turning and absf(turn) <= 0.00001:
		for foot in 2:
			_pivot_feet[foot] = world * (goals[foot][1] as Transform3D)
			_pivot_headings[foot] = heading
		return
	_pivot_turning = true
	var pivot_cfg: Dictionary = cfg["pivot"]
	var duration := float(pivot_cfg["swing_s"])
	if _swing_foot >= 0:
		_swing_time += delta
		if _swing_time >= duration:
			_pivot_feet[_swing_foot] = _swing_target
			_pivot_headings[_swing_foot] = _swing_heading
			_swing_foot = -1
	if _swing_foot < 0:
		var left_lag := absf(angle_difference(_pivot_headings[0], heading))
		var right_lag := absf(angle_difference(_pivot_headings[1], heading))
		if maxf(left_lag, right_lag) >= deg_to_rad(float(pivot_cfg["step_deg"])):
			_swing_foot = 0 if left_lag >= right_lag else 1
			if is_equal_approx(left_lag, right_lag):
				_swing_foot = 0 if turn >= 0.0 else 1
			_swing_time = 0.0
			var lead_max := deg_to_rad(float(pivot_cfg["lead_max_deg"]))
			var lead := clampf(turn * duration / maxf(delta, 0.001) * 0.6, -lead_max, lead_max)
			var ahead := Basis(Vector3.UP, lead)
			var foot_world := world * (goals[_swing_foot][1] as Transform3D)
			_swing_target = Transform3D(ahead * foot_world.basis, world.origin + ahead * (foot_world.origin - world.origin))
			_swing_heading = heading + lead
	var inverse := world.affine_inverse()
	for foot in 2:
		var anchored := _pivot_feet[foot]
		if foot == _swing_foot:
			var progress := _swing_time / duration
			anchored = anchored.interpolate_with(_swing_target, smoothstep(0.22, 0.78, progress))
			var arc := sin(PI * progress)
			anchored.origin.y += arc * arc * float(pivot_cfg["lift_m"])
		var local := inverse * anchored
		var initial: Transform3D = goals[foot][1]
		var knee: Vector3 = goals[foot][0]
		var knee_turn := angle_difference(initial.basis.get_euler().y, local.basis.get_euler().y) * 0.5
		goals[foot] = [pivot + Basis(Vector3.UP, knee_turn) * (knee - pivot), local]


## M2 AN3: q split into its twist about UP (the yaw, kept) and its swing (pitch and roll), the swing scaled by `keep`.
static func _scale_swing(q: Quaternion, keep: float) -> Quaternion:
	var twist := Quaternion(0.0, q.y, 0.0, q.w)
	if twist.length_squared() < 0.000001:
		return Quaternion.IDENTITY.slerp(q, keep)
	twist = twist.normalized()
	var swing := q * twist.inverse()
	return Quaternion.IDENTITY.slerp(swing, keep) * twist


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
