extends "res://tests/test_case.gd"

const BrS := preload("res://scripts/systems/br_rules.gd")
const ModeRegistryS := preload("res://scripts/systems/mode_registry.gd")
const _TMP := "user://br_rules_test_tmp.json"
const OUT := Vector2(500, 0)


func _cfg(down: Dictionary = {}, mode: String = "squads") -> Dictionary:
	var d := {"bleed_out_s": 10, "revive_s": 4, "revive_range_m": 2, "downed_move_speed_pct": 30,
			"revive_health_pct": 30, "can_be_finished": true, "zone_finishes_downed": true,
			"squad_wipe_kills_downed": true, "kill_credit_to_downer": true,
			"bleed_pauses_while_reviving": true, "bleed_restarts_on_new_down": true}
	d.merge(down, true)
	return {
		"zone": {"_x": "ignored", "start_center": [0, 0], "start_radius_m": 100, "damage_skips_shield": true,
				"phases": [{"wait_s": 10, "shrink_s": 10, "radius_m": 60, "damage_per_s": 1},
						{"wait_s": 5, "shrink_s": 5, "radius_m": 30, "damage_per_s": 2}]},
		"downed": d, "end": {"tie_result": "draw"},
		"teams": {"mode": {"value": mode}, "squad_size_max": 3}, "default_seed": 7}


## players: [[player_id, squad_id], ...]
func _mk(players: Array, mode: String = "squads", down: Dictionary = {}) -> BrRules:
	var b: BrRules = BrS.new()
	b.setup(_cfg(down, mode))
	for p in players:
		b.register_player(p[0], p[1])
	return b


func _facts(b: BrRules, out: Dictionary = {}, reviving: Dictionary = {}) -> Dictionary:
	var pos := {}
	for id in range(0, 20):
		if b.player_state(id) in [0, 1]:
			pos[id] = out.get(id, Vector2.ZERO)
	return {"positions": pos, "reviving": reviving}


## 3 players: squad 10 = {1, 2}, squad 11 = {3}; started.
func _started(down: Dictionary = {}) -> BrRules:
	var b := _mk([[1, 10], [2, 10], [3, 11]], "squads", down)
	b.tick(0.0, _facts(b))
	return b


func _types(ev: Array[Dictionary]) -> Array:
	var t := []
	for e in ev:
		t.append(e["type"])
	return t


func _of(ev: Array[Dictionary], type: String) -> Array:
	var r := []
	for e in ev:
		if e["type"] == type:
			r.append(e)
	return r


func _near(a: float, b: float) -> bool:
	return absf(a - b) < 1e-4


# ---- a: validation ----
func test_validate_config_ok_and_ignores_underscore_keys() -> void:
	assert_eq(BrS.validate_config(_cfg()), [] as Array[String], "good cfg")


func test_validate_config_problems() -> void:
	var cases := {}
	var c := _cfg(); c["zone"]["phases"] = []; cases["empty phases"] = c
	c = _cfg(); c["zone"]["phases"][0]["radius_m"] = 100; cases["phase0 not smaller"] = c
	c = _cfg(); c["zone"]["phases"][1]["radius_m"] = 60; cases["not decreasing"] = c
	c = _cfg(); c["zone"]["phases"][0]["wait_s"] = -1; cases["neg time"] = c
	c = _cfg(); c["zone"]["phases"][0]["damage_per_s"] = -1; cases["neg damage"] = c
	c = _cfg(); c["zone"]["phases"][1]["radius_m"] = -2; cases["neg radius"] = c
	c = _cfg(); c["downed"]["revive_health_pct"] = 101; cases["pct high"] = c
	c = _cfg(); c["downed"]["downed_move_speed_pct"] = -1; cases["pct low"] = c
	c = _cfg(); c["teams"]["mode"]["value"] = "duo"; cases["team mode"] = c
	c = _cfg(); c.erase("downed"); cases["missing downed"] = c
	c = _cfg(); c["downed"].erase("revive_s"); cases["missing key"] = c
	c = _cfg(); c["zone"]["start_radius_m"] = 0; cases["start radius 0"] = c
	c = _cfg(); c["zone"]["start_center"] = [0, 0, 0]; cases["center size"] = c
	c = _cfg(); c["teams"]["squad_size_max"] = 0; cases["squad max"] = c
	c = _cfg(); c["downed"]["can_be_finished"] = "yes"; cases["not bool"] = c
	c = _cfg(); c["end"]["tie_result"] = "shared"; cases["tie"] = c
	for k in cases:
		assert_true(not BrS.validate_config(cases[k]).is_empty(), "problem expected: %s" % k)


