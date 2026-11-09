extends "res://tests/test_case.gd"
## M1 S4: ground loot, the starting kit, pickups through the real tapped Interact button, armor tiers,
## gun replacement, ammo, guns dropped on elimination and bot pickups.

const _MatchScene := preload("res://scenes/match/match.tscn")

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame
		await tree().process_frame


func setup_loot_match(mode: String = "solo") -> void:
	old_size = tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 31337
	m.ground_loot = true
	tree().root.add_child(m)
	await tree().process_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	assert_true(m.begin(), "match begins")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await frames(3)


func cleanup() -> void:
	m.queue_free()
	await tree().process_frame
	tree().root.size = old_size
	AppFlow.profile = old_profile


func touch_at(point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 7
	event.pressed = down
	event.position = tree().root.get_screen_transform() * point
	tree().root.push_input(event, false)


## Clears the ground near the local pawn so only test items are in range.
func clear_near(pos: Vector3) -> void:
	for id in m.loot.items.keys():
		if Vector2(m.loot.items[id]["pos"].x - pos.x, m.loot.items[id]["pos"].z - pos.z).length() < 6.0:
			m.loot.take(id)


func test_weighted_pick_is_seeded_and_valid() -> void:
	var defs := {"a": {"weight": 3}, "b": {"weight": 1}, "c": {"weight": 0}}
	var r1 := RandomNumberGenerator.new()
	r1.seed = 5
	var r2 := RandomNumberGenerator.new()
	r2.seed = 5
	var one := LootField.pick_item_ids(defs, 400, r1)
	assert_eq(one, LootField.pick_item_ids(defs, 400, r2), "same seed, same items")
	assert_true(not ("c" in one), "zero weight never picked")
	var a_count := one.count("a")
	assert_true(a_count > 240 and a_count < 360, "weights respected (a ~ 300 of 400, got %d)" % a_count)


func test_loot_is_placed_on_the_ground_and_start_kit_is_the_blade() -> void:
	await setup_loot_match()
	assert_true(m.loot.placed, "placed on the first physics tick")
	var n := m.loot.items.size()
	assert_true(n > 30 and n <= 70, "most of the 70 items found ground (%d)" % n)
	for id in m.loot.items:
		assert_true(float(m.loot.items[id]["pos"].y) < 2.0, "item %d on walkable ground" % id)
	var lo := m.local_player.loadout
	assert_true(lo.slots[0] == null and lo.slots[2] == null, "no guns at the start")
	assert_eq(lo.get_active().def.id, "gladius_lux", "the blade is active")
	await cleanup()


func test_tap_interact_picks_up_a_gun() -> void:
	await setup_loot_match()
	var me := m.local_player
	clear_near(me.global_position)
	m.loot.drop({"item_id": "pilum_br"}, me.global_position + me.global_transform.basis.x * 0.8)
	await frames(2)
	var button := m.hud.interact_button
	assert_true(button.visible, "Interact shows near loot")
	assert_eq(button.label.text, "Pick up\nPilum BR", "names the item")
	var c := button.get_touch_rect().get_center()
	touch_at(c, true)
	await frames(2)
	touch_at(c, false)
	await frames(2)
	assert_true(me.loadout.slots[0] != null and me.loadout.slots[0].def.id == "pilum_br", "Pilum BR in the primary slot")
	assert_eq(me.loadout.active, 0, "and in hand")
	assert_true(not button.visible, "nothing left to pick up")
	await cleanup()


func test_armor_tiers_and_refusals() -> void:
	await setup_loot_match()
	var me := m.local_player
	var base := me.bridge.state.max_shield
	var a2 := m.loot.def("armor_2")
	assert_true(me.can_take(a2), "armor II usable")
	me.take_item({"item_id": "armor_2"}, a2)
	assert_eq(me.armor_tier, 2, "tier 2 worn")
	assert_true(absf(me.bridge.state.max_shield - base * 1.4) < 1e-3, "shield cap +40%")
	assert_true(not me.can_take(m.loot.def("armor_1")), "a lower tier is refused")
	assert_true(not me.can_take(m.loot.def("armor_2")), "the same tier is refused")
	assert_true(me.can_take(m.loot.def("armor_3")), "a higher tier is usable")
	assert_true(not me.can_take(m.loot.def("ammo")), "ammo refused without a gun")
	await cleanup()


func test_gun_replacement_drops_the_old_gun_with_its_ammo_and_ammo_adds_reserve() -> void:
	await setup_loot_match()
	var me := m.local_player
	clear_near(me.global_position)
	me.take_item({"item_id": "pilum_br"}, m.loot.def("pilum_br"))
	me.take_item({"item_id": "sagittarii_rifle"}, m.loot.def("sagittarii_rifle"))
	assert_eq([me.loadout.slots[0].def.id, me.loadout.slots[2].def.id], ["pilum_br", "sagittarii_rifle"], "two guns")
	me.loadout.slots[2].ammo_in_mag = 1
	m.loot.drop({"item_id": "pilum_br", "ammo_in_mag": 3, "reserve": 9}, me.global_position)
	var before := m.loot.items.size()
	await frames(1)
	assert_true(m.director.try_pickup(me.player_id), "picked up the third gun")
	assert_eq(me.loadout.slots[2].def.id, "pilum_br", "replaced the gun in hand")
	assert_eq([me.loadout.slots[2].ammo_in_mag, me.loadout.slots[2].reserve], [3, 9], "picked gun keeps its ammo")
	assert_eq(m.loot.items.size(), before, "the old gun lies on the ground instead")
	var dropped := m.loot.nearest(me.global_position, 2.0)
	assert_eq(str(m.loot.items[dropped]["item_id"]), "sagittarii_rifle", "it is the rifle")
	assert_eq(int(m.loot.items[dropped]["ammo_in_mag"]), 1, "with the ammo it had")
	var reserve := me.loadout.get_active().reserve
	me.take_item({"item_id": "ammo"}, m.loot.def("ammo"))
	assert_eq(me.loadout.get_active().reserve, reserve + int(m.loot.def("ammo")["rounds"]), "ammo adds reserve")
	await cleanup()


func test_eliminated_player_drops_guns_and_bots_pick_up() -> void:
	await setup_loot_match()
	var bot: Pawn = m.bots[0]
	clear_near(bot.global_position)
	bot.take_item({"item_id": "pilum_br"}, m.loot.def("pilum_br"))
	var before := m.loot.items.size()
	m.director.rules.report_zero_health(bot.player_id, -1, "zone")  # solo: straight to DEAD
	await frames(2)
	assert_eq(bot.life, Pawn.Life.DEAD, "bot eliminated")
	assert_eq(m.loot.items.size(), before + 1, "its gun dropped")
	var other: Pawn = m.bots[1]
	clear_near(other.global_position)
	m.loot.drop({"item_id": "armor_1"}, other.global_position)
	await frames(2)
	assert_eq(other.armor_tier, 1, "a bot standing on armor picks it up")
	await cleanup()
