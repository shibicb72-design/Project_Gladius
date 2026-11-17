extends "res://tests/test_case.gd"

## M2 H1b commit 5: the first-play coach (scripts/ui/hud_coach.gd, data/coach.json, OQ-COACH) and the layout editor's
## fixed elements. The coach shows once (flag + coach_done false), is saved done when it ends or is skipped, never shows
## without the flag (tests, sims, capture tools, the auto_start path), can be replayed from Settings; each step points at
## its control's real rect on six sizes (fire per shooting mode); steps advance on the action and on timeout; the hints
## are passive (look drags and stick starts pass through) and never pause the match; the coach_done profile key.

const _H1a := preload("res://tests/test_h1a_layout.gd")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _HudScene := preload("res://scenes/ui/hud.tscn")
const _EditorScene := preload("res://scenes/ui/layout_editor.tscn")
const SIZES := [Vector2(2520, 1080), Vector2(2176, 1812), Vector2(1512, 648), Vector2(1152, 959), Vector2(2340, 1080), Vector2(3120, 1440)]
const TMP := "user://test_h1b_coach_profile.json"
const IDS := ["move", "look", "aim", "fire", "cover", "pickup", "map"]

var _h1a: RefCounted
var _nodes: Array = []


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _begin() -> void:
	_h1a = _H1a.new()
	_h1a._begin()
	PlatformServices.dpi_override = 420.0
	AppFlow.coach_route = false
	_rm()


func _end() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_h1a._end()
	AppFlow.coach_route = false
	_TouchHud.move_stick_override = ""
	_rm()


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _pawn() -> Pawn:
	var p := Pawn.new()
	p.setup("hastati", 0)
	p.player_id = 0
	_nodes.append(p)
	return p


## A GameHud stand-in holding a minimap (not bound; the coach only reads `expanded` and the static tap rect).
func _game_hud(sz: Vector2) -> GameHud:
	var hud: GameHud = _HudScene.instantiate()
	_tree().root.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = sz
	hud.minimap = HudMinimap.new()
	_nodes.push_front(hud.minimap)
	_nodes.push_front(hud)
	return hud


## An Interact button shown on the touch HUD (its own refresh off, so it stays visible without a director).
func _interact(touch: Control, hud: GameHud) -> InteractButton:
	var ib := InteractButton.new()
	_tree().root.add_child(ib)
	ib.touch_hud = touch
	ib.set_process(false)
	ib.set_physics_process(false)
	ib.visible = true
	hud.interact_button = ib
	_nodes.push_front(ib)
	return ib


## A coach after the touch HUD in the tree (its _input runs first), ticked by hand.
func _coach(sz: Vector2, touch: Control, me: Pawn, pm: PauseMenu = null, hud: Control = null) -> HudCoach:
	var c := HudCoach.new()
	c.save = SaveService.new(TMP)
	_tree().root.add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	c.size = sz
	c.bind(null, me, touch, pm, hud)
	c.set_process(false)
	_nodes.push_front(c)
	return c


func _start(c: HudCoach) -> void:
	c.tick(float(HudCoach.data()["start_delay_s"]) + 0.01)


func _gap(c: HudCoach) -> void:
	c.tick(float(HudCoach.data()["gap_s"]) + 0.01)


func _step_index(id: String) -> int:
	return IDS.find(id)


func _touch_ev(idx: int, pos: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = down
	_tree().root.push_input(e, true)


func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	_tree().root.push_input(e, true)


func _saved_done() -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(TMP)).get("coach_done", null) if FileAccess.file_exists(TMP) else null


# --- profile key and gate --------------------------------------------------------------------------------------------

