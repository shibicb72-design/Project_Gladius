extends SceneTree
## M2L1c: where do bots get stuck on a map, and what is there. Read-only: builds the map as a match does (MatchRoot
## .begin: the scene, ArtBuilder with map_json, so cover, breakables, chests and kit pieces; then the saved
## navigation mesh from MapNav.load_fresh) and prints; it writes no file.
##   godot --headless --path . --script res://tools/unstick_probe.gd -- --at="x,z;x,z" [--radius=6]
##   godot --headless --path . --script res://tools/unstick_probe.gd -- --from=<log or dir> [--from=...] [--top=5]
## --at: positions as x,z (terrain height) or x,y,z, separated by ';' (or '|', which godot.cmd's cmd.exe eats), or
## one --at per position. --from: SIM_UNSTICK_AT lines (from
## tests/sim/test_sim_alesia_1km.gd) in a log, or every *.log / *.txt in a directory (sorted by name). With --from
## it prints the cluster table (greedy, input order, --cluster-m=8 around each cluster's first event), then a PROBE
## block for each of the --top=N biggest clusters (--top=0: table only, the map is not built). --map=<json> picks
## another map (default alesia_1km). Deterministic: no random numbers, fixed input order, sorted output.

const DEFAULT_MAP := "res://data/maps/alesia_1km.json"
const PAWN_SCENE := "res://scenes/player/pawn.tscn"
const PAWN_RADIUS_AT := "scenes/player/pawn.tscn:10 (CapsuleShape3D body_shape radius)"
const STEP_FILE := "res://data/physics_baseline.json"
const STEP_AT := "data/physics_baseline.json:9 (max_step_up_m, measured by tests/test_physics_baseline.gd:57)"
const SLOPE_AT := "CharacterBody3D floor_max_angle default (scripts/classes/pawn.gd sets none)"
const GRID := 5  # nav samples per collider footprint: GRID x GRID
const SNAP_M := 0.3  # a footprint sample "has nav" when the closest navmesh point is this close horizontally
const LARGE_M := 250.0  # shapes this wide on both axes are terrain: skipped
const STEP_SPACING := 0.25
const WALL_M := 1.2  # a rise above this between two samples is a wall, not a step
const NAV_LIFT_M := 0.75  # the baked navmesh lies up to this far above the collision surface it was baked on

var _map: Node3D
var _nav: NavigationRegion3D
var _terrain: Variant
var _shapes: Array = []  # {body, shape_node, foot: PackedVector2Array, aabb: AABB, local: AABB, xform}
var _pawn_r := 0.4
var _max_step := 0.12
var _slope_tan := 1.0
var _re_at := RegEx.new()
var _re_v := RegEx.new()


func _initialize() -> void:
	await process_frame
	_re_at.compile("^SIM_UNSTICK_AT map=(\\S+) mode=(\\S+) seed=(-?\\d+) bot=(-?\\d+) game_s=([-\\d.]+) pos=(\\([^)]*\\)) area=(.*) goal=(\\S*) goal_pos=(\\([^)]*\\)|\\S+) nav=(\\S+) next=(.*)$")
	_re_v.compile("\\(\\s*(-?[\\d.]+),\\s*(-?[\\d.]+),\\s*(-?[\\d.]+)\\s*\\)")
	var map_path := DEFAULT_MAP
	var radius := 6.0
	var top := 5
	var cluster_m := 8.0
	var froms := PackedStringArray()
	var points: Array = []  # {p: Vector3, has_y: bool, source: String}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			map_path = arg.substr(6)
		elif arg.begins_with("--radius="):
			radius = float(arg.substr(9))
		elif arg.begins_with("--top="):
			top = int(arg.substr(6))
		elif arg.begins_with("--cluster-m="):
			cluster_m = float(arg.substr(12))
		elif arg.begins_with("--from="):
			froms.append(arg.substr(7))
		elif arg.begins_with("--at="):
			for item in arg.substr(5).replace("|", ";").split(";", false):
				var n := item.strip_edges().split(",", false)
				if n.size() == 2:
					points.append({"p": Vector3(float(n[0]), 0.0, float(n[1])), "has_y": false, "source": "at"})
				elif n.size() == 3:
					points.append({"p": Vector3(float(n[0]), float(n[1]), float(n[2])), "has_y": true, "source": "at"})
				else:
					print("PROBE bad --at item '%s' (want x,z or x,y,z)" % item)
	if froms.is_empty() and points.is_empty():
		print("unstick_probe: give --at=x,z;... and/or --from=<log or dir>")
		quit(1)
		return
	if not froms.is_empty():
		var events := _read_events(froms)
		var clusters := _cluster(events, cluster_m)
		_print_clusters(clusters, events.size(), cluster_m)
		for i in mini(top, clusters.size()):
			points.append({"p": clusters[i]["centre"], "has_y": true, "source": "cluster#%d events=%d" % [i + 1, clusters[i]["events"].size()]})
	if points.is_empty():
		quit(0)
		return
	var failure: String = await _build(map_path)
	if failure != "":
		print("PROBE map=%s failed: %s" % [map_path, failure])
		quit(1)
		return
	for pt: Dictionary in points:
		var p: Vector3 = pt["p"]
		if not bool(pt["has_y"]):
			p.y = _ground(p.x, p.z)
		await physics_frame
		_probe(p, radius, String(pt["source"]))
	_map.free()
	quit(0)


