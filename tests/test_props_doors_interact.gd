extends "res://tests/test_case.gd"
## M2 L1c commit 3: Interact and doors in the real match scene (the fixture map plus doors placed by the test).
## The button reads "Open door" / "Close door" ("Open gate" / "Close gate") for the door a press would toggle; a press
## toggles the NEAREST door in range and nothing else; MatchRoot keeps revive > pickup > chest > door; a DOWNED pawn
## or a client toggles nothing.

const _MatchScene := preload("res://scenes/match/match.tscn")

var m: MatchRoot
var old_size: Vector2i
var old_profile: Dictionary


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame
		await _tree().process_frame


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


## A door `ahead_m` in front of `pawn` (its leaves across the pawn's view, its threshold at the pawn's feet),
## registered on the match's WorldProps.
func _door_ahead(pawn: Pawn, id: String, ahead_m: float, kind := Door.KIND_DOOR, start := "closed", side_m := 0.0) -> Door:
	var h := 2.3 if kind == Door.KIND_DOOR else 4.5
	var basis := pawn.global_transform.basis
	var at := pawn.global_position - basis.z * ahead_m + basis.x * side_m + Vector3(0, h * 0.5, 0)
	var size := [2.0, 2.3, 0.12] if kind == Door.KIND_DOOR else [4.0, 4.5, 0.25]
	var entry := {"id": id, "kind": kind, "at": [at.x, at.y, at.z], "yaw": rad_to_deg(pawn.global_rotation.y), "size": size,
		"slide": "apart" if kind == Door.KIND_GATE else "right", "start": start}
	var d := Door.make(entry, WorldProps.door_cfg(WorldProps.config(), kind))
	m.map.add_child(d)
	m.world_props.register_door(d)
	return d


## A chest beside `pawn` (1.6 m to its right, its bottom at the pawn's feet), registered on the match's WorldProps.
func _chest_beside(pawn: Pawn, id: String) -> LootChest:
	var at := pawn.global_position + pawn.global_transform.basis.x * 1.6 + Vector3(0, 0.45, 0)
	var c := LootChest.make({"id": id, "at": [at.x, at.y, at.z], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	m.map.add_child(c)
	m.world_props.register_chest(c)
	return c


func test_label_reads_both_states_and_a_press_toggles_the_nearest_only() -> void:
	await _setup_match()
	var me := m.local_player
	_clear_near(me.global_position)
	await frames(2)
	var button := m.hud.interact_button
	assert_true(not button.visible, "hidden: nothing in range")
	var near := _door_ahead(me, "Door_970", 1.4)
	var far := _door_ahead(me, "Door_971", 1.8)
	await frames(2)
	assert_true(far.distance_to(me.global_position) <= far.interact_range_m, "nonvacuous: the second door is in range too")
	assert_eq(m.director.door_target_for(me.player_id), "Door_970", "the nearer door is the target")
	assert_true(button.visible, "Interact shows next to a door")
	assert_eq(button.label.text, "Open door", "a closed door reads Open door")
	m._on_action_triggered("interact")
	await frames(2)
	assert_eq(m.world_props.state_of("Door_970"), WorldProps.OPEN, "the press opened the nearest door")
	assert_eq(m.world_props.state_of("Door_971"), WorldProps.CLOSED, "and nothing else")
	assert_eq(button.label.text, "Close door", "an open door reads Close door")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Door_970"), WorldProps.CLOSED, "the next press closes it again")
	assert_eq(m.world_props.state_of("Door_971"), WorldProps.CLOSED, "the other one still untouched")
	assert_true(near.open == false and far.open == false, "the bodies follow")
	# A gate reads its own noun.
	near.position.y += 100.0
	far.position.y += 100.0
	_door_ahead(me, "Gate_970", 2.0, Door.KIND_GATE, "open")
	await frames(2)
	assert_eq(m.director.door_target_for(me.player_id), "Gate_970", "the gate is the target")
	assert_eq(button.label.text, "Close gate", "an open gate reads Close gate")
	m._on_action_triggered("interact")
	await frames(2)
	assert_eq(button.label.text, "Open gate", "a closed gate reads Open gate")
	# A client toggles nothing (no request path until M3).
	m.director.authoritative = false
	m.world_props.authority = false
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Gate_970"), WorldProps.CLOSED, "a client press changes nothing")
	assert_true(not m.director.try_toggle_door(me.player_id), "a client's director toggles nothing")
	m.director.authoritative = true
	m.world_props.authority = true
	await _cleanup_match()


func test_interact_priority_pickup_then_chest_then_door() -> void:
	await _setup_match()
	var me := m.local_player
	me.apply_start_kit({"secondary": "gladius_lux"})  # empty gun slots: the gun is usable
	_clear_near(me.global_position)
	_door_ahead(me, "Door_972", 1.4)
	_chest_beside(me, "Chest_972")
	m.loot.drop({"item_id": "pilum_br"}, me.global_position - me.global_transform.basis.x * 0.8)
	await frames(1)
	assert_true(m.director.door_target_for(me.player_id) == "Door_972" and m.director.chest_target_for(me.player_id) == "Chest_972", "nonvacuous: a door and a chest in range")
	m._on_action_triggered("interact")
	assert_true(me.loadout.slots[0] != null and me.loadout.slots[0].def.id == "pilum_br", "the first press picks the gun up")
	assert_eq(m.world_props.state_of("Chest_972"), WorldProps.INTACT, "the chest stays closed")
	assert_eq(m.world_props.state_of("Door_972"), WorldProps.CLOSED, "the door stays closed")
	assert_eq(m.hud.interact_button._label_text(), "Open chest", "the chest comes before the door in the label")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Chest_972"), WorldProps.OPEN, "the second press opens the chest")
	assert_eq(m.world_props.state_of("Door_972"), WorldProps.CLOSED, "the door still closed")
	assert_eq(m.hud.interact_button._label_text(), "Open door", "then the door")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Door_972"), WorldProps.OPEN, "the third press, nothing else left, opens the door")
	await _cleanup_match()


func test_interact_priority_revive_before_door_and_downed_cannot_toggle() -> void:
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
	for b: Pawn in m.bots:
		if b != mate:
			b.global_position = me.global_position + Vector3(15.0 + 2.0 * b.player_id, 0.0, 15.0)
	_clear_near(me.global_position)
	_door_ahead(me, "Door_973", 1.4)
	mate.global_position = me.global_position - me.global_transform.basis.x * 1.0
	mate.bridge.state.shield = 0.0
	mate.bridge.state.health = 1.0
	var rifle := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	mate.receive_hit(rifle, false, enemy.squad_id, enemy.player_id)
	await frames(2)
	assert_true(mate.is_downed(), "the mate is DOWNED")
	assert_eq(m.director.door_target_for(me.player_id), "Door_973", "the door is in range of the local pawn")
	m._on_action_triggered("interact")
	assert_eq(m.world_props.state_of("Door_973"), WorldProps.CLOSED, "revive wins: the door stays closed")
	m._on_action_released("interact", true)
	assert_eq(m.director.door_target_for(mate.player_id), "", "a DOWNED pawn has no door target")
	assert_true(not m.director.try_toggle_door(mate.player_id), "a DOWNED pawn cannot toggle")
	await _cleanup_match()
