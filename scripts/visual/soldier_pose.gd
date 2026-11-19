class_name SoldierPose
extends SkeletonModifier3D
## S4: poses laid over the animation graph's result, driven by read-only pawn state: falling from the carrier
## (drop_state), the landing crouch, downed (is_downed), reviving a squad mate (MatchDirector.is_reviving),
## the blade stance and swing when the active weapon is the blade, and a lean into movement. It runs as a
## skeleton modifier after the AnimationTree, so the graph, its parameters and the rifle pose are untouched
## when no pose is active. Angles and blend times: data/anim.json "poses" (placeholders, OQ-ANIM).
## Presentation only: it moves bones of the visual skeleton, never the pawn, its collider or its head hitbox.

const STATES: Array[String] = ["blade", "revive", "downed", "land", "fall"]  # later entries win

var pawn: Pawn
var cfg: Dictionary = {}
## Current blend weight of each state, 0..1.
var weights := {"blade": 0.0, "revive": 0.0, "downed": 0.0, "land": 0.0, "fall": 0.0}
## Tools and tests: a state listed here is held at that weight whatever the pawn does.
var force: Dictionary = {}
## M2 AN3 tools only (tools/head_motion_measure.gd): contributors switched off to measure their share. Empty (the
## shipped default) changes nothing. "carry_neck": the kneel does not carry the neck; "body_turn_neck": the whole-body
## turn moves the Hips root only, the Neck root stays where the layers below put it.
static var measure_off: Dictionary = {}
## How far the arms are taken away from the rifle (the model fades the left hand's IK by it).
var arms_weight := 0.0
var swing_left_s := 0.0
var _land_left_s := 0.0
var _was_falling := false
var _lean := Vector2.ZERO
var _breath := 0.0
var _bones := {}
var _pivot := Vector3.ZERO
var _head_centre := Vector3.ZERO  # M2 AN3: the head hitbox centre (Head rest)
var head_drop := 0.0  # M2 AN3 stage C: the free crouch's head drop (SoldierModel): the head pivot drops with it
var _swing_clip: Animation
var _revive_clip: Animation
var _tracks := {}
var _neck_from_chest := Transform3D.IDENTITY
var _revive_s := 0.0
## M2 AN2 items 3/5: a keyed action clip (ladder, door, chest, pickup; soldier_keyed.glb) that SoldierModel drives:
## the clip, its time, its weight, the bones it owns ([] = every bone, the Hips and Neck positions too) and a root
## offset (model frame, the top step's catch-up) added to the Hips and Neck at that weight. The lean is held off
## under it; the arms count as away from the rifle (the left-hand IK lets go) by its weight.
var action_clip: Animation
var action_time := 0.0
var action_weight := 0.0
var action_bones: Array = []
var action_offset := Vector3.ZERO
var top_step_source: Array[Transform3D] = []
var top_step_weight := 0.0


func setup(new_pawn: Pawn) -> void:
	pawn = new_pawn
	cfg = SoldierRig.config()["poses"]
	var skeleton := get_skeleton()
	for i in skeleton.get_bone_count():
		_bones[String(skeleton.get_bone_name(i))] = i
	_pivot = skeleton.get_bone_global_rest(int(_bones["Hips"])).origin
	_head_centre = skeleton.get_bone_global_rest(int(_bones["Head"])).origin
	# M2 AN1 commit 4: library clips for the blade swing (UAL Sword_Attack) and the reviver (UAL Fixing_Kneeling),
	# shared baked clips; null keeps the code-built poses.
	_swing_clip = SoldierAnimation.shared("blade_swing", skeleton)
	_revive_clip = SoldierAnimation.shared("revive", skeleton)
	for clip: Animation in [_swing_clip, _revive_clip]:
		if clip == null:
			continue
		var tracks := {}
		for track in clip.get_track_count():
			tracks[clip.track_get_path(track).get_concatenated_subnames() + ("@p" if clip.track_get_type(track) == Animation.TYPE_POSITION_3D else "")] = track
		_tracks[clip] = tracks
	_neck_from_chest = skeleton.get_bone_global_rest(int(_bones["Chest"])).affine_inverse() * skeleton.get_bone_global_rest(int(_bones["Neck"]))
	if pawn != null:
		pawn.shot.connect(_on_shot)
		pawn.landed.connect(_on_landed)