func test_problems_block_everything() -> void:
	var b: BrRules = BrS.new()
	var c := _cfg()
	c["zone"]["phases"] = []
	b.setup(c)
	assert_true(not b.config_problems().is_empty(), "problems stored")
	assert_true(not b.register_player(1, 1), "register refused")
	assert_true(not b.register_player(2, 2), "register refused 2")
	assert_eq(b.tick(5.0, {}).size(), 0, "tick does nothing")
	assert_true(not b.is_over(), "not over")


func _joined(c: Dictionary) -> String:
	return "\n".join(BrS.validate_config(c))


func test_empty_sub_objects_name_every_missing_key() -> void:
	var expected := {
		"zone": ["start_center", "start_radius_m", "damage_skips_shield", "phases"],
		"downed": ["bleed_out_s", "revive_s", "revive_range_m", "downed_move_speed_pct", "revive_health_pct",
				"can_be_finished", "zone_finishes_downed", "squad_wipe_kills_downed", "kill_credit_to_downer",
				"bleed_pauses_while_reviving", "bleed_restarts_on_new_down"],
		"end": ["tie_result"],
		"teams": ["mode", "squad_size_max"]}
	for sub in expected:
		var c := _cfg()
		c[sub] = {}
		var text := _joined(c)
		for k in expected[sub]:
			assert_true(text.contains(k), "empty %s names %s" % [sub, k])
		assert_true(not text.contains("%s: missing or not an object" % sub), "empty %s counts as an object" % sub)
		var b: BrRules = BrS.new()
		b.setup(c)
		assert_true(not b.config_problems().is_empty(), "problems stored for empty %s" % sub)
		assert_true(not b.register_player(1, 1), "register refused for empty %s" % sub)
		assert_eq(b.tick(5.0, {}).size(), 0, "tick inert for empty %s" % sub)
		# a missing sub-object adds the "missing or not an object" problem on top of the key problems
		c = _cfg()
		c.erase(sub)
		text = _joined(c)
		assert_true(text.contains("%s: missing or not an object" % sub), "missing %s reported" % sub)
		for k in expected[sub]:
			assert_true(text.contains(k), "missing %s names %s" % [sub, k])


func test_default_seed_validation() -> void:
	for ok in [7, 7.0, 3.0, 0, -5, -5.0]:
		var c := _cfg()
		c["default_seed"] = ok
		assert_eq(BrS.validate_config(c), [] as Array[String], "seed ok: %s" % str(ok))
	for bad in [1.5, "7", true, null]:
		var c := _cfg()
		c["default_seed"] = bad
		assert_true(_joined(c).contains("default_seed"), "seed rejected: %s" % str(bad))
	var m := _cfg()
	m.erase("default_seed")
	assert_true(_joined(m).contains("default_seed"), "missing default_seed")
	var b: BrRules = BrS.new()
	b.setup(m)
	assert_true(not b.config_problems().is_empty(), "setup keeps problems when seed missing")


func test_squad_size_max_validation() -> void:
	for ok in [1, 3.0, 4]:
		var c := _cfg()
		c["teams"]["squad_size_max"] = ok
		assert_eq(BrS.validate_config(c), [] as Array[String], "squad max ok: %s" % str(ok))
	for bad in [0, 1.5, "3", true, -2]:
		var c := _cfg()
		c["teams"]["squad_size_max"] = bad
		assert_true(_joined(c).contains("squad_size_max"), "squad max rejected: %s" % str(bad))


# ---- b: players, teams, start ----
func test_registration_and_start() -> void:
	var b := _mk([[1, 10]])
	assert_eq(b.tick(5.0, _facts(b)).size(), 0, "one squad: no events")
	assert_true(_near(b.zone_seconds_left(), 10.0), "time did not advance")
	assert_eq(b.zone_state(), "waiting", "waiting before start")
	assert_true(not b.register_player(1, 10), "duplicate id")
	assert_true(b.register_player(2, 11), "second squad")
	assert_true(not b.set_team_mode("solo"), "mode locked after registration")
	var ev := b.tick(0.0, _facts(b))
	assert_eq(_types(ev), ["zone_phase"], "start emits phase 0")
	assert_true(not b.register_player(3, 12), "refused after start")
	assert_true(not b.is_over(), "not over")


func test_squad_size_limit_and_mode_validation() -> void:
	var b := _mk([[1, 10], [2, 10], [3, 10]])
	assert_true(not b.register_player(4, 10), "squad above max")
	assert_true(b.register_player(4, 11), "other squad ok")
	var c: BrRules = BrS.new()
	c.setup(_cfg())
	assert_true(not c.set_team_mode("trio"), "bad mode")
	assert_true(c.set_team_mode("solo"), "valid mode")


