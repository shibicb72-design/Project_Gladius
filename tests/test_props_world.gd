extends "res://tests/test_case.gd"
## M2 L1b: WorldProps. data/props.json and the committed 1 km cover file validate and bad entries are reported
## (problems()); the loot roll is a pure function of the match seed, the prop id and the salt (the same on every
## peer, whatever the order of breaks); a break spills its roll through LootField.drop on the authority only and
## says prop_changed; a client applies a host state without loot or prop_changed; collect finds a map's breakables;
## every match gets a WorldProps (director.props), empty on the fixture, whose maps carry no props.

const _MatchScene := preload("res://scenes/match/match.tscn")
const KM_COVER := "res://data/maps/alesia_1km_cover.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _items() -> Dictionary:
	return DataRegistry.new().load_file(MatchDirector.LOOT_PATH)["items"]


func _loot() -> LootField:
	var f := LootField.new()
	f.setup(DataRegistry.new().load_file(MatchDirector.LOOT_PATH), 7)
	f.placed = true  # no ground placement: only the props' drops
	_tree().root.add_child(f)
	return f


func _props(authority: bool, loot: LootField) -> WorldProps:
	var p := WorldProps.new()
	p.setup(WorldProps.config(), 4242, authority, loot)
	_tree().root.add_child(p)
	return p


func _crate(id: String, at := Vector3(0, 0.6, 0)) -> Breakable:
	var b := Breakable.make({"id": id, "type": "breakable_crate", "at": [at.x, at.y, at.z], "size": [1.2, 1.2, 1.2]},
			WorldProps.config()["breakables"]["breakable_crate"])
	_tree().root.add_child(b)
	return b


func test_props_json_and_the_1km_cover_file_validate() -> void:
	var cfg := WorldProps.config()
	assert_true(bool(cfg.get("_placeholder", false)) and String(cfg["_todo"]).contains("OQ-PROPS-BREAK"), "props.json is a placeholder (OQ-PROPS-BREAK)")
	assert_eq(WorldProps.problems({}, cfg), PackedStringArray(), "props.json has no problem")
	assert_true((cfg["breakables"] as Dictionary).has("breakable_crate") and (cfg["breakables"] as Dictionary).has("breakable_barrel"), "both breakable types")
	var km := DataRegistry.parse_quiet(KM_COVER)
	assert_true((km.get("breakables", []) as Array).size() > 0, "nonvacuous: the 1 km cover file has breakables")
	assert_eq(WorldProps.problems(km, cfg), PackedStringArray(), "the committed 1 km cover file's breakables validate")


func test_problems_reports_bad_entries() -> void:
	var cfg := WorldProps.config()
	var good := {"pieces": [{"id": "Cover_000"}], "ring_pieces": [{"id": "Ring_000"}],
		"breakables": [{"id": "Breakable_000", "type": "breakable_crate", "at": [1, 0.6, 2], "size": [1.2, 1.2, 1.2]}]}
	assert_eq(WorldProps.problems(good, cfg), PackedStringArray(), "a good file passes")
	var cases := {
		"unknown type": {"breakables": [{"id": "B", "type": "breakable_sofa", "at": [0, 0, 0], "size": [1, 1, 1]}]},
		"duplicate id": {"pieces": [{"id": "X"}], "breakables": [{"id": "X", "type": "breakable_crate", "at": [0, 0, 0], "size": [1, 1, 1]}]},
		"bad size": {"breakables": [{"id": "B", "type": "breakable_crate", "at": [0, 0, 0], "size": [1, 0, 1]}]},
		"bad at": {"breakables": [{"id": "B", "type": "breakable_crate", "at": [0, 0], "size": [1, 1, 1]}]},
		"not a list": {"breakables": {}},
	}
	for what: String in cases:
		assert_true(not WorldProps.problems(cases[what], cfg).is_empty(), what + " is reported")
	var bad_cfg := cfg.duplicate(true)
	bad_cfg["breakables"]["breakable_crate"]["health"] = 0
	bad_cfg["breakables"]["breakable_barrel"]["loot"]["count_min"] = 5
	var lines := WorldProps.problems({}, bad_cfg)
	assert_true(lines.size() >= 2, "health 0 and count_min > count_max are reported: %s" % ", ".join(lines))


func test_loot_roll_is_seeded_by_seed_and_id_only() -> void:
	var items := _items()
	var roll := {"count_min": 1, "count_max": 3, "item_kinds": []}
	var a := WorldProps.loot_roll(items, roll, 11, "Breakable_003", "break")
	assert_eq(WorldProps.loot_roll(items, roll, 11, "Breakable_003", "break"), a, "same seed and id: same items")
	assert_true(a.size() >= 1 and a.size() <= 3, "count within the range: %d" % a.size())
	for i in 5:  # order independence: rolling other props first changes nothing
		WorldProps.loot_roll(items, roll, 11, "Breakable_%03d" % i, "break")
	assert_eq(WorldProps.loot_roll(items, roll, 11, "Breakable_003", "break"), a, "other rolls first: same items")
	var differ := 0
	for i in 20:
		if WorldProps.loot_roll(items, roll, 12 + i, "Breakable_003", "break") != a:
			differ += 1
	assert_true(differ > 0, "nonvacuous: other seeds give other items")
	var ammo := WorldProps.loot_roll(items, {"count_min": 4, "count_max": 4, "item_kinds": ["ammo"]}, 11, "Breakable_001", "break")
	assert_eq(ammo.size(), 4, "a fixed count")
	for id: String in ammo:
		assert_eq(String(items[id]["kind"]), "ammo", "item_kinds limits the table")
	assert_eq(WorldProps.loot_roll(items, {"count_min": 0, "count_max": 0}, 11, "B", "break").size(), 0, "a roll of 0 items")


