extends "res://tests/test_case.gd"
## M2 H1a step 2: the two touch shooting modes (data/input.json shooting, OQ-SHOOT-MODE; docs/CONTROLS.md Shooting mode).
## Advanced (default): the right Fire button fires at once; Aim is a separate toggle; optional hold-to-ADS (off by
## default). Simple: no right Fire button; with the sight up and the crosshair on a live enemy in range and clear sight
## (Pawn.simple_fire_target) the touch HUD presses "fire" after shooting.simple.first_shot_delay_s. Every touch shot goes
## through the "fire" action, the InputRouter frame and the pawn's normal weapon path.
## Rigs: (1) the touch HUD + an unchanged InputRouter + a pawn stepped by hand (tests/test_look_tap_fire.gd), with a
## stand-in GameHud sibling; (2) the same with the pawn in real cover (tests/test_cover_fire_c1b.gd fixture); (3) a real
## match with viewport touches (LAN rule and the live Settings switch).

const DT := 1.0 / 60.0
const ORIGIN := Vector3(3200, 0, 0)
const RIGHT_FIRE := "fire_right"
const TMP := "user://test_shooting_mode_profile.json"
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const SIMPLE := {"shooting_mode": "simple"}

var root: Node3D
var hud: Control
var pawn: Pawn
var router: InputRouter
var game_hud: FakeGameHud
var rig: CameraRig
var shots := 0
var shot_clocks: Array = []
var fire_seen := false
var previous_profile: Dictionary


class FakeGameHud extends Node:
	var pawn: Pawn
	var spectate_text: String = ""


func tree() -> SceneTree:
	return Engine.get_main_loop()


# ---- rig ----------------------------------------------------------------------------------------------------------

func fixture(profile: Dictionary = {}, mode: String = "auto", hold_ads: bool = false) -> void:
	previous_profile = AppFlow.profile
	AppFlow.profile = profile
	_rm()
	root = Node3D.new()
	tree().root.add_child(root)
	hud = load("res://scenes/ui/touch_hud.tscn").instantiate()
	tree().root.add_child(hud)
	hud.cfg["force_touch_hud"] = true
	hud.cfg["shooting"]["hold_to_ads"]["enabled"] = hold_ads  # this HUD's own parsed copy of data/input.json
	hud.refresh_visibility()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.size = Vector2(1512, 648)
	hud.relayout()
	hud.set_process(false)
	pawn = _PawnScene.instantiate()
	pawn.position = ORIGIN
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.hit_authority = Callable()  # rounds deal no damage, so the targets stay alive for the whole test
	pawn.loadout.get_active().fire_mode = mode
	shots = 0
	shot_clocks = []
	fire_seen = false
	pawn.fired.connect(func() -> void:
			shots += 1
			shot_clocks.append(pawn.get_clock()))
	game_hud = FakeGameHud.new()
	game_hud.name = "GameHud"
	game_hud.pawn = pawn
	hud.add_sibling(game_hud)
	router = InputRouter.new()
	router.add_provider(KeyboardMouseProvider.new())
	router.add_provider(hud.provider)
	await tree().physics_frame


func cleanup() -> void:
	hud.free()
	game_hud.free()
	router.free()
	root.free()
	rig = null
	AppFlow.profile = previous_profile
	for action in ["fire", "aim", "swap_shoulder", "cover"]:
		Input.action_release(action)
	_rm()
	await tree().process_frame


func _rm() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## HUD -> unchanged InputRouter -> Pawn (aim, then the locked weapon) at the fixed timestep. `hold_view` puts pitch and
## yaw back each step (the player pulling the recoil down), so the crosshair stays where the test put it.
func step(count: int = 1, hold_view: bool = true) -> void:
	for i in count:
		if hold_view:
			pawn.pitch = 0.0
			pawn.rotation.y = 0.0
		hud._process(DT)
		fire_seen = fire_seen or Input.is_action_pressed("fire")
		pawn.set_frame(router.update_frame(DT))
		pawn._clock += DT
		pawn._apply_aim(DT)
		pawn._apply_weapon()


