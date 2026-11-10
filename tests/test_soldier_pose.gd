extends "res://tests/test_case.gd"
## S4: poses from read-only pawn state (scripts/visual/soldier_pose.gd, data/anim.json "poses"), the blade in
## the hand when only the blade is held, and the armor tier trim. A headless run can prove what the pose
## asks for and that bones move; how it looks is in the soldier_poses shots.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


## Blend times are seconds, so wait by the clock (a headless frame is a few milliseconds).
func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await _tree().process_frame


func test_pose_data_is_placeholder_and_names_real_bones() -> void:
	var cfg: Dictionary = SoldierRig.config()["poses"]
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-ANIM"), "pose numbers are placeholders with an OQ id")
	var bones := {}
	for bone: Dictionary in SoldierRig.config()["bones"]:
		bones[bone["name"]] = true
	for state in SoldierPose.STATES:
		assert_true(cfg.has(state) and (cfg["blend_s"] as Dictionary).has(state), "pose and blend time for " + state)
		for bone: String in cfg[state]["bones"]:
			assert_true(bones.has(bone), "%s poses a real bone (%s)" % [state, bone])
	for key in ["raised", "struck"]:
		for bone: String in cfg["swing"][key]:
			assert_true(bones.has(bone), "the swing poses a real bone (%s)" % bone)


func test_states_follow_the_pawn_and_never_write_to_it() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var pose := model.pose
	assert_true(pose != null and pose.get_parent() == model.skeleton, "the pose is a modifier on the soldier's skeleton")
	await _frames(3)
	var before := [pawn.global_transform, pawn.life, pawn.drop_state, pawn.armor_tier, pawn.velocity]
	var standing: Dictionary = pose.wanted()
	assert_true(float(standing["fall"]) == 0.0 and float(standing["downed"]) == 0.0 and float(standing["revive"]) == 0.0 and float(standing["land"]) == 0.0, "a standing soldier asks for no pose")
	var hips := model.skeleton.find_bone("Hips")
	var rest_height := model.pose_cache[hips].origin.y
	pawn.drop_state = Pawn.Drop.FALLING  # the test plays gameplay here; the pose only reads it
	assert_eq(float(pose.wanted()["fall"]), 1.0, "falling asks for the fall pose")
	await _wait(0.6)
	assert_true(float(pose.weights["fall"]) > 0.99, "the fall pose blends in")
	assert_true(pose.arms_weight > 0.99 and is_equal_approx(model.left_ik.influence, 1.0 - pose.arms_weight), "the left hand lets go of the rifle as the arms take the pose")
	var chest := model.skeleton.find_bone("Chest")
	assert_true(model.pose_cache[chest].basis.y.y < 0.75, "the body is tipped forward in the fall")
	pawn.drop_state = Pawn.Drop.NONE
	pawn.landed.emit()
	await _frames(2)
	assert_true(float(pose.wanted()["land"]) == 1.0, "landing asks for the crouch")
	await _wait(0.9)
	assert_true(float(pose.weights["fall"]) < 0.01 and float(pose.weights["land"]) < 0.01, "both poses blend out again")
	assert_true(absf(model.pose_cache[hips].origin.y - rest_height) < 0.02, "the hips are back at standing height")
	pawn.life = Pawn.Life.DOWNED
	assert_eq(float(pose.wanted()["downed"]), 1.0, "a downed pawn asks for the downed pose")
	await _wait(0.6)
	assert_true(model.pose_cache[hips].origin.y < rest_height - 0.3, "the downed body is low (hips %.2f m, standing %.2f m)" % [model.pose_cache[hips].origin.y, rest_height])
	# The downed pose reads about as low as the lead's downed hitbox: the head bone's centre near the data's height.
	var downed_cfg: Dictionary = SoldierRig.config()["poses"]["downed"]
	var head_y := model.pose_cache[model.skeleton.find_bone("Head")].origin.y
	assert_true(absf(head_y - float(downed_cfg["head_height_m"])) <= float(downed_cfg["head_tolerance_m"]), "the downed head sits near %.2f m (it is at %.2f m)" % [float(downed_cfg["head_height_m"]), head_y])
	var top := 0.0
	var bounds: Array[AABB] = []
	bounds.resize(model.local_part_bounds.size())
	model.posed_bounds(bounds)
	for box in bounds:
		top = maxf(top, pawn.to_local(box.end).y)
	print("ASTRA_POSE downed head_centre_m=%.2f highest_part_m=%.2f" % [head_y, top])
	pawn.life = Pawn.Life.ALIVE
	await _wait(0.6)
	# The pose changed bones only: collider, head hitbox and pawn state are as the test left them.
	assert_eq((pawn.get_node("Head") as Node3D).position, Vector3(0, 1.75, 0), "the head hitbox did not move")
	assert_eq((pawn.get_node("CollisionShape3D") as Node3D).position, Vector3(0, 0.8, 0), "the body collider did not move")
	assert_eq([pawn.global_transform, pawn.life, pawn.drop_state, pawn.armor_tier, pawn.velocity], before, "the pawn's own state is untouched")
	print("ASTRA_POSE hips_standing=%.3f" % rest_height)
	pawn.free()


func test_blade_is_shown_when_only_the_blade_is_held_and_tier_shows_on_the_trim() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	await _frames(3)
	assert_true(model.blade != null and model.rifle != null, "rifle and blade models exist")
	var active := pawn.loadout.get_active()
	assert_true(active != null and not active.def.is_melee(), "the default loadout starts on the rifle")
	assert_true(model.rifle.visible and not model.blade.visible, "the rifle is in the hand, the blade is not")
	for attempt in 3:
		if pawn.loadout.get_active().def.is_melee():
			break
		pawn.loadout.swap()
	if pawn.loadout.get_active().def.is_melee():
		await _wait(0.5)
		assert_true(model.blade.visible and not model.rifle.visible, "with the blade active the rifle is hidden and the blade shown")
		assert_true(float(model.pose.weights["blade"]) > 0.99, "the blade stance blends in")
		pawn.shot.emit(Vector3.ZERO, Vector3.FORWARD, pawn.loadout.get_active().def.id)
		assert_true(model.pose.swing_left_s > 0.0, "a blade shot starts the swing")
	else:
		assert_true(false, "the default loadout carries no blade to test with")
	# Armor tier: a per-instance value on the one shared material.
	assert_eq(SoldierSquadColour.material().get_shader_parameter("tier_surface"), WorldSurface.surface_id("tier_trim"), "the material knows the tier trim surface")
	var tiers: Array = LowpolyKit.config()["soldier"]["material"]["armor_tiers"]
	assert_eq(tiers.size(), 3, "three armor tiers have a look")
	var none: Variant = model.armor.get_instance_shader_parameter(SoldierSquadColour.TIER_PARAM)
	assert_true(none == null or (none as Vector4).w < 0.0, "no tier: the trim keeps its own paint")
	pawn.armor_tier = 2
	await _frames(2)
	var shown: Vector4 = model.armor.get_instance_shader_parameter(SoldierSquadColour.TIER_PARAM)
	var want := GreyboxArt.color_value(tiers[1]["paint"])
	assert_true(model.shown_tier == 2 and is_equal_approx(shown.x, want.r) and is_equal_approx(shown.w, float(tiers[1]["glow"])), "tier II shows its paint and glow on this soldier only")
	var trim := 0
	for part: Dictionary in LowpolyKit.config()["soldier"]["parts"]:
		if String(part.get("surface", "")) == "tier_trim":
			trim += 1
	assert_true(trim >= 4, "several parts carry the tier trim (%d)" % trim)
	pawn.free()
