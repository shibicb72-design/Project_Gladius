extends "res://tests/test_case.gd"
## M2 L1b: the two damage hooks (scripts/weapons/hitscan.gd fire, scripts/weapons/melee.gd swing) on a breakable.
## A ray that hits a crate breaks it through BOTH shot paths: the offline local authority (Pawn.fire_shot ->
## Hitscan.fire -> Pawn._local_authority) and the host (NetMatchBridge.host_handle_fire -> Hitscan.fire with
## _host_authority); an invalid authority (a client) leaves it untouched. The shot's result keeps target null (no
## hit marker: hud.gd shows one only for a target; the sims count a hit only for a Pawn target) and the shot's own
## impact probe still finds the crate in the breaking frame, so the cover_palette impact plays. A swing breaks a crate
## in its range and arc unless world geometry stands between; its returned pawns are unchanged. Pawn rule results
## are pinned (numbers from data/stats.json, the same as tests/test_melee_rule.gd): the hooks change no pawn damage.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const PEER := 78
const PID := 6


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _settle() -> void:
	for i in 2:
		await _tree().physics_frame
	await _tree().process_frame


func _crate(parent: Node, id: String, at: Vector3) -> Breakable:
	var b := Breakable.make({"id": id, "type": "breakable_crate", "at": [at.x, at.y, at.z], "size": [1.2, 1.2, 1.2]},
			WorldProps.config()["breakables"]["breakable_crate"])
	parent.add_child(b)
	return b