func test_coach_done_profile_key_default_saved_loaded_missing() -> void:
	_begin()
	assert_eq(SaveService.defaults()["coach_done"], false, "default false")
	var save := SaveService.new(TMP)
	assert_eq(save.load_profile()["coach_done"], false, "no file: false")
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "gamertag": "X"}))
	f.close()
	assert_eq(save.load_profile()["coach_done"], false, "a profile without the key loads as false")
	f = FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "coach_done": "yes"}))
	f.close()
	assert_eq(save.load_profile()["coach_done"], false, "a non-bool value loads as false")
	var p := save.load_profile()
	p["coach_done"] = true
	save.save_profile(p)
	assert_eq(save.load_profile()["coach_done"], true, "true is saved and loaded")
	assert_eq(_saved_done(), true, "written to the file")
	p["coach_done"] = false
	save.save_profile(p)
	assert_eq(save.load_profile()["coach_done"], false, "false again")
	var no_key := SaveService.defaults()
	no_key.erase("coach_done")
	save.save_profile(no_key)
	assert_eq(_saved_done(), false, "saving a profile without the key writes the default false")
	_end()


func test_gate_needs_the_flag_and_coach_done_false() -> void:
	_begin()
	assert_true(HudCoach.is_enabled(), "data switch on")
	assert_true(not HudCoach.wanted(false, {}), "no flag, empty profile (the test default): no coach")
	assert_true(not HudCoach.wanted(false, {"coach_done": false}), "no flag: no coach")
	assert_true(HudCoach.wanted(true, {}), "flag, coach_done missing: coach")
	assert_true(HudCoach.wanted(true, {"coach_done": false}), "flag, coach_done false: coach")
	assert_true(not HudCoach.wanted(true, {"coach_done": true}), "flag, coach_done true: no coach")
	HudCoach.data()["enabled"] = false
	assert_true(not HudCoach.wanted(true, {}), "data switch off: no coach")
	HudCoach.data()["enabled"] = true
	AppFlow.coach_route = true
	assert_true(AppFlow.take_coach_route(), "the flag is taken")
	assert_true(not AppFlow.take_coach_route(), "and cleared (one match per lobby start)")
	AppFlow.coach_route = true
	AppFlow.end_session()
	assert_true(not AppFlow.coach_route, "leaving the session clears it")
	# Only the lobby screen's match start sets the flag: no other script or tool does.
	var writers: Array = []
	for dir in ["res://scripts", "res://tools"]:
		_scan(dir, writers)
	assert_eq(writers, ["res://scripts/ui/lobby.gd"], "only lobby.gd sets AppFlow.coach_route = true (%s)" % [writers])
	var lobby_src := (load("res://scripts/ui/lobby.gd") as GDScript).source_code
	var at := lobby_src.find("func _on_match_starting")
	assert_true(at >= 0 and lobby_src.find("AppFlow.coach_route = true", at) < lobby_src.find("AppFlow.go(", at), "set in _on_match_starting before the scene change")
	_end()


