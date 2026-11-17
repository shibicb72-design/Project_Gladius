extends "res://tests/test_case.gd"
## M2 H1c item 1: the Cover button after a REAL landing on alesia_1km. The main menu's only way to play is Host
## (main_menu.gd _on_host -> NetSession.host_game -> lobby -> Start), so Shibi's "offline" match is a hosted session
## with no client: MatchRoot.networked_match is true there, Pawn.in_lan_session() was true, _ensure_cover never built
## the controller and the first-person slot between Swap and Jump stayed empty. Now a LAN session also needs another
## human in the match (Pawn._match_has_remote_human). Both routes run the real begin(): map_select (alesia_1km), the
## carrier, Jump through the input layer, the fall and the landing in Pawn._apply_fall, with the real match HUD.

const _MatchScene := preload("res://scenes/match/match.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## hosted: the menu route (an isolated NetSession hosts, the lobby opens and starts, as lobby.gd does). remote_human:
## a second human joins the lobby before the start (a real LAN match). Not hosted: the auto_start route without a
## session. The flags are the ones MatchRoot._ready sets for auto_start (drop_from_sky, ground_loot, use_map_select).
func _real_match(hosted: bool, remote_human := false) -> Array:
	var s: NetSession = null
	if hosted:
		s = NetSession.new()
		s.name = "TH1cHost"
		s.isolated = true
		_tree().root.add_child(s)
		assert_eq(s.host_game(), OK, "host_game")
		s.lobby.host_open(2, 3, "Host")
		if remote_human:
			assert_true(s.lobby.state.add_human(2, "Client"), "a second human joins the lobby")
		assert_true(s.lobby.start_match(), "host lobby starts")
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	if s != null:
		m.session_override = s
		m.lobby_override = s.lobby.state
		m.seed_override = s.lobby.match_seed
	m.seed_override = 4242  # one carrier path and landing spot every run
	m.drop_from_sky = true
	m.ground_loot = true
	m.use_map_select = true
	_tree().root.add_child(m)
	await _tree().physics_frame
	assert_true(m.begin(), "begin")
	return [m, s]


## Jump off the carrier through the input layer and wait for the real landing (Pawn._apply_fall: is_on_floor -> NONE).
func _land(m: MatchRoot) -> void:
	await _tree().physics_frame
	await _tree().physics_frame
	Input.action_press("jump")
	await _tree().physics_frame
	await _tree().physics_frame
	Input.action_release("jump")
	var pawn := m.local_player
	for i in 60 * 30:
		await _tree().physics_frame
		if pawn.drop_state == Pawn.Drop.NONE:
			break
	for i in 6:
		await _tree().physics_frame
	await _tree().process_frame
	await _tree().process_frame


func _free(pair: Array) -> void:
	(pair[0] as Node).queue_free()
	var s: NetSession = pair[1]
	if s != null:
		s.leave()
		s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame
	await _tree().process_frame


## A one-box cover wall (the CoverProbe contract) whose face is `dist_m` ahead of the pawn's feet. Axis-aligned, as the
## map's cover is (CoverProbe measures box extents along world x / z): the pawn is turned to face -z first.
func _wall_ahead(m: MatchRoot, dist_m: float) -> StaticBody3D:
	var pawn := m.local_player
	pawn.rotation.y = 0.0
	var ahead := Vector3.FORWARD
	var wall := StaticBody3D.new()
	wall.add_to_group(&"cover_wall")
	wall.position = pawn.global_position + ahead * (dist_m + 0.5) + Vector3.UP * 1.1
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	wall.add_child(shape)
	m.add_child(wall)
	return wall


## The whole player-facing check after a real landing: Shoulder on the carrier, then the Cover button in first person,
## its highlight near a wall, and a press through the touch HUD's route entering cover.
func _check_cover_after_landing(m: MatchRoot, tag: String) -> void:
	var pawn := m.local_player
	var touch: Control = m.get_node("Hud/TouchHud")
	var key: String = touch.SHOULDER_KEY
	var b: Button = touch._buttons[key]
	await _tree().process_frame
	assert_eq(pawn.drop_state, Pawn.Drop.ABOARD, "%s: on the carrier" % tag)
	assert_true(not touch.cover_slot_active and b.visible and b.text == "Shoulder", "%s: the carrier shows Shoulder" % tag)
	await _land(m)
	assert_eq(pawn.drop_state, Pawn.Drop.NONE, "%s: landed" % tag)
	assert_true(pawn.is_on_floor(), "%s: standing on a floor" % tag)
	assert_true(touch.first_person_active, "%s: first person after landing" % tag)
	assert_true(not pawn.in_lan_session(), "%s: no other human, so not a LAN session" % tag)
	assert_true(pawn.cover != null, "%s: _ensure_cover built the controller on the real path" % tag)
	assert_true(pawn.cover_button_available(), "%s: the pawn offers the Cover button" % tag)
	assert_true(touch.cover_slot_active, "%s: the slot is the Cover button" % tag)
	assert_true(not touch.is_first_person_slot_hidden(key), "%s: the first-person rule does not hide it" % tag)
	assert_true(b.visible, "%s: the Cover button is drawn" % tag)
	assert_eq(b.text, str(DataRegistry.new().load_file("res://data/ui.json")["cover_button"]["label"]), "%s: Cover label" % tag)
	assert_eq(touch._action_of(key), "cover", "%s: the slot presses cover" % tag)
	# Near a wall it highlights.
	var wall := _wall_ahead(m, 1.1)
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	assert_true(pawn.cover_button_valid(), "%s: a wall face 1.1 m ahead is valid" % tag)
	assert_true(touch.cover_slot_valid, "%s: the Cover button highlights" % tag)
	# A press through the touch HUD's route: provider.trigger_action -> router -> MatchRoot -> Pawn.handle_action_press.
	var got: Array = []
	m.router.action_triggered.connect(func(a: String) -> void: got.append(a))
	touch.provider.trigger_action("cover")
	assert_true(got.has("cover"), "%s: the router re-emits cover" % tag)
	assert_eq(pawn.cover.state if pawn.cover != null else -1, CoverController.State.ENTERING, "%s: the press enters cover at once" % tag)
	for i in 60:
		await _tree().physics_frame
	assert_true(pawn.in_cover(), "%s: in cover after the entry" % tag)
	await _tree().process_frame
	assert_true(touch.cover_slot_engaged, "%s: the Cover button shows the engaged look" % tag)
	wall.queue_free()


## The menu route Shibi plays (Host, no client). Failed before the fix: networked_match true -> no controller, hidden slot.
func test_solo_host_menu_route_shows_cover_after_a_real_landing() -> void:
	var pair := await _real_match(true)
	var m: MatchRoot = pair[0]
	assert_true(m.networked_match, "the solo host is still a networked match (unchanged)")
	await _check_cover_after_landing(m, "solo host")
	await _free(pair)


## The auto_start route without a session (guard: it worked before and must keep working).
func test_offline_auto_start_route_shows_cover_after_a_real_landing() -> void:
	var pair := await _real_match(false)
	var m: MatchRoot = pair[0]
	assert_true(not m.networked_match, "no session: not networked")
	await _check_cover_after_landing(m, "offline")
	await _free(pair)


## A real LAN match (a second human in the lobby) keeps the C1b gate: no controller, no Cover button.
func test_host_with_a_remote_human_keeps_the_lan_gate() -> void:
	var pair := await _real_match(true, true)
	var m: MatchRoot = pair[0]
	var pawn := m.local_player
	var remote := 0
	for id in m.director.all_players():
		if m.director.player(id).net_mode == Pawn.NetMode.HOST_REMOTE:
			remote += 1
	assert_eq(remote, 1, "the second human is a HOST_REMOTE pawn")
	await _land(m)
	assert_eq(pawn.drop_state, Pawn.Drop.NONE, "landed")
	assert_true(pawn.in_lan_session(), "a LAN session")
	assert_true(pawn.cover == null and not pawn.cover_button_available(), "no cover controller, no Cover button")
	var touch: Control = m.get_node("Hud/TouchHud")
	assert_true(not touch.cover_slot_active, "the slot is not the Cover button")
	await _free(pair)
