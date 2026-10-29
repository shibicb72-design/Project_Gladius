class_name SoldierCorpse
extends RefCounted
## Explicit native-node snapshot: no gameplay, modifier or presentation scripts copied to the corpse.

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
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		var pose := model.pose_cache[i]
		if parent >= 0:
			pose = model.pose_cache[parent].affine_inverse() * pose
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
	var armor := MeshInstance3D.new()
	armor.name = "Armor"
	armor.mesh = model.armor.mesh
	armor.skin = model.armor.skin
	armor.skeleton = NodePath("..")
	skeleton.add_child(armor)
	var head_attachment := BoneAttachment3D.new()
	head_attachment.name = "HeadAttachment"
	head_attachment.bone_name = &"Head"
	skeleton.add_child(head_attachment)
	var source_shell := source_head.get_node("HeadMesh") as MeshInstance3D
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
	hand.add_child(rifle)
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