func test_solo_squad_id_is_player_id() -> void:
	var b := _mk([[5, 99], [6, 99], [7, 99]], "solo")
	assert_eq(b.squad_of(5), 5, "squad = player")
	assert_eq(b.squad_of(6), 6, "squad = player 6")
	assert_eq(b.player_state(42), -1, "unknown")
	assert_eq(b.squad_of(42), -1, "unknown squad")


# ---- c: zone ----
func test_zone_timing_linear_shrink_and_final() -> void:
	var b := _started()
	assert_eq(b.zone_state(), "waiting", "start waiting")
	var ev := b.tick(10.0, _facts(b))
	assert_eq(ev.size(), 1, "exactly at boundary: one event")
	assert_eq(ev[0]["state"], "shrinking", "shrinking")
	assert_eq(b.zone_state(), "shrinking", "state")
	ev = b.tick(5.0, _facts(b))
	assert_eq(ev.size(), 0, "mid shrink")
	assert_true(_near(b.zone_radius(), 80.0), "linear halfway radius %s" % b.zone_radius())
	ev = b.tick(5.0, _facts(b))
	assert_eq(ev[0]["phase"], 1, "phase 1")
	assert_eq(ev[0]["state"], "waiting", "phase 1 waiting")
	assert_true(_near(b.zone_radius(), 60.0), "radius 60")
	assert_eq(b.tick(0.0, _facts(b)).size(), 0, "zero tick: no repeated event")
	b.tick(5.0, _facts(b))
	ev = b.tick(5.0, _facts(b))
	assert_eq(ev[0]["state"], "final", "final")
	assert_eq(ev[0]["phase"], 1, "final carries last index")
	assert_eq(b.zone_phase(), 1, "zone_phase last")
	assert_eq(b.zone_state(), "final", "state final")
	assert_true(_near(b.zone_seconds_left(), 0.0), "no seconds left")
	assert_true(_near(b.zone_radius(), 30.0), "radius 30")
	assert_true(_near(b.zone_damage_per_s(), 2.0), "last damage")
	assert_eq(b.tick(50.0, _facts(b)).size(), 0, "final: no more phase events")


func test_large_delta_crosses_boundaries() -> void:
	var b := _mk([[1, 10], [2, 11]])
	var ev := b.tick(100.0, _facts(b, {1: OUT}))
	var zp := _of(ev, "zone_phase")
	var seq := []
	for e in zp:
		seq.append("%d%s" % [e["phase"], e["state"]])
	assert_eq(seq, ["0waiting", "0shrinking", "1waiting", "1shrinking", "1final"], "boundary order")
	var dmg := _of(ev, "zone_damage")
	assert_eq(dmg.size(), 1, "one damage event")
	assert_true(_near(dmg[0]["amount"], 180.0), "split damage %s" % dmg[0]["amount"])
	assert_true(dmg[0]["skips_shield"], "skips shield flag")


func test_zone_nesting_200_seeds_and_determinism() -> void:
	var b := _mk([[1, 10], [2, 11]])
	for s in 200:
		b.set_seed(s)
		var pc := Vector2.ZERO
		var pr := 100.0
		for i in b.phase_count():
			var c := b.phase_circle(i)
			assert_true((c["center"] as Vector2).distance_to(pc) + float(c["radius"]) <= pr + 1e-4, "nested seed %d phase %d" % [s, i])
			pc = c["center"]
			pr = c["radius"]
	b.set_seed(3)
	var a := b.phase_circle(0)
	b.set_seed(4)
	assert_true(a["center"] != b.phase_circle(0)["center"], "set_seed regenerates")
	b.set_seed(3)
	assert_eq(b.phase_circle(0)["center"], a["center"], "same seed same circle")
	var b2 := _mk([[1, 10], [2, 11]])
	b2.set_seed(3)
	assert_eq(b2.phase_circle(1), b.phase_circle(1), "same seed, other instance")
	b2.tick(0.0, _facts(b2))
	assert_true(not b2.set_seed(9), "set_seed refused after start")


func test_setup_seeds_from_default_seed() -> void:
	var ca := _cfg()
	ca["default_seed"] = 7
	var cb := _cfg()
	cb["default_seed"] = 8
	var a: BrRules = BrS.new()
	a.setup(ca)
	var b: BrRules = BrS.new()
	b.setup(cb)
	var differs := false
	for i in a.phase_count():
		if a.phase_circle(i) != b.phase_circle(i):
			differs = true
	assert_true(differs, "different default_seed gives different circles")
	assert_true(b.set_seed(7), "set_seed before start")
	for i in a.phase_count():
		assert_eq(a.phase_circle(i), b.phase_circle(i), "same seed 7 equal at phase %d" % i)


