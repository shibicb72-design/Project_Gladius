extends "res://tests/test_case.gd"
const DT := 1.0 / 60.0
var hud: Control
var pawn: Pawn
var router: InputRouter
var shots := 0
var previous_profile: Dictionary

func tree() -> SceneTree:
	return Engine.get_main_loop()

func fixture(mode: String = "semi", left: bool = false, legacy_slot: bool = false) -> void:
	previous_profile = AppFlow.profile
	AppFlow.profile = {"left_fire_enabled": left}
	if legacy_slot:
		var model := HudLayoutModel.new()
		model.set_pos(0, "fire", Vector2(0.8, 0.5))
		AppFlow.profile["hud_layouts"] = model.to_dict()
	hud = load("res://scenes/ui/touch_hud.tscn").instantiate()
	tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(1512, 648)
	hud.relayout()
	hud.set_process(false)
	pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.loadout.get_active().fire_mode = mode
	shots = 0
	pawn.fired.connect(func(): shots += 1)
	router = InputRouter.new()
	router.add_provider(KeyboardMouseProvider.new())  # existing shared InputMap action provider
	router.add_provider(hud.provider)
	await tree().physics_frame

func cleanup() -> void:
	hud.free()
	pawn.free()
	router.free()
	AppFlow.profile = previous_profile
	await tree().process_frame

## Exercise HUD -> unchanged InputRouter -> Pawn -> locked Weapon at the real fixed timestep.
func step(count: int = 1) -> void:
	for i in count:
		hud._process(DT)
		pawn.set_frame(router.update_frame(DT))
		pawn._clock += DT
		pawn._apply_weapon()

func look_down() -> void:
	hud._on_down(7, hud.get_element_rect("look_stick").get_center())
	assert_eq(hud._look_touch, 7, "look touch captured")

func tap() -> void:
	look_down()
	hud._on_up(7)
	step(8)

func test_main_button_removed_legacy_slot_ignored_left_fire_still_optional() -> void:
	await fixture("semi", false, true)
	assert_true(not hud.get_button_actions().has("fire"), "no main Fire button")
	assert_true(not hud.get_element_keys().has("fire"), "no stale saved Fire element")
	assert_true(not hud.get_element_keys().has("fire_left"), "Left Fire remains off by default")
	assert_true(InputMap.has_action("fire"), "general fire action retained")
	AppFlow.profile["left_fire_enabled"] = true
	hud.refresh_left_fire()
	assert_true(hud.get_button_actions().has("fire_left"), "optional Left Fire builds")
	AppFlow.profile["left_fire_enabled"] = false
	hud.refresh_left_fire()
	assert_true(not hud.get_button_actions().has("fire_left"), "optional Left Fire removes")
	await cleanup()

func test_semi_tap_and_still_hold_each_fire_one_round() -> void:
	await fixture()
	var weapon := pawn.loadout.get_active()
	var ammo := weapon.ammo_in_mag
	tap()
	assert_eq(shots, 1, "semi look tap one round")
	assert_eq(weapon.ammo_in_mag, ammo - 1, "tap ammo -1")
	step(20)
	look_down()
	step(60)
	assert_eq(shots, 2, "semi still one-second hold fires one round")
	hud._on_up(7)
	step(20)
	assert_eq(shots, 2, "hold adds no release pulse")
	await cleanup()

func test_auto_still_hold_repeats_at_weapon_interval_and_tap_is_one_round() -> void:
	await fixture("auto")
	var weapon := pawn.loadout.get_active()
	var hold_min := float(hud._layout["look_hold_fire"]["hold_min_s"])
	look_down()
	step(60)
	var expected := (1.0 - hold_min) / (weapon.def.fire_interval_s / maxi(weapon.def.burst_count, 1))
	assert_true(absf(shots - expected) <= 1.0, "auto hold rounds within one of data interval")
	hud._on_up(7)
	var count := shots
	step(30)
	assert_eq(shots, count, "none after auto hold release")
	tap()
	assert_eq(shots, count + 1, "auto tap one round")
	await cleanup()

func test_early_drag_never_fires_both_modes_late_drag_retains_hold() -> void:
	for mode in ["semi", "auto"]:
		await fixture(mode)
		look_down()
		var origin: Vector2 = hud._look_origin
		hud._on_drag(7, origin + Vector2(100, 0), Vector2(100, 0))
		step(60)
		hud._on_up(7)
		step(10)
		assert_eq(shots, 0, "early drag never fires " + mode)
		look_down()
		step(20)
		origin = hud._look_origin
		hud._on_drag(7, origin + Vector2(100, 0), Vector2(100, 0))
		assert_true(hud._look_hold_fire and hud.provider.get_look() != Vector2.ZERO, "late drag retains fire and turns camera")
		step(40)
		assert_true(shots > 0, "late drag keeps established hold " + mode)
		hud._on_up(7)
		step(10)
		await cleanup()

func test_look_tap_and_hold_never_fire_in_cover_or_peek_both_modes() -> void:
	for mode in ["semi", "auto"]:
		for state in [CoverController.State.IN_COVER, CoverController.State.PEEK_RIGHT]:
			await fixture(mode, true)
			pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
			pawn.cover.state = state
			pawn.cover._peek_complete = true
			pawn.cover._facts = {"shot_clear": true, "stand_clear": true}
			var ammo := pawn.loadout.get_active().ammo_in_mag
			tap()
			look_down()
			step(60)
			hud._on_up(7)
			var left: Vector2 = hud.get_button_rect("fire_left").get_center()
			hud._on_down(8, left)
			step(60)
			hud._on_up(8)
			step(20)
			assert_eq(shots, 0, "only contextual FIRE fires in cover/peek: " + mode)
			assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "cover general fire spends no ammo")
			await cleanup()

func test_fire_union_pulse_hold_left_release_refresh_and_suspend() -> void:
	await fixture("auto", true)
	var left: Vector2 = hud.get_button_rect("fire_left").get_center()
	hud._on_down(8, left)
	tap()
	assert_true(Input.is_action_pressed("fire"), "tap expiry cannot release held Left Fire")
	look_down()
	step(20)
	hud._on_up(8)
	assert_true(Input.is_action_pressed("fire"), "Left Fire release cannot release look hold")
	AppFlow.profile["left_fire_enabled"] = false
	hud.refresh_left_fire()
	assert_true(Input.is_action_pressed("fire"), "Left Fire removal cannot release look hold")
	hud.set_suspended(true)
	assert_true(not Input.is_action_pressed("fire") and not hud._look_hold_fire, "suspend drops all sources")
	hud.set_suspended(false)
	look_down()
	step(20)
	assert_true(Input.is_action_pressed("fire"), "hold re-established")
	hud.free()
	assert_true(not Input.is_action_pressed("fire"), "exit drops all sources")
	pawn.free()
	router.free()
	AppFlow.profile = previous_profile
	await tree().process_frame

func test_touch_idle_does_not_release_keyboard_fire() -> void:
	await fixture()
	Input.action_press("fire")
	hud._process(DT)
	assert_true(Input.is_action_pressed("fire"), "idle TouchHud does not own keyboard/gamepad fire")
	Input.action_release("fire")
	await cleanup()