func tap_aim() -> void:
	hud._on_down(9, hud.get_button_rect("aim").get_center())
	step(1)
	hud._on_up(9)
	step(1)


func enemy_at(offset: Vector3, squad: int = 1) -> Pawn:
	var p: Pawn = _PawnScene.instantiate()
	p.position = ORIGIN + offset
	root.add_child(p)
	p.set_physics_process(false)
	p.set_squad(squad)
	return p


func box(at: Vector3, size: Vector3, tagged: bool = false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"  # CoverProbe reads the wall's box through this child (tests/test_cover_fire_c1b.gd)
	var b := BoxShape3D.new()
	b.size = size
	shape.shape = b
	body.add_child(shape)
	if tagged:
		body.add_to_group(&"cover_wall")
	root.add_child(body)
	return body


func settle() -> void:
	await tree().physics_frame
	await tree().physics_frame


func interval() -> float:
	var d := pawn.loadout.get_active().def
	return d.fire_interval_s / maxi(d.burst_count, 1)


func delay() -> float:
	return float(hud.cfg["shooting"]["simple"]["first_shot_delay_s"])


func hold_s() -> float:
	return float(hud.cfg["shooting"]["hold_to_ads"]["hold_s"])


# ---- data -----------------------------------------------------------------------------------------------------------

func test_data_block_and_placeholders() -> void:
	var data := DataRegistry.new().load_file("res://data/input.json")
	var s: Dictionary = data["shooting"]
	assert_eq(s["modes"], ["advanced", "simple"], "two modes")
	assert_eq(s["default_mode"], "advanced", "default mode placeholder")
	assert_eq(s["hold_to_ads"]["enabled"], false, "hold-to-ADS off by default")
	assert_eq(float(s["hold_to_ads"]["hold_s"]), 0.25, "hold time placeholder")
	assert_eq(float(s["simple"]["first_shot_delay_s"]), 0.15, "Simple delay placeholder")
	assert_true(str(data["_shooting_todo"]).contains("OQ-SHOOT-MODE"), "the block names OQ-SHOOT-MODE")
	assert_true(FileAccess.get_file_as_string("res://docs/OPEN_QUESTIONS.md").contains("OQ-SHOOT-MODE"), "OPEN_QUESTIONS has the entry")


# ---- Advanced ---------------------------------------------------------------------------------------------------------

func test_advanced_fire_button_fires_at_once() -> void:
	await fixture()
	assert_eq(hud.shooting_mode(), "advanced", "no profile key: the data default")
	assert_true(hud.get_button_actions().has(RIGHT_FIRE), "the right Fire button is built")
	var w := pawn.loadout.get_active()
	var ammo := w.ammo_in_mag
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	step(1)
	assert_eq(shots, 1, "the first round on the press step (hip fire, no delay)")
	assert_true(not pawn.aiming, "hip fire: the sight stays down")
	step(30)
	hud._on_up(3)
	step(2)
	assert_true(shots > 1 and w.ammo_in_mag == ammo - shots, "auto repeats and spends ammo (%d shots)" % shots)
	assert_true(not Input.is_action_pressed("fire"), "release stops")
	await cleanup()


func test_advanced_aim_alone_and_look_touches_never_fire_on_an_enemy() -> void:
	await fixture()
	var enemy := enemy_at(Vector3(0, 0, -10))
	await settle()
	tap_aim()
	assert_true(pawn.aiming, "fixture: sight up")
	assert_true(pawn.simple_fire_target() == enemy, "fixture: the enemy is under the crosshair")
	step(90)
	assert_true(not fire_seen and shots == 0, "Advanced: Aim alone never fires, even on an enemy")
	var look: Vector2 = hud.get_look_point()  # M2 H1a: no look stick element in drag mode
	hud._on_down(7, look)
	hud._on_up(7)
	step(20)
	hud._on_down(7, look)
	step(60)
	hud._on_up(7)
	step(20)
	assert_true(not fire_seen and shots == 0, "a look tap and a look hold never fire")
	await cleanup()


# ---- hold-to-ADS ----------------------------------------------------------------------------------------------------------

func test_hold_to_ads_off_by_default() -> void:
	await fixture()
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	var ever := false
	for i in 90:
		step(1)
		ever = ever or pawn.aiming or hud.provider.hold_ads
	hud._on_up(3)
	step(2)
	assert_true(not ever, "a 1.5 s Fire hold never raises the sight with the switch off")
	assert_true(shots > 1, "it fires")
	await cleanup()


func test_hold_to_ads_raises_after_hold_s_and_release_lowers() -> void:
	await fixture({}, "auto", true)
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	var up_step := -1
	for i in 60:
		step(1)
		if pawn.aiming:
			up_step = i + 1
			break
	var want := ceili(hold_s() / DT - 0.0001)
	assert_true(up_step >= want and up_step <= want + 2, "sight up after hold_s (%d steps, hold_s = %d)" % [up_step, want])
	assert_true(shots >= 1, "it fired from the first step (hip fire first)")
	assert_true(not router.get_frame().aim_just_pressed, "aim_just_pressed stays the raw Aim edge")
	assert_true(not router.aim_toggle.toggled_aim, "the Aim toggle latch is not touched")
	step(20)
	assert_true(pawn.aiming, "still up while held")
	hud._on_up(3)
	step(1)
	assert_true(not pawn.aiming and not hud.provider.hold_ads, "release lowers the sight on the next step")
	step(30)
	assert_true(not pawn.aiming, "and it stays down")
	# Left Fire holds the same way.
	AppFlow.profile = {"left_fire_enabled": true}
	hud.refresh_left_fire()
	hud._on_down(4, hud.get_button_rect("fire_left").get_center())
	step(want + 2)
	assert_true(pawn.aiming, "a Left Fire hold raises the sight too")
	hud._on_up(4)
	step(1)
	assert_true(not pawn.aiming, "and its release lowers it")
	await cleanup()


func test_hold_to_ads_release_keeps_the_sight_when_aim_was_toggled_on() -> void:
	await fixture({}, "auto", true)
	tap_aim()
	assert_true(pawn.aiming and router.aim_toggle.toggled_aim, "fixture: Aim toggled on")
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	step(ceili(hold_s() / DT) + 10)
	assert_true(hud.provider.hold_ads and pawn.aiming, "held past hold_s")
	hud._on_up(3)
	step(30)
	assert_true(pawn.aiming and router.aim_toggle.toggled_aim, "release keeps the sight up: Aim was on")
	tap_aim()
	step(2)
	assert_true(not pawn.aiming and not router.aim_toggle.toggled_aim, "one Aim tap lowers it: no double toggle")
	await cleanup()


func test_hold_to_ads_is_advanced_only() -> void:
	await fixture({"shooting_mode": "simple", "left_fire_enabled": true}, "auto", true)
	hud._on_down(4, hud.get_button_rect("fire_left").get_center())
	step(ceili(hold_s() / DT) + 10)
	assert_true(not pawn.aiming and not hud.provider.hold_ads, "Simple: a Left Fire hold does not raise the sight")
	assert_true(shots >= 1, "Left Fire still fires in Simple")
	hud._on_up(4)
	await cleanup()


# ---- cover (pawn in real cover, tests/test_cover_fire_c1b.gd fixture) ------------------------------------------------------

## A 4 m x 2.2 m wall with its face on z = 0 around ORIGIN, the local pawn 0.35 m inside its right end facing it, entered
## by Pawn.handle_action_press("cover") (the Cover button's action); the automatic turn is left to finish.
func cover_fixture(profile: Dictionary, hold_ads: bool = false) -> void:
	await fixture(profile, "auto", hold_ads)
	pawn.free()
	box(ORIGIN + Vector3(0, -0.1, 0), Vector3(30, 0.2, 30))
	box(ORIGIN + Vector3(0, 1.1, -0.5), Vector3(4, 2.2, 1), true)
	pawn = _PawnScene.instantiate()
	pawn.position = ORIGIN + Vector3(1.65, 0, 0.6)
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.hit_authority = Callable()
	pawn.loadout.get_active().fire_mode = "auto"
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	rig = _RigScene.instantiate()
	rig.name = "CameraRig"
	pawn.add_child(rig)
	game_hud.pawn = pawn
	pawn.fired.connect(func() -> void: shots += 1)
	await tree().physics_frame
	await tree().physics_frame
	assert_true(pawn.cover_button_valid(), "fixture: a Cover press would enter")
	pawn.handle_action_press("cover")
	for i in 150:
		await ctick()
		if pawn.cover.state == CoverController.State.IN_COVER and rig.get_first_person_weight() == 0.0 and not pawn.is_cover_turning():
			break
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "fixture: in cover")
	shots = 0
	fire_seen = false


