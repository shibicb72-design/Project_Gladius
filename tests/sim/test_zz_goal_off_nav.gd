extends "res://tests/test_case.gd"
## M2B3 (OQ-BOT-FLIP), measure only, on demand: how far each SIM_UNSTICK_AT event's walk goal lies from the 1 km
## map's SAVED navmesh. Reads every *.log in the directory given after `--` as --offnav-from=<dir> (absolute path),
## parses the SIM_UNSTICK_AT lines (tests/sim/test_sim_alesia_1km.gd), loads the saved navmesh on the map scene's
## region and waits until the navigation map has synced (as tests/test_stuck_spots.gd _nav_map), then for each event
## computes the FLAT (x, z) distance from goal_pos to the nearest navmesh point.
## Storeys: the goal's storey height is its own y, except for y exactly 0 (the brain's flat circle points: zone spot,
## hunt centre and rim are built with y = 0 even on the central hill), whose storey is the ground there
## (MapTerrain.height_at; structures such as decks are not terrain). The closest-point query is made from that
## point. It is 3D, so a goal on the ground beside (or under) a raised deck could be matched to
## the deck above it with a small flat distance. A query result more than STOREY_M above or below the goal is
## therefore not trusted: the flat distance is then taken from a scan of the navmesh polygons themselves (the region's
## mesh, in world space) near the goal, counting only polygon points whose height lies within STOREY_M of the goal's
## height (the goal's own storey). The line says which: src=query or src=scan (src=none: no same-storey polygon
## within SCAN_M; flat_m is then printed as >SCAN_M).
## Prints `OFFNAV ...` for every event farther than THRESHOLD_M and one `OFFNAV_SUMMARY`. goal_pos "none" is
## skipped and counted. No arg: the test only says so and passes. Nothing here changes the game.

const MAP := "res://data/maps/alesia_1km.json"
const THRESHOLD_M := 2.0
const STOREY_M := 2.0
const SCAN_M := 40.0
const CELL_M := 8.0

var _built: Node3D
var _verts := PackedVector3Array()  # navmesh vertices, world space
var _polys: Array = []  # PackedInt32Array per polygon
var _grid := {}  # Vector2i cell -> Array of polygon indices (by the polygon's flat AABB)


func _tree() -> SceneTree:
	return Engine.get_main_loop()


static func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(name + "="):
			return a.substr(name.length() + 1)
	return ""


static func _parse_v3(s: String) -> Vector3:
	var p := s.replace("(", "").replace(")", "").split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2])) if p.size() == 3 else Vector3.INF


## The saved mesh on the 1 km map's region, synced (as tests/test_stuck_spots.gd _nav_map).
func _nav_map() -> RID:
	_built = load(String(DataRegistry.parse_quiet(MAP)["scene"])).instantiate()
	_built.get_node("ArtBuilder").set("map_json", MAP)
	_tree().root.add_child(_built)
	var nav := _built.get_node("Nav") as NavigationRegion3D
	if nav.navigation_mesh == null or nav.navigation_mesh.resource_path != MapNav.saved_path(MAP):
		nav.navigation_mesh = MapNav.load_fresh(MAP)
	for n in Engine.physics_ticks_per_second * 2:
		await _tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 and \
				NavigationServer3D.map_get_closest_point(nav.get_navigation_map(), Vector3(0, 25, 5)).distance_to(Vector3(0, 25, 5)) < 1.0:
			break
	var mesh := nav.navigation_mesh
	var xf := nav.global_transform
	for v in mesh.get_vertices():
		_verts.append(xf * v)
	for i in mesh.get_polygon_count():
		var poly := mesh.get_polygon(i)
		_polys.append(poly)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for vi in poly:
			var w := _verts[vi]
			lo = Vector2(minf(lo.x, w.x), minf(lo.y, w.z))
			hi = Vector2(maxf(hi.x, w.x), maxf(hi.y, w.z))
		for cx in range(floori(lo.x / CELL_M), floori(hi.x / CELL_M) + 1):
			for cz in range(floori(lo.y / CELL_M), floori(hi.y / CELL_M) + 1):
				var k := Vector2i(cx, cz)
				if not _grid.has(k):
					_grid[k] = []
				_grid[k].append(i)
	return nav.get_navigation_map()


