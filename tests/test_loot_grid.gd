extends "res://tests/test_case.gd"
## M2P1C stop 6: LootField.nearest and BotBrain._loot_goal through the loot grid give exactly the old
## whole-`items` loops' results. _old_nearest and _old_loot_goal below are the pre-stop-6 loops copied
## verbatim (scripts/systems/loot_field.gd nearest, scripts/systems/bot_brain.gd _loot_goal) as references.

const _MatchScene := preload("res://scenes/match/match.tscn")
const KINDS := ["ammo", "armor_1", "armor_2", "armor_3", "pilum_br", "sagittarii_rifle"]

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


## The pre-stop-6 LootField.nearest, verbatim except `items` -> `f.items`.
func _old_nearest(f: LootField, pos: Vector3, range_m: float, accept: Callable = Callable()) -> int:
	var best := -1
	var best_d := INF
	for id in f.items:
		var p: Vector3 = f.items[id]["pos"]
		if absf(p.y - pos.y) > 2.0:
			continue
		if accept.is_valid() and not bool(accept.call(str(f.items[id]["item_id"]))):
			continue
		var d := Vector2(p.x - pos.x, p.z - pos.z).length()
		if d <= range_m and d < best_d:
			best = id
			best_d = d
	return best


## The pre-stop-6 BotBrain._loot_goal, verbatim except the brain's members reached through `b`.
func _old_loot_goal(b: BotBrain, guns_only: bool = false) -> Vector3:
	var loot := b.director.loot
	if loot == null:
		return Vector3.INF
	var range_m := float(b.cfg.get("loot_seek_range_m", 45.0))
	var best := Vector3.INF
	var best_score := INF
	var want_gun := b._melee_only()
	for id in loot.items:
		var entry: Dictionary = loot.items[id]
		var item_def := loot.def(str(entry["item_id"]))
		if not b.pawn.wants_item(item_def, b.director.bot_ammo_low_magazines(), b.director.bot_heal_below_pct()) or (guns_only and str(item_def.get("kind", "")) != "weapon"):
			continue
		var pos: Vector3 = entry["pos"]
		var d := Vector2(pos.x - b.pawn.global_position.x, pos.z - b.pawn.global_position.z).length()
		if d > range_m:
			continue
		var score := d * (0.5 if want_gun and str(item_def.get("kind", "")) == "weapon" else 1.0)
		if score < best_score:
			best_score = score
			best = pos
	return best


func _field() -> LootField:
	var f := LootField.new()
	f.setup(DataRegistry.new().load_file("res://data/loot.json"), 7)
	f.placed = true  # no physics placement: the tests add the items
	tree().root.add_child(f)
	return f


## Adds an item through drop (the public add path; it raises y by 0.25).
func _put(f: LootField, rng: RandomNumberGenerator, pos: Vector3) -> int:
	return f.drop({"item_id": KINDS[rng.randi_range(0, KINDS.size() - 1)]}, pos)


func _rand_pos(rng: RandomNumberGenerator, half: float) -> Vector3:
	return Vector3(rng.randf_range(-half, half), rng.randf_range(-0.5, 2.5), rng.randf_range(-half, half))


## A query point: random, on an item, or on a grid-cell corner (cell borders), at varied heights.
func _query_pos(f: LootField, rng: RandomNumberGenerator, half: float) -> Vector3:
	match rng.randi_range(0, 3):
		0:
			if not f.items.is_empty():
				var ids := f.items.keys()
				var p: Vector3 = f.items[ids[rng.randi_range(0, ids.size() - 1)]]["pos"]
				return p + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-2.5, 2.5), rng.randf_range(-3.0, 3.0))
		1:
			var cell := float(DataRegistry.new().load_file("res://data/map_build.json")["spatial_index"]["loot_cell_m"])
			return Vector3(cell * rng.randi_range(-4, 4), rng.randf_range(-0.5, 2.5), cell * rng.randi_range(-4, 4))
	return _rand_pos(rng, half)


const RANGES := [0.0, 0.5, 2.0, 5.0, 19.99, 20.0, 45.0, 120.0, 1000.0, INF, -1.0]


## Compares new vs old for `n` seeded queries; returns [queries, found, mismatches].
func _compare(f: LootField, rng: RandomNumberGenerator, n: int, half: float, label: String) -> Array:
	var found := 0
	var bad := 0
	var no_ammo := func(item_id: String) -> bool: return item_id != "ammo"
	for q in n:
		var pos := _query_pos(f, rng, half)
		var r: float = RANGES[q % RANGES.size()]
		var accept: Callable = no_ammo if q % 3 == 0 else Callable()
		var a := f.nearest(pos, r, accept)
		var b := _old_nearest(f, pos, r, accept)
		if b >= 0:
			found += 1
		if a != b:
			bad += 1
			if bad <= 5:
				failures.append("%s: nearest(%s, %s) new %d old %d" % [label, pos, r, a, b])
	return [n, found, bad]