## One real pawn tick fed by the HUD and the router (movement, cover, aim, weapon).
func ctick() -> void:
	hud._process(DT)
	fire_seen = fire_seen or Input.is_action_pressed("fire")
	pawn.set_frame(router.update_frame(DT))
	pawn._physics_process(DT)
	await tree().physics_frame


func cticks(seconds: float) -> int:
	return ceili(seconds / DT - 0.0001)


func test_cover_fire_hold_with_hold_to_ads_returns_on_release() -> void:
	await cover_fixture({}, true)
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	for i in cticks(hold_s()) + 20:
		await ctick()
	assert_true(pawn.aiming and hud.provider.hold_ads, "the Fire hold raised the sight in cover")
	assert_true(pawn.cover.aimed_out and pawn.cover.state == CoverController.State.PEEK_RIGHT, "leaned out")
	assert_true(shots >= 1, "and fired from the lean (%d)" % shots)
	hud._on_up(3)
	await ctick()
	assert_true(not pawn.aiming, "release lowers the sight")
	var back := -1
	var cfg := pawn.cover.config
	var limit := cticks(float(cfg["fire_return_delay_s"]) + float(cfg["aim_return_s"])) + 10
	for i in limit:
		await ctick()
		if pawn.cover.state == CoverController.State.IN_COVER and not pawn.cover.aimed_out:
			back = i + 1
			break
	assert_true(back > 0, "back in cover after the release (%d ticks, limit %d)" % [back, limit])
	var after := shots
	for i in 20:
		await ctick()
	assert_eq(shots, after, "no round after the return")
	await cleanup()