func _scan(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd") and FileAccess.get_file_as_string(dir.path_join(f)).contains("coach_route = true"):
			out.append(dir.path_join(f))
	for s in d.get_directories():
		_scan(dir.path_join(s), out)


# --- real matches: once, saved, the second match, replay ---------------------------------------------------------------

## A match on the test fixture; `auto` = the auto_start / use_map_select path (as the menu, drop_capture and
## test_alesia_1km start one), else begin() by hand.
func _match(auto: bool) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.bake_navmesh = false
	m.fill_bots = false
	m.seed_override = 31337
	m.map_path_override = MatchRoot.MAP_PATH
	m.auto_start = auto
	_tree().root.add_child(m)
	if not auto:
		await _tree().process_frame
		m.director.load_config()
		assert_true(m.begin(), "match begins")
	await _tree().process_frame
	await _tree().process_frame
	return m


func _free_match(m: MatchRoot) -> void:
	m.queue_free()
	await _tree().process_frame
	await _tree().process_frame


func test_real_match_shows_once_saves_and_replays() -> void:
	_begin()
	var old_size := _tree().root.size
	_tree().root.size = Vector2i(2520, 1080)
	# 1. No flag, AppFlow.profile = {} (the test default), the auto_start / use_map_select path: no coach.
	AppFlow.profile = {}
	var m: MatchRoot = await _match(true)
	assert_true(m.use_map_select, "fixture: the auto_start path")
	assert_true(m.hud.coach == null, "no flag: no coach on the auto_start path")
	assert_true(m.find_children("*", "HudCoach", true, false).is_empty(), "no coach node")
	await _free_match(m)
	# Also a begin() by hand with a profile that never finished the coach: still no flag, no coach.
	AppFlow.profile = {"coach_done": false}
	m = await _match(false)
	assert_true(m.hud.coach == null, "no flag: no coach even with coach_done false")
	await _free_match(m)
	# 2. Flag (the lobby's match start) + coach_done false: the coach shows; finishing saves coach_done at once.
	var save := SaveService.new(TMP)
	var prof := save.load_profile()
	save.save_profile(prof)
	AppFlow.profile = save.load_profile()
	AppFlow.coach_route = true
	m = await _match(false)
	assert_true(not AppFlow.coach_route, "the match took the flag")
	var c: HudCoach = m.hud.coach
	assert_true(c != null and is_instance_valid(c), "flag + coach_done false: the coach is built")
	if c == null:
		_tree().root.size = old_size
		await _free_match(m)
		_end()
		return
	c.save = save
	var hud_parent := m.get_node("Hud")
	assert_eq(c.get_parent(), hud_parent, "a sibling of the HUD nodes")
	assert_true(c.get_index() > m.hud.radar.get_index() and c.get_index() > (m.get_node("Hud/TouchHud") as Node).get_index(), "after the touch HUD and the radar (its _input sees Skip first)")
	assert_eq(c.z_index, 1, "drawn over the HUD siblings")
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	c.set_process(false)
	for i in 60:
		if c.is_done():
			break
		c.tick(5.0)
	assert_true(c.is_done() and not c.skipped, "the sequence ends (%s, %s)" % [c.phase, c.paused_reason])
	assert_eq(_saved_done(), true, "coach_done saved to the profile file at once")
	assert_eq(AppFlow.profile.get("coach_done"), true, "and in the loaded profile")
	var hows: Array = []
	for h in c.history:
		hows.append(h["id"])
	assert_eq(hows.size(), IDS.size(), "every step was shown or skipped once: %s" % [c.history])
	assert_true(not _tree().paused and is_equal_approx(Engine.time_scale, 1.0), "the match was never paused")
	await _free_match(m)
	# 3. A second real match: coach_done is set, no coach.
	AppFlow.coach_route = true
	m = await _match(false)
	assert_true(m.hud.coach == null, "a second match does not show it")
	await _free_match(m)
	# 4. Replay: the Settings row sets coach_done false; the next flagged match shows it again.
	var panel := SettingsPanel.new()
	panel.save = save
	_tree().root.add_child(panel)
	assert_eq(panel.coach_button.text, str(HudCoach.data()["settings"]["replay_text"]), "row: Replay the coach")
	panel.replay_coach()
	assert_eq(_saved_done(), false, "the row stores coach_done false")
	assert_eq(AppFlow.profile.get("coach_done"), false, "AppFlow.profile follows")
	assert_eq(panel.coach_button.text, str(HudCoach.data()["settings"]["replay_pending_text"]), "row: shows next match")
	panel.toggle_minimap_rotate()  # another row's persist() keeps coach_done
	assert_eq(_saved_done(), false, "another Settings change keeps coach_done")
	panel.toggle_minimap_rotate()
	panel.free()
	AppFlow.coach_route = true
	m = await _match(false)
	assert_true(m.hud.coach != null, "after Replay the next flagged match shows the coach again")
	if m.hud.coach != null:
		m.hud.coach.save = save
	await _free_match(m)
	_tree().root.size = old_size
	_end()


# --- Skip ---------------------------------------------------------------------------------------------------------------

func test_skip_ends_it_saves_and_is_consumed() -> void:
	_begin()
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		for sz in [Vector2(2520, 1080), Vector2(1512, 648)]:
			_rm()
			var touch: Control = _h1a._new_touch(sz)
			_nodes.push_front(touch)
			var me := _pawn()
			var c := _coach(sz, touch, me)
			var tag := "%s %s" % [stick, sz]
			var skip := HudCoach.skip_rect(sz)
			assert_true(skip.end.x < sz.x * 0.5 and not skip.intersects(touch.get_look_area_rect()), "%s: Skip in the left half, outside the look area" % tag)
			# Before the first hint Skip is not there: a press on its place starts the stick as usual.
			assert_true(not c.skip_visible(), "%s: no Skip before the first hint" % tag)
			_touch_ev(3, skip.get_center(), true)
			_drag(3, skip.get_center() + Vector2(0, 90), Vector2(0, 90))
			touch._process(1.0 / 60.0)
			assert_true(touch._move_touch == 3, "%s: without Skip the press is a stick start" % tag)
			_touch_ev(3, skip.get_center() + Vector2(0, 90), false)
			touch._process(1.0 / 60.0)
			_start(c)
			assert_true(c.showing_hint() and c.skip_visible(), "%s: the first hint and Skip show" % tag)
			touch.provider.move_value = Vector2.ZERO
			_touch_ev(4, skip.get_center(), true)
			assert_true(c.is_done() and c.skipped, "%s: Skip ends the whole sequence" % tag)
			assert_eq(c.history[-1]["how"], "skipped", "%s: recorded as skipped" % tag)
			assert_eq(_saved_done(), true, "%s: coach_done saved at once" % tag)
			assert_eq(touch._move_touch, -1, "%s: the Skip press is consumed (no stick start)" % tag)
			assert_eq(touch._look_touch, -1, "%s: and no look touch" % tag)
			_touch_ev(4, skip.get_center(), false)
			touch._process(1.0 / 60.0)
			assert_true(not c.visible, "%s: hidden after Skip" % tag)
	_end()


# --- advancing -------------------------------------------------------------------------------------------------------

func test_steps_advance_on_the_action() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	AppFlow.profile = {"shooting_mode": "advanced"}
	var touch: Control = _h1a._new_touch(sz)
	_nodes.push_front(touch)
	touch.set_cover_slot(true, true, false)
	var hud := _game_hud(sz)
	var me := _pawn()
	var c := _coach(sz, touch, me, null, hud)
	_start(c)
	assert_eq(c.current_id(), "move", "first: move")
	c.tick(0.1)
	me.position += Vector3(1.2, 0, 0)
	c.tick(0.1)
	assert_eq(c.current_id(), "move", "1.2 m is not yet the move")
	me.position += Vector3(0, 0, 1.2)
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "move", "how": "action"}, "walking 2 m advances move")
	assert_eq(c.phase, HudCoach.PHASE_GAP, "a short gap")
	assert_true(not c.showing_hint() and c.skip_visible(), "no hint in the gap, Skip stays")
	_gap(c)
	assert_eq(c.current_id(), "look", "then look")
	c.tick(0.1)
	me.rotation.y += deg_to_rad(30.0)
	c.tick(0.1)
	me.rotation.y -= deg_to_rad(20.0)
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "look", "how": "action"}, "turning 50 degrees in total advances look")
	_gap(c)
	assert_eq(c.current_id(), "aim", "then aim")
	me.aiming = true
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "aim", "how": "action"}, "raising the sight advances aim")
	me.aiming = false
	_gap(c)
	assert_eq(c.current_id(), "fire", "then fire")
	assert_eq(c.target_key(c.current_step()), "fire_right", "Advanced: points at Fire")
	me.fired.emit()
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "fire", "how": "action"}, "a shot advances fire")
	_gap(c)
	assert_eq(c.current_id(), "cover", "then cover (the Cover button is offered)")
	var cover := CoverController.new({})
	me.cover = cover
	cover.state = CoverController.State.IN_COVER
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "cover", "how": "action"}, "being in cover advances cover")
	me.cover = null
	_gap(c)
	assert_eq(c.current_id(), "pickup", "then pick up")
	assert_eq(c.phase, HudCoach.PHASE_WAIT, "no pickup in reach (no director): waiting, nothing shown")
	assert_true(not c.showing_hint() and not c.skip_visible(), "nothing shown while waiting")
	# A pickup in reach. A real pickup target needs a director with loot, so the step is put on screen by hand (as the
	# wait would once applies() is true); then an Interact press on the touch provider (the call the button and the prompt
	# make) advances it.
	var ib := _interact(touch, hud)
	assert_true(c.target_rect("interact").is_equal_approx(ib.get_touch_rect()), "the Interact button's rect is the pick-up target")
	c._begin_show()
	assert_true(not c.action_done("interacted"), "no press yet")
	touch.provider.trigger_action("interact")
	assert_true(c.action_done("interacted"), "an interact press counts as the pick up")
	touch.provider.release_action("interact")
	c._end_step("action")
	ib.visible = false
	_gap(c)
	assert_eq(c.current_id(), "map", "then the map")
	assert_true(c.showing_hint(), "the map hint shows")
	hud.minimap.expanded = true
	c.tick(0.1)
	assert_eq(c.history[-1], {"id": "map", "how": "action"}, "opening the map advances the last step")
	assert_true(c.is_done() and not c.skipped, "the sequence is finished")
	assert_eq(_saved_done(), true, "coach_done saved")
	_end()


