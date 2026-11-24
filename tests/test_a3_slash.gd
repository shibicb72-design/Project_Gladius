extends "res://tests/test_case.gd"
## A3 item 2: the alternating slash set (data/anim_sources.json blade_swing_a / blade_swing_b, soldier_a3.glb,
## tools/blender/a3_clips.py). Both slots resolve from "blender"; one pawn's consecutive melee shots play a, b, a and
## every pawn counts its own swings; with the new slots unresolvable the old blade_swing still plays; sampled through
## SoldierPose's own path (the blade guard, then the slash clip at swing_clip_time with the swing's fade weight), the
## blade tip (RightHand origin + basis * (0, 0, -0.6)) travels fastest inside poses.swing strike_from .. strike_to.

const MELEE := "gladius_lux"
const SAMPLES := 120
const BLADE := Vector3(0.0, 0.0, -0.6)


func _pawn(at: Vector3 = Vector3.ZERO) -> Pawn:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = at
	pawn.loadout.slots[pawn.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(MELEE))
	return pawn


func _swing(pawn: Pawn) -> void:
	pawn.shot.emit(pawn.get_muzzle_position(), pawn.get_aim_direction(), MELEE)


func test_both_slash_slots_resolve_from_blender() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var clips := ClipLibrary.new()
	for slot in SoldierPose.SWING_SLOTS:
		var clip := clips.resolve(slot, null, model.skeleton)
		assert_true(clip != null, "%s resolves" % slot)
		assert_eq(clips.source_for(slot), "blender", "%s comes from soldier_a3.glb" % slot)
		assert_true(SoldierAnimation.SHARED_SLOTS.has(slot), "%s is a shared slot" % slot)
		assert_true(model.pose._swing_clips.has(slot), "the pose holds %s" % slot)
		if clip != null:
			assert_true(absf(clip.length - 0.6667) < 0.01, "%s lasts 0.667 s (%.3f)" % [slot, clip.length])
	assert_true(SoldierAnimation.SHARED_SLOTS.has("blade_swing"), "blade_swing stays the shared fallback")
	pawn.free()


func test_swings_alternate_per_pawn() -> void:
	var one := _pawn()
	var two := _pawn(Vector3(4, 0, 0))
	var p1 := (one.get_node("SoldierModel") as SoldierModel).pose
	var p2 := (two.get_node("SoldierModel") as SoldierModel).pose
	var seen: Array[String] = []
	for i in 3:
		_swing(one)
		seen.append(p1.swing_slot)
		assert_true(p1.swing_left_s > 0.0, "swing %d starts" % i)
		assert_true(p1.swing_clip() == p1._swing_clips[p1.swing_slot], "swing %d plays its slash clip" % i)
	assert_eq(seen, ["blade_swing_a", "blade_swing_b", "blade_swing_a"] as Array[String], "one pawn alternates a, b, a")
	_swing(two)
	assert_eq(p2.swing_slot, "blade_swing_a", "the second pawn starts its own count at a")
	assert_eq([p1.swing_count, p2.swing_count], [3, 1], "each pawn counts its own swings")
	# A rifle shot does not count as a swing.
	one.loadout.slots[one.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def("pilum_br"))
	one.shot.emit(one.get_muzzle_position(), one.get_aim_direction(), "pilum_br")
	assert_eq(p1.swing_count, 3, "a rifle shot is no swing")
	print("A3_SLASH sequence=", seen, " second=", p2.swing_slot)
	one.free()
	two.free()


func test_without_the_new_slots_the_old_blade_swing_plays() -> void:
	ClipLibrary.skip_sources.assign(["blender"])
	var pawn := _pawn()
	ClipLibrary.skip_sources.clear()
	var pose := (pawn.get_node("SoldierModel") as SoldierModel).pose
	assert_true(pose._swing_clips.is_empty(), "no slash clip resolves without the blender source")
	assert_true(pose._swing_clip != null, "the old blade_swing resolves (UAL Sword_Attack)")
	_swing(pawn)
	_swing(pawn)
	assert_eq(pose.swing_count, 2, "the swings are still counted")
	assert_true(pose.swing_clip() == pose._swing_clip, "the swing plays the old blade_swing")
	var swing: Dictionary = pose.cfg["swing"]
	assert_true(is_equal_approx(pose.swing_clip_time(0.0), float(swing["clip_from_s"])) and is_equal_approx(pose.swing_clip_time(1.0), float(swing["clip_to_s"])), "over the old clip_from_s .. clip_to_s")
	pawn.free()


