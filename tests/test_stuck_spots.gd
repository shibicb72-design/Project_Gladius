extends "res://tests/test_case.gd"
## M2L1c: controlled nav walks through the 1 km map's measured stuck places (runs/M2L1C, tests/sim SIM_UNSTICK_AT).
## A real pawn (scenes/player/pawn.tscn, real physics, no brain, no cover) follows a NavigationAgent3D path on the
## saved navmesh the way BotBrain._move_direction does (next path point, flat direction, full stick, facing it) and
## must ARRIVE within a time bound, never moving less than brain stuck_min_move_m over any stuck_window_s
## (data/bots.json; the brain's unstick trigger). Builds the 1 km scene once (static, freed by the last method).
##   aqueduct ramps (the one map fault measured: a pawn beside a ramp's foot was sent onto the ramp's side, a step
##     the navmesh connects and the pawn cannot climb): from beside each foot, both sides, up onto the first span.
##   brain spots: the binding clusters whose stall is the brain's goal flip (class f in the M2L1c report); the walk
##     from the stall point to the goal it flipped from proves the ground there is passable.

const MAP := "res://data/maps/alesia_1km.json"
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const RAMP_HALF_M := 4.7  # alesia_structures.json aqueduct_ramp: the wedge 9.4 m long, 2.8 m wide, 5 m high
const RAMP_HALF_W := 1.4

## [name, start x, z, goal x, z] from the baseline events (pos, and the loot goal or 20 m toward the hunt goal).
const BRAIN_SPOTS := [
	["c1 InnerRing NW loot", -105.2, -95.9, -125.1, -79.7],
	["c2 camp_ring SE loot", 121.4, 147.4, 127.9, 149.3],
	["c3 inner_band S loot", -8.9, 151.7, -35.5, 168.2],
	["c4 inner_band SE hunt", 92.1, 93.5, 75.4, 102.9],
	["c5 camp_ring N loot", -18.6, -182.6, -9.8, -194.6],
	["c6 inner_band W loot", -102.1, -34.4, -147.1, -35.7],
	["c7 camp_ring S hunt", -16.4, 299.3, -36.4, 298.2],
	["c8 camp_ring SW loot", -88.0, 168.4, -83.8, 204.6],
	["c9 inner_band SE hunt", 49.9, 91.8, 39.2, 108.7],
	["c10 camp_ring N, under the aqueduct", 6.1, -154.0, 25.0, -150.0],  # toward its hunt goal is through the inner wall
	["c11 Castra Sexta loot", -126.1, -150.1, -147.8, -175.2],
	["c12 camp_ring W hunt", -177.9, -42.2, -161.5, -30.7],
]

static var _built: Node3D


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _map() -> Node3D:
	if is_instance_valid(_built):
		return _built
	_built = load(String(DataRegistry.parse_quiet(MAP)["scene"])).instantiate()
	_built.get_node("ArtBuilder").set("map_json", MAP)
	_tree().root.add_child(_built)
	return _built


## The saved mesh on the region, synced (as tests/test_alesia_1km.gd _nav_map).
func _nav_map() -> RID:
	var nav := _map().get_node("Nav") as NavigationRegion3D
	if nav.navigation_mesh == null or nav.navigation_mesh.resource_path != MapNav.saved_path(MAP):
		nav.navigation_mesh = MapNav.load_fresh(MAP)
		for n in Engine.physics_ticks_per_second * 2:
			await _tree().physics_frame
			if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 and \
					NavigationServer3D.map_get_closest_point(nav.get_navigation_map(), Vector3(0, 25, 5)).distance_to(Vector3(0, 25, 5)) < 1.0:
				break
	return nav.get_navigation_map()


static func _brain_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/bots.json").get("brain", {})


## The aqueduct ramps of the generated structures: [id, centre Vector3, yaw degrees].
static func ramps() -> Array:
	var out: Array = []
	var pieces: Array = DataRegistry.parse_quiet(String(DataRegistry.parse_quiet(MAP)["structure_data"]))["pieces"]
	for p: Dictionary in pieces:
		if String(p["type"]) == "aqueduct_ramp":
			out.append([String(p["id"]), LowpolyKit.vec(p["at"]), float(p["yaw"])])
	return out


## A point in a ramp's frame (local +x up the slope towards the spans, the foot at -RAMP_HALF_M).
static func ramp_point(at: Vector3, yaw: float, local: Vector3) -> Vector3:
	return at + Basis(Vector3.UP, deg_to_rad(yaw)) * local


