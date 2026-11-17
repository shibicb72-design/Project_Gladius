extends SceneTree
## M2P1B: bakes a map's navigation mesh on this machine and saves it with its manifest (MapNav), so a match
## loads it instead of baking at match start (MatchRoot.begin). Re-run after changing any map data; the CI test
## tests/test_saved_nav.gd fails until you do.
## godot --headless --path . --script res://tools/bake_nav.gd -- --map=res://data/maps/<file>.json
## Without --map it bakes DEFAULT_MAPS (named explicitly, M2L1 binding fix 12). Prints one line per map:
## "NAV_SAVED map=<id> polygons=N vertices=N bytes=N bake_ms=N path=<res>", or "NAV_SAVED map=<path> failed:
## <reason>" and quits with 1. The manifest's tool_inputs also hold the sha256 of a binary heights .res and a
## baked ground paint .res (MapNav.input_files); the runtime never hashes those, tests/test_saved_nav.gd does.
## alesia_1km (about 6 s on the desktop, M2L1) is never re-baked by the suite: it gets the hash check only.

const DEFAULT_MAPS: Array[String] = [
	"res://data/maps/alesia_section.json",
	"res://data/maps/test_300.json",
	"res://data/maps/alesia_1km.json",
	"res://data/maps/alesia_500.json",
]


func _initialize() -> void:
	await process_frame
	var maps := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			maps.append(arg.substr(6))
	if maps.is_empty():
		maps = PackedStringArray(DEFAULT_MAPS)
	var code := 0
	for map_path in maps:
		var failure: String = await _bake(map_path)
		if failure != "":
			print("NAV_SAVED map=%s failed: %s" % [map_path, failure])
			code = 1
	quit(code)


## Bakes and saves one map; "" on success, else the reason.
func _bake(map_path: String) -> String:
	var problems := DataRegistry.new().validate_map(map_path)
	if not problems.is_empty():
		return "; ".join(problems)
	var map_def := DataRegistry.parse_quiet(map_path)
	var scene := load(String(map_def["scene"])) as PackedScene
	var map := scene.instantiate() as Node3D if scene != null else null
	var nav := map.get_node_or_null("Nav") as NavigationRegion3D if map != null else null
	if nav == null or nav.navigation_mesh == null:
		if map != null:
			map.free()
		return "scene '%s' has no Node3D root with a Nav NavigationRegion3D and a NavigationMesh" % map_def["scene"]
	var builder := map.get_node_or_null("ArtBuilder")
	if builder != null and "map_json" in builder:
		builder.set("map_json", map_path)  # before add_child: the builder reads it in _ready (as MatchRoot.begin)
	root.add_child(map)
	await physics_frame
	# A copy of the scene's own mesh, so the parse and agent settings are the scene's; the inline one stays empty.
	var mesh := nav.navigation_mesh.duplicate() as NavigationMesh
	nav.navigation_mesh = mesh
	var started := Time.get_ticks_usec()
	nav.bake_navigation_mesh(false)
	var bake_ms := (Time.get_ticks_usec() - started) / 1000.0
	map.free()
	if mesh.get_polygon_count() == 0:
		return "the bake produced no polygons"
	DirAccess.make_dir_recursive_absolute(MapNav.DIR)
	var path := MapNav.saved_path(map_path)
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		return "ResourceSaver.save(%s) returned %s" % [path, error_string(err)]
	var manifest := MapNav.manifest_for(map_path, mesh, path)
	var file := FileAccess.open(MapNav.manifest_path(map_path), FileAccess.WRITE)
	if file == null:
		return "cannot write %s: %s" % [MapNav.manifest_path(map_path), error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify(manifest, "\t", true) + "\n")
	file.close()
	var left := MapNav.stale_reasons(map_path, true)
	if not left.is_empty():
		return "still stale after saving: " + "; ".join(left)
	print("NAV_SAVED map=%s polygons=%d vertices=%d bytes=%d bake_ms=%d path=%s" % [str(map_def.get("id", map_path)),
			int(manifest["polygons"]), int(manifest["vertices"]), int(manifest["mesh_bytes"]), roundi(bake_ms), path])
	return ""