# --- Cluster mode ---

func _read_events(froms: PackedStringArray) -> Array:
	var files := PackedStringArray()
	for f in froms:
		if DirAccess.dir_exists_absolute(f):
			var names := Array(DirAccess.get_files_at(f))
			names.sort()
			for nm: String in names:
				if nm.ends_with(".log") or nm.ends_with(".txt"):
					files.append(f.path_join(nm))
		else:
			files.append(f)
	var out: Array = []
	for path in files:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			print("UNSTICK_CLUSTERS cannot read %s: %s" % [path, error_string(FileAccess.get_open_error())])
			continue
		while not file.eof_reached():
			var m := _re_at.search(file.get_line().strip_edges())
			if m == null:
				continue
			out.append({"mode": m.get_string(2), "seed": int(m.get_string(3)), "bot": int(m.get_string(4)),
					"game_s": float(m.get_string(5)), "pos": _vec(m.get_string(6)), "area": m.get_string(7),
					"goal": m.get_string(8), "nav": m.get_string(10), "file": path.get_file()})
	return out


func _cluster(events: Array, within: float) -> Array:
	var clusters: Array = []
	for e: Dictionary in events:
		var p: Vector3 = e["pos"]
		var home: Dictionary = {}
		for c: Dictionary in clusters:
			var a: Vector3 = c["anchor"]
			if Vector2(a.x - p.x, a.z - p.z).length() <= within:
				home = c
				break
		if home.is_empty():
			home = {"anchor": p, "events": []}
			clusters.append(home)
		home["events"].append(e)
	for c: Dictionary in clusters:
		var sum := Vector3.ZERO
		for e: Dictionary in c["events"]:
			sum += e["pos"]
		c["centre"] = sum / float(c["events"].size())
	clusters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["events"].size() != b["events"].size():
			return a["events"].size() > b["events"].size()
		if a["centre"].x != b["centre"].x:
			return a["centre"].x < b["centre"].x
		return a["centre"].z < b["centre"].z)
	return clusters


func _print_clusters(clusters: Array, total: int, within: float) -> void:
	print("UNSTICK_CLUSTERS events=%d clusters=%d cluster_m=%.1f (greedy around each cluster's first event, input order; sorted by events)" % [total, clusters.size(), within])
	var rank := 0
	for c: Dictionary in clusters:
		rank += 1
		var bots := {}
		var runs := {}
		var areas := {}
		var goals := {}
		var nav := {}
		for e: Dictionary in c["events"]:
			var run := "%s:%d" % [e["mode"], e["seed"]]
			bots[run + ":" + str(e["bot"])] = true
			runs[run] = int(runs.get(run, 0)) + 1
			areas[e["area"]] = int(areas.get(e["area"], 0)) + 1
			goals[e["goal"]] = int(goals.get(e["goal"], 0)) + 1
			nav[e["nav"]] = int(nav.get(e["nav"], 0)) + 1
		print("CLUSTER rank=%d centre=%s events=%d bots=%d runs=%s areas=%s goals=%s nav=%s" % [rank, _v3(c["centre"]),
				c["events"].size(), bots.size(), _sorted(runs), _sorted(areas), _sorted(goals), _sorted(nav)])


