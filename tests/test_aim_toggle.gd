extends "res://tests/test_case.gd"
## OQ-AIM (Shibi pick 1.1, Fold eye-test 2026-10-28): ADS is a pure tap toggle. Each rising edge of the Aim button
## flips the latch and release keeps it; disabled is hold-to-aim passthrough. aim_hold_threshold_s stays in the
## data, unused. Latch lifecycle (EL default): local death clears it.

const _MatchScene := preload("res://scenes/match/match.tscn")


func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).physics_frame


func test_aim_toggle_disabled_passthrough() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": false, "aim_hold_threshold_s": 0.4})
	assert_true(t.resolve(true), "hold passes through when disabled")
	assert_true(not t.resolve(false), "release clears when disabled")


func test_aim_toggle_rising_edge_latches_and_second_edge_clears() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": true})
	assert_true(t.resolve(true), "first press aims")
	assert_true(t.toggled_aim, "rising edge latches")
	var stays := true
	for i in 30:  # 0.5 s at 60 Hz with the button up
		stays = stays and t.resolve(false)
	assert_true(stays, "stays aimed after release")
	assert_true(not t.resolve(true), "second press clears the latch")
	assert_true(not t.resolve(true), "holding the clearing press stays off")
	assert_true(not t.resolve(false), "release after the clearing press stays off")
	assert_true(t.resolve(true), "third press latches again")


func test_aim_toggle_long_hold_still_latches() -> void:
	# No hybrid: how long the press lasts does not matter, release keeps the latch.
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": true, "aim_hold_threshold_s": 0.4})
	var held := true
	for i in 60:  # 1 s, past the unused 0.4 s threshold
		held = held and t.resolve(true)
	assert_true(held, "holding aims")
	assert_true(t.resolve(false), "release after a long hold keeps the latch")


func test_clear_latch_needs_a_new_press() -> void:
	var t := AimToggle.new()
	t.configure({"aim_toggle_enabled": true})
	t.resolve(true)
	t.clear_latch()
	assert_true(not t.resolve(true), "a finger still on Aim does not re-latch after clear_latch")
	assert_true(not t.resolve(false), "release stays off")
	assert_true(t.resolve(true), "the next press latches again")


## Keyboard and gamepad reach the router through the shared InputMap action (KeyboardMouseProvider); only Aim
## presses flip the latch.
func test_router_keyboard_gamepad_aim_action_toggles() -> void:
	var r := InputRouter.new()
	r.add_provider(KeyboardMouseProvider.new())
	Input.action_press("aim")
	assert_true(r.update_frame().aim_pressed, "Aim press zooms")
	Input.action_release("aim")
	assert_true(r.update_frame().aim_pressed, "still zoomed after release")
	for action in ["fire", "reload", "swap_weapon", "jump"]:
		Input.action_press(action)
		r.update_frame()
		Input.action_release(action)
		assert_true(r.update_frame().aim_pressed, "%s keeps the latch" % action)
	Input.action_press("aim")
	assert_true(not r.update_frame().aim_pressed, "second Aim press unzooms")
	Input.action_release("aim")
	assert_true(not r.update_frame().aim_pressed, "stays off after release")
	r.free()


func test_aim_cfg_ships_tap_toggle_on_and_keeps_unused_threshold_key() -> void:
	var cfg := DataRegistry.new().get_aim_cfg()
	assert_true(cfg.has("aim_toggle_enabled"), "aim_toggle_enabled present")
	assert_true(cfg.has("aim_hold_threshold_s"), "aim_hold_threshold_s kept for data shape (unused)")
	assert_eq(bool(cfg["aim_toggle_enabled"]), true, "default on: pure tap toggle (Shibi pick 1.1)")
	assert_eq(float(cfg["aim_hold_threshold_s"]), 0.4, "unused threshold key keeps its 0.4 value")


func test_local_death_clears_aim_latch() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.match_cfg["respawn_s"] = 0.2
	assert_true(m.begin(), "match begins")
	await _frames(3)
	var pawn := m.local_player
	Input.action_press("aim")
	await _frames(2)
	Input.action_release("aim")
	await _frames(2)
	assert_true(pawn.aiming, "Aim tap latched ADS")
	pawn.bridge.state.health = 0.0  # the kill of tests/test_match_scene.gd test_dead_pawn_respawns_at_squad_spot_protected
	await _frames(3)
	assert_true(not pawn.is_alive(), "local pawn dead")
	assert_true(not m.router.aim_toggle.toggled_aim, "death cleared the latch")
	Input.action_press("aim")
	await _frames(2)
	Input.action_release("aim")
	await _frames(2)
	assert_true(not m.router.aim_toggle.toggled_aim, "an Aim tap while dead is dropped")
	await _frames(30)
	assert_true(pawn.is_alive(), "respawned")
	assert_true(not pawn.aiming and not m.router.get_frame().aim_pressed, "the respawned pawn is not aiming")
	m.queue_free()
	await tree.process_frame
