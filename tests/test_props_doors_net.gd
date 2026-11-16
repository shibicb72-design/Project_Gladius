extends "res://tests/test_case.gd"
## M2 L1c commit 3: doors over the existing prop event (ev_world_prop), in tests/test_net_match.gd's loopback
## harness (a host and a client in one process, each MatchRoot in its own SubViewport world). One door (starts
## closed) and one gate (starts open) with the same ids and start states on both peers, 50 m up, out of every
## pawn's reach. Before any event both peers hold the same seeded states; the host toggles the door twice (closed ->
## open -> closed) and the client applies each changed ABSOLUTE value; a client toggles nothing; the bridge's wiring
## resend (the late-join path, net_match_bridge.gd _wire_props) carries every door, so a client whose door states
## went wrong ends with the host's.

const _Net := preload("res://tests/test_net_match.gd")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _doors(m: MatchRoot, tag: String) -> Dictionary:
	var cfg := WorldProps.config()
	var door := Door.make({"id": "Door_980", "kind": "door", "at": [3.0, 51.15, 3.0], "yaw": 0.0, "size": [2.0, 2.3, 0.12],
		"slide": "right", "start": "closed"}, WorldProps.door_cfg(cfg, Door.KIND_DOOR))
	var gate := Door.make({"id": "Gate_980", "kind": "gate", "at": [-6.0, 52.25, 3.0], "yaw": 90.0, "size": [4.0, 4.5, 0.25],
		"slide": "apart", "start": "open"}, WorldProps.door_cfg(cfg, Door.KIND_GATE))
	for d: Door in [door, gate]:
		d.name = String(d.name) + tag
		m.map.add_child(d)
		m.world_props.register_door(d)
	return {"door": door, "gate": gate}


func test_e2e_doors_host_and_client_agree_toggle_twice_and_resend_every_door() -> void:
	var h = _Net.new()
	var p: Dictionary = await h._start_pair("DR")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		for b in hm.bots + cm.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
		var hd := _doors(hm, "H")
		var cd := _doors(cm, "C")
		var want := {"Door_980": WorldProps.CLOSED, "Gate_980": WorldProps.OPEN}
		assert_true(hm.world_props.states.has("Door_980") and hm.world_props.states.has("Gate_980"), "every door is stored on the host from the start")
		for id: String in want:
			assert_eq(hm.world_props.state_of(id), want[id], "host %s starts in its seeded state" % id)
			assert_eq(cm.world_props.state_of(id), want[id], "client %s starts in the same state, before any event" % id)
		assert_true(hm.world_props.authority and not cm.world_props.authority, "the host is the props authority")
		await _tree().physics_frame
		await _tree().physics_frame
		assert_true(hm.roster.bridge._props == hm.world_props and cm.roster.bridge._props == cm.world_props, "both bridges wired their WorldProps")
		var client_door: Door = cd["door"]
		# Toggle twice: closed -> open -> closed; the client applies each changed value.
		assert_true(hm.world_props.toggle_door("Door_980"), "the host opens the door")
		var opened: bool = await h._wait_until(func() -> bool: return cm.world_props.state_of("Door_980") == WorldProps.OPEN, h.TIMEOUT_S)
		assert_true(opened and client_door.open, "the client applied OPEN")
		assert_true(hm.world_props.toggle_door("Door_980"), "the host closes it again")
		var closed: bool = await h._wait_until(func() -> bool: return cm.world_props.state_of("Door_980") == WorldProps.CLOSED, h.TIMEOUT_S)
		assert_true(closed and not client_door.open, "the client applied the changed CLOSED")
		assert_eq(cm.world_props.states, hm.world_props.states, "both peers hold the same states")
		var settled: bool = await h._wait_until(func() -> bool: return (hd["door"] as Door).settled() and client_door.settled(), h.TIMEOUT_S)
		assert_true(settled and client_door.blocks() and (hd["door"] as Door).blocks(), "both doors end closed, colliders on")
		# A client toggles nothing by itself.
		assert_true(not cm.world_props.toggle_door("Gate_980"), "a client's WorldProps toggles nothing")
		assert_true(not cm.director.try_toggle_door(cm.roster.local_player_id), "a client's director toggles nothing")
		# The late-join path: the client's door states are wrong (as a peer that missed the events); the host's
		# bridge is set up again (detach + _wire_props), which resends every state it holds.
		cm.world_props.apply_state("Door_980", WorldProps.OPEN)
		cm.world_props.apply_state("Gate_980", WorldProps.CLOSED)
		assert_true(cm.world_props.states != hm.world_props.states, "nonvacuous: the client is wrong on both doors")
		hm.roster.bridge.setup(hm.director)
		await _tree().physics_frame
		var resent: bool = await h._wait_until(func() -> bool: return cm.world_props.states == hm.world_props.states, h.TIMEOUT_S)
		assert_true(resent, "the resend brought every door's state to the client")
		assert_true(not client_door.open and (cd["gate"] as Door).open, "the client's bodies follow")
		assert_eq(cm.world_props.state_of("Gate_980"), WorldProps.OPEN, "the gate is open again on the client")
	failures.append_array(h.failures)
	await h._teardown(p)
