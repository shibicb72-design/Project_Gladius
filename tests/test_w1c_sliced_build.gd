extends "res://tests/test_case.gd"
## W1c stage B: the frame-sliced map build of the staged open (scripts/visual/astra_map.gd build_step; docs/ARCHITECTURE.md
## "Staged match open and shader warm-up"). The world hash (tests/world_hash.gd, binding fix 12) of a match opened
## through begin() equals the one opened through the sliced STAGED path for the same seed, on alesia_500 (the real
## match map) and the small fixture map; the sliced path really took many frames and slices, no later stage started
## before the build was done, and the bar moved through the build; the hash notices a one-value change; quitting or
## freeing the scene in the middle of the build leaves the tree running, runs no further build step and leaks nothing.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _WorldHash := preload("res://tests/world_hash.gd")
const MAP_500 := "res://data/maps/alesia_500.json"
const MAX_FRAMES := 6000
const SEED := 4242


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _solo_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_root().add_child(s)
	s.start_offline()
	s.lobby.host_open(2, 1, "Solus")
	s.lobby.state.start()
	return s


func _new_match(s: NetSession, path: MatchRoot.OpenPath, map: String) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.open_path = path
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = SEED
	m.map_path_override = map
	m.go_scene = func(_p: String) -> void: pass
	return m


func _free(m: MatchRoot, s: NetSession) -> void:
	if m != null and is_instance_valid(m):
		m.queue_free()
	await _frames(2)
	_tree().paused = false
	if is_instance_valid(s):
		s.leave()
		s.queue_free()
	await _frames(1)


## The map's navigation mesh (null without a Nav region). The nav stage always assigns a mesh of its own (the saved
## mesh, a new instance, or a bake into a copy), so "still the mesh the map was instanced with" proves the nav stage
## has not run. Not "0 polygons": the scene's own mesh is a sub-resource shared through the resource cache, and an
## earlier test that baked a map instance in place leaves its polygons there (full suite).
func _nav_mesh(m: MatchRoot) -> NavigationMesh:
	var nav := m.map.get_node_or_null("Nav") as NavigationRegion3D
	return nav.navigation_mesh if nav != null else null


func _builder(m: MatchRoot) -> Node:
	return m.map.get_node_or_null("ArtBuilder") if m != null and m.map != null else null


## Opens `map` through `path` and returns {hash, lines, ...}: the world at the moment the match opens (begin()
## returned; match_opened for the staged open), loot and props after the loot field placed its items.
func _open_and_hash(map: String, path: MatchRoot.OpenPath, tag: String, detail: Array = []) -> Dictionary:
	var s := _solo_session("W1cSliced%s%d" % [tag, path])
	var m := _new_match(s, path, map)
	var out := {"frames_building": 0, "slices": 0, "stage_ok": true, "stage_why": "", "progress_back": false, "progress_moved": false}
	var captured := {}
	m.match_opened.connect(func(_ok: bool) -> void: captured["world"] = _WorldHash.compute(m, detail))
	_root().add_child(m)
	if path == MatchRoot.OpenPath.SYNC:
		# The staged open applies the seed's look variant behind the overlay (its world stage); begin() leaves that to
		# MatchLook's first frame. The look writes shared materials the map holds (WorldSurface's wet / glow on the ground
		# and palette materials), so apply it here too: the comparison is of the BUILT world, not of when the look lands.
		m._apply_look_variant()
		captured["world"] = _WorldHash.compute(m, detail)
	var map_stage := MatchRoot._OPEN_STAGES.find("map_build")
	var last := -1.0
	var first_build_progress := -1.0
	var n := 0
	var built_mesh: NavigationMesh = null  # the map's mesh on the first build frame (the map entered the tree then)
	var built_polygons := -1
	while m.opening and n < MAX_FRAMES:
		var b := _builder(m)
		if b != null and b.is_inside_tree() and not bool(b.call("build_done")):
			out["frames_building"] = int(out["frames_building"]) + 1
			if int(out["frames_building"]) == 1:
				built_mesh = _nav_mesh(m)
				built_polygons = built_mesh.get_polygon_count() if built_mesh != null else -1
			# Nothing after the build may start while it runs: the stage stays map_build, no navigation, no pawn: the map's
			# navigation mesh is still the one it had when it entered the tree (see _nav_mesh).
			var mesh := _nav_mesh(m)
			var why := ""
			if m._open_stage != map_stage:
				why = "stage %s" % MatchRoot._OPEN_STAGES[m._open_stage]
			elif m.local_player != null or not m.bots.is_empty():
				why = "a pawn exists"
			elif mesh == null or mesh != built_mesh or mesh.get_polygon_count() != built_polygons:
				why = "the navigation mesh changed"
			if why != "" and bool(out["stage_ok"]):
				out["stage_ok"] = false
				out["stage_why"] = "%s on build frame %d" % [why, int(out["frames_building"])]
			if m.loading_overlay != null:
				var p := m.loading_overlay.progress()
				if first_build_progress < 0.0:
					first_build_progress = p
				elif p > first_build_progress:
					out["progress_moved"] = true
		if m.loading_overlay != null:
			out["progress_back"] = bool(out["progress_back"]) or m.loading_overlay.progress() < last
			last = m.loading_overlay.progress()
		await _tree().process_frame
		n += 1
	out["opened"] = not m.opening and m.director.running
	# The mesh check above means something only when the nav stage does swap the mesh (and the swapped one is a real one).
	var final_mesh := _nav_mesh(m)
	out["nav_swapped"] = built_mesh != null and final_mesh != null and final_mesh != built_mesh and final_mesh.get_polygon_count() > 0
	out["slices"] = int(_builder(m).get("build_slices"))
	out["done"] = bool(_builder(m).call("build_done"))
	out["last_progress"] = last
	await _tree().physics_frame
	await _tree().physics_frame
	await _tree().process_frame
	out["loot_placed"] = m.loot.placed
	out["loot"] = _WorldHash.loot_state(m)
	out["props"] = _WorldHash.props_state(m)
	var world: Dictionary = captured.get("world", {"hash": "", "lines": PackedStringArray()})
	out["hash"] = world["hash"]
	out["lines"] = world["lines"]
	out["detail"] = world.get("detail", {})
	await _free(m, s)
	return out


