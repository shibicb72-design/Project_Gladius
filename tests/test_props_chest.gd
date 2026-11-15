extends "res://tests/test_case.gd"
## M2 L1b: loot chests. WorldProps.open_chest opens a closed chest once on the authority (state OPEN, the closed look
## hidden and the open one shown on the batch metas, the seeded roll of chest.loot spilled on a ring in front of it
## at its ground height, reachable by a pickup from there, prop_changed once); a client opens nothing and applies
## the host's OPEN as a look swap only; chest_near keeps to the range and the height limit. In the real match scene:
## the Interact button reads "Open chest" and a tap opens it; MatchRoot's interact path keeps revive > pickup >
## chest; bots open a chest in range through _bot_pickups; a DOWNED or dead pawn cannot open one.

const _MatchScene := preload("res://scenes/match/match.tscn")
const SEED := 4242

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame
		await _tree().process_frame


func _loot() -> LootField:
	var f := LootField.new()
	f.setup(DataRegistry.new().load_file(MatchDirector.LOOT_PATH), 7)
	f.placed = true  # no ground placement: only the chests' drops
	_tree().root.add_child(f)
	return f


func _props(authority: bool, loot: LootField, seed_value := SEED) -> WorldProps:
	var p := WorldProps.new()
	p.setup(WorldProps.config(), seed_value, authority, loot)
	_tree().root.add_child(p)
	return p


func _chest(id: String, at := Vector3(0, 0.45, 0), yaw := 0.0) -> LootChest:
	var c := LootChest.make({"id": id, "at": [at.x, at.y, at.z], "size": [1.4, 0.9, 0.9], "yaw": yaw}, "camp")
	_tree().root.add_child(c)
	return c


## A chest's two looks as named pieces of a real MapChunks, the open one hidden (the builder's order).
func _looks(c: LootChest) -> MapChunks:
	var chunks := MapChunks.new()
	chunks.setup(200.0)
	var mesh := BoxMesh.new()
	chunks.add("cover", "loot_chest", mesh, null, c.transform, true, c.prop_id)
	chunks.add("cover", "loot_chest_open", mesh, null, c.transform, true, LootChest.open_id(c.prop_id))
	chunks.build()
	chunks.hide_piece(LootChest.open_id(c.prop_id))
	c.chunks = chunks
	return chunks


func _cleanup(nodes: Array) -> void:
	await _tree().process_frame
	for n: Node in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await _tree().process_frame


func test_props_json_chest_block_validates() -> void:
	var cfg := WorldProps.config()
	var chest: Dictionary = cfg["chest"]
	assert_true(String(chest["_todo"]).contains("OQ-PROPS-CHEST"), "the chest numbers are placeholders (OQ-PROPS-CHEST)")
	assert_eq(WorldProps.problems({}, cfg), PackedStringArray(), "props.json has no problem")
	var bad := cfg.duplicate(true)
	bad["chest"]["interact_range_m"] = 0
	bad["chest"]["look_open"] = {"parts": []}
	assert_true(WorldProps.problems({}, bad).size() >= 2, "a zero range and an empty look are reported")
	var cases := {
		"bad yaw": {"chests": [{"id": "C", "at": [0, 0, 0], "size": [1, 1, 1], "yaw": 45.0}]},
		"duplicate id": {"pieces": [{"id": "X"}], "chests": [{"id": "X", "at": [0, 0, 0], "size": [1, 1, 1], "yaw": 0.0}]},
		"bad size": {"chests": [{"id": "C", "at": [0, 0, 0], "size": [1, 0, 1], "yaw": 0.0}]},
		"not a list": {"chests": {}},
	}
	for what: String in cases:
		assert_true(not WorldProps.problems(cases[what], cfg).is_empty(), what + " is reported")
	var good := {"chests": [{"id": "Chest_000", "at": [1, 0.45, 2], "size": [1.4, 0.9, 0.9], "yaw": 270.0}]}
	assert_eq(WorldProps.problems(good, cfg), PackedStringArray(), "a good chest passes")


