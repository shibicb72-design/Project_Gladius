extends "res://tests/test_case.gd"
## M2B2 on demand (tests/sim, never in the normal suite): time to down. One shooter bot (its real BotBrain) and one
## target on alesia_1km, so the big-map code runs (start radius 480 > route.big_map_radius_m). The target is the
## local human pawn (no Brain): a standing Hastati, 100 shield + 100 health, no armour, never shooting, standing
## still. The shooter holds the gun under test with a full magazine and its full reserve. Every other bot has its
## Brain off and is deactivated where it spawned (Pawn.set_active(false): hidden, no collision). Each trial is a fresh match with its own match seed (1..10), so the
## brain streams are those of that seed; a trial ends when the target is downed / dead or after 30 s game time.
## Sim-local brain overrides (bots.json stays as it is), printed in SIM_TTD_SETUP: fight.band_far_frac=1.0 and
## fight.band_near_frac=1.0 (the whole sight is the near zone: the shooter strafes in place, it never closes in), and
## fight.sight_by_weapon.<gun>=<range_m> only for a case beyond the shipped sight. The first zone wait is made
## 100000 s (the zone stays "waiting", so no zone goal and the big-map switch holds). Shield regen (stats.json) is
## unchanged. The think-rate rule is as shipped: the target IS the alive human of that rule, so a shooter farther
## than think_rate.far_distance_m (60 m) from it thinks every 4th tick and never fires on coast ticks.
## One method per gun and profile, e.g.:
##   godot --headless --fixed-fps 60 --path . --script res://tests/run_tests.gd -- --dir=res://tests/sim --only=test_sim_bot_ttd.gd::test_ttd_pilum_tiro

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP := "res://data/maps/alesia_1km.json"
const BOTS_PATH := "res://data/bots.json"
const TRIALS := 10
const TRIAL_TICKS := 30 * 60
const SPOT_R := 410.0  # the fields band (inside the 480 m start circle, outside the walls and camps)
const STRAFE_CLEAR_M := 3.5  # the line of sight is also checked this far to each side of the shooter
const MAX_SLOPE_DY := 1.5  # the ground under the line varies by at most this much


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## A fresh 1 km match for one trial: no drop, no loot, the first wait made very long. Returns the MatchRoot.
func _match(seed_value: int) -> MatchRoot:
	var tree := _tree()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.seed_override = seed_value
	m.drop_from_sky = false
	m.ground_loot = false
	m.map_path_override = MAP
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config(MAP)
	m.director.mode_cfg["teams"]["mode"]["value"] = "solo"
	m.director.mode_cfg["zone"]["phases"][0]["wait_s"] = 100000.0
	assert_true(m.begin(), "begin")
	return m


static func _ground(terrain: MapTerrain, x: float, z: float) -> float:
	return terrain.height_at(x, z) if terrain != null else 0.0


## The eye-to-body ray the brain uses (_find_target): clear when it hits no world geometry.
static func _clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, eye_h: float, target_h: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from + Vector3(0.0, eye_h, 0.0), to + Vector3(0.0, target_h, 0.0), Hitscan.MASK_WORLD)
	return space.intersect_ray(q).is_empty()


