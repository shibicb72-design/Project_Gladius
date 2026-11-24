extends "res://tests/test_case.gd"
## A3 item 1: ground contact of the downed crawl and the death, for both armour sets (data/cosmetics.json; the pawn's
## "armour_set" meta picks the set, as tests/test_soldier_glb.gd does). The probe (tests/a3_contact_probe.gd) skins
## each set's NEAR mesh on the CPU by the live skeleton pose and returns, per part, the height of its lowest vertex
## above a FLAT floor at the pawn's y (not terrain). Vertex sets (dominant bone weight): hand = Hand + Fingers; heel =
## Foot (not Toes), rear half of the boot; knee = UpperLeg/LowerLeg within contact.knee_radius_m of the knee joint;
## hips = Hips. The cape (shader-displaced cloth) is in no set. Sampled at contact.sample_hz (every second 60 Hz frame).
##
## Downed (no clip: SoldierPose's poses.downed + SoldierCrawl, run as skeleton modifiers on a real pawn, ticked as
## tests/test_soldier_footslide.gd does), 3 s after a 1 s warm-up, at three speeds: still; normal = full stick
## forward while downed (Pawn.get_move_speed x br.json downed_move_speed_pct, 1.41 m/s); fastest = downed mid-sprint
## (x stats.json sprint_speed_multiplier, 1.89 m/s, the most sprint_factor can carry into the down: Pawn eases it
## back to 1 while not alive). Tolerance tol = data/anim_third_person.json contact.contact_tolerance_m (OQ-A3-CONTACT).
##   1. No sinking: in EVERY frame, every part's lowest vertex >= -tol.
##   2. Knees: in every frame the LOWER of the two knees <= tol (one knee is always planted; the swing knee lifts).
##   3. Hands: both hands are crawl hands (the gun is slung while downed: SoldierModel hides it at
##      gun.hide_downed_weight; a blade, if active, stays in the right hand, but the default loadout is the rifle). A
##      hand counts as planted while SoldierCrawl says so (hand_planted: its stance half of the cycle, the diagonal
##      partner of the opposite knee, and both while still); a planted hand <= tol. Heels and hips are not planted
##      in the knee-crawl (the toes point back, the pelvis rides the thighs): only rule 1 applies to them.
## Death (SoldierCorpse.authored_collapse, from a standing soldier and from a downed one): every 30 Hz frame of the
## whole collapse (blend_s crossfade + the 2.4 s Death01 clip) plus the final pose held HELD_S later.
##   1. No sinking: every frame, every part >= -tol (the downed-to-standing crossfade included: the corpse keys the
##      legs there to keep the feet on the floor).
##   2. Settled: from contact.death_settled_s of collapse time on (the clip stops moving at about 1.9 s), and in the
##      held pose, heels, hips and hands each <= tol. Knees are not required to touch (the corpse lies with them up).
##      The hips are the baked clip's (Death01's settle_hips step lowers the pelvis; the corpse settles the hands by
##      the arm bones and nothing else of the body).

const Probe := preload("res://tests/a3_contact_probe.gd")
const DT := 1.0 / 60.0
const WARM_S := 1.0
const MEASURE_S := 3.0
const HELD_S := 1.0  # the final held pose: this long after the collapse ends
const SETTLED_PARTS: Array[String] = ["heel_l", "heel_r", "hips", "hand_l", "hand_r"]


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return SoldierRig.config()["contact"]


func _pawn(set_id: String) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.set_meta("armour_set", set_id)
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	return pawn


## One game frame of the model as tests/test_soldier_footslide.gd drives it: the pawn moves by velocity x dt, the
## tree and the skeleton modifiers advance with the same dt; pose_cache is then the drawn pose of the frame.
func _tick(pawn: Pawn, model: SoldierModel, velocity: Vector3) -> void:
	pawn.velocity = velocity
	pawn.global_position += velocity * DT
	model._process(DT)
	model.animation_tree.advance(DT)
	model.skeleton.advance(DT)
	await _tree().process_frame


func _probe(model: SoldierModel):
	return Probe.make(model.armor.mesh, model.armor.skin, model.skeleton, float(_cfg()["knee_radius_m"]))


