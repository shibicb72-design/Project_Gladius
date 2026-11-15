extends "res://tests/test_case.gd"
## M2L1 item 7 and the Proxies section, on demand (tests/sim, never in the normal suite; binding fixes 9, 10, 15, 21).
## Seeded 18-player matches on alesia_1km (solo and squads), the drop, ground loot and the map's overrides, with
## tests/sim/test_sim_bot_match.gd's x0.4 phase scaling; the local human idles. Each match is capped at 10 minutes
## of WALL time: an unfinished match prints over=false with how far it got and FAILS its test (the brief: matches
## must end within a bounded wall time). Plus report-only proxies for alesia_1km (no limit is checked).
## One match per method so each command stays inside a shell timeout:
##   godot --headless --path . --script res://tests/run_tests.gd -- --dir=res://tests/sim --only=test_sim_alesia_1km.gd::test_match_solo
## Methods: test_match_solo, test_match_squads, test_repeat_solo, test_repeat_squads (the repeat checks, two matches
## each; names chosen so no --only filter half-matches another), test_report_load (run it alone: cold caches),
## test_report_draw_proxy, test_report_cover_time.
## M2B1 metrics (tests/sim/sim_metrics.gd): gun_hit_rate = hits / (shots - swings); loot taken split into placed and
## dropped ids, each vanished id credited to the nearest pawn in pickup range; kill/down distances at the zeroing
## blow; --sim-profile=<tiro|miles|centurion|legatus> (after `--`) gives every bot that bots.json profile; the CPU
## proxy brain_us_per_think is printed after " | " (wall clock, never compared).

const _MatchScene := preload("res://scenes/match/match.tscn")
const _Metrics := preload("res://tests/sim/sim_metrics.gd")
const MAP := "res://data/maps/alesia_1km.json"
## The existing sim's scaling (test_sim_bot_match.gd:24-27): phases x0.4; its carrier_s 8 is br.json's 20 x 0.4,
## so here the map's own carrier_s (40, OQ-BR-DROP) gets the same x0.4 = 16 s: the opening is shortened in the
## same proportion, and the carrier still crosses 960 m (60 m/s).
const SCALE := 0.4
const WALL_CAP_MS := 10 * 60 * 1000
const SOLO_SEED := 99
const SQUADS_SEED := 199


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## The area name of a ground point for the unstick report: a landmark when inside its radius, else the nearest
## wall or aqueduct piece within 6 m (its id prefix: OuterRing, InnerRing, AquaeductusMagnus, ...), else the ring
## band (hill / inner_band / camp_ring / outer_band / fields) with its compass octant. "+raised" when the pawn
## stands over 1.5 m above the terrain (a wall walk, a deck, a ramp, a roof).
static func area_of(p: Vector3, ground_y: float, landmarks: Array, pieces: Array) -> String:
	var flat := Vector2(p.x, p.z)
	var raised := " +raised" if p.y - ground_y > 1.5 else ""
	for lm: Dictionary in landmarks:
		var at := Vector2(float(lm["at"][0]), float(lm["at"][1]))
		if flat.distance_to(at) <= float(lm["radius_m"]):
			return String(lm["name"]) + raised
	var best := ""
	var best_d := 6.0
	for piece: Dictionary in pieces:
		var d := flat.distance_to(piece["at"])
		if d < best_d:
			best_d = d
			best = String(piece["group"])
	if best != "":
		return best + raised
	var r := flat.length()
	var band := "fields"
	if r < 90.0:
		band = "hill"
	elif r < 152.0:
		band = "inner_band"
	elif r < 318.0:
		band = "camp_ring"
	elif r < 342.0:
		band = "outer_band"
	var octants := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var bearing := fposmod(rad_to_deg(atan2(p.x, -p.z)), 360.0)
	return "%s %s%s" % [band, octants[int(round(bearing / 45.0)) % 8], raised]


## Wall, gate, tower, stair and aqueduct pieces of the map as {at: Vector2, group: id prefix}.
static func _named_pieces(def: Dictionary) -> Array:
	var out: Array = []
	for entry: Dictionary in WorldKit.pieces_for(def):
		var id := String(entry["id"])
		if id.begins_with("InnerRing") or id.begins_with("OuterRing") or id.begins_with("Aqu"):
			out.append({"at": Vector2(float(entry["at"][0]), float(entry["at"][2])), "group": id.get_slice("_", 0)})
	return out


