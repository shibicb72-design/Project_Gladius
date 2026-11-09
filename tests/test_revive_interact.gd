extends "res://tests/test_case.gd"
## S1b items 4-5: DOWNED state and the Interact (Revive) touch button in the real match scene (squads mode).
## Taps are real InputEventScreenTouch events pushed through the viewport at the button's on-screen centre;
## the press goes TouchProvider -> InputRouter -> MatchRoot -> MatchDirector (the revive pair owner).

const _MatchScene := preload("res://scenes/match/match.tscn")
const REVIVE_S := 0.5  # test-only fast revive (data value: br.json downed.revive_s)

var m: MatchRoot
var local: Pawn
var mate: Pawn
var enemy: Pawn
var button: InteractButton
var routed: Array = []
var old_size: Vector2i
var old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame
		await tree().process_frame


func setup() -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	tree().root.add_child(m)
	await tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = "squads"
	m.director.mode_cfg["downed"]["revive_s"] = REVIVE_S
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)  # bots present but idle
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	local = m.local_player
	mate = null
	enemy = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == local:
			continue
		if p.squad_id == local.squad_id and mate == null:
			mate = p
		elif p.squad_id != local.squad_id and enemy == null:
			enemy = p
	routed = []
	m.router.action_triggered.connect(func(a: String) -> void: routed.append(["press", a]))
	m.router.action_released.connect(func(a: String, c: bool) -> void: routed.append(["release", a, c]))
	await frames(3)  # rules start on the first tick
	button = m.hud.interact_button


func cleanup() -> void:
	m.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile
	tree().paused = false


func touch_at(point: Vector2, down: bool, index: int = 7) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)


## Downs the mate with an enemy hit and puts it next to the local pawn.
func down_mate() -> void:
	mate.global_position = local.global_position + local.global_transform.basis.x * 1.0
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	mate.receive_hit(def, false, enemy.squad_id, enemy.player_id)
	await frames(2)


func test_fixture() -> void:
	await setup()
	assert_true(mate != null and enemy != null, "squad mate and enemy found")
	assert_true(button != null and button.is_inside_tree(), "Interact button in the HUD")
	await cleanup()


func test_interact_hidden_without_downed_mate_in_range() -> void:
	await setup()
	await frames(2)
	assert_true(not button.visible, "hidden: no downed squad mate")
	await down_mate()
	assert_true(mate.is_downed(), "mate downed")
	await frames(1)
	assert_true(button.visible, "visible next to a downed squad mate")
	assert_eq(button.label.text, "Revive", "labelled Revive")
	mate.global_position = local.global_position + Vector3(20.0, 0.0, 0.0)
	await frames(2)
	assert_true(not button.visible, "hidden when the downed mate is out of range")
	await cleanup()


func test_downed_pawn_cannot_fire_and_is_finished_by_a_further_hit() -> void:
	await setup()
	await down_mate()
	assert_true(mate.is_downed() and not mate.is_alive(), "downed, not alive")
	assert_true(mate.bridge.downed, "bridge downed flag set")
	var w: Weapon = mate.loadout.get_active()
	var ammo := w.ammo_in_mag
	var f := InputFrame.new()
	f.fire_pressed = true
	f.fire_just_pressed = true
	mate.set_frame(f)
	await frames(5)
	assert_eq(w.ammo_in_mag, ammo, "a DOWNED pawn cannot fire")
	assert_true(not mate.aiming, "a DOWNED pawn cannot aim")
	mate.set_frame(InputFrame.new())
	var shield_before: float = mate.bridge.state.shield
	await frames(30)
	assert_true(absf(mate.bridge.state.shield - shield_before) < 1e-4, "no shield regen while DOWNED")
	var gone: Array = []
	m.director.player_eliminated.connect(func(id: int, k: int, c: String) -> void: gone.append([id, k, c]))
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	var res := mate.receive_hit(def, false, enemy.squad_id, enemy.player_id)
	assert_true(res.hit_downed, "the hit lands on the DOWNED pawn")
	await frames(2)
	assert_eq(mate.life, Pawn.Life.DEAD, "finished")
	assert_eq(gone.size(), 1, "one elimination")
	if gone.size() == 1:
		assert_eq(gone[0][0], mate.player_id, "the mate was eliminated")
	await cleanup()


