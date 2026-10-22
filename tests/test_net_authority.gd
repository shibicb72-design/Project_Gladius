extends "res://tests/test_case.gd"
## Host-side authority checks: ammo/reload, vertical movement, and the single squad-count key.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const PEER := 77
const PID := 5


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _validator() -> NetValidator:
	return NetValidator.new(DataRegistry.new().load_file("res://data/net.json")["validation"])


## Returns {root, bridge, pawn}; one remote human (peer PEER -> player PID) on a host bridge with no network.
func _host_rig() -> Dictionary:
	var root := Node.new()
	_tree().root.add_child(root)
	var director := MatchDirector.new()
	root.add_child(director)
	var bridge := NetMatchBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	bridge.set_physics_process(false)
	bridge.setup(director)
	var pawn: Pawn = _PawnScene.instantiate()
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = Vector3(0, 0.1, 0)
	director.add_player(PID, pawn)
	bridge.register_peer(PEER, PID)
	return {"root": root, "bridge": bridge, "pawn": pawn}


func _fire(bridge: NetMatchBridge, pawn: Pawn) -> Dictionary:
	return bridge.host_handle_fire(PEER, pawn.get_muzzle_position(), Vector3(0, 0, -1),
			pawn.loadout.get_active().def.id)


func test_host_rejects_fire_when_magazine_empty() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var pawn: Pawn = rig["pawn"]
	var w := pawn.loadout.get_active()
	w.ammo_in_mag = 0
	assert_eq(_fire(bridge, pawn)["reason"], "empty", "empty magazine rejected")
	w.ammo_in_mag = 2
	assert_true(_fire(bridge, pawn)["ok"], "shot with ammo accepted")
	assert_eq(w.ammo_in_mag, 1, "accepted shot consumes one round on the host")
	rig["root"].queue_free()


func test_host_rejects_fire_while_reloading() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var pawn: Pawn = rig["pawn"]
	var w := pawn.loadout.get_active()
	w.ammo_in_mag = 1
	assert_true(bridge.host_handle_reload(PEER), "host starts the requested reload")
	assert_eq(_fire(bridge, pawn)["reason"], "reloading", "fire during reload rejected")
	assert_eq(w.ammo_in_mag, 1, "rejected shot keeps ammo")
	rig["root"].queue_free()


func test_host_reload_request_refills_after_reload_time() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var pawn: Pawn = rig["pawn"]
	var w := pawn.loadout.get_active()
	w.ammo_in_mag = 0
	assert_true(bridge.host_handle_reload(PEER), "reload started")
	bridge._clock += w.def.reload_s + 0.1
	var r := _fire(bridge, pawn)
	assert_true(r["ok"], "fire accepted once the reload time passed")
	assert_eq(w.ammo_in_mag, w.def.magazine - 1, "magazine refilled, then one round used")
	rig["root"].queue_free()


func test_validate_move_rejects_vertical_teleport() -> void:
	var v := _validator()
	assert_true(not v.validate_move(Vector3.ZERO, Vector3(0, 50, 0), 0.1, 5.0, 7.0, 0.785), "fly up rejected")
	assert_true(not v.validate_move(Vector3.ZERO, Vector3(0, -200, 0), 0.1, 5.0, 7.0, 0.785), "drop rejected")
	assert_true(not v.validate_move(Vector3.ZERO, Vector3(0, INF, 0), 0.1, 5.0, 7.0, 0.785), "non-finite rejected")


func test_validate_move_allows_jump_and_fall() -> void:
	var v := _validator()
	assert_true(v.validate_move(Vector3.ZERO, Vector3(0, 0.7, 0), 0.1, 5.0, 7.0, 0.785), "jump rise ok")
	assert_true(v.validate_move(Vector3.ZERO, Vector3(0, -5.0, 0), 0.1, 5.0, 7.0, 0.785), "fast fall ok")
	assert_true(v.validate_move(Vector3.ZERO, Vector3(0.3, 0.0, 0), 0.1, 5.0, 7.0, 0.785), "flat walk ok")


func test_rejected_move_keeps_host_position_and_does_not_age_in() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var pawn: Pawn = rig["pawn"]
	var start := pawn.global_position
	var far := start + Vector3(8, 0, 0)
	for i in 100:
		bridge._clock += 0.033
		assert_true(not bridge.host_handle_move(PEER, far, 0.0), "far position rejected at step %d" % i)
	assert_eq(pawn.global_position, start, "host position stays authoritative")
	assert_eq(bridge._last_move_s[PID], bridge._clock, "rejection refreshes the move clock")
	bridge._clock += 0.033
	assert_true(bridge.host_handle_move(PEER, start + Vector3(0.1, 0, 0), 0.0), "plausible move still accepted")
	rig["root"].queue_free()


func test_squad_count_single_source() -> void:
	var reg := DataRegistry.new()
	var squads := int(reg.load_file("res://data/match.json").get("squads", 0))
	assert_true(squads > 0, "match.json squads set")
	assert_true(not reg.load_file("res://data/match.json").has("offline_squads"), "offline_squads removed")
	assert_true(not reg.load_file("res://data/bots.json")["match_fill"].has("squads"), "bots.json has no squads")
	var seen := {}
	for e in BotSpawner.plan_fill({}, reg.load_file("res://data/bots.json")):
		seen[e["squad"]] = true
	assert_eq(seen.size(), squads, "bot fill covers exactly match.json squads")
	var src := FileAccess.get_file_as_string("res://scripts/ui/lobby.gd")
	assert_true(src.contains('cfg.get("squads"'), "lobby reads match.json squads")
	assert_eq(DataRegistry.validate_squads(reg.load_file("res://data/match.json"),
			reg.load_file(DataRegistry.MAP_PATH)).size(), 0, "shipped data is consistent")


func test_validate_rejects_more_squads_than_spawns() -> void:
	var map_def := {"spawns": {"a": [0, 0, 0], "b": [1, 0, 0]}}
	var ok := DataRegistry.validate_squads({"squads": 2, "squad_size": 3, "max_players": 18}, map_def)
	assert_eq(ok.size(), 0, "2 squads on 2 spots is fine")
	var few := DataRegistry.validate_squads({"squads": 3, "squad_size": 3, "max_players": 18}, map_def)
	assert_true(few.size() > 0, "more squads than spawn spots reported")
	var many := DataRegistry.validate_squads({"squads": 7, "squad_size": 3, "max_players": 18},
			{"spawns": {"a": 0, "b": 0, "c": 0, "d": 0, "e": 0, "f": 0, "g": 0}})
	assert_true(many.size() > 0, "squads * squad_size above max_players reported")
