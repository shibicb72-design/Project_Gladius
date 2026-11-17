extends "res://tests/test_case.gd"
## M2 AN3: assets/generated/characters/soldier_rifle.glb (tools/blender/build_soldier_rifle.py), the Blender-keyed
## third-person rifle reload per gun (data/anim_sources.json reload_<gun>, data/anim_third_person.json
## upper_body.reload_keyed). Both clips resolve from the "blender" source; SoldierModel plays the shown gun's keyed
## reload scaled to the weapon's WeaponDef.reload_s and cut to the code-built reload's tracks (the reload layer moves
## no new bone); its first and last frames are the aimed pose (pitch 0); on the real model the left hand starts and
## ends where the aimed pose (the left-hand IK) holds it, with no snap above reload_keyed.snap_max_m when the reload
## starts or the IK takes the hand back; each stage key sits at its reload_key_fractions time on its point of the
## gun (or the belt pouch). The code-built reload stays the fallback (code_built_reload, the blender source skipped).

const GUNS: Array[String] = ["pilum_br", "sagittarii_rifle"]
const DT := 1.0 / 60.0
const POSE_DEG := 0.5
const POSE_M := 0.001
const HAND_M := 0.01  # start / end: the clip's left hand within 1 cm of where the aimed pose holds it
const KEY_M := 0.005  # a stage key's left hand on its target (beyond what the arm can reach)


func _pawn(gun: String) -> Pawn:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.loadout.slots[pawn.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(gun))
	return pawn


func _angle_deg(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.normalized().dot(b.normalized())), 0.0, 1.0)))


func _track(clip: Animation, bone: String, kind: int) -> int:
	return clip.find_track(NodePath("Skeleton3D:" + bone), kind)


func test_both_clips_resolve_scale_to_reload_s_and_move_only_the_code_built_bones() -> void:
	for gun in GUNS:
		var pawn := _pawn(gun)
		var model := pawn.get_node("SoldierModel") as SoldierModel
		var clips := model.animation_tree.get_meta(&"clip_library") as ClipLibrary
		assert_true(clips.resolve("reload_" + gun, null, model.skeleton) != null, "%s: the keyed reload resolves" % gun)
		assert_eq(clips.source_for("reload_" + gun), "blender", "%s: from soldier_rifle.glb" % gun)
		var def := pawn.loadout.get_active().def
		pawn.reload_started.emit()
		var played := model.animation_tree.get_animation(&"reload")
		assert_true(is_equal_approx(played.length, def.reload_s), "%s: the keyed reload lasts reload_s %.2f s (%.3f)" % [gun, def.reload_s, played.length])
		var code := SoldierAnimation.reload_clip(model.skeleton, def.reload_s, model._upper_cfg)
		assert_eq(played.get_track_count(), code.get_track_count(), "%s: the keyed reload has the code-built reload's tracks" % gun)
		for track in played.get_track_count():
			assert_true(code.find_track(played.track_get_path(track), played.track_get_type(track)) >= 0, "%s: %s is a code-built reload track" % [gun, played.track_get_path(track)])
		for side in ["Left", "Right"]:
			assert_true(_track(played, side + "UpperArm", Animation.TYPE_POSITION_3D) >= 0, "%s: %sUpperArm shoulder position keys" % [gun, side])
		# Stage keys at reload_key_fractions x reload_s (the authored frames land on them).
		var track := _track(played, "LeftHand", Animation.TYPE_ROTATION_3D)
		for f in model._upper_cfg["reload_key_fractions"]:
			var at := float(f) * def.reload_s
			var found := false
			for k in played.track_get_key_count(track):
				found = found or absf(played.track_get_key_time(track, k) - at) < 0.0005
			assert_true(found, "%s: a key at fraction %.2f (%.3f s)" % [gun, float(f), at])
		pawn.free()


