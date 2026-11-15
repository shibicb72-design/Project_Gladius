extends "res://tests/sim/test_sim_alesia_1km.gd"
## On demand, never in the normal suite (M2L1c step A, kept as the evidence tool for the stuck-spot causes): runs the same seeded sim and, at each unstick start, prints what happened in the
## stuck window (the last 121 physics frames = stuck_window_s 2.0 + 1): path walked, wall frames and the slide
## colliders (Ground excluded), goal-kind switches and _inside_target flips, frames with no move input.

const WIN := 121
var _done := false


func _poll() -> void:
	var tree := _tree()
	var buf := {}  # bot id -> Array of per-frame [step_m, on_wall, hit names, goal_kind, inside, move0]
	var last := {}
	var prev := {}
	while not _done:
		await tree.physics_frame
		var m: MatchRoot = null
		for c in tree.root.get_children():
			if c is MatchRoot:
				m = c
		if m == null or m.bots.is_empty():
			continue
		for b: Pawn in m.bots:
			var brain := b.get_node_or_null("Brain")
			if brain == null or not b.is_alive() or b.is_dropping():
				continue
			var p := b.global_position
			var lp: Vector3 = last.get(b.player_id, p)
			last[b.player_id] = p
			var hits: Array = []
			for i in b.get_slide_collision_count():
				var o := b.get_slide_collision(i).get_collider()
				if o is Node and String((o as Node).name) != "Ground":
					hits.append(String((o as Node).name))
			var fr: InputFrame = b.get("_frame")
			var rows: Array = buf.get_or_add(b.player_id, [])
			rows.append([Vector2(p.x - lp.x, p.z - lp.z).length(), b.is_on_wall(), hits, String(brain.goal_kind),
					bool(brain.call("_inside_target")), fr.move.length() < 0.05])
			if rows.size() > WIN:
				rows.pop_front()
			var left := float(brain.get("_unstick_left"))
			if left > 0.0 and float(prev.get(b.player_id, 0.0)) <= 0.0:
				var walk := 0.0
				var wall := 0
				var move0 := 0
				var names := {}
				var kinds := {}
				var switches := 0
				var flips := 0
				for i in rows.size():
					var r: Array = rows[i]
					walk += float(r[0])
					wall += 1 if bool(r[1]) else 0
					move0 += 1 if bool(r[5]) else 0
					for nm: String in r[2]:
						names[nm] = int(names.get(nm, 0)) + 1
					kinds[r[3]] = int(kinds.get(r[3], 0)) + 1
					if i > 0:
						switches += 1 if String(rows[i - 1][3]) != String(r[3]) else 0
						flips += 1 if bool(rows[i - 1][4]) != bool(r[4]) else 0
				var cls := "osc_inside" if flips >= 2 else ("blocked" if wall >= 20 else ("goal_flip" if switches >= 2 else "other"))
				var g: Vector3 = brain.get("_last_goal")
				print("EV bot=%d t=%.1f pos=(%.1f, %.1f) class=%s walk_m=%.1f wall=%d move0=%d flips=%d switches=%d kinds=%s hits=%s goal=%s goal_pos=(%.1f, %.1f) reach=%s" % [
						b.player_id, m.director.tick_count / 60.0, p.x, p.z, cls, walk, wall, move0, flips, switches, str(kinds), str(names),
						brain.goal_kind, g.x, g.z, (brain.get("_agent") as NavigationAgent3D).is_target_reachable()])
			prev[b.player_id] = left


func test_trace_solo() -> void:
	_poll()
	var a := await _run("solo", _Metrics.cli_seed(SOLO_SEED))
	_done = true
	assert_true(bool(a["over"]), "over")


func test_trace_squads() -> void:
	_poll()
	var a := await _run("squads", _Metrics.cli_seed(SQUADS_SEED))
	_done = true
	assert_true(bool(a["over"]), "over")
