extends "res://tests/test_case.gd"
const Checks := preload("res://tests/soldier_checks.gd")

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
	# Was "corpse shell follows Head bone" (D1, Shibi, Nov 9 2026: the yellow sphere is a debug overlay, off by
	# default). The helmet is in the shared armor mesh, skinned to the Head bone, so it follows the corpse's head.
	assert_true(rig.get_node_or_null("HeadAttachment/Shell") == null, "no yellow sphere on the corpse while the debug flag is off")
	var head_bone := rig.find_bone("Head")
	var helmet_parts := 0
	for i in model.part_bones.size():
		if Checks.is_helmet(model, i):
			helmet_parts += 1
	assert_true(helmet_parts > 0 and head_bone == Checks.head_bone(model), "corpse helmet follows the Head bone")
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
	# Was the yellow shell's box plus 0.02: now the head hitbox's box, carried by the corpse's Head bone.
	var head_bounds := rig.global_transform * snapshots[head_bone] * Checks.head_box_local(pawn).grow(Checks.body_clearance())
	for i in model.local_part_bounds.size():
		if Checks.is_helmet(model, i):
			continue
		var part := rig.global_transform * snapshots[model.part_bones[i]] * model.local_part_bounds[i]
		assert_true(not head_bounds.intersects(part), "corpse end pose clears the head: " + String(model.get_meta("parts")[i]))
	for node in corpse.find_children("*", "", true, false):
		assert_true(node.get_script() == null, "no corpse scripts")
		assert_true(not node is CollisionObject3D and not node is CollisionShape3D, "no corpse collision")
	print("RIG_DEATH copied_bones=", rig.get_bone_count(), " surfaces=2 collider_free=true scripts=0")
	corpse.free()
	pawn.free()