## M2B1 report fields (deterministic, appended at the end of the SIM line's deterministic part): bots that landed
## (first grounded think after the drop) inside any landmark's radius, inside the landmark they picked, and bots
## that were ever geared (armour + ammo, BotBrain._geared); enemy gun shots heard (summed over the bots).
static func route_fields(bots: Array, landmarks: Array) -> String:
	var landed := 0
	var landed_pick := 0
	var geared := 0
	var heard := 0
	for b: Pawn in bots:
		var brain := b.get_node_or_null("Brain")
		if brain == null:
			continue
		if bool(brain.get("route_geared_ever")):
			geared += 1
		heard += int(brain.get("heard_count"))
		var at: Vector3 = brain.get("route_landed_at")
		if at == Vector3.INF:
			continue
		for lm: Dictionary in landmarks:
			var c: Array = lm["at"]
			if Vector2(at.x - float(c[0]), at.z - float(c[1])).length() <= float(lm["radius_m"]):
				landed += 1
				break
		if bool(brain.get("route_landed_in_pick")):
			landed_pick += 1
	return " landed_in_landmark=%d landed_in_pick=%d geared_ever=%d heard=%d" % [landed, landed_pick, geared, heard]


static func _mean(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var s := 0.0
	for v in values:
		s += float(v)
	return s / values.size()


static func _top(counts: Dictionary, n: int) -> String:
	var keys: Array = counts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return int(counts[a]) > int(counts[b]) or (int(counts[a]) == int(counts[b]) and str(a) < str(b)))
	var parts: Array[String] = []
	for k in keys.slice(0, n):
		parts.append("%s:%d" % [k, int(counts[k])])
	return "{" + ", ".join(parts) + "}"