## Walks every [name, start, goal] at once (each its own pawn and agent; keep them apart); returns
## {name: {arrived, t, stall_at, pos, path_m}}. A stall is a stuck_window_s window that moved < stuck_min_move_m.
func _walk(walks: Array, limit_s: float) -> Dictionary:
	var nav_map: RID = await _nav_map()
	var cfg := _brain_cfg()
	var window := int(float(cfg.get("stuck_window_s", 2.0)) * Engine.physics_ticks_per_second)
	var min_move := float(cfg.get("stuck_min_move_m", 0.6))
	var runs: Array = []
	for w: Array in walks:
		var start: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, w[1])
		var goal: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, w[2])
		var p: Pawn = _PawnScene.instantiate()
		p.set("_cover_auto_disabled", true)  # bots never take cover (Pawn._ensure_cover skips a pawn with a Brain)
		_map().add_child(p)
		p.global_position = Vector3(start.x, start.y - 0.4, start.z)  # the mesh floats about 0.5 m over the floor
		var agent := NavigationAgent3D.new()
		agent.path_desired_distance = float(cfg.get("path_desired_distance_m", 1.0))
		agent.target_desired_distance = float(cfg.get("target_desired_distance_m", 1.0))
		p.add_child(agent)
		var f := InputFrame.new()
		p.set_frame(f)
		var path := NavigationServer3D.map_get_path(nav_map, start, goal, true)
		var path_m := 0.0
		for i in range(1, path.size()):
			path_m += path[i - 1].distance_to(path[i])
		runs.append({"name": w[0], "pawn": p, "agent": agent, "frame": f, "goal": goal, "trail": [], "done": false,
				"result": {"arrived": false, "t": 0.0, "stall_at": "", "path_m": snappedf(path_m, 0.1), "goal": goal}})
	for i in 10:  # settle on the floor, the agents get their map
		await _tree().physics_frame
	for r: Dictionary in runs:
		(r["agent"] as NavigationAgent3D).target_position = r["goal"]
	var ticks := int(limit_s * Engine.physics_ticks_per_second)
	for t in ticks:
		await _tree().physics_frame
		var left := 0
		for r: Dictionary in runs:
			if bool(r["done"]):
				continue
			left += 1
			var p: Pawn = r["pawn"]
			var pos := p.global_position
			var trail: Array = r["trail"]
			trail.append(pos)
			var to_goal: Vector3 = r["goal"] - pos
			if Vector2(to_goal.x, to_goal.z).length() < 1.0 and absf(to_goal.y) < 1.5:
				r["done"] = true
				r["result"]["arrived"] = true
				r["result"]["t"] = snappedf(float(t) / Engine.physics_ticks_per_second, 0.01)
				(r["frame"] as InputFrame).move = Vector2.ZERO
				continue
			if trail.size() > window:
				var a: Vector3 = trail[trail.size() - 1 - window]
				if Vector2(pos.x - a.x, pos.z - a.z).length() < min_move:
					r["done"] = true
					r["result"]["stall_at"] = "(%.1f, %.1f, %.1f) t=%.1f" % [pos.x, pos.y, pos.z, float(t) / Engine.physics_ticks_per_second]
					(r["frame"] as InputFrame).move = Vector2.ZERO
					continue
			var next := (r["agent"] as NavigationAgent3D).get_next_path_position()
			var dir := next - pos
			dir.y = 0.0
			if dir.length() < 0.1:
				dir = Vector3(to_goal.x, 0.0, to_goal.z)
			if dir.length() > 0.01:
				p.rotation.y = atan2(-dir.x, -dir.z)  # face the walk (a bot looks along its move with no enemy)
				(r["frame"] as InputFrame).move = Vector2(0.0, -1.0)
		if left == 0:
			break
	var out := {}
	for r: Dictionary in runs:
		var res: Dictionary = r["result"]
		var p: Pawn = r["pawn"]
		res["pos"] = "(%.1f, %.1f, %.1f)" % [p.global_position.x, p.global_position.y, p.global_position.z]
		out[r["name"]] = res
		p.queue_free()
	await _tree().process_frame
	return out


## Every aqueduct ramp, one side at a time (both sides of a ramp meet at its foot): from beside the foot, 3.1 m off
## the centre line (1 m clear of a side guard) and 1.2 m up the slope from the foot, to the middle of the first
## span's deck (local x 9.7, the deck top 5 m).
func _ramp_walks(side: float) -> Array:
	var walks: Array = []
	for r: Array in ramps():
		var at: Vector3 = r[1]
		var yaw: float = r[2]
		var start := ramp_point(at, yaw, Vector3(-RAMP_HALF_M + 1.2, 0.5, side * (RAMP_HALF_W + 1.7)))
		var goal := ramp_point(at, yaw, Vector3(9.7, 5.5, 0.0))
		walks.append(["%s side %+d" % [r[0], int(side)], start, goal])
	return walks


func test_pawn_walks_up_every_aqueduct_ramp_from_beside_its_foot() -> void:
	assert_eq(ramps().size(), 6, "three aqueducts, a ramp at each end")
	var lines: Array[String] = []
	for side: float in [1.0, -1.0]:
		var got := await _walk(_ramp_walks(side), 25.0)
		for name: String in got:
			var r: Dictionary = got[name]
			lines.append("%s arrived=%s t=%s stall=%s path_m=%s end=%s" % [name, r["arrived"], r["t"], r["stall_at"], r["path_m"], r["pos"]])
			assert_true(bool(r["arrived"]), "%s: the pawn reaches the deck (stall %s, ended at %s, path %s m)" % [name, r["stall_at"], r["pos"], r["path_m"]])
	print("STUCK_SPOTS_RAMPS ", " | ".join(lines))


func test_pawn_walks_out_of_every_brain_stall_spot() -> void:
	var walks: Array = []
	for s: Array in BRAIN_SPOTS:
		walks.append([s[0], Vector3(s[1], 0.5, s[2]), Vector3(s[3], 0.5, s[4])])
	var got := await _walk(walks, 40.0)
	var lines: Array[String] = []
	for name: String in got:
		var r: Dictionary = got[name]
		lines.append("%s arrived=%s t=%s stall=%s path_m=%s" % [name, r["arrived"], r["t"], r["stall_at"], r["path_m"]])
		assert_true(bool(r["arrived"]), "%s: the pawn walks the nav path to the goal (stall %s, ended at %s, path %s m)" % [name, r["stall_at"], r["pos"], r["path_m"]])
	print("STUCK_SPOTS_BRAIN ", " | ".join(lines))


## Last: frees the 1 km map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