## Flat closest point of triangle (a, b, c) to q (x, z), with the triangle's height there: [flat distance, point].
static func _tri_closest(q: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Array:
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	var c2 := Vector2(c.x, c.z)
	var den := (b2.y - c2.y) * (a2.x - c2.x) + (c2.x - b2.x) * (a2.y - c2.y)
	if absf(den) > 1e-9:
		var l1 := ((b2.y - c2.y) * (q.x - c2.x) + (c2.x - b2.x) * (q.y - c2.y)) / den
		var l2 := ((c2.y - a2.y) * (q.x - c2.x) + (a2.x - c2.x) * (q.y - c2.y)) / den
		var l3 := 1.0 - l1 - l2
		if l1 >= 0.0 and l2 >= 0.0 and l3 >= 0.0:
			return [0.0, Vector3(q.x, a.y * l1 + b.y * l2 + c.y * l3, q.y)]
	var best := [INF, Vector3.INF]
	for e in [[a, b], [b, c], [c, a]]:
		var p: Vector3 = e[0]
		var r: Vector3 = e[1]
		var p2 := Vector2(p.x, p.z)
		var d2 := Vector2(r.x, r.z) - p2
		var t := clampf((q - p2).dot(d2) / d2.length_squared(), 0.0, 1.0) if d2.length_squared() > 1e-12 else 0.0
		var on := p2 + d2 * t
		var dist := on.distance_to(q)
		if dist < float(best[0]):
			best = [dist, Vector3(on.x, lerpf(p.y, r.y, t), on.y)]
	return best


## The nearest navmesh point on the goal's storey by a polygon scan within SCAN_M: [flat distance, point] or [INF, INF].
func _scan_same_storey(goal: Vector3) -> Array:
	var q := Vector2(goal.x, goal.z)
	var reach := int(ceil(SCAN_M / CELL_M))
	var c0 := Vector2i(floori(goal.x / CELL_M), floori(goal.z / CELL_M))
	var seen := {}
	var best := [INF, Vector3.INF]
	for cx in range(c0.x - reach, c0.x + reach + 1):
		for cz in range(c0.y - reach, c0.y + reach + 1):
			for i in _grid.get(Vector2i(cx, cz), []):
				if seen.has(i):
					continue
				seen[i] = true
				var poly: PackedInt32Array = _polys[i]
				for t in range(1, poly.size() - 1):
					var hit := _tri_closest(q, _verts[poly[0]], _verts[poly[t]], _verts[poly[t + 1]])
					var pt: Vector3 = hit[1]
					if float(hit[0]) < float(best[0]) and absf(pt.y - goal.y) <= STOREY_M:
						best = hit
	if float(best[0]) > SCAN_M:
		return [INF, Vector3.INF]
	return best


func test_goal_off_nav() -> void:
	var dir_path := _arg("--offnav-from")
	if dir_path == "":
		print("OFFNAV skipped: no --offnav-from=<dir> after --")
		assert_true(true, "on demand only")
		return
	var dir := DirAccess.open(dir_path)
	assert_true(dir != null, "log directory opens: " + dir_path)
	if dir == null:
		return
	var names: Array = []
	for f in dir.get_files():
		if f.ends_with(".log"):
			names.append(f)
	names.sort()
	var re := RegEx.new()
	re.compile("SIM_UNSTICK_AT map=(\\S+) mode=(\\S+) seed=(-?\\d+) bot=(\\d+) game_s=([\\d.]+) pos=(\\([^)]*\\)) area=(.*?) goal=(\\S+) goal_pos=(\\([^)]*\\)|none) nav=(\\S+) next=(.*)$")
	var events: Array = []
	for f in names:
		for line in FileAccess.get_file_as_string(dir_path.path_join(f)).split("\n"):
			var mt := re.search(line.strip_edges())
			if mt != null:
				events.append(mt)
	var nav_map: RID = await _nav_map()
	var terrain := MapTerrain.for_map(DataRegistry.parse_quiet(MAP))
	var off := 0
	var none := 0
	var scanned := 0
	var max_flat := 0.0
	for mt: RegExMatch in events:
		var gp := mt.get_string(9)
		if gp == "none":
			none += 1
			continue
		var raw := _parse_v3(gp)
		# The storey: the goal's own height, except for the brain's flat circle points (zone spot, hunt centre and
		# rim, which carry y = 0 exactly) whose storey is the ground: the terrain height there.
		var goal := raw
		if raw.y == 0.0 and terrain != null:
			goal.y = terrain.height_at(raw.x, raw.z)
		var near := NavigationServer3D.map_get_closest_point(nav_map, goal)
		var flat := Vector2(near.x - goal.x, near.z - goal.z).length()
		var src := "query"
		if absf(near.y - goal.y) > STOREY_M:
			scanned += 1
			var hit := _scan_same_storey(goal)
			near = hit[1]
			flat = float(hit[0])
			src = "scan" if flat < INF else "none"
		max_flat = maxf(max_flat, flat)
		if flat > THRESHOLD_M:
			off += 1
			print("OFFNAV mode=%s seed=%s bot=%s game_s=%s goal=%s goal_pos=%s nearest=%s flat_m=%s pos=%s area=%s src=%s storey_y=%.1f" % [
					mt.get_string(2), mt.get_string(3), mt.get_string(4), mt.get_string(5), mt.get_string(8), gp,
					("(%.1f, %.1f, %.1f)" % [near.x, near.y, near.z]) if near != Vector3.INF else "none",
					("%.2f" % flat) if flat < INF else (">%.0f" % SCAN_M), mt.get_string(6), mt.get_string(7), src, goal.y])
	print("OFFNAV_SUMMARY events=%d off=%d threshold_m=%.1f goal_none=%d storey_scans=%d max_flat_m=%.2f logs=%d" % [events.size(), off, THRESHOLD_M, none, scanned, max_flat, names.size()])
	assert_true(events.size() > 0, "parsed some SIM_UNSTICK_AT lines")
	_built.free()
	_built = null
	MapTerrain.clear_cache()  # this file's for_map call: leave the cache empty, as the map's exit does
