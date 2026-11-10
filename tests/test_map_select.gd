extends "res://tests/test_case.gd"
## Which map a match loads (data/map_select.json, the phone override file) and the per-map piece and ground keys.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _MapScene := preload("res://scenes/maps/alesia_section.tscn")
const TMP_DIR := "user://p1a_test_tmp/"
const NO_FILE := "user://p1a_test_tmp/does_not_exist.json"


func _write(name: String, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var path := TMP_DIR + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func _clean() -> void:
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)


func _new_match() -> MatchRoot:  # call with await; same setup as test_match_scene.gd
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	return m


func test_map_select_defaults_to_alesia() -> void:
	var data := DataRegistry.new().load_file(DataRegistry.MAP_SELECT_PATH)
	assert_eq(str(data.get("map", "")), MatchRoot.MAP_PATH, "map_select.json names alesia_section")
	var chosen := MatchRoot.select_map(DataRegistry.MAP_SELECT_PATH, NO_FILE)
	assert_eq(chosen["path"], MatchRoot.MAP_PATH, "selected path")
	assert_eq(chosen["error"], "", "no error")


func test_no_stale_override_on_this_machine() -> void:
	assert_true(not FileAccess.file_exists(MatchRoot.MAP_OVERRIDE_PATH),
			"%s exists: a leftover override would switch every match test to another map; delete it" % MatchRoot.MAP_OVERRIDE_PATH)


func test_override_wins_over_map_select() -> void:
	var select := _write("select.json", '{"map": "res://data/maps/nope.json"}')
	var alone := MatchRoot.select_map(select, NO_FILE)
	assert_eq(alone["path"], MatchRoot.MAP_PATH, "select alone falls back")
	assert_true(String(alone["error"]) != "", "select alone reports an error")
	var override := _write("override", MatchRoot.MAP_PATH + "\n")
	var chosen := MatchRoot.select_map(select, override)
	assert_eq(chosen["path"], MatchRoot.MAP_PATH, "override path")
	assert_eq(chosen["error"], "", "override is clean")
	_clean()


func test_bad_maps_fall_back_with_an_error() -> void:
	var cases := {
		"select names a missing map": MatchRoot.select_map(_write("missing.json", '{"map": "res://data/maps/nope.json"}'), NO_FILE),
		"select without map": MatchRoot.select_map(_write("nomap.json", '{"other": 1}'), NO_FILE),
		"missing select file": MatchRoot.select_map(NO_FILE, NO_FILE),
	}
	for text in ["res://data/stats.json", "user://x.json", "res://data/maps/../stats.json", "res://data/maps/nope.json", ""]:
		cases["override '%s'" % text] = MatchRoot.select_map(DataRegistry.MAP_SELECT_PATH, _write("override", text))
	for label: String in cases:
		var chosen: Dictionary = cases[label]
		assert_eq(chosen["path"], MatchRoot.MAP_PATH, label + ": falls back")
		assert_true(String(chosen["error"]) != "", label + ": reports an error")
	_clean()


func test_validate_map() -> void:
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(MatchRoot.MAP_PATH).size(), 0, "alesia is clean: " + ", ".join(reg.validate_map(MatchRoot.MAP_PATH)))
	var good := reg.load_file(MatchRoot.MAP_PATH).duplicate(true)
	assert_eq(DataRegistry.validate_map_def(good).size(), 0, "alesia def is clean")
	var with_files := good.duplicate(true)
	with_files["cover_data"] = "res://data/maps/alesia_cover.json"
	with_files["structure_data"] = "res://data/maps/alesia_structures.json"
	assert_eq(DataRegistry.validate_map_def(with_files).size(), 0, "existing piece files are clean")
	var no_scene := good.duplicate(true)
	no_scene.erase("scene")
	assert_true(DataRegistry.validate_map_def(no_scene).size() > 0, "missing scene reported")
	var bad_scene := good.duplicate(true)
	bad_scene["scene"] = "res://scenes/maps/nope.tscn"
	assert_true(DataRegistry.validate_map_def(bad_scene).size() > 0, "scene that does not exist reported")
	var no_spawns := good.duplicate(true)
	no_spawns["spawns"] = {}
	assert_true(DataRegistry.validate_map_def(no_spawns).size() > 0, "empty spawns reported")
	var bad_cover := good.duplicate(true)
	bad_cover["cover_data"] = NO_FILE
	assert_true(DataRegistry.validate_map_def(bad_cover).size() > 0, "missing cover_data file reported")
	var bad_structures := good.duplicate(true)
	bad_structures["structure_data"] = _write("empty.json", "{}")
	assert_true(DataRegistry.validate_map_def(bad_structures).size() > 0, "empty structure_data file reported")
	assert_eq(reg.validate().size(), 0, "validate is clean: " + ", ".join(reg.validate()))
	_clean()


func test_art_builder_follows_the_map() -> void:
	var scene: Node = _MapScene.instantiate()
	assert_eq(scene.get_node("ArtBuilder").get("map_json"), MatchRoot.MAP_PATH, "scene built directly keeps alesia")
	scene.free()
	var m := await _new_match()
	assert_true(m.begin(), "begin succeeds")
	assert_eq(m.map_path, MatchRoot.MAP_PATH, "match loaded alesia")
	assert_eq(m.map.get_node("ArtBuilder").get("map_json"), m.map_path, "ArtBuilder builds the match's map")
	m.queue_free()
	var o := await _new_match()
	o.map_path_override = MatchRoot.MAP_PATH
	assert_true(o.begin(), "begin with override succeeds")
	assert_eq(o.map_path, MatchRoot.MAP_PATH, "override map loaded")
	assert_eq(o.map.get_node("ArtBuilder").get("map_json"), o.map_path, "ArtBuilder follows the override")
	o.queue_free()


func test_ground_material_per_map_key() -> void:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var paint := ImageTexture.create_from_image(image)
	var a := WorldSurface.ground_material(paint, 100.0, "p1a_test_a")
	assert_true(WorldSurface.ground_material(paint, 100.0, "p1a_test_a") == a, "same key, same resource")
	var b := WorldSurface.ground_material(paint, 50.0, "p1a_test_b")
	assert_true(a != b, "different keys, different materials")
	assert_eq(float(a.get_shader_parameter("map_size_m")), 100.0, "a keeps its size")
	assert_eq(float(b.get_shader_parameter("map_size_m")), 50.0, "b keeps its size")
	var was := WorldSurface.wet()
	WorldSurface.set_wet(0.75)
	assert_eq(float(a.get_shader_parameter("wet")), 0.75, "set_wet reaches a")
	assert_eq(float(b.get_shader_parameter("wet")), 0.75, "set_wet reaches b")
	WorldSurface.set_wet(was)
	WorldSurface._grounds.erase("p1a_test_a")
	WorldSurface._grounds.erase("p1a_test_b")


func test_piece_file_keys() -> void:
	assert_eq(WorldKit.pieces_for({}), WorldKit.config()["pieces"], "default structure pieces")
	assert_eq(WorldKit.pieces_for({"structure_data": "res://data/maps/alesia_structures.json"}), WorldKit.config()["pieces"], "named alesia structure pieces")