func _run(mode: String, seed_value: int) -> Dictionary:
	var tree := _tree()
	var def := DataRegistry.parse_quiet(MAP)
	var landmarks: Array = DataRegistry.parse_quiet(String(def["landmarks"]))["landmarks"]
	var pieces := _named_pieces(def)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.seed_override = seed_value
	m.drop_from_sky = true
	m.ground_loot = true
	m.map_path_override = MAP  # binding fix 21: the one allowed override use
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config(MAP)  # merges the map's overrides (zone, drop, loot); the scaling below survives begin()
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	var z: Dictionary = m.director.mode_cfg["zone"]
	var want_phases: Array = []
	var scale := _Metrics.cli_scale(SCALE)  # --sim-scale=1.0 plays the data's own timings (M2B1, for the rotation check)
	for ph in z["phases"]:
		ph["wait_s"] = float(ph["wait_s"]) * scale
		ph["shrink_s"] = float(ph["shrink_s"]) * scale
		want_phases.append([ph["wait_s"], ph["shrink_s"], ph["radius_m"]])
	var carrier_s := float(m.director.mode_cfg["drop"]["carrier_s"]) * scale
	m.director.mode_cfg["drop"]["carrier_s"] = carrier_s
	var causes := {}
	var kills := {"gun": 0, "blade": 0, "none": 0}
	var downs := {"gun": 0, "blade": 0, "none": 0}
	var metrics := _Metrics.new()  # shots, swings, hits, loot credit, CPU proxy (tests/sim/sim_metrics.gd)
	var fought := {}  # player id -> true once it fired or took a pawn's blow
	var blow := {}  # victim id -> "gun" | "blade": the blow that zeroed its health last
	var blow_dist := {}  # victim id -> attacker-victim 3D distance (m) at that blow
	var kill_dist := {"gun": [], "blade": []}  # eliminations by "hit" / "finished", whole metres, event order
	var down_dist := {"gun": [], "blade": []}  # downs, the same
	var zone := {"deaths": 0, "before_fight": 0}  # a dictionary: lambdas capture locals by value
	var wall_start := Time.get_ticks_msec()
	m.director.player_downed.connect(func(id: int) -> void:
		var k := String(blow.get(id, "none"))
		downs[k] = int(downs[k]) + 1
		if k != "none" and blow_dist.has(id):
			down_dist[k].append(int(blow_dist[id])))
	m.director.player_eliminated.connect(func(id: int, killer: int, cause: String) -> void:
		causes[cause] = int(causes.get(cause, 0)) + 1
		var v: Pawn = m.director.player(id)
		if cause == "zone":
			zone["deaths"] = int(zone["deaths"]) + 1
			if not fought.has(id):
				zone["before_fight"] = int(zone["before_fight"]) + 1
		elif cause == "hit" or cause == "finished":
			var k := String(blow.get(id, "none"))
			kills[k] = int(kills[k]) + 1
			if k != "none" and blow_dist.has(id):
				kill_dist[k].append(int(blow_dist[id]))
		if v != null:
			print("SIM_WHERE map=alesia_1km mode=%s seed=%d cause=%s killer=%d at=(%d, %d) r=%d game_s=%.1f" % [mode, seed_value, cause, killer, int(v.global_position.x), int(v.global_position.z), int(Vector2(v.global_position.x, v.global_position.z).length()), m.director.tick_count / 60.0]))
	var results: Array = []
	m.director.match_over.connect(func(r: Dictionary) -> void: results.append(r))
	var begin_t := Time.get_ticks_msec()
	assert_true(m.begin(), "begin %s" % mode)
	var begin_ms := Time.get_ticks_msec() - begin_t
	assert_eq(m.map_path, MAP, "the sim plays alesia_1km")
	assert_eq(m.nav_bakes, 0, "the saved 1 km mesh loads (no bake at match start)")
	# Binding fix 21: begin() does not merge again, so the sim's scaled values survive on alesia_1km.
	var got_phases: Array = []
	for ph in m.director.mode_cfg["zone"]["phases"]:
		got_phases.append([ph["wait_s"], ph["shrink_s"], ph["radius_m"]])
	assert_eq(got_phases, want_phases, "the scaled phases survive begin()")
	assert_eq(float(m.director.mode_cfg["drop"]["carrier_s"]), carrier_s, "the scaled carrier_s survives begin()")
	assert_eq(float(m.director.mode_cfg["zone"]["start_radius_m"]), 480.0, "the map's zone override is in")
	var profile := metrics.bind(m)  # --sim-profile (if given) goes onto every bot Brain here, before the first tick
	assert_true(profile != "", "--sim-profile names a data/bots.json profile (got '%s')" % _Metrics.cli_profile())
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		p.fired.connect(func() -> void: fought[id] = true)
		p.damaged.connect(func(_r: DamageRules.HitResult) -> void: fought[id] = true)
		p.health_zeroed.connect(func(attacker: int) -> void:
			if attacker >= 0:
				blow[id] = "blade" if bool(metrics.last_melee.get(attacker, false)) else "gun"
				var a: Pawn = m.director.player(attacker)
				if a != null:
					blow_dist[id] = a.global_position.distance_to(p.global_position)
				else:
					blow_dist.erase(id))
	var terrain: MapTerrain = m.map.get_node("ArtBuilder").terrain
	var goal_frames := {}
	var unstick_prev := {}  # bot player id -> _unstick_left last frame
	var unstick_per_bot := {}
	var unstick_areas := {}
	var unstick_bands := {}
	var reached_inner := {}
	var reached_hill := {}
	var n := 0
	var capped := false
	while results.is_empty():
		if Time.get_ticks_msec() - wall_start > WALL_CAP_MS:
			capped = true
			break
		await tree.physics_frame
		n += 1
		metrics.loot_step()
		for b in m.bots:
			var brain := b.get_node_or_null("Brain")
			if brain == null or not b.is_alive() or b.is_dropping():
				continue
			goal_frames[brain.goal_kind] = int(goal_frames.get(brain.goal_kind, 0)) + 1
			var left := float(brain.get("_unstick_left"))
			if left > 0.0 and float(unstick_prev.get(b.player_id, 0.0)) <= 0.0:
				unstick_per_bot[b.player_id] = int(unstick_per_bot.get(b.player_id, 0)) + 1
				var p := b.global_position
				var gy := terrain.height_at(p.x, p.z) if terrain != null else 0.0
				var area := area_of(p, gy, landmarks, pieces)
				unstick_areas[area] = int(unstick_areas.get(area, 0)) + 1
				var band := area.get_slice(" ", 0)
				unstick_bands[band] = int(unstick_bands.get(band, 0)) + 1
			unstick_prev[b.player_id] = left
			var r := Vector2(b.global_position.x, b.global_position.z).length()
			if r < 140.0:
				reached_inner[b.player_id] = true
			if r < 90.0:
				reached_hill[b.player_id] = true
	var wall_s := (Time.get_ticks_msec() - wall_start) / 1000.0
	metrics.loot_step()  # the last tick's pickups
	var goal_total := 0
	for g in goal_frames:
		goal_total += int(goal_frames[g])
	var shares := {}
	for g in goal_frames:
		shares[g] = snappedf(float(goal_frames[g]) / maxf(goal_total, 1.0), 0.01)
	var unstick_total := 0
	for id in unstick_per_bot:
		unstick_total += int(unstick_per_bot[id])
	var over := not results.is_empty()
	# Deterministic part first (compared by the repeat check); wall-clock numbers after "|".
	var line := "SIM map=alesia_1km mode=%s seed=%d profile=%s game_s=%.1f over=%s alive=%d zone_phase=%d zone_r=%.0f causes=%s kills_gun=%d kills_blade=%d kills_unknown=%d downs_gun=%d downs_blade=%d downs_unknown=%d kill_dist_gun=%s kill_dist_blade=%s down_dist_gun_mean=%.1f down_dist_blade_mean=%.1f zone_deaths=%d zone_before_fight=%d %s %s unstick=%d reached_inner=%d reached_hill=%d goals=%s%s %s" % [
			mode, seed_value, profile, n / 60.0, over, m.director.players_alive(), m.director.rules.zone_phase(), m.director.rules.zone_radius(),
			causes, kills["gun"], kills["blade"], kills["none"], downs["gun"], downs["blade"], downs["none"],
			kill_dist["gun"], kill_dist["blade"], _mean(down_dist["gun"]), _mean(down_dist["blade"]), zone["deaths"], zone["before_fight"],
			metrics.shot_fields(), metrics.loot_fields(), unstick_total, reached_inner.size(), reached_hill.size(), shares,
			route_fields(m.bots, landmarks), metrics.prop_fields()]
	print(line + " | scale=%.2f wall_s=%.1f begin_ms=%d carrier_s=%.1f wall_capped=%s %s" % [scale, wall_s, begin_ms, carrier_s, capped, metrics.cpu_fields()])
	if over:
		print("SIM result map=alesia_1km mode=%s winner=%s draw=%s" % [mode, results[0]["winner"], results[0]["draw"]])
	else:
		print("SIM UNFINISHED map=alesia_1km mode=%s seed=%d: no result after %.1f s wall (cap %d s); game_s=%.1f alive=%d squads_alive=%d zone_phase=%d of %d zone_state=%s zone_r=%.0f" % [
				mode, seed_value, wall_s, WALL_CAP_MS / 1000, n / 60.0, m.director.players_alive(), m.director.squads_alive(),
				m.director.rules.zone_phase(), m.director.rules.phase_count(), m.director.rules.zone_state(), m.director.rules.zone_radius()])
	print("SIM_UNSTICK map=alesia_1km mode=%s seed=%d total=%d bots_with_any=%d by_band=%s by_area=%s per_bot=%s" % [
			mode, seed_value, unstick_total, unstick_per_bot.size(), _top(unstick_bands, 12), _top(unstick_areas, 14), unstick_per_bot])
	m.queue_free()
	await tree.process_frame
	return {"line": line, "over": over}