func test_zero_length_wait_and_shrink_emit_in_one_tick() -> void:
	var c := _cfg()
	c["zone"]["phases"] = [{"wait_s": 10, "shrink_s": 10, "radius_m": 60, "damage_per_s": 1},
			{"wait_s": 0, "shrink_s": 0, "radius_m": 40, "damage_per_s": 1},
			{"wait_s": 5, "shrink_s": 5, "radius_m": 20, "damage_per_s": 2}]
	var b: BrRules = BrS.new()
	b.setup(c)
	b.register_player(1, 10)
	b.register_player(2, 11)
	b.tick(0.0, _facts(b))
	b.tick(10.0, _facts(b))
	var ev := b.tick(10.0, _facts(b))
	var seq := []
	for e in _of(ev, "zone_phase"):
		seq.append("%d%s" % [e["phase"], e["state"]])
	assert_eq(seq, ["1waiting", "1shrinking", "2waiting"], "zero-length phase order in one tick")
	assert_eq(b.zone_phase(), 2, "now in phase 2")
	assert_true(_near(b.zone_radius(), 40.0), "radius 40 after zero-length shrink")


func test_zone_getters_before_start_and_after_over() -> void:
	var b := _mk([[1, 10], [2, 11]], "solo")
	assert_eq(b.zone_phase(), 0, "phase 0")
	assert_true(_near(b.zone_seconds_left(), 10.0), "wait_s")
	assert_eq(b.zone_center(), Vector2.ZERO, "start center")
	b.tick(0.0, _facts(b))
	b.report_zero_health(1, 2, "hit")
	b.tick(3.0, _facts(b))
	assert_true(b.is_over(), "over")
	var left := b.zone_seconds_left()
	b.tick(5.0, _facts(b))
	assert_true(_near(b.zone_seconds_left(), left), "frozen after over")


func test_zone_damage_only_alive_outside() -> void:
	var b := _started()
	b.report_zero_health(2, 3, "hit")  # downed
	b.tick(0.0, _facts(b))
	var ev := b.tick(2.0, _facts(b, {1: OUT, 2: OUT, 3: Vector2(10, 0)}))
	var dmg := _of(ev, "zone_damage")
	assert_eq(dmg.size(), 1, "only the alive outside player")
	assert_eq(dmg[0]["player_id"], 1, "player 1")
	assert_true(_near(dmg[0]["amount"], 2.0), "2 s at 1/s")
	var f := _facts(b, {1: OUT})
	(f["positions"] as Dictionary).erase(1)
	assert_eq(_of(b.tick(1.0, f), "zone_damage").size(), 0, "missing position = inside")


func test_zone_finishes_downed_flag() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	var ev := b.tick(1.0, _facts(b, {1: OUT}))
	var dead := _of(ev, "dead")
	assert_eq(dead.size(), 1, "downed dies in zone")
	assert_eq(dead[0]["cause"], "zone", "cause zone")
	assert_eq(dead[0]["killer_id"], 3, "downer credited")
	var b2 := _started({"zone_finishes_downed": false})
	b2.report_zero_health(1, 3, "hit")
	assert_eq(_of(b2.tick(1.0, _facts(b2, {1: OUT})), "dead").size(), 0, "flag off: zone ignores downed")
	assert_eq(b2.player_state(1), BrRules.State.DOWNED, "still downed")


# ---- d/e: events, zero health ----
func test_ignored_calls() -> void:
	var b := _mk([[1, 10], [2, 11]])
	b.report_zero_health(1, 2, "hit")
	assert_eq(b.player_state(1), BrRules.State.ALIVE, "ignored before start")
	b.tick(0.0, _facts(b))
	b.report_zero_health(99, 2, "hit")
	b.report_zero_health(1, 2, "fall")
	assert_eq(b.player_state(1), BrRules.State.ALIVE, "bad cause ignored")
	b.report_zero_health(1, 2, "zone")
	assert_eq(b.player_state(1), BrRules.State.DOWNED, "zone cause downs an alive player")
	var s := _mk([[1, 10], [2, 11]], "solo")
	s.tick(0.0, _facts(s))
	s.report_zero_health(1, 2, "hit")
	s.report_zero_health(1, 2, "hit")
	assert_eq(_of(s.tick(0.0, _facts(s)), "dead").size(), 1, "dead player ignored")
	s.report_zero_health(2, 1, "hit")
	assert_eq(s.player_state(2), BrRules.State.ALIVE, "ignored after match_over")


