extends "res://tests/test_case.gd"
## W1c: the staged match open (MatchRoot.OpenPath, docs/ARCHITECTURE.md "Staged match open and shader warm-up").
## A plain headless auto_start takes begin() (no overlay, no warm-up); the STAGED opt-in runs the overlay, one phase
## per frame and the warm-up with the tree paused, then starts the director (progress 1, overlay gone); a networked
## session never takes it; staged and begin() reach the same director, loot and prop state and the same built map for
## a seed; quitting or freeing the scene mid-open leaves the tree running and logs nothing.

const _MatchScene := preload("res://scenes/match/match.tscn")
const MAP_500 := "res://data/maps/alesia_500.json"
const MAX_FRAMES := 4000


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


## A Play-solo session (its own SceneMultiplayer, offline peer, solo flag) with a started lobby of `squads` x 1.
func _solo_session(node_name: String, squads: int = 2) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_root().add_child(s)
	s.start_offline()
	s.lobby.host_open(squads, 1, "Solus")
	s.lobby.state.start()
	return s


func _match(s: NetSession, path: MatchRoot.OpenPath, map: String = "", back: Array = []) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.open_path = path
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	if map != "":
		m.map_path_override = map
	m.go_scene = func(p: String) -> void: back.append(p)
	_root().add_child(m)  # auto_start (the default): _ready opens the match
	return m


func _wait_open(m: MatchRoot) -> bool:
	var n := 0
	while m.opening and n < MAX_FRAMES:
		await _tree().process_frame
		n += 1
	return not m.opening


func _free(m: MatchRoot, s: NetSession) -> void:
	if is_instance_valid(m):
		m.queue_free()
	await _frames(2)
	_tree().paused = false
	if is_instance_valid(s):
		s.leave()
		s.queue_free()
	await _frames(1)


func test_plain_headless_auto_start_takes_begin() -> void:
	var s := _solo_session("W1cPlainSession")
	var m := _match(s, MatchRoot.OpenPath.AUTO, MatchRoot.MAP_PATH)
	assert_true(not m.staged_open_wanted(), "AUTO off the web: no staged open")
	assert_true(not m.opening, "begin() ran inside _ready")
	assert_true(m.director.running, "the director runs at once")
	assert_true(m.loading_overlay == null and m.find_children("*", "LoadingOverlay", true, false).is_empty(), "no overlay")
	assert_true(m.find_children("*", "ShaderWarmup", true, false).is_empty(), "no warm-up")
	assert_true(m.warmup_report.is_empty(), "no warm-up report")
	assert_true(not _tree().paused, "the tree is not paused")
	await _free(m, s)


func test_staged_open_pauses_warms_and_starts_last() -> void:
	var s := _solo_session("W1cStagedSession")
	var m := _match(s, MatchRoot.OpenPath.STAGED, MatchRoot.MAP_PATH)
	assert_true(m.opening, "the staged open runs")
	assert_true(_tree().paused, "the tree is paused while it runs")
	assert_true(m.loading_overlay != null and m.loading_overlay.is_inside_tree(), "the overlay is up from the first frame")
	assert_true(m.map == null, "nothing is built in _ready (the overlay draws first)")
	assert_eq(m.pause_menu.process_mode, Node.PROCESS_MODE_DISABLED, "the pause menu is off while loading")
	var opened: Array = []
	var at_open := {}
	m.match_opened.connect(func(ok: bool) -> void:
			opened.append(ok)
			at_open["ticks"] = m.director.tick_count
			at_open["paused"] = _tree().paused
			at_open["overlay"] = m.loading_overlay)
	var last_progress := 0.0
	var positions := {}
	var still := true
	var director_ran := false
	var n := 0
	while m.opening and n < MAX_FRAMES:
		if m.loading_overlay != null:
			assert_true(m.loading_overlay.progress() >= last_progress, "the bar never goes back")
			last_progress = m.loading_overlay.progress()
		director_ran = director_ran or m.director.running
		for p: Pawn in ([m.local_player] if m.local_player != null else []) + m.bots:
			if positions.has(p):
				still = still and (positions[p] as Vector3).is_equal_approx(p.global_position)
			positions[p] = p.global_position
		await _tree().process_frame
		n += 1
	assert_true(not m.opening, "the staged open ended (%d frames)" % n)
	assert_eq(opened, [true], "match_opened(true) once")
	assert_true(not director_ran, "the director did not run while loading")
	assert_true(still and not positions.is_empty(), "no pawn moved while loading (%d pawns)" % positions.size())
	assert_true(m.director.running, "the director runs after it")
	assert_eq(at_open.get("ticks", -1), 0, "no rule tick before the start")
	assert_eq(at_open.get("paused", true), false, "the tree runs from the start")
	assert_true(at_open.get("overlay", 1) == null, "the overlay is off when the match opens")
	for b in m.bots:
		var brain: BotBrain = b.get_node_or_null("Brain")
		assert_true(brain == null or brain.brain_ticks == 0, "a bot brain did not tick while loading")
	assert_true(last_progress >= 0.99, "the bar reached its end (%.2f)" % last_progress)
	assert_eq(float(m.warmup_report.get("progress", 0.0)), 1.0, "the warm-up's progress reached 100 percent")
	assert_true(int(m.warmup_report.get("items", 0)) > 0, "the warm-up had items")
	await _frames(1)
	assert_true(m.loading_overlay == null and m.find_children("*", "LoadingOverlay", true, false).is_empty(), "the overlay is gone")
	assert_true(m.find_children("*", "ShaderWarmup", true, false).is_empty(), "the warm-up is gone")
	assert_true(not _tree().paused, "the tree runs again")
	assert_eq(m.pause_menu.process_mode, Node.PROCESS_MODE_ALWAYS, "the pause menu is back")
	var rig := m.local_player.get_node("CameraRig") as CameraRig
	assert_true(m.get_viewport().get_camera_3d() == rig.get_camera(), "the match camera is current again")
	await _free(m, s)