const DT := 1.0 / 60.0
const ARM: Array[String] = ["RightUpperArm", "RightForeArm", "RightHand"]
## Fix pass 1 (B2): a drawn bone matches its clip key within MATCH_DEG (at full swing weight the pose sets the clip's
## rotation exactly: slerp(q, 1) = q; the margin is float noise). Swing a and b differ by more than DIFFER_DEG (the
## largest of the three arm bones) at the same swing time in at least half the full-weight frames; the drawn pose is
## further than OLD_DEG from the old blade_swing (UAL Sword_Attack) at the fallback's clip time in at least half too.
const MATCH_DEG := 1.0
const DIFFER_DEG := 15.0
const OLD_DEG := 15.0


## The drawn arm (after every modifier: SoldierModel.pose_cache, filled on skeleton_updated) as local rotations.
func _drawn_arm(model: SoldierModel) -> Array[Quaternion]:
	var out: Array[Quaternion] = []
	var skeleton := model.skeleton
	for bone in ARM:
		var i := skeleton.find_bone(bone)
		var parent := skeleton.get_bone_parent(i)
		var local := model.pose_cache[parent].affine_inverse() * model.pose_cache[i]
		out.append(local.basis.orthonormalized().get_rotation_quaternion())
	return out


func _clip_arm(clip: Animation, at: float) -> Array[Quaternion]:
	var out: Array[Quaternion] = []
	for bone in ARM:
		var key := Quaternion.IDENTITY
		for track in clip.get_track_count():
			if clip.track_get_type(track) == Animation.TYPE_ROTATION_3D and clip.track_get_path(track).get_concatenated_subnames() == bone:
				key = clip.rotation_track_interpolate(track, at)
		out.append(key)
	return out


func _max_deg(a: Array[Quaternion], b: Array[Quaternion]) -> float:
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, rad_to_deg(a[i].angle_to(b[i])))
	return worst


func _tick(pawn: Pawn, model: SoldierModel) -> void:
	model._process(DT)
	model.animation_tree.advance(DT)
	model.skeleton.advance(DT)
	await (Engine.get_main_loop() as SceneTree).process_frame


## One swing through the real path: the pawn's own shot signal, then the engine's modifier processing (the tree and
## the skeleton advanced as the engine does each frame). Returns {t (swing fraction the pose used): drawn arm} for the
## full-weight frames.
func _drawn_swing(pawn: Pawn, model: SoldierModel) -> Dictionary:
	var swing: Dictionary = model.pose.cfg["swing"]
	var s := float(swing["s"])
	_swing(pawn)
	var out := {}
	for i in int(ceil(s / DT)) + 2:
		await _tick(pawn, model)
		var left := model.pose.swing_left_s
		if left <= 0.0:
			break
		var t := 1.0 - left / s
		if t >= float(swing["fade_in"]) + 0.01 and t <= float(swing["recover_from"]) - 0.01:
			out[snappedf(t, 0.0001)] = _drawn_arm(model)
	return out


