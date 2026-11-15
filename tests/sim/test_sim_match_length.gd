extends "res://tests/test_case.gd"
## M2 Z1 stage C, on demand (tests/sim, never in the normal suite): ONE real-timing 18-player match on
## alesia_1km per process, for the match length, the zone phases, the drop and how fast pawns loot. Nothing is
## scaled: the zone waits and shrinks, the carrier and the loot are the merged config exactly as a real match
## loads it (data/br.json and data/loot.json with the map's "overrides"). The local human idles. Everything is
## measured by POLLING from here each physics frame (gameplay code is untouched; there is no pickup signal).
## The match is chosen with user args, so a bare --only never starts six matches:
##   godot --headless --path . --script res://tests/run_tests.gd -- --dir=res://tests/sim --only=test_sim_match_length --ml-mode=solo --ml-seed=99
## --ml-mode=solo|squads, --ml-seed=N (the planned seeds are SOLO_SEEDS and SQUADS_SEEDS), --ml-max-game-s=N
## (a trial: stop after N game seconds and print the lines for what happened so far, marked trial=true).
## Without --ml-mode the test prints one "ML none" line and plays nothing.
## A match not over after WALL_CAP_MS of wall time is REPORTED (an "ML UNFINISHED" line), not failed.
## Output: single-line "ML ..." lines, key=value, mode and seed on every line. On each line the part before
## " | " is the deterministic part (compare runs on it); wall-clock numbers come after it.

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP := "res://data/maps/alesia_1km.json"
const WALL_CAP_MS := 25 * 60 * 1000
## Seed 1 of each mode is the L1 sim's (tests/sim/test_sim_alesia_1km.gd SOLO_SEED / SQUADS_SEED).
const SOLO_SEEDS := [99, 1099, 2099]
const SQUADS_SEEDS := [199, 1199, 2199]


## Stamps the wall clock on each physics tick; two of them sit right before and right after the LootField in
## the tree (same physics priority, so tree order), so their difference on the placing tick is the placement.
class _Stamp extends Node:
	var usec: int = 0

	func _physics_process(_delta: float) -> void:
		usec = Time.get_ticks_usec()


func _tree() -> SceneTree:
	return Engine.get_main_loop()


