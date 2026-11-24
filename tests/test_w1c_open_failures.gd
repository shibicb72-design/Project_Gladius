extends "res://tests/test_case.gd"
## W1c review fixes: how the staged open (MatchRoot.OpenPath.STAGED) ends when it cannot go on, and what it leaves.
## A stage returning false ends the open cleanly (tree running, overlay gone, pause menu back, match_opened(false)
## once); the abort guard of MatchRoot._open_tick ends it instead of re-running an aborted stage (tested through its
## seam: the guard left set, as an aborted tick leaves it; a build_step() that is not done and counted a script error
## on the open's error watch, against a slow one that did not); Esc during loading does
## nothing; a second staged match after a first one opens like the first; the navigation map sync and the roster land
## in different frames; the early look variant's seam exists on the real match scene.
## Quiet: every failure here runs with quiet_open_errors, so the reason is read from last_open_error and no ERROR line
## reaches the suite log (a real run pushes the same text as an error).

const _MatchScene := preload("res://scenes/match/match.tscn")
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


## A staged match on the test fixture map; `before` runs on the instance before it enters the tree.
func _staged(s: NetSession, back: Array = [], before: Callable = Callable()) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.open_path = MatchRoot.OpenPath.STAGED
	m.session_override = s
	m.lobby_override = s.lobby.state
	m.seed_override = 4242
	m.map_path_override = MatchRoot.MAP_PATH
	m.go_scene = func(p: String) -> void: back.append(p)
	if before.is_valid():
		before.call(m)
	_root().add_child(m)  # auto_start (the default): _ready starts the staged open
	return m


func _wait_open(m: MatchRoot) -> bool:
	var n := 0
	while m.opening and n < MAX_FRAMES:
		await _tree().process_frame
		n += 1
	return not m.opening


func _wait_stage(m: MatchRoot, stage: String) -> bool:
	var at := MatchRoot._OPEN_STAGES.find(stage)
	var n := 0
	while m.opening and m._open_stage < at and n < MAX_FRAMES:
		await _tree().process_frame
		n += 1
	return m.opening and m._open_stage == at


func _free(m: MatchRoot, s: NetSession) -> void:
	if is_instance_valid(m):
		m.queue_free()
	await _frames(2)
	_tree().paused = false
	if is_instance_valid(s):
		s.leave()
		s.queue_free()
	await _frames(1)


## Nothing of the open is left one frame after it ended: no overlay, driver or warm-up, the tree runs, the pause menu
## processes again.
func _assert_open_gone(m: MatchRoot, what: String) -> void:
	assert_true(not m.opening, "%s: not opening" % what)
	assert_true(not _tree().paused, "%s: the tree runs" % what)
	assert_true(m.loading_overlay == null and m.find_children("*", "LoadingOverlay", true, false).is_empty(), "%s: the overlay is gone" % what)
	assert_true(m.get_node_or_null("OpenDriver") == null, "%s: the driver is gone" % what)
	assert_true(m.find_children("*", "ShaderWarmup", true, false).is_empty(), "%s: no warm-up is left" % what)
	assert_eq(m.pause_menu.process_mode, Node.PROCESS_MODE_ALWAYS, "%s: the pause menu processes again" % what)


## Stand-in for a map builder whose build_step() hit a script error: an aborted `-> bool` function returns false to
## its caller, which goes on, and the error reaches the loggers. The seam: the error is counted on the open's watch
## (as the logger would count it) instead of being printed.
class _AbortedBuilder extends Node:
	var calls := 0
	var match_root: MatchRoot

	func build_step() -> bool:
		calls += 1
		match_root._open_watch.script_errors += 1
		return false

	func build_step_label() -> String:
		return "fake_step"


## A builder slice that is simply not done yet (no error).
class _SlowBuilder extends Node:
	func build_step() -> bool:
		return false

	func build_step_label() -> String:
		return "slow_step"


## (a) A stage that returns false (here the start: director.start refuses a mode config with a problem, quietly).
func test_a_failing_stage_ends_the_open_cleanly() -> void:
	var s := _solo_session("W1cFailSession")
	var m := _staged(s, [], func(r: MatchRoot) -> void:
			r.quiet_open_errors = true
			r.fill_bots = false)
	var opened: Array = []
	m.match_opened.connect(func(ok: bool) -> void: opened.append(ok))
	# The config stage keeps a config loaded before it (MatchRoot._open_config): one BrRules rejects.
	m.director.load_config(MatchRoot.MAP_PATH, s.lobby.state.match_length)
	m.director.mode_cfg.erase("default_seed")
	assert_true(m.opening and _tree().paused, "the staged open runs, tree paused")
	assert_true(await _wait_open(m), "the open ended")
	assert_eq(opened, [false], "match_opened(false) once")
	assert_true(m.last_open_error.contains("begin() failed"), "the reason is kept (%s)" % m.last_open_error)
	assert_true(not m.director.running, "the director did not start")
	await _frames(2)
	_assert_open_gone(m, "failed start")
	assert_eq(opened, [false], "still once")
	await _free(m, s)


