extends "res://tests/test_case.gd"
## M2U1 stop 3: the restyled lobby and end screen fit every phone size we target.

## The phone sizes ([device px, screen dpi]) come from one place: tests/test_front_end_sizes.gd `SIZES`.
const _Sizes := preload("res://tests/test_front_end_sizes.gd")

const VICTORY := {"winner": 4, "draw": false, "placements": {4: 1, 7: 2, 9: 3}, "kills": {4: 3, 7: 0},
		"local_player_id": 4, "local_squad_id": 4, "squad_count": 3}
const PLACED := {"winner": 3, "draw": false, "placements": {3: 1, 5: 12}, "kills": {5: 2},
		"local_player_id": 5, "local_squad_id": 5, "squad_count": 18}
## "Match over": the longest display-face title.
const MATCH_OVER := {"winner": -1, "draw": false, "placements": {}}


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(n: int) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for i in n:
		await tree.process_frame


## Hosting lobby scene on an isolated loopback session (as tests/test_ui.gd does).
func _host_lobby() -> Lobby:
	var s := NetSession.new()
	s.name = "FrontEndLobbySession"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	s.host_game()
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	_root().add_child(lobby)
	return lobby


func _end_lobby(lobby: Lobby) -> void:
	lobby.free()
	AppFlow.end_session()


func _dp(r: Rect2) -> float:
	return r.size.y * _root().get_screen_transform().get_scale().y / PlatformServices.new().get_dp_scale()


func _inside(outer: Rect2, inner: Rect2) -> bool:
	return outer.grow(0.5).encloses(inner)


func test_lobby_fits_every_phone_size() -> void:
	var prev := _root().size
	for case in _Sizes.SIZES:
		var px: Vector2i = case[0]
		var dpi: float = case[1]
		var tag := "%s/%d dpi" % [px, int(dpi)]
		PlatformServices.dpi_override = dpi
		_root().size = px
		var lobby := _host_lobby()
		await _frames(4)
		var vp := _root().get_visible_rect()
		var bar: Control = lobby.find_child("ActionBar", true, false)
		assert_true(bar != null, "ActionBar present")
		assert_true(_inside(vp, bar.get_global_rect()), "action bar inside the viewport at %s" % tag)
		var n := 0
		for b: Button in lobby.find_children("*", "Button", true, false):
			if not b.is_visible_in_tree() or b in lobby.slot_buttons:
				continue
			n += 1
			var r := b.get_global_rect()
			assert_true(_inside(vp, r), "%s inside the viewport at %s: %s in %s" % [b.text, tag, r, vp])
			assert_true(_dp(r) >= 48.0 - 0.5, "%s >= 48 dp at %s (%.1f)" % [b.text, tag, _dp(r)])
		assert_true(n >= 4, "host sees Back, Class, Mode and Start at %s" % tag)
		var scroll := lobby.rows_box.get_parent() as ScrollContainer
		assert_true(scroll.get_global_rect().end.y <= bar.get_global_rect().position.y + 0.5,
				"roster ends above the action bar at %s" % tag)
		assert_true(scroll.size.y > lobby.slot_buttons[0].size.y * 2.0, "roster taller than two rows at %s" % tag)
		assert_true(lobby.squad_grid.columns >= 1 and lobby.squad_grid.columns <= 3,
				"1 to 3 squad columns at %s (%d)" % [tag, lobby.squad_grid.columns])
		for b in lobby.slot_buttons:
			scroll.ensure_control_visible(b)
			await _frames(2)
			var r := b.get_global_rect()
			assert_true(_inside(scroll.get_global_rect(), r) and _inside(vp, r),
					"row %s scrolls fully into view at %s: %s" % [b.text, tag, r])
			assert_true(_dp(r) >= 48.0 - 0.5, "row %s >= 48 dp at %s" % [b.text, tag])
		var me := lobby.net_lobby.local_id()
		var slots := lobby.state.assign()
		var found := false
		for s in slots:
			if not bool(s["is_bot"]) and int(s["peer_id"]) == me:
				found = true
				var row: Button = lobby.slot_buttons[int(s["player_id"])]
				assert_true(row.has_theme_color_override("font_color"), "own row has a font colour override at %s" % tag)
				assert_eq(row.get_theme_color("font_color"), MenuStyle.color("gold_hi"), "own row is gold_hi at %s" % tag)
		assert_true(found, "the local player has a slot at %s" % tag)
		lobby.set_team_mode("squads")
		await _frames(2)
		assert_eq(lobby.slot_buttons.size(), lobby.state.squad_count * lobby.state.squad_size, "squads: one row per slot")
		assert_true(_inside(vp, bar.get_global_rect()), "squads: action bar inside the viewport at %s" % tag)
		_end_lobby(lobby)
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	AppFlow.lobby = null
	await _frames(1)


func test_end_screen_fits_every_phone_size() -> void:
	var prev := _root().size
	for case in _Sizes.SIZES:
		var px: Vector2i = case[0]
		var dpi: float = case[1]
		PlatformServices.dpi_override = dpi
		_root().size = px
		for r: Dictionary in [VICTORY, PLACED, MATCH_OVER]:
			var end: EndScreen = load("res://scenes/ui/end_screen.tscn").instantiate()
			end.result = r.duplicate(true)
			_root().add_child(end)
			await _frames(4)
			var tag := "%s at %s/%d dpi" % [end.title_label.text, px, int(dpi)]
			var vp := _root().get_visible_rect()
			var buttons := end.find_children("*", "Button", true, false)
			assert_eq(buttons.size(), 1, "one button")
			var br := (buttons[0] as Button).get_global_rect()
			assert_true(_inside(vp, br), "button inside the viewport: %s: %s" % [tag, br])
			assert_true(_dp(br) >= 48.0 - 0.5, "button >= 48 dp: %s" % tag)
			for l: Label in [end.title_label, end.scores_label]:
				var lr := l.get_global_rect()
				assert_true(_inside(vp, lr), "%s inside the viewport: %s: %s" % [l.text, tag, lr])
				assert_true(not lr.intersects(br), "%s clear of the button: %s" % [l.text, tag])
			end.free()
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	AppFlow.lobby = null
	await _frames(1)


func test_end_title_uses_the_display_face_only_without_digits() -> void:
	var end: EndScreen = load("res://scenes/ui/end_screen.tscn").instantiate()
	_root().add_child(end)
	end.show_result(VICTORY.duplicate(true))
	assert_eq(end.title_label.text, "Victory", "victory text")
	assert_true(end.title_label.has_theme_font_override("font"), "victory uses a font override")
	assert_eq(end.title_label.get_theme_font("font"), MenuStyle.DISPLAY_FONT, "victory is set in the display face")
	var lost := VICTORY.duplicate(true)
	lost["local_player_id"] = 7
	lost["local_squad_id"] = 7
	end.show_result(lost)
	assert_eq(end.title_label.text, "Placed 2 of 3", "placement text")
	assert_true(not end.title_label.has_theme_font_override("font"), "digits fall back to the body face")
	end.free()
	AppFlow.lobby = null