static func _median(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var s := values.duplicate()
	s.sort()
	var n := s.size()
	return float(s[n / 2]) if n % 2 == 1 else (float(s[n / 2 - 1]) + float(s[n / 2])) * 0.5


static func _f(v: float) -> String:
	return "%.1f" % v


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(name + "="):
			return a.substr(name.length() + 1)
	return fallback


func test_match_length() -> void:
	var mode := _arg("--ml-mode", "")
	if mode == "":
		print("ML none: no match selected; pass -- --ml-mode=solo|squads --ml-seed=N [--ml-max-game-s=N] (solo seeds %s, squads seeds %s)" % [SOLO_SEEDS, SQUADS_SEEDS])
		return
	assert_true(mode == "solo" or mode == "squads", "--ml-mode is solo or squads (got %s)" % mode)
	if mode != "solo" and mode != "squads":
		return
	var seeds: Array = SOLO_SEEDS if mode == "solo" else SQUADS_SEEDS
	var seed_value := int(_arg("--ml-seed", str(seeds[0])))
	await _run(mode, seed_value, float(_arg("--ml-max-game-s", "0")))


func _run(mode: String, seed_value: int, max_game_s: float) -> void:
	var tree := _tree()
	var tag := "mode=%s seed=%d" % [mode, seed_value]
	var def := DataRegistry.parse_quiet(MAP)
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.seed_override = seed_value
	m.drop_from_sky = true
	m.ground_loot = true
	m.map_path_override = MAP
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config(MAP)  # the merge a real match does; nothing below changes a timing
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	var wall_start := Time.get_ticks_msec()
	var tps := float(Engine.physics_ticks_per_second)
	var game_s := func() -> float: return m.director.tick_count / tps

	# ---- per-pawn records and the signals the L1 sim listens to ----
	var rec := {}  # player id -> Dictionary
	var last_melee := {}  # attacker id -> whether its last shot was the blade
	var blow := {}  # victim id -> "gun" | "blade"
	var tally := {"kills_gun": 0, "kills_blade": 0, "kills_unknown": 0, "zone": 0, "other": 0,
			"first_kill_s": -1.0, "first_down_s": -1.0, "first_elim_s": -1.0}
	var causes := {}
	var phase_rec: Array = []  # one Dictionary per zone phase
	var results: Array = []
	m.director.player_downed.connect(func(_id: int) -> void:
		if float(tally["first_down_s"]) < 0.0:
			tally["first_down_s"] = game_s.call())
	m.director.player_eliminated.connect(func(id: int, _killer: int, cause: String) -> void:
		var t: float = game_s.call()
		causes[cause] = int(causes.get(cause, 0)) + 1
		if float(tally["first_elim_s"]) < 0.0:
			tally["first_elim_s"] = t
		var ph: int = m.director.rules.zone_phase() if m.director.rules != null else 0
		var pr: Dictionary = phase_rec[mini(ph, phase_rec.size() - 1)] if not phase_rec.is_empty() else {}
		if cause == "zone":
			tally["zone"] = int(tally["zone"]) + 1
			if not pr.is_empty():
				pr["zone_deaths"] = int(pr["zone_deaths"]) + 1
		elif cause == "hit" or cause == "finished":
			var k := "kills_" + String(blow.get(id, "unknown"))
			tally[k] = int(tally[k]) + 1
			if float(tally["first_kill_s"]) < 0.0:
				tally["first_kill_s"] = t
			if not pr.is_empty():
				pr["kills"] = int(pr["kills"]) + 1
		else:
			tally["other"] = int(tally["other"]) + 1
		if rec.has(id):
			rec[id]["death_s"] = t
			rec[id]["cause"] = cause)
	m.director.match_over.connect(func(r: Dictionary) -> void: results.append(r))

	var begin_t := Time.get_ticks_msec()
	assert_true(m.begin(), "begin %s" % mode)
	var begin_ms := Time.get_ticks_msec() - begin_t
	assert_eq(m.map_path, MAP, "the match plays alesia_1km")
	assert_eq(m.nav_bakes, 0, "the saved 1 km mesh loads (no bake at match start)")
	# Real timings: the phases and the carrier are the map's own (generated) numbers, unscaled.
	var zone_cfg: Dictionary = m.director.mode_cfg["zone"]
	var file_phases: Array = def["overrides"]["br"]["zone"]["phases"]
	var nominal := 0.0
	for i in (zone_cfg["phases"] as Array).size():
		var ph: Dictionary = zone_cfg["phases"][i]
		assert_eq([float(ph["wait_s"]), float(ph["shrink_s"])], [float(file_phases[i]["wait_s"]), float(file_phases[i]["shrink_s"])], "phase %d timing is the map's, unscaled" % i)
		nominal += float(ph["wait_s"]) + float(ph["shrink_s"])
	assert_eq(float(m.director.mode_cfg["drop"]["carrier_s"]), float(def["overrides"]["br"]["drop"]["carrier_s"]), "carrier_s is the map's, unscaled")
	var rules := m.director.rules
	for i in rules.phase_count():
		phase_rec.append({"reached": false, "start_s": -1.0, "shrink_start_s": -1.0, "end_s": -1.0,
				"radius": float(rules.phase_circle(i)["radius"]), "alive_at_start": -1, "outside_current": -1,
				"outside_target": -1, "kills": 0, "zone_deaths": 0})
	phase_rec[0]["reached"] = true
	phase_rec[0]["start_s"] = 0.0
	phase_rec[0]["alive_at_start"] = m.director.players_alive()

	var ids: Array = m.director.all_players().keys()
	ids.sort()
	for id in ids:
		var p: Pawn = m.director.player(id)
		var start_guns := {}
		for w in p.loadout.slots:
			if w != null and not w.def.is_melee():
				start_guns[w.def.id] = true
		rec[id] = {"bot": p.has_node("Brain"), "class": String(p.class_id), "squad": p.squad_id, "jump_s": -1.0,
				"land_s": -1.0, "land": Vector3.INF, "armour_s": -1.0, "ammo_s": -1.0, "gun2_s": -1.0, "heal_s": -1.0,
				"death_s": -1.0, "cause": "alive", "start_guns": start_guns, "armor": p.armor_tier,
				"w": [], "res": [], "hp": p.bridge.state.health}
		for w in p.loadout.slots:
			rec[id]["w"].append(w)
			rec[id]["res"].append(w.reserve if w != null else 0)
		p.landed.connect(func() -> void:
			if float(rec[id]["land_s"]) < 0.0:
				rec[id]["land_s"] = game_s.call()
				rec[id]["land"] = p.global_position)
		p.shot.connect(func(_o: Vector3, _d: Vector3, _w: String) -> void:
			var w := p.loadout.get_active() if p.loadout != null else null
			last_melee[id] = w != null and w.def.is_melee())
		p.health_zeroed.connect(func(attacker: int) -> void:
			if attacker >= 0:
				blow[id] = "blade" if bool(last_melee.get(attacker, false)) else "gun")

	# ---- loot placement timing (see _Stamp) ----
	var before := _Stamp.new()
	var after := _Stamp.new()
	if m.loot != null:
		before.process_physics_priority = m.loot.process_physics_priority
		after.process_physics_priority = m.loot.process_physics_priority
		m.add_child(before)
		m.move_child(before, m.loot.get_index())
		m.add_child(after)
		m.move_child(after, m.loot.get_index() + 1)
	var place := {"count": -1, "ms": -1.0, "how": "none", "at_s": -1.0}
	var heal_items := {}  # loot id -> position, the heal items still on the ground
	var heal_unmatched := 0
	var heal_taken := 0
	var pickup_range := float(m.director.loot_cfg.get("pickup_range_m", 2.0))
	var loot_world := ""

	var key_prev := [0, "waiting"]
	var capped := false
	var trial := false
	while results.is_empty():
		if Time.get_ticks_msec() - wall_start > WALL_CAP_MS:
			capped = true
			break
		if max_game_s > 0.0 and float(game_s.call()) >= max_game_s:
			trial = true
			break
		await tree.physics_frame
		var t: float = game_s.call()
		# Loot placement: the first tick the field reports placed.
		if m.loot != null and m.loot.placed and int(place["count"]) < 0:
			place["count"] = m.loot.items.size()
			place["at_s"] = t
			if before.usec > 0 and after.usec >= before.usec:
				place["ms"] = (after.usec - before.usec) / 1000.0
				place["how"] = "stamps_around_lootfield"
			loot_world = _loot_world_line(tag, m, landmarks, nominal)
			for lid in m.loot.items:
				if str(m.loot.def(str(m.loot.items[lid]["item_id"])).get("kind", "")) == "heal":
					heal_items[lid] = m.loot.items[lid]["pos"]
		# Zone phases.
		var key := [rules.zone_phase(), rules.zone_state()]
		if key != key_prev:
			var ph := int(key[0])
			if key[1] == "shrinking":
				phase_rec[ph]["shrink_start_s"] = t
				var tc: Dictionary = rules.phase_circle(ph)
				var out_cur := 0
				var out_tgt := 0
				for b in m.bots:
					if b.life == Pawn.Life.DEAD:
						continue
					var flat := Vector2(b.global_position.x, b.global_position.z)
					if rules.is_outside(flat):
						out_cur += 1
					if flat.distance_to(tc["center"]) > float(tc["radius"]):
						out_tgt += 1
				phase_rec[ph]["outside_current"] = out_cur
				phase_rec[ph]["outside_target"] = out_tgt
			elif key[1] == "waiting" and ph != int(key_prev[0]):
				phase_rec[int(key_prev[0])]["end_s"] = t
				phase_rec[ph]["reached"] = true
				phase_rec[ph]["start_s"] = t
				phase_rec[ph]["alive_at_start"] = m.director.players_alive()
			elif key[1] == "final":
				phase_rec[ph]["end_s"] = t
			key_prev = key
		# Heal pickups: a bandage leaves the world in the same frame as a pawn within pickup range gains health.
		if m.loot != null and not heal_items.is_empty():
			var gone: Array = []
			for lid in heal_items:
				if not m.loot.items.has(lid):
					gone.append(lid)
			for lid in gone:
				var at: Vector3 = heal_items[lid]
				heal_items.erase(lid)
				heal_taken += 1
				var best := -1
				var best_d := INF
				for id in ids:
					var p: Pawn = m.director.player(id)
					if p.life == Pawn.Life.DEAD or p.bridge.state.health <= float(rec[id]["hp"]):
						continue
					var d := Vector2(p.global_position.x - at.x, p.global_position.z - at.z).length()
					if d <= pickup_range + 0.5 and absf(p.global_position.y - at.y) <= 2.5 and d < best_d:
						best = id
						best_d = d
				if best < 0:
					heal_unmatched += 1
				elif float(rec[best]["heal_s"]) < 0.0 and float(rec[best]["land_s"]) >= 0.0:
					rec[best]["heal_s"] = t - float(rec[best]["land_s"])
		# Per pawn: jump, armour, ammo, second gun, health.
		for id in ids:
			var p: Pawn = m.director.player(id)
			var r: Dictionary = rec[id]
			if float(r["jump_s"]) < 0.0 and p.drop_state == Pawn.Drop.FALLING:
				r["jump_s"] = t
			var land := float(r["land_s"])
			if land >= 0.0 and p.life != Pawn.Life.DEAD:
				if p.armor_tier > int(r["armor"]) and float(r["armour_s"]) < 0.0:
					r["armour_s"] = t - land
				var guns := 0
				var new_gun := false
				for i in p.loadout.slots.size():
					var w: Weapon = p.loadout.slots[i]
					if w == null or w.def.is_melee():
						continue
					guns += 1
					if not (r["start_guns"] as Dictionary).has(w.def.id):
						new_gun = true
					# Same gun as last frame with more reserve: an ammo pickup (a reload only lowers the reserve).
					if r["w"][i] == w and w.reserve > int(r["res"][i]) and float(r["ammo_s"]) < 0.0:
						r["ammo_s"] = t - land
				if (guns >= 2 or new_gun) and float(r["gun2_s"]) < 0.0:
					r["gun2_s"] = t - land
			r["armor"] = p.armor_tier
			for i in p.loadout.slots.size():
				var w: Weapon = p.loadout.slots[i]
				r["w"][i] = w
				r["res"][i] = w.reserve if w != null else 0
			r["hp"] = p.bridge.state.health

	var wall_s := (Time.get_ticks_msec() - wall_start) / 1000.0
	var over := not results.is_empty()
	var t_end: float = game_s.call()
	var winner: Variant = results[0]["winner"] if over else -1
	var draw: Variant = results[0]["draw"] if over else false
	var kills_total := int(tally["kills_gun"]) + int(tally["kills_blade"]) + int(tally["kills_unknown"])
	print("ML match %s trial=%s game_s=%s over=%s winner=%s draw=%s players=%d alive=%d squads_alive=%d zone_phase=%d zone_state=%s zone_r=%s zone_nominal_s=%s first_kill_s=%s first_down_s=%s first_elim_s=%s kills_total=%d kills_gun=%d kills_blade=%d kills_unknown=%d zone_deaths=%d other_deaths=%d causes=%s | wall_s=%s begin_ms=%d wall_capped=%s" % [
			tag, trial, _f(t_end), over, winner, draw, ids.size(), m.director.players_alive(), m.director.squads_alive(),
			rules.zone_phase(), rules.zone_state(), _f(rules.zone_radius()), _f(nominal), _f(tally["first_kill_s"]),
			_f(tally["first_down_s"]), _f(tally["first_elim_s"]), kills_total, tally["kills_gun"], tally["kills_blade"],
			tally["kills_unknown"], tally["zone"], tally["other"], causes, _f(wall_s), begin_ms, capped])
	if capped:
		print("ML UNFINISHED %s wall_s=%s cap_s=%d game_s=%s alive=%d squads_alive=%d zone_phase=%d of %d zone_state=%s zone_r=%s" % [
				tag, _f(wall_s), WALL_CAP_MS / 1000, _f(t_end), m.director.players_alive(), m.director.squads_alive(),
				rules.zone_phase(), rules.phase_count(), rules.zone_state(), _f(rules.zone_radius())])
	for i in phase_rec.size():
		var pr: Dictionary = phase_rec[i]
		print("ML phase %s trial=%s i=%d reached=%s start_s=%s shrink_start_s=%s end_s=%s radius=%s alive_at_start=%d outside_current_at_shrink=%d outside_target_at_shrink=%d kills_in_phase=%d zone_deaths_in_phase=%d" % [
				tag, trial, i, pr["reached"], _f(pr["start_s"]), _f(pr["shrink_start_s"]), _f(pr["end_s"]), _f(pr["radius"]),
				pr["alive_at_start"], pr["outside_current"], pr["outside_target"], pr["kills"], pr["zone_deaths"]])
	if loot_world == "":
		loot_world = "ML loot_world %s placed=-1" % tag
	print(loot_world + " | place_ms=%s place_how=%s placed_at_game_s=%s" % [_f(place["ms"]), place["how"], _f(place["at_s"])])
	# Per pawn, and the summary.
	var clusters := _cluster_centres(m, landmarks)
	var sums := {"armour": [], "ammo": [], "gun2": [], "heal": []}
	var land_d: Array = []
	var landed := 0
	for id in ids:
		var r: Dictionary = rec[id]
		var near := "none"
		var near_d := -1.0
		var at: Vector3 = r["land"]
		if float(r["land_s"]) >= 0.0:
			landed += 1
			near_d = INF
			for c: Dictionary in clusters:
				var d := Vector2(at.x, at.z).distance_to(c["at"])
				if d < near_d:
					near_d = d
					near = c["id"]
			land_d.append(near_d)
			for k: String in sums:
				var v := float(r[k + "_s"])
				if v >= 0.0:
					sums[k].append(v)
		print("ML bot %s id=%d bot=%s class=%s squad=%d jump_s=%s land_s=%s land_x=%s land_z=%s near_cluster=%s near_cluster_m=%s first_armour_s=%s first_ammo_s=%s second_gun_s=%s first_heal_s=%s death_s=%s cause=%s" % [
				tag, id, r["bot"], r["class"], r["squad"], _f(r["jump_s"]), _f(r["land_s"]),
				_f(at.x) if at != Vector3.INF else "na", _f(at.z) if at != Vector3.INF else "na", near, _f(near_d),
				_f(r["armour_s"]), _f(r["ammo_s"]), _f(r["gun2_s"]), _f(r["heal_s"]), _f(r["death_s"]), r["cause"]])
	var parts: Array[String] = []
	for k: String in ["armour", "ammo", "gun2", "heal"]:
		var vals: Array = sums[k]
		var w30 := 0
		var w60 := 0
		var mx := -1.0
		for v in vals:
			mx = maxf(mx, float(v))
			if float(v) <= 30.0:
				w30 += 1
			if float(v) <= 60.0:
				w60 += 1
		var name := "second_gun" if k == "gun2" else k
		parts.append("%s_got=%d %s_median_s=%s %s_max_s=%s %s_within30=%.2f %s_within60=%.2f" % [name, vals.size(), name, _f(_median(vals)),
				name, _f(mx), name, float(w30) / maxf(landed, 1.0), name, float(w60) / maxf(landed, 1.0)])
	print("ML loot_summary %s trial=%s landed=%d %s median_land_to_cluster_m=%s heal_taken=%d heal_unmatched=%d" % [
			tag, trial, landed, " ".join(parts), _f(_median(land_d)), heal_taken, heal_unmatched])
	m.queue_free()
	await tree.process_frame


## The landmarks the merged loot config clusters at, as {id, at: Vector2}.
static func _cluster_centres(m: MatchRoot, landmarks: Array) -> Array:
	var out: Array = []
	for cluster: Dictionary in m.director.loot_cfg.get("clusters", []):
		for lm: Dictionary in landmarks:
			if String(lm["id"]) == String(cluster["landmark"]):
				out.append({"id": String(lm["id"]), "at": Vector2(float(lm["at"][0]), float(lm["at"][1]))})
	return out


## The ML loot_world line (without its wall-clock part): items placed, per landmark (inside its radius), per
## player, and by kind (armour by tier).
func _loot_world_line(tag: String, m: MatchRoot, landmarks: Array, _nominal: float) -> String:
	var per_lm := {}
	for lm: Dictionary in landmarks:
		per_lm[String(lm["id"])] = 0
	var kinds := {}
	for lid in m.loot.items:
		var item: Dictionary = m.loot.items[lid]
		var d := m.loot.def(str(item["item_id"]))
		var kind := str(d.get("kind", "?"))
		if kind == "armor":
			kind = "armor_t%d" % int(d.get("tier", 0))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var pos: Vector3 = item["pos"]
		for lm: Dictionary in landmarks:
			if Vector2(pos.x, pos.z).distance_to(Vector2(float(lm["at"][0]), float(lm["at"][1]))) <= float(lm["radius_m"]):
				per_lm[String(lm["id"])] = int(per_lm[String(lm["id"])]) + 1
	var lm_parts: Array[String] = []
	for k in per_lm:
		lm_parts.append("%s=%d" % [k, per_lm[k]])
	var kind_keys: Array = kinds.keys()
	kind_keys.sort()
	var kind_parts: Array[String] = []
	for k in kind_keys:
		kind_parts.append("%s=%d" % [k, kinds[k]])
	var players := m.director.all_players().size()
	return "ML loot_world %s placed=%d per_player=%.1f landmarks{%s} kinds{%s}" % [tag, m.loot.items.size(),
			float(m.loot.items.size()) / maxf(players, 1.0), ",".join(lm_parts), ",".join(kind_parts)]
