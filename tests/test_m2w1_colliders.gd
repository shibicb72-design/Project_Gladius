extends "res://tests/test_case.gd"
## M2W1: the world-art slice changes looks only. This file rebuilds the 1 km map and compares its play space with the
## committed snapshot (data/maps/snapshots/alesia_1km_colliders.json, written by tools/m2w1_collider_snapshot.gd):
## every collision shape under Nav and ArtBuilder/Props (path, body class, groups, layer and mask, global transform,
## shape numbers, disabled), the cover_wall list, the builder's body lists and the group counts. Also: the three saved
## navigation meshes are fresh, and the ground paint's inputs hash is the recorded one.
## tests/test_alesia_1km.gd stays THE file that builds the 1 km map for its own checks; this file builds it once more
## (about half a second headless here, M2W1_COLLIDERS build_ms), as a static freed by its last method. After an
## intended collider change, rerun the snapshot tool and commit the new file with the change.

const MAP := "res://data/maps/alesia_1km.json"
const _Snap := preload("res://tools/m2w1_collider_snapshot.gd")
const _BakeTool := preload("res://tools/bake_nav.gd")
const SHOW := 10

static var _built: Node3D
static var _build_ms := 0


func _map() -> Node3D:
	if is_instance_valid(_built):
		return _built
	var tree: SceneTree = Engine.get_main_loop()
	var started := Time.get_ticks_msec()
	_built = _Snap.build_map(MAP)
	tree.root.add_child(_built)
	_build_ms = Time.get_ticks_msec() - started
	return _built


func _saved() -> Dictionary:
	return DataRegistry.parse_quiet(_Snap.snapshot_path(MAP))


func test_play_space_matches_the_snapshot() -> void:
	var saved := _saved()
	assert_true(not saved.is_empty() and saved.has("entries"), "the snapshot %s reads" % _Snap.snapshot_path(MAP))
	if saved.is_empty():
		return
	var now := _Snap.snapshot(_map(), MAP)
	var old_by_path := {}
	for e: Dictionary in saved["entries"]:
		old_by_path[String(e["p"])] = _Snap.entry_line(_normal(e))
	var new_by_path := {}
	for e: Dictionary in now["entries"]:
		new_by_path[String(e["p"])] = _Snap.entry_line(e)
	var diffs := PackedStringArray()
	var total := 0
	var paths: Array = old_by_path.keys()
	for p: String in new_by_path:
		if not old_by_path.has(p):
			paths.append(p)
	paths.sort()
	for p: String in paths:
		var was := String(old_by_path.get(p, "<missing>"))
		var is_now := String(new_by_path.get(p, "<missing>"))
		if was != is_now:
			total += 1
			if diffs.size() < SHOW:
				diffs.append("%s\n    old %s\n    new %s" % [p, was, is_now])
	assert_true(total == 0, "%d collision shapes differ from the snapshot (first %d):\n  %s" % [total, diffs.size(), "\n  ".join(diffs)])
	assert_eq((now["entries"] as Array).size(), (saved["entries"] as Array).size(), "as many collision shapes as the snapshot")
	assert_true((now["entries"] as Array).size() > 1000, "nonvacuous: %d shapes" % (now["entries"] as Array).size())
	assert_eq(String(now["entries_sha256"]), String(saved["entries_sha256"]), "the canonical entries hash")
	_compare_list("cover_wall", now["cover_wall"], saved["cover_wall"])
	for list: String in _Snap.LISTS:
		_compare_list("builder." + list, now["builder_lists"][list], (saved["builder_lists"] as Dictionary).get(list, []))
	var counts_now: Dictionary = now["group_counts"]
	var counts_old: Dictionary = saved["group_counts"]
	for g: String in counts_old:
		assert_eq(int(counts_now.get(g, 0)), int(counts_old[g]), "group %s count" % g)
	for g: String in counts_now:
		assert_true(counts_old.has(g), "group %s is new (not in the snapshot)" % g)
	print("M2W1_COLLIDERS shapes=%d cover_wall=%d entries_sha256=%s differing=%d build_ms=%d" % [(now["entries"] as Array).size(), (now["cover_wall"] as Array).size(),
			now["entries_sha256"], total, _build_ms])


