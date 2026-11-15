extends "res://tests/test_case.gd"
## M2L1 stage B (binding fixes 3, 4, 21, 22, 23): per-map gameplay overrides and loot on the hill, at the config
## level and on the small maps (no 1 km build here; the 1 km scene checks live in tests/test_alesia_1km.gd).
## A map json's "overrides" {"br", "loot"} are deep-merged over data/br.json and data/loot.json at config load
## (MatchDirector.load_config(map)), once: a config the caller loaded and edited before begin() is kept. Maps
## without overrides (alesia_section, test_300) get the plain files and the same loot as before.

const _MatchScene := preload("res://scenes/match/match.tscn")
const ALESIA := "res://data/maps/alesia_section.json"
const TEST_300 := "res://data/maps/test_300.json"
const BIG := "res://data/maps/alesia_1km.json"
## A temporary copy of alesia with a small overrides block: it must sit in res://data/maps/ (validate_map), so
## it is removed at the end of its test.
const TMP_MAP := "res://data/maps/_overrides_test_tmp.json"
## The edge of a shrinking zone may move at most this fast (m/s) on alesia_1km (its overrides' _todo note).
const EDGE_MPS := 4.0
## M2 Z1 drop rule on alesia_1km (OQ-BR-DROP, guesses for Shibi): a dropping soldier can glide at least this far
## sideways (m), and the carrier flies no higher than DROP_MAX_ALT_M.
const DROP_REACH_M := 120.0
const DROP_MAX_ALT_M := 200.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## {"br": mode config, "loot": loot config} as MatchDirector.load_config(map_json) leaves them.
func _cfg(map_json: String = "") -> Dictionary:
	var d := MatchDirector.new()
	d.load_config(map_json)
	var out := {"br": d.mode_cfg, "loot": d.loot_cfg}
	d.free()
	return out


func test_merge_semantics() -> void:
	var base := {"a": 1, "d": {"x": 1, "y": [1, 2], "n": {"k": 1}}, "arr": [1, 2, 3], "_note": "base note"}
	var over := {"a": 2, "d": {"y": [9], "n": {"j": 2}, "_n": "a note"}, "arr": [7], "new": {"z": 1, "_q": 1}, "_note": "skipped"}
	var base_before := base.duplicate(true)
	var over_before := over.duplicate(true)
	var out := MatchDirector.merge_overrides(base, over)
	assert_eq(out, {"a": 2, "d": {"x": 1, "y": [9], "n": {"k": 1, "j": 2}}, "arr": [7], "new": {"z": 1}, "_note": "base note"},
			"dictionaries merge by key, arrays and scalars replace, _ keys are not merged")
	assert_eq(base, base_before, "the base is unchanged")
	assert_eq(over, over_before, "the overrides are unchanged")
	(out["d"]["y"] as Array).append(5)
	(out["d"]["n"] as Dictionary)["k"] = 3
	assert_eq(over["d"]["y"], [9], "the result shares no array with the overrides")
	assert_eq(base["d"]["n"]["k"], 1, "the result shares no dictionary with the base")
	assert_eq(MatchDirector.merge_overrides(base, {}), base, "no overrides: a copy of the base")
	assert_eq(MatchDirector.merge_overrides(base, "not a dictionary"), base, "a non-dictionary is ignored")
	assert_eq(MatchDirector.map_overrides(ALESIA), {}, "alesia_section has no overrides")
	assert_eq(MatchDirector.map_overrides("res://data/maps/nope.json"), {}, "a missing map has none")


func test_flat_maps_get_the_plain_files() -> void:
	var plain := _cfg()
	assert_eq(plain["br"], ModeRegistry.merged_config(MatchDirector.MODE_ID, DataRegistry.new().load_file("res://data/modes.json")), "no map: the br config is the plain merged mode config")
	assert_eq(plain["loot"], DataRegistry.new().load_file("res://data/loot.json"), "no map: the loot config is loot.json")
	for map_path: String in [ALESIA, TEST_300]:
		assert_true(not DataRegistry.parse_quiet(map_path).has("overrides"), map_path + " has no overrides block")
		var cfg := _cfg(map_path)
		assert_eq(cfg["br"], plain["br"], map_path + ": br config equals the plain file")
		assert_eq(cfg["loot"], plain["loot"], map_path + ": loot config equals the plain file")