func test_drawn_arm_follows_swing_a_then_swing_b() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	for i in 10:
		await _tick(pawn, model)
	var swing: Dictionary = model.pose.cfg["swing"]
	var spans: Dictionary = swing["clips"]
	var old: Animation = SoldierAnimation.shared("blade_swing", model.skeleton)
	assert_true(old != null, "the old blade_swing resolves (for the does-not-match check)")
	var clips := {}
	for slot in SoldierPose.SWING_SLOTS:
		clips[slot] = SoldierAnimation.shared(slot, model.skeleton)
		assert_true(clips[slot] != null, "%s resolves" % slot)
	if old == null or clips.values().has(null):
		pawn.free()
		return
	var drawn := {}
	for slot in SoldierPose.SWING_SLOTS:
		drawn[slot] = await _drawn_swing(pawn, model)
		for i in 30:  # past the swing, back to the idle arm
			await _tick(pawn, model)
		var frames: Dictionary = drawn[slot]
		assert_true(frames.size() >= 6, "%s: %d full-weight frames sampled" % [slot, frames.size()])
		var span: Dictionary = spans[slot]
		var worst := 0.0
		var far_from_old := 0
		var log: Array[String] = []
		for t: float in frames:
			var at := lerpf(float(span["clip_from_s"]), float(span["clip_to_s"]), t)
			var own := _max_deg(frames[t], _clip_arm(clips[slot], at))
			var from_old := _max_deg(frames[t], _clip_arm(old, lerpf(float(swing["clip_from_s"]), float(swing["clip_to_s"]), t)))
			worst = maxf(worst, own)
			if from_old > OLD_DEG:
				far_from_old += 1
			log.append("t=%.3f own=%.2f old=%.1f" % [t, own, from_old])
		print("A3_SLASH_DRAWN %s %s" % [slot, ", ".join(log)])
		assert_true(worst <= MATCH_DEG, "%s: the drawn right arm is its own clip at the swing's clip time (worst %.2f deg > %.1f)" % [slot, worst, MATCH_DEG])
		assert_true(far_from_old * 2 >= frames.size(), "%s: the drawn right arm is not the old blade_swing (%d of %d frames over %.0f deg)" % [slot, far_from_old, frames.size(), OLD_DEG])
	# Swing 1 against swing 2 at the same swing times (the frames land on the same t: same DT, same s).
	var a: Dictionary = drawn["blade_swing_a"]
	var b: Dictionary = drawn["blade_swing_b"]
	var common := 0
	var differ := 0
	var biggest := 0.0
	for t: float in a:
		if not b.has(t):
			continue
		common += 1
		var d := _max_deg(a[t], b[t])
		biggest = maxf(biggest, d)
		if d > DIFFER_DEG:
			differ += 1
	print("A3_SLASH_DRAWN a_vs_b common=%d over_%.0f_deg=%d biggest=%.1f" % [common, DIFFER_DEG, differ, biggest])
	assert_true(common >= 6, "both swings sampled at the same swing times (%d)" % common)
	assert_true(differ * 2 >= common, "swing a and swing b draw clearly different right arms (%d of %d frames over %.0f deg)" % [differ, common, DIFFER_DEG])
	pawn.free()


## The skeleton-frame transform of `bone` from the local poses set on the skeleton.
func _global(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var out := skeleton.get_bone_pose(bone)
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		out = skeleton.get_bone_pose(parent) * out
		parent = skeleton.get_bone_parent(parent)
	return out


func test_blade_tip_is_fastest_inside_the_strike_window() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.active = false
	var skeleton := model.skeleton
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var pose := model.pose
	var swing: Dictionary = pose.cfg["swing"]
	var hand := skeleton.find_bone("RightHand")
	assert_true(is_equal_approx(float(swing["s"]), 0.34) and is_equal_approx(float(swing["strike_from"]), 0.12) and is_equal_approx(float(swing["strike_to"]), 0.5), "the swing timing is the frozen one")
	for slot in SoldierPose.SWING_SLOTS:
		if not pose._swing_clips.has(slot):
			assert_true(false, "%s resolved" % slot)
			continue
		pose.swing_slot = slot
		var clip := pose.swing_clip()
		assert_true(is_equal_approx(pose.swing_clip_time(0.0), 0.0) and absf(pose.swing_clip_time(1.0) - clip.length) < 0.01, "%s plays whole over the swing" % slot)
		var tips: Array[Vector3] = []
		for i in SAMPLES + 1:
			var t := float(i) / SAMPLES
			skeleton.reset_bone_poses()
			pose._blend_bones(skeleton, pose.cfg["blade"]["bones"], 1.0)
			var out := 1.0 - smoothstep(float(swing["recover_from"]), 1.0, t)
			pose._blend_clip(skeleton, clip, pose.swing_clip_time(t), minf(smoothstep(0.0, float(swing["fade_in"]), t), out), swing["clip_bones"], false)
			var g := _global(skeleton, hand)
			tips.append(g.origin + g.basis * BLADE)
		var best := 0.0
		var best_t := 0.0
		var profile: Array[String] = []
		for i in range(1, tips.size()):
			var speed := tips[i].distance_to(tips[i - 1]) * SAMPLES / float(swing["s"])
			if i % 6 == 0:
				profile.append("%.0f" % speed)
			if speed > best:
				best = speed
				best_t = (float(i) - 0.5) / SAMPLES
		print("A3_SLASH_TIP %s fastest=%.2f m/s at t=%.3f (window %.2f..%.2f) profile(m/s, every 0.05 of the swing)=%s" % [slot, best, best_t, float(swing["strike_from"]), float(swing["strike_to"]), ",".join(profile)])
		assert_true(best > 1.0, "%s: the blade really moves (%.2f m/s)" % [slot, best])
		assert_true(best_t >= float(swing["strike_from"]) and best_t <= float(swing["strike_to"]), "%s: the blade is fastest inside the strike window (t=%.3f)" % [slot, best_t])
	pawn.free()