## JSON reads every number as a float: the saved layer, mask back to ints so the canonical line matches.
func _normal(e: Dictionary) -> Dictionary:
	var out := e.duplicate()
	out["l"] = int(e["l"])
	out["m"] = int(e["m"])
	return out


func _compare_list(what: String, now: Array, old: Array) -> void:
	var shown := PackedStringArray()
	var total := 0
	for i in maxi(now.size(), old.size()):
		var a := String(old[i]) if i < old.size() else "<missing>"
		var b := String(now[i]) if i < now.size() else "<missing>"
		if a != b:
			total += 1
			if shown.size() < SHOW:
				shown.append("#%d old %s new %s" % [i, a, b])
	assert_true(total == 0, "%s: %d places differ from the snapshot (first %d): %s" % [what, total, shown.size(), "; ".join(shown)])


## The ground paint's inputs (GroundPaint.inputs_hash: the art_materials.json "ground" numbers with the map's
## ground_paint keys, the ground size, the landmarks and the trodden points) are the recorded ones, and the baked
## paint still carries them (a changed "ground" key would repaint at load and change the footstep surfaces).
func test_ground_paint_inputs_are_unchanged() -> void:
	var saved := _saved()
	var want := String(saved.get("ground_paint_inputs_sha256", ""))
	var now := _Snap.ground_paint_hash(_map(), MAP)
	assert_true(want != "", "the snapshot records the ground paint inputs hash")
	assert_eq(now, want, "GroundPaint.inputs_hash of alesia_1km")
	var baked := String(GroundPaint.settings_for(DataRegistry.parse_quiet(MAP)).get("baked", ""))
	var image := ResourceLoader.load(baked, "", ResourceLoader.CACHE_MODE_IGNORE) as Image if baked != "" else null
	assert_true(image != null and String(image.get_meta(&"inputs_sha256", "")) == now, "the baked paint %s carries that hash" % baked)
	print("M2W1_GROUND_PAINT map=%s inputs_sha256=%s baked=%s" % [MAP, now, baked])


## The three saved navigation meshes are fresh (runtime and tool inputs and the mesh's own hash), as
## tests/test_saved_nav.gd checks; their mesh hashes are printed for the slice report.
func test_the_three_navigation_meshes_are_fresh() -> void:  # not "saved_nav": --only=test_saved_nav must not pick it
	for map_path: String in _BakeTool.DEFAULT_MAPS:
		var reasons := MapNav.stale_reasons(map_path, true)
		assert_true(reasons.is_empty(), "%s: saved navigation is stale: %s" % [map_path, "; ".join(reasons)])
		var manifest := DataRegistry.parse_quiet(MapNav.manifest_path(map_path))
		print("M2W1_NAV map=%s mesh_sha256=%s polygons=%s fresh=%s" % [map_path, manifest.get("mesh_sha256", ""), str(manifest.get("polygons", "")), reasons.is_empty()])
	assert_eq(_BakeTool.DEFAULT_MAPS.size(), 4, "four saved maps (M2L2a: alesia_500 joined the three)")


## The snapshot file is no input of any saved navigation manifest (it must never make a mesh stale).
func test_snapshot_is_no_navigation_input() -> void:
	for map_path: String in _BakeTool.DEFAULT_MAPS:
		var files := MapNav.input_files(map_path)
		for kind: String in ["runtime", "tool"]:
			assert_true(not (_Snap.snapshot_path(MAP) in files[kind]), "%s: the snapshot is not a %s input" % [map_path, kind])


## Last in this file: frees the map so later suite files start clean.
func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	assert_eq(MapTerrain.cached_count(), 0, "the terrain cache is empty after the map left")