func test_alesia_1km_overrides_follow_the_rules() -> void:
	var plain := _cfg()
	var big := _cfg(BIG)
	var over: Dictionary = MatchDirector.map_overrides(BIG)
	for block: Array in [[over["br"]["zone"], "OQ-BR-ZONE"], [over["br"]["drop"], "OQ-BR-DROP"], [over["loot"], "OQ-BR-LOOT"]]:
		var b: Dictionary = block[0]
		assert_true(bool(b.get("_placeholder", false)) and String(b.get("_todo", "")).contains(String(block[1])) and String(b["_todo"]).contains("guess"), "%s: a placeholder, labelled a guess" % block[1])
	# Zone: covers the play circle; the phases follow tools/gen_zone.gd's rules for the map's "zone_gen" inputs
	# (tests/test_zone_gen.gd checks they are exactly the tool's output).
	var zone: Dictionary = big["br"]["zone"]
	var base: Dictionary = plain["br"]["zone"]
	var def := DataRegistry.parse_quiet(BIG)
	var play := float(def["play_radius_m"])
	var zg: Dictionary = def["zone_gen"]
	var min_shrink := float(zg["min_shrink_s"])
	assert_eq(float(zone["start_radius_m"]), play, "the zone starts on the play circle")
	assert_eq(zone["start_center"], base["start_center"], "the zone starts at the centre")
	assert_eq((zone["phases"] as Array).size(), (zg["phases"] as Array).size(), "one phase per zone_gen entry")
	assert_eq(float(zg["edge_speed_cap_mps"]), EDGE_MPS, "the edge cap is zone_gen's")
	var prev := float(zone["start_radius_m"])
	var prev_damage := -INF
	var nominal := 0.0
	for i in (zone["phases"] as Array).size():
		var ph: Dictionary = zone["phases"][i]
		for key: String in ["wait_s", "shrink_s"]:
			assert_true(float(ph[key]) > 0.0 and float(ph[key]) == floorf(float(ph[key])), "phase %d %s is a whole number of seconds (%s)" % [i, key, ph[key]])
		assert_true(float(ph["radius_m"]) < prev, "phase %d circle is strictly smaller than the one before (with the centre move limit, inside it)" % i)
		assert_true(float(ph["damage_per_s"]) > prev_damage, "phase %d damage is higher than the one before" % i)
		assert_true(float(ph["shrink_s"]) >= min_shrink, "phase %d shrink is at least zone_gen.min_shrink_s" % i)
		var edge := 2.0 * (prev - float(ph["radius_m"])) / float(ph["shrink_s"])
		assert_true(edge <= EDGE_MPS + 0.001, "phase %d: the edge moves at most %.1f m/s (%.2f)" % [i, EDGE_MPS, edge])
		# Only as slow as needed: one second less would break the cap, or the shrink is the minimum.
		assert_true(float(ph["shrink_s"]) == min_shrink or 2.0 * (prev - float(ph["radius_m"])) / (float(ph["shrink_s"]) - 1.0) > EDGE_MPS, "phase %d shrink is the shortest the cap allows" % i)
		nominal += float(ph["wait_s"]) + float(ph["shrink_s"])
		prev = float(ph["radius_m"])
		prev_damage = float(ph["damage_per_s"])
	assert_eq(prev, 0.0, "the last phase ends at radius 0")
	# The reach rule, with the merged drop: the last forced drop lands, then runs across to the first circle
	# (2 x (play radius - first radius) at zone_gen.run_speed_mps) before the first shrink ends.
	var merged_drop: Dictionary = big["br"]["drop"]
	var first: Dictionary = zone["phases"][0]
	var t_land := float(merged_drop["carrier_s"]) + float(merged_drop["altitude_m"]) / float(merged_drop["max_fall_mps"])
	var reach_s := t_land + 2.0 * (play - float(first["radius_m"])) / float(zg["run_speed_mps"])
	assert_true(reach_s <= float(first["wait_s"]) + float(first["shrink_s"]), "the last lander can reach the first circle before its shrink ends (%.1f s <= %d s)" % [reach_s, int(float(first["wait_s"]) + float(first["shrink_s"]))])
	var rules := ModeRegistry.create(MatchDirector.MODE_ID, {MatchDirector.MODE_ID: big["br"]}) as BrRules
	assert_true(rules != null and rules.config_problems().is_empty(), "BrRules accepts the merged 1 km config")
	# Nested for real: on a few seeds every seeded target circle lies inside the one before.
	for seed_value in (20 if rules != null else 0):
		rules.set_seed(seed_value)
		var outer_c := Vector2(float(zone["start_center"][0]), float(zone["start_center"][1]))
		var outer_r := play
		for circle: Dictionary in rules.get("_circles"):
			var c: Vector2 = circle["center"]
			assert_true(c.distance_to(outer_c) + float(circle["radius"]) <= outer_r + 0.001, "seed %d: each zone circle lies inside the one before" % seed_value)
			outer_c = c
			outer_r = float(circle["radius"])
	for key: String in ["teams", "downed", "end", "default_seed"]:
		assert_eq(big["br"][key], plain["br"][key], key + " is br.json's")
	# Drop (M2 Z1): crosses the play circle; a falling soldier can glide at least DROP_REACH_M sideways
	# (altitude / max fall speed x glide speed, the simple rule; the real fall is a little longer, see
	# test_measured_drop_reach), from no higher than DROP_MAX_ALT_M. "enabled" and the bot jump window stay br.json's.
	var drop: Dictionary = big["br"]["drop"]
	for key: String in ["enabled", "bot_jump_window"]:
		assert_eq(drop[key], plain["br"]["drop"][key], "drop " + key + " is br.json's")
	var side_reach := float(drop["altitude_m"]) / float(drop["max_fall_mps"]) * float(drop["glide_speed_mps"])
	assert_true(side_reach >= DROP_REACH_M, "the side reach is at least %.0f m (%.1f m)" % [DROP_REACH_M, side_reach])
	assert_true(float(drop["altitude_m"]) <= DROP_MAX_ALT_M, "the carrier flies at most %.0f m up (%.0f m)" % [DROP_MAX_ALT_M, float(drop["altitude_m"])])
	assert_true(float(drop["path_length_m"]) >= 2.0 * play, "the carrier line spans the play circle")
	assert_true(float(drop["map_half_m"]) >= play and float(drop["map_half_m"]) < 500.0, "the drop clamp holds the play circle, inside the 1000 m ground")
	var fall_s := float(drop["altitude_m"]) / float(drop["max_fall_mps"])
	assert_true(float(drop["carrier_s"]) + fall_s < float(zone["phases"][0]["wait_s"]), "the last forced drop lands before the first shrink")
	# Loot: the area covers the circle, clusters at the map's own landmarks, the rest is loot.json's.
	var loot: Dictionary = big["loot"]
	assert_true(float(loot["area_half_m"]) >= play, "the loot area covers the zone start circle")
	var ids := {}
	for landmark: Dictionary in DataRegistry.parse_quiet(String(DataRegistry.parse_quiet(BIG)["landmarks"]))["landmarks"]:
		ids[landmark["id"]] = true
	var clustered := 0
	for cluster: Dictionary in loot["clusters"]:
		assert_true(ids.has(cluster["landmark"]), "cluster landmark %s is one of the map's" % cluster["landmark"])
		ids.erase(cluster["landmark"])
		clustered += int(cluster["items"])
	assert_true(ids.is_empty(), "every landmark gets a cluster (left: %s)" % [ids.keys()])
	assert_true(clustered < int(loot["count"]), "clusters take part of the count")
	# M2Z1 (binding fix 13): the first-tick placement cost grows with the count, so it is capped.
	assert_true(int(loot["count"]) <= 900, "the loot count is at most 900 (%d)" % int(loot["count"]))
	for key: String in ["max_ground_y_m", "zone_edge_margin_m", "items", "start_kit", "pickup_range_m", "colors"]:
		assert_eq(loot[key], plain["loot"][key], "loot " + key + " is loot.json's")
	print("MAP_OVERRIDES alesia_1km zone_nominal_s=", nominal, " carrier_s=", drop["carrier_s"], " loot_count=", loot["count"], " clustered=", clustered)


