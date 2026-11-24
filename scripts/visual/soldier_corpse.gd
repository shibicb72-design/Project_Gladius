class_name SoldierCorpse
extends RefCounted
## Explicit native-node snapshot: no gameplay, modifier or presentation scripts copied to the corpse.


## M2 AN1 commit 4: the corpse's collapse from the snapshot (local bone poses) into the shared baked death clip:
## the first death.blend_s crossfade from the last living pose, then the clip plays to its end and holds. The neck
## is a root bone (the living helmet is locked on the head hitbox), so the corpse carries it on the chest top with
## its rest offset, sampled from the clip, and the head falls with the body.
## A3 item 1: hand settling (data death.settle, OQ-A3-CONTACT). The clip's end pose floats both hands (13-19 cm with
## the raw clip arms) and arm_follow turns the right one into the floor, so in every clip frame each hand's lowest
## skinned vertex (the armour set's own mesh: Hand and Fingers vertices) is measured on the corpse's floor (y 0, where
## DeathFx puts the corpse root) and the arm is re-solved (two bones from the shoulder, the elbow kept in its plane,
## the hand's own orientation kept): a hand below the floor is lifted onto it in any frame, a hand above it is lowered
## onto it by smoothstep(from_s, full_s) of the clip time. Never the root or the body: only the arm bones. The keys
## after the crossfade come from the clip alone, so the result is cached per mesh and clip.
static var _settle_cache := {}
static var _hand_sets := {}
## Fix pass 1 (S1): the death clip's sampled bone globals per collapse frame (clip and rests only, never the living
## pose), per clip, skeleton rests and frame count.
static var _clip_globals := {}


## Fix pass 1 (S1): the per-set work of a death that does not depend on the last living pose, done when the set's
## soldier model is built (SoldierModel) so the first death does not pay it mid-match: the armour mesh's hand and foot
## vertex sets and the death clip's sampled globals. Cached per mesh / clip, so later models of the set cost nothing.
static func precache(skeleton: Skeleton3D, mesh: Mesh, skin: Skin) -> void:
	if skeleton == null or mesh == null or skin == null:
		return
	_limb_verts(mesh, skin, skeleton, HAND_PARTS)
	_limb_verts(mesh, skin, skeleton, FOOT_PARTS)
	var death := SoldierAnimation.shared("death", skeleton)
	if death != null:
		_death_globals(death, skeleton, _frame_count(death))


## Fix pass 1 (S1): the per-frame hand settle, cached per mesh and clip by the first collapse. It reads the clip and
## the bones' unkeyed offsets of the snapshot (the aim layer keys the shoulders off their rest), so it is filled from
## the model's drawn living pose a few frames after the model of the set first animates (SoldierModel._cache_pose),
## the same pose a first death would snapshot, instead of on that death.
static func precache_settle(model: SoldierModel) -> void:
	var mesh := model.armor.mesh if model.armor != null else null
	var skin := model.armor.skin if model.armor != null else null
	var skeleton := model.skeleton
	if mesh == null or skin == null or not bool((SoldierRig.config()["death"].get("settle", {}) as Dictionary).get("hands", false)):
		return
	var death := SoldierAnimation.shared("death", skeleton)
	if death == null or _settle_cache.has("%d|%d" % [mesh.get_instance_id(), death.get_instance_id()]):
		return
	authored_collapse(skeleton, _snapshot(model), death, mesh, skin)


## The model's drawn pose as local bone transforms (what SoldierCorpse.build snapshots).
static func _snapshot(model: SoldierModel) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in model.skeleton.get_bone_count():
		var parent := model.skeleton.get_bone_parent(i)
		out.append(model.pose_cache[i] if parent < 0 else model.pose_cache[parent].affine_inverse() * model.pose_cache[i])
	return out


## Fix pass 1 (S1): whether the hand settle of this mesh and the death clip is already computed (tests).
static func has_settle(mesh: Mesh, death: Animation) -> bool:
	return _settle_cache.has("%d|%d" % [mesh.get_instance_id(), death.get_instance_id()]) \
			and (_settle_cache["%d|%d" % [mesh.get_instance_id(), death.get_instance_id()]] as Array).size() == _frame_count(death) + 1


static func _frame_count(death: Animation) -> int:
	return ceili(death.length * float(SoldierRig.config()["retarget"]["sample_hz"]))