## Sets every bone the clip keys (rotation; the Hips position too when `whole_body`) toward the clip at time t, by w.
func _blend_clip(skeleton: Skeleton3D, clip: Animation, t: float, w: float, bones: Array, whole_body: bool) -> void:
	var tracks: Dictionary = _tracks[clip]
	for bone: String in (_bones.keys() if whole_body else bones):
		if not tracks.has(bone) or not _bones.has(bone):
			continue
		var index := int(_bones[bone])
		var q := clip.rotation_track_interpolate(int(tracks[bone]), t)
		skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(q, w))
	if whole_body and tracks.has("Hips@p"):
		var hips := int(_bones["Hips"])
		skeleton.set_bone_pose_position(hips, skeleton.get_bone_pose_position(hips).lerp(clip.position_track_interpolate(int(tracks["Hips@p"]), t), w))
	if whole_body and clip == action_clip and tracks.has("Neck@p"):
		var neck := int(_bones["Neck"])
		skeleton.set_bone_pose_position(neck, skeleton.get_bone_pose_position(neck).lerp(clip.position_track_interpolate(int(tracks["Neck@p"]), t), w))


## The neck is a root bone: carried on the chest top (rest offset) by w, so a kneeling body takes its head along.
func _carry_neck(skeleton: Skeleton3D, w: float) -> void:
	var neck := int(_bones["Neck"])
	var chest := skeleton.get_bone_global_pose(int(_bones["Chest"])) * _neck_from_chest
	skeleton.set_bone_pose_position(neck, skeleton.get_bone_pose_position(neck).lerp(chest.origin, w))
	skeleton.set_bone_pose_rotation(neck, skeleton.get_bone_pose_rotation(neck).slerp(chest.basis.get_rotation_quaternion(), w))


func _apply_action(skeleton: Skeleton3D) -> void:
	if not _tracks.has(action_clip):
		var tracks := {}
		for track in action_clip.get_track_count():
			tracks[action_clip.track_get_path(track).get_concatenated_subnames() + ("@p" if action_clip.track_get_type(track) == Animation.TYPE_POSITION_3D else "")] = track
		_tracks[action_clip] = tracks  # the shared keyed clips are a fixed handful: one map each
	var w := smoothstep(0.0, 1.0, clampf(action_weight, 0.0, 1.0))
	var whole := action_bones.is_empty()
	_blend_clip(skeleton, action_clip, action_time, w, action_bones, whole)
	if whole and not action_offset.is_zero_approx():
		for root_name in ["Hips", "Neck"]:
			var index := int(_bones[root_name])
			skeleton.set_bone_pose_position(index, skeleton.get_bone_pose_position(index) + action_offset * w)
	arms_weight = maxf(arms_weight, w)


## The pawn has already moved to the ledge. Rebase the last drawn climb pose so its roots
## stay at their previous world positions while the authored top step takes over.
func cache_top_step(globals: Array[Transform3D], old_model_in_new: Transform3D) -> void:
	var skeleton := get_skeleton()
	top_step_source.clear()
	for i in globals.size():
		var parent := skeleton.get_bone_parent(i)
		var local := globals[i]
		if parent >= 0:
			local = globals[parent].affine_inverse() * local
		else:
			local = old_model_in_new * local
		top_step_source.append(local)


func _blend_top_step(skeleton: Skeleton3D) -> void:
	for index in top_step_source.size():
		var from := top_step_source[index]
		skeleton.set_bone_pose_position(index, skeleton.get_bone_pose_position(index).lerp(from.origin, top_step_weight))
		skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(from.basis.get_rotation_quaternion(), top_step_weight))


func _on_shot(_origin: Vector3, _direction: Vector3, weapon_id: String) -> void:
	var weapon := pawn.loadout.get_active() if pawn.loadout != null else null
	if weapon != null and weapon.def.id == weapon_id and weapon.def.is_melee():
		swing_left_s = float(cfg["swing"]["s"])


func _on_landed() -> void:
	_land_left_s = float(cfg["land_hold_s"]) + float(cfg["blend_s"]["land"])


func _director() -> MatchDirector:
	var parent := pawn.get_parent() if pawn != null else null
	return parent.get_node_or_null("Director") as MatchDirector if parent != null else null


