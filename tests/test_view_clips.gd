extends "res://tests/test_case.gd"
## M2 AN2 item 4b: the first-person clips (tools/blender/build_view_clips.py -> view_clips_<id>.glb, data/anim.json
## first_person.clips, ViewMotion.ClipSet / clip_frame). Every weapon's file has the view rig (<= 50 bones) and the
## required clips; loops close; frame 0 of idle is today's hold pose exactly; the reload clip as played lasts the
## WeaponDef's reload_s (also for another reload_s) with the stages in order; the ADS raise ends on the ADS pose; the
## procedural fallback runs when a clip is disabled or missing.

const DT := 1.0 / 60.0
const HITSCAN_CLIPS: Array[String] = ["idle", "walk", "sprint", "ads_raise", "ads_lower", "fire", "reload", "switch_out", "switch_in", "pickup"]
const MELEE_CLIPS: Array[String] = ["idle", "swing", "switch_out", "switch_in", "pickup"]
const LOOPS: Array[String] = ["idle", "walk", "sprint"]
const IDS: Array[String] = ["pilum_br", "sagittarii_rifle", "gladius_lux"]


func _fp() -> Dictionary:
	return DataRegistry.new().load_file("res://data/anim.json")["first_person"]


func _vm_cfg() -> Dictionary:
	return DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]


func _clips_of(id: String) -> ViewMotion.ClipSet:
	return ViewMotion.ClipSet.get_for(String(_fp()["clips"]["sources"][id]))


func _motion(id: String, fp: Dictionary = {}) -> ViewMotion:
	var m := ViewMotion.new(fp if not fp.is_empty() else _fp())
	m.weapon_id = id
	return m


## Origin distance (m) + rotation difference (rad, from the quaternion chord: Quaternion.angle_to's acos reads 7e-4 rad
## for equal float quaternions).
static func _err(a: Transform3D, b: Transform3D) -> float:
	return a.origin.distance_to(b.origin) + _qerr(a.basis.get_rotation_quaternion(), b.basis.get_rotation_quaternion())


static func _qerr(p: Quaternion, q: Quaternion) -> float:
	var d := minf((p - q).length(), (p + q).length())
	return 4.0 * asin(clampf(d * 0.5, 0.0, 1.0))


func test_every_weapon_has_the_rig_and_the_required_clips() -> void:
	for id in IDS:
		var cs := _clips_of(id)
		assert_true(cs != null, "%s: the clip file loads with a view rig" % id)
		if cs == null:
			continue
		var melee := DataRegistry.new().get_weapon_def(id).is_melee()
		print("FP CLIPS %s bones=%d clips=%s" % [id, cs.rests.size(), cs.clips.keys()])
		var max_bones := int(ViewMesh.config()["budget"]["blender"]["view_rig_max_bones"])  # data/art_soldier.json, placeholder
		assert_true(cs.rests.size() <= max_bones, "%s: %d bones <= %d" % [id, cs.rests.size(), max_bones])
		var need: Array[String] = ["Weapon", "R_hand", "L_hand", "R_elbow", "L_elbow"]
		if not melee:
			need.append_array(["Cell", "Charge"])
		for side in ["R_", "L_"]:
			for n in ViewHands.finger_bone_names():
				need.append(side + n)
		for b in need:
			assert_true(cs.rests.has(b), "%s: bone %s" % [id, b])
		for c in (MELEE_CLIPS if melee else HITSCAN_CLIPS):
			var n := "%s_%s" % [id, c]
			assert_true(cs.has(n), "%s: clip %s" % [id, n])
			if not cs.has(n):
				continue
			var anim: Animation = cs.clips[n]["anim"]
			if LOOPS.has(c):
				assert_eq(anim.loop_mode, Animation.LOOP_LINEAR, "%s loops" % n)
				var first := cs.sample(n, 0.0)
				var last := cs.sample(n, cs.length(n))
				var worst := 0.0
				for b: String in first:
					worst = maxf(worst, _err(first[b], last[b]))
				assert_true(worst < 1e-4, "%s closes (first vs last sample %.6f)" % [n, worst])


