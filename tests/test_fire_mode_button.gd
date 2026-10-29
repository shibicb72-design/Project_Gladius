extends "res://tests/test_case.gd"

func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _tap(point: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.index = 9
		event.position = point
		event.pressed = pressed
		_tree().root.push_input(event, true)


func test_hud_cleanup_releases_pending_button() -> void:
	var tree := _tree()
	var parent := CanvasLayer.new()
	tree.root.add_child(parent)
	var hud := GameHud.new()
	parent.add_child(hud)
	var touch: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	touch.name = "TouchHud"
	parent.add_child(touch)
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var director := MatchDirector.new()
	tree.root.add_child(director)
	hud.bind(director, pawn)
	var pending: WeakRef = weakref(hud.fire_mode_button)
	hud.free()  # before the deferred add_sibling runs
	await tree.process_frame
	await tree.process_frame
	assert_true(pending.get_ref() == null, "pending sibling released with its HUD")
	parent.free()
	pawn.free()
	director.free()


func test_button_consumes_touch_before_hud_and_keeps_choice_on_respawn() -> void:
	var tree := _tree()
	var old_size := tree.root.size
	var old_profile := AppFlow.profile
	AppFlow.profile = {}
	tree.root.size = Vector2i(1512, 648)
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.fill_bots = false
	m.bake_navmesh = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	assert_true(m.begin(), "match starts")
	await tree.process_frame
	await tree.process_frame
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	var button := m.hud.fire_mode_button
	button.refresh()
	assert_true(button.get_parent() == touch.get_parent() and button.get_index() > touch.get_index(), "button after TouchHud")
	assert_true(button.process_physics_priority < m.local_player.process_physics_priority, "mode applied before weapon tick")
	assert_eq(button.label.text, "AUTO", "placeholder data default")
	var weapon := m.local_player.loadout.get_active()
	assert_eq(weapon.fire_mode, "auto", "local mode applied")
	touch.provider.lock_sprint()
	_tap(button.get_touch_rect().get_center())
	assert_eq(weapon.fire_mode, "semi", "one touch toggles exactly once")
	assert_eq(button.label.text, "SEMI", "label follows choice")
	assert_true(not Input.is_action_pressed("fire"), "release never fires")
	assert_eq(touch._move_touch, -1, "no move touch")
	assert_eq(touch._look_touch, -1, "no look touch")
	assert_true(touch.provider.sprint_locked, "sprint lock unchanged")
	var layout: Dictionary = touch.cfg["touch_layout"]
	await tree.create_timer(float(layout["tap_fire_max_s"]) + float(layout["fire_pulse_s"])).timeout
	assert_true(not Input.is_action_pressed("fire"), "no delayed fire pulse")
	# A user layout overlapping the mode button retains the action button's input.
	var original: Dictionary = touch.slot_layout.duplicate(true)
	var point := button.get_touch_rect().get_center()
	touch.apply_slot_layout({"aim": {"pos": [point.x / touch.size.x, point.y / touch.size.y], "size_pct": 100.0, "alpha_pct": 100.0}})
	var down := InputEventScreenTouch.new()
	down.index = 8
	down.position = point
	down.pressed = true
	tree.root.push_input(down, true)
	assert_true(Input.is_action_pressed("aim"), "overlapping Aim still receives press")
	assert_eq(weapon.fire_mode, "semi", "overlapping action does not toggle mode")
	down.pressed = false
	tree.root.push_input(down, true)
	touch.apply_slot_layout(original)
	m.pause_menu.open()
	_tap(point)
	assert_eq(weapon.fire_mode, "semi", "pause blocks mode changes")
	m.pause_menu.close()
	# Real desktop click works; its emulated touch copy is ignored.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = point
	click.pressed = true
	click.device = InputEvent.DEVICE_ID_EMULATION
	tree.root.push_input(click, true)
	assert_eq(weapon.fire_mode, "semi", "emulated mouse ignored")
	click.device = InputEvent.DEVICE_ID_MOUSE
	tree.root.push_input(click, true)
	assert_eq(weapon.fire_mode, "auto", "real mouse toggles")
	click.pressed = false
	tree.root.push_input(click, true)
	# Restore semi and replace loadout, exactly as respawn does.
	_tap(point)
	m.local_player.respawn_at(m.local_player.global_transform)
	button._physics_process(0.0)
	assert_eq(m.local_player.loadout.get_active().fire_mode, "semi", "choice survives new loadout")
	m.local_player.loadout.swap()
	button._physics_process(0.0)
	assert_true(not button.visible, "hidden for blade")
	assert_eq(m.local_player.loadout.get_active().fire_mode, "", "blade unchanged")
	m.local_player.loadout.swap()
	button._physics_process(0.0)
	assert_eq(button.label.text, "SEMI", "choice survives swap")
	var remote: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	m.add_child(remote)
	remote.net_mode = Pawn.NetMode.HOST_REMOTE
	assert_eq(remote.loadout.get_active().fire_mode, "", "host remote not opted in")
	remote.net_mode = Pawn.NetMode.REPLICA
	assert_eq(remote.loadout.get_active().fire_mode, "", "replica not opted in")
	button.hide()
	_tap(point)
	assert_eq(m.local_player.loadout.get_active().fire_mode, "semi", "hidden button does not toggle")
	touch.set_suspended(true)
	button.show()
	_tap(point)
	assert_eq(m.local_player.loadout.get_active().fire_mode, "semi", "suspended touch HUD blocks toggle")
	touch.set_suspended(false)
	m.local_player.bridge.state.health = 0
	m.local_player.bridge.state.shield = 0
	_tap(point)
	assert_eq(m.local_player.loadout.get_active().fire_mode, "semi", "dead pawn does not toggle")
	m.queue_free()
	AppFlow.profile = old_profile
	tree.root.size = old_size
	await tree.process_frame
	await tree.process_frame