## What the pawn's state asks for right now, per state (0 or 1).
func wanted() -> Dictionary:
	var out := {"blade": 0.0, "revive": 0.0, "downed": 0.0, "land": 0.0, "fall": 0.0}
	if pawn == null:
		return out
	var weapon := pawn.loadout.get_active() if pawn.loadout != null else null
	if weapon != null and weapon.def.is_melee():
		out["blade"] = 1.0
	if pawn.drop_state == Pawn.Drop.FALLING:
		out["fall"] = 1.0
	if pawn.is_downed():
		out["downed"] = 1.0
	elif pawn.is_alive():
		var director := _director()
		if director != null and director.running and director.is_reviving(pawn.player_id):
			out["revive"] = 1.0
	if _land_left_s > float(cfg["blend_s"]["land"]):
		out["land"] = 1.0
	return out


static func _quat(degrees: Array) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(float(degrees[0])), deg_to_rad(float(degrees[1])), deg_to_rad(float(degrees[2]))))


func _blend_bones(skeleton: Skeleton3D, bones: Dictionary, weight: float) -> void:
	for bone: String in bones:
		if _bones.has(bone):
			var index := int(_bones[bone])
			skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(_quat(bones[bone]), weight))


func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or pawn == null or cfg.is_empty():
		return
	_land_left_s = maxf(0.0, _land_left_s - delta)
	swing_left_s = maxf(0.0, swing_left_s - delta)
	var target := wanted()
	var busy := 0.0
	for state in STATES:
		var goal := float(force.get(state, target[state]))
		var blend := float(cfg["blend_s"][state])
		weights[state] = move_toward(float(weights[state]), goal, delta / blend if blend > 0.0 else 1.0)
		busy = maxf(busy, float(weights[state]))
	# Lean into movement: the body tips forward when running and sideways when strafing.
	var lean_cfg: Dictionary = cfg["lean"]
	var local := pawn.global_transform.basis.inverse() * pawn.velocity
	var speed := maxf(pawn.get_max_move_speed(), 0.01)
	var lean_goal := Vector2(clampf(local.x / speed, -1.0, 1.0), clampf(-local.z / speed, -1.0, 1.0))
	if pawn.drop_state != Pawn.Drop.NONE or not pawn.is_alive():
		lean_goal = Vector2.ZERO
	_lean = _lean.lerp(lean_goal, 1.0 - exp(-delta / float(lean_cfg["smooth_s"])))
	_breath = fposmod(_breath + delta * float(cfg["breath"]["hz"]), 1.0)
	arms_weight = maxf(maxf(float(weights["blade"]), float(weights["revive"])), maxf(float(weights["downed"]), float(weights["fall"])))
	if busy <= 0.0 and swing_left_s <= 0.0 and _lean.length_squared() < 0.000001 and float(cfg["breath"]["deg"]) <= 0.0:
		return
	# The whole body (both root bones: Hips, and Neck with the head) moves as one about the pelvis.
	var pitch := -deg_to_rad(float(lean_cfg["forward_deg"])) * _lean.y
	var roll := -deg_to_rad(float(lean_cfg["side_deg"])) * _lean.x
	if action_clip != null and action_bones.is_empty():
		# M2 AN2: no lean under a whole-body action (the climb's pull toward the ladder would tip the climber).
		pitch *= 1.0 - clampf(action_weight, 0.0, 1.0)
		roll *= 1.0 - clampf(action_weight, 0.0, 1.0)
	var offset := Vector3.ZERO
	# M2 AN3: the offset the Neck root takes (data head.offset_moves_head; under head_legacy the same as the Hips').
	var head_offset := Vector3.ZERO
	var head_cfg := SoldierRig.head_cfg()
	var moves_head: Dictionary = head_cfg.get("offset_moves_head", {})
	var kneel := 0.0
	_revive_s = _revive_s + delta if float(weights["revive"]) > 0.0 else 0.0
	for state in STATES:
		var w := float(weights[state])
		if w <= 0.0:
			continue
		var pose: Dictionary = cfg[state]
		w = smoothstep(0.0, 1.0, w)
		if state == "revive" and _revive_clip != null:
			# M2 AN1 commit 4: the reviver kneels and works with both hands (UAL Fixing_Kneeling): the kneel-down
			# once, then the working part loops between clip_loop_from_s and clip_loop_to_s.
			var from := float(pose["clip_loop_from_s"])
			var to := float(pose["clip_loop_to_s"])
			var at := _revive_s if _revive_s < to else from + fposmod(_revive_s - to, to - from)
			_blend_clip(skeleton, _revive_clip, at, w, [], true)
			pitch = lerpf(pitch, 0.0, w)
			offset = offset.lerp(Vector3.ZERO, w)
			head_offset = head_offset.lerp(Vector3.ZERO, w)
			kneel = w
			continue
		pitch = lerpf(pitch, deg_to_rad(float(pose.get("body_pitch_deg", 0.0))), w) if pose.has("body_pitch_deg") else pitch
		if pose.has("body_offset_m"):
			offset = offset.lerp(LowpolyKit.vec(pose["body_offset_m"]), w)
			head_offset = head_offset.lerp(LowpolyKit.vec(pose["body_offset_m"]) if head_cfg.is_empty() or bool(moves_head.get(state, true)) else Vector3.ZERO, w)
		_blend_bones(skeleton, pose["bones"], w)
	if swing_left_s > 0.0:
		var swing: Dictionary = cfg["swing"]
		var t := 1.0 - swing_left_s / float(swing["s"])
		var strike := smoothstep(float(swing["strike_from"]), float(swing["strike_to"]), t)
		var out := 1.0 - smoothstep(float(swing["recover_from"]), 1.0, t)
		if _swing_clip != null:
			# M2 AN1 commit 4: the authored sword strike (UAL Sword_Attack) from clip_from_s to clip_to_s over the
			# same swing time, so its strike lands in the strike window; it fades in over fade_in of the swing.
			var at := lerpf(float(swing["clip_from_s"]), float(swing["clip_to_s"]), t)
			_blend_clip(skeleton, _swing_clip, at, minf(smoothstep(0.0, float(swing["fade_in"]), t), out), swing["clip_bones"], false)
		else:
			var raised: Dictionary = swing["raised"]
			var struck: Dictionary = swing["struck"]
			for bone: String in raised:
				if _bones.has(bone):
					var index := int(_bones[bone])
					var key := _quat(raised[bone]).slerp(_quat(struck.get(bone, raised[bone])), strike)
					skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(key, out))
		arms_weight = maxf(arms_weight, out)
	if action_clip != null and action_weight > 0.0:
		_apply_action(skeleton)
	# Breathing: a small rise and fall of the chest.
	var chest := int(_bones.get("Chest", -1))
	if chest >= 0:
		var breath := deg_to_rad(float(cfg["breath"]["deg"])) * sin(TAU * _breath)
		skeleton.set_bone_pose_rotation(chest, skeleton.get_bone_pose_rotation(chest) * Quaternion(Vector3.RIGHT, breath))
	if measure_off.has("carry_neck"):
		kneel = 0.0
	if is_zero_approx(pitch) and is_zero_approx(roll) and offset.is_zero_approx():
		if kneel > 0.0:
			_carry_neck(skeleton, kneel)
		if top_step_weight > 0.0:
			_blend_top_step(skeleton)
		return
	var turn := Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var pivot := _pivot
	if bool(head_cfg.get("fall_pivot_head", false)):
		# M2 AN3: the lean, fall and landing turn the body about the head hitbox centre (the helmet stays on it, the
		# body swings behind and under it); downed and revive keep the pelvis pivot (they lower the head on purpose).
		pivot = (_head_centre - Vector3(0.0, head_drop, 0.0)).lerp(_pivot,clampf(maxf(float(weights["downed"]), float(weights["revive"])), 0.0, 1.0))
	var body := Transform3D(turn, pivot + offset - turn * pivot)
	var body_head := Transform3D(turn, pivot + head_offset - turn * pivot)
	for root_name in ["Hips", "Neck"]:
		if root_name == "Neck" and measure_off.has("body_turn_neck"):
			continue
		if _bones.has(root_name):
			var index := int(_bones[root_name])
			var posed := (body_head if root_name == "Neck" else body) * skeleton.get_bone_pose(index)
			skeleton.set_bone_pose_position(index, posed.origin)
			skeleton.set_bone_pose_rotation(index, posed.basis.get_rotation_quaternion())
	if kneel > 0.0:
		_carry_neck(skeleton, kneel)
	if top_step_weight > 0.0:
		_blend_top_step(skeleton)