func test_steps_advance_on_timeout_and_skip_what_cannot_apply() -> void:
	_begin()
	var sz := Vector2(2176, 1812)
	AppFlow.profile = {"shooting_mode": "simple"}
	var touch: Control = _h1a._new_touch(sz)
	_nodes.push_front(touch)
	var me := _pawn()
	var c := _coach(sz, touch, me)  # no GameHud: no minimap; no Cover button offered (LAN-like); no director
	var steps: Array = HudCoach.data()["steps"]
	_start(c)
	for id in ["move", "look", "aim", "fire"]:
		assert_eq(c.current_id(), id, "%s shows" % id)
		assert_true(c.showing_hint(), "%s: a hint is on screen" % id)
		var t := float(steps[_step_index(id)]["timeout_s"])
		c.tick(t - 0.2)
		assert_eq(c.current_id(), id, "%s: still shown just before its timeout" % id)
		c.tick(0.3)
		assert_eq(c.history[-1], {"id": id, "how": "timeout"}, "%s advances on its timeout" % id)
		if id == "fire":
			break
		_gap(c)
	# Simple mode: the fire hint points at the crosshair with the Simple wording.
	_gap(c)
	# Cover: no Cover button (LAN client / no controller): skipped at once; pickup waits wait_s then is skipped; no map.
	assert_eq(c.current_id(), "pickup", "cover is skipped (not applicable), pickup waits")
	assert_eq(c.history[-1], {"id": "cover", "how": "not_applicable"}, "cover recorded as not applicable")
	assert_eq(c.phase, HudCoach.PHASE_WAIT, "pickup: waiting")
	c.tick(float(steps[_step_index("pickup")]["wait_s"]) - 0.5)
	assert_eq(c.phase, HudCoach.PHASE_WAIT, "still waiting")
	c.tick(1.0)
	assert_true(c.is_done(), "pickup and map skipped, the sequence ends")
	assert_eq(c.history.slice(-2), [{"id": "pickup", "how": "not_applicable"}, {"id": "map", "how": "not_applicable"}], "both recorded")
	assert_eq(_saved_done(), true, "coach_done saved")
	# A LAN client (director not authoritative): the pickup step never applies even with a pickup button.
	var d := MatchDirector.new()
	d.authoritative = false
	_nodes.append(d)
	var c2 := _coach(sz, touch, me)
	c2.director = d
	assert_true(not c2.applies(steps[_step_index("pickup")]), "LAN client: no pick-up step")
	_end()


