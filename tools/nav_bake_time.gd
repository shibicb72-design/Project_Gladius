extends SceneTree
## Prints how long the map's navmesh bake takes on this machine: the same call MatchRoot.begin makes on the
## main thread at match start (scripts/systems/match_root.gd, nav.bake_navigation_mesh(false)).
## godot --headless --path . --script res://tools/nav_bake_time.gd
## A desktop number for before / after comparisons, not a phone measurement.
## "-- --without=structure" (any node group) frees that group's bodies under Nav first: the map as it baked
## before those pieces existed, on the same machine in the same state.

const RUNS := 5


func _initialize() -> void:
	await process_frame
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	root.add_child(map)
	await physics_frame
	var nav := map.get_node("Nav") as NavigationRegion3D
	var without := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--without="):
			without = arg.substr(10)
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
	print("NAV_BAKE%s runs=%d min_ms=%.1f median_ms=%.1f max_ms=%.1f polygons=%d vertices=%d bodies=%d shapes=%d" % [
			"" if without == "" else " without=" + without, RUNS, times[0], times[RUNS / 2], times[RUNS - 1], nav.navigation_mesh.get_polygon_count(),
			nav.navigation_mesh.get_vertices().size(), nav.get_child_count(), shapes])
	map.free()
	quit(0)