func test_match_solo() -> void:
	var a := await _run("solo", SOLO_SEED)
	assert_true(bool(a["over"]), "the solo match on alesia_1km ended within the wall cap")


func test_match_squads() -> void:
	var s := await _run("squads", SQUADS_SEED)
	assert_true(bool(s["over"]), "the squads match on alesia_1km ended within the wall cap")


## The repeat check, as test_sim_bot_match.gd does it: the same seed twice in one process, the same SIM line
## (the deterministic part, before " | ").
func test_repeat_solo() -> void:
	var a := await _run("solo", SOLO_SEED)
	var b := await _run("solo", SOLO_SEED)
	print("SIM map=alesia_1km repeat_identical=%s" % (a["line"] == b["line"]))
	assert_true(bool(a["over"]) and bool(b["over"]), "both solo matches ended")
	assert_eq(a["line"], b["line"], "same seed, same match")


func test_repeat_squads() -> void:
	var a := await _run("squads", SQUADS_SEED)
	var b := await _run("squads", SQUADS_SEED)
	print("SIM map=alesia_1km mode=squads repeat_identical=%s" % (a["line"] == b["line"]))
	assert_true(bool(a["over"]) and bool(b["over"]), "both squads matches ended")
	assert_eq(a["line"], b["line"], "same seed, same match")


