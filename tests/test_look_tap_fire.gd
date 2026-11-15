extends "res://tests/test_case.gd"
## M2 H1a step 1: a look-area touch only turns the view, everywhere, in and out of cover. It never presses "fire":
## not a tap, not a still hold, not a touch that starts still and then drags. Only the Fire buttons (fire_right and the
## optional fire_left) press "fire". (Was: a look tap sent a short fire pulse and a still look hold latched fire,
## outside cover only.)
const DT := 1.0 / 60.0
const RIGHT_FIRE := "fire_right"
var hud: Control
var pawn: Pawn
var router: InputRouter
var shots := 0
var fire_seen := false
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

## Exercise HUD -> unchanged InputRouter -> Pawn -> locked Weapon at the real fixed timestep. fire_seen collects
## whether "fire" was pressed on any step.
func step(count: int = 1) -> void:
	for i in count:
		hud._process(DT)
		fire_seen = fire_seen or Input.is_action_pressed("fire")
		pawn.set_frame(router.update_frame(DT))
		pawn._clock += DT
		pawn._apply_weapon()

func look_down() -> void:
	hud._on_down(7, hud.get_look_point())  # M2 H1a: the look area centre (no look stick element in drag mode)
	assert_eq(hud._look_touch, 7, "look touch captured")
	fire_seen = fire_seen or Input.is_action_pressed("fire")

func tap() -> void:
	look_down()
	hud._on_up(7)
	fire_seen = fire_seen or Input.is_action_pressed("fire")
	step(8)

## A still look touch held for `count` steps (well past the old 0.2 s hold threshold), then lifted.
func still_hold(count: int = 60) -> void:
	look_down()
	step(count)
	hud._on_up(7)
	step(20)

## M2 C1b stage 4 (decision 5, fix 9): the HUD reads the pawn's cover state through the sibling GameHud (a stand-in
## here). The test seam sets the completed out pose (the rise in IN_COVER, the lean in PEEK_RIGHT).
class FakeGameHud extends Node:
	var pawn: Pawn

func enter_cover(state: CoverController.State) -> FakeGameHud:
	var game_hud := FakeGameHud.new()
	game_hud.name = "GameHud"
	game_hud.pawn = pawn
	hud.add_sibling(game_hud)
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	pawn.cover.state = state
	pawn.cover._draw_active = true
	pawn.cover.aim_out_amount = 1.0
	pawn.cover.aimed_out = true
	pawn.cover._facts = {"shot_clear": true, "stand_clear": true}
	assert_true(pawn.in_cover(), "fixture: the pawn is in cover")
	return game_hud

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

## M2 H1a: outside cover a look-area tap never fires (semi and auto).
func test_look_tap_never_fires_outside_cover() -> void:
	for mode in ["semi", "auto"]:
		await fixture(mode)
		var ammo := pawn.loadout.get_active().ammo_in_mag
		fire_seen = false
		for i in 3:
			tap()
			step(20)
		assert_true(not fire_seen, "a look tap never presses fire: " + mode)
		assert_eq(shots, 0, "a look tap never fires: " + mode)
		assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "a look tap spends no ammo: " + mode)
		await cleanup()

## M2 H1a: outside cover a still look-area hold never fires (semi and auto), however long it is held.
func test_look_hold_never_fires_outside_cover() -> void:
	for mode in ["semi", "auto"]:
		await fixture(mode)
		var ammo := pawn.loadout.get_active().ammo_in_mag
		fire_seen = false
		still_hold(120)
		assert_true(not fire_seen, "a still look hold never presses fire: " + mode)
		assert_eq(shots, 0, "a still look hold never fires: " + mode)
		assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "a still look hold spends no ammo: " + mode)
		await cleanup()

## M2 H1a: in cover (IN_COVER rise and PEEK_RIGHT lean) a look-area tap never fires.
func test_look_tap_never_fires_in_cover() -> void:
	for mode in ["semi", "auto"]:
		for state in [CoverController.State.IN_COVER, CoverController.State.PEEK_RIGHT]:
			await fixture(mode)
			var game_hud := enter_cover(state)
			var ammo := pawn.loadout.get_active().ammo_in_mag
			fire_seen = false
			for i in 3:
				tap()
				step(20)
			assert_true(not fire_seen, "a look tap never presses fire in cover: %s %s" % [mode, state])
			assert_eq(shots, 0, "a look tap never fires in cover: %s %s" % [mode, state])
			assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "a look tap spends no ammo in cover")
			game_hud.free()
			await cleanup()

## M2 H1a: in cover a still look-area hold never fires.
func test_look_hold_never_fires_in_cover() -> void:
	for mode in ["semi", "auto"]:
		for state in [CoverController.State.IN_COVER, CoverController.State.PEEK_RIGHT]:
			await fixture(mode)
			var game_hud := enter_cover(state)
			var ammo := pawn.loadout.get_active().ammo_in_mag
			fire_seen = false
			still_hold(120)
			assert_true(not fire_seen, "a still look hold never presses fire in cover: %s %s" % [mode, state])
			assert_eq(shots, 0, "a still look hold never fires in cover: %s %s" % [mode, state])
			assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "a still look hold spends no ammo in cover")
			game_hud.free()
			await cleanup()