## A count dictionary as "{key:n, ...}", biggest first, then by key.
static func _sorted(counts: Dictionary) -> String:
	var keys := counts.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		if counts[a] != counts[b]:
			return counts[a] > counts[b]
		return str(a) < str(b))
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s:%d" % [k, counts[k]])
	return "{" + ", ".join(parts) + "}"


# --- Map build and probe ---

func _build(map_path: String) -> String:
	var def := DataRegistry.parse_quiet(map_path)
	var scene := load(String(def.get("scene", ""))) as PackedScene
	if scene == null:
		return "no scene"
	_map = scene.instantiate() as Node3D
	var builder := _map.get_node_or_null("ArtBuilder")
	if builder != null and "map_json" in builder:
		builder.set("map_json", map_path)  # before add_child, as MatchRoot.begin
	root.add_child(_map)
	_nav = _map.get_node_or_null("Nav") as NavigationRegion3D
	if _nav == null:
		return "no Nav region"
	var saved := MapNav.load_fresh(map_path)
	if saved == null:
		return "saved navigation missing or stale: " + "; ".join(MapNav.last_reasons)
	_nav.navigation_mesh = saved
	_terrain = builder.get("terrain") if builder != null and "terrain" in builder else null
	# Wait for the server to hold the region's polygons (region iterations can be asynchronous): the closest point
	# to the mesh's first vertex must be that vertex.
	var rid := _nav.get_navigation_map()
	var first: Vector3 = _nav.global_transform * saved.get_vertices()[saved.get_polygon(0)[0]]
	var synced := false
	for i in 1200:
		await physics_frame
		if NavigationServer3D.map_get_iteration_id(rid) == 0:
			continue  # no query before the first synchronization (the server errors)
		if NavigationServer3D.map_get_closest_point(rid, first).distance_to(first) < 0.05:
			synced = true
			break
	if not synced:
		return "the navigation map never synced the saved mesh (1200 physics frames)"
	var pawn_scene := load(PAWN_SCENE) as PackedScene
	var pawn := pawn_scene.instantiate() if pawn_scene != null else null
	if pawn != null:
		var cs := pawn.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs != null and cs.shape is CapsuleShape3D:
			_pawn_r = (cs.shape as CapsuleShape3D).radius
		if pawn is CharacterBody3D:
			_slope_tan = tan((pawn as CharacterBody3D).floor_max_angle)
		pawn.free()
	var base := DataRegistry.parse_quiet(STEP_FILE)
	if base.has("max_step_up_m"):
		_max_step = float(base["max_step_up_m"])
	var skipped := PackedStringArray()
	for node in _map.find_children("*", "CollisionShape3D", true, false):
		var cs := node as CollisionShape3D
		var body := cs.get_parent() as PhysicsBody3D
		if body == null or cs.disabled or cs.shape == null:
			continue
		var local := _local_aabb(cs.shape)
		var xf := cs.global_transform
		var world := xf * local
		if world.size.x > LARGE_M and world.size.z > LARGE_M:
			skipped.append(String(body.name))
			continue
		var foot := PackedVector2Array()
		for c in [Vector3(local.position.x, 0, local.position.z), Vector3(local.end.x, 0, local.position.z),
				Vector3(local.end.x, 0, local.end.z), Vector3(local.position.x, 0, local.end.z)]:
			var w: Vector3 = xf * c
			foot.append(Vector2(w.x, w.z))
		_shapes.append({"body": body, "shape": cs, "foot": foot, "aabb": world, "local": local, "xform": xf})
	var mesh := _nav.navigation_mesh
	print("PROBE_MAP map=%s shapes=%d skipped_terrain=%s nav_polygons=%d navmesh(agent_radius=%.2f agent_height=%.2f agent_max_climb=%.2f agent_max_slope=%.1f cell_size=%.2f cell_height=%.2f, saved %s) pawn_radius=%.2f diameter=%.2f [%s] max_step_up_m=%.2f [%s] floor_max_slope=%.0f deg [%s]" % [
			def.get("id", map_path), _shapes.size(), skipped, mesh.get_polygon_count(), mesh.agent_radius, mesh.agent_height,
			mesh.agent_max_climb, mesh.agent_max_slope, mesh.cell_size, mesh.cell_height, MapNav.saved_path(map_path),
			_pawn_r, _pawn_r * 2.0, PAWN_RADIUS_AT, _max_step, STEP_AT, rad_to_deg(atan(_slope_tan)), SLOPE_AT])
	return ""