func test_simple_from_cover_aim_holds_out_then_fires_on_target() -> void:
	await cover_fixture(SIMPLE)
	assert_true(not hud.get_button_actions().has(RIGHT_FIRE), "Simple: no right Fire button")
	hud._on_down(9, hud.get_button_rect("aim").get_center())
	await ctick()
	hud._on_up(9)
	for i in 60:
		await ctick()
		if pawn.cover.aimed_out:
			break
	assert_true(pawn.aiming and pawn.cover.aimed_out, "C1b: Aim alone holds out")
	for i in 20:
		await ctick()
	assert_true(shots == 0 and not fire_seen, "out with no enemy in sight: no fire")
	var point := pawn.get_muzzle_position() + pawn.get_aim_direction() * 12.0
	var muzzle_h := pawn.get_muzzle_position().y - pawn.global_position.y
	var enemy := enemy_at(point - ORIGIN - Vector3(0, muzzle_h, 0))
	await settle()
	var first := -1
	for i in 60:
		await ctick()
		if shots > 0:
			first = i + 1
			break
	assert_true(first > 0, "Simple fired from the held lean on the enemy")
	assert_true(first >= cticks(delay()), "not before the delay (%d ticks)" % first)
	assert_true(pawn.cover.aimed_out, "the shot left the out pose")
	assert_true(pawn.simple_fire_target() == enemy, "the target is the enemy")
	# Aim off: back into cover, no more fire.
	hud._on_down(9, hud.get_button_rect("aim").get_center())
	await ctick()
	hud._on_up(9)
	for i in 40:
		await ctick()
	assert_eq(pawn.cover.state, CoverController.State.IN_COVER, "Aim off returns")
	var after := shots
	for i in 20:
		await ctick()
	assert_eq(shots, after, "back in cover: no fire")
	await cleanup()


