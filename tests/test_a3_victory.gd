extends "res://tests/test_case.gd"
## A3 item 4: the victory cheer (data/anim_sources.json victory, soldier_a3.glb). SoldierModel hears its sibling
## Director's match_over itself and plays the clip on the action layer for every LIVING pawn of the winning squad only
## (losers, downed or dead winners and a draw get nothing), upper body only (keyed.actions.victory_bones), held on its
## last frame, the left hand off the foregrip. While it plays, the pawn's own state, its movement and aim blends and the
## hips and leg bones are exactly what a run without it shows; the arms really move.

const DT := 1.0 / 60.0
const NOISE_DEG := 0.05
const NOISE_M := 0.0001


func _pawn(parent: Node, squad: int, at: Vector3) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	parent.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.set_squad(squad)
	pawn.global_position = at
	return pawn


func test_the_slot_resolves() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn := _pawn(tree.root, 0, Vector3.ZERO)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var clips := ClipLibrary.new()
	var clip := clips.resolve("victory", null, model.skeleton)
	assert_true(clip != null and clips.source_for("victory") == "blender", "victory resolves from soldier_a3.glb")
	assert_true(SoldierAnimation.SHARED_SLOTS.has("victory"), "victory is a shared slot")
	if clip != null:
		assert_true(absf(clip.length - 2.4) < 0.02, "victory lasts 2.4 s (%.3f)" % clip.length)
	var bones: Array = SoldierRig.config()["keyed"]["actions"]["victory_bones"]
	for bone: String in bones:
		assert_true(model.skeleton.find_bone(bone) >= 0, "victory bone %s exists" % bone)
		assert_true(not (bone == "Hips" or bone == "Neck" or bone == "Head" or bone.contains("Leg") or bone.contains("Foot") or bone.contains("Toes")), "victory owns no %s" % bone)
	for bone in ["LeftUpperArm", "RightUpperArm", "LeftHand", "RightHand"]:
		assert_true(bones.has(bone), "victory takes both arms (%s)" % bone)
	pawn.free()


func test_only_living_winners_cheer_on_match_over() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var world := Node3D.new()
	tree.root.add_child(world)
	var director := MatchDirector.new()
	director.name = "Director"
	world.add_child(director)
	var winner := _pawn(world, 1, Vector3(0, 0, 0))
	var mate_downed := _pawn(world, 1, Vector3(2, 0, 0))
	var mate_dead := _pawn(world, 1, Vector3(4, 0, 0))
	var loser := _pawn(world, 2, Vector3(6, 0, 0))
	mate_downed.life = Pawn.Life.DOWNED
	mate_dead.life = Pawn.Life.DEAD
	await tree.process_frame
	var models: Array[SoldierModel] = []
	for pawn in [winner, mate_downed, mate_dead, loser]:
		models.append(pawn.get_node("SoldierModel") as SoldierModel)
	# A draw: nobody.
	director.match_over.emit({"winner": -1, "draw": true, "placements": {}, "kills": {}, "scores": {}})
	for model in models:
		assert_eq(model.action_name, "", "a draw plays no victory")
	director.match_over.emit({"winner": 1, "draw": false, "placements": {}, "kills": {}, "scores": {}})
	assert_eq(models[0].action_name, SoldierModel.VICTORY, "the living winner cheers")
	assert_eq(models[1].action_name, "", "a downed winner does not")
	assert_eq(models[2].action_name, "", "a dead winner does not")
	assert_eq(models[3].action_name, "", "the loser does not")
	# It holds its last frame (the arm raised) past the clip's end, and the left hand lets go of the foregrip.
	var clip := models[0]._action_clips[SoldierModel.VICTORY] as Animation
	for i in int((clip.length + 0.5) / DT):
		models[0].drive_actions(DT)
	models[0]._show_weapon()
	assert_eq(models[0].action_name, SoldierModel.VICTORY, "still shown after the clip's length")
	assert_true(is_equal_approx(models[0].pose.action_time, clip.length) and is_equal_approx(models[0].pose.action_weight, 1.0), "held on the last frame at full weight")
	assert_eq(models[0].pose.action_bones, SoldierRig.config()["keyed"]["actions"]["victory_bones"], "on the victory bones only")
	assert_true(models[0].left_ik.influence < 0.001, "the left hand follows the clip, not the foregrip")
	assert_true(models[0].rifle.visible, "the gun stays in the hand")
	world.free()