func _probe(p: Vector3, radius: float, source: String) -> void:
	var gy := _ground(p.x, p.z)
	var rid := _nav.get_navigation_map()
	var closest := NavigationServer3D.map_get_closest_point(rid, p)
	print("PROBE at=%s source=%s radius_m=%.1f terrain_y=%.2f above_terrain=%.2f" % [_v3(p), source, radius, gy, p.y - gy])
	print("  nav_closest=%s dist=%.2f horiz=%.2f dy=%.2f" % [_v3(closest), closest.distance_to(p),
			Vector2(closest.x - p.x, closest.z - p.z).length(), closest.y - p.y])
	var flat := Vector2(p.x, p.z)
	var near: Array = []
	for s: Dictionary in _shapes:
		var d := _poly_dist(flat, s["foot"])
		if d <= radius:
			near.append([d, s])
	near.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return str(a[1]["shape"].get_path()) < str(b[1]["shape"].get_path()))
	print("  colliders_within_radius=%d" % near.size())
	var blocking: Array = []
	for item: Array in near:
		var s: Dictionary = item[1]
		var body: PhysicsBody3D = s["body"]
		var box: AABB = s["aabb"]
		var groups := PackedStringArray()
		for g in body.get_groups():
			if not String(g).begins_with("_"):
				groups.append(String(g))
		var prop := String(body.get("prop_id")) if "prop_id" in body else ""
		var cls := body.get_class()
		var script := body.get_script() as Script
		if script != null and script.get_global_name() != &"":
			cls = String(script.get_global_name())
		var nav_counts := _nav_in_footprint(s)
		var piece_gy := _ground(box.get_center().x, box.get_center().z)
		print("  COLLIDER id=%s class=%s%s shape=%s path=%s groups=%s in_nav=%s dist_m=%.2f aabb_min=%s aabb_max=%s size=%s top_above_ground=%.2f bottom_above_ground=%.2f nav_under=%d/%d nav_top=%d/%d" % [
				body.name, cls, (" prop_id=" + prop) if prop != "" else "", s["shape"].shape.get_class(), _map.get_path_to(s["shape"]),
				groups, _nav.is_ancestor_of(body), item[0], _v3(box.position), _v3(box.end), _v3(box.size), box.end.y - piece_gy,
				box.position.y - piece_gy,
				nav_counts[0], GRID * GRID, nav_counts[1], GRID * GRID])
		if box.end.y > gy + _max_step and box.position.y < gy + 1.6:
			blocking.append(s)
	_print_gaps(blocking)
	_print_steps(p, minf(radius, 6.0))


