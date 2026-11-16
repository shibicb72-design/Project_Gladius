class_name SoldierCorpse
extends RefCounted
## Explicit native-node snapshot: no gameplay, modifier or presentation scripts copied to the corpse.


## M2 AN1 commit 4: the corpse's collapse from the snapshot (local bone poses) into the shared baked death clip:
## the first death.blend_s crossfade from the last living pose, then the clip plays to its end and holds. The neck
## is a root bone (the living helmet is locked on the head hitbox), so the corpse carries it on the chest top with
## its rest offset, sampled from the clip, and the head falls with the body.
static func authored_collapse(skeleton: Skeleton3D, snapshot: Array[Transform3D], death: Animation) -> Animation:
	var blend := float(SoldierRig.config()["death"]["blend_s"])
	var animation := Animation.new()
	animation.length = blend + death.length
	var hz := float(SoldierRig.config()["retarget"]["sample_hz"])
	var count := ceili(death.length * hz)
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
		positions.append(position)
	for k in count + 1:
		var t := death.length * float(k) / count
		var globals := AnimRetarget.sample_globals(death, skeleton, t)
		var carried := globals[chest] * neck_from_chest
		for i in skeleton.get_bone_count():
			var parent := skeleton.get_bone_parent(i)
			var local := globals[i] if parent < 0 else globals[parent].affine_inverse() * globals[i]
			if i == neck:
				local = carried
			elif arms.has(i):
				# The fall flings the arms up past the helmet; they keep arm_follow of the clip's turn from rest.
				local.basis = Basis(Quaternion.IDENTITY.slerp(local.basis.get_rotation_quaternion(), arm_follow))
			animation.rotation_track_insert_key(rotations[i], blend + t, local.basis.get_rotation_quaternion())
			if int(positions[i]) >= 0:
				animation.position_track_insert_key(positions[i], blend + t, local.origin)
	return animation

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
		animation = authored_collapse(skeleton, snapshot, death)
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