## M2 Z1: one real pawn falls the 1 km map's drop (its merged altitude, glide and fall speeds) onto a flat test
## floor, gliding straight at full stick. Its sideways travel matches the real fall (it starts at 0 m/s and
## speeds up at the movement gravity to max_fall_mps: t = altitude / max_fall + max_fall / (2 g)) within 2 m, and
## is at least DROP_REACH_M. On the small alesia map with a floor above every building, so nothing is in the way.
func test_measured_drop_reach() -> void:
	var drop: Dictionary = _cfg(BIG)["br"]["drop"]
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 777
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	assert_true(m.begin(), "begin")
	var floor_y := 100.0
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600.0, 2.0, 600.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, floor_y - 1.0, 0.0)
	m.add_child(floor_body)
	var bot: Pawn = m.bots[0]
	bot.get_node("Brain").set_physics_process(false)
	bot.drop_glide_mps = float(drop["glide_speed_mps"])
	bot.drop_max_fall_mps = float(drop["max_fall_mps"])
	await _tree().physics_frame
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)  # straight ahead, full stick
	bot.set_frame(f)
	var start := Vector3(0.0, floor_y + float(drop["altitude_m"]), 0.0)
	bot.start_fall(start)
	var frames := 0
	while bot.drop_state == Pawn.Drop.FALLING and frames < 3000:
		await _tree().physics_frame
		frames += 1
	assert_eq(bot.drop_state, Pawn.Drop.NONE, "the pawn landed")
	var fallen_s := frames / float(Engine.physics_ticks_per_second)
	var travel := Vector2(bot.global_position.x - start.x, bot.global_position.z - start.z).length()
	var g := float(bot._movement.get("gravity", 20.0))
	var v := float(drop["max_fall_mps"])
	var h := start.y - bot.global_position.y
	var t_real := h / v + v / (2.0 * g)
	var expect := float(drop["glide_speed_mps"]) * t_real
	assert_true(absf(fallen_s - t_real) < 0.15, "the fall takes altitude / max_fall + max_fall / 2g (%.2f s, measured %.2f s)" % [t_real, fallen_s])
	assert_true(absf(travel - expect) < 2.0, "the sideways travel is glide x fall time (%.1f m, measured %.1f m)" % [expect, travel])
	assert_true(travel >= DROP_REACH_M, "the measured side reach is at least %.0f m (%.1f m)" % [DROP_REACH_M, travel])
	print("MAP_OVERRIDES measured_drop alesia_1km fall_s=%.2f formula_s=%.2f simple_s=%.2f reach_m=%.1f formula_m=%.1f simple_m=%.1f" % [fallen_s, t_real,
			float(drop["altitude_m"]) / v, travel, expect, float(drop["altitude_m"]) / v * float(drop["glide_speed_mps"])])
	m.queue_free()
	await _tree().process_frame


