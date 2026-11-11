extends "res://tests/test_case.gd"
## M2P1B commit 1: the ground size comes from the map json (alesia keeps its mesh fallback) and the ground
## paint's resolution from art_materials.json "ground" (pixels per metre with a cap).

const _Builder := preload("res://scripts/visual/astra_map.gd")
const ALESIA :="res://data/maps/alesia_section.json"
const MAP := "res://data/maps/test_300.json"
const TEST_SCENE := "res://scenes/maps/test_300.tscn"
const TMP_DIR := "user://p1b_ground_tmp/"
## sha256 of alesia's paint bytes measured before the change (256 px from the old fixed map_px).
const ALESIA_PAINT_SHA := "f2d8c15a0369fea9baa869fceda8560c120f75c7617dfc4cc69344acf56cd1d7"


## Builds a map scene with ArtBuilder.map_json set to `json_path` before it enters the tree.
func _build(json_path: String, scene_path: String = "") -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	if scene_path == "":
		scene_path = String(DataRegistry.parse_quiet(json_path)["scene"])
	var map: Node3D = load(scene_path).instantiate()
	map.get_node("ArtBuilder").set("map_json", json_path)
	tree.root.add_child(map)
	return map


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


func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func test_px_for_scales_per_metre_with_a_cap() -> void:
	var g: Dictionary = WorldSurface.config()["ground"]
	var per_m := float(g["paint_px_per_m"])
	var cap := int(g["paint_px_cap"])
	assert_eq(GroundPaint.px_for(160.0), 256, "alesia's 160 m ground keeps 256 px")
	assert_eq(GroundPaint.px_for(300.0), 480, "test_300's 300 m ground gets 480 px")
	assert_eq(GroundPaint.px_for(160.0), roundi(160.0 * per_m), "160 m follows paint_px_per_m")
	var past := float(cap) / per_m * 2.0
	assert_eq(GroundPaint.px_for(past), cap, "a ground past the cap gets the cap")
	assert_true(GroundPaint.px_for(0.0) >= 1, "no ground still gets at least one pixel")


func test_alesia_paint_is_byte_identical() -> void:
	var map := _build(ALESIA)
	var builder := map.get_node("ArtBuilder")
	assert_eq(float(builder.ground_size_m), 160.0, "alesia's size falls back to the ground mesh")
	var image: Image = builder.ground_paint
	assert_true(image != null, "alesia has a ground paint")
	if image != null:
		assert_eq(image.get_width(), 256, "alesia paint width")
		assert_eq(_sha256(image.get_data()), ALESIA_PAINT_SHA, "alesia paint bytes unchanged")
	map.free()


func test_test_300_size_from_data() -> void:
	var map := _build(MAP)
	var builder := map.get_node("ArtBuilder")
	assert_eq(float(builder.ground_size_m), 300.0, "test_300 ground size")
	var image: Image = builder.ground_paint
	assert_true(image != null and image.get_width() == 480, "test_300 paint is 480 px wide")
	var material := (map.get_node("Nav/Ground/Mesh") as MeshInstance3D).material_override as ShaderMaterial
	assert_true(material != null, "test_300 ground has the shader material")
	if material != null:
		assert_eq(float(material.get_shader_parameter("map_size_m")), 300.0, "ground material map_size_m")
	map.free()


func test_data_wins_over_the_mesh() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	def.erase("terrain")  # M2P1B: terrain.size_m would win; this checks the flat-map key
	def["ground_size_m"] = 200
	var path := _write("ground_200.json", JSON.stringify(def))
	var map := _build(path, TEST_SCENE)
	var builder := map.get_node("ArtBuilder")
	assert_eq(float(builder.ground_size_m), 200.0, "the json's ground_size_m beats the 300 m mesh")
	var chunk_m := float(MapChunks.config()["chunk_size_m"])
	assert_eq(builder.chunks.per_side, ceili(200.0 / chunk_m), "the chunk grid uses the same size")
	map.free()
	_clean()


## The builder's resolver on a bare Nav node (no ground mesh).
func _size_of(def: Dictionary) -> float:
	var nav := Node.new()
	var size: float = _Builder.ground_size_of(def, nav)
	nav.free()
	return size


func test_ground_size_resolver_order() -> void:
	assert_eq(_size_of({"terrain": {"size_m": 120}, "ground_size_m": 200}), 120.0, "terrain.size_m first")
	assert_eq(_size_of({"terrain": "flat", "ground_size_m": 200}), 200.0, "a non-dictionary terrain is skipped")
	assert_eq(_size_of({}), 0.0, "no data and no ground mesh is 0")


func test_validator_checks_ground_size() -> void:
	var def := DataRegistry.parse_quiet(MAP)
	assert_eq(DataRegistry.validate_map_def(def).size(), 0, "test_300 is clean: " + ", ".join(DataRegistry.validate_map_def(def)))
	for bad: Variant in [0, -5.0, "300"]:
		var copy := def.duplicate(true)
		copy["ground_size_m"] = bad
		assert_true(DataRegistry.validate_map_def(copy).size() > 0, "ground_size_m %s is reported" % str(bad))
