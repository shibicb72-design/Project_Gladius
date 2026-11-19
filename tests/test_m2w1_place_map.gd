extends "res://tests/test_case.gd"
## M2W1 astraB: the place map (scripts/visual/place_map.gd): built at map load from the placed bodies and the
## clutter, deterministic, never saved and never an input of the ground paint hash or the navigation manifest;
## R trodden round buildings, doorways and tracks, G shelter at wall feet, B contact under clutter, A the broad
## noise the ground shader no longer fetches. The 1 km map is built once (freed by test_zz).
const MAP_1KM := "res://data/maps/alesia_1km.json"
const PAINT_HASH := "54179b8650e1112efec992a94aa2bce984d24edb918cec4b4c00d181f1415ee8"

static var _built: Node3D


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _build() -> Node3D:
	var def := DataRegistry.parse_quiet(MAP_1KM)
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", MAP_1KM)
	_tree().root.add_child(map)
	return map


func _map() -> Node3D:
	WorldClutter.enabled_override = 1
	if not is_instance_valid(_built):
		_built = _build()
	return _built


func _place() -> RefCounted:
	return _map().get_node("ArtBuilder").get("place_map")


func test_built_at_load_and_given_to_the_ground() -> void:
	var builder := _map().get_node("ArtBuilder")
	var place: RefCounted = _place()
	assert_true(place != null, "alesia_1km has a place map")
	if place == null:
		return
	assert_eq(int(place.px), int(PlaceMapCfg.get("px", 512)), "its size is the data's")
	assert_eq((place.data as PackedByteArray).size(), int(place.px) * int(place.px) * 4, "RGBA8")
	var ground: ShaderMaterial = builder.get("ground_material")
	assert_true(ground.get_shader_parameter("place_map") is Texture2D, "the ground material samples it")
	assert_eq(float(ground.get_shader_parameter("place_enabled")), 1.0, "and reads it")
	assert_true(int(place.build_ms) < 1500, "built in %d ms" % int(place.build_ms))
	print("M2W1_PLACE_MAP px=%d build_ms=%d stamps=%d" % [place.px, place.build_ms, place.stamps])


var PlaceMapCfg: Dictionary:
	get:
		return WorldSurface.ground_detail_config().get("place_map", {})


func test_500_gate_approach_uses_the_gate_frame() -> void:
	var script := preload("res://scripts/visual/place_map.gd")
	var profiles: Dictionary = script.config("alesia_500")["gate_approaches"]
	assert_true(not script.config("alesia_1km").has("gate_approaches"), "gate profiles apply to Alesia 500")
	var placed: Array = DataRegistry.parse_quiet("res://data/maps/alesia_500_structures.json")["pieces"]
	var gate_ids := placed.filter(func(row: Dictionary) -> bool: return row["type"] == "gate").map(func(row: Dictionary) -> String: return String(row["id"]))
	gate_ids.sort()
	var configured := profiles.keys()
	configured.sort()
	assert_eq(configured, gate_ids, "a ground profile for every gateway")
	var place := script.new(500.0, 512)
	var frame := Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(40, 0, 20))
	place.stamp_gate_approach(frame, profiles["OuterRing_054"])
	assert_true(place.sample(Vector2(31, 14)).r > 0.85, "the east gate's forecourt lies on the authored shoulder")
	assert_true(place.sample(Vector2(31, 28)).g > 0.75, "the east gate's opposite shoulder stays sheltered")
	assert_true(place.sample(Vector2(49, 28)).g < 0.05, "the profile follows the inward side of the gate")


func test_out_of_every_hashed_input() -> void:
	# The paint keeps its pinned inputs hash; the navigation manifest's inputs name neither data file.
	var settings := GroundPaint.settings_for(DataRegistry.parse_quiet(MAP_1KM))
	var baked := String(settings.get("baked", ""))
	var image := ResourceLoader.load(baked, "", ResourceLoader.CACHE_MODE_IGNORE) as Image if baked != "" else null
	assert_true(image != null and String(image.get_meta(&"inputs_sha256", "")) == PAINT_HASH, "the baked paint keeps its inputs hash")
	var files := MapNav.input_files(MAP_1KM)
	for path: String in [WorldSurface.GROUND_DETAIL_PATH, WorldClutter.PATH, "res://scripts/visual/place_map.gd"]:
		assert_true(not files.has(path), "%s is not a navigation input" % path)
	# Nothing saved: no file under data/ or the map folder carries a place map.
	assert_true(not FileAccess.file_exists("res://data/maps/alesia_1km_place.png"), "no saved place map")