func test_networked_session_never_takes_the_staged_open() -> void:
	var s := NetSession.new()
	s.name = "W1cLanSession"
	s.isolated = true
	_root().add_child(s)
	s.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()  # id 1, no solo flag: a Host (networked)
	s.lobby.host_open(2, 1, "Host")
	s.lobby.state.start()
	AppFlow.solo = false
	var probe: MatchRoot = _MatchScene.instantiate()
	probe.session_override = s
	probe.open_path = MatchRoot.OpenPath.STAGED
	assert_true(bool(probe.session_facts()["networked"]), "the session is networked")
	assert_true(not probe.staged_open_wanted(), "decided before anything is built: no staged open")
	assert_true(probe.map == null, "the decision built nothing")
	probe.free()
	var m := _match(s, MatchRoot.OpenPath.STAGED, MatchRoot.MAP_PATH)
	assert_true(not m.opening and m.loading_overlay == null, "the STAGED opt-in still takes begin() when networked")
	assert_true(m.networked_match and m.director.running, "today's networked begin()")
	assert_true(m.warmup_report.is_empty() and m.find_children("*", "ShaderWarmup", true, false).is_empty(), "no warm-up")
	await _free(m, s)
	AppFlow.session = null


func test_quit_mid_open_stops_it() -> void:
	var s := _solo_session("W1cQuitSession")
	var back: Array = []
	var m := _match(s, MatchRoot.OpenPath.STAGED, MatchRoot.MAP_PATH, back)
	var n := 0
	while m.opening and m.local_player == null and n < MAX_FRAMES:
		await _tree().process_frame
		n += 1
	assert_true(m.opening, "still opening when the player quits")
	m.quit_to_menu()
	assert_true(not m.opening, "the open stopped")
	assert_true(not _tree().paused, "the tree runs")
	assert_eq(back, [AppFlow.MENU_SCENE], "quit goes to the menu")
	await _frames(3)
	assert_true(not m.director.running, "the director never started")
	assert_true(m.find_children("*", "ShaderWarmup", true, false).is_empty() and m.loading_overlay == null, "nothing of the open is left")
	await _free(m, s)


func test_freed_mid_open_leaves_the_tree_running() -> void:
	var s := _solo_session("W1cFreeSession")
	var m := _match(s, MatchRoot.OpenPath.STAGED, MatchRoot.MAP_PATH)
	await _frames(4)
	assert_true(m.opening and _tree().paused, "opening, tree paused")
	m.queue_free()
	await _frames(3)
	assert_true(not is_instance_valid(m), "the match is gone")
	assert_true(not _tree().paused, "the tree is not left paused")
	await _free(null, s)