func _first_diff(a: PackedStringArray, b: PackedStringArray) -> String:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return "line %d: %s | %s" % [i, a[i], b[i]]
	return "sizes %d / %d" % [a.size(), b.size()] if a.size() != b.size() else "none"


func _compare(map: String, tag: String) -> void:
	var started := Time.get_ticks_msec()
	var sync := await _open_and_hash(map, MatchRoot.OpenPath.SYNC, tag)
	var sliced := await _open_and_hash(map, MatchRoot.OpenPath.STAGED, tag)
	assert_true(bool(sync["opened"]) and bool(sliced["opened"]), "%s: both opened" % tag)
	assert_eq(int(sync["slices"]), 1, "%s: begin() built the map in one go" % tag)
	assert_true(bool(sliced["done"]), "%s: the sliced build finished" % tag)
	assert_true(int(sliced["slices"]) > 1 and int(sliced["frames_building"]) > 1,
			"%s: the sliced build took more than one slice and frame (%d slices, %d frames)" % [tag, int(sliced["slices"]), int(sliced["frames_building"])])
	assert_true(bool(sliced["stage_ok"]), "%s: no later stage ran while the map was building (%s)" % [tag, sliced["stage_why"]])
	assert_true(bool(sliced["nav_swapped"]), "%s: the nav stage, after the build, gave the map a navigation mesh of its own" % tag)
	assert_true(bool(sliced["progress_moved"]), "%s: the bar moved during the build" % tag)
	assert_true(not bool(sliced["progress_back"]), "%s: the bar never went back" % tag)
	assert_true(float(sliced["last_progress"]) >= 0.99, "%s: the bar reached its end (%.2f)" % [tag, float(sliced["last_progress"])])
	var la: PackedStringArray = sync["lines"]
	var lb: PackedStringArray = sliced["lines"]
	assert_true(la.size() > 10, "%s: a real world (%d lines)" % [tag, la.size()])
	var diff := _first_diff(la, lb)
	if sliced["hash"] != sync["hash"] and diff.begins_with("line "):
		# Name the differing properties of the first differing node (both opens once more, that node in detail).
		var path := diff.get_slice(": ", 1).get_slice(" ", 0)
		var da: Dictionary = (await _open_and_hash(map, MatchRoot.OpenPath.SYNC, tag + "D", [path]))["detail"].get(path, {})
		var db: Dictionary = (await _open_and_hash(map, MatchRoot.OpenPath.STAGED, tag + "D", [path]))["detail"].get(path, {})
		var props: Array = []
		for k: String in da:
			if da[k] != db.get(k):
				props.append(k)
		diff += " (properties: %s)" % ", ".join(props)
	assert_eq(sliced["hash"], sync["hash"], "%s: the world hash (%d / %d lines; first difference: %s)" % [tag, la.size(), lb.size(), diff])
	assert_true(bool(sync["loot_placed"]) and bool(sliced["loot_placed"]), "%s: the loot is placed" % tag)
	assert_eq(sliced["loot"], sync["loot"], "%s: the loot spawns" % tag)
	assert_eq(sliced["props"], sync["props"], "%s: the props and their states" % tag)
	print("W1C_SLICED_HASH map=%s lines=%d hash=%s slices=%d frames=%d ms=%d" % [tag, la.size(), String(sync["hash"]).left(16),
			int(sliced["slices"]), int(sliced["frames_building"]), Time.get_ticks_msec() - started])


func test_sliced_build_matches_begin_on_alesia_500() -> void:
	await _compare(MAP_500, "alesia_500")


func test_sliced_build_matches_begin_on_the_fixture_map() -> void:
	await _compare(MatchRoot.MAP_PATH, MatchRoot.MAP_PATH.get_file().get_basename())


