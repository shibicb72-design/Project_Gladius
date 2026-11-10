extends "res://tests/test_case.gd"
## W2: ground loot stays inside the zone's start circle. LootField is handed the zone block of the merged mode
## config the match already holds (MatchRoot.begin passes director.mode_cfg["zone"]); loot.json holds no copy of
## the circle. (tests/test_br_loot.gd is the lead's and stays as it is.)
const _MatchScene := preload("res://scenes/match/match.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _loot_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/loot.json")


## A started offline match without bots; `zone` entries overwrite the mode config's zone block before begin().
func _loot_match(zone: Dictionary, seed_value: int) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	m.seed_override = seed_value
	m.ground_loot = true
	_tree().root.add_child(m)
	await _tree().process_frame
	m.director.load_config()
	for key: String in zone:
		m.director.mode_cfg["zone"][key] = zone[key]
	assert_true(m.begin(), "match begins")
	m.local_player.set_physics_process(false)
	for i in 3:
		await _tree().physics_frame
	return m


func _farthest(loot: LootField, center: Vector2) -> float:
	var farthest := 0.0
	for id in loot.items:
		var p: Vector3 = loot.items[id]["pos"]
		farthest = maxf(farthest, Vector2(p.x, p.z).distance_to(center))
	return farthest


func test_every_placed_item_lies_inside_the_start_circle() -> void:
	var loot_cfg := _loot_cfg()
	assert_true(not loot_cfg.has("start_radius_m") and not loot_cfg.has("start_center"), "loot.json holds no copy of the zone circle")
	assert_true(bool(loot_cfg["_placeholder"]) and loot_cfg.has("zone_edge_margin_m"), "the edge margin is placeholder loot data")
	var worst := 0.0
	var placed := 0
	for seed_value: int in [4242, 99, 31337]:
		var m := await _loot_match({}, seed_value)
		var zone: Dictionary = m.director.mode_cfg["zone"]
		var center := Vector2(float(zone["start_center"][0]), float(zone["start_center"][1]))
		var radius := float(zone["start_radius_m"])
		assert_true(m.loot.placed and m.loot.items.size() > 30, "seed %d: most items found ground (%d)" % [seed_value, m.loot.items.size()])
		var farthest := _farthest(m.loot, center)
		assert_true(farthest <= radius - float(loot_cfg["zone_edge_margin_m"]) + 0.001, "seed %d: every item within start_radius_m %s of start_center, less the edge margin (farthest %.2f)" % [seed_value, radius, farthest])
		worst = maxf(worst, farthest)
		placed += m.loot.items.size()
		m.queue_free()
		await _tree().process_frame
	print("WORLD_LOOT circle seeds=3 placed=", placed, " farthest_m=", snappedf(worst, 0.01))


func test_a_different_mode_config_circle_moves_the_limit() -> void:
	var center := Vector2(12.0, -6.0)
	var radius := 55.0  # still at least the first phase's radius, so the mode config stays valid and the match begins
	var m := await _loot_match({"start_center": [center.x, center.y], "start_radius_m": radius}, 4242)
	assert_true(m.loot.items.size() > 30, "items still find ground in the small circle (%d)" % m.loot.items.size())
	var farthest := _farthest(m.loot, center)
	assert_true(farthest <= radius, "every item within %s m of the moved centre (farthest %.2f)" % [radius, farthest])
	m.queue_free()
	await _tree().process_frame
	# Nonvacuous: with the data's own circle the same seed does place items outside this small one.
	var wide := await _loot_match({}, 4242)
	assert_true(_farthest(wide.loot, center) > radius, "the data's circle reaches further than the small one")
	print("WORLD_LOOT moved circle radius=", radius, " farthest_m=", snappedf(farthest, 0.01), " default_farthest_m=", snappedf(_farthest(wide.loot, center), 0.01))
	wide.queue_free()
	await _tree().process_frame