static func _death_globals(death: Animation, skeleton: Skeleton3D, count: int) -> Array:
	var rests: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		rests.append(skeleton.get_bone_rest(i))
	var key := "%d|%d|%d" % [death.get_instance_id(), rests.hash(), count]
	if not _clip_globals.has(key):
		var frames: Array = []
		for k in count + 1:
			frames.append(AnimRetarget.sample_globals(death, skeleton, death.length * float(k) / count))
		_clip_globals[key] = frames
	return _clip_globals[key]


static func authored_collapse(skeleton: Skeleton3D, snapshot: Array[Transform3D], death: Animation, mesh: Mesh = null, skin: Skin = null) -> Animation:
	var blend := float(SoldierRig.config()["death"]["blend_s"])
	var animation := Animation.new()
	animation.length = blend + death.length
	var count := _frame_count(death)
	var sampled := _death_globals(death, skeleton, count)
	var chest := skeleton.find_bone("Chest")
	var neck := skeleton.find_bone("Neck")
	var hips := skeleton.find_bone("Hips")
	var neck_from_chest := skeleton.get_bone_global_rest(chest).affine_inverse() * skeleton.get_bone_global_rest(neck)
	var rotations: Array = []
	var positions: Array = []
	var arm_follow := float(SoldierRig.config()["death"]["arm_follow"])
	var arms: Array[int] = [skeleton.find_bone("LeftUpperArm"), skeleton.find_bone("RightUpperArm")]
	for i in skeleton.get_bone_count():
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("Skeleton3D:" + String(skeleton.get_bone_name(i))))
		animation.rotation_track_insert_key(track, 0.0, snapshot[i].basis.get_rotation_quaternion())
		rotations.append(track)
		var moves := i == hips or i == neck
		var position := -1
		if moves:
			position = animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(position, NodePath("Skeleton3D:" + String(skeleton.get_bone_name(i))))
			animation.position_track_insert_key(position, 0.0, snapshot[i].origin)
		elif i == chest and not snapshot[i].origin.is_equal_approx(skeleton.get_bone_rest(i).origin):
			# M2 AN3: a bone the live layers moved off its rest offset (SoldierGait's torso stretch lifts the Chest)
			# goes back to its rest offset over the crossfade: the death clip keys no position for it.
			var back := animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(back, NodePath("Skeleton3D:" + String(skeleton.get_bone_name(i))))
			animation.position_track_insert_key(back, 0.0, snapshot[i].origin)
			animation.position_track_insert_key(back, blend, skeleton.get_bone_rest(i).origin)
		positions.append(position)
	var settle: Dictionary = SoldierRig.config()["death"].get("settle", {})
	var cache_key := ""
	if mesh != null and skin != null and bool(settle.get("hands", false)):
		cache_key = "%d|%d" % [mesh.get_instance_id(), death.get_instance_id()]
		if not _settle_cache.has(cache_key):
			_settle_cache[cache_key] = []
	var locals: Array[Transform3D] = []
	locals.resize(skeleton.get_bone_count())
	for k in count + 1:
		var t := death.length * float(k) / count
		var globals: Array[Transform3D] = sampled[k]
		var carried := globals[chest] * neck_from_chest
		for i in skeleton.get_bone_count():
			var parent := skeleton.get_bone_parent(i)
			var local := globals[i] if parent < 0 else globals[parent].affine_inverse() * globals[i]
			if i == neck:
				local = carried
			elif arms.has(i):
				# The fall flings the arms up past the helmet; they keep arm_follow of the clip's turn from rest.
				local.basis = Basis(Quaternion.IDENTITY.slerp(local.basis.get_rotation_quaternion(), arm_follow))
			if int(positions[i]) < 0:
				# Unkeyed offsets are the corpse skeleton's own (the snapshot's; the Chest's goes back to its rest),
				# not the clip's: the settle's forward kinematics must match what the skeleton draws.
				local.origin = skeleton.get_bone_rest(i).origin if i == chest else snapshot[i].origin
			locals[i] = local
		if cache_key != "":
			var cached: Array = _settle_cache[cache_key]
			if cached.size() <= k:
				cached.append(_settle_hands(skeleton, locals, mesh, skin, settle, t))
			var turns: Dictionary = cached[k]
			for i: int in turns:
				locals[i].basis = Basis(turns[i] as Quaternion)
		if k == 0 and mesh != null and skin != null and blend > 0.0:
			_key_crossfade_feet(animation, skeleton, snapshot, locals, rotations, blend, mesh, skin)
		for i in skeleton.get_bone_count():
			animation.rotation_track_insert_key(rotations[i], blend + t, locals[i].basis.get_rotation_quaternion())
			if int(positions[i]) >= 0:
				animation.position_track_insert_key(positions[i], blend + t, locals[i].origin)
	return animation