## (b) The abort guard: the tick after an aborted one finds the guard set and fails the open; the stage never re-runs.
func test_an_aborted_stage_is_not_run_again() -> void:
	var s := _solo_session("W1cAbortSession")
	var m := _staged(s, [], func(r: MatchRoot) -> void: r.quiet_open_errors = true)
	var opened: Array = []
	m.match_opened.connect(func(ok: bool) -> void: opened.append(ok))
	assert_true(await _wait_stage(m, "roster"), "reached the roster stage")
	assert_true(m.local_player == null and m.bots.is_empty(), "no pawn yet")
	# As a roster tick aborted by a script error leaves it: the guard names the stage, _open_stage did not move.
	m._open_in_stage = "roster"
	m._open_tick()
	assert_true(not m.opening, "the open ended")
	assert_eq(opened, [false], "match_opened(false) once")
	assert_true(m.last_open_error.contains("'roster' stage aborted"), "the reason names the stage (%s)" % m.last_open_error)
	assert_true(m.local_player == null and m.bots.is_empty(), "the roster did not run again")
	m._open_tick()
	assert_eq(opened, [false], "a later tick does nothing")
	await _frames(2)
	_assert_open_gone(m, "aborted stage")
	assert_true(m.local_player == null and m.find_children("*", "Pawn", true, false).is_empty(), "no pawn was spawned afterwards")
	await _free(m, s)


## (b) A map build step aborted inside build_step() (a Nil result) ends the open instead of re-running its step.
func test_an_aborted_build_step_ends_the_open() -> void:
	var s := _solo_session("W1cBuildAbortSession")
	var m := _staged(s, [], func(r: MatchRoot) -> void: r.quiet_open_errors = true)
	var opened: Array = []
	m.match_opened.connect(func(ok: bool) -> void: opened.append(ok))
	assert_true(await _wait_stage(m, "map_build"), "reached the map build")
	await _frames(1)  # the first map_build tick added the map
	assert_true(m.opening and m.map != null and m.map.is_inside_tree(), "building")
	# Control: a slice that returns false without an error is a slow build, not a failure.
	var real_builder := m._open_builder
	assert_true(m._open_watch != null, "the open watches for script errors")
	var slow := _SlowBuilder.new()
	m._open_builder = slow
	m._open_tick()
	assert_true(m.opening and opened.is_empty(), "a slow slice keeps the open going")
	slow.free()
	var fake := _AbortedBuilder.new()
	fake.match_root = m
	m._open_builder = fake
	m._open_tick()
	assert_eq(fake.calls, 1, "build_step() was called once")
	assert_true(not m.opening, "the open ended")
	assert_eq(opened, [false], "match_opened(false) once")
	assert_true(m.last_open_error.contains("'fake_step' hit a script error"), "the reason names the step (%s)" % m.last_open_error)
	assert_true(m._open_watch == null, "the watch is removed with the open")
	assert_true(real_builder != null, "the real builder stays with the map (freed with the match)")
	await _frames(2)
	assert_eq(fake.calls, 1, "the step was not run again")
	_assert_open_gone(m, "aborted build step")
	fake.free()
	await _free(m, s)


## (c) Esc while loading opens no menu and leaves the tree paused; the open then ends and the tree runs; Esc works after.
func test_esc_while_loading_does_nothing() -> void:
	var s := _solo_session("W1cEscSession")
	var m := _staged(s)
	var fake := [Input.MOUSE_MODE_VISIBLE]
	m.pause_menu.capture.get_mode = func() -> int: return fake[0]
	m.pause_menu.capture.set_mode = func(v: int) -> void: fake[0] = v
	assert_true(m.pause_menu.pc_controls(), "headless: PC controls (Esc is the pause key)")
	assert_true(await _wait_stage(m, "roster"), "loading")
	for i in 3:
		for pressed in [true, false]:
			var key := InputEventKey.new()
			key.physical_keycode = KEY_ESCAPE
			key.pressed = pressed
			_root().push_input(key, true)
		await _frames(1)
		assert_true(not m.pause_menu.is_open and not m.menu_open, "Esc opens no menu while loading (%d)" % i)
		assert_true(m.opening and _tree().paused, "still loading, the tree paused (%d)" % i)
	assert_true(await _wait_open(m), "the open ended")
	assert_true(m.director.running and not _tree().paused, "the match runs")
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.physical_keycode = KEY_ESCAPE
		key.pressed = pressed
		_root().push_input(key, true)
	assert_true(m.pause_menu.is_open and _tree().paused, "after loading Esc opens the menu (the check above was real)")
	m.pause_menu.close()
	assert_true(not _tree().paused, "closing it resumes")
	await _free(m, s)


