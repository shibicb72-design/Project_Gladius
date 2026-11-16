extends "res://tests/test_case.gd"
## M2W1 item 9: the 1 km map's far backdrop (data/art_backdrop.json "maps".alesia_1km, scripts/visual/backdrop.gd
## _build_far). Looks only: no CollisionObject3D, nothing under Nav, no shadow; within its draw and triangle budget;
## inside the camera's far plane; trees only well beyond the play space. The two small maps build exactly today's
## backdrop (node names, instance and triangle counts recorded before item 9). The preset switch off builds none. The
## three saved navigation meshes keep the hashes recorded before item 9 (any later navigation drift fails here).
const Perf := preload("res://tests/test_astra_perf.gd")
const MAP_1KM := "res://data/maps/alesia_1km.json"
## Recorded at HEAD 786ab39 before item 9 (build/m2w1/probe_backdrop.gd): both small maps.
const SMALL_PARTS := "GroundSkirt:MeshInstance3D:n=1:tris=2, OuterWall:MultiMeshInstance3D:n=40:tris=12800, OuterTowers:MultiMeshInstance3D:n=8:tris=2048, Spires:MultiMeshInstance3D:n=6:tris=960, AqueductRun:MultiMeshInstance3D:n=28:tris=21728, Hills:MeshInstance3D:n=1:tris=400"
const SMALL_PLACED := 82
const NAV_SHA := {
	"res://data/maps/nav/alesia_1km.json": "66deef7062d0a3c24e2998bafb880ca7aa71354724f49cbcddc4b3eab0ac4883",
	"res://data/maps/nav/alesia_section.json": "f1a98dd071dbc9eee479f544b392b6312227cd8c025a0a238e815f00b59dfe7b",
	"res://data/maps/nav/test_300.json": "669944c64ff167989ab678e47186c1aba9712e83b8f36dfae832d0ad09d27c74",
}
## Godot's default Camera3D far (no game camera sets another: data/camera.json has no far plane).
const CAMERA_FAR_M := 4000.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _build(path: String) -> Node3D:
	var def := DataRegistry.parse_quiet(path)
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", path)
	_tree().root.add_child(map)
	return map


static func _parts(b: Node) -> Array:
	var out: Array = []
	var tris := 0
	for c in b.get_children():
		var m: Mesh = (c as MultiMeshInstance3D).multimesh.mesh if c is MultiMeshInstance3D else (c as MeshInstance3D).mesh
		var n := (c as MultiMeshInstance3D).multimesh.instance_count if c is MultiMeshInstance3D else 1
		out.append("%s:%s:n=%d:tris=%d" % [c.name, c.get_class(), n, Perf.triangles(m) * n])
		tris += Perf.triangles(m) * n
	return [", ".join(out), tris]


func test_navigation_meshes_keep_their_recorded_hashes() -> void:
	for manifest: String in NAV_SHA:
		var m := DataRegistry.parse_quiet(manifest)
		assert_eq(String(m.get("mesh_sha256", "")), String(NAV_SHA[manifest]), "%s: mesh_sha256 as recorded before M2W1 item 9" % manifest)
		assert_eq(MapNav.file_hash(String(manifest).replace(".json", ".res")), String(NAV_SHA[manifest]), "%s: the saved mesh file hashes to it" % manifest)