# ---- Simple -----------------------------------------------------------------------------------------------------------------

func test_simple_has_no_right_fire_button_and_its_rect_is_look_area() -> void:
	await fixture(SIMPLE)
	assert_eq(hud.shooting_mode(), "simple", "profile Simple")
	assert_true(not hud.get_button_actions().has(RIGHT_FIRE), "no right Fire button")
	assert_true(not hud.get_element_keys().has(RIGHT_FIRE), "not an editable element")
	var old: Vector2 = hud.get_button_rect(RIGHT_FIRE).get_center()  # the data rect it would have
	assert_eq(hud._button_at(old), "", "its old rect hit-tests to no button")
	hud._on_down(5, old)
	assert_eq(hud._look_touch, 5, "a touch there is a look touch")
	hud._on_drag(5, old + Vector2(30, 0), Vector2(30, 0))
	assert_true(hud.provider.get_look() != Vector2.ZERO, "and it turns the view")
	hud._on_up(5)
	step(10)
	assert_true(not fire_seen and shots == 0, "and never fires")
	await cleanup()


func test_simple_fires_after_the_delay_on_target_and_never_with_the_sight_down() -> void:
	await fixture(SIMPLE)
	var enemy := enemy_at(Vector3(4, 0, -10))  # off the line for now
	await settle()
	var w := pawn.loadout.get_active()
	var ammo := w.ammo_in_mag
	enemy.position.x = ORIGIN.x
	await settle()
	step(60)
	assert_true(not fire_seen and shots == 0, "sight down, enemy under the crosshair: never")
	assert_eq(hud.simple_fire_block_reason(), "sight_down", "blocked by the sight")
	enemy.position.x = ORIGIN.x + 4.0
	await settle()
	tap_aim()
	step(20)
	assert_true(pawn.aiming and not fire_seen and shots == 0, "sight up, nothing under the crosshair: never")
	enemy.position.x = ORIGIN.x  # the crosshair comes onto the enemy
	await settle()
	var first := -1
	for i in 60:
		step(1)
		if fire_seen or shots > 0:
			first = i
			break
	assert_true(first >= 0 and shots == 1, "it fires")
	assert_true(first * DT >= delay() - 0.0001 and first * DT <= delay() + 2.0 * DT,
			"after first_shot_delay_s %.3f s (%.3f s)" % [delay(), first * DT])
	assert_eq(w.ammo_in_mag, ammo - 1, "the normal fire path spent the round")
	await cleanup()


func test_simple_auto_repeats_and_leaving_the_target_stops_within_a_frame() -> void:
	await fixture(SIMPLE, "auto")
	var enemy := enemy_at(Vector3(0, 0, -10))
	await settle()
	tap_aim()
	step(ceili(delay() / DT) + 60)
	assert_true(shots >= 5, "auto repeats while on target (%d in 1 s)" % shots)
	for i in range(1, shot_clocks.size()):
		assert_true(shot_clocks[i] - shot_clocks[i - 1] >= interval() - 0.001, "auto keeps the weapon's interval")
	enemy.position.x = ORIGIN.x + 4.0
	await settle()
	var before := shots
	step(1)
	assert_true(not Input.is_action_pressed("fire"), "off target: fire released on the next step")
	step(30)
	assert_true(shots <= before + 1, "no more rounds after leaving the target (%d -> %d)" % [before, shots])
	await cleanup()