## A3 item 1: the crossfade's feet. Over the first blend_s every bone slerps from the snapshot to the clip's first
## frame; dying from the downed crawl (toes back, knee on the floor) into the clip's STANDING first frame swings the
## shin down through the floor (a heel 3.4 cm under it, measured by tests/test_a3_contact.gd). So the crossfade is
## sampled at death.settle.crossfade_keys_hz (OQ-A3-CONTACT) with the interpolation the player uses (rotation slerp,
## position lerp) and, in any sample where a foot's lowest skinned vertex (Foot and Toes vertices) is under the floor
## (y 0, the corpse root), the leg is re-solved (UpperLeg/LowerLeg two-bone, the knee kept in its plane, the foot's
## orientation kept) to lift it onto the floor. Only the six leg bones get these extra keys; never the root or the
## body. A foot on or above the floor gets the plain interpolated key, so nothing else changes.
static func _key_crossfade_feet(animation: Animation, skeleton: Skeleton3D, snapshot: Array[Transform3D], first: Array[Transform3D], rotations: Array, blend: float, mesh: Mesh, skin: Skin) -> void:
	var sets := _limb_verts(mesh, skin, skeleton, FOOT_PARTS)
	var steps := ceili(blend * float(SoldierRig.config()["death"]["settle"]["crossfade_keys_hz"]))
	var legs := {}
	for side in ["Left", "Right"]:
		legs[side] = [skeleton.find_bone(side + "UpperLeg"), skeleton.find_bone(side + "LowerLeg"), skeleton.find_bone(side + "Foot")]
	var locals: Array[Transform3D] = []
	locals.resize(skeleton.get_bone_count())
	var globals: Array[Transform3D] = []
	globals.resize(skeleton.get_bone_count())
	for j in range(1, steps):
		var w := float(j) / float(steps)
		for i in skeleton.get_bone_count():
			var q := snapshot[i].basis.get_rotation_quaternion().slerp(first[i].basis.get_rotation_quaternion(), w)
			locals[i] = Transform3D(Basis(q), snapshot[i].origin.lerp(first[i].origin, w))
			var parent := skeleton.get_bone_parent(i)
			globals[i] = locals[i] if parent < 0 else globals[parent] * locals[i]
		var turns := {}
		for side in ["Left", "Right"]:
			var low := _lowest(sets[side], globals, skin)
			if low < 0.0 and low != INF:
				var bones: Array = legs[side]
				_solve_limb(skeleton, locals, globals, bones[0], bones[1], bones[2], -low, turns)
		for side in ["Left", "Right"]:
			for i: int in legs[side]:
				var q: Quaternion = turns[i] if turns.has(i) else locals[i].basis.get_rotation_quaternion()
				animation.rotation_track_insert_key(rotations[i], blend * w, q)


## A3: the lowest skinned y of a vertex set from _limb_verts under the given bone globals (INF for an empty set).
static func _lowest(verts: Array, globals: Array[Transform3D], skin: Skin) -> float:
	var low := INF
	for v: Array in verts:
		var p := Vector3.ZERO
		for j in range(0, (v[1] as Array).size()):
			var bind: int = v[1][j]
			p += float(v[2][j]) * (globals[skin.get_bind_bone(bind)] * skin.get_bind_pose(bind) * (v[0] as Vector3))
		low = minf(low, p.y)
	return low