func test_first_and_last_frames_are_the_aimed_pose() -> void:
	var pawn := _pawn(GUNS[0])
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var clips := model.animation_tree.get_meta(&"clip_library") as ClipLibrary
	var aim := SoldierAnimation.aim_clip(model.skeleton, model._upper_cfg, 0.0)
	for gun in GUNS:
		var code := SoldierAnimation.reload_clip(model.skeleton, 1.0, model._upper_cfg)
		var clip := SoldierAnimation.resolve_reload(clips, gun, code, model.skeleton)
		for t in [0.0, clip.length]:
			for bone in ["RightUpperArm", "RightForeArm", "Chest"]:
				var want: Quaternion = aim.rotation_track_interpolate(_track(aim, bone, Animation.TYPE_ROTATION_3D), 0.0)
				var got := clip.rotation_track_interpolate(_track(clip, bone, Animation.TYPE_ROTATION_3D), t)
				assert_true(_angle_deg(got, want) < POSE_DEG, "%s t=%.2f: %s is the aimed turn (%.3f deg)" % [gun, t, bone, _angle_deg(got, want)])
			var hand := clip.rotation_track_interpolate(_track(clip, "RightHand", Animation.TYPE_ROTATION_3D), t)
			var aimed_hand: Quaternion = aim.rotation_track_interpolate(_track(aim, "RightHand", Animation.TYPE_ROTATION_3D), 0.0)
			assert_true(_angle_deg(hand, aimed_hand) < POSE_DEG, "%s t=%.2f: the rifle is not canted (%.3f deg)" % [gun, t, _angle_deg(hand, aimed_hand)])
			for side in ["Left", "Right"]:
				var want_p: Vector3 = aim.position_track_interpolate(_track(aim, side + "UpperArm", Animation.TYPE_POSITION_3D), 0.0)
				var got_p := clip.position_track_interpolate(_track(clip, side + "UpperArm", Animation.TYPE_POSITION_3D), t)
				assert_true(got_p.distance_to(want_p) < POSE_M, "%s t=%.2f: %s shoulder where the aim clip puts it (%.4f m)" % [gun, t, side, got_p.distance_to(want_p)])
	pawn.free()


## The chest-frame position of a side's hand from the clip's arm keys at time t (the chest's own turn left out).
func _hand(clip: Animation, skeleton: Skeleton3D, side: String, t: float) -> Dictionary:
	var chest := skeleton.get_bone_global_rest(skeleton.find_bone("Chest")).origin
	var ua := chest + clip.position_track_interpolate(_track(clip, side + "UpperArm", Animation.TYPE_POSITION_3D), t)
	var u := clip.rotation_track_interpolate(_track(clip, side + "UpperArm", Animation.TYPE_ROTATION_3D), t)
	var f := u * clip.rotation_track_interpolate(_track(clip, side + "ForeArm", Animation.TYPE_ROTATION_3D), t)
	var h := f * clip.rotation_track_interpolate(_track(clip, side + "Hand", Animation.TYPE_ROTATION_3D), t)
	var at := ua + u * skeleton.get_bone_rest(skeleton.find_bone(side + "ForeArm")).origin + f * skeleton.get_bone_rest(skeleton.find_bone(side + "Hand")).origin
	return {"at": at, "turn": h, "root": ua}


func test_stage_keys_put_the_left_hand_on_their_points() -> void:
	var pawn := _pawn(GUNS[0])
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var skeleton := model.skeleton
	var clips := model.animation_tree.get_meta(&"clip_library") as ClipLibrary
	var cfg: Dictionary = model._upper_cfg
	var keyed: Dictionary = cfg["reload_keyed"]
	var art: Dictionary = DataRegistry.new().load_file("res://data/art_soldier.json")["weapons"]
	var reach := skeleton.get_bone_rest(skeleton.find_bone("LeftForeArm")).origin.length() + skeleton.get_bone_rest(skeleton.find_bone("LeftHand")).origin.length()
	var chest_at := skeleton.get_bone_global_rest(skeleton.find_bone("Chest")).origin
	for gun in GUNS:
		var scale := SoldierLook.gun_scale(gun)
		var grip := SoldierLook.gun_point(gun, "grip_m")
		var points := {"foregrip": SoldierLook.gun_point(gun, "foregrip_m"), "cell": LowpolyKit.vec(art[gun]["cell"]["at"]) * scale,
			"charge": LowpolyKit.vec(art[gun]["charge"]["at"]) * scale}
		var clip := SoldierAnimation.resolve_reload(clips, gun, SoldierAnimation.reload_clip(skeleton, 1.0, cfg), skeleton)
		var fractions: Array = cfg["reload_key_fractions"]
		for i in fractions.size():
			var t := float(fractions[i]) * clip.length
			var right := _hand(clip, skeleton, "Right", t)
			var left := _hand(clip, skeleton, "Left", t)
			var row: Dictionary = keyed["left"][i]
			var gun_q: Quaternion = right["turn"]
			var off := LowpolyKit.vec(row["off_m"])
			var target: Vector3
			if String(row["at"]) == "pouch":
				var chest_q := clip.rotation_track_interpolate(_track(clip, "Chest", Animation.TYPE_ROTATION_3D), t)
				target = chest_q.inverse() * (LowpolyKit.vec(keyed["pouch_m"]) + off - chest_at) + chest_at
			else:
				target = (right["at"] as Vector3) + gun_q * ((points[row["at"]] as Vector3) - grip) + gun_q * off
			var excess := maxf(0.0, (left["root"] as Vector3).distance_to(target) - reach)
			var error := (left["at"] as Vector3).distance_to(target)
			assert_true(error <= KEY_M + excess, "%s key %d (%s, %.2f): left hand %.4f m from its point (out of reach by %.4f m)" % [gun, i, row["at"], float(fractions[i]), error, excess])
	pawn.free()