func test_pause_rules_freeze_and_resume() -> void:
	_begin()
	var sz := Vector2(2520, 1080)
	var touch: Control = _h1a._new_touch(sz)
	_nodes.push_front(touch)
	var pm: PauseMenu = _h1a._pause(sz)
	_nodes.push_front(pm)
	var hud := _game_hud(sz)
	var me := _pawn()
	var c := _coach(sz, touch, me, pm, hud)
	# The drop: nothing shows until the pawn is on the ground.
	me.drop_state = Pawn.Drop.ABOARD
	c.tick(30.0)
	assert_eq(c.paused_reason, "drop", "aboard: paused")
	assert_true(not c.visible and c.phase == HudCoach.PHASE_START, "nothing shown, the start delay has not run")
	me.drop_state = Pawn.Drop.FALLING
	c.tick(30.0)
	assert_eq(c.paused_reason, "drop", "falling: paused")
	me.drop_state = Pawn.Drop.NONE
	_start(c)
	assert_eq(c.current_id(), "move", "landed: the first hint")
	c.tick(3.0)
	var at := c.phase_s
	for case in ["menu", "suspended", "downed", "dead", "map", "hud_hidden"]:
		match case:
			"menu":
				pm.is_open = true
			"suspended":
				touch.set_suspended(true)
			"downed":
				me.life = Pawn.Life.DOWNED
			"dead":
				me.life = Pawn.Life.DEAD
			"map":
				hud.minimap.expanded = true
			"hud_hidden":
				hud.visible = false
		c.tick(100.0)
		assert_true(c.paused_reason != "", "%s: paused (%s)" % [case, c.paused_reason])
		assert_true(not c.visible and not c.showing_hint() and not c.skip_visible(), "%s: hint and Skip hidden" % case)
		assert_eq(c.current_id(), "move", "%s: the step is kept" % case)
		assert_true(is_equal_approx(c.phase_s, at), "%s: its timer is frozen" % case)
		pm.is_open = false
		touch.set_suspended(false)
		me.life = Pawn.Life.ALIVE
		hud.minimap.expanded = false
		hud.visible = true
		c.tick(0.0)
		assert_true(c.showing_hint(), "%s over: the same hint shows again" % case)
	var t := float(HudCoach.data()["steps"][0]["timeout_s"])
	c.tick(t - at - 0.2)
	assert_eq(c.current_id(), "move", "resumed where it was: still move just before the rest of its timeout")
	c.tick(0.3)
	assert_eq(c.history[-1], {"id": "move", "how": "timeout"}, "then it times out")
	# The map step is the exception: there the expanded map is the action, not a pause.
	c.index = _step_index("map")
	c._begin_show()
	hud.minimap.expanded = true
	assert_eq(c.pause_reason(), "", "the expanded map does not pause the map step")
	_end()


