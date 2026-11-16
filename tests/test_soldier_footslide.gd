extends "res://tests/test_case.gd"
## M2 AN1 commit 4: foot slide of the third-person soldier. A REAL pawn and SoldierModel are moved at a forced ground
## speed (the pawn's own physics step is off; the test moves it by velocity x dt, as the game does), the model's
## tree and skeleton modifiers are advanced by hand with the same dt, and every boot's heel and toe (SoldierClips
## sole points) is followed in world space. While a point touches the ground (within gait.contact_height_m of the
## lowest point seen) it should not move: the drift of one contact is the farthest it gets, on the ground plane,
## from where it touched down. Limit: data/anim_third_person.json gait.foot_slide_max_m (OQ-ANIM-FOOTSLIDE placeholder).
## Speeds come from data: the normal move speed (Pawn.get_move_speed, stats.json base_speed_mps), sprint
## (get_max_move_speed) and downed (br.json downed.downed_move_speed_pct of the move speed).

const DT := 1.0 / 60.0


## Moves a fresh pawn at `velocity` (pawn-local direction scaled to m/s) for warm_s + measure_s and returns
## {max_m, mean_m, contacts}. `downed` sets Life.DOWNED with br.json's downed speed percent.
## `baseline`: the code-built clips at their own rate with no gait or crawl modifier, as before M2 AN1 commit 4
## (the library is passed over with ClipLibrary.skip_sources; the code path is then the old one for straight moves).
func drift(velocity: Vector3, downed: bool, baseline: bool = false, warm_s: float = 1.0, measure_s: float = 2.5) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop()
	ClipLibrary.skip_sources.assign(["blender", "ual"] if baseline else [])
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	ClipLibrary.skip_sources.clear()
	pawn.set_physics_process(false)
	if downed:
		pawn.downed_move_speed_pct = float(DataRegistry.new().load_file("res://data/br.json")["downed"]["downed_move_speed_pct"])
		pawn.life = Pawn.Life.DOWNED
	var model := pawn.get_node("SoldierModel") as SoldierModel
	if baseline:
		model.gait.active = false
		model.crawl.active = false
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var soles := SoldierClips.sole_points(model.skeleton)
	var contact_m := float(SoldierRig.config()["gait"]["contact_height_m"])
	var track: Array = []  # per frame: 4 world points
	var frames := roundi((warm_s + measure_s) / DT)
	var warm := roundi(warm_s / DT)
	for f in frames:
		pawn.velocity = velocity
		pawn.global_position += velocity * DT
		model._process(DT)
		model.animation_tree.advance(DT)
		# The modifiers (SoldierGait, SoldierPose, IK) run on the skeleton's next update with this dt; their result
		# is the model's pose_cache (the final pose of the frame, as drawn).
		model.skeleton.advance(DT)
		await tree.process_frame
		if f < warm:
			continue
		var world: Array[Vector3] = []
		for p in SoldierClips.contacts(model.pose_cache, soles):
			world.append(model.skeleton.global_transform * p)
		track.append(world)
	var floor_y := INF
	for world: Array in track:
		for p: Vector3 in world:
			floor_y = minf(floor_y, p.y)
	var worst := 0.0
	var total := 0.0
	var count := 0
	for point in (track[0] as Array).size():
		var start := Vector3.INF
		var far := 0.0
		var frames_down := 0
		for i in track.size() + 1:
			var down := i < track.size() and (track[i][point] as Vector3).y <= floor_y + contact_m
			if down:
				var p: Vector3 = track[i][point]
				if frames_down == 0:
					start = p
				frames_down += 1
				far = maxf(far, Vector2(p.x - start.x, p.z - start.z).length())
			elif frames_down > 0:
				# A contact cut by the window's start or end still counts (a point down the whole window is a point
				# that should never move); a touch of under three frames is a graze, not a contact.
				if frames_down >= 3:
					worst = maxf(worst, far)
					total += far
					count += 1
				frames_down = 0
				far = 0.0
	pawn.free()
	return {"max_m": worst, "mean_m": total / maxf(count, 1.0), "contacts": count}


func _speeds() -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	var out := {"move": pawn.get_move_speed(), "sprint": pawn.get_max_move_speed(),
		"downed": pawn.get_move_speed() * float(DataRegistry.new().load_file("res://data/br.json")["downed"]["downed_move_speed_pct"]) / 100.0}
	pawn.free()
	return out