func test_overrides_may_not_touch_what_the_lobby_reads() -> void:
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(BIG).size(), 0, "alesia_1km validates: " + ", ".join(reg.validate_map(BIG)))
	assert_eq(DataRegistry.overrides_problems({}).size(), 0, "no block, no problem")
	assert_eq(DataRegistry.overrides_problems({"overrides": {"_note": "x", "br": {"zone": {}}, "loot": {"count": 1}}}).size(), 0, "br, loot and notes are fine")
	var cases := {
		"teams": {"overrides": {"br": {"teams": {"squad_size_max": 4}}}},
		"not one of": {"overrides": {"stats": {}}},
		"'br' must be a dictionary": {"overrides": {"br": [1]}},
		"overrides must be a dictionary": {"overrides": "zone"},
	}
	for text: String in cases:
		var problems := DataRegistry.overrides_problems(cases[text])
		assert_true(problems.size() == 1 and problems[0].contains(text), "rejected (%s): %s" % [text, problems])
	# Wired into the map validation (MatchRoot falls back from such a map).
	var def := DataRegistry.parse_quiet(BIG)
	def["overrides"]["br"]["teams"] = {"mode": {"value": "squads"}}
	var problems := DataRegistry.validate_map_def(def)
	assert_true(problems.size() == 1 and problems[0].contains("teams"), "validate_map_def rejects a teams override: %s" % [problems])
	assert_true(DataRegistry.LOBBY_BR_KEYS.has("teams"), "teams is a lobby key")


