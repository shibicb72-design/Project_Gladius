extends "res://tests/test_case.gd"
## C0: the capture tool's 3D shots (tools/scene_shots.gd). The PNGs need a window; these headless checks keep
## the shot list, its framing data and the lane search honest.
const SceneShots := preload("res://tools/scene_shots.gd")


class ToolStub extends Node:
	var lines: PackedStringArray = []
	func _log(s: String) -> void:
		lines.append(s)


func test_every_shot_has_framing_data_marked_placeholder() -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/capture_shots.json")
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-3D-CAPTURE"), "framing numbers are placeholders with an OQ id")
	assert_eq(SceneShots.SHOTS.size(), 9, "turntable, 50 m, 50 m magnifier, overview, loot line-up, wall close-up, kit line-up (W1), ground views (W3), in-match third person (S0)")
	for view: Dictionary in cfg["in_match"]["views"]:
		assert_true(view.has("name") and view.has("at") and view.has("look_at"), "an in-match view has a name, a place to stand and something to look at")
	for view: Dictionary in cfg["ground_views"]["views"]:
		assert_true(view.has("name") and view.has("from") and (view.has("landmark") or view.has("look_at")), "a ground view has a name, a place to stand and something to look at")
	var lined_up := {}
	for row: Array in cfg["kit_lineup"]["rows"]:
		for type: String in row:
			lined_up[type] = true
	for type: String in WorldKit.config()["types"]:
		assert_true(lined_up.has(type), "the kit line-up shows " + type)
	for shot in SceneShots.SHOTS:
		var data_key := shot.trim_suffix("_zoom")  # the magnifier reuses the 50 m scene
		assert_true(cfg.has(data_key) and cfg[data_key] is Dictionary, "framing data for " + shot)
		assert_true(SceneShots.new().has_method("_" + data_key), "builder for " + shot)
	assert_eq((cfg["soldier_turntable"]["yaws_deg"] as Array).size(), 3, "front, side and back")
	assert_eq(float(cfg["soldier_50m"]["distance_m"]), 50.0, "the far shot is the 50 m shot")


func test_lane_search_finds_a_clear_50_m_lane_on_the_map() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = false
	match_scene.fill_bots = false
	tree.root.add_child(match_scene)
	await tree.physics_frame
	assert_true(match_scene.begin(), "match starts")
	match_scene.local_player.set_physics_process(false)
	await tree.physics_frame
	await tree.physics_frame
	var stub := ToolStub.new()
	var shots := SceneShots.new()
	shots._tool = stub
	shots._cfg = DataRegistry.new().load_file("res://data/capture_shots.json")
	shots._match = match_scene
	var length := float(shots._cfg["soldier_50m"]["distance_m"])
	shots._pick_lane(length)
	assert_true(stub.lines.size() == 1 and stub.lines[0].begins_with("RESULT scene_lane_found=true"), "a stage with a clear lane exists: " + str(stub.lines))
	var eye := Vector3.UP * float(shots._cfg["soldier_50m"]["eye_height_m"])
	assert_true(shots._clear(shots._stage + eye, shots._stage + shots._lane * length + eye), "no world collider between the camera and the soldiers")
	assert_true(is_equal_approx(shots._lane.length(), 1.0) and is_zero_approx(shots._lane.y), "lane is a level unit direction")
	print("SCENE_SHOTS stage=", shots._stage, " lane=", shots._lane)
	stub.free()
	match_scene.free()
