extends "res://tests/test_case.gd"

func test_lower_stand_keeps_live_locomotion_paths_and_replica_ground_state() -> void:
	var scene: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	scene.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var tree := model.animation_tree
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var graph := tree.tree_root as AnimationNodeBlendTree
	assert_true(graph.get_node(&"locomotion") is AnimationNodeBlendSpace2D, "root blend space stays live")
	var lower := graph.get_node(&"lower") as AnimationNodeTransition
	assert_true(lower != null, "lower transition exists")
	if lower != null:
		assert_eq(lower.input_count, 1, "only stand: no acquired airborne source")
		assert_eq(lower.get_input_name(0), "stand", "stand input name")
	var links: Array = graph.get("node_connections")
	assert_true(_connection(links, "lower", 0, "locomotion"), "stand receives original blend space")
	assert_true(_connection(links, "upper", 0, "lower"), "lower replaces previous upper input")
	for mode in [Pawn.NetMode.LOCAL, Pawn.NetMode.REPLICA, Pawn.NetMode.HOST_REMOTE]:
		pawn.net_mode = mode
		for speed in [pawn.get_move_speed(), pawn.get_max_move_speed()]:
			pawn.velocity = Vector3.FORWARD * speed
			model._process(0.1)
			tree.advance(0.0)
			assert_eq(String(tree.get("parameters/lower/current_state")), "stand", "stand for simulated and observed roles")
			assert_true((tree.get("parameters/locomotion/blend_position") as Vector2).is_equal_approx(Vector2(0, -speed / pawn.get_move_speed())), "unmodified speed blend")
	for path in ["locomotion/blend_position", "aim/blend_position", "upper/blend_amount", "fire/request", "fire/active", "reload/request", "reload/active"]:
		assert_true(tree.get("parameters/" + path) != null, "KEEP path " + path)
	pawn.velocity = Vector3.ZERO
	model._process(0.1)
	tree.advance(0.0)
	assert_eq(String(tree.get("parameters/lower/current_state")), "stand", "flat stationary replica does not enter air")
	print("ANIM_GRAPH root connections=", links, "; lower inputs=[stand]")
	pawn.free()

func _connection(links: Array, to: String, input: int, from: String) -> bool:
	for i in range(0, links.size(), 3):
		if String(links[i]) == to and int(links[i + 1]) == input and String(links[i + 2]) == from:
			return true
	return false