func test_stance_feet_stay_planted_at_move_sprint_and_downed_speeds() -> void:
	var limit := float(SoldierRig.config()["gait"]["foot_slide_max_m"])
	var speeds := _speeds()
	for case: Array in [["move", Vector3.FORWARD, false], ["sprint", Vector3.FORWARD, false], ["downed", Vector3.FORWARD, true]]:
		var result: Dictionary = await drift(case[1] * float(speeds[case[0]]), case[2])
		print("FOOTSLIDE %s speed=%.2f max_m=%.3f mean_m=%.3f contacts=%d limit=%.3f" % [case[0], speeds[case[0]], result["max_m"], result["mean_m"], result["contacts"], limit])
		assert_true(int(result["contacts"]) >= 2, "%s: the feet touch the ground (%d contacts)" % [case[0], result["contacts"]])
		assert_true(float(result["max_m"]) <= limit, "%s: stance drift %.3f m within %.3f m" % [case[0], result["max_m"], limit])


## Before (the code-built clips, measured the same way) against after: the library gait slides less at every speed.
func test_library_gait_slides_less_than_the_code_built_baseline() -> void:
	var speeds := _speeds()
	for case: Array in [["move", false], ["sprint", false], ["downed", true]]:
		var before: Dictionary = await drift(Vector3.FORWARD * float(speeds[case[0]]), case[1], true)
		var after: Dictionary = await drift(Vector3.FORWARD * float(speeds[case[0]]), case[1])
		print("FOOTSLIDE_BEFORE_AFTER %s speed=%.2f before_max_m=%.3f (contacts %d) after_max_m=%.3f (contacts %d)" % [case[0], speeds[case[0]], before["max_m"], before["contacts"], after["max_m"], after["contacts"]])
		assert_true(float(after["max_m"]) < float(before["max_m"]) or int(before["contacts"]) == 0, "%s: the library gait slides less than the code-built one" % case[0])


## M2 AN2 item 2: at sprint speed the sprint cycle plays at about its authored rate (the runtime-retargeted UAL sprint
## needed ~1.5x; the Blender bake measures the real stance speed and sets the stride, tools/blender/
## soldier_clips_design.json). Rate = ground speed / the clip's natural ground speed (SoldierClips.measure, with the
## slot's gait.cycle_scale), as SoldierModel plays it.
const SPRINT_RATE_MAX := 0.95
const JOG_RATE_RANGE := [0.85, 1.15]


func test_sprint_and_jog_play_near_their_authored_rate() -> void:
	var speeds := _speeds()
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	var skeleton := (pawn.get_node("SoldierModel") as SoldierModel).skeleton
	var clips := ClipLibrary.new()
	var scale: Dictionary = SoldierRig.config()["gait"].get("cycle_scale", {})
	var rates := {}
	# The runtime-retargeted UAL fallback first (printed for the record, not asserted), then the shipped clips.
	for skip: Array in [["blender"], []]:
		ClipLibrary.skip_sources.assign(skip)
		for case: Array in [["run_fwd", "sprint"], ["walk_fwd", "move"]]:
			var clip := clips.resolve(case[0], null, skeleton)
			var gait := SoldierClips.gait(clip, skeleton, false)
			var natural := float(gait["speed_mps"]) * float(scale.get(case[0], 1.0))
			rates[case[0]] = float(speeds[case[1]]) / natural
			print("GAIT_RATE %s source=%s speed=%.2f natural_mps=%.2f cycle_m=%.3f play_rate=%.3f" % [case[0], clips.source_for(case[0]), speeds[case[1]], natural, gait["cycle_m"], rates[case[0]]])
	ClipLibrary.skip_sources.clear()
	ClipLibrary.release_sources()
	pawn.free()
	assert_true(float(rates["run_fwd"]) <= SPRINT_RATE_MAX, "the sprint plays at %.3fx its authored rate at sprint speed (<= %.2f)" % [rates["run_fwd"], SPRINT_RATE_MAX])
	assert_true(float(rates["walk_fwd"]) >= JOG_RATE_RANGE[0] and float(rates["walk_fwd"]) <= JOG_RATE_RANGE[1], "the jog plays at %.3fx at move speed" % rates["walk_fwd"])


func test_strafe_and_back_pedal_slide_is_measured() -> void:
	var limit := float(SoldierRig.config()["gait"]["foot_slide_max_m"])
	var speeds := _speeds()
	var ratio := float(DataRegistry.new().get_movement_cfg()["strafe_back_ratio"]["value"])
	for case: Array in [["strafe_right", Vector3.RIGHT], ["strafe_left", Vector3.LEFT], ["back", Vector3.BACK], ["slow_walk", Vector3.FORWARD]]:
		var speed := float(speeds["move"]) * (float(SoldierRig.config()["gait"]["walk_slow_blend"]) if case[0] == "slow_walk" else ratio)
		var result: Dictionary = await drift(case[1] * speed, false)
		print("FOOTSLIDE %s speed=%.2f max_m=%.3f mean_m=%.3f contacts=%d limit=%.3f" % [case[0], speed, result["max_m"], result["mean_m"], result["contacts"], limit])
		assert_true(float(result["max_m"]) <= limit * 2.0, "%s: stance drift %.3f m within twice the limit" % [case[0], result["max_m"]])
