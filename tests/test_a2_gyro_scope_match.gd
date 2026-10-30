extends "res://tests/test_case.gd"
## A2 T2/T5: real Aim/Swap touches and fake sensor readings in the shipped match.
const Rig := preload("res://tests/button_rig.gd")
const HIP := "tpp_fpp_no_scope"

class FakeGyro extends PlatformServices:
	func has_gyro() -> bool:
		return true
	func get_gyro_rate() -> Vector3:
		return Vector3(0.5, 0.25, 0.0)

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _profile(mode: String) -> Dictionary:
	var settings := SensitivitySettings.new()
	for table in ["gyro", "ads_gyro"]:
		var index := 0
		for row in settings.rows_of(table):
			# Distinct test fixtures, not product tuning.
			settings.set_value(table, row, (41.0 if table == "gyro" else 181.0) + index * 23.0)
			index += 1
	settings.set_gyro_mode(mode)
	var profile := SaveService.defaults()
	profile["sensitivity"] = settings.to_dict()
	return profile

func _start(mode: String) -> Dictionary:
	PlatformServices.dpi_override = 420.0
	AppFlow.profile = _profile(mode) # Before add_child: _ready applies this, never the user's save.
	var ctx: Dictionary = await Rig.setup(Vector2i(2520, 1080), "custom")
	var match_root: MatchRoot = ctx["m"]
	match_root._gyro._platform = FakeGyro.new()
	await Rig.frames(2)
	return ctx

func _finish(ctx: Dictionary) -> void:
	await Rig.teardown(ctx)
	AppFlow.profile = {}
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	PlatformServices.dpi_override = 0.0
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""
	for action in ["aim", "swap_weapon"]:
		Input.action_release(action)
	await _tree().process_frame

func _touch(ctx: Dictionary, action: String, pressed: bool) -> void:
	var hud: Control = ctx["touch"]
	var event := InputEventScreenTouch.new()
	event.index = 51
	event.pressed = pressed
	event.position = _tree().root.get_screen_transform() * hud.get_button_rect(action).get_center()
	_tree().root.push_input(event, false)

func _aim(ctx: Dictionary, active: bool) -> void:
	_touch(ctx, "aim", true)
	await Rig.frames(2)
	_touch(ctx, "aim", false)
	var pawn: Pawn = ctx["pawn"]
	for i in 240:
		if (pawn.aim_blend > 0.0 if active else pawn.aim_blend == 0.0):
			break
		await Rig.frames(1)
	assert_eq(pawn.aiming, active, "real Aim tap changes gameplay")
	assert_true(pawn.aim_blend > 0.0 if active else pawn.aim_blend == 0.0, "bounded aim blend")
	await Rig.frames(2)

func _assert_look(m: MatchRoot, state: String, table: String, silent: bool = false) -> void:
	assert_eq(m.router.aim_state, state, "weapon scope state")
	var row := m.router.sens.row_for_state(state)
	var expected := Vector2(0.25, 0.5) / float(Engine.physics_ticks_per_second)
	expected *= float(DataRegistry.new().load_file("res://data/input.json")["gyro"]["sensitivity"])
	expected *= m.router.sens.percent(table, row) / 100.0
	if silent:
		expected = Vector2.ZERO
	var got := m.router.get_frame().look
	assert_true(got.is_equal_approx(expected), "%s/%s gyro look: expected %s got %s" % [table, row, expected, got])

func _settle(ctx: Dictionary, state: String, table: String, silent: bool = false) -> void:
	var m: MatchRoot = ctx["m"]
	for i in 3:
		await Rig.frames(1)
		if m.router.aim_state == state:
			break
	_assert_look(m, state, table, silent)