func test_open_once_swaps_the_looks_and_spills_the_seeded_roll_in_front() -> void:
	var loot := _loot()
	var props := _props(true, loot)
	props.cfg = WorldProps.config().duplicate(true)
	props.cfg["chest"]["loot"] = {"count_min": 3, "count_max": 3, "item_kinds": []}  # nonvacuous spill
	var c := _chest("Chest_900", Vector3(4, 0.45, 5), 90.0)
	var chunks := _looks(c)
	props.register_chest(c)
	var changes: Array = []
	props.prop_changed.connect(func(id: String, s: int) -> void: changes.append([id, s]))
	assert_true(not chunks.is_piece_hidden("Chest_900") and chunks.is_piece_hidden("Chest_900/open"), "starts closed: closed look drawn, open look hidden")
	var want := WorldProps.loot_roll(loot.cfg["items"], props.cfg["chest"]["loot"], SEED, "Chest_900", "chest")
	assert_true(props.open_chest("Chest_900"), "opens")
	assert_eq(props.state_of("Chest_900"), WorldProps.OPEN, "the state is OPEN")
	assert_eq(changes, [["Chest_900", WorldProps.OPEN]], "prop_changed once")
	assert_true(c.is_open, "the chest knows it is open")
	assert_true(chunks.is_piece_hidden("Chest_900") and not chunks.is_piece_hidden("Chest_900/open"), "the looks are swapped on the batch metas")
	assert_true(not props.open_chest("Chest_900"), "a second open does nothing")
	assert_eq(changes.size(), 1, "still one prop_changed")
	assert_eq(props.chest_near(Vector3(4, 0, 5)), "", "an open chest is no target")
	assert_eq(props.spilled.size(), 3, "the roll is spilled")
	# yaw 90: the front is -x; the spill ring sits spill_offset_m past the front face at the ground height.
	var chest_cfg: Dictionary = props.cfg["chest"]
	var centre := Vector3(4 - 0.45 - float(chest_cfg["spill_offset_m"]), 0.0, 5)
	assert_true(c.spill_centre(float(chest_cfg["spill_offset_m"])).is_equal_approx(centre), "the spill centre is in front (-x at yaw 90)")
	for i in props.spilled.size():
		var item: Dictionary = loot.items[props.spilled[i]]
		var p: Vector3 = item["pos"]
		assert_eq(String(item["item_id"]), want[i], "item %d is the roll's" % i)
		assert_true(is_equal_approx(Vector2(p.x - centre.x, p.z - centre.z).length(), float(chest_cfg["spill_radius_m"])), "item %d on the spill ring" % i)
		assert_true(is_equal_approx(p.y, 0.25), "item %d at the ground height (+ LootField's 0.25)" % i)
		assert_true(p.x < 4 - 0.45, "item %d lies in front of the front face" % i)
	# Reachable: every item is picked up from the spill centre (a player standing in front of the chest).
	var range_m := float(loot.cfg.get("pickup_range_m", 2.0))
	var taken := 0
	for i in props.spilled.size():
		var id := loot.nearest(centre, range_m)
		if id >= 0:
			loot.take(id)
			taken += 1
	assert_eq(taken, 3, "every spilled item is in pickup range from in front of the chest")
	await _cleanup([props, loot, c])


func test_contents_are_seeded_by_match_seed_and_chest_id() -> void:
	var a_loot := _loot()
	var b_loot := _loot()
	var a := _props(true, a_loot, 99)
	var b := _props(true, b_loot, 99)
	var ca := _chest("Chest_901")
	var cb := _chest("Chest_901", Vector3(20, 0.45, 0))
	a.register_chest(ca)
	b.register_chest(cb)
	a.open_chest("Chest_901")
	b.open_chest("Chest_901")
	var ids_a: Array = []
	var ids_b: Array = []
	for id in a.spilled:
		ids_a.append(a_loot.items[id]["item_id"])
	for id in b.spilled:
		ids_b.append(b_loot.items[id]["item_id"])
	assert_true(ids_a.size() >= 2, "nonvacuous: %d items" % ids_a.size())
	assert_eq(ids_a, ids_b, "same seed and id: the same items, wherever the chest stands")
	var roll: Dictionary = WorldProps.config()["chest"]["loot"]
	var items: Dictionary = a_loot.cfg["items"]
	var differ := 0
	for i in 20:
		if WorldProps.loot_roll(items, roll, 99, "Chest_%03d" % (910 + i), "chest") != WorldProps.loot_roll(items, roll, 99, "Chest_901", "chest"):
			differ += 1
	assert_true(differ > 0, "other chest ids give other contents")
	await _cleanup([a, b, a_loot, b_loot, ca, cb])


func test_a_client_opens_nothing_and_applies_the_host_state_as_a_look() -> void:
	var loot := _loot()
	var props := _props(false, loot)
	var c := _chest("Chest_902")
	var chunks := _looks(c)
	props.register_chest(c)
	var changes: Array = []
	props.prop_changed.connect(func(id: String, _s: int) -> void: changes.append(id))
	assert_true(not props.open_chest("Chest_902"), "a client cannot open")
	assert_eq(props.state_of("Chest_902"), WorldProps.INTACT, "still closed")
	assert_true(not c.is_open and not chunks.is_piece_hidden("Chest_902"), "the closed look stays")
	props.apply_state("Chest_902", WorldProps.OPEN)
	assert_eq(props.state_of("Chest_902"), WorldProps.OPEN, "the host's state is applied")
	assert_true(chunks.is_piece_hidden("Chest_902") and not chunks.is_piece_hidden("Chest_902/open"), "the looks swapped")
	assert_true(props.spilled.is_empty() and loot.items.is_empty(), "no loot on a client")
	assert_true(changes.is_empty(), "no prop_changed on a client")
	props.apply_state("Chest_902", WorldProps.BROKEN)
	assert_eq(props.state_of("Chest_902"), WorldProps.OPEN, "a later state does not overwrite it")
	assert_true(is_instance_valid(c) and c.is_inside_tree(), "an open chest stays in the world")
	await _cleanup([props, loot, c])


