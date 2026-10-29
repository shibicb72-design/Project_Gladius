extends "res://tests/test_case.gd"

func test_corpse_snapshots_rig_and_collapses_without_scripts_or_colliders() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.animation_tree.set("parameters/locomotion/blend_position", Vector2(0, -1))
	model.animation_tree.advance(0.0)
	model.animation_tree.advance(float(SoldierRig.config()["locomotion"]["walk_s"]) * 0.25)
	await tree.process_frame
	await tree.process_frame
	var corpse := model.make_corpse()
	var rig := corpse.get_node("Skeleton3D") as Skeleton3D
	var player := corpse.get_node("Collapse") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.root.add_child(corpse)
	assert_true(rig != model.skeleton, "independent corpse skeleton")
	var armor := rig.get_node("Armor") as MeshInstance3D
	assert_true(armor.mesh == model.armor.mesh and armor.skin == model.armor.skin, "shared corpse mesh/Skin")
	for i in rig.get_bone_count():
		assert_true(rig.get_bone_global_pose(i).is_equal_approx(model.pose_cache[i]), "current posed bone copied: " + String(rig.get_bone_name(i)))
	var shell := rig.get_node("HeadAttachment/Shell") as MeshInstance3D
	assert_eq((shell.get_parent() as BoneAttachment3D).bone_name, &"Head", "corpse shell follows Head bone")
	assert_eq(player.get_animation(&"collapse").length, float(LowpolyKit.config()["death"]["topple_s"]), "existing topple duration")
	assert_true(player.is_playing(), "native collapse autoplay")
	var snapshots: Array[Transform3D] = []
	snapshots.resize(rig.get_bone_count())
	rig.skeleton_updated.connect(func() -> void:
		for i in snapshots.size():
			snapshots[i] = rig.get_bone_global_pose(i))
	player.advance(player.get_animation(&"collapse").length)
	await tree.process_frame
	await tree.process_frame
	var hip := rig.find_bone("Hips")
	assert_true(not snapshots[hip].basis.is_equal_approx(model.pose_cache[hip].basis), "collapse changes rig pose")
	# Final corpse end pose includes the same outer topple as DeathFx; no engine skinning used.
	corpse.rotation_degrees.x = float(LowpolyKit.config()["death"]["topple_degrees"])
	var head_bounds := rig.global_transform * snapshots[rig.find_bone("Head")] * shell.get_aabb().grow(0.02)
	for i in model.local_part_bounds.size():
		var part := rig.global_transform * snapshots[model.part_bones[i]] * model.local_part_bounds[i]
		assert_true(not head_bounds.intersects(part), "corpse end pose clears shell: " + String(model.get_meta("parts")[i]))
	for node in corpse.find_children("*", "", true, false):
		assert_true(node.get_script() == null, "no corpse scripts")
		assert_true(not node is CollisionObject3D and not node is CollisionShape3D, "no corpse collision")
	print("RIG_DEATH copied_bones=", rig.get_bone_count(), " surfaces=3 collider_free=true scripts=0")
	corpse.free()
	pawn.free()