## Fix pass 1 (S7): a winner on a ladder when the match ends cheers once the climb ends (the climb owns the action
## layer meanwhile); one who is downed before the climb ends does not.
func test_a_winner_on_a_ladder_cheers_when_the_climb_ends() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var world := Node3D.new()
	tree.root.add_child(world)
	var director := MatchDirector.new()
	director.name = "Director"
	world.add_child(director)
	var climber := _pawn(world, 1, Vector3(0, 0, 0))
	var downed := _pawn(world, 1, Vector3(3, 0, 0))
	await tree.process_frame
	var models: Array[SoldierModel] = [climber.get_node("SoldierModel") as SoldierModel, downed.get_node("SoldierModel") as SoldierModel]
	for pawn: Pawn in [climber, downed]:
		pawn.climbing = true
	for i in 30:
		for model in models:
			model.drive_actions(DT)
	assert_true(models[0].climb_weight >= 1.0, "climbing shown")
	director.match_over.emit({"winner": 1, "draw": false, "placements": {}, "kills": {}, "scores": {}})
	for i in 10:
		for model in models:
			model.drive_actions(DT)
	assert_eq(models[0].action_name, "", "no cheer while still on the ladder")
	assert_true(is_equal_approx(models[0].pose.action_weight, 1.0) and models[0].climb_clip != "", "the climb keeps the action layer")
	# The climb ends (the pawn stays where it is: no top step); one of the two was downed on the ladder first.
	downed.life = Pawn.Life.DOWNED
	for pawn: Pawn in [climber, downed]:
		pawn.climbing = false
	var started := -1
	for i in 60:
		for model in models:
			model.drive_actions(DT)
		if started < 0 and models[0].action_name == SoldierModel.VICTORY:
			started = i
	print("A3_VICTORY_LADDER cheer_started_frame=%d climb_weight=%.2f" % [started, models[0].climb_weight])
	assert_true(started >= 0, "the winner cheers once off the ladder")
	assert_eq(models[0].climb_weight, 0.0, "the climb has faded out")
	assert_true(models[0].pose.action_clip == models[0]._action_clips[SoldierModel.VICTORY], "the cheer is on the action layer")
	assert_eq(models[1].action_name, "", "a winner downed before the climb ended does not cheer")
	world.free()


func _spawn() -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn := _pawn(tree.root, 1, Vector3.ZERO)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	return {"pawn": pawn, "model": model}


func _locals(model: SoldierModel) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var skeleton := model.skeleton
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		out.append(model.pose_cache[i] if parent < 0 else model.pose_cache[parent].affine_inverse() * model.pose_cache[i])
	return out


func test_victory_leaves_movement_aim_and_legs_alone() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var runs: Array = []
	var names: Array[String] = []
	for cheer: bool in [false, true]:
		var s := _spawn()
		var pawn: Pawn = s["pawn"]
		var model: SoldierModel = s["model"]
		if names.is_empty():
			for i in model.skeleton.get_bone_count():
				names.append(String(model.skeleton.get_bone_name(i)))
		var frames: Array = []
		for f in 90:
			if cheer and f == 5:
				assert_true(model.play_victory(1), "the winner's victory starts")
			# The same inputs every run: walk forward, then sideways, the aim pitched up.
			pawn.velocity = Vector3(0, 0, -3) if f < 45 else Vector3(2.5, 0, 0)
			pawn.global_position += pawn.velocity * DT
			pawn.pitch = 0.2
			model._process(DT)
			model.animation_tree.advance(DT)
			model.skeleton.advance(DT)
			await tree.process_frame
			frames.append({"state": [pawn.global_transform, pawn.velocity, pawn.pitch, (pawn.get_node("Head") as Node3D).global_position],
				"blend": [model.animation_tree.get("parameters/locomotion/blend_position"), model.animation_tree.get("parameters/aim/blend_position")],
				"bones": _locals(model)})
		runs.append(frames)
		pawn.free()
		await tree.process_frame
	var leg_moved := 0.0
	var arm_moved := 0.0
	for f in (runs[0] as Array).size():
		var a: Dictionary = runs[0][f]
		var b: Dictionary = runs[1][f]
		assert_eq(b["state"], a["state"], "frame %d: the pawn's position, velocity, aim and head hitbox are unchanged" % f)
		assert_eq(b["blend"], a["blend"], "frame %d: the movement and aim blends are unchanged" % f)
		for i in names.size():
			var turn := rad_to_deg((a["bones"][i] as Transform3D).basis.get_rotation_quaternion().angle_to((b["bones"][i] as Transform3D).basis.get_rotation_quaternion()))
			var shift := (a["bones"][i] as Transform3D).origin.distance_to((b["bones"][i] as Transform3D).origin)
			var bone := names[i]
			if bone == "Hips" or bone.contains("Leg") or bone.contains("Foot") or bone.contains("Toes"):
				leg_moved = maxf(leg_moved, turn + shift * 1000.0)
			elif bone.contains("Arm"):
				arm_moved = maxf(arm_moved, turn)
	print("A3_VICTORY legs/hips max diff=%.4f (deg + mm), arms max diff=%.1f deg" % [leg_moved, arm_moved])
	assert_true(leg_moved < NOISE_DEG + NOISE_M * 1000.0, "the hips and legs are untouched by the victory (%.4f)" % leg_moved)
	assert_true(arm_moved > 20.0, "nonvacuous: the victory moves the arms (%.1f deg)" % arm_moved)