func test_simple_semi_keeps_shooting_at_the_weapon_interval() -> void:
	await fixture(SIMPLE, "semi")
	enemy_at(Vector3(0, 0, -10))
	await settle()
	tap_aim()
	step(ceili(delay() / DT) + 90)
	var gaps: Array = []
	for i in range(1, shot_clocks.size()):
		gaps.append(shot_clocks[i] - shot_clocks[i - 1])
	assert_true(shots >= 6, "semi keeps shooting while on target (%d in 1.5 s, interval %.3f s)" % [shots, interval()])
	for g in gaps:
		assert_true(g >= interval() - 0.001 and g <= interval() + DT + 0.001, "one round per interval: gap %.4f s" % g)
	await cleanup()


func _assert_never(label: String) -> void:
	fire_seen = false
	var before := shots
	step(60)
	assert_true(not fire_seen and shots == before, label)


func test_simple_never_on_mates_downed_walls_or_beyond_range() -> void:
	await fixture(SIMPLE)
	tap_aim()
	var mate := enemy_at(Vector3(0, 0, -10), 0)
	await settle()
	_assert_never("a squad mate: never")
	mate.life = Pawn.Life.DOWNED
	_assert_never("a downed squad mate: never")
	mate.free()
	var enemy := enemy_at(Vector3(0, 0, -10), 1)
	enemy.life = Pawn.Life.DOWNED
	await settle()
	_assert_never("a downed enemy: never")
	enemy.life = Pawn.Life.ALIVE
	var wall := box(ORIGIN + Vector3(0, 1.5, -5), Vector3(4, 3, 0.3))
	await settle()
	_assert_never("an enemy behind a wall: never")
	wall.free()
	enemy.position.z = ORIGIN.z - (pawn.loadout.get_active().def.range_m + 5.0)
	await settle()
	_assert_never("an enemy beyond range: never")
	enemy.position.z = ORIGIN.z - 10.0
	await settle()
	step(ceili(delay() / DT) + 5)
	assert_true(shots >= 1, "control: the same enemy in range and clear is shot")
	await cleanup()


func test_simple_off_while_spectating_falling_downed_suspended_or_hidden() -> void:
	await fixture(SIMPLE)
	enemy_at(Vector3(0, 0, -10))
	await settle()
	tap_aim()
	game_hud.spectate_text = "Spectating Squad II"
	_assert_never("spectating (GameHud.spectate_text): never")
	assert_eq(hud.simple_fire_block_reason(), "spectating", "reason spectating")
	game_hud.spectate_text = ""
	for drop in [Pawn.Drop.ABOARD, Pawn.Drop.FALLING]:
		pawn.drop_state = drop
		_assert_never("on the carrier / falling: never")
		assert_eq(hud.simple_fire_block_reason(), "drop", "reason drop")
	pawn.drop_state = Pawn.Drop.NONE
	hud.set_suspended(true)
	_assert_never("suspended (menu open): never")
	assert_eq(hud.simple_fire_block_reason(), "suspended", "reason suspended")
	hud.set_suspended(false)
	hud.cfg["force_touch_hud"] = false
	hud.refresh_visibility()
	assert_true(not hud.visible, "fixture: the HUD is hidden (no touch screen headless)")
	_assert_never("HUD hidden: never")
	assert_eq(hud.simple_fire_block_reason(), "hidden", "reason hidden")
	hud.cfg["force_touch_hud"] = true
	hud.refresh_visibility()
	step(ceili(delay() / DT) + 5)
	assert_true(shots >= 1, "control: back to normal it fires")
	var after := shots
	pawn.life = Pawn.Life.DOWNED
	_assert_never("downed: never")
	assert_eq(hud.simple_fire_block_reason(), "downed", "reason downed")
	pawn.life = Pawn.Life.DEAD
	_assert_never("dead / spectating: never")
	assert_eq(hud.simple_fire_block_reason(), "spectating", "reason spectating for a dead pawn")
	assert_eq(shots, after, "no round in any of these")
	await cleanup()


