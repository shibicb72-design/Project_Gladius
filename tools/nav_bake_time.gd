extends SceneTree
## Prints how long the map's navmesh bake takes on this machine: the same call MatchRoot.begin makes on the
## main thread at match start (scripts/systems/match_root.gd, nav.bake_navigation_mesh(false)).
## godot --headless --path . --script res://tools/nav_bake_time.gd
## A desktop number for before / after comparisons, not a phone measurement.
## "-- --map=res://data/maps/<file>.json" bakes that map's scene with ArtBuilder.map_json set to it, as
## MatchRoot.begin does (default: res://data/maps/alesia_section.json). An unusable map prints
## "NAV_BAKE map=<path> failed: <reason>" and quits with 1.
## "-- --without=structure" (any node group) frees that group's bodies under Nav first: the map as it baked
## before those pieces existed, on the same machine in the same state. Both options combine.
## M2P1B: "-- --load" also times, over the same runs, what MatchRoot.begin does instead when the saved mesh is
## fresh: the freshness check (MapNav.stale_reasons) and loading the saved mesh into the region, printed as one
## "NAV_LOAD ..." line against the bake median of this process (load_ms=-1 when there is no saved mesh).

const RUNS := 5
const DEFAULT_MAP := "res://data/maps/alesia_section.json"


func _initialize() -> void:
	await process_frame
	var map_path := DEFAULT_MAP
	var without := ""
	var time_load := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--load":
			time_load = true
		elif arg.begins_with("--without="):
			without = arg.substr(10)
		elif arg.begins_with("--map="):
			map_path = arg.substr(6)
	var problems := DataRegistry.new().validate_map(map_path)
	if not problems.is_empty():
		print("NAV_BAKE map=%s failed: %s" % [map_path, "; ".join(problems)])
		quit(1)
		return
	var map_def := DataRegistry.parse_quiet(map_path)
	var scene := load(String(map_def["scene"])) as PackedScene
	var map := scene.instantiate() as Node3D if scene != null else null
	var nav := map.get_node_or_null("Nav") as NavigationRegion3D if map != null else null
	if nav == null:
		print("NAV_BAKE map=%s failed: scene '%s' has no Node3D root with a Nav NavigationRegion3D" % [map_path, map_def["scene"]])
		if map != null:
			map.free()
		quit(1)
		return
	var builder := map.get_node_or_null("ArtBuilder")
	if builder != null and "map_json" in builder:
		builder.set("map_json", map_path)  # before add_child: the builder reads it in _ready
	root.add_child(map)
	await physics_frame
	if without != "":
		for body in nav.get_children():
			if body.is_in_group(without):
				body.free()
		await physics_frame
	var times: Array[float] = []
	for i in RUNS:
		var started := Time.get_ticks_usec()
		nav.bake_navigation_mesh(false)
		times.append((Time.get_ticks_usec() - started) / 1000.0)
	times.sort()
	var shapes := nav.find_children("*", "CollisionShape3D", true, false).size()
	print("NAV_BAKE map=%s%s runs=%d min_ms=%.1f median_ms=%.1f max_ms=%.1f polygons=%d vertices=%d bodies=%d shapes=%d" % [
			str(map_def.get("id", map_path)), "" if without == "" else " without=" + without, RUNS, times[0], times[RUNS / 2], times[RUNS - 1],
			nav.navigation_mesh.get_polygon_count(), nav.navigation_mesh.get_vertices().size(), nav.get_child_count(), shapes])
	if time_load:
		_time_load(map_path, map_def, nav, times[RUNS / 2])
	map.free()
	quit(0)


## The --load line: medians of the freshness check, the load + assign, and both together.
func _time_load(map_path: String, map_def: Dictionary, nav: NavigationRegion3D, bake_median_ms: float) -> void:
	var checks: Array[float] = []
	var loads: Array[float] = []
	var totals: Array[float] = []
	var fresh := false
	var mesh: NavigationMesh
	for i in RUNS:
		var started := Time.get_ticks_usec()
		fresh = MapNav.stale_reasons(map_path).is_empty()
		var checked := Time.get_ticks_usec()
		mesh = MapNav.load_saved(map_path)
		if mesh != null:
			nav.navigation_mesh = mesh
		var loaded := Time.get_ticks_usec()
		checks.append((checked - started) / 1000.0)
		loads.append((loaded - checked) / 1000.0 if mesh != null else -1.0)
		totals.append((loaded - started) / 1000.0)
	checks.sort()
	loads.sort()
	totals.sort()
	print("NAV_LOAD map=%s runs=%d check_ms=%.2f load_ms=%.2f load_total_ms=%.2f bake_median_ms=%.1f polygons=%d vertices=%d fresh=%s" % [
			str(map_def.get("id", map_path)), RUNS, checks[RUNS / 2], loads[RUNS / 2], totals[RUNS / 2], bake_median_ms,
			mesh.get_polygon_count() if mesh != null else 0, mesh.get_vertices().size() if mesh != null else 0, str(fresh)])
