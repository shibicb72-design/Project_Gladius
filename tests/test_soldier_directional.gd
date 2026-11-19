extends "res://tests/test_case.gd"

const Footslide := preload("res://tests/test_soldier_footslide.gd")
const HeadMotion := preload("res://tests/test_soldier_head_motion.gd")
const DIRECTIONS := {"strafe_l": Vector3.LEFT, "strafe_r": Vector3.RIGHT, "walk_back": Vector3.BACK}


func test_directional_clips_keep_contact_at_gameplay_speed() -> void:
	var probe := Footslide.new()
	var ratio := float(DataRegistry.new().get_movement_cfg()["strafe_back_ratio"]["value"])
	var speed := float(probe._speeds()["move"]) * ratio
	var limit := float(SoldierRig.config()["gait"]["foot_slide_max_m"])
	for slot: String in DIRECTIONS:
		var velocity: Vector3 = DIRECTIONS[slot] * speed
		var result: Dictionary = await probe.drift(velocity, false)
		print("DIRECTIONAL_FOOTSLIDE %s max_m=%.4f contacts=%d limit_m=%.3f" % [slot, result["max_m"], result["contacts"], limit])
		assert_true(int(result["contacts"]) >= 2, "%s has stance contacts" % slot)
		assert_true(float(result["max_m"]) <= limit, "%s drifts %.4f m with a %.3f m limit" % [slot, result["max_m"], limit])


func test_directional_slots_resolve_three_distinct_baked_loops() -> void:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var clips := ClipLibrary.new()
	var baked: Array[Animation] = []
	for slot: String in DIRECTIONS:
		var clip := clips.resolve(slot, null, model.skeleton)
		var candidate: Dictionary = clips.resolved_candidates.get(slot, {})
		assert_true(candidate.get("path") == "res://assets/generated/characters/soldier_directional.glb", "%s resolves to the directional bake" % slot)
		assert_true(clip != null and clip.loop_mode == Animation.LOOP_LINEAR, "%s is a loop" % slot)
		assert_true(not baked.has(clip), "%s is its own animation" % slot)
		baked.append(clip)
	pawn.free()


func test_directional_gaits_keep_the_head_within_upright_limits() -> void:
	SoldierRig.head_legacy = false
	var probe := HeadMotion.new()
	var ratio := float(DataRegistry.new().get_movement_cfg()["strafe_back_ratio"]["value"])
	for slot: String in DIRECTIONS:
		await probe._spawn()
		var velocity: Vector3 = DIRECTIONS[slot] * probe._pawn.get_move_speed() * ratio
		var worst: Dictionary = await probe._run(150, func(_frame: int) -> Vector3: return velocity)
		probe._check(slot, worst)
		await probe._free()
	failures.append_array(probe.failures)
