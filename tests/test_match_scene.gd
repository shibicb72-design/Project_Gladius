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
	assert_true(scene.get_node_or_null("Nav") is NavigationRegion3D, "navigation region")
	assert_true("br" in def["modes"], "battle royale mode listed")
	scene.free()


func test_match_scene_instantiates() -> void:
	var m := await _new_match()
	m.bake_navmesh = true  # exercise the load-time navmesh bake once
	assert_true(m.begin(), "begin succeeds")
	await _frames(2)
	assert_true(m.local_player != null and m.local_player.is_alive(), "local player alive")
	assert_true(m.director.running, "director running")
	m.queue_free()


func test_no_respawn_in_battle_royale() -> void:
	var m := await _new_match()
	m.begin()
	await _frames(2)
	assert_true(m.director.get("spawn_rules") == null, "SpawnRules is gone from the director")
	m.queue_free()