func test_solo_dead_not_downed() -> void:
	var b := _mk([[1, 0], [2, 0], [3, 0]], "solo")
	b.tick(0.0, _facts(b))
	b.report_zero_health(1, 2, "hit")
	b.report_zero_health(3, -1, "zone")
	assert_eq(b.player_state(1), BrRules.State.DEAD, "dead")
	var ev := b.tick(0.0, _facts(b))
	assert_eq(_types(ev).count("downed"), 0, "no downed in solo")
	var dead := _of(ev, "dead")
	assert_eq(dead[0]["cause"], "hit", "cause hit")
	assert_eq(dead[0]["killer_id"], 2, "killer")
	assert_eq(dead[1]["cause"], "zone", "cause zone")
	assert_eq(dead[1]["killer_id"], -1, "no zone kill")


func test_last_alive_member_goes_down_then_wipe() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.report_zero_health(2, 3, "hit")
	assert_eq(b.player_state(2), BrRules.State.DOWNED, "downed not dead")
	var ev := b.tick(0.0, _facts(b))
	assert_eq(_types(ev), ["downed", "downed", "dead", "dead", "squad_eliminated", "match_over"], "wipe sequence")
	assert_eq(_of(ev, "dead")[0]["cause"], "squad_wipe", "wipe cause")
	for e in _of(ev, "dead"):
		assert_eq(e["killer_id"], 3, "wipe death credits the downer")
	assert_eq(b.result()["kills"][3], 2, "downer has both wipe kills")
	assert_eq(_of(ev, "squad_eliminated")[0]["placement"], 2, "placement 2")
	assert_eq(_of(ev, "match_over")[0]["winner"], 11, "winner squad 11")


func test_finish_flag() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.report_zero_health(1, 3, "hit")
	var ev := b.tick(0.0, _facts(b))
	assert_eq(_of(ev, "dead")[0]["cause"], "finished", "finished")
	var b2 := _started({"can_be_finished": false})
	b2.report_zero_health(1, 3, "hit")
	b2.report_zero_health(1, 3, "hit")
	assert_eq(b2.player_state(1), BrRules.State.DOWNED, "not finishable")
	assert_eq(_types(b2.tick(0.0, _facts(b2))), ["downed"], "only downed event")
	b2.report_zero_health(1, -1, "zone")
	assert_eq(b2.player_state(1), BrRules.State.DOWNED, "zone report on downed ignored")


# ---- f: bleed and revive ----
func test_bleed_out() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.tick(9.0, _facts(b))
	assert_eq(b.player_state(1), BrRules.State.DOWNED, "still downed at 9s")
	var ev := b.tick(1.0, _facts(b))
	assert_eq(_types(ev).filter(func(t): return t != "zone_phase"), ["bled_out", "dead"], "bled out then dead")
	assert_eq(_of(ev, "dead")[0]["cause"], "bled_out", "cause")
	assert_eq(_of(ev, "dead")[0]["killer_id"], 3, "downer credited for bleed out")


func test_bleed_pause_while_reviving() -> void:
	for pause in [true, false]:
		var b := _started({"revive_s": 100, "bleed_pauses_while_reviving": pause})
		b.report_zero_health(1, 3, "hit")
		b.tick(0.0, _facts(b))
		b.tick(6.0, _facts(b, {}, {2: 1}))
		b.tick(6.0, _facts(b, {}, {2: 1}))
		var expect_state: int = BrRules.State.DOWNED if pause else BrRules.State.DEAD
		assert_eq(b.player_state(1), expect_state, "pause=%s" % pause)


func test_bleed_restart_on_new_down() -> void:
	for restart in [true, false]:
		var b := _started({"bleed_restarts_on_new_down": restart, "bleed_pauses_while_reviving": false})
		b.report_zero_health(1, 3, "hit")
		b.tick(6.0, _facts(b))
		b.tick(4.0, _facts(b, {}, {2: 1}))
		assert_eq(b.player_state(1), BrRules.State.ALIVE, "revived")
		b.report_zero_health(1, 3, "hit")
		b.tick(5.0, _facts(b))
		var expect_state: int = BrRules.State.DOWNED if restart else BrRules.State.DEAD
		assert_eq(b.player_state(1), expect_state, "restart=%s" % restart)