func test_chest_near_keeps_range_and_height() -> void:
	var props := _props(true, null)
	var near := _chest("Chest_903", Vector3(0, 0.45, 0))
	var far := _chest("Chest_904", Vector3(1.5, 0.45, 0))
	props.register_chest(near)
	props.register_chest(far)
	var range_m := float(props.cfg["chest"]["interact_range_m"])
	assert_eq(props.chest_near(Vector3(-0.8, 0, 0)), "Chest_903", "the nearest closed chest")
	assert_eq(props.chest_near(Vector3(2.4, 0, 0)), "Chest_904", "the other one when nearer")
	assert_eq(props.chest_near(Vector3(1.5 + range_m + 0.1, 0, 0)), "", "out of range: none")
	assert_eq(props.chest_near(Vector3(0, float(props.cfg["chest"]["height_limit_m"]) + 0.5, 0)), "", "too far above: none")
	props.open_chest("Chest_903")
	assert_eq(props.chest_near(Vector3(-0.8, 0, 0)), "Chest_904", "an open chest is skipped")
	await _cleanup([props, near, far])


func test_collect_finds_chests_under_a_map() -> void:
	var map := Node3D.new()
	var nav := Node3D.new()
	nav.add_child(LootChest.make({"id": "Chest_905", "at": [0, 0.45, 0], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp"))
	map.add_child(nav)
	var p := WorldProps.new()
	p.setup(WorldProps.config(), 1, true)
	p.collect(map)
	assert_eq(p.chests.keys(), ["Chest_905"], "the chest is registered")
	assert_true(p.breakables.is_empty(), "and is no breakable")
	var c: LootChest = p.chests["Chest_905"]
	assert_true(c.is_in_group(LootChest.GROUP) and not c.is_in_group(&"cover_wall"), "group loot_chest, never cover_wall")
	assert_true(c.collision_layer == 1 and c.get_node_or_null("Shape") != null and c.has_meta(&"cover_palette"), "layer 1, a Shape box, a palette")
	p.free()
	map.free()


## ---- In the real match scene (the fixture map plus a chest placed by the test). ----

func _setup_match(mode := "solo") -> void:
	old_size = _tree().root.size
	old_profile = AppFlow.profile
	AppFlow.profile = {}
	_tree().root.size = Vector2i(2520, 1080)
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 31337
	m.ground_loot = true
	_tree().root.add_child(m)
	await _tree().process_frame
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


func _cleanup_match() -> void:
	m.queue_free()
	await _tree().process_frame
	_tree().root.size = old_size
	AppFlow.profile = old_profile
	_tree().paused = false


func _clear_near(pos: Vector3) -> void:
	for id in m.loot.items.keys():
		if Vector2(m.loot.items[id]["pos"].x - pos.x, m.loot.items[id]["pos"].z - pos.z).length() < 8.0:
			m.loot.take(id)


## A chest beside `pawn` (1.6 m to its right, its bottom at the pawn's feet), registered on the match's WorldProps.
func _chest_beside(pawn: Pawn, id: String) -> LootChest:
	var at := pawn.global_position + pawn.global_transform.basis.x * 1.6 + Vector3(0, 0.45, 0)
	var c := LootChest.make({"id": id, "at": [at.x, at.y, at.z], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	m.map.add_child(c)
	m.world_props.register_chest(c)
	return c


func _touch_at(point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 7
	event.pressed = down
	event.position = _tree().root.get_screen_transform() * point
	_tree().root.push_input(event, false)


func test_interact_button_reads_open_chest_and_a_tap_opens_it() -> void:
	await _setup_match()
	var me := m.local_player
	_clear_near(me.global_position)
	await frames(2)
	var button := m.hud.interact_button
	assert_true(not button.visible, "hidden: nothing in range")
	_chest_beside(me, "Chest_950")
	await frames(2)
	assert_eq(m.director.chest_target_for(me.player_id), "Chest_950", "the chest is the target")
	assert_true(button.visible, "Interact shows next to a closed chest")
	assert_eq(button.label.text, "Open chest", "labelled Open chest")
	var c := button.get_touch_rect().get_center()
	_touch_at(c, true)
	await frames(2)
	_touch_at(c, false)
	await frames(2)
	assert_eq(m.world_props.state_of("Chest_950"), WorldProps.OPEN, "the tap opened it")
	assert_eq(m.director.chest_target_for(me.player_id), "", "no target once open")
	var spilled := m.world_props.spilled.size()
	assert_true(spilled >= 1, "its loot is on the ground: %d items" % spilled)
	await _cleanup_match()


func test_interact_priority_pickup_before_chest() -> void:
	await _setup_match()
	var me := m.local_player
	me.apply_start_kit({"secondary": "gladius_lux"})  # empty gun slots: the gun is usable
	_clear_near(me.global_position)
	_chest_beside(me, "Chest_951")
	m.loot.drop({"item_id": "pilum_br"}, me.global_position - me.global_transform.basis.x * 0.8)
	await frames(1)
	m._on_action_triggered("interact")
	assert_true(me.loadout.slots[0] != null and me.loadout.slots[0].def.id == "pilum_br", "the first press picks the gun up")
	assert_eq(m.world_props.state_of("Chest_951"), WorldProps.INTACT, "and does not open the chest")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Chest_951"), WorldProps.OPEN, "the next press, with nothing to pick up, opens it")
	await _cleanup_match()


func test_interact_priority_revive_before_chest_and_downed_or_dead_cannot_open() -> void:
	await _setup_match("squads")
	var me := m.local_player
	var mate: Pawn = null
	var enemy: Pawn = null
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		if p == me:
			continue
		if p.squad_id == me.squad_id and mate == null:
			mate = p
		elif p.squad_id != me.squad_id and enemy == null:
			enemy = p
	assert_true(mate != null and enemy != null, "a squad mate and an enemy")
	# Every other bot far away: a bot in range would open the chest itself (_bot_pickups).
	for b: Pawn in m.bots:
		if b != mate:
			b.global_position = me.global_position + Vector3(15.0 + 2.0 * b.player_id, 0.0, 15.0)
	_clear_near(me.global_position)
	_chest_beside(me, "Chest_952")
	mate.global_position = me.global_position - me.global_transform.basis.x * 1.0
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	var rifle := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	mate.receive_hit(rifle, false, enemy.squad_id, enemy.player_id)
	await frames(2)
	assert_true(mate.is_downed(), "the mate is DOWNED")
	assert_eq(m.director.chest_target_for(me.player_id), "Chest_952", "the chest is in range of the local pawn")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Chest_952"), WorldProps.INTACT, "revive wins: the chest stays closed")
	m._on_action_released("interact", true)
	# The DOWNED mate stands by a second chest: it cannot open it.
	_chest_beside(mate, "Chest_953")
	assert_eq(m.director.chest_target_for(mate.player_id), "", "a DOWNED pawn has no chest target")
	assert_true(not m.director.try_open_chest(mate.player_id), "a DOWNED pawn cannot open")
	mate.receive_hit(rifle, false, enemy.squad_id, enemy.player_id)
	await frames(1)
	assert_true(not mate.is_alive() and not mate.is_downed(), "a further hit finishes the mate")
	assert_true(not m.director.try_open_chest(mate.player_id), "a dead pawn cannot open")
	assert_eq(m.world_props.state_of("Chest_953"), WorldProps.INTACT, "the second chest stays closed")
	await _cleanup_match()


func test_bots_open_a_chest_in_range_through_bot_pickups() -> void:
	await _setup_match()
	var bot: Pawn = null
	for b: Pawn in m.bots:
		if b.is_alive() and not b.is_dropping():
			bot = b
			break
	assert_true(bot != null, "an alive bot")
	var me := m.local_player
	var bot_chest := _chest_beside(bot, "Chest_954")
	var my_chest := _chest_beside(me, "Chest_955")
	assert_eq(m.director.chest_target_for(bot.player_id), "Chest_954", "in the bot's range")
	m.director._bot_pickups()
	assert_eq(m.world_props.state_of("Chest_954"), WorldProps.OPEN, "the bot opened its chest")
	assert_eq(m.world_props.state_of("Chest_955"), WorldProps.INTACT, "the human's chest is not opened by the bot pass")
	assert_true(bot_chest.is_open and not my_chest.is_open, "the looks follow")
	m.director.authoritative = false
	var other := _chest_beside(bot, "Chest_956")
	bot_chest.position.x += 50.0
	m.director._bot_pickups()
	assert_eq(m.world_props.state_of("Chest_956"), WorldProps.INTACT, "not authoritative: nothing opens")
	assert_true(not other.is_open, "the look stays closed")
	m.director.authoritative = true
	await _cleanup_match()