func _speeds() -> Dictionary:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	var pct := float(DataRegistry.new().load_file("res://data/br.json")["downed"]["downed_move_speed_pct"]) / 100.0
	var out := {"downed_still": 0.0, "downed_crawl": pawn.get_move_speed() * pct, "downed_fast": pawn.get_max_move_speed() * pct}
	pawn.free()
	return out


## Whether SoldierCrawl has this hand planted (its own answer when it has one, else the knee cycle's: a hand is down
## while its diagonal partner knee, the opposite one, is in stance).
func _planted(crawl: SoldierCrawl, side: String) -> bool:
	if crawl.has_method("hand_planted"):
		return crawl.call("hand_planted", side)
	var knee_phase := crawl.phase if side == "Right" else fposmod(crawl.phase + 0.5, 1.0)
	return crawl.knee_offset(knee_phase).y <= 0.0


## 30 Hz samples over MEASURE_S of the downed crawl at `speed`, after WARM_S.
func downed_samples(set_id: String, speed: float) -> Array:
	var pawn := _pawn(set_id)
	pawn.downed_move_speed_pct = float(DataRegistry.new().load_file("res://data/br.json")["downed"]["downed_move_speed_pct"])
	pawn.life = Pawn.Life.DOWNED
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var probe = _probe(model)
	var every := roundi(1.0 / (DT * float(_cfg()["sample_hz"])))
	var out: Array = []
	for f in roundi((WARM_S + MEASURE_S) / DT):
		await _tick(pawn, model, Vector3.FORWARD * speed)
		if f < roundi(WARM_S / DT) or (f % every) != 0:
			continue
		var low: Dictionary = probe.lowest(model.pose_cache, model.skeleton.global_transform, pawn.global_position.y)
		low["planted_l"] = _planted(model.crawl, "Left")
		low["planted_r"] = _planted(model.crawl, "Right")
		low["head_m"] = model.pose_cache[model.skeleton.find_bone("Head")].origin.y
		out.append(low)
	pawn.free()
	return out


## Every 30 Hz frame of the corpse's whole collapse and the final held pose (last entry), with their times.
## from_downed: the soldier dies from the downed crawl (the battle royale's usual death) instead of standing.
func death_samples(set_id: String, from_downed: bool) -> Dictionary:
	var pawn := _pawn(set_id)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	if from_downed:
		pawn.life = Pawn.Life.DOWNED
	for f in 60:
		await _tick(pawn, model, Vector3.ZERO)
	var corpse := model.make_corpse()
	var player := corpse.get_node("Collapse") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_tree().root.add_child(corpse)
	corpse.global_transform = pawn.global_transform  # as DeathFx places it; the root is never moved after
	var rig := corpse.get_node("Skeleton3D") as Skeleton3D
	var armor := rig.get_node("Armor") as MeshInstance3D
	var probe = Probe.make(armor.mesh, armor.skin, rig, float(_cfg()["knee_radius_m"]))
	var length := player.get_animation(&"collapse").length
	var hz := float(_cfg()["sample_hz"])
	var times: Array = []
	var frames: Array = []
	for k in ceili(length * hz) + 1:
		times.append(minf(float(k) / hz, length))
	times.append(length + HELD_S)
	for t: float in times:
		player.seek(t, true)
		frames.append(probe.lowest_of(rig, pawn.global_position.y))
	var root := corpse.global_transform
	corpse.free()
	pawn.free()
	return {"times": times, "frames": frames, "root": root, "placed": pawn_placed(root)}


func pawn_placed(root: Transform3D) -> bool:
	return root.origin.y == 0.0 and root.basis.is_equal_approx(Basis.IDENTITY)


func _stats(frames: Array, part: String, from_index: int = 0) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in range(from_index, frames.size()):
		lo = minf(lo, float(frames[i][part]))
		hi = maxf(hi, float(frames[i][part]))
	return Vector2(lo, hi)


func test_probe_finds_every_part_on_both_sets() -> void:
	for set_id: String in SoldierRig.armour_sets():
		var pawn := _pawn(set_id)
		var model := pawn.get_node("SoldierModel") as SoldierModel
		var counts: Dictionary = _probe(model).counts()
		print("A3_CONTACT_VERTS set=%s %s" % [set_id, counts])
		for part in Probe.PARTS:
			assert_true(int(counts[part]) > 0, "%s: the probe finds %s vertices" % [set_id, part])
		pawn.free()


