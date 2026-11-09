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


func test_rejected_move_corrections_are_rate_limited() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var far: Vector3 = (rig["pawn"] as Pawn).global_position + Vector3(8, 0, 0)
	bridge._clock += 0.033
	assert_true(not bridge.host_handle_move(PEER, far, 0.0), "first move rejected")
	var first: float = bridge._last_correction_s[PID]
	assert_eq(first, bridge._clock, "correction time recorded")
	bridge._clock += 0.033
	assert_true(not bridge.host_handle_move(PEER, far, 0.0), "second move rejected")
	assert_eq(bridge._last_correction_s[PID], first, "second correction suppressed inside the interval")
	bridge._clock = first + bridge.snapshot_interval_s
	assert_true(not bridge.host_handle_move(PEER, far, 0.0), "third move rejected")
	assert_eq(bridge._last_correction_s[PID], bridge._clock, "correction allowed after one snapshot interval")
	rig["root"].queue_free()


func test_remote_fire_ends_spawn_protection_only_when_accepted() -> void:
	var rig := _host_rig()
	var bridge: NetMatchBridge = rig["bridge"]
	var pawn: Pawn = rig["pawn"]
	# Spawn protection is gone in battle royale (spawn_protected stays false); empty vs accepted shots only.
	var w := pawn.loadout.get_active()
	w.ammo_in_mag = 0
	assert_eq(_fire(bridge, pawn)["reason"], "empty", "empty shot rejected")
	assert_true(not pawn.bridge.spawn_protected, "never protected")
	w.ammo_in_mag = 2
	assert_true(_fire(bridge, pawn)["ok"], "shot with ammo accepted")
	rig["root"].queue_free()


func test_squad_count_single_source() -> void:
	var reg := DataRegistry.new()
	# Battle royale (DESIGN.md, Nov 9 2026) supersedes OQ-30: squad layout comes from br.json teams.
	var match_cfg := reg.load_file("res://data/match.json")
	assert_true(not match_cfg.has("squads"), "match.json has no squads key")
	var br := ModeRegistry.merged_config("br", reg.load_file("res://data/modes.json"))
	var layout := MatchDirector.team_layout(br, match_cfg)
	var seen := {}
	for e in BotSpawner.plan_fill({}, reg.load_file("res://data/bots.json"), int(layout["squad_count"]), int(layout["squad_size"])):
		seen[e["squad"]] = true
	assert_eq(seen.size(), int(layout["squad_count"]), "bot fill covers every squad of the layout")
	var src := FileAccess.get_file_as_string("res://scripts/ui/lobby.gd")
	assert_true(src.contains("MatchDirector.team_layout"), "lobby derives squads from the team mode")
	assert_eq(DataRegistry.validate_squads(reg.load_file("res://data/match.json"),
			reg.load_file(DataRegistry.MAP_PATH)).size(), 0, "shipped data is consistent")


func test_validate_player_caps_and_spawns() -> void:
	var map_def := {"spawns": {"a": [0, 0, 0], "b": [1, 0, 0]}}
	var ok := DataRegistry.validate_squads({"max_players": 18, "min_humans": 1, "max_humans": 8}, map_def)
	assert_eq(ok.size(), 0, "valid caps; fewer spots than squads is fine (shared spots)")
	var bad := DataRegistry.validate_squads({"max_players": 18, "min_humans": 1, "max_humans": 20}, map_def)
	assert_true(bad.size() > 0, "max_humans above max_players reported")
	var none := DataRegistry.validate_squads({"max_players": 18, "min_humans": 1, "max_humans": 8}, {"spawns": {}})
	assert_true(none.size() > 0, "map without spawn spots reported")