# --- geometry: each step points at its control on six sizes --------------------------------------------------------------

func test_each_step_points_at_its_controls_real_rect_on_six_sizes() -> void:
	_begin()
	var L: Dictionary = HudCoach.data()["layout"]
	for dpi in [420.0, 373.0]:
		PlatformServices.dpi_override = dpi
		for sz in SIZES:
			for mode in ["advanced", "simple"]:
				AppFlow.profile = {"shooting_mode": mode}
				var touch: Control = _h1a._new_touch(sz)
				touch.set_cover_slot(true, true, false)
				var hud := _game_hud(sz)
				var ib := _interact(touch, hud)
				var me := _pawn()
				var c := _coach(sz, touch, me, null, hud)
				var u := HudArrangement.unit(sz)
				var view := Rect2(Vector2.ZERO, sz)
				var expect := {"move": touch.get_move_visual_rect(), "aim": touch.get_button_rect("aim"),
					"fire": touch.get_button_rect("fire_right") if mode == "advanced" else HudCoach.crosshair_rect(sz),
					"cover": touch.get_button_rect("swap_shoulder"), "pickup": ib.get_touch_rect(),
					"map": HudMinimap.tap_rect(sz)}
				var keep_clear := {"crosshair": HudCoach.crosshair_rect(sz), "objective": HudArrangement.objective_rect(sz),
					"banner": HudArrangement.banner_rect(sz), "weapon_block": HudArrangement.weapon_block_rect(sz)}
				var texts := {}
				for i in IDS.size():
					var tag := "%s dpi %d %s %s" % [sz, dpi, mode, IDS[i]]
					c.index = i
					c._begin_show()
					assert_true(c.applies(c.current_step()) or IDS[i] == "pickup", "%s: applies" % tag)
					var h := c.hint_layout(sz)
					assert_true(not h.is_empty(), "%s: a layout" % tag)
					if h.is_empty():
						continue
					var target: Rect2 = h["target"]
					if expect.has(IDS[i]):
						assert_true((expect[IDS[i]] as Rect2).is_equal_approx(target), "%s: target %s is the control's real rect %s" % [tag, target, expect[IDS[i]]])
					else:
						assert_true(touch.get_look_area_rect().encloses(target), "%s: the look ring %s is inside the look area" % [tag, target])
					var tip: Vector2 = h["tip"]
					assert_true(target.grow(float(L["ring_pad_units"]) * u + 2.0).has_point(tip), "%s: the pointer ends at the control (%s, %s)" % [tag, tip, target])
					var bubble: Rect2 = h["bubble"]
					assert_true(view.encloses(bubble), "%s: hint %s on screen" % [tag, bubble])
					var ring: Rect2 = h["ring_box"]
					assert_true(not bubble.intersects(ring), "%s: the hint does not cover the control it points at" % tag)
					for k in keep_clear:
						assert_true(not bubble.intersects(keep_clear[k]), "%s: the hint %s clear of the %s %s" % [tag, bubble, k, keep_clear[k]])
					assert_true(not bubble.intersects(HudCoach.skip_rect(sz)), "%s: clear of Skip" % tag)
					texts[IDS[i]] = h["text"]
				var want_fire: String = HudCoach.data()["steps"][3]["text_by_mode"][mode]
				assert_eq(texts.get("fire", ""), want_fire, "%s %s: fire wording per shooting mode" % [sz, mode])
				for n in [c, ib, hud.minimap, hud, touch]:
					_nodes.erase(n)
					n.free()
	_end()