func test_downed_crawl_hands_and_knees_on_the_ground() -> void:
	var tol := float(_cfg()["contact_tolerance_m"])
	assert_true(bool(_cfg()["_placeholder"]) and String(_cfg()["_todo"]).contains("OQ-A3-CONTACT"), "the tolerance is a placeholder with its OQ id")
	var speeds := _speeds()
	for set_id: String in SoldierRig.armour_sets():
		for state: String in ["downed_still", "downed_crawl", "downed_fast"]:
			var frames := await downed_samples(set_id, float(speeds[state]))
			var worst_knee := -INF
			var worst_hand := {"l": -INF, "r": -INF}
			var planted := {"l": 0, "r": 0}
			var head := Vector2(INF, -INF)
			for f: Dictionary in frames:
				worst_knee = maxf(worst_knee, minf(f["knee_l"], f["knee_r"]))
				head = Vector2(minf(head.x, f["head_m"]), maxf(head.y, f["head_m"]))
				for s in ["l", "r"]:
					if f["planted_" + s]:
						planted[s] += 1
						worst_hand[s] = maxf(worst_hand[s], f["hand_" + s])
			for part in Probe.PARTS:
				var st := _stats(frames, part)
				var extra := ""
				if part.begins_with("hand"):
					extra = " planted_max_cm=%.1f planted_frames=%d" % [float(worst_hand[part.right(1)]) * 100.0, planted[part.right(1)]]
				print("A3_CONTACT set=%s state=%s part=%s min_cm=%.1f max_cm=%.1f%s" % [set_id, state, part, st.x * 100.0, st.y * 100.0, extra])
				assert_true(st.x >= -tol, "%s %s: %s never sinks (lowest %.1f cm, limit -%.1f)" % [set_id, state, part, st.x * 100.0, tol * 100.0])
			print("A3_CONTACT set=%s state=%s lower_knee_max_cm=%.1f head_m=%.3f..%.3f speed_mps=%.2f samples=%d" % [set_id, state, worst_knee * 100.0, head.x, head.y, speeds[state], frames.size()])
			assert_true(worst_knee <= tol, "%s %s: the lower knee is on the ground in every frame (worst %.1f cm)" % [set_id, state, worst_knee * 100.0])
			for s in ["l", "r"]:
				assert_true(int(planted[s]) > 0, "%s %s: hand_%s is planted in some frames" % [set_id, state, s])
				assert_true(float(worst_hand[s]) <= tol, "%s %s: planted hand_%s on the ground (worst %.1f cm)" % [set_id, state, s, float(worst_hand[s]) * 100.0])


func test_death_settles_heels_hips_and_hands_on_the_ground() -> void:
	var tol := float(_cfg()["contact_tolerance_m"])
	var settled_s := float(_cfg()["death_settled_s"])
	for set_id: String in SoldierRig.armour_sets():
		for from_downed in [false, true]:
			var state := "death_downed" if from_downed else "death"
			var death := await death_samples(set_id, from_downed)
			var frames: Array = death["frames"]
			var times: Array = death["times"]
			assert_true(bool(death["placed"]), "%s: the corpse root stays where DeathFx put it" % state)
			var settled := times.size() - 1
			for i in times.size():
				if float(times[i]) >= settled_s:
					settled = i
					break
			# Dying from the downed pose, the first blend_s crossfades the kneeling snapshot into the clip's STANDING first
			# frame (the knee rises while the shin swings down); SoldierCorpse keys the legs there so the feet stay on the
			# floor. Every frame, the crossfade's included, is asserted.
			for part in Probe.PARTS:
				var all := _stats(frames, part)
				var end := _stats(frames, part, settled)
				print("A3_CONTACT set=%s state=%s part=%s min_cm=%.1f max_cm=%.1f settled_cm=%.1f..%.1f held_cm=%.1f" % [set_id, state, part, all.x * 100.0, all.y * 100.0, end.x * 100.0, end.y * 100.0, float(frames[-1][part]) * 100.0])
				assert_true(all.x >= -tol, "%s %s: %s never sinks (lowest %.1f cm)" % [set_id, state, part, all.x * 100.0])
				if SETTLED_PARTS.has(part):
					assert_true(end.y <= tol, "%s %s: settled %s on the ground (highest %.1f cm from %.2f s)" % [set_id, state, part, end.y * 100.0, settled_s])