func _inside(loot: LootField, landmark: Dictionary) -> int:
	var count := 0
	for id in loot.items:
		var p: Vector3 = loot.items[id]["pos"]
		if Vector2(p.x, p.z).distance_to(Vector2(float(landmark["at"][0]), float(landmark["at"][1]))) <= float(landmark["radius_m"]):
			count += 1
	return count


## W3: loot clusters name landmarks by id (data/loot.json "clusters"); MatchRoot hands LootField the landmarks of
## the map's landmark file. Clustered items keep the ground rules.
func test_loot_clusters_land_inside_their_landmarks_on_walkable_ground() -> void:
	var loot_cfg := _loot_cfg()
	var landmarks: Array = DataRegistry.new().load_file("res://data/maps/alesia_landmarks.json")["landmarks"]
	var by_id := {}
	for landmark: Dictionary in landmarks:
		by_id[landmark["id"]] = landmark
	var m := await _loot_match({}, 4242)
	# The same seed and circle with no landmarks handed in: every item scattered.
	var plain := LootField.new()
	plain.setup(loot_cfg, 4242, m.director.mode_cfg["zone"])
	m.add_child(plain)
	await _tree().physics_frame
	await _tree().physics_frame
	assert_true(plain.placed and plain.items.size() > 30, "the scattered field placed its items (%d)" % plain.items.size())
	var clustered := 0
	var scattered := 0
	var wanted := 0
	for cluster: Dictionary in loot_cfg["clusters"]:
		var landmark: Dictionary = by_id[cluster["landmark"]]
		var here := _inside(m.loot, landmark)
		assert_true(here >= int(cluster["items"]) - 1, "%s holds its cluster: %d items in its area (cluster of %d, one may find no ground)" % [cluster["landmark"], here, cluster["items"]])
		clustered += here
		scattered += _inside(plain, landmark)
		wanted += int(cluster["items"])
	assert_true(clustered >= scattered + wanted / 2, "nonvacuous: %d items at the landmarks with clusters, %d when everything is scattered" % [clustered, scattered])
	assert_true(m.loot.items.size() > 30 and m.loot.items.size() <= int(loot_cfg["count"]), "the total stays within count (%d)" % m.loot.items.size())
	for id in m.loot.items:
		assert_true(float(m.loot.items[id]["pos"].y) <= float(loot_cfg["max_ground_y_m"]) + 0.25 + 0.001, "item %d lies on low walkable ground, not on a roof or a walkway" % id)
	print("WORLD_LOOT clusters at_landmarks=", clustered, " scattered_baseline=", scattered, " placed=", m.loot.items.size())
	plain.free()
	m.queue_free()
	await _tree().process_frame


func test_without_a_zone_block_the_square_area_is_the_only_limit() -> void:
	# The capture tool and bare scenes call setup(cfg, seed) with no zone: placement is the old square.
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(160, 1, 160)
	shape.shape = slab
	ground.add_child(shape)
	ground.collision_layer = Hitscan.MASK_WORLD
	_tree().root.add_child(ground)
	ground.global_position = Vector3(0, -0.5, 0)
	var loot_cfg := _loot_cfg()
	var half := float(loot_cfg["area_half_m"])
	var square := LootField.new()
	square.setup(loot_cfg, 7)
	_tree().root.add_child(square)
	var round := LootField.new()
	round.setup(loot_cfg, 7, {"start_center": [0, 0], "start_radius_m": half})
	_tree().root.add_child(round)
	await _tree().physics_frame
	await _tree().physics_frame
	assert_true(square.placed and square.items.size() == int(loot_cfg["count"]), "bare ground takes every item")
	assert_true(_farthest(square, Vector2.ZERO) > half, "no zone block: items reach the corners of the square")
	assert_true(round.items.size() > 30 and _farthest(round, Vector2.ZERO) <= half, "zone block: the same field stays inside the circle")
	square.free()
	round.free()
	ground.free()