func test_nearest_equals_the_old_loop_seeded_with_ties_and_take_drop() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var f := _field()
	var half := 90.0
	for i in 300:
		_put(f, rng, _rand_pos(rng, half))
	# Ties: identical positions (several items on one spot), and items at equal distance from a point
	# (a ring around it), some on cell borders.
	for s in 12:
		var spot := _rand_pos(rng, half) if s % 2 == 0 else Vector3(20.0 * rng.randi_range(-3, 3), 0.0, 20.0 * rng.randi_range(-3, 3))
		for k in rng.randi_range(2, 5):
			_put(f, rng, spot)
		for k in 6:
			var a := TAU * k / 6.0
			_put(f, rng, spot + Vector3(cos(a) * 1.5, 0.0, sin(a) * 1.5))
		for k in 4:  # exact axis offsets: equal float distances
			_put(f, rng, spot + [Vector3(3, 0, 0), Vector3(-3, 0, 0), Vector3(0, 0, 3), Vector3(0, 0, -3)][k])
	var totals := [0, 0, 0]
	var ties := 0
	for round_i in 40:
		var res := _compare(f, rng, 150, half, "round %d" % round_i)
		for j in 3:
			totals[j] += res[j]
		# Tie queries exactly on a spot: several items at distance 0 or equal distances.
		for id in f.items.keys().slice(0, 20):
			var p: Vector3 = f.items[id]["pos"]
			for r: float in [0.0, 1.5, 3.0, 3.5]:
				var a := f.nearest(p, r)
				var b := _old_nearest(f, p, r)
				totals[0] += 1
				ties += 1
				if a != b:
					totals[2] += 1
					if totals[2] <= 5:
						failures.append("tie at %s r %s: new %d old %d" % [p, r, a, b])
		# Interleaved take and drop: take some (nearest ones and random ones), drop some back elsewhere.
		var ids := f.items.keys()
		for t in 8:
			var id: int = ids[rng.randi_range(0, ids.size() - 1)]
			var item := f.take(id)
			if not item.is_empty() and t % 2 == 0:
				f.drop(item, _rand_pos(rng, half))
		var near := f.nearest(_query_pos(f, rng, half), 45.0)
		if near >= 0:
			f.take(near)
		for t in 6:
			_put(f, rng, _rand_pos(rng, half))
		f.take(-5)  # unknown id: no-op
	# Every query after the last change too, and a field emptied entirely.
	var res2 := _compare(f, rng, 300, half, "final")
	for j in 3:
		totals[j] += res2[j]
	for id in f.items.keys():
		f.take(id)
	assert_eq(f.nearest(Vector3.ZERO, INF), -1, "an emptied field finds nothing")
	assert_eq(f.items_near(Vector3.ZERO, 1000.0).size(), 0, "an emptied grid holds nothing")
	_put(f, rng, Vector3(1, 0, 1))
	assert_eq(f.nearest(Vector3(1, 0.25, 1), 2.0), _old_nearest(f, Vector3(1, 0.25, 1), 2.0), "refilled after emptying")
	print("LOOT_GRID seeded queries=%d found=%d tie_queries=%d mismatches=%d" % [totals[0], totals[1], ties, totals[2]])
	assert_true(totals[0] > 6000 and totals[1] > 2000, "nonvacuous (%d queries, %d found)" % [totals[0], totals[1]])
	assert_eq(totals[2], 0, "every query equals the old loop")
	f.free()


## The first inserted of equally near items wins, also when a later-inserted item is in an earlier cell
## or the earlier one lies in a far cell of the query's reach.
func test_tie_break_is_insertion_order_across_cells() -> void:
	var f := _field()
	var a := f.drop({"item_id": "ammo"}, Vector3(25.0, 0.0, 0.0))  # cell (1, 0)
	var b := f.drop({"item_id": "ammo"}, Vector3(15.0, 0.0, 0.0))  # cell (0, 0), inserted later
	assert_eq(f.nearest(Vector3(20.0, 0.25, 0.0), 10.0), a, "equal distance 5: the first inserted (a) wins")
	assert_eq(_old_nearest(f, Vector3(20.0, 0.25, 0.0), 10.0), a, "the old loop agrees")
	f.take(a)
	var c := f.drop({"item_id": "ammo"}, Vector3(25.0, 0.0, 0.0))
	assert_eq(f.nearest(Vector3(20.0, 0.25, 0.0), 10.0), b, "after a's take, b is first among the equals")
	assert_true(c > b, "a dropped item gets a later id")
	var order := f.items_near(Vector3(20.0, 0.25, 0.0), 10.0)
	assert_eq(order, f.items.keys(), "items_near lists ids in `items` order")
	f.free()