func test_1km_backdrop_is_a_cheap_look_outside_the_play_space() -> void:
	var map := _build(MAP_1KM)
	var b := map.get_node_or_null("ArtBuilder/Backdrop") as Backdrop
	assert_true(b != null, "the 1 km map builds a backdrop")
	if b == null:
		map.free()
		return
	var block: Dictionary = Backdrop.config()["maps"]["alesia_1km"]
	assert_eq(b.find_children("*", "CollisionObject3D", true, false).size() + b.find_children("*", "CollisionShape3D", true, false).size(), 0, "no body, no shape")
	assert_true(not map.get_node("Nav").is_ancestor_of(b), "not under Nav")
	for name: String in ["OuterWall", "OuterTowers", "Spires", "AqueductRun"]:
		assert_true(b.get_node_or_null(name) == null, "no small-map %s (the map's own outer wall is its edge)" % name)
	var draws := 0
	for c in b.get_children():
		assert_eq((c as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s casts no shadow" % c.name)
		draws += 1  # one node, one mesh, one surface: one draw
	var parts := _parts(b)
	var budgets: Dictionary = block["budgets"]
	assert_true(draws <= int(budgets["draws"]), "%d draws, cap %d" % [draws, budgets["draws"]])
	assert_true(int(parts[1]) <= int(budgets["tris"]), "%d triangles, cap %d" % [parts[1], budgets["tris"]])
	# Everything placed stands outside the ground square; trees well beyond it and the outer wall.
	var half := float(block["ground_half_m"])
	var trees: Dictionary = block["trees"]
	var kinds := {}
	for p: Dictionary in b.placed:
		var at: Vector3 = p["at"]
		kinds[p["kind"]] = int(kinds.get(p["kind"], 0)) + 1
		var edge := Vector2(clampf(at.x, -half, half), clampf(at.z, -half, half))
		var out_m := Vector2(at.x, at.z).distance_to(edge)
		assert_true(out_m >= float(Backdrop.config()["clear_of_ground_m"]), "%s at %s is outside the ground square" % [p["kind"], at])
		if p["kind"] == "tree":
			assert_true(out_m >= float(trees["clear_of_square_m"]) - 0.01 and Vector2(at.x, at.z).length() >= float(trees["wall_radius_m"]) + float(trees["min_from_wall_m"]), "tree at %s far beyond the play space" % at)
	for kind: String in ["far_aqueduct", "beacon", "tree"]:
		assert_true(int(kinds.get(kind, 0)) > 0, "the backdrop places %s" % kind)
	# The hills: every vertex outside the square, and every vertex a camera on the ground square could see is within
	# the far plane (the farthest corner of the square).
	var hills := (b.get_node("Hills") as MeshInstance3D).mesh
	var farthest := 0.0
	for v: Vector3 in hills.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		assert_true(absf(v.x) > half or absf(v.z) > half, "hill vertex %s outside the ground square" % v)
		farthest = maxf(farthest, Vector2(v.x, v.z).length())
	var ridge_far := 0.0
	for ring: Dictionary in block["hills"]["rings"]:
		ridge_far = maxf(ridge_far, (float(ring["radius_m"]) + float(ring["depth_m"]) * 0.58) * (1.0 + float(ring.get("radius_noise", 0.12))))
	assert_true(ridge_far + half * sqrt(2.0) <= CAMERA_FAR_M, "the farthest ridge (%.0f m) is inside the far plane from the square's corner" % ridge_far)
	print("M2W1_BACKDROP draws=%d tris=%d kinds=%s farthest_vertex_m=%.0f farthest_ridge_m=%.0f parts=%s" % [draws, parts[1], str(kinds), farthest, ridge_far, parts[0]])
	map.free()


## M2W1 astraB (F8): the 1 km map's skyline is composed by direction: the far ring's two northern peaks stand
## over its saddle, the east is one flat table on the middle ring, the south is the lowest opening, the west's
## cypresses outnumber the rest.
func test_1km_skyline_has_a_direction_each_way() -> void:
	var rings: Array = Backdrop.config()["maps"]["alesia_1km"]["hills"]["rings"]
	var far: Array = rings[2]["profile"]
	var mid: Array = rings[1]["profile"]
	var near: Array = rings[0]["profile"]
	var peak_w := Backdrop.profile_at(far, 353.0).x
	var saddle := Backdrop.profile_at(far, 5.0).x
	var peak_e := Backdrop.profile_at(far, 16.0).x
	assert_true(peak_w > saddle * 1.5 and peak_e > saddle * 1.5, "north: two peaks (%.0f, %.0f m) over a saddle (%.0f m)" % [peak_w, peak_e, saddle])
	assert_true(absf(Backdrop.profile_at(mid, 70.0).x - Backdrop.profile_at(mid, 115.0).x) < 1.0 and Backdrop.profile_at(mid, 90.0).z < 0.1, "east: a flat table ridge")
	for ring: Array in [near, mid, far]:
		var south := Backdrop.profile_at(ring, 195.0).x
		for bearing: float in [0.0, 90.0, 270.0]:
			assert_true(south < Backdrop.profile_at(ring, bearing).x, "south is the open side (bearing %.0f)" % bearing)
	var sectors: Array = Backdrop.config()["maps"]["alesia_1km"]["trees"]["sectors"]
	assert_true(absf(float(sectors[0][0]) - 270.0) < 1.0 and float(sectors[0][2]) > 0.5, "most cypress clumps stand west")
	# M2W1 r2b (C3): one bold feature per direction, and the sun's side darker.
	var hills: Dictionary = Backdrop.config()["maps"]["alesia_1km"]["hills"]
	var cap: Dictionary = rings[2].get("cap", {})
	assert_true(not cap.is_empty() and peak_w > float(cap["full_m"]) and peak_e > float(cap["full_m"]) and saddle < float(cap["from_m"]), "north: both peaks capped pale, the saddle not")
	var cliff: Dictionary = rings[1].get("cliff", {})
	assert_true(not cliff.is_empty() and Backdrop._arc_weight(90.0, float(cliff["bearings"][0]), float(cliff["bearings"][1]), 1.0) == 1.0, "east: the table is a cliffed mesa")
	assert_true(Backdrop.profile_at(mid, 94.0).x < Backdrop.profile_at(mid, 80.0).x * 0.75, "east: one notch in the mesa")
	assert_true(Backdrop.profile_at(mid, 173.0).x > Backdrop.profile_at(mid, 190.0).x * 3.0 and Backdrop.profile_at(mid, 207.0).x > Backdrop.profile_at(mid, 190.0).x * 3.0, "south: two headlands over the low opening")
	var bright_south := false
	for band: Dictionary in hills.get("bands", []):
		if float(band["bearings_deg"][0]) < 180.0 and float(band["bearings_deg"][1]) > 200.0 and GreyboxArt.color_value(band["color"]).get_luminance() > 0.7:
			bright_south = true
	assert_true(bright_south, "south: a bright plain band")
	var spire_west := false
	for s: Dictionary in hills.get("spires", []):
		spire_west = spire_west or (float(s["bearing_deg"]) > 225.0 and float(s["bearing_deg"]) < 315.0)
	assert_true(spire_west, "west: a lone spire")
	for ring: Dictionary in rings:
		assert_true(Backdrop._bearing_value(ring.get("tint", []), 45.0) < 0.8, "the sun's side (north-east in dusk) is darker on every ring")


func test_small_maps_build_exactly_todays_backdrop() -> void:
	for path: String in ["res://data/maps/alesia_section.json", "res://data/maps/test_300.json"]:
		var map := _build(path)
		var b := map.get_node_or_null("ArtBuilder/Backdrop") as Backdrop
		assert_true(b != null, "%s builds a backdrop" % path)
		if b != null:
			assert_eq(String(_parts(b)[0]), SMALL_PARTS, "%s: the same nodes, instances and triangles as before item 9" % path)
			assert_eq(b.placed.size(), SMALL_PLACED, "%s: the same placed pieces" % path)
		map.free()


func test_preset_off_builds_none() -> void:
	var builder := preload("res://scripts/visual/astra_map.gd")
	assert_true(builder.backdrop_wanted(DataRegistry.parse_quiet(MAP_1KM), true), "the 1 km map wants its backdrop with the preset on")
	assert_true(not builder.backdrop_wanted(DataRegistry.parse_quiet(MAP_1KM), false), "preset off: no backdrop")
	assert_true(bool(GraphicsPresets.new().get_preset().get("art_backdrop_enabled", false)), "default preset: backdrop on")