func test_revive_completes() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.tick(0.0, _facts(b))
	var ev := b.tick(2.0, _facts(b, {}, {2: 1}))
	assert_true(_near(_of(ev, "revive_progress")[0]["progress"], 0.5), "half")
	ev = b.tick(2.0, _facts(b, {}, {2: 1}))
	assert_eq(_types(ev), ["revive_progress", "revived"], "progress 1.0 then revived")
	assert_true(_near(ev[0]["progress"], 1.0), "progress 1")
	assert_true(_near(ev[1]["health_pct"], 30.0), "health pct")
	assert_eq(ev[0]["reviver_id"], 2, "reviver")
	assert_eq(b.player_state(1), BrRules.State.ALIVE, "alive again")


func test_revive_resets_and_conditions() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.tick(0.0, _facts(b))
	b.tick(2.0, _facts(b, {}, {2: 1}))
	b.tick(1.0, _facts(b))  # interrupted
	var ev := b.tick(2.0, _facts(b, {}, {2: 1}))
	assert_true(_near(_of(ev, "revive_progress")[0]["progress"], 0.5), "progress reset by interruption")
	b.tick(1.0, _facts(b, {2: Vector2(5, 0)}, {2: 1}))  # out of range
	ev = b.tick(2.0, _facts(b, {}, {2: 1}))
	assert_true(_near(_of(ev, "revive_progress")[0]["progress"], 0.5), "reset by range")
	var f := _facts(b, {}, {2: 1})
	(f["positions"] as Dictionary).erase(2)
	assert_eq(_of(b.tick(1.0, f), "revive_progress").size(), 0, "missing position: no revive")
	# other squad cannot revive
	assert_eq(_of(b.tick(1.0, _facts(b, {}, {3: 1})), "revive_progress").size(), 0, "other squad")


func test_revive_stops_when_reviver_goes_down() -> void:
	var b := _started()
	b.report_zero_health(1, 3, "hit")
	b.tick(0.0, _facts(b))
	b.tick(2.0, _facts(b, {}, {2: 1}))
	b.report_zero_health(2, 3, "hit")
	var ev := b.tick(1.0, _facts(b, {}, {2: 1}))
	assert_eq(_of(ev, "revive_progress").size(), 0, "downed reviver does not revive")


func test_lowest_reviver_id_counts() -> void:
	var b := _mk([[1, 10], [2, 10], [3, 10], [4, 11]])
	b.tick(0.0, _facts(b))
	b.report_zero_health(1, 4, "hit")
	b.tick(0.0, _facts(b))
	var ev := b.tick(1.0, _facts(b, {3: Vector2(9, 0)}, {2: 1, 3: 1}))
	assert_eq(_of(ev, "revive_progress")[0]["reviver_id"], 2, "reviver 2 in range counts")
	ev = b.tick(1.0, _facts(b, {2: Vector2(9, 0)}, {2: 1, 3: 1}))
	assert_eq(_of(ev, "revive_progress").size(), 0, "lowest id out of range: nobody advances")


# ---- g: squad wipe off ----
func test_squad_wipe_flag_off() -> void:
	var b := _started({"squad_wipe_kills_downed": false})
	b.report_zero_health(1, 3, "hit")
	b.report_zero_health(2, 3, "hit")
	var ev := b.tick(0.0, _facts(b))
	assert_eq(_of(ev, "squad_eliminated").size(), 0, "downed members keep squad alive")
	ev = b.tick(10.0, _facts(b))
	assert_eq(_types(ev).filter(func(t): return t != "zone_phase"), ["bled_out", "dead", "bled_out", "dead", "squad_eliminated", "match_over"], "eliminated when last downed dies")


# ---- h/j: placement, end, result ----
func test_placements_shared_and_winner() -> void:
	var b := _mk([[1, 0], [2, 0], [3, 0], [4, 0]], "solo")
	b.tick(0.0, _facts(b))
	b.report_zero_health(2, 4, "hit")
	b.report_zero_health(1, 4, "hit")
	var ev := b.tick(0.0, _facts(b))
	var el := _of(ev, "squad_eliminated")
	assert_eq([el[0]["squad_id"], el[1]["squad_id"]], [1, 2], "ascending ids")
	assert_eq([el[0]["placement"], el[1]["placement"]], [4, 4], "shared placement")
	b.report_zero_health(3, 4, "hit")
	ev = b.tick(0.0, _facts(b))
	assert_eq(_of(ev, "squad_eliminated")[0]["placement"], 2, "placement 2")
	assert_eq(_of(ev, "match_over")[0]["winner"], 4, "winner")
	assert_true(b.is_over(), "over")
	var r := b.result()
	assert_eq(r["winner"], 4, "result winner")
	assert_true(not r["draw"], "no draw")
	assert_eq(r["placements"], {1: 4, 2: 4, 3: 2, 4: 1}, "placements")
	assert_eq(r["kills"], {1: 0, 2: 0, 3: 0, 4: 3}, "kills incl. zero")
	assert_eq(r["scores"], {}, "scores stay")
	assert_eq(b.tick(5.0, _facts(b, {4: OUT})).size(), 0, "no events after match_over")