## A3: per hand, the new local rotations of UpperArm, ForeArm and Hand that put the hand's lowest vertex on the floor
## (see the note above authored_collapse); {} entries for a hand that needs no move.
static func _settle_hands(skeleton: Skeleton3D, locals: Array[Transform3D], mesh: Mesh, skin: Skin, settle: Dictionary, t: float) -> Dictionary:
	var globals: Array[Transform3D] = []
	globals.resize(locals.size())
	for i in locals.size():
		var parent := skeleton.get_bone_parent(i)
		globals[i] = locals[i] if parent < 0 else globals[parent] * locals[i]
	var sets := _limb_verts(mesh, skin, skeleton, HAND_PARTS)
	var lower := smoothstep(float(settle["from_s"]), float(settle["full_s"]), t)
	var out := {}
	for side in ["Left", "Right"]:
		var low := _lowest(sets[side], globals, skin)
		if low == INF:
			continue
		var drop := -low if low < 0.0 else -low * lower
		if is_zero_approx(drop):
			continue
		_solve_limb(skeleton, locals, globals, skeleton.find_bone(side + "UpperArm"), skeleton.find_bone(side + "ForeArm"), skeleton.find_bone(side + "Hand"), drop, out)
	return out


## A3: a two-bone solve from `upper` (the shoulder or hip stays) that moves the `end` bone (hand or foot) by `drop`
## in y, the middle joint (elbow or knee) kept in its plane and the end bone's global orientation kept; writes the
## three new local rotations into `out`.
static func _solve_limb(skeleton: Skeleton3D, locals: Array[Transform3D], globals: Array[Transform3D], upper: int, fore: int, hand: int, drop: float, out: Dictionary) -> void:
	var root := globals[upper].origin
	var elbow_was := globals[fore].origin
	var hand_was := globals[hand].origin
	var target := hand_was + Vector3(0.0, drop, 0.0)
	var a := locals[fore].origin.length()
	var b := locals[hand].origin.length()
	var distance := clampf(root.distance_to(target), absf(a - b) + 0.001, a + b - 0.001)
	var direction := (target - root).normalized()
	var pole := elbow_was - root
	var bend := pole - direction * pole.dot(direction)
	bend = bend.normalized() if bend.length() > 0.0001 else Vector3.BACK
	var along := (a * a + distance * distance - b * b) / (2.0 * distance)
	var elbow := root + direction * along + bend * sqrt(maxf(a * a - along * along, 0.0))
	var end := root + direction * distance
	var upper_global := Quaternion((elbow_was - root).normalized(), (elbow - root).normalized()) * globals[upper].basis.get_rotation_quaternion()
	var fore_global := Quaternion((hand_was - elbow_was).normalized(), (end - elbow).normalized()) * globals[fore].basis.get_rotation_quaternion()
	var hand_global := globals[hand].basis.get_rotation_quaternion()
	out[upper] = (globals[skeleton.get_bone_parent(upper)].basis.get_rotation_quaternion().inverse() * upper_global).normalized()
	out[fore] = (upper_global.inverse() * fore_global).normalized()
	out[hand] = (fore_global.inverse() * hand_global).normalized()


## A3: per side, this mesh's vertices dominated by side + one of `suffixes` (["Hand", "Fingers"] or ["Foot",
## "Toes"]) as [rest position, bind indices, weights], read once per mesh and set.
static func _limb_verts(mesh: Mesh, skin: Skin, skeleton: Skeleton3D, suffixes: Array) -> Dictionary:
	var key := "%d|%s" % [mesh.get_instance_id(), "|".join(PackedStringArray(suffixes))]
	if _hand_sets.has(key):
		return _hand_sets[key]
	var out := {"Left": [], "Right": []}
	var seen := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or bones.is_empty():
			continue
		var per: int = floori(float(bones.size()) / float(vertices.size()))
		for v in vertices.size():
			var best := 0
			for j in per:
				if weights[v * per + j] > weights[v * per + best]:
					best = j
			var bone_name := String(skeleton.get_bone_name(skin.get_bind_bone(bones[v * per + best])))
			for side in ["Left", "Right"]:
				if not suffixes.has(bone_name.trim_prefix(side)) or not bone_name.begins_with(side):
					continue
				var dedupe := "%s%s" % [side, vertices[v]]
				if seen.has(dedupe):
					continue
				seen[dedupe] = true
				var binds: Array = []
				var w: Array = []
				for j in per:
					if weights[v * per + j] > 0.0:
						binds.append(bones[v * per + j])
						w.append(weights[v * per + j])
				(out[side] as Array).append([vertices[v], binds, w])
	_hand_sets[key] = out
	return out