## Nav points that snap into a collider's footprint: [at ground level (a polygon under it), on its top].
func _nav_in_footprint(s: Dictionary) -> Array:
	var rid := _nav.get_navigation_map()
	var local: AABB = s["local"]
	var xf: Transform3D = s["xform"]
	var top: float = s["aabb"].end.y
	var under := 0
	var on_top := 0
	for i in GRID:
		for j in GRID:
			var u := (i + 0.5) / GRID * 0.8 + 0.1  # inset 10% at each side
			var v := (j + 0.5) / GRID * 0.8 + 0.1
			var w: Vector3 = xf * Vector3(lerpf(local.position.x, local.end.x, u), local.position.y, lerpf(local.position.z, local.end.z, v))
			var gy := _ground(w.x, w.z)
			var c := NavigationServer3D.map_get_closest_point(rid, Vector3(w.x, gy + 0.1, w.z))
			# The baked surface floats up to NAV_LIFT_M over the collision surface (cell_height steps).
			if Vector2(c.x - w.x, c.z - w.z).length() <= SNAP_M and c.y - gy >= -0.6 and c.y - gy <= NAV_LIFT_M and c.y < top - 0.15:
				under += 1
			c = NavigationServer3D.map_get_closest_point(rid, Vector3(w.x, top + 0.1, w.z))
			if Vector2(c.x - w.x, c.z - w.z).length() <= SNAP_M and c.y - top >= -0.2 and c.y - top <= NAV_LIFT_M:
				on_top += 1
	return [under, on_top]


## The narrowest horizontal gaps between neighbouring colliders that block a pawn's body (top above the step
## height, bottom below 1.6 m over the ground), against the pawn capsule and the nav agent diameters.
func _print_gaps(blocking: Array) -> void:
	var pair_gap := {}  # "a|b" (body names sorted) -> the smallest gap between any of their shapes
	for i in blocking.size():
		for j in range(i + 1, blocking.size()):
			var a: Dictionary = blocking[i]
			var b: Dictionary = blocking[j]
			if a["body"] == b["body"]:
				continue
			var names := [String(a["body"].name), String(b["body"].name)]
			names.sort()
			var key := "%s|%s" % names
			pair_gap[key] = minf(float(pair_gap.get(key, INF)), _poly_poly(a["foot"], b["foot"]))
	var gaps: Array = []
	var touching := 0
	for key: String in pair_gap:
		if float(pair_gap[key]) <= 0.01:
			touching += 1
		else:
			gaps.append([pair_gap[key], key.get_slice("|", 0), key.get_slice("|", 1)])
	gaps.sort_custom(func(x: Array, y: Array) -> bool:
		if x[0] != y[0]:
			return x[0] < y[0]
		return x[1] + x[2] < y[1] + y[2])
	var agent_d := _nav.navigation_mesh.agent_radius * 2.0
	print("  gaps blocking_colliders=%d touching_pairs=%d pawn_d=%.2f agent_d=%.2f" % [blocking.size(), touching, _pawn_r * 2.0, agent_d])
	for k in mini(6, gaps.size()):
		var g: Array = gaps[k]
		print("  GAP a=%s b=%s gap_m=%.2f pawn_fits=%s agent_fits=%s" % [g[1], g[2], g[0], g[0] >= _pawn_r * 2.0, g[0] >= agent_d])