func test_friendly_hit_does_not_finish_a_downed_mate() -> void:
	await setup()
	await down_mate()
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	var res := mate.receive_hit(def, false, local.squad_id, local.player_id)
	assert_eq(res.blocked_reason, "friendly", "squad mate hit blocked")
	await frames(2)
	assert_true(mate.is_downed(), "still downed")
	await cleanup()


func test_downed_pawn_moves_at_downed_speed() -> void:
	await setup()
	await down_mate()
	var pct := float(m.director.mode_cfg["downed"]["downed_move_speed_pct"])
	assert_true(absf(mate.downed_move_speed_pct - pct) < 1e-4, "downed speed pct from br.json")
	assert_true(absf(mate._life_speed_mult() - pct / 100.0) < 1e-4, "speed multiplier while DOWNED")
	await cleanup()


func test_hold_tapped_interact_revives_mate() -> void:
	await setup()
	await down_mate()
	await frames(1)
	assert_true(button.visible, "Interact visible")
	var c := button.get_touch_rect().get_center()
	touch_at(c, true)
	await frames(2)
	assert_true(["press", "interact"] in routed, "press routed through the InputRouter")
	assert_true(m.director.is_reviving(local.player_id), "director holds the revive pair")
	var n := 0
	while mate.is_downed() and n < 120:
		await frames(1)
		n += 1
	assert_eq(mate.life, Pawn.Life.ALIVE, "revived while held")
	var pct := float(m.director.mode_cfg["downed"]["revive_health_pct"])
	assert_true(absf(mate.bridge.state.health - mate.bridge.state.max_health * pct / 100.0) < 1e-4, "health = revive_health_pct")
	assert_true(absf(mate.bridge.state.shield) < 1e-4, "shield 0 after revive")
	assert_true(not mate.bridge.downed, "bridge downed flag cleared")
	await frames(1)
	assert_true(not button.visible, "hidden once the mate is revived")
	assert_true(not m.director.is_reviving(local.player_id), "pair ended by the revive")
	touch_at(c, false)
	await frames(1)
	await cleanup()


func test_release_early_resets_progress() -> void:
	await setup()
	await down_mate()
	await frames(1)
	var c := button.get_touch_rect().get_center()
	touch_at(c, true)
	await frames(int(REVIVE_S * 60.0 * 0.6))
	touch_at(c, false)
	await frames(2)
	assert_true(["release", "interact", false] in routed, "release routed through the InputRouter")
	assert_true(not m.director.is_reviving(local.player_id), "release reaches MatchDirector")
	await frames(int(REVIVE_S * 60.0))
	assert_true(mate.is_downed(), "still downed after an early release")
	touch_at(c, true)
	await frames(int(REVIVE_S * 60.0 * 0.6))
	assert_true(mate.is_downed(), "second partial hold starts from zero")
	touch_at(c, false)
	await frames(1)
	await cleanup()


func test_menu_ends_revive_and_blocks_press() -> void:
	await setup()
	await down_mate()
	await frames(1)
	var c := button.get_touch_rect().get_center()
	touch_at(c, true)
	await frames(2)
	assert_true(m.director.is_reviving(local.player_id), "holding")
	m.pause_menu.open()
	await tree().process_frame
	await tree().process_frame
	assert_true(not m.director.is_reviving(local.player_id), "opening the menu ends the revive")
	touch_at(c, false)
	touch_at(c, true, 8)
	await tree().process_frame
	assert_true(not m.director.is_reviving(local.player_id), "a press while the menu is open does nothing")
	touch_at(c, false, 8)
	m.pause_menu.close()
	await frames(2)
	await cleanup()


func test_hiding_touch_hud_ends_revive() -> void:
	await setup()
	await down_mate()
	await frames(1)
	var c := button.get_touch_rect().get_center()
	touch_at(c, true)
	await frames(2)
	assert_true(m.director.is_reviving(local.player_id), "holding")
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.visible = false
	await frames(1)
	assert_true(not m.director.is_reviving(local.player_id), "hiding the touch HUD ends the revive")
	touch_at(c, false)
	touch.visible = true
	await frames(1)
	await cleanup()
