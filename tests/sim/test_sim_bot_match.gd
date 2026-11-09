extends "res://tests/test_case.gd"
## On-demand simulation (not in the regular suite): a full 18-player match with the drop, ground loot and a
## faster zone; the local human idles. Prints how players were eliminated and who won.
## Run: godot --headless --path . --script res://tests/run_tests.gd -- --dir=res://tests/sim

const _MatchScene := preload("res://scenes/match/match.tscn")


func test_bot_match_runs_to_a_result() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for mode in ["solo", "squads"]:
		var m: MatchRoot = _MatchScene.instantiate()
		m.auto_start = false
		m.bake_navmesh = true
		m.seed_override = 99 if mode == "solo" else 199
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
		var killers := {}
		m.director.player_eliminated.connect(func(id: int, killer: int, cause: String) -> void:
			causes[cause] = int(causes.get(cause, 0)) + 1
			if killer >= 0:
				killers[killer] = int(killers.get(killer, 0)) + 1)
		var results: Array = []
		m.director.match_over.connect(func(r: Dictionary) -> void: results.append(r))
		assert_true(m.begin(), "begin %s" % mode)
		var t0 := Time.get_ticks_msec()
		var n := 0
		while results.is_empty() and n < 60 * 240:
			await tree.physics_frame
			n += 1
		var picked := 0
		for id in m.director.all_players():
			var p: Pawn = m.director.player(id)
			if p.loadout != null and (p.loadout.slots[0] != null or p.loadout.slots[2] != null or p.armor_tier > 0):
				picked += 1
		print("SIM mode=%s physics_frames=%d game_s=%.1f real_s=%.1f over=%s causes=%s killers=%s armed_or_armored=%d loot_left=%d" % [
				mode, n, n / 60.0, (Time.get_ticks_msec() - t0) / 1000.0, not results.is_empty(), causes, killers,
				picked, m.loot.items.size()])
		if not results.is_empty():
			print("SIM result=%s" % results[0])
		for id in m.director.all_players():
			var p: Pawn = m.director.player(id)
			if p.life != Pawn.Life.DEAD:
				var w := p.loadout.get_active() if p.loadout != null else null
				var brain := p.get_node_or_null("Brain")
				print("SIM survivor id=%d life=%d pos=%s weapon=%s goal=%s target=%s drop=%d" % [id, p.life,
						p.global_position.snapped(Vector3.ONE * 0.1), w.def.id if w != null else "none",
						brain.goal_kind if brain != null else "human", brain.target_id if brain != null else -1, p.drop_state])
		assert_eq(results.size(), 1, "%s match ended" % mode)
		m.queue_free()
		await tree.process_frame