func test_simple_keyboard_and_gamepad_fire_still_fire() -> void:
	await fixture(SIMPLE)
	step(5)
	assert_eq(shots, 0, "fixture: nothing fires")
	Input.action_press("fire")  # what a key, mouse button or gamepad binding of the fire action does
	step(20)
	Input.action_release("fire")
	step(2)
	assert_true(shots >= 1, "the fire action from the other devices still fires in Simple (%d)" % shots)
	await cleanup()


# ---- profile and Settings -------------------------------------------------------------------------------------------------------

func test_profile_saves_loads_and_sanitizes() -> void:
	previous_profile = AppFlow.profile
	_rm()
	var svc := SaveService.new(TMP)
	assert_eq(SaveService.defaults()["shooting_mode"], "advanced", "default from data")
	assert_eq(svc.load_profile()["shooting_mode"], "advanced", "no file: the default")
	var p := svc.load_profile()
	p["shooting_mode"] = "simple"
	p["not_a_profile_key"] = 1
	assert_true(svc.save_profile(p), "saved")
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TMP))
	assert_eq(raw.get("shooting_mode", null), "simple", "the whitelist writes shooting_mode")
	assert_true(not raw.has("not_a_profile_key"), "and still drops unknown keys")
	assert_eq(svc.load_profile()["shooting_mode"], "simple", "survives a reload")
	for bad in ["turbo", "SIMPLE", 3, null, true, ["simple"]]:
		p["shooting_mode"] = bad
		svc.save_profile(p)
		assert_eq(svc.load_profile()["shooting_mode"], "advanced", "bad value %s -> the default" % str(bad))
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"gamertag": "x", "shooting_mode": "nope"}))
	f.close()
	assert_eq(svc.load_profile()["shooting_mode"], "advanced", "a bad value in the file loads as the default")
	AppFlow.profile = {"shooting_mode": 7}
	var h: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	tree().root.add_child(h)
	assert_eq(h.shooting_mode(), "advanced", "the HUD reads a bad profile value as the default")
	assert_true(h.get_button_actions().has(RIGHT_FIRE), "and builds the right Fire button")
	h.free()
	AppFlow.profile = previous_profile
	_rm()


func test_settings_row_changes_the_mode_and_the_hud_follows_live() -> void:
	await fixture({})
	var panel := SettingsPanel.new()
	panel.save = SaveService.new(TMP)
	tree().root.add_child(panel)
	panel.changed.connect(hud.reload_profile_layout)  # as MatchRoot wires the in-match Settings
	assert_eq(panel.shooting_mode_button.text, "Shooting mode: Advanced", "row shows Advanced")
	hud._on_down(3, hud.get_button_rect(RIGHT_FIRE).get_center())
	step(2)
	assert_true(Input.is_action_pressed("fire"), "fixture: the right Fire is held")
	panel.toggle_shooting_mode()
	assert_eq(panel.save.load_profile()["shooting_mode"], "simple", "stored in the profile")
	assert_eq(AppFlow.profile["shooting_mode"], "simple", "AppFlow.profile follows")
	assert_eq(panel.shooting_mode_button.text, "Shooting mode: Simple", "row shows Simple")
	assert_true(not hud.get_button_actions().has(RIGHT_FIRE), "the live HUD dropped the right Fire button")
	assert_true(not Input.is_action_pressed("fire"), "and the held Fire touch is released")
	hud._on_up(3)
	panel.toggle_shooting_mode()
	assert_eq(panel.save.load_profile()["shooting_mode"], "advanced", "back to Advanced")
	assert_true(hud.get_button_actions().has(RIGHT_FIRE), "the right Fire button is back")
	panel.free()
	await cleanup()


# ---- a real match: LAN rule, end-to-end, live Settings ---------------------------------------------------------------------------