## The sim's order (tests/sim/test_sim_bot_match.gd :21-27): load_config, then scale. On alesia_1km the scaled
## values are the map's overrides times 0.4 and carrier_s 8.
func test_scaled_sim_values_survive_on_alesia_1km() -> void:
	var over: Dictionary = MatchDirector.map_overrides(BIG)
	var d := MatchDirector.new()
	d.load_config(BIG)
	var z: Dictionary = d.mode_cfg["zone"]
	for ph in z["phases"]:
		ph["wait_s"] = float(ph["wait_s"]) * 0.4
		ph["shrink_s"] = float(ph["shrink_s"]) * 0.4
	d.mode_cfg["drop"]["carrier_s"] = 8.0
	for i in (z["phases"] as Array).size():
		assert_eq(float(d.mode_cfg["zone"]["phases"][i]["shrink_s"]), float(over["br"]["zone"]["phases"][i]["shrink_s"]) * 0.4, "phase %d shrink scaled from the override" % i)
		assert_eq(float(d.mode_cfg["zone"]["phases"][i]["wait_s"]), float(over["br"]["zone"]["phases"][i]["wait_s"]) * 0.4, "phase %d wait scaled" % i)
	assert_eq(float(d.mode_cfg["drop"]["carrier_s"]), 8.0, "carrier_s is the sim's")
	assert_eq(float(d.mode_cfg["zone"]["start_radius_m"]), float(over["br"]["zone"]["start_radius_m"]), "the map's start radius stays")
	assert_eq(float(d.mode_cfg["drop"]["path_length_m"]), float(over["br"]["drop"]["path_length_m"]), "the map's carrier line stays")
	assert_eq(MatchDirector.map_overrides(BIG), over, "scaling the config leaves the map's overrides as they are")
	d.free()


func _write_tmp_map() -> void:
	if FileAccess.file_exists(TMP_MAP):  # left by an aborted earlier run
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MAP))
	var def := DataRegistry.parse_quiet(ALESIA)
	def["overrides"] = {"br": {"zone": {"start_radius_m": 74.0}, "drop": {"carrier_s": 33.0}}, "loot": {"count": 33}}
	var f := FileAccess.open(TMP_MAP, FileAccess.WRITE)
	f.store_string(JSON.stringify(def, "\t"))
	f.close()


func _match(preload_cfg: String, scale: bool) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	m.ground_loot = true
	m.seed_override = 4242
	m.map_path_override = TMP_MAP
	_tree().root.add_child(m)
	await _tree().physics_frame
	if preload_cfg != "-":
		m.director.load_config(preload_cfg)
		if scale:
			for ph in m.director.mode_cfg["zone"]["phases"]:
				ph["wait_s"] = float(ph["wait_s"]) * 0.4
			m.director.mode_cfg["drop"]["carrier_s"] = 8.0
	assert_true(m.begin(), "begin on the temporary map")
	return m


## Through the real begin() on a small copy of alesia with overrides: begin() merges when the config is empty,
## and never again once the caller loaded it (with or without the map).
func test_begin_merges_once_at_config_load() -> void:
	_write_tmp_map()
	var plain := _cfg()
	var fresh: MatchRoot = await _match("-", false)
	assert_eq(float(fresh.director.mode_cfg["zone"]["start_radius_m"]), 74.0, "empty config: begin() merges the map's zone override")
	assert_eq(float(fresh.director.mode_cfg["drop"]["carrier_s"]), 33.0, "and its drop override")
	assert_eq(int(fresh.director.loot_cfg["count"]), 33, "and its loot override")
	await _tree().physics_frame
	await _tree().physics_frame
	assert_true(fresh.loot.placed and fresh.loot.items.size() <= 33 and fresh.loot.items.size() > 20, "the loot field placed the map's count (%d)" % fresh.loot.items.size())
	fresh.queue_free()
	await _tree().process_frame
	var scaled: MatchRoot = await _match(TMP_MAP, true)
	assert_eq(float(scaled.director.mode_cfg["zone"]["phases"][0]["wait_s"]), float(plain["br"]["zone"]["phases"][0]["wait_s"]) * 0.4, "a config loaded and scaled before begin() keeps its scaling")
	assert_eq(float(scaled.director.mode_cfg["drop"]["carrier_s"]), 8.0, "and its carrier_s (not the map's 33)")
	assert_eq(float(scaled.director.mode_cfg["zone"]["start_radius_m"]), 74.0, "the override merged at that config load stays")
	scaled.queue_free()
	await _tree().process_frame
	var old_way: MatchRoot = await _match("", false)
	assert_eq(old_way.director.mode_cfg, plain["br"], "a config loaded without the map (the 45 match tests) is not merged by begin()")
	assert_eq(old_way.map_path, TMP_MAP, "on the override map")
	old_way.queue_free()
	await _tree().process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MAP))
	assert_true(not FileAccess.file_exists(TMP_MAP), "temporary map removed")