## Frame 0 of idle reproduces the hold pose ViewRig builds from the data today: the weapon at the hold, cell and
## charging handle at rest, both arms placed, every finger as posed, the forearms aimed at the same elbows.
func test_idle_frame_zero_is_the_hold_pose() -> void:
	var cam := _vm_cfg()
	for id in IDS:
		var cs := _clips_of(id)
		if cs == null:
			assert_true(false, "%s: no clip file" % id)
			continue
		var melee := DataRegistry.new().get_weapon_def(id).is_melee()
		var node := ViewRig.build_weapon(id, cam["weapons"][id], String(cam["default_melee" if melee else "default_gun"]), 0.0024, Color.RED)
		var bones := cs.sample("%s_idle" % id, 0.0)
		var worst := 0.0
		var hold: Transform3D = node.get_meta(&"hold")
		worst = maxf(worst, _err(bones["Weapon"], hold))
		for sub in ["Cell", "Charge"]:
			var n := node.get_node_or_null(sub) as Node3D
			if n != null:
				worst = maxf(worst, _err(bones[sub], n.get_meta(&"rest")))
		for side in ["r", "l"]:
			var arm := node.get_node("RightArm" if side == "r" else "LeftArm") as Node3D
			var pre := String(side).to_upper() + "_"
			var place: Transform3D = arm.get_meta(&"view_xf") if arm.has_meta(&"view_xf") else arm.get_meta(&"rest")
			worst = maxf(worst, _err(bones[pre + "hand"], place))
			var skel := arm.get_node("Skeleton") as Skeleton3D
			for n in ViewHands.finger_bone_names():
				var q := skel.get_bone_pose_rotation(skel.find_bone(n))
				worst = maxf(worst, _qerr(q, (bones[pre + n] as Transform3D).basis.get_rotation_quaternion()))
			# the same forearm aim: the clip's elbow seen from the placed arm points where the built arm points
			var elbow: Vector3 = (bones[pre + "elbow"] as Transform3D).origin
			var to_clip := ((hold * arm.transform).affine_inverse() * elbow).normalized() if not arm.has_meta(&"view_xf") \
					else ((arm.get_meta(&"view_xf") as Transform3D).affine_inverse() * elbow).normalized()
			var fq := skel.get_bone_pose_rotation(skel.find_bone("forearm"))
			worst = maxf(worst, (fq * Vector3.BACK).angle_to(to_clip))
		print("FP CLIPS %s idle frame 0 vs hold pose: worst %.7f (m + rad)" % [id, worst])
		assert_true(worst < 1e-4, "%s: idle frame 0 is the hold pose (%.7f)" % [id, worst])
		node.free()


## The reload clip is played time-scaled: its length AS PLAYED equals the weapon's reload_s (and any other reload_s,
## here a test double of 2.0 s), it runs from its first to its last key, and reload_stage() goes through the stages in
## order on the same fractions the clip was authored with.
func test_reload_clip_as_played_lasts_reload_s_with_the_stages_in_order() -> void:
	for id in ["pilum_br", "sagittarii_rifle"]:
		var def_reload := DataRegistry.new().get_weapon_def(id).reload_s
		for reload_s: float in [def_reload, 2.0]:
			var m := _motion(id)
			assert_true(m.clip_on("reload"), "%s: the reload clip is enabled and present" % id)
			m.start_reload(reload_s)
			var order: Array[String] = []
			var frames := 0
			var first_t := -1.0
			var last_t := 0.0
			while m.reload_total > 0.0 and frames < 1000:
				var f := m.clip_frame()
				assert_eq(String(f.get("name", "")), "reload", "%s: the reload clip drives the parts" % id)
				if first_t < 0.0:
					first_t = float(f.get("time", 0.0))
				last_t = float(f.get("time", 0.0))
				var s := m.reload_stage()
				if order.is_empty() or order[order.size() - 1] != s:
					order.append(s)
				m.tick(DT, 0.0, 5.0, 0.0, 0.0, true, 0.0)
				frames += 1
			var length := m.clip_set().length("%s_reload" % id)
			print("FP CLIPS %s reload_s=%.3f played=%.3f s (%d frames) clip %.3f s sampled %.3f..%.3f stages=%s" % [id, reload_s, frames * DT, frames, length, first_t, last_t, order])
			assert_true(absf(frames * DT - reload_s) <= 2.0 * DT,"%s: played %.3f s == reload_s %.3f" % [id, frames * DT, reload_s])
			assert_true(first_t == 0.0 and absf(last_t - length) <= length * DT / reload_s + 1e-4, "%s: the whole clip plays (%.3f..%.3f of %.3f)" % [id, first_t, last_t, length])
			assert_eq(order, ViewMotion.RELOAD_STAGES, "%s: stages in order" % id)


## The spent cell leaves with the hand: from cell_out to the start of cell_in the left hand holds the cell (its wrist
## within a hand's length of the cell), and the cell is out of the well at the cell_out -> cell_in boundary where the
## view model drops the spent copy.
func test_reload_clip_hand_carries_the_cell() -> void:
	for id in ["pilum_br", "sagittarii_rifle"]:
		var m := _motion(id)
		var cs := m.clip_set()
		var rest: Transform3D = cs.rests["Cell"]
		m.start_reload(1.0)
		var far_hand := 0.0
		var out_at_drop := 0.0
		var last := ""
		while m.reload_total > 0.0:
			var s := m.reload_stage()
			var b: Dictionary = m.clip_frame()["bones"]
			var cell: Transform3D = b["Cell"]
			if s == "cell_out" or s == "cell_in":
				far_hand = maxf(far_hand, (b["L_hand"] as Transform3D).origin.distance_to(cell.origin))
			if last == "cell_out" and s == "cell_in":
				out_at_drop = cell.origin.distance_to(rest.origin)
			last = s
			m.tick(DT, 0.0, 5.0, 0.0, 0.0, true, 0.0)
		print("FP CLIPS %s reload: left wrist to cell at most %.3f m; cell out of the well by %.3f m at the drop" % [id, far_hand, out_at_drop])
		assert_true(far_hand < 0.13, "%s: the hand holds the cell while it is out (%.3f m)" % [id, far_hand])
		assert_true(out_at_drop > 0.1, "%s: the cell is out at the drop (%.3f m)" % [id, out_at_drop])