var match_scene: MatchRoot
var touch: Control


func frames(count: int) -> void:
	for i in count:
		await tree().physics_frame
		await tree().process_frame


func _touch_at(point: Vector2, down: bool, index: int = 47) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)


func _tap(point: Vector2) -> void:
	_touch_at(point, true)
	await frames(2)
	_touch_at(point, false)
	await frames(2)


func test_real_match_simple_fires_never_in_lan_and_settings_switch_live() -> void:
	var old_size := tree().root.size
	var old_dpi := PlatformServices.dpi_override
	previous_profile = AppFlow.profile
	_rm()
	AppFlow.profile = SIMPLE.duplicate()
	PlatformServices.dpi_override = 420.0
	tree().root.size = Vector2i(2520, 1080)
	load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"
	match_scene = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	tree().root.add_child(match_scene)
	await tree().process_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	var local := match_scene.local_player
	touch = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	assert_true(not touch.get_button_actions().has(RIGHT_FIRE), "Simple profile: no right Fire button in the match HUD")
	var ground := StaticBody3D.new()
	ground.position = Vector3(1000, -0.1, 0)
	var shape := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(30, 0.2, 30)
	shape.shape = b
	ground.add_child(shape)
	match_scene.add_child(ground)
	local.position = Vector3(1000, 0, 0)
	local.rotation = Vector3.ZERO
	local.pitch = 0.0
	local.velocity = Vector3.ZERO
	local.hit_authority = Callable()  # no damage: the enemy stays alive
	var enemy: Pawn = _PawnScene.instantiate()
	enemy.position = Vector3(1000, 0, -8)
	match_scene.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.set_squad(local.squad_id + 1)
	var count := [0]
	local.fired.connect(func() -> void: count[0] += 1)
	await frames(5)
	assert_eq(local.drop_state, Pawn.Drop.NONE, "fixture: on the ground")
	await _tap(touch.get_button_rect("aim").get_center())
	var fired_in := -1
	for i in 60:
		await frames(1)
		if count[0] > 0:
			fired_in = i
			break
	assert_true(local.aiming, "the real Aim button raised the sight")
	assert_true(fired_in >= 0, "Simple fires in a real offline match (frame %d)" % fired_in)
	# LAN: the same pawn, sight still up, on the same enemy.
	local.pitch = 0.0
	match_scene.networked_match = true
	await frames(2)
	var before: int = count[0]
	var seen := false
	for i in 40:
		await frames(1)
		local.pitch = 0.0
		seen = seen or Input.is_action_pressed("fire")
	assert_eq(touch.simple_fire_block_reason(), "lan", "reason lan (MatchRoot.networked_match via Pawn.in_lan_session)")
	assert_true(not seen and count[0] == before, "in a LAN session Simple never fires")
	match_scene.networked_match = false
	# The in-match Settings row switches the live HUD (MatchRoot wires settings.changed to reload_profile_layout).
	var panel: SettingsPanel = match_scene.pause_menu.settings
	panel.save = SaveService.new(TMP)
	panel.shooting_mode = "simple"
	panel.toggle_shooting_mode()
	assert_eq(AppFlow.profile["shooting_mode"], "advanced", "Settings: Advanced")
	assert_true(touch.get_button_actions().has(RIGHT_FIRE), "the match HUD has the right Fire button again, no restart")
	before = count[0]
	for i in 40:
		await frames(1)
		local.pitch = 0.0
	assert_true(local.aiming and count[0] == before, "Advanced: Aim on an enemy no longer fires")
	panel.toggle_shooting_mode()
	assert_true(not touch.get_button_actions().has(RIGHT_FIRE), "and Simple again removes it")
	match_scene.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	PlatformServices.dpi_override = old_dpi
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""
	AppFlow.profile = previous_profile
	for action in ["fire", "aim"]:
		Input.action_release(action)
	_rm()
	await tree().process_frame