## (d) A second staged match after the first ended (quit to menu, freed) opens like the first.
func test_a_second_staged_match_opens_normally() -> void:
	for round in 2:
		var s := _solo_session("W1cAgainSession%d" % round)
		var back: Array = []
		var m := _staged(s, back)
		var opened: Array = []
		m.match_opened.connect(func(ok: bool) -> void: opened.append(ok))
		assert_true(m.opening and _tree().paused, "round %d: the tree is paused from the first frame" % round)
		assert_true(m.loading_overlay != null and m.loading_overlay.is_inside_tree(), "round %d: the overlay is up" % round)
		var paused_all := true
		var n := 0
		while m.opening and n < MAX_FRAMES:
			paused_all = paused_all and _tree().paused
			await _tree().process_frame
			n += 1
		assert_true(not m.opening, "round %d: opened (%d frames)" % [round, n])
		assert_true(paused_all, "round %d: paused all through the open" % round)
		assert_eq(opened, [true], "round %d: match_opened(true) once" % round)
		assert_eq(m.last_open_error, "", "round %d: no failure" % round)
		await _frames(1)
		_assert_open_gone(m, "round %d" % round)
		assert_true(m.director.running, "round %d: the director runs" % round)
		m.quit_to_menu()
		assert_eq(back, [AppFlow.MENU_SCENE], "round %d: quit goes to the menu" % round)
		assert_true(not _tree().paused, "round %d: the tree runs after quitting" % round)
		await _free(m, s)


## Fix 6: the engine syncs the navigation map in the frame after the nav stage; the roster comes at least one frame
## later (data/warmup.json nav_sync_frames), so the two long pieces of work are not one frame.
func test_nav_sync_and_roster_are_different_frames() -> void:
	var nav_at := MatchRoot._OPEN_STAGES.find("nav")
	assert_true(nav_at >= 0 and MatchRoot._OPEN_STAGES[nav_at + 1] == "nav_sync" and MatchRoot._OPEN_STAGES[nav_at + 2] == "roster",
			"nav, nav_sync, roster")
	var s := _solo_session("W1cNavSyncSession")
	var m := _staged(s)
	var nav_done_frame := -1
	var roster_frame := -1
	var n := 0
	while m.opening and roster_frame < 0 and n < MAX_FRAMES:
		await _tree().process_frame
		n += 1
		if nav_done_frame < 0 and m._open_stage > nav_at:
			nav_done_frame = n
		if m.local_player != null:
			roster_frame = n
	assert_true(nav_done_frame > 0 and roster_frame > 0, "both seen")
	assert_true(roster_frame - nav_done_frame >= 2, "the roster ran at least two frames after the nav stage (%d -> %d)" % [nav_done_frame, roster_frame])
	assert_true(await _wait_open(m), "opened")
	await _free(m, s)


## Fix 3: MatchRoot._apply_look_variant calls the real match scene's WorldEnvironment through
## _apply_environment(world, variant); a rename in greybox_art.gd must fail here, not silently drop the early look.
func test_the_early_look_seam_exists_on_the_match_scene() -> void:
	var m: MatchRoot = _MatchScene.instantiate()
	var world := m.get_node_or_null("WorldEnvironment")
	assert_true(world is WorldEnvironment, "the match scene has its WorldEnvironment")
	assert_true(world != null and world.has_method("_apply_environment"), "it has _apply_environment")
	var found := {}
	if world != null and world.get_script() != null:
		for meth: Dictionary in (world.get_script() as Script).get_script_method_list():
			if String(meth["name"]) == "_apply_environment":
				found = meth
	assert_eq((found.get("args", []) as Array).size(), 2, "two arguments: (world, variant)")
	assert_eq((found.get("default_args", []) as Array).size(), 1, "the variant has a default")
	m.free()