func _step(pawn: Pawn, model: SoldierModel, dt: float) -> void:
	pawn.velocity = Vector3.ZERO
	model._process(dt)
	model.animation_tree.advance(dt)
	model.skeleton.advance(dt)
	await (Engine.get_main_loop() as SceneTree).process_frame


func _left_hand(model: SoldierModel) -> Vector3:
	return model.skeleton.global_transform * model.pose_cache[model.skeleton.find_bone("LeftHand")].origin


func test_on_the_real_model_the_hand_starts_and_ends_on_the_gun_without_a_snap() -> void:
	var snap_max := float(SoldierRig.config()["upper_body"]["reload_keyed"]["snap_max_m"])
	for gun in GUNS:
		var pawn := _pawn(gun)
		var model := pawn.get_node("SoldierModel") as SoldierModel
		model.set_process(false)
		model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		for i in 6:
			await _step(pawn, model, DT)
		assert_eq(model.shown_gun, gun, "the %s is shown" % gun)
		var aimed := _left_hand(model)
		var aim_error := model.hand_error_m
		var reload_s := pawn.loadout.get_active().def.reload_s
		pawn.reload_started.emit()
		await _step(pawn, model, DT)  # the reload's first frame shows its time 0
		assert_true(bool(model.animation_tree.get("parameters/reload/active")), "%s: the reload plays" % gun)
		var start := _left_hand(model)
		var start_error := start.distance_to(model.foregrip.global_position)
		# Just before the end (the clip's last pose), then one step on: the IK holds the hand again.
		await _step(pawn, model, reload_s - 0.002)
		assert_true(bool(model.animation_tree.get("parameters/reload/active")), "%s: still reloading just before reload_s" % gun)
		var end := _left_hand(model)
		var end_error := end.distance_to(model.foregrip.global_position)
		await _step(pawn, model, DT)
		assert_true(not bool(model.animation_tree.get("parameters/reload/active")), "%s: the reload ended at reload_s" % gun)
		var after := _left_hand(model)
		print("RIFLE_RELOAD %s aim_error_m=%.4f start_error_m=%.4f end_error_m=%.4f snap_start_m=%.4f snap_end_m=%.4f" % [
			gun, aim_error, start_error, end_error, start.distance_to(aimed), after.distance_to(end)])
		assert_true(start_error <= aim_error + HAND_M, "%s: the reload starts with the hand on the foregrip (%.4f m; the aimed pose %.4f m)" % [gun, start_error, aim_error])
		assert_true(end_error <= aim_error + HAND_M, "%s: the reload ends with the hand on the foregrip (%.4f m; the aimed pose %.4f m)" % [gun, end_error, aim_error])
		assert_true(start.distance_to(aimed) <= snap_max, "%s: no jump when the reload starts (%.4f m)" % [gun, start.distance_to(aimed)])
		assert_true(after.distance_to(end) <= snap_max, "%s: no snap when the IK takes the hand back (%.4f m)" % [gun, after.distance_to(end)])
		pawn.free()


func test_the_code_built_reload_stays_the_fallback() -> void:
	var pawn := _pawn(GUNS[0])
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var code := SoldierAnimation.reload_clip(model.skeleton, 1.0, model._upper_cfg)
	var clips := model.animation_tree.get_meta(&"clip_library") as ClipLibrary
	assert_eq(SoldierAnimation.resolve_reload(clips, "pilum_br", code, model.skeleton, false), code, "keyed off: the code-built reload")
	assert_eq(SoldierAnimation.resolve_reload(clips, "no_such_gun", code, model.skeleton), code, "a gun without a keyed clip: the code-built reload")
	ClipLibrary.skip_sources.assign(["blender"])
	var skipped := SoldierAnimation.resolve_reload(ClipLibrary.new(), "pilum_br", code, model.skeleton)
	ClipLibrary.skip_sources.clear()
	assert_eq(skipped, code, "the blender source passed over: the code-built reload")
	SoldierModel.code_built_reload = true
	pawn.reload_started.emit()
	SoldierModel.code_built_reload = false
	var played := model.animation_tree.get_animation(&"reload")
	var track := _track(played, "LeftHand", Animation.TYPE_ROTATION_3D)
	assert_eq(played.track_get_key_count(track), (model._upper_cfg["reload_key_fractions"] as Array).size(), "code_built_reload: the code-built clip (one key per stage)")
	pawn.free()