## A cheap hash of the built map: every Node3D's path and transform, every mesh's AABB, every collision shape's class
## and size data (tests/kit_hash.gd's idea, stage A scope; stage B hashes the mesh arrays too).
static func _map_hash(map: Node) -> String:
	return "\n".join(_map_lines(map)).md5_text()


## One line per node; an engine-made name's counter ("@MeshInstance3D@123") is process-wide, so it is folded.
static func _map_lines(map: Node) -> PackedStringArray:
	var auto_name := RegEx.create_from_string("@[0-9]+")
	var parts := PackedStringArray()
	for n in map.find_children("*", "", true, false):
		var line := auto_name.sub(str(map.get_path_to(n)), "@#", true)
		if n is Node3D:
			line += " " + str((n as Node3D).transform)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			line += " " + str((n as MeshInstance3D).mesh.get_aabb())
		if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			line += " mm%d" % (n as MultiMeshInstance3D).multimesh.instance_count
		if n is CollisionShape3D and (n as CollisionShape3D).shape != null:
			var sh := (n as CollisionShape3D).shape
			line += " " + sh.get_class() + str(sh.get("size")) + str(sh.get("radius")) + str(sh.get("height"))
		parts.append(line)
	return parts


static func _director_state(m: MatchRoot) -> Dictionary:
	var d := m.director
	var players := {}
	for id in d.all_players():
		var p: Pawn = d.player(id)
		players[id] = [p.squad_id, p.class_id, p.global_position, p.drop_state, int(p.life)]
	return {"seed": d.match_seed, "running": d.running, "drop": d.drop_active, "from": d.carrier_from, "to": d.carrier_to,
			"t": d.carrier_t, "ticks": d.tick_count, "zone": [d.rules.zone_center(), d.rules.zone_radius()], "players": players}


static func _loot_state(m: MatchRoot) -> Array:
	var out: Array = []
	for id in m.loot.items:
		out.append([id, m.loot.items[id]["item_id"], m.loot.items[id]["pos"]])
	return out


static func _props_state(m: MatchRoot) -> Array:
	return [m.world_props.states.duplicate(), m.world_props.breakables.keys(), m.world_props.chests.keys(), m.world_props.doors.keys()]


func test_staged_and_begin_reach_the_same_state() -> void:
	var states: Array = []
	for path: MatchRoot.OpenPath in [MatchRoot.OpenPath.SYNC, MatchRoot.OpenPath.STAGED]:
		var s := _solo_session("W1cSameSession%d" % path)
		var m: MatchRoot = _MatchScene.instantiate()
		m.open_path = path
		m.session_override = s
		m.lobby_override = s.lobby.state
		m.seed_override = 4242
		m.map_path_override = MAP_500
		var captured := {}
		var capture := func(_ok: bool) -> void:
			captured["director"] = _director_state(m)
			captured["map"] = _map_hash(m.map)
			captured["lines"] = _map_lines(m.map)
		m.match_opened.connect(capture)
		_root().add_child(m)  # SYNC: begin() inside _ready; STAGED: match_opened at the end of the open
		if path == MatchRoot.OpenPath.SYNC:
			capture.call(true)
		assert_true(await _wait_open(m), "opened (%d)" % path)
		var at_start: Dictionary = captured["director"]
		var hash: String = captured["map"]
		await _tree().physics_frame
		await _tree().physics_frame
		await _tree().process_frame
		assert_true(m.loot.placed, "the loot is placed (%d)" % path)
		states.append({"director": at_start, "map": hash, "lines": captured["lines"], "loot": _loot_state(m), "props": _props_state(m),
				"bots": m.bots.size()})
		await _free(m, s)
	var a: Dictionary = states[0]
	var b: Dictionary = states[1]
	assert_eq(b["director"], a["director"], "the director's state at the start")
	var first_diff := ""
	var la: PackedStringArray = a["lines"]
	var lb: PackedStringArray = b["lines"]
	for i in mini(la.size(), lb.size()):
		if la[i] != lb[i]:
			first_diff = "%s | %s" % [la[i], lb[i]]
			break
	assert_eq(b["map"], a["map"], "the built map (%d / %d nodes; first difference: %s)" % [la.size(), lb.size(), first_diff])
	assert_eq(b["loot"], a["loot"], "the loot spawns")
	assert_true((a["loot"] as Array).size() > 50, "a real loot field (%d items)" % (a["loot"] as Array).size())
	assert_eq(b["props"], a["props"], "the props and their states")
	assert_eq(b["bots"], a["bots"], "the roster")