func test_channels_mean_what_they_say() -> void:
	var builder := _map().get_node("ArtBuilder")
	var place: RefCounted = _place()
	var root := builder.get_parent()
	# R: trodden at every door's opening.
	var trodden := 0
	var doors: Array = builder.get("door_bodies")
	for door: Node in doors:
		var t := WorldClutter.xform_to(door, root)
		if (place.sample(Vector2(t.origin.x, t.origin.z)) as Color).r > 0.5:
			trodden += 1
	assert_true(doors.size() >= 20 and trodden == doors.size(),"trodden at %d of %d doorways" % [trodden, doors.size()])
	# The far field corner is open ground: nothing trodden, no shelter.
	var corner: Color = place.sample(Vector2(-480.0, 480.0))
	assert_true(corner.r < 0.05, "the field corner is not trodden (%.2f)" % corner.r)
	# G: shelter at the foot of the wall pieces.
	var sheltered := 0
	var walls := 0
	for body: Node in builder.get("structure_bodies"):
		if String(body.get_meta(&"structure_type", "")) != "wall_walk":
			continue
		walls += 1
		var t := WorldClutter.xform_to(body, root)
		var foot := t * Vector3(0.0, 0.0, 1.6)
		if (place.sample(Vector2(foot.x, foot.z)) as Color).g > 0.3:
			sheltered += 1
	assert_true(walls > 100 and sheltered >= walls * 0.9, "shelter at %d of %d wall feet" % [sheltered, walls])
	# B: contact under every clutter spot the builder reported.
	var spots: Array = (builder.get("clutter_report") as Dictionary).get("contact", [])
	var grounded := 0
	for s: Dictionary in spots:
		if (place.sample(s["c"]) as Color).b > 0.2:
			grounded += 1
	assert_true(spots.size() > 1000 and grounded >= spots.size() * 0.95, "contact under %d of %d clutter spots" % [grounded, spots.size()])
	# A: the noise pack's G at the 360 m tile (the fetch the ground shader dropped).
	var noise := (load(String(WorldSurface.config()["noise"])) as Texture2D).get_image()
	noise.decompress()
	var p := Vector2(123.0, -77.0)
	var tile := float(WorldSurface.ground_detail_config()["uniforms"]["detail_large_m"])
	var uv := p / tile + Vector2(0.37, 0.11)
	var q: Vector2 = place.to_px(p)
	var x := int(q.x)
	var y := int(q.y)
	var w: Vector2 = place.to_world(x + 0.5, y + 0.5)
	uv = w / tile + Vector2(0.37, 0.11)
	var want := noise.get_pixel(posmod(int(floor(uv.x * noise.get_width())), noise.get_width()), posmod(int(floor(uv.y * noise.get_height())), noise.get_height())).g
	assert_true(absf((place.sample(p) as Color).a - want) < 0.01, "A is the broad noise (%.3f, want %.3f)" % [(place.sample(p) as Color).a, want])


## M2W1 r2b (C2): broad compacted roads. Every outer gate has one running out through it (straight for the gate
## stretch), every camp yard is reached, and a main road is a solid 5-8 m band: full on its line, still trodden at
## the solid half width, clear of trodden a few metres past its outer edge (unless something else is trodden there).
func test_roads_are_broad_and_reach_every_gate_and_camp() -> void:
	var builder := _map().get_node("ArtBuilder")
	var place: RefCounted = _place()
	var root := builder.get_parent()
	var roads: Array = place.get("roads")
	var cfg: Dictionary = PlaceMapCfg["roads"]
	var main: Array = cfg["main"]
	assert_true(float(main[0]) * 2.0 >= 5.0 and float(main[0]) * 2.0 <= 8.0, "main roads' solid core is 5-8 m wide (%.1f)" % (float(main[0]) * 2.0))
	assert_true(roads.size() >= 4 + 4 + 6, "a road per outer gate, inner gate and camp at least (%d)" % roads.size())
	var outer := 0
	for body: Node in builder.get("structure_bodies"):
		if String(body.get_meta(&"structure_type", "")) != "gate":
			continue
		var t := WorldClutter.xform_to(body, root)
		var c := Vector2(t.origin.x, t.origin.z)
		if c.length() < float(cfg["outer_gate_min_r_m"]):
			continue
		outer += 1
		var out := c.normalized()  # the outer gates face the centre square-on
		var at := c + out * 50.0  # past the field ring track
		var on := place.sample(at) as Color
		var side := place.sample(at + out.orthogonal() * (float(main[0]) - 0.5)) as Color
		var past := place.sample(at + out.orthogonal() * (float(main[1]) + 4.0)) as Color
		assert_true(on.r >= 0.8 and side.r >= 0.6 and past.r < 0.3, "the road 50 m outside the gate at %s: centre %.2f, edge %.2f, past it %.2f" % [c, on.r, side.r, past.r])
	assert_eq(outer, 4, "four outer gates")
	var parts := {}
	for body: Node in builder.get("structure_bodies"):
		var id := String(body.name)
		if String(body.get_meta(&"structure_type", "")) == "barracks" and id.contains("_"):
			var t := WorldClutter.xform_to(body, root)
			parts[id.get_slice("_", 0)] = Vector2(t.origin.x, t.origin.z)
	for camp: String in parts:
		var reached := false
		for road: Dictionary in roads:
			var pts: PackedVector2Array = road["pts"]
			if pts[pts.size() - 1].distance_to(parts[camp]) < 30.0:
				reached = true
		assert_true(reached, "a road ends in %s's yard" % camp)


func test_deterministic() -> void:
	var first: PackedByteArray = _place().data
	var again := _build()
	var second: PackedByteArray = (again.get_node("ArtBuilder").get("place_map")).data
	again.free()
	assert_eq(second.size(), first.size(), "same size")
	assert_true(second == first, "two builds make the same place map")


func test_fixture_maps_build_one_too() -> void:
	# The ground detail path reads A on every map: the small maps get a place map (no clutter on them).
	var def := DataRegistry.parse_quiet("res://data/maps/alesia_section.json")
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", "res://data/maps/alesia_section.json")
	_tree().root.add_child(map)
	var place: Variant = map.get_node("ArtBuilder").get("place_map")
	assert_true(place != null, "alesia_section has a place map")
	map.free()
	MapTerrain.clear_cache()


func test_zz_free_the_map() -> void:
	if is_instance_valid(_built):
		_built.free()
	_built = null
	WorldClutter.enabled_override = -1
	MapTerrain.clear_cache()
	assert_true(true, "freed")