# --- passive ---------------------------------------------------------------------------------------------------------

func test_hints_are_passive_look_drags_and_stick_starts_pass_through() -> void:
	_begin()
	var counts := {"look": 0, "move": 0}
	for stick in ["virtual", "custom"]:
		_TouchHud.move_stick_override = stick
		for sz in [Vector2(2520, 1080), Vector2(2176, 1812)]:
			AppFlow.profile = {"shooting_mode": "advanced"}
			var touch: Control = _h1a._new_touch(sz)
			_nodes.push_front(touch)
			touch.set_cover_slot(true, true, false)
			var hud := _game_hud(sz)
			_interact(touch, hud)
			var me := _pawn()
			var c := _coach(sz, touch, me, null, hud)
			for i in IDS.size():
				c.index = i
				c.forced_step = i
				c.tick(0.016)
				var h := c.hint_layout(sz)
				if h.is_empty():
					continue
				var b: Rect2 = h["bubble"]
				var pts: Array = [b.get_center(), b.position + b.size * 0.2, (h["from"] + h["tip"]) * 0.5,
					h["ring_c"] + Vector2(0, -h["ring_r"])]
				for p: Vector2 in pts:
					var tag := "%s %s %s at %s" % [stick, sz, IDS[i], p]
					if not Rect2(Vector2.ZERO, sz).has_point(p) or touch._button_at(p) != "" or touch.get_lock_button_rect().has_point(p) \
							or HudCoach.skip_rect(sz).has_point(p) or hud.interact_button.get_touch_rect().has_point(p):
						continue  # on a real control: that control's press, not the hint's
					if p.x >= sz.x * 0.5:
						touch.provider.clear_look()
						_touch_ev(5, p, true)
						_drag(5, p + Vector2(-60, 0), Vector2(-60, 0))
						assert_true(touch.provider.get_look() != Vector2.ZERO, "%s: a look drag through the hint turns the view" % tag)
						_touch_ev(5, p + Vector2(-60, 0), false)
						counts["look"] += 1
					else:
						touch.provider.move_value = Vector2.ZERO
						_touch_ev(6, p, true)
						_drag(6, p + Vector2(0, -100), Vector2(0, -100))
						touch._process(1.0 / 60.0)
						assert_true(touch.provider.move_value.y < 0.0, "%s: a stick start through the hint moves (%s)" % [tag, touch.provider.move_value])
						_touch_ev(6, p + Vector2(0, -100), false)
						counts["move"] += 1
					touch._process(1.0 / 60.0)
				assert_true(not c.is_done(), "%s %s %s: touches on the hint do not skip it" % [stick, sz, IDS[i]])
			for n in [c] + c.find_children("*", "Control", true, false):
				assert_eq((n as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores touches" % n.name)
	assert_true(counts["look"] > 0 and counts["move"] > 0, "both halves were tried: %s" % [counts])
	var src := (load("res://scripts/ui/hud_coach.gd") as GDScript).source_code
	assert_true(not src.contains("func _gui_input") and not src.contains("func _unhandled_input"), "no GUI input handler")
	assert_true(not src.contains("paused =") and not src.contains("time_scale"), "the coach never pauses or slows the match")
	assert_true(not _tree().paused and is_equal_approx(Engine.time_scale, 1.0), "tree not paused, time scale 1")
	_end()


# --- layout editor -----------------------------------------------------------------------------------------------------

func test_old_layout_loads_unchanged_and_editor_shows_fixed_elements() -> void:
	_begin()
	# A layout saved at the current layout_version, with only the old element keys (no coach / panel keys): unchanged.
	var m := HudLayoutModel.new()
	m.set_pos(0, "jump", Vector2(0.7, 0.9))
	m.set_size_pct(0, "aim", 120.0)
	m.set_alpha_pct(2, "reload", 60.0)
	var save := SaveService.new(TMP)
	var prof := SaveService.defaults()
	prof["hud_layouts"] = m.to_dict()
	prof.erase("coach_done")
	save.save_profile(prof)
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TMP))
	assert_eq(int(raw["hud_layouts"]["version"]), HudLayoutModel.current_version(), "fixture: saved at the current version")
	var p := save.load_profile()
	assert_eq(JSON.stringify(p["hud_layouts"]), JSON.stringify(m.to_dict()), "loaded unchanged")
	assert_true(not p["layout_notice_pending"], "no reset notice")
	# M2 H1c item 4: was 2 ("not raised, no default moved" by the coach); the Crouch button raised it to 3.
	assert_eq(HudLayoutModel.current_version(), 3, "layout_version not raised by the coach (3 since M2 H1c's Crouch)")
	# The editor lists and draws the fixed elements at their match rects.
	var ed: Control = _EditorScene.instantiate()
	ed.save = save
	_tree().root.add_child(ed)
	ed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var sz := Vector2(2520, 1080)
	ed.size = sz
	await _tree().process_frame
	await _tree().process_frame
	ed.refresh()
	await _tree().process_frame
	var els: Dictionary = LayoutEditor.fixed_elements(sz)
	assert_eq(els.keys(), ["weapon_block", "objective", "chip", "panel", "minimap_tap", "gear", "coach_skip"], "the fixed elements")
	assert_eq(els["coach_skip"], HudCoach.skip_rect(sz), "Skip at its match rect")
	assert_eq(els["panel"], HudArrangement.panel_rect(sz), "the radar + minimap panel")
	assert_eq(els["minimap_tap"], HudArrangement.minimap_tap_rect(sz), "the minimap tap target")
	assert_eq(els["weapon_block"], HudArrangement.weapon_block_rect(sz), "the weapon block")
	assert_eq(ed.drawn_fixed, els.keys(), "every fixed element is drawn")
	for k in LayoutEditor.FIXED_TOUCH:
		assert_true(els.has(k), "%s is a fixed touch target" % k)
	assert_true(not ed.get_node("FixedElements").get_index() > ed.preview.get_index(), "drawn under the live buttons")
	# A button dropped on Skip: warned by name, never blocked.
	ed.select_element("jump")
	var skip := HudCoach.skip_rect(sz)
	# Inside Skip but away from the screen edge, so Jump stays on screen at every checked size (off-screen would block).
	ed.move_selected_to((skip.position + skip.size * Vector2(0.9, 0.6)) / sz)
	var found := false
	for it in ed.issues:
		if it["kind"] == "overlap" and it["element"] == "jump" and it["size"] == Vector2i(sz) and str(it["text"]).contains("coach skip"):
			found = true
	assert_true(found, "overlap with the coach Skip is reported: %s" % [ed.issues])
	assert_true(not ed.is_blocked(), "overlap alone does not block Save: %s" % [ed.issues])
	ed.free()
	_end()
