extends "res://tests/test_case.gd"
## On-demand simulation (not in the regular suite): full 18-player matches with the drop, ground loot and a
## faster zone; the local human idles. Prints how players were eliminated (cause, weapon, range), shots and
## hits, loot taken, bot goal time shares and the result. The solo match runs twice with the same seed to
## check that the sim repeats (G0).
## Run: godot --headless --path . --script res://tests/run_tests.gd -- --dir=res://tests/sim

const _MatchScene := preload("res://scenes/match/match.tscn")


func _run(mode: String, seed_value: int) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.seed_override = seed_value
	m.drop_from_sky = true
	m.ground_loot = true
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	var z: Dictionary = m.director.mode_cfg["zone"]
	for ph in z["phases"]:  # 40% of the data timings so a sim takes about two minutes
		ph["wait_s"] = float(ph["wait_s"]) * 0.4
		ph["shrink_s"] = float(ph["shrink_s"]) * 0.4
	m.director.mode_cfg["drop"]["carrier_s"] = 8.0
	var causes := {}
	var kills: Array[String] = []
	var shots := {}
	var hits := {}
	m.director.player_eliminated.connect(func(id: int, killer: int, cause: String) -> void:
		causes[cause] = int(causes.get(cause, 0)) + 1
		var k: Pawn = m.director.player(killer) if killer >= 0 else null
		var v: Pawn = m.director.player(id)
		if k != null and v != null:
			var w := k.loadout.get_active() if k.loadout != null else null
			kills.append("%s@%dm" % [w.def.id if w != null else "none", int(k.global_position.distance_to(v.global_position))]))
	var results: Array = []
	m.director.match_over.connect(func(r: Dictionary) -> void: results.append(r))
	assert_true(m.begin(), "begin %s" % mode)
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		p.fired.connect(func() -> void: shots[id] = int(shots.get(id, 0)) + 1)
		p.shot_resolved.connect(func(_o: Vector3, _e: Vector3, hit: Dictionary) -> void:
			if not hit.is_empty() and hit.get("target") is Pawn:
				hits[id] = int(hits.get(id, 0)) + 1)
	var goal_frames := {}
	var n := 0
	while results.is_empty() and n < 60 * 240:
		await tree.physics_frame
		n += 1
		for b in m.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null and b.is_alive() and not b.is_dropping():
				goal_frames[brain.goal_kind] = int(goal_frames.get(brain.goal_kind, 0)) + 1
	var total_shots := 0
	var total_hits := 0
	for id in shots:
		total_shots += int(shots[id])
	for id in hits:
		total_hits += int(hits[id])
	var goal_total := 0
	for g in goal_frames:
		goal_total += int(goal_frames[g])
	var shares := {}
	for g in goal_frames:
		shares[g] = snappedf(float(goal_frames[g]) / maxf(goal_total, 1.0), 0.01)
	var line := "SIM mode=%s seed=%d game_s=%.1f over=%s causes=%s kills=%s shots=%d hits=%d loot_left=%d goals=%s" % [
			mode, seed_value, n / 60.0, not results.is_empty(), causes, kills, total_shots, total_hits,
			m.loot.items.size(), shares]
	print(line)
	if not results.is_empty():
		print("SIM result winner=%s draw=%s" % [results[0]["winner"], results[0]["draw"]])
	m.queue_free()
	await tree.process_frame
	return {"line": line, "over": not results.is_empty()}


func test_bot_match_runs_to_a_result_and_repeats() -> void:
	var a := await _run("solo", 99)
	var b := await _run("solo", 99)
	var s := await _run("squads", 199)
	assert_true(bool(a["over"]), "solo match ended")
	assert_true(bool(s["over"]), "squads match ended")
	print("SIM repeat_identical=%s" % (a["line"] == b["line"]))
	assert_eq(a["line"], b["line"], "same seed, same match")
