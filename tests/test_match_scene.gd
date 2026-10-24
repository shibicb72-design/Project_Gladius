extends "res://tests/test_case.gd"

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP_PATH := "res://data/maps/alesia_section.json"


func _new_match() -> MatchRoot:  # call with await
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(m)
	# The tree may not run _ready (and so resolve @onready nodes) until the next frame.
	await tree.physics_frame
	m.director.load_config()
	return m


func _frames(n: int) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for i in n:
		await tree.physics_frame


func test_map_json_matches_scene_markers() -> void:
	var def := DataRegistry.new().load_file(MAP_PATH)
	var scene: Node = load(def["scene"]).instantiate()
	var markers: Dictionary = {}
	for c in scene.get_node("SquadSpawns").get_children():
		markers[str(c.name)] = c
	var spawns: Dictionary = def["spawns"]
	for id in spawns:
		assert_true(markers.has(id), "marker for " + id)
		if markers.has(id):
			var p: Array = spawns[id]
			assert_true(markers[id].position.distance_to(Vector3(p[0], p[1], p[2])) < 0.05, "position of " + id)
	for id in markers:
		assert_true(spawns.has(id), "json entry for " + id)
	assert_true(scene.get_node_or_null("HillCenter") != null, "hill center marker")
	assert_true(scene.get_node_or_null("Nav") is NavigationRegion3D, "navigation region")
	assert_true("koth" in def["modes"], "koth mode listed")
	scene.free()


func test_match_scene_instantiates() -> void:
	var m := await _new_match()
	m.bake_navmesh = true  # exercise the load-time navmesh bake once
	assert_true(m.begin(), "begin succeeds")
	await _frames(2)
	assert_true(m.local_player != null and m.local_player.is_alive(), "local player alive")
	assert_true(m.director.running, "director running")
	m.queue_free()


func test_pawn_in_hill_scores() -> void:
	var m := await _new_match()
	m.begin()
	await _frames(2)
	m.local_player.global_position = Vector3(0.0, 0.1, 0.0)
	await _frames(130)
	assert_true(float(m.director.rules.scores[0]) >= 1.0, "squad 0 scored, got %s" % m.director.rules.scores[0])
	m.queue_free()


func test_dead_pawn_respawns_at_squad_spot_protected() -> void:
	var m := await _new_match()
	m.director.match_cfg["respawn_s"] = 0.2
	m.director.match_cfg["spawn_protection_s"] = 30.0
	m.begin()
	await _frames(2)
	var pawn := m.local_player
	var spot: Variant = m.director.spawn_rules.squad_spot(0)
	var spot_pos := Vector3(m.map_def["spawns"][spot][0], m.map_def["spawns"][spot][1], m.map_def["spawns"][spot][2])
	pawn.global_position = Vector3(0.0, 0.1, 0.0)
	pawn.bridge.state.health = 0.0
	await _frames(3)
	assert_true(not pawn.is_alive(), "dead while waiting")
	assert_true(m.director.spawn_rules.is_waiting_respawn(0), "respawn timer running")
	await _frames(30)
	assert_true(pawn.is_alive(), "respawned")
	assert_true(pawn.global_position.distance_to(spot_pos) < 1.0, "back at squad spot")
	assert_true(pawn.bridge.spawn_protected, "spawn protected")
	m.queue_free()


func test_match_over_signal_at_score_to_win() -> void:
	var m := await _new_match()
	m.director.mode_cfg["score_to_win"] = 1
	var seen: Array = []
	m.director.match_over.connect(func(r): seen.append(r))
	m.begin()
	await _frames(2)
	m.local_player.global_position = Vector3(0.0, 0.1, 0.0)
	await _frames(100)
	assert_eq(seen.size(), 1, "match_over emitted once")
	if seen.size() == 1:
		assert_eq(seen[0]["winner"], 0, "squad 0 won")
	assert_true(not m.director.running, "director stopped")
	m.queue_free()