# --- Proxies (report only, binding fix 10: alesia_1km is in no limits test) ---

func _build_map() -> Node3D:
	var map: Node3D = load(String(DataRegistry.parse_quiet(MAP)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", MAP)
	_tree().root.add_child(map)
	return map


## Load costs on the desktop; run alone in a fresh process so the caches are cold (the terrain, paint and nav
## caches fill on first use). terrain_build_ms = the scene build minus nothing: the builder makes the terrain
## inside the build and has no separate timer, so only the parts it loads from files are apart.
func test_report_load() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	var t0 := Time.get_ticks_usec()
	var heights := MapTerrain.from_block(def["terrain"], def)
	var heights_us := Time.get_ticks_usec() - t0
	assert_true(heights != null, "the heights load")
	var settings := GroundPaint.settings_for(def)
	t0 = Time.get_ticks_usec()
	var paint := ResourceLoader.load(String(settings["baked"]), "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	var paint_us := Time.get_ticks_usec() - t0
	assert_true(paint != null, "the paint loads")
	t0 = Time.get_ticks_usec()
	var nav := MapNav.load_fresh(MAP)
	var nav_us := Time.get_ticks_usec() - t0
	assert_true(nav != null, "the saved nav is fresh and loads")
	t0 = Time.get_ticks_usec()
	var map := _build_map()
	var build_us := Time.get_ticks_usec() - t0
	await _tree().physics_frame
	map.free()
	await _tree().process_frame
	# A full 18-player match start (bots on, the drop, loot) to its first rendered frame.
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.seed_override = SOLO_SEED
	m.drop_from_sky = true
	m.ground_loot = true
	m.map_path_override = MAP
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config(MAP)
	t0 = Time.get_ticks_usec()
	assert_true(m.begin(), "an 18-player match starts on alesia_1km")
	var begin_us := Time.get_ticks_usec() - t0
	await _tree().process_frame
	var first_frame_us := Time.get_ticks_usec() - t0
	var players := m.director.all_players().size()
	await _tree().physics_frame
	await _tree().physics_frame
	var loot := m.loot.items.size() if m.loot != null else -1
	var bakes := m.nav_bakes
	m.queue_free()
	await _tree().process_frame
	print("ALESIA_1KM_LOAD desktop, headless, cold process: heights_load_us=%d paint_load_us=%d nav_load_us=%d (load_fresh: freshness hashes + load) scene_build_us=%d (instantiate + enter tree: heights, terrain build, baked paint, pieces, chunks) begin_us=%d begin_to_first_frame_us=%d players=%d nav_bakes=%d loot_after_2_ticks=%d" % [
			heights_us, paint_us, nav_us, build_us, begin_us, first_frame_us, players, bakes, loot])


## The 18-player draw and shadow proxy (tests/test_map_cull.gd test_p1c_proxy_report_only's counting) plus the
## visible-at-a-point counts from the standard points and the three L1 points, and the map-wide proxies against
## data/map_build.json's limits (report only: which ones alesia_1km would exceed).
func test_report_draw_proxy() -> void:
	var cull = preload("res://tests/test_map_cull.gd").new()
	var perf = preload("res://tests/test_astra_perf.gd").new()
	var map := _build_map()
	await _tree().physics_frame
	var counts := MapChunks.proxies(map)
	var pm: Dictionary = counts["per_map"]
	var limits: Dictionary = MapChunks.config().get("proxy_limits", {})
	var over := MapChunks.proxy_problems(counts, limits)
	var visible := MapChunks.visible_proxies(map)
	var over_visible := MapChunks.visible_problems(visible, limits.get("visible", {}))
	map.free()
	await _tree().process_frame
	var setup: Array = await perf._full_match(MAP)
	var match_scene: MatchRoot = setup[0]
	var splits: int = setup[1]
	assert_eq(match_scene.map_path, MAP, "the proxy match loaded alesia_1km")
	var total: Vector3i = cull._match_count(match_scene, splits, Vector3i.ZERO)
	var builder := match_scene.map.get_node("ArtBuilder")
	var looks: Vector3i = cull._match_count(builder.get_node("Chunks"), splits, Vector3i.ZERO)
	var terrain := builder.get_node_or_null("Terrain")
	var ground: Vector3i = cull._match_count(terrain, splits, Vector3i.ZERO) if terrain != null else Vector3i.ZERO
	var soldiers := Vector3i.ZERO
	for pawn: Pawn in match_scene.director.all_players().values():
		soldiers += cull._match_count(pawn, splits, Vector3i.ZERO)
	var ambient := builder.get_node_or_null("Ambient")
	var amb: Vector3i = cull._match_count(ambient, splits, Vector3i.ZERO) if ambient != null else Vector3i.ZERO
	var players := match_scene.director.all_players().size()
	match_scene.free()
	assert_true(total.x > 0 and int(pm["batches"]) > 0, "nonvacuous")
	print("ALESIA_1KM_PROXY match, proxy, not measured: draw=%d shadow_proxy=%d triangles=%d players=%d splits=%d chunk_looks(draw=%d,shadow=%d) terrain(draw=%d,shadow=%d) soldiers(draw=%d,shadow=%d) ambient(draw=%d,shadow=%d) batches=%d chunks=%d" % [
			total.x, total.y, total.z, players, splits, looks.x, looks.y, ground.x, ground.y, soldiers.x, soldiers.y, amb.x, amb.y, pm["batches"], pm["chunks"]])
	print("ALESIA_1KM_PROXY map-wide per_map=%s per_chunk=%s per_chunk_at=%s" % [counts["per_map"], counts["per_chunk"], counts["per_chunk_at"]])
	print("ALESIA_1KM_PROXY would exceed (report only, not in the limits test): %s" % ("; ".join(over) if not over.is_empty() else "none"))
	print("ALESIA_1KM_PROXY visible standard points would exceed: %s" % ("; ".join(over_visible) if not over_visible.is_empty() else "none"))
	failures.append_array(perf.failures)
	failures.append_array(cull.failures)


## CoverProbe time on the built 1 km map: tests/test_cover_index.gd test_cover_time_proxy's method (the same
## stands, 400 samples on a hit, median of 7, one full validation per warm run), on alesia_1km.
func test_report_cover_time() -> void:
	var h = preload("res://tests/test_cover_index.gd").new()
	var Old = preload("res://tests/test_cover_index.gd").OldProbe
	var map: Node3D = await h._build(MAP)
	var pawn: Pawn = h._pawn(map)
	var probe := CoverProbe.new()
	var old = Old.new()
	var set_: Array = []
	for xf: Transform3D in h._stands(map, map.get_node("ArtBuilder").get("terrain")):
		pawn.global_transform = xf
		if bool(old.sample(pawn, h._cfg, false)["hit"]):
			set_.append(xf)
		if set_.size() >= 400:
			break
	var olds: Array = []
	var news: Array = []
	var valids: Array = []
	var index := CoverIndex.of(_tree())
	for run in 7:
		await _tree().physics_frame
		var t0 := Time.get_ticks_usec()
		for xf: Transform3D in set_:
			pawn.global_transform = xf
			old.sample(pawn, h._cfg, false)
		var t1 := Time.get_ticks_usec()
		for xf: Transform3D in set_:
			pawn.global_transform = xf
			probe.sample(pawn, h._cfg, false)
		var t2 := Time.get_ticks_usec()
		var members := _tree().get_nodes_in_group(&"cover_wall")
		assert_true(members == index._members and index._valid(), "index valid")
		var t3 := Time.get_ticks_usec()
		olds.append(float(t1 - t0) / maxf(set_.size(), 1.0))
		news.append(float(t2 - t1) / maxf(set_.size(), 1.0))
		valids.append(float(t3 - t2))
	olds.sort()
	news.sort()
	valids.sort()
	var statics := map.find_children("*", "StaticBody3D", true, false).size()
	print("COVER_TIME map=alesia_1km.json walls=%d static_bodies=%d samples=%d old_us=%.1f index_us=%.1f full_validation_us=%.1f once per frame (median of 7, whole CoverProbe.sample on a hit)" % [
			index.size(), statics, set_.size(), olds[3], news[3], valids[3]])
	assert_true(set_.size() > 100, "nonvacuous time set")
	failures.append_array(h.failures)
	pawn.free()
	map.free()