const HAND_PARTS: Array = ["Hand", "Fingers"]
const FOOT_PARTS: Array = ["Foot", "Toes"]


## Fix pass 1 (S1): whether this mesh's hand and foot vertex sets are already read (tests/test_a3_corpse_cost.gd).
static func has_limb_verts(mesh: Mesh) -> bool:
	for parts: Array in [HAND_PARTS, FOOT_PARTS]:
		if not _hand_sets.has("%d|%s" % [mesh.get_instance_id(), "|".join(PackedStringArray(parts))]):
			return false
	return true


static func build(model: SoldierModel) -> Node3D:
	var corpse := Node3D.new()
	corpse.name = "SoldierCorpse"
	corpse.set_meta("corpse", true)
	var source_head := model._pawn.get_node("Head") as Node3D
	var skeleton := SoldierRig.build(model._cfg["parts"], source_head.position)
	corpse.add_child(skeleton)
	var animation := Animation.new()
	animation.length = float(LowpolyKit.config()["death"]["topple_s"])
	var targets: Dictionary = SoldierRig.config()["death"]["end_rotations_deg"]
	var snapshot: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		var pose := model.pose_cache[i]
		if parent >= 0:
			pose = model.pose_cache[parent].affine_inverse() * pose
		snapshot.append(pose)
		skeleton.set_bone_pose_position(i, pose.origin)
		skeleton.set_bone_pose_rotation(i, pose.basis.get_rotation_quaternion())
		skeleton.set_bone_pose_scale(i, pose.basis.get_scale())
		var bone := String(skeleton.get_bone_name(i))
		var start := pose.basis.get_rotation_quaternion()
		var finish := start
		if targets.has(bone):
			var degrees := LowpolyKit.vec(targets[bone])
			finish = Quaternion.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)))
		SoldierAnimation._rotation_track(animation, bone, [0.0, animation.length], [start, finish])
	# M2 AN1 commit 4: the library's authored fall (UAL Death01) replaces the code-built collapse and the outer
	# topple (DeathFx skips it for a corpse marked "authored_fall"): it blends from the soldier's last pose.
	var death := SoldierAnimation.shared("death", skeleton)
	if death != null:
		animation = authored_collapse(skeleton, snapshot, death, model.armor.mesh, model.armor.skin)
		corpse.set_meta("authored_fall", true)
	var armor := MeshInstance3D.new()
	armor.name = "Armor"
	armor.mesh = model.armor.mesh
	armor.skin = model.armor.skin
	armor.skeleton = NodePath("..")
	SoldierSquadColour.copy(model.armor, armor)  # the corpse keeps its squad colour (C3)
	skeleton.add_child(armor)
	# D1: the helmet is part of the armor mesh. The yellow head sphere is copied only while the debug flag shows it.
	var source_shell := source_head.get_node("HeadMesh") as MeshInstance3D
	if source_shell.visible:
		var head_attachment := BoneAttachment3D.new()
		head_attachment.name = "HeadAttachment"
		head_attachment.bone_name = &"Head"
		skeleton.add_child(head_attachment)
		var shell := MeshInstance3D.new()
		shell.name = "Shell"
		shell.mesh = source_shell.mesh
		shell.material_override = source_shell.material_override
		shell.transform = source_shell.transform
		head_attachment.add_child(shell)
	var hand := BoneAttachment3D.new()
	hand.name = "RightHandAttachment"
	hand.bone_name = &"RightHand"
	skeleton.add_child(hand)
	var rifle := MeshInstance3D.new()
	rifle.name = "RifleModel"
	rifle.mesh = model.rifle.mesh
	rifle.transform = model.rifle.transform
	rifle.visible = model.rifle.visible
	hand.add_child(rifle)
	if model.blade != null and model.blade.visible:  # S4: a soldier who held the blade falls with it
		var blade := MeshInstance3D.new()
		blade.name = "BladeModel"
		blade.mesh = model.blade.mesh
		blade.transform = model.blade.transform
		hand.add_child(blade)
	var player := AnimationPlayer.new()
	player.name = "Collapse"
	player.root_node = NodePath("..")
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	var library := AnimationLibrary.new()
	library.add_animation(&"collapse", animation)
	player.add_animation_library(&"", library)
	player.autoplay = "collapse"
	corpse.add_child(player)
	return corpse