## Height steps of the walkable surface (rays down, colliders and terrain) on a grid around p: rises between
## neighbouring samples over max_step_up_m and steeper than floor_max_angle, up to WALL_M (taller is a wall).
func _print_steps(p: Vector3, r: float) -> void:
	var space := root.get_world_3d().direct_space_state
	var n := int(ceil(r / STEP_SPACING))
	var from_y := maxf(p.y, _ground(p.x, p.z)) + WALL_M
	var h := {}
	var hits := 0
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var x := p.x + i * STEP_SPACING
			var z := p.z + j * STEP_SPACING
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - WALL_M - 5.0, z))
			q.hit_from_inside = true
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				hits += 1
			if hit.is_empty():
				h[Vector2i(i, j)] = _ground(x, z)
			elif (hit["normal"] as Vector3) == Vector3.ZERO:
				h[Vector2i(i, j)] = INF  # the ray starts inside a solid: wall
			else:
				h[Vector2i(i, j)] = float(hit["position"].y)
	var steps := 0
	var best := 0.0
	var best_at := ""
	var climb := _nav.navigation_mesh.agent_max_climb
	var over_climb := 0
	var nav_steps := 0
	for key: Vector2i in h:
		for nb in [Vector2i(1, 0), Vector2i(0, 1)]:
			var other: Vector2i = key + nb
			if not h.has(other) or is_inf(h[key]) or is_inf(h[other]):
				continue
			var d := absf(float(h[key]) - float(h[other]))
			if d > _max_step and d <= WALL_M and d / STEP_SPACING > _slope_tan:
				steps += 1
				if d > climb:
					over_climb += 1
				var pa := Vector3(p.x + key.x * STEP_SPACING, h[key], p.z + key.y * STEP_SPACING)
				var pb := Vector3(p.x + other.x * STEP_SPACING, h[other], p.z + other.y * STEP_SPACING)
				if _on_nav(pa) and _on_nav(pb):
					nav_steps += 1  # the navmesh covers both sides: a path may lead the pawn up this step
				if d > best:
					best = d
					best_at = "%s-%s" % [_v3(Vector3(p.x + key.x * STEP_SPACING, h[key], p.z + key.y * STEP_SPACING)),
							_v3(Vector3(p.x + other.x * STEP_SPACING, h[other], p.z + other.y * STEP_SPACING))]
	print("  steps grid_r=%.1f spacing=%.2f samples=%d ray_hits=%d steps_over_max_step=%d (over agent_max_climb %.2f: %d; navmesh on both sides: %d) biggest=%.2f at=%s" % [
			r, STEP_SPACING, h.size(), hits, steps, climb, over_climb, nav_steps, best, best_at if best_at != "" else "none"])


## True when the navmesh lies on this surface point (within SNAP_M horizontally, at most NAV_LIFT_M above).
func _on_nav(q: Vector3) -> bool:
	var c := NavigationServer3D.map_get_closest_point(_nav.get_navigation_map(), q + Vector3(0, 0.1, 0))
	return Vector2(c.x - q.x, c.z - q.z).length() <= SNAP_M and c.y - q.y >= -0.3 and c.y - q.y <= NAV_LIFT_M


# --- Helpers ---

func _ground(x: float, z: float) -> float:
	return (_terrain as MapTerrain).height_at(x, z) if _terrain is MapTerrain else 0.0


static func _local_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var s := (shape as BoxShape3D).size
		return AABB(-s * 0.5, s)
	if shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		return AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius), Vector3(c.radius * 2.0, c.height, c.radius * 2.0))
	if shape is CapsuleShape3D:
		var k := shape as CapsuleShape3D
		return AABB(Vector3(-k.radius, -k.height * 0.5, -k.radius), Vector3(k.radius * 2.0, k.height, k.radius * 2.0))
	if shape is SphereShape3D:
		var r := (shape as SphereShape3D).radius
		return AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0)
	var pts := PackedVector3Array()
	if shape is ConvexPolygonShape3D:
		pts = (shape as ConvexPolygonShape3D).points
	elif shape is ConcavePolygonShape3D:
		pts = (shape as ConcavePolygonShape3D).get_faces()
	if not pts.is_empty():
		var box := AABB(pts[0], Vector3.ZERO)
		for q in pts:
			box = box.expand(q)
		return box
	var mesh := shape.get_debug_mesh()
	return mesh.get_aabb() if mesh != null else AABB()


## Horizontal distance from a point to a convex footprint (0 inside).
static func _poly_dist(p: Vector2, poly: PackedVector2Array) -> float:
	if Geometry2D.is_point_in_polygon(p, poly):
		return 0.0
	var best := INF
	for i in poly.size():
		var c := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		best = minf(best, p.distance_to(c))
	return best


## Horizontal distance between two convex footprints (0 when they touch or overlap).
static func _poly_poly(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if not Geometry2D.intersect_polygons(a, b).is_empty():
		return 0.0
	var best := INF
	for q in a:
		best = minf(best, _poly_dist(q, b))
	for q in b:
		best = minf(best, _poly_dist(q, a))
	return best


func _vec(text: String) -> Vector3:
	var m := _re_v.search(text)
	return Vector3(float(m.get_string(1)), float(m.get_string(2)), float(m.get_string(3))) if m != null else Vector3.ZERO


static func _v3(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]