## M2 H1a: a look touch that starts (still, early or after a long still pause) and then drags never fires, and the
## drag still turns the view. (Was: an early drag never fired, a late drag kept an established look-hold fire.)
func test_look_touch_that_drags_never_fires_and_turns_the_view() -> void:
	for mode in ["semi", "auto"]:
		for still_steps in [0, 20, 60]:
			await fixture(mode)
			fire_seen = false
			look_down()
			step(still_steps)
			var origin: Vector2 = hud._look_origin
			hud._on_drag(7, origin + Vector2(100, 0), Vector2(100, 0))
			assert_true(hud.provider.get_look() != Vector2.ZERO, "the drag turns the view: %s after %d still steps" % [mode, still_steps])
			assert_true(hud.is_look_active(), "the dragged look touch is an active look")
			step(40)
			hud._on_up(7)
			step(10)
			assert_true(not fire_seen, "a dragged look touch never presses fire: %s after %d still steps" % [mode, still_steps])
			assert_eq(shots, 0, "a dragged look touch never fires: %s after %d still steps" % [mode, still_steps])
			await cleanup()

## M2 H1a: the right Fire button still fires (semi: one round per press; auto: repeats while held), outside cover and
## in cover, and a look touch held at the same time neither adds nor blocks fire.
func test_right_fire_button_still_fires_in_and_out_of_cover() -> void:
	for mode in ["semi", "auto"]:
		for covered in [false, true]:
			await fixture(mode)
			var game_hud: FakeGameHud = enter_cover(CoverController.State.PEEK_RIGHT) if covered else null
			var ammo := pawn.loadout.get_active().ammo_in_mag
			var fire_c: Vector2 = hud.get_button_rect(RIGHT_FIRE).get_center()
			assert_eq(hud._button_at(fire_c), RIGHT_FIRE, "the right Fire centre hit-tests to fire_right")
			hud._on_down(8, fire_c)
			assert_true(Input.is_action_pressed("fire"), "the right Fire button presses fire: %s covered=%s" % [mode, covered])
			step(30)
			assert_true(shots >= 1, "the right Fire button fires: %s covered=%s" % [mode, covered])
			look_down()  # a second finger turning the view meanwhile
			step(30)
			assert_true(Input.is_action_pressed("fire"), "a look touch does not release a held Fire button")
			hud._on_up(8)
			step(1)
			assert_true(not Input.is_action_pressed("fire"), "releasing Fire releases fire while a look touch is still held")
			var count := shots
			step(30)
			assert_eq(shots, count, "no round after the release with the look touch still down")
			hud._on_up(7)
			step(10)
			assert_eq(shots, count, "no round when the look touch lifts")
			assert_true(pawn.loadout.get_active().ammo_in_mag < ammo, "the right Fire button spent ammo")
			if mode == "auto":
				assert_true(count > 1, "auto: a held right Fire button repeats (%d rounds)" % count)
			if game_hud != null:
				game_hud.free()
			await cleanup()

## In cover/peek the Left Fire button fires, and look-zone taps and holds before it never do.
func test_look_tap_and_hold_never_fire_in_cover_or_peek_but_left_fire_does_both_modes() -> void:
	for mode in ["semi", "auto"]:
		for state in [CoverController.State.IN_COVER, CoverController.State.PEEK_RIGHT]:
			await fixture(mode, true)
			var game_hud := enter_cover(state)
			var ammo := pawn.loadout.get_active().ammo_in_mag
			tap()
			look_down()
			step(60)
			assert_true(not Input.is_action_pressed("fire"), "a look hold does not press fire in cover: " + mode)
			hud._on_up(7)
			step(20)
			assert_eq(shots, 0, "look-zone taps and holds never fire in cover/peek: " + mode)
			assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "the look zone spends no ammo in cover")
			var left: Vector2 = hud.get_button_rect("fire_left").get_center()
			hud._on_down(8, left)
			step(60)
			hud._on_up(8)
			step(20)
			assert_true(shots >= 1, "Left Fire fires in cover/peek: " + mode)
			assert_true(pawn.loadout.get_active().ammo_in_mag < ammo, "Left Fire spends ammo in cover")
			game_hud.free()
			await cleanup()

## "fire" is the union of the two Fire buttons only; releasing one keeps it while the other is held; a look touch,
## Left Fire removal, suspend and exit behave as before.
func test_fire_union_left_right_release_refresh_and_suspend() -> void:
	await fixture("auto", true)
	var left: Vector2 = hud.get_button_rect("fire_left").get_center()
	var right: Vector2 = hud.get_button_rect(RIGHT_FIRE).get_center()
	hud._on_down(8, left)
	tap()
	assert_true(Input.is_action_pressed("fire"), "a look tap cannot release held Left Fire")
	hud._on_down(9, right)
	step(20)
	hud._on_up(8)
	assert_true(Input.is_action_pressed("fire"), "Left Fire release cannot release the held right Fire")
	hud._on_down(8, left)
	AppFlow.profile["left_fire_enabled"] = false
	hud.refresh_left_fire()
	assert_true(Input.is_action_pressed("fire"), "Left Fire removal cannot release the held right Fire")
	hud.set_suspended(true)
	assert_true(not Input.is_action_pressed("fire"), "suspend drops all sources")
	hud.set_suspended(false)
	look_down()
	step(20)
	assert_true(not Input.is_action_pressed("fire"), "after suspend a look touch alone does not re-press fire")
	hud._on_up(7)
	hud._on_down(9, right)
	step(2)
	assert_true(Input.is_action_pressed("fire"), "the right Fire re-establishes fire")
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
	look_down()
	step(30)
	hud._on_up(7)
	hud._process(DT)
	assert_true(Input.is_action_pressed("fire"), "a look touch does not release keyboard/gamepad fire")
	Input.action_release("fire")
	await cleanup()