## A real match's ground loot (as tests/test_br_loot.gd builds it): nearest from around every item and
## from every pawn, with the director's accept filter, equals the old loop; so do the bots' loot goals.
func test_real_match_loot_and_bot_goals_equal_the_old_loops() -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 31337
	m.ground_loot = true
	tree().root.add_child(m)
	await tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	assert_true(m.begin(), "match begins")
	var brains: Array = []
	for bot in m.bots:
		var brain := bot.get_node_or_null("Brain") as BotBrain
		if brain != null:
			brain.set_physics_process(false)
			brains.append(brain)
	for i in 3:
		await tree().physics_frame
		await tree().process_frame
	var f := m.loot
	assert_true(f.placed and f.items.size() > 30, "the match placed its ground loot (%d items)" % f.items.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	var res := _compare(f, rng, 3000, 80.0, "match")
	var bad: int = res[2]
	var found: int = res[1]
	var queries: int = res[0]
	for id in f.items.keys():
		var p: Vector3 = f.items[id]["pos"]
		for r: float in [2.0, 45.0]:
			queries += 1
			var a := f.nearest(p, r)
			if a >= 0:
				found += 1
			if a != _old_nearest(f, p, r):
				bad += 1
	# Every bot's loot goal (both modes), the bot moved onto items or anywhere.
	var goals := 0
	var goals_found := 0
	var goal_bad := 0
	for k in 120:
		var bot: Pawn = m.bots[k % m.bots.size()]
		var item_ids := f.items.keys()
		var p: Vector3 = f.items[item_ids[k % item_ids.size()]]["pos"] if k % 2 == 0 else _rand_pos(rng, 70.0)
		bot.global_position = Vector3(p.x + rng.randf_range(-1.5, 1.5), p.y - 0.25, p.z + rng.randf_range(-1.5, 1.5))
		for brain: BotBrain in brains:
			if brain.pawn != bot:
				continue
			for guns_only: bool in [false, true]:
				var g_new: Vector3 = brain._loot_goal(guns_only)
				var g_old := _old_loot_goal(brain, guns_only)
				goals += 1
				if g_old != Vector3.INF:
					goals_found += 1
				if g_new != g_old:
					goal_bad += 1
					if goal_bad <= 5:
						failures.append("loot goal at %s guns_only %s: new %s old %s" % [bot.global_position, guns_only, g_new, g_old])
		# Take/drop interleaved on the real field.
		if k % 10 == 9:
			var near := f.nearest(bot.global_position, 45.0)
			if near >= 0:
				var item := f.take(near)
				f.drop(item, _rand_pos(rng, 60.0))
	print("LOOT_GRID match items=%d queries=%d found=%d mismatches=%d goals=%d goals_found=%d goal_mismatches=%d" % [f.items.size(), queries, found, bad, goals, goals_found, goal_bad])
	assert_true(found > 300 and goals > 100 and goals_found > 40, "nonvacuous (%d found, %d goals, %d with a goal)" % [found, goals, goals_found])
	assert_eq(bad, 0, "every match query equals the old loop")
	assert_eq(goal_bad, 0, "every bot loot goal equals the old loop")
	m.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile


## Report only: microseconds per nearest() query, old loop vs grid, at the real match's item count and at
## 10x (same density over a sqrt(10) wider square, as on a bigger map), pickup range and bot seek range.
func test_loot_time_proxy() -> void:
	var count := int(DataRegistry.new().load_file("res://data/loot.json")["count"])
	for scale: int in [1, 10]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 5150 + scale
		var f := _field()
		var half := 72.0 * sqrt(float(scale))
		for i in count * scale:
			_put(f, rng, Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half)))
		var points: Array = []
		for i in 500:
			points.append(Vector3(rng.randf_range(-half, half), 0.25, rng.randf_range(-half, half)))
		for r: float in [2.0, 45.0]:
			var olds: Array = []
			var news: Array = []
			for run in 7:
				var t0 := Time.get_ticks_usec()
				for p: Vector3 in points:
					_old_nearest(f, p, r)
				var t1 := Time.get_ticks_usec()
				for p: Vector3 in points:
					f.nearest(p, r)
				var t2 := Time.get_ticks_usec()
				olds.append(float(t1 - t0) / points.size())
				news.append(float(t2 - t1) / points.size())
			olds.sort()
			news.sort()
			print("LOOT_TIME items=%d range_m=%.0f old_us=%.2f grid_us=%.2f (median of 7, %d queries)" % [f.items.size(), r, olds[3], news[3], points.size()])
		f.free()
	assert_true(true)
