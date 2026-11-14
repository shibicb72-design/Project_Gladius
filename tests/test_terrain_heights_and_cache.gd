extends "res://tests/test_case.gd"
## M2P1C stop 8 (P1b carry-overs): a heights file whose grid does not fit its terrain block is a validation
## problem (DataRegistry.validate_terrain via MapTerrain.heights_file_problem) and MapTerrain.load_problem names
## it, all quietly (for_map logs that text once when a real map's terrain fails; no test triggers that here, so
## the suite log stays clean). MapTerrain's static cache holds at most one map's terrain and is emptied when a
## map builder leaves the tree; a dropped entry only costs a regeneration.

const MAP := "res://data/maps/test_300.json"
const TMP_DIR := "user://p1c_heights_tmp/"


## Every error and warning while it is attached.
class _Catcher extends Logger:
	var lines: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		lines.append("%d %s (%s:%d in %s)" % [error_type, rationale if rationale != "" else code, file, line, function])


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


func _clean() -> void:
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)


func test_a_heights_file_that_does_not_fit_is_reported_quietly() -> void:
	var good := MapTerrain.from_block(_def()["terrain"])
	assert_true(good != null and good.samples == 301, "test_300 terrain builds (301 samples a side)")
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var heights := Array(good.heights)
	var files := {
		"good": {"size_m": 300, "resolution_m": 1, "heights": heights},
		"one sample short": {"size_m": 300, "resolution_m": 1, "heights": heights.slice(0, heights.size() - 1)},
		"other size": {"size_m": 299, "resolution_m": 1, "heights": heights},
		"no heights": {"size_m": 300, "resolution_m": 1},
	}
	var needles := {"one sample short": "90600 samples", "other size": "is 299", "no heights": "no heights array"}
	var catcher := _Catcher.new()
	OS.add_logger(catcher)
	var i := 0
	for label: String in files:
		var path := TMP_DIR + "h%d.json" % i
		i += 1
		_write(path, files[label])
		var def := _def()
		def["terrain"]["height_source"] = {"type": "file", "path": path}
		var problems := DataRegistry.validate_terrain(def["terrain"], def)
		var map_problems := DataRegistry.validate_map_def(def)
		var built := MapTerrain.from_block(def["terrain"], def)
		var said := MapTerrain.load_problem(def)
		if label == "good":
			assert_eq(problems.size(), 0, "a fitting file is clean: " + ", ".join(problems))
			assert_eq(MapTerrain.heights_file_problem(path, 300.0, 1.0), "", "heights_file_problem: fits")
			assert_true(built != null and built.heights == good.heights, "a fitting file builds the same heights")
			assert_eq(said, "", "no load problem for a fitting file")
			continue
		var needle: String = needles[label]
		assert_eq(problems.size(), 1, "%s: one terrain problem: %s" % [label, ", ".join(problems)])
		assert_true(problems.size() == 1 and problems[0].contains(needle), "%s: the problem says '%s': %s" % [label, needle, ", ".join(problems)])
		assert_true(", ".join(map_problems).contains(needle), "%s: the map validation reports it" % label)
		assert_true(built == null, "%s: no terrain" % label)
		assert_true(said.contains("gives no ground") and said.contains(needle), "%s: load_problem names it: %s" % [label, said])
		# The quick path (from_block reads the file itself) skips the file read in validation but still gives none.
		assert_eq(DataRegistry.validate_terrain(def["terrain"], def, false).size(), 0, "%s: without reading the file the block itself is clean" % label)
	OS.remove_logger(catcher)
	assert_true(catcher.lines.is_empty(), "quiet: no error or warning logged: %s" % "; ".join(catcher.lines))
	_clean()


func test_cache_keeps_one_map_and_empties_when_the_map_leaves() -> void:
	MapTerrain.clear_cache()
	assert_eq(MapTerrain.cached_count(), 0, "a cleared cache is empty")
	var def := _def()
	var a := MapTerrain.for_map(def)
	assert_true(a != null and MapTerrain.cached_count() == 1, "one map cached")
	assert_true(is_same(MapTerrain.for_map(def), a), "the same map hits the cache")
	var other := _def()
	other["terrain"]["height_source"]["seed"] = 12345
	var b := MapTerrain.for_map(other)
	assert_true(b != null and b.heights != a.heights, "another block builds other heights")
	assert_eq(MapTerrain.cached_count(), 1, "a different map key drops the others")
	var again := MapTerrain.for_map(def)
	assert_true(not is_same(again, a), "the first map was dropped: a regeneration")
	assert_true(again.heights == a.heights and a.heights.size() == 301 * 301, "the regeneration gives the same heights; the held one is intact")
	# A built map: its builder holds the terrain; leaving the tree empties the cache.
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", MAP)
	tree.root.add_child(map)
	var held: MapTerrain = map.get_node("ArtBuilder").terrain
	assert_true(held != null and MapTerrain.cached_count() == 1, "the map's terrain is cached while the map lives")
	assert_true(is_same(held, again), "the builder got the cached terrain")
	map.free()
	assert_eq(MapTerrain.cached_count(), 0, "the map left the tree: the cache is empty")
	assert_true(held.heights == a.heights and held.height_at(90.0, 90.0) > 12.0, "a held terrain keeps working after the clear")
	var fresh := MapTerrain.for_map(def)
	assert_true(fresh != null and fresh.heights == held.heights and MapTerrain.cached_count() == 1, "the next map regenerates the same terrain")
	MapTerrain.clear_cache()