func _swap(ctx: Dictionary, expected_state: String) -> void:
	var pawn: Pawn = ctx["pawn"]
	var old_slot := pawn.loadout.active
	_touch(ctx, "swap_weapon", true)
	for i in 8:
		await Rig.frames(1)
		if pawn.loadout.active != old_slot:
			break
	assert_true(pawn.loadout.active != old_slot, "real Swap tap changes active weapon")
	_touch(ctx, "swap_weapon", false)
	await _settle(ctx, expected_state, "ads_gyro")
	assert_true(pawn.aiming and pawn.aim_blend > 0.0, "Swap keeps ADS on")

func test_a2_match_sensor_scope_rows_fallbacks_and_swap() -> void:
	var ctx := await _start("always_on")
	var pawn: Pawn = ctx["pawn"]
	var m: MatchRoot = ctx["m"]
	# Own pawn's defs only. Exercise every valid state independently of shipped scope assignments.
	for slot in pawn.loadout.slots:
		if slot != null:
			slot.def.scope = "no_scope"
	for state in m.router.sens.cfg["states"]:
		if str(state).begins_with("_"):
			continue
		pawn.loadout.get_active().def.scope = str(state)
		await _settle(ctx, "no_scope", "gyro")
		await _aim(ctx, true)
		await _settle(ctx, str(state), "ads_gyro")
		await _aim(ctx, false)
		await _settle(ctx, "no_scope", "gyro")
	pawn.loadout.slots[0].def.scope = "red_dot"
	pawn.loadout.slots[1].def.scope = "16x"
	await _aim(ctx, true)
	await _settle(ctx, "red_dot", "ads_gyro")
	await _swap(ctx, "16x")
	pawn.loadout.get_active().def.scope = "unknown_test_scope"
	await _settle(ctx, "no_scope", "ads_gyro")
	pawn.loadout.get_active().def.scope = "no_scope"
	await _settle(ctx, "no_scope", "ads_gyro")
	await _aim(ctx, false)
	await _settle(ctx, "no_scope", "gyro")
	await _finish(ctx)

func test_a2_scope_on_sensor_is_silent_at_hip_and_uses_ads_scope() -> void:
	var ctx := await _start("scope_on")
	var pawn: Pawn = ctx["pawn"]
	for weapon in pawn.loadout.slots:
		if weapon != null:
			weapon.def.scope = "4x"
	await _settle(ctx, "no_scope", "gyro", true)
	await _aim(ctx, true)
	await _settle(ctx, "4x", "ads_gyro")
	await _aim(ctx, false)
	await _settle(ctx, "no_scope", "gyro", true)
	await _finish(ctx)

func _data_state(pawn: Pawn, weapons: Dictionary) -> String:
	return str(weapons[pawn.loadout.get_active().def.id].get("scope", "no_scope"))

func test_a2_shipped_class_loadouts_select_weapon_scope_while_aiming() -> void:
	var registry := DataRegistry.new()
	var weapons: Dictionary = registry.load_file("res://data/stats.json")["weapons"]
	var classes: Dictionary = registry.load_file("res://data/loadouts.json")["classes"]
	for class_id in classes:
		var ctx := await _start("always_on")
		var pawn: Pawn = ctx["pawn"]
		# Existing setup seam replaces this pawn's bridge/loadout, like respawn; no data mutations.
		pawn.setup(str(class_id), pawn.squad_id)
		await _settle(ctx, "no_scope", "gyro")
		assert_eq(pawn.loadout.get_active().def.id, registry.get_loadout_ids(str(class_id))["primary"], "data primary active")
		var state := _data_state(pawn, weapons)
		await _aim(ctx, true)
		await _settle(ctx, state, "ads_gyro")
		var next_id := str(registry.get_loadout_ids(str(class_id))["secondary"])
		var next_state := str(weapons[next_id].get("scope", "no_scope"))
		await _swap(ctx, next_state)
		assert_eq(pawn.loadout.get_active().def.id, next_id, "data secondary active")
		await _aim(ctx, false)
		await _settle(ctx, "no_scope", "gyro")
		await _finish(ctx)