func _wall(parent: Node, at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = at
	return body


## A pawn scene in the tree, physics off, holding the Sagittarii rifle (damage 90: one ray breaks a 60 crate).
func _shooter(parent: Node, at: Vector3) -> Pawn:
	var pawn: Pawn = _PawnScene.instantiate()
	parent.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = at
	pawn.loadout.slots[0] = Weapon.new(DataRegistry.new().get_weapon_def("sagittarii_rifle"))
	pawn.loadout.active = 0
	return pawn


func _free_voices(sfx: Node) -> void:
	for i in sfx._pool_until.size():
		sfx._pool_until[i] = 0
	sfx._last_play.clear()
	sfx.clear_log()


func test_cast_reports_the_collider_and_keeps_target() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var b := _crate(root, "Breakable_930", Vector3(0, 1.0, -6))
	await _settle()
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	var none: Array[RID] = []
	var res := Hitscan.cast(root.get_world_3d().direct_space_state, Vector3(0, 1.0, 0), Vector3(0, 0, -1), def, none)
	assert_true(not res.is_empty() and res["collider"] == b, "the cast reports the crate as its collider")
	assert_true(res["target"] == null and not bool(res["is_headshot"]), "target stays null for a crate")
	assert_true(not (res.get("target") is Pawn), "the sims' hit rule (target is Pawn) does not count it")
	root.queue_free()
	await _tree().process_frame


func test_local_authority_shot_breaks_a_crate_and_sounds_like_it() -> void:
	var sfx := _tree().root.get_node_or_null("Sfx")
	var root := Node3D.new()
	_tree().root.add_child(root)
	var pawn := _shooter(root, Vector3(0, 0.1, 0))
	var b := _crate(root, "Breakable_931", pawn.get_muzzle_position() + Vector3(0, 0, -6))
	await _settle()
	var resolved: Array = []
	pawn.shot_resolved.connect(func(_o: Vector3, _e: Vector3, hit: Dictionary) -> void: resolved.append(hit))
	if sfx != null:
		_free_voices(sfx)
	var res := pawn.fire_shot()
	assert_true(b.is_broken, "the local authority's shot broke the crate")
	assert_true(res.get("collider") == b and res["target"] == null, "the result names the crate, target null")
	assert_eq(resolved.size(), 1, "shot_resolved once")
	var audio := pawn.get_node_or_null("Audio") as PawnAudio
	if audio != null and sfx != null:
		var impacts: Dictionary = sfx.cfg["impacts"]
		var want := PawnAudio.material_of(b, impacts)
		assert_eq(audio.impact_material_at(pawn.get_muzzle_position(), res["position"]), want, "the shot's impact probe still finds the crate in the breaking frame")
		var sound := String(impacts["by_material"].get(want, ""))
		var ids: Array = []
		for entry: Dictionary in sfx.played:
			ids.append(String(entry["id"]))
		assert_true(sound != "" and ids.has(sound), "the cover_palette impact %s played (%s)" % [sound, str(ids)])
	await _tree().process_frame
	assert_true(not is_instance_valid(b) or not b.is_inside_tree(), "gone the next frame")
	root.queue_free()
	await _tree().process_frame


func test_host_authority_shot_breaks_a_crate() -> void:
	var root := Node.new()
	_tree().root.add_child(root)
	var director := MatchDirector.new()
	root.add_child(director)
	var bridge := NetMatchBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	bridge.set_physics_process(false)
	bridge.setup(director)
	var world := Node3D.new()
	root.add_child(world)
	var pawn := _shooter(world, Vector3(0, 0.1, 0))
	director.add_player(PID, pawn)
	bridge.register_peer(PEER, PID)
	var b := _crate(world, "Breakable_932", pawn.get_muzzle_position() + Vector3(0, 0, -6))
	await _settle()
	var v := bridge.host_handle_fire(PEER, pawn.get_muzzle_position(), Vector3(0, 0, -1), pawn.loadout.get_active().def.id)
	assert_true(bool(v["ok"]), "the host accepted the shot: %s" % str(v.get("reason", "")))
	var hit: Dictionary = v.get("hit", {})
	assert_true(hit.get("collider") == b and hit.get("target") == null, "the host's ray hit the crate, target null")
	assert_true(b.is_broken, "the host's shot broke the crate")
	await _tree().process_frame
	root.queue_free()
	await _tree().process_frame


func test_a_client_shot_leaves_the_crate() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var pawn := _shooter(root, Vector3(0, 0.1, 0))
	pawn.hit_authority = Callable()  # what MatchRoster gives a client's pawns
	var b := _crate(root, "Breakable_933", pawn.get_muzzle_position() + Vector3(0, 0, -6))
	await _settle()
	var full := b.health
	var res := pawn.fire_shot()
	assert_true(res.get("collider") == b, "the client's ray reached the crate")
	assert_true(not b.is_broken and b.health == full, "a client never damages a breakable")
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	Hitscan.fire(root.get_world_3d().direct_space_state, pawn, pawn.get_muzzle_position(), Vector3(0, 0, -1), def,
			pawn.hitscan_exclude(), Callable())
	assert_eq(b.health, full, "Hitscan.fire with an invalid authority leaves it")
	root.queue_free()
	await _tree().process_frame


func test_swing_breaks_a_crate_in_reach_and_not_through_a_wall() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	root.add_child(attacker)
	attacker.set_physics_process(false)
	attacker.global_position = Vector3(0, 80, 0)
	var blade := DataRegistry.new().get_weapon_def("gladius_lux")
	var origin := Vector3(0, 80.8, 0)
	var near := _crate(root, "Breakable_940", Vector3(0, 80.8, -1.5))  # face 0.9 m ahead: in reach, in the arc
	var behind := _crate(root, "Breakable_941", Vector3(0, 80.8, 1.5))  # behind the attacker: out of the arc
	var far := _crate(root, "Breakable_942", Vector3(5, 80.8, -5))  # out of reach
	# In reach (nearest point (-0.9, -1.0): 1.35 m) and in the arc (42 of 50 degrees), with a wall across the line
	# to it (the line passes x -0.45 at z -0.5) that stays clear of the line to `near` (x 0).
	var walled := _crate(root, "Breakable_943", Vector3(-1.5, 80.8, -1.6))
	_wall(root, Vector3(-0.45, 80.8, -0.5), Vector3(0.3, 3.0, 0.2))
	await _settle()
	var space := root.get_world_3d().direct_space_state
	var reached := Melee.breakables_in_swing(space, attacker, origin, Vector3(0, 0, -1), blade)
	assert_true(reached.has(near), "the crate in front is reached")
	assert_true(not reached.has(behind) and not reached.has(far), "behind and far crates are not")
	assert_true(Melee.in_swing(origin, Vector3(0, 0, -1), walled.closest_point(origin), blade), "nonvacuous: the walled crate is in reach and arc")
	assert_true(not reached.has(walled), "a wall between blocks the swing (line of sight)")
	var hit := Melee.swing(space, attacker, origin, Vector3(0, 0, -1), blade, [], Callable())
	assert_true(hit.is_empty() and not near.is_broken, "a client's swing (invalid authority) breaks nothing")
	hit = Melee.swing(space, attacker, origin, Vector3(0, 0, -1), blade, [], Callable(attacker, "_local_authority"))
	assert_true(hit.is_empty(), "the returned pawns are unchanged (none)")
	assert_true(near.is_broken, "the authority's swing breaks the crate in reach (melee_damage)")
	assert_true(not behind.is_broken and not far.is_broken and not walled.is_broken, "the others stand")
	await _tree().process_frame
	root.queue_free()
	await _tree().process_frame


func test_pawn_results_are_pinned_with_the_hooks_present() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var shooter := _shooter(root, Vector3(0, 0, 0))
	shooter.setup("hastati", 0)
	shooter.loadout.slots[0] = Weapon.new(DataRegistry.new().get_weapon_def("sagittarii_rifle"))
	shooter.loadout.active = 0
	var victim: Pawn = _PawnScene.instantiate()
	root.add_child(victim)
	victim.set_physics_process(false)
	victim.setup("hastati", 1)
	victim.global_position = Vector3(0, 0, -6)
	var crate := _crate(root, "Breakable_950", Vector3(3, 0.8, -6))  # beside the line: never hit
	await _settle()
	# A body ray through Hitscan.fire and the local authority: Sagittarii 90 on the Hastati's 100 shield.
	var def: WeaponDef = shooter.loadout.get_active().def
	var res := Hitscan.fire(root.get_world_3d().direct_space_state, shooter, Vector3(0, 0.8, 0), Vector3(0, 0, -1), def,
			shooter.hitscan_exclude(), shooter.hit_authority)
	assert_true(res.get("target") == victim and not bool(res.get("is_headshot", true)), "a body hit on the victim")
	assert_eq(victim.bridge.state.shield, 10.0, "pinned: shield 100 - 90 = 10")
	assert_eq(victim.bridge.state.health, 100.0, "pinned: health untouched")
	assert_true(not crate.is_broken and crate.health == float(WorldProps.config()["breakables"]["breakable_crate"]["health"]), "the crate beside is untouched")
	# The same hit straight through receive_hit on a fresh victim gives the same numbers.
	var fresh := Pawn.new()
	fresh.setup("hastati", 1)
	root.add_child(fresh)
	fresh.set_physics_process(false)
	var r := fresh.receive_hit(def, false, 0)
	assert_true(r.shield_damage == 90.0 and r.health_damage == 0.0 and fresh.bridge.state.shield == 10.0, "receive_hit: the same 90 on the shield")
	# A front swing through Melee.swing and the local authority: 70% of the full 100 shield (DESIGN.md:15).
	var mate := Pawn.new()
	mate.setup("hastati", 1)
	root.add_child(mate)
	mate.set_physics_process(false)
	mate.global_position = Vector3(10, 80, -1.0)
	mate.rotation.y = PI  # faces the attacker (+z): a front hit
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	root.add_child(attacker)
	attacker.set_physics_process(false)
	attacker.global_position = Vector3(10, 80, 0)
	await _settle()
	var blade := DataRegistry.new().get_weapon_def("gladius_lux")
	var hit := Melee.swing(root.get_world_3d().direct_space_state, attacker, attacker.get_muzzle_position(), Vector3(0, 0, -1),
			blade, [mate], Callable(attacker, "_local_authority"))
	assert_eq(hit.size(), 1, "the swing reached the mate")
	assert_eq(mate.bridge.state.shield, 30.0, "pinned: front swing leaves 30 shield")
	assert_eq(mate.bridge.state.health, 100.0, "pinned: health untouched")
	root.queue_free()
	await _tree().process_frame