func test_spill_points_ring_the_centre() -> void:
	var pts := WorldProps.spill_points(Vector3(1, 2, 3), 4, 1.5, 0.0)
	assert_eq(pts.size(), 4, "one point per item")
	for p: Vector3 in pts:
		assert_true(is_equal_approx(Vector2(p.x - 1, p.z - 3).length(), 1.5) and p.y == 2.0, "on the ring at the centre's height")
	assert_true(pts[0].is_equal_approx(Vector3(1, 2, 1.5)), "the first in front (-z) at yaw 0")
	assert_eq(WorldProps.spill_points(Vector3(1, 2, 3), 2, 0.0, 0.0), [Vector3(1, 2, 3), Vector3(1, 2, 3)] as Array[Vector3], "radius 0: at the centre")


func test_break_spills_on_the_authority_and_announces() -> void:
	var loot := _loot()
	var props := _props(true, loot)
	# A roll that drops something for this seed: force one item so the spill is nonvacuous.
	props.cfg = WorldProps.config().duplicate(true)
	props.cfg["breakables"]["breakable_crate"]["loot"] = {"count_min": 2, "count_max": 2, "item_kinds": []}
	var b := _crate("Breakable_910", Vector3(4, 0.6, 5))
	props.register_breakable(b)
	var changes: Array = []
	props.prop_changed.connect(func(id: String, s: int) -> void: changes.append([id, s]))
	var want := WorldProps.loot_roll(loot.cfg["items"], props.cfg["breakables"]["breakable_crate"]["loot"], 4242, "Breakable_910", "break")
	b.take_hit(b.health)
	assert_eq(props.state_of("Breakable_910"), WorldProps.BROKEN, "the state is BROKEN")
	assert_eq(changes, [["Breakable_910", WorldProps.BROKEN]], "prop_changed once")
	assert_eq(props.spilled.size(), 2, "the seeded roll is spilled")
	for i in props.spilled.size():
		var item: Dictionary = loot.items[props.spilled[i]]
		assert_eq(String(item["item_id"]), want[i], "item %d is the roll's" % i)
		assert_true((item["pos"] as Vector3).is_equal_approx(Vector3(4, 0.25, 5)), "item %d on the ground under the crate" % i)
	await _tree().process_frame
	props.queue_free()
	loot.queue_free()


func test_a_client_applies_states_without_loot() -> void:
	var loot := _loot()
	var props := _props(false, loot)
	var b := _crate("Breakable_911")
	props.register_breakable(b)
	var changes: Array = []
	props.prop_changed.connect(func(id: String, _s: int) -> void: changes.append(id))
	props.apply_state("Breakable_911", WorldProps.BROKEN)
	props.apply_state("Nope", WorldProps.BROKEN)
	assert_true(b.is_broken, "the host's state is applied")
	assert_eq(props.state_of("Breakable_911"), WorldProps.BROKEN, "state kept")
	assert_true(props.spilled.is_empty() and loot.items.is_empty(), "no loot on a client")
	assert_true(changes.is_empty(), "no prop_changed on a client")
	props.apply_state("Breakable_911", WorldProps.BROKEN)
	assert_true(props.spilled.is_empty(), "applying twice does nothing")
	await _tree().process_frame
	assert_true(not is_instance_valid(b) or not b.is_inside_tree(), "the broken body left the world")
	props.queue_free()
	loot.queue_free()


func test_collect_finds_breakables_under_a_map() -> void:
	var map := Node3D.new()
	var props_node := Node3D.new()
	props_node.add_child(Breakable.make({"id": "Breakable_920", "type": "breakable_crate", "at": [0, 0.6, 0], "size": [1, 1, 1]}, WorldProps.config()["breakables"]["breakable_crate"]))
	map.add_child(props_node)
	var plain := StaticBody3D.new()
	map.add_child(plain)
	var p := WorldProps.new()
	p.setup(WorldProps.config(), 1, true)
	p.collect(map)
	assert_eq(p.breakables.keys(), ["Breakable_920"], "only the breakable")
	p.free()
	map.free()


func test_every_match_has_world_props_and_the_fixtures_have_none() -> void:
	for path: String in ["res://data/maps/alesia_cover.json", "res://data/maps/test_300_cover.json"]:
		assert_true(not DataRegistry.parse_quiet(path).has("breakables"), path + ": no breakables")
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	m.seed_override = 777
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	assert_true(m.begin(), "the fixture match begins")
	assert_true(m.world_props != null and m.world_props.is_inside_tree(), "the match has its WorldProps")
	assert_true(m.director.props == m.world_props, "director.props is it")
	assert_true(m.world_props.authority, "offline is the authority")
	assert_eq(m.world_props.match_seed, 777, "seeded from the match seed")
	assert_true(m.world_props.breakables.is_empty(), "no breakables on the fixture")
	assert_true(m.map.get_node_or_null("ArtBuilder/Props") == null, "no Props node on the fixture")
	assert_eq(_tree().get_nodes_in_group(Breakable.GROUP).size(), 0, "no breakable in the tree")
	m.queue_free()
	await _tree().process_frame
