extends "res://tests/test_case.gd"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_roster_local_set_is_independent_of_class_and_bots_stay_legionary() -> void:
	var previous := AppFlow.profile
	AppFlow.profile = {"armour_set": "murmillo"}
	var stage := Node3D.new()
	_tree().root.add_child(stage)
	var director := MatchDirector.new()
	director.load_config()
	var roster := MatchRoster.new()
	var slots := [
		{"player_id": 0, "peer_id": 21, "squad_id": 0, "is_bot": false, "class_id": "hastati"},
		{"player_id": 1, "peer_id": 22, "squad_id": 1, "is_bot": false, "class_id": "hastati"},
		{"player_id": 2, "peer_id": 0, "squad_id": 2, "is_bot": true, "class_id": "hastati"},
	]
	roster.build(stage, director, slots, 22, false, true, true)
	assert_eq(roster.local_pawn.class_id, "hastati", "selection is independent of class")
	var local := roster.local_pawn.get_node("SoldierModel") as SoldierModel
	assert_eq(local.armor.mesh.resource_name, "GladiatorNear", "LAN local human has the profile set")
	var remote := director.player(0).get_node("SoldierModel") as SoldierModel
	assert_eq(remote.armor.mesh.resource_name, "SoldierNear", "LAN remote human appears Legionary")
	var lobby_bot := roster.bots[0].get_node("SoldierModel") as SoldierModel
	assert_true(lobby_bot.armor.mesh == remote.armor.mesh, "lobby bot appears Legionary")
	var standalone := BotSpawner.spawn_bots(stage, director, {0: 1}, 100, false)
	assert_true(not standalone.is_empty(), "standalone spawn path added bots")
	for bot in standalone:
		var bot_model := bot.get_node("SoldierModel") as SoldierModel
		assert_true(bot_model.armor.mesh == remote.armor.mesh, "standalone bot with no metadata appears Legionary")
	stage.free()
	director.free()
	AppFlow.profile = previous