func test_draw_same_tick() -> void:
	var b := _mk([[1, 0], [2, 0]], "solo")
	b.tick(0.0, _facts(b))
	assert_true(not b.is_over(), "not over yet")
	b.report_zero_health(1, 2, "hit")
	b.report_zero_health(2, 1, "hit")
	var ev := b.tick(0.0, _facts(b))
	var mo: Dictionary = _of(ev, "match_over")[0]
	assert_eq(mo["winner"], -1, "no winner")
	assert_true(mo["draw"], "draw")
	assert_eq(b.result()["placements"], {1: 2, 2: 2}, "shared placement, nobody 1")


# ---- i: kill credit ----
func test_kill_credit_rules() -> void:
	var b := _mk([[1, 10], [2, 10], [3, 11], [4, 12]])
	b.tick(0.0, _facts(b))
	b.report_zero_health(1, 3, "hit")  # downed by 3
	b.report_zero_health(1, 4, "hit")  # finished by 4: credit goes to downer 3
	var d := _of(b.tick(0.0, _facts(b)), "dead")
	assert_eq(d[0]["killer_id"], 3, "downer credit")
	assert_eq(b.result()["kills"][3], 1, "kills counted")
	assert_eq(b.result()["kills"][4], 0, "finisher gets none")
	var c := _mk([[1, 10], [2, 10], [3, 11], [4, 12]], "squads", {"kill_credit_to_downer": false})
	c.tick(0.0, _facts(c))
	c.report_zero_health(1, 3, "hit")
	c.report_zero_health(1, 4, "hit")
	assert_eq(_of(c.tick(0.0, _facts(c)), "dead")[0]["killer_id"], 4, "finisher credit when flag off")
	# flag off: only a valid finisher gets credit
	var finishers := {4: 4, 1: -1, 2: -1, 77: -1, -1: -1}  # finisher -> expected killer (1 self, 2 same squad)
	for f in finishers:
		var o := _mk([[1, 10], [2, 10], [3, 11], [4, 12]], "squads", {"kill_credit_to_downer": false})
		o.tick(0.0, _facts(o))
		o.report_zero_health(1, 3, "hit")
		o.report_zero_health(1, f, "hit")
		var dd := _of(o.tick(0.0, _facts(o)), "dead")
		assert_eq(dd[0]["killer_id"], finishers[f], "flag off, finisher %d" % f)
	# flag off: bled_out, zone and squad_wipe deaths give no kill
	var o2 := _mk([[1, 10], [2, 10], [3, 11], [4, 12]], "squads", {"kill_credit_to_downer": false})
	o2.tick(0.0, _facts(o2))
	o2.report_zero_health(1, 3, "hit")
	var bd := _of(o2.tick(10.0, _facts(o2)), "dead")
	assert_eq(bd[0]["cause"], "bled_out", "bled out")
	assert_eq(bd[0]["killer_id"], -1, "flag off: bled_out gives no kill")
	var o3 := _mk([[1, 10], [2, 10], [3, 11], [4, 12]], "squads", {"kill_credit_to_downer": false})
	o3.tick(0.0, _facts(o3))
	o3.report_zero_health(1, 3, "hit")
	var zd := _of(o3.tick(0.0, _facts(o3, {1: OUT})), "dead")
	assert_eq(zd[0]["cause"], "zone", "zone finish")
	assert_eq(zd[0]["killer_id"], -1, "flag off: zone gives no kill")
	var o4 := _mk([[1, 10], [2, 10], [3, 11], [4, 12]], "squads", {"kill_credit_to_downer": false})
	o4.tick(0.0, _facts(o4))
	o4.report_zero_health(1, 3, "hit")
	o4.report_zero_health(2, 3, "hit")
	var wd := _of(o4.tick(0.0, _facts(o4)), "dead")
	assert_eq(wd[0]["cause"], "squad_wipe", "wipe")
	for e in wd:
		assert_eq(e["killer_id"], -1, "flag off: squad_wipe gives no kill")
	var total := 0
	for k in o2.result()["kills"]:
		total += int(o2.result()["kills"][k])
	assert_eq(total, 0, "no kills recorded with flag off")