## The first spot on the SPOT_R circle (every 5 degrees) where the target and a shooter `max_d` away along the
## tangent have flat ground and a clear line of sight at every case distance, also from STRAFE_CLEAR_M to each side.
## Returns {target: Vector3, dir: Vector3 (target -> shooter, flat unit)} or {} when none.
func _find_spot(m: MatchRoot, dists: Array, eye_h: float, target_h: float) -> Dictionary:
	var terrain: MapTerrain = m.map.get_node("ArtBuilder").terrain
	var space := m.get_world_3d().direct_space_state
	var max_d := 0.0
	for d in dists:
		max_d = maxf(max_d, float(d))
	for step in 72:
		var a := deg_to_rad(float(step) * 5.0)
		var t2 := Vector2(sin(a), -cos(a)) * SPOT_R
		var dir2 := Vector2(cos(a), sin(a))  # the tangent
		var tp := Vector3(t2.x, _ground(terrain, t2.x, t2.y), t2.y)
		var dir := Vector3(dir2.x, 0.0, dir2.y)
		var side := Vector3(-dir.z, 0.0, dir.x)
		var ok := true
		var lo := tp.y
		var hi := tp.y
		for i in int(max_d) + 1:
			var p := tp + dir * float(i)
			var h := _ground(terrain, p.x, p.z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
		ok = hi - lo <= MAX_SLOPE_DY
		for d in dists:
			if not ok:
				break
			for off in [0.0, -STRAFE_CLEAR_M, STRAFE_CLEAR_M]:
				var sp := tp + dir * float(d) + side * float(off)
				sp.y = _ground(terrain, sp.x, sp.z)
				if not _clear(space, sp, tp, eye_h, target_h):
					ok = false
					break
		if ok:
			return {"target": tp, "dir": dir}
	return {}


## One trial: returns {downed: bool, t_s: float, shots: int, hits: int}.
func _trial(seed_value: int, gun: String, dist: float, profile: Dictionary, overrides: Dictionary, dists: Array) -> Dictionary:
	var tree := _tree()
	var m := await _match(seed_value)
	var shooter: Pawn = m.bots[0]
	for b in m.bots:  # every other bot: Brain off, deactivated (hidden, no collision, no physics) where it spawned
		if b == shooter:
			continue
		b.get_node("Brain").set_physics_process(false)
		b.set_frame(InputFrame.new())
		b.set_active(false)
	var brain_cfg: Dictionary = DataRegistry.new().load_file(BOTS_PATH)["brain"]
	await tree.physics_frame
	var spot := _find_spot(m, dists, float(brain_cfg["eye_height_m"]), float(brain_cfg["target_height_m"]))
	assert_true(not spot.is_empty(), "a flat open spot with a clear line of sight")
	if spot.is_empty():
		m.queue_free()
		await tree.process_frame
		return {}
	var terrain: MapTerrain = m.map.get_node("ArtBuilder").terrain
	assert_true(terrain != null, "the map terrain is there (the ground heights are real)")
	var target := m.local_player
	if target.class_id != "hastati":
		target.setup("hastati", target.squad_id)
	target.apply_start_kit({"secondary": "gladius_lux"})  # no gun: it cannot shoot back; armour tier 0
	var tp: Vector3 = spot["target"]
	target.global_position = tp + Vector3(0.0, 0.05, 0.0)
	target.velocity = Vector3.ZERO
	target.visible = true
	target.set_frame(InputFrame.new())
	shooter.apply_start_kit({"primary": gun, "secondary": "gladius_lux"})  # full magazine and reserve
	var sp: Vector3 = tp + (spot["dir"] as Vector3) * dist
	sp.y = _ground(terrain, sp.x, sp.z) + 0.05
	shooter.global_position = sp
	shooter.velocity = Vector3.ZERO
	shooter.rotation.y = BotTargeting.yaw_of(tp - sp)  # facing the target: the trial measures aim, not the turn
	var brain := shooter.get_node("Brain") as BotBrain
	brain.profile = profile.duplicate(true)
	brain.cfg = brain.cfg.duplicate(true)
	for path in overrides:
		var keys: PackedStringArray = String(path).split(".")
		var d: Dictionary = brain.cfg
		for k in keys.size() - 1:
			if not d.has(keys[k]) or not d[keys[k]] is Dictionary:
				d[keys[k]] = {}
			d = d[keys[k]]
		d[keys[keys.size() - 1]] = overrides[path]
	var counts := {"shots": 0, "hits": 0}
	shooter.fired.connect(func() -> void:
		var w := shooter.loadout.get_active() if shooter.loadout != null else null
		if w != null and not w.def.is_melee():
			counts["shots"] = int(counts["shots"]) + 1)
	shooter.shot_resolved.connect(func(_o: Vector3, _e: Vector3, hit: Dictionary) -> void:
		if not hit.is_empty() and hit.get("target") == target:
			counts["hits"] = int(counts["hits"]) + 1)
	var shield := target.bridge.state.shield
	var health := target.bridge.state.health
	var n := 0
	var downed := false
	while n < TRIAL_TICKS:
		await tree.physics_frame
		n += 1
		if not target.is_alive():
			downed = true
			break
	var out := {"downed": downed, "t_s": n / 60.0, "shots": counts["shots"], "hits": counts["hits"], "spot": tp,
			"target_y": target.global_position.y, "shooter_y": shooter.global_position.y,
			"shield": shield, "health": health, "armor": target.armor_tier, "big": brain.is_big_map(), "sight": brain.sight_m()}
	m.queue_free()
	await tree.process_frame
	return out


## M2 B4: a non-empty `level` (a bots.json "difficulty" level) puts the level's accuracy and reaction_time_s over
## the profile and adds its fight.settle_s / fight.settle_floor_frac to the overrides; the lines print profile=<level>.
func _case(gun: String, dist: float, profile_name: String, dists: Array, level: String = "") -> void:
	var all := DataRegistry.new().load_file(BOTS_PATH)
	var profile: Dictionary = all["profiles"][profile_name]
	var reg := DataRegistry.new()
	var range_m := reg.get_weapon_def(gun).range_m
	var shipped_sight := minf(float(all["brain"]["fight"]["sight_by_weapon"][gun]), range_m)
	var overrides := {"fight.band_far_frac": 1.0, "fight.band_near_frac": 1.0}
	var sight_override := dist > shipped_sight
	if sight_override:
		overrides["fight.sight_by_weapon." + gun] = range_m
	if level != "":
		var lv := MatchRoot.bot_difficulty_level(level)
		assert_true(not lv.is_empty(), "difficulty level %s exists" % level)
		if lv.is_empty():
			return
		profile = profile.duplicate(true)
		profile["accuracy"] = float(lv["accuracy"])
		profile["reaction_time_s"] = float(lv["reaction_time_s"])
		overrides["fight.settle_s"] = float(lv["settle_s"])
		overrides["fight.settle_floor_frac"] = float(lv["settle_floor_frac"])
		profile_name = level
	var times: Array = []
	var shots := 0
	var hits := 0
	var never := 0
	var first: Dictionary = {}
	var wall0 := Time.get_ticks_msec()
	for s in range(1, TRIALS + 1):
		var r := await _trial(s, gun, dist, profile, overrides, dists)
		if r.is_empty():
			return
		if first.is_empty():
			first = r
		shots += int(r["shots"])
		hits += int(r["hits"])
		if bool(r["downed"]):
			times.append(float(r["t_s"]))
		else:
			never += 1
	var shown: Array[String] = []
	for k in overrides:
		shown.append("%s=%s" % [k, overrides[k]])
	var tp: Vector3 = first["spot"]
	print("SIM_TTD_SETUP gun=%s dist=%.0f profile=%s spot=(%.1f, %.1f, %.1f) end_y_target=%.2f end_y_shooter=%.2f big_map=%s sight=%.0f shipped_sight=%.0f sight_override=%s target_shield=%.0f target_health=%.0f target_armor=%d overrides=%s" % [
			gun, dist, profile_name, tp.x, tp.y, tp.z, first["target_y"], first["shooter_y"], first["big"], first["sight"], shipped_sight, sight_override,
			first["shield"], first["health"], first["armor"], ",".join(shown)])
	var mean_s := "-"
	var min_s := "-"
	var max_s := "-"
	if not times.is_empty():
		var sum := 0.0
		for t in times:
			sum += float(t)
		mean_s = "%.2f" % (sum / times.size())
		min_s = "%.2f" % times.min()
		max_s = "%.2f" % times.max()
	print("SIM_TTD gun=%s dist=%.0f profile=%s n=%d mean_s=%s min_s=%s max_s=%s never=%.2f shots_mean=%.1f hit_rate=%.3f | wall_s=%.1f" % [
			gun, dist, profile_name, TRIALS, mean_s, min_s, max_s, float(never) / TRIALS, float(shots) / TRIALS,
			float(hits) / float(shots) if shots > 0 else 0.0, (Time.get_ticks_msec() - wall0) / 1000.0])
	assert_true(bool(first["big"]), "the shooter runs the big-map code")


const PILUM_DISTS := [20.0, 50.0, 70.0]
const RIFLE_DISTS := [20.0, 50.0, 80.0, 150.0]


func test_ttd_pilum_tiro() -> void:
	for d in PILUM_DISTS:
		await _case("pilum_br", d, "tiro", PILUM_DISTS)


func test_ttd_pilum_legatus() -> void:
	for d in PILUM_DISTS:
		await _case("pilum_br", d, "legatus", PILUM_DISTS)


func test_ttd_rifle_tiro() -> void:
	for d in RIFLE_DISTS:
		await _case("sagittarii_rifle", d, "tiro", RIFLE_DISTS)


func test_ttd_rifle_legatus() -> void:
	for d in RIFLE_DISTS:
		await _case("sagittarii_rifle", d, "legatus", RIFLE_DISTS)


## M2 B4: one method per gun and bots.json difficulty level (the match_fill profile, tiro, under the level), e.g.
##   ... --only=test_sim_bot_ttd.gd::test_ttd_pilum_hard
## test_ttd_pilum_normal draws the same numbers as test_ttd_pilum_tiro (only profile= and overrides= differ).
func _level_cases(gun: String, level: String, dists: Array) -> void:
	var base := String(DataRegistry.new().load_file(BOTS_PATH)["match_fill"]["profile"])
	for d in dists:
		await _case(gun, d, base, dists, level)


func test_ttd_pilum_easy() -> void:
	await _level_cases("pilum_br", "easy", PILUM_DISTS)


func test_ttd_pilum_normal() -> void:
	await _level_cases("pilum_br", "normal", PILUM_DISTS)


func test_ttd_pilum_hard() -> void:
	await _level_cases("pilum_br", "hard", PILUM_DISTS)


func test_ttd_pilum_very_hard() -> void:
	await _level_cases("pilum_br", "very_hard", PILUM_DISTS)


func test_ttd_sagittarii_easy() -> void:
	await _level_cases("sagittarii_rifle", "easy", RIFLE_DISTS)


func test_ttd_sagittarii_normal() -> void:
	await _level_cases("sagittarii_rifle", "normal", RIFLE_DISTS)


func test_ttd_sagittarii_hard() -> void:
	await _level_cases("sagittarii_rifle", "hard", RIFLE_DISTS)


func test_ttd_sagittarii_very_hard() -> void:
	await _level_cases("sagittarii_rifle", "very_hard", RIFLE_DISTS)