func _positions(field: LootField) -> Array:
	var out: Array = []
	for id in field.items:
		out.append([field.items[id]["item_id"], field.items[id]["pos"]])
	return out


## Binding fix 4: on the flat maps the loot lands exactly where it did before the terrain-relative limit. The match's
## own field (as MatchRoot.begin sets it up) against a field with the old absolute rule, same seed and inputs.
func test_flat_map_loot_is_unchanged() -> void:
	for map_path: String in [ALESIA, TEST_300]:
		var m: MatchRoot = _MatchScene.instantiate()
		m.auto_start = false
		m.bake_navmesh = false
		m.fill_bots = false
		m.ground_loot = true
		m.seed_override = 4242
		if map_path != ALESIA:
			m.map_path_override = map_path
		_tree().root.add_child(m)
		await _tree().physics_frame
		m.director.load_config()
		assert_true(m.begin(), "begin on " + map_path)
		var terrain: MapTerrain = m.map.get_node("ArtBuilder").terrain
		assert_eq(m.loot._ground_height.is_valid(), terrain != null, map_path + ": the loot field gets the terrain height exactly when the map has terrain")
		var landmarks: Array = DataRegistry.parse_quiet(str(m.map_def.get("landmarks", ""))).get("landmarks", [])
		assert_true(not landmarks.is_empty(), map_path + ": landmarks for the clusters")
		var old_rule := LootField.new()  # Callable(): the absolute max_ground_y_m, the code path before M2L1
		old_rule.setup(m.director.loot_cfg, 4242, m.director.mode_cfg["zone"], landmarks)
		var zero := LootField.new()  # a height of 0 everywhere: the new arithmetic on flat ground
		zero.setup(m.director.loot_cfg, 4242, m.director.mode_cfg["zone"], landmarks, func(_x: float, _z: float) -> float: return 0.0)
		m.add_child(old_rule)
		m.add_child(zero)
		await _tree().physics_frame
		await _tree().physics_frame
		assert_true(m.loot.placed and m.loot.items.size() > 30, map_path + ": loot placed (%d)" % m.loot.items.size())
		assert_eq(_positions(m.loot), _positions(old_rule), map_path + ": the match's loot lies exactly where the old rule puts it")
		assert_eq(_positions(zero), _positions(old_rule), map_path + ": a zero ground height gives the old placement")
		if terrain != null:
			# Why test_300 is unchanged: its one hill (centre (90, 90), radius 45 towards the centre) lies outside the
			# loot circle (start radius less the edge margin), where the ground is exactly 0.
			var r := float(m.director.mode_cfg["zone"]["start_radius_m"])
			var highest := 0.0
			for x in range(-int(r), int(r) + 1):
				for z in range(-int(r), int(r) + 1):
					if Vector2(x, z).length() <= r:
						highest = maxf(highest, absf(terrain.height_at(float(x), float(z))))
			assert_eq(highest, 0.0, map_path + ": the ground inside the zone start circle is exactly flat")
		print("MAP_OVERRIDES flat_loot map=", map_path.get_file(), " items=", m.loot.items.size(), " terrain=", terrain != null)
		old_rule.free()
		zero.free()
		m.queue_free()
		await _tree().process_frame