## ADS: the raise ends exactly on the ADS pose (the red dot on the centre ray, tests/test_first_person_camera.gd) and
## the lower on the hold; the path offset the game applies is the identity at both ends; at full ADS no looping clip
## moves the gun (calm and 1 - ads damp them as the procedural bob is damped).
func test_ads_clip_ends_on_the_ads_pose() -> void:
	var cam := _vm_cfg()
	for id in ["pilum_br", "sagittarii_rifle"]:
		var node := ViewRig.build_weapon(id, cam["weapons"][id], "pilum_br", 0.0024, Color.RED)
		var hold: Transform3D = node.get_meta(&"hold")
		var ads: Transform3D = node.get_meta(&"ads")
		var m := _motion(id)
		var cs := m.clip_set()
		var up := "%s_ads_raise" % id
		var down := "%s_ads_lower" % id
		var e_up := _err(cs.sample_bone(up, "Weapon", cs.length(up)), ads)
		var e_down := _err(cs.sample_bone(down, "Weapon", cs.length(down)), hold)
		var e_off := _err(m.clip_ads_offset(hold, ads, 0.9999), Transform3D.IDENTITY)
		print("FP CLIPS %s ads_raise end vs ADS pose %.7f, ads_lower end vs hold %.7f, offset at 0.9999 %.7f" % [id, e_up, e_down, e_off])
		assert_true(e_up < 1e-4, "%s: ads_raise ends on the ADS pose (%.7f)" % [id, e_up])
		assert_true(e_down < 1e-4, "%s: ads_lower ends on the hold (%.7f)" % [id, e_down])
		assert_true(e_off < 1e-3, "%s: the path offset vanishes at full ADS (%.7f)" % [id, e_off])
		assert_eq(m.clip_ads_offset(hold, ads, 1.0), Transform3D.IDENTITY, "%s: no offset at full ADS" % id)
		# every loop clip forced on: at full ADS idle and walk weigh nothing (sprint is cut by ADS in tick)
		var fp := _fp().duplicate(true)
		for k in ["idle", "walk", "sprint"]:
			fp["clips"]["enabled"][k] = true
		var lm := _motion(id, fp)
		for i in 30:
			lm.tick(DT, 4.0, 5.0, 0.0, 1.0, true, 0.0)
		var calm := float(cam["ads_motion_mult"]["value"])
		var d := lm.clip_loop_delta(calm, 1.0, 0.5)
		var walk_only := _err(d, Transform3D.IDENTITY)
		print("FP CLIPS %s loops at full ADS while walking: %.6f (walk clip x calm %.2f)" % [id, walk_only, calm])
		var full := _err(Transform3D.IDENTITY.interpolate_with(cs.rests["Weapon"].affine_inverse() * cs.sample_bone("%s_walk" % id, "Weapon", cs.length("%s_walk" % id) * 0.25), 1.0), Transform3D.IDENTITY)
		assert_true(walk_only <= full * calm + 1e-5, "%s: at full ADS the loops are damped like the procedural bob (%.6f <= %.6f x %.2f)" % [id, walk_only, full, calm])
		node.free()


## The fallback: with a motion disabled in data, or no clip file for the weapon, the procedural curve runs exactly as
## before (clip_frame empty, the procedural reload tilt and cell offset move).
func test_disabled_or_missing_clip_falls_back_to_the_procedural_curve() -> void:
	var fp := _fp().duplicate(true)
	for k in (fp["clips"]["enabled"] as Dictionary).keys():
		fp["clips"]["enabled"][k] = false
	var off := _motion("pilum_br", fp)
	var missing := _motion("no_such_weapon")
	for m: ViewMotion in [off, missing]:
		assert_true(not m.clip_on("reload") and not m.clip_on("switch") and not m.clip_on("swing"), "no clip")
		m.start_reload(1.0)
		for i in 30:
			m.tick(DT, 0.0, 5.0, 0.0, 0.0, true, 0.0)
		assert_true(m.clip_frame().is_empty(), "the procedural layer drives the parts")
		assert_true(m.weapon_xf(1.0).origin.length() > 0.01, "the procedural reload tilt runs")
		assert_true(m.cell_offset().origin.length() > 0.0 or m.reload_stage() == "hand_to_cell", "the procedural cell offset is live")
	var on := _motion("pilum_br")
	on.start_reload(1.0)
	for i in 30:
		on.tick(DT, 0.0, 5.0, 0.0, 0.0, true, 0.0)
	assert_true(not on.clip_frame().is_empty(), "enabled: the clip drives the parts")
	assert_true(on.weapon_xf(1.0).origin.length() < 1e-6, "enabled: the procedural reload tilt steps aside")
