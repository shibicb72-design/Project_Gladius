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
## How far the arms are taken away from the rifle (the model fades the left hand's IK by it).
var arms_weight := 0.0
var swing_left_s := 0.0
var _land_left_s := 0.0
var _was_falling := false
var _lean := Vector2.ZERO
var _breath := 0.0
var _bones := {}
var _pivot := Vector3.ZERO


func setup(new_pawn: Pawn) -> void:
	pawn = new_pawn
	cfg = SoldierRig.config()["poses"]
	var skeleton := get_skeleton()
	for i in skeleton.get_bone_count():
		_bones[String(skeleton.get_bone_name(i))] = i
	_pivot = skeleton.get_bone_global_rest(int(_bones["Hips"])).origin
	if pawn != null:
		pawn.shot.connect(_on_shot)
		pawn.landed.connect(_on_landed)


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
	var offset := Vector3.ZERO
	for state in STATES:
		var w := float(weights[state])
		if w <= 0.0:
			continue
		var pose: Dictionary = cfg[state]
		w = smoothstep(0.0, 1.0, w)
		pitch = lerpf(pitch, deg_to_rad(float(pose.get("body_pitch_deg", 0.0))), w) if pose.has("body_pitch_deg") else pitch
		if pose.has("body_offset_m"):
			offset = offset.lerp(LowpolyKit.vec(pose["body_offset_m"]), w)
		_blend_bones(skeleton, pose["bones"], w)
	if swing_left_s > 0.0:
		var swing: Dictionary = cfg["swing"]
		var t := 1.0 - swing_left_s / float(swing["s"])
		var strike := smoothstep(float(swing["strike_from"]), float(swing["strike_to"]), t)
		var out := 1.0 - smoothstep(float(swing["recover_from"]), 1.0, t)
		var raised: Dictionary = swing["raised"]
		var struck: Dictionary = swing["struck"]
		for bone: String in raised:
			if _bones.has(bone):
				var index := int(_bones[bone])
				var key := _quat(raised[bone]).slerp(_quat(struck.get(bone, raised[bone])), strike)
				skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(key, out))
		arms_weight = maxf(arms_weight, out)
	# Breathing: a small rise and fall of the chest.
	var chest := int(_bones.get("Chest", -1))
	if chest >= 0:
		var breath := deg_to_rad(float(cfg["breath"]["deg"])) * sin(TAU * _breath)
		skeleton.set_bone_pose_rotation(chest, skeleton.get_bone_pose_rotation(chest) * Quaternion(Vector3.RIGHT, breath))
	if is_zero_approx(pitch) and is_zero_approx(roll) and offset.is_zero_approx():
		return
	var turn := Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var body := Transform3D(turn, _pivot + offset - turn * _pivot)
	for root_name in ["Hips", "Neck"]:
		if _bones.has(root_name):
			var index := int(_bones[root_name])
			var posed := body * skeleton.get_bone_pose(index)
			skeleton.set_bone_pose_position(index, posed.origin)
			skeleton.set_bone_pose_rotation(index, posed.basis.get_rotation_quaternion())