func test_solo_kill_credit() -> void:
	var b := _mk([[1, 1], [2, 2], [3, 3], [4, 4]], "solo")
	b.tick(0.0, _facts(b))
	b.report_zero_health(1, 1, "hit")  # self
	b.report_zero_health(2, 77, "hit")  # unknown killer
	b.report_zero_health(3, 4, "zone")  # zone with an enemy id: no credit
	var dd := _of(b.tick(0.0, _facts(b)), "dead")
	assert_eq(dd.size(), 3, "three solo deaths")
	for e in dd:
		assert_eq(e["killer_id"], -1, "solo no credit for %d" % e["player_id"])
	var c := _mk([[1, 1], [2, 2], [3, 3]], "solo")
	c.tick(0.0, _facts(c))
	c.report_zero_health(1, 2, "hit")
	assert_eq(_of(c.tick(0.0, _facts(c)), "dead")[0]["killer_id"], 2, "solo valid killer is credited")


func test_no_kill_cases() -> void:
	var b := _mk([[1, 10], [2, 10], [3, 11], [4, 12], [5, 13]], "squads", {"can_be_finished": true})
	b.tick(0.0, _facts(b))
	var cases := [[1, 1, "hit"], [2, 1, "hit"], [3, -1, "hit"], [4, 77, "hit"], [5, 3, "zone"]]
	for cs in cases:
		b.report_zero_health(cs[0], cs[1], cs[2])
		b.report_zero_health(cs[0], cs[1], cs[2])
	var ev := b.tick(0.0, _facts(b))
	for e in _of(ev, "downed"):
		assert_eq(e["killer_id"], -1, "no downer for %d" % e["player_id"])
	for e in _of(ev, "dead"):
		assert_eq(e["killer_id"], -1, "no killer for %d" % e["player_id"])
	var total := 0
	for k in b.result()["kills"]:
		total += int(b.result()["kills"][k])
	assert_eq(total, 0, "no kills at all")


# ---- order within a tick ----
func test_event_order_within_tick() -> void:
	var b := _mk([[1, 10], [2, 10], [3, 11], [4, 11]])
	b.tick(0.0, _facts(b))
	b.report_zero_health(2, 3, "hit")
	b.report_zero_health(1, 3, "hit")
	b.report_zero_health(4, 1, "hit")
	var ev := b.tick(10.0, _facts(b, {3: OUT}))
	assert_eq(_types(ev), ["downed", "downed", "downed", "zone_phase", "zone_damage", "bled_out", "dead",
			"bled_out", "dead", "bled_out", "dead", "squad_eliminated", "match_over"], "full order")
	var ids := []
	for e in _of(ev, "downed"):
		ids.append(e["player_id"])
	assert_eq(ids, [1, 2, 4], "queued events sorted by id")
	assert_true(_types(ev).find("zone_phase") > _types(ev).find("downed"), "queue before zone_phase")
	assert_true(_types(ev).find("zone_damage") > _types(ev).find("zone_phase"), "zone_phase before damage")
	assert_true(_types(ev).find("squad_eliminated") > _types(ev).rfind("dead"), "dead before elimination")
	assert_true(_types(ev).back() == "match_over" or not b.is_over(), "match_over last")


# ---- ModeRegistry ----
func test_mode_registry_loads_br_data() -> void:
	var modes: Dictionary = DataRegistry.new().load_file("res://data/modes.json")
	var data: Dictionary = DataRegistry.new().load_file("res://data/br.json")
	assert_true(not data.is_empty(), "br.json loads")
	var rules := ModeRegistryS.create("br", modes)
	assert_true(rules is BrRules, "br rules created")
	var br := rules as BrRules
	assert_eq(br.config_problems(), [] as Array[String], "no problems in br.json")
	assert_eq(br.cfg["zone"]["start_radius_m"], data["zone"]["start_radius_m"], "merged zone data")
	assert_eq(br.cfg["rules"], "br", "entry key kept")
	assert_eq(br.phase_count(), (data["zone"]["phases"] as Array).size(), "phases")
	assert_true(not (modes["br"] as Dictionary).has("zone"), "registry cache not mutated")
	assert_true(ModeRegistryS.create("koth", modes) is KothRules, "koth unchanged")


func test_mode_registry_bad_data_returns_null() -> void:
	var missing := {"br": {"rules": "br", "data": "res://data/does_not_exist_br.json"}}
	assert_eq(ModeRegistryS.create("br", missing), null, "missing file")
	var f := FileAccess.open(_TMP, FileAccess.WRITE)
	f.store_string("[1, 2, 3]")
	f.close()
	var wrong := {"br": {"rules": "br", "data": _TMP}}
	assert_eq(ModeRegistryS.create("br", wrong), null, "wrong shape")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))
