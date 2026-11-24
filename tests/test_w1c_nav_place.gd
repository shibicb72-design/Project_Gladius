extends "res://tests/test_case.gd"
## W1c fix pass 1 (review S1, S2).
## S1: MatchRoot._open_nav's bake fallback (a map without a fresh saved navmesh) bakes into a COPY of the scene's
## navigation mesh, so a second instance of that map scene starts unbaked (before W1c it inherited the first match's
## polygons through the shared sub-resource).
## S2: the place map's queued pixel work (PlaceMap.deferred + flush, which the map builder uses on both open paths)
## gives the same bytes and stamp count as stamping at once (PlaceMap.build without deferral) on alesia_500, and both
## equal the place map the match itself built.

const _MatchScene := preload("res://scenes/match/match.tscn")
const PlaceMap := preload("res://scripts/visual/place_map.gd")
const MAP_500 := "res://data/maps/alesia_500.json"
const FIXTURE := "res://tests/fixtures/w1c_nav_fallback.json"
## A temporary copy of the fixture where map paths must live; it has no saved navmesh (removed after the test).
const NO_NAV_MAP := "res://data/maps/_w1c_nav_fallback_tmp.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_tree().root.add_child(s)
	s.start_offline()
	s.lobby.host_open(2, 1, "Solus")
	s.lobby.state.start()
	return s


## A match opened through begin() (headless AUTO) on `map`.
func _begin_match(s: NetSession, map: String) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	m.map_path_override = map
	m.go_scene = func(_p: String) -> void: pass
	_tree().root.add_child(m)
	return m


func _free(m: MatchRoot, s: NetSession) -> void:
	if is_instance_valid(m):
		m.queue_free()
	await _frames(2)
	if is_instance_valid(s):
		s.leave()
		s.queue_free()
	await _frames(1)


static func _nav_polygons(map_root: Node) -> int:
	var nav := map_root.get_node_or_null("Nav") as NavigationRegion3D
	return nav.navigation_mesh.get_polygon_count() if nav != null and nav.navigation_mesh != null else -1


func _remove_tmp() -> void:
	if FileAccess.file_exists(NO_NAV_MAP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(NO_NAV_MAP))


func test_bake_fallback_leaves_the_next_map_instance_unbaked() -> void:
	_remove_tmp()  # a copy left by an aborted earlier run goes first
	var f := FileAccess.open(NO_NAV_MAP, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(FIXTURE))
	f.close()
	assert_true(MapNav.load_fresh(NO_NAV_MAP) == null, "the copy has no saved navigation mesh (the bake fallback runs)")
	var def := DataRegistry.new().load_file(NO_NAV_MAP)
	var scene := load(String(def["scene"])) as PackedScene
	var before := scene.instantiate()
	assert_eq(_nav_polygons(before), 0, "a fresh instance of the map scene starts unbaked")
	before.free()
	var s := _session("W1cNavFallbackSession")
	var m := _begin_match(s, NO_NAV_MAP)
	assert_eq(m.map_path, NO_NAV_MAP, "the match opened the fixture map")
	assert_eq(m.nav_bakes, 1, "begin() took the bake fallback once")
	assert_true(_nav_polygons(m.map) > 0, "the match's map has baked polygons (%d)" % _nav_polygons(m.map))
	var second := scene.instantiate()
	assert_eq(_nav_polygons(second), 0, "a second instance of the map scene, after the first was baked, starts unbaked")
	var nav_a := m.map.get_node("Nav") as NavigationRegion3D
	var nav_b := second.get_node("Nav") as NavigationRegion3D
	assert_true(nav_a.navigation_mesh != nav_b.navigation_mesh, "the bake went into a copy, not the scene's shared mesh")
	second.free()
	await _free(m, s)
	_remove_tmp()
	assert_true(not FileAccess.file_exists(NO_NAV_MAP), "the temporary map is removed")


func test_queued_place_map_equals_stamping_at_once_on_alesia_500() -> void:
	var s := _session("W1cPlaceMapSession")
	var m := _begin_match(s, MAP_500)
	var builder := m.map.get_node("ArtBuilder")
	var built: RefCounted = builder.get("place_map")
	assert_true(built != null and not bool(built.get("deferred")), "the match built its place map (queued, then flushed)")
	var size_m := float(builder.get("ground_size_m"))
	var contact: Array = (builder.get("clutter_report") as Dictionary).get("contact", [])
	var bodies: Array = builder.get("structure_bodies")
	# Stamped at once (no queue), in the builder's order: build(), the gate approaches, the clutter's contact blobs.
	var now: RefCounted = PlaceMap.build(builder, size_m, false)
	now.add_gate_approaches(bodies, builder.get_parent())
	now.add_contact(contact)
	# Queued and flushed in small slices, as the sliced build does (a deadline per call).
	var queued: RefCounted = PlaceMap.build(builder, size_m, true)
	queued.add_gate_approaches(bodies, builder.get_parent())
	var calls := 0
	while not queued.flush(Time.get_ticks_usec() + 2000) and calls < 100000:
		calls += 1
	queued.add_contact(contact)
	while not queued.flush(Time.get_ticks_usec() + 2000) and calls < 100000:
		calls += 1
	assert_true(calls > 1, "the queue ran over more than one flush (%d calls)" % calls)
	assert_eq(int(queued.call("pending")), 0, "nothing is left in the queue")
	assert_true(int(now.get("stamps")) > 100, "a real place map (%d stamps)" % int(now.get("stamps")))
	assert_eq(int(queued.get("stamps")), int(now.get("stamps")), "the same stamp count queued and at once")
	var a: PackedByteArray = now.get("data")
	var b: PackedByteArray = queued.get("data")
	assert_eq(a.size(), b.size(), "the same size")
	assert_true(a == b, "the same bytes queued and at once (sha256 %s / %s)" % [_sha(a), _sha(b)])
	assert_true(a == (built.get("data") as PackedByteArray), "and the bytes the match's own build made")
	assert_eq(int(built.get("stamps")), int(now.get("stamps")), "and its stamp count")
	await _free(m, s)


static func _sha(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode().left(16)