## Negative self-check: one changed transform, one changed batch instance or one changed place-map byte changes the hash.
func test_world_hash_notices_one_change() -> void:
	var s := _solo_session("W1cHashNeg")
	var m := _new_match(s, MatchRoot.OpenPath.SYNC, MAP_500)
	_root().add_child(m)
	var base: String = _WorldHash.compute(m)["hash"]
	assert_eq(_WorldHash.compute(m)["hash"], base, "the hash is stable")
	var b := _builder(m)
	var body: StaticBody3D = (b.get("structure_bodies") as Array)[0]
	var was := body.position
	body.position.x += 0.001
	assert_true(_WorldHash.compute(m)["hash"] != base, "a moved body changes the hash")
	body.position = was
	assert_eq(_WorldHash.compute(m)["hash"], base, "restored")
	# A batch instance: the headless renderer keeps no MultiMesh instance data, so the hash reads the batch's
	# "transforms" meta, which MapChunks fills from the same list it fills the MultiMesh from (and _set_instance keeps).
	var batch: MultiMeshInstance3D = (b.get("chunks") as MapChunks).batches()[0]
	var transforms: Array = batch.get_meta(&"transforms")
	var xf: Transform3D = transforms[0]
	transforms[0] = xf.translated(Vector3(0.0, 0.001, 0.0))
	batch.set_meta(&"transforms", transforms)
	assert_true(_WorldHash.compute(m)["hash"] != base, "a moved batch instance changes the hash")
	transforms[0] = xf
	batch.set_meta(&"transforms", transforms)
	assert_eq(_WorldHash.compute(m)["hash"], base, "restored")
	# A mesh's surface arrays: one vertex of one terrain cell's mesh.
	var cell := b.get_node("Terrain").get_child(0).get_node("Mesh") as MeshInstance3D
	var old_mesh := cell.mesh
	var arrays := old_mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	verts[0] += Vector3(0.0, 0.001, 0.0)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var moved := ArrayMesh.new()
	moved.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	cell.mesh = moved
	assert_true(_WorldHash.compute(m)["hash"] != base, "a moved mesh vertex changes the hash")
	cell.mesh = old_mesh
	assert_eq(_WorldHash.compute(m)["hash"], base, "restored")
	# A collider shape: one cover box a millimetre longer.
	var cover: StaticBody3D = (b.get("cover_bodies") as Array)[0]
	var box := (cover.get_node("Shape") as CollisionShape3D).shape as BoxShape3D
	var size := box.size
	box.size = size + Vector3(0.001, 0.0, 0.0)
	assert_true(_WorldHash.compute(m)["hash"] != base, "a resized collider changes the hash")
	box.size = size
	assert_eq(_WorldHash.compute(m)["hash"], base, "restored")
	var place: RefCounted = b.get("place_map")
	var data: PackedByteArray = place.get("data")
	data[7] = (data[7] + 1) % 256
	place.set("data", data)
	assert_true(_WorldHash.compute(m)["hash"] != base, "a changed place-map byte changes the hash")
	await _free(m, s)


## Starts a staged alesia_500 open and waits until its map is part-built (a few slices in).
func _mid_build(tag: String) -> Array:
	var s := _solo_session("W1cMidBuild%s" % tag)
	var m := _new_match(s, MatchRoot.OpenPath.STAGED, MAP_500)
	_root().add_child(m)
	var n := 0
	while n < MAX_FRAMES:
		var b := _builder(m)
		if b != null and b.is_inside_tree() and int(b.get("build_slices")) >= 3:
			break
		await _tree().process_frame
		n += 1
	return [s, m]


func test_quit_in_the_middle_of_the_build() -> void:
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var sm := await _mid_build("Quit")
	var s: NetSession = sm[0]
	var m: MatchRoot = sm[1]
	var b := _builder(m)
	assert_true(b != null and not bool(b.call("build_done")) and m.opening, "the build is in the middle (%s)" % (b.call("build_step_label") if b != null else "-"))
	var slices := int(b.get("build_slices"))
	m.quit_to_menu()
	assert_true(not m.opening and not _tree().paused, "the open stopped and the tree runs")
	await _frames(4)
	assert_eq(int(b.get("build_slices")), slices, "no build step ran after the quit")
	assert_true(not bool(b.call("build_done")) and not m.director.running, "the build stays unfinished, the director never started")
	await _free(m, s)
	await _frames(2)
	assert_eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before, "no orphan nodes left")


func test_freed_in_the_middle_of_the_build() -> void:
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var sm := await _mid_build("Free")
	var s: NetSession = sm[0]
	var m: MatchRoot = sm[1]
	var b := _builder(m)
	assert_true(b != null and not bool(b.call("build_done")) and _tree().paused, "mid-build, tree paused")
	m.queue_free()
	await _frames(3)
	assert_true(not is_instance_valid(m) and not is_instance_valid(b), "the match and its builder are gone")
	assert_true(not _tree().paused, "the tree is not left paused")
	await _free(null, s)
	await _frames(2)
	assert_eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before, "no orphan nodes left")
