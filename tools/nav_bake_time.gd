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

const RUNS := 5
const DEFAULT_MAP := "res://data/maps/alesia_section.json"


func _initialize() -> void:
	await process_frame
	var map_path := DEFAULT_MAP
	var without := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--without="):
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
	map.free()
	quit(0)
