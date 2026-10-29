extends "res://tests/test_case.gd"

func _corpses(parent: Node) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in parent.get_children():
		if child.has_meta("corpse"):
			found.append(child)
	return found

func test_death_adds_one_visible_corpse_and_respawn_adds_none() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var match_parent := Node3D.new()
	tree.root.add_child(match_parent)
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	match_parent.add_child(pawn)
	pawn.set_physics_process(false)
	assert_eq(_corpses(match_parent).size(), 0, "no corpse on setup")
	pawn.bridge.state.health = 0
	pawn.bridge.state.shield = 0
	pawn.set_active(false)
	var corpses := _corpses(match_parent)
	assert_eq(corpses.size(), 1, "one corpse on death")
	if corpses.size() == 1:
		var corpse := corpses[0]
		assert_true(corpse.get_parent() == match_parent and corpse.is_visible_in_tree(), "corpse visible outside hidden pawn")
		assert_eq(corpse.global_transform, pawn.global_transform, "starts at pawn transform")
		assert_true(corpse.get_script() == null, "no sway or gameplay script on corpse")
		for child in corpse.get_children():
			assert_true(child is MeshInstance3D, "corpse has no collider")
		pawn.set_active(false)
		assert_eq(_corpses(match_parent).size(), 1, "repeated hide adds none")
		pawn.set_active(true)
		pawn.set_physics_process(false)
		assert_eq(_corpses(match_parent).size(), 1, "respawn adds none")
		await tree.create_timer(float(LowpolyKit.config()["death"]["topple_s"]) + 0.1).timeout
		assert_true(absf(corpse.rotation_degrees.x) > 45.0, "toppled presentation")
		await tree.create_timer(float(LowpolyKit.config()["death"]["lifetime_s"])).timeout
		assert_true(not is_instance_valid(corpse), "corpse lifetime releases node")
		assert_eq(_corpses(match_parent).size(), 0, "no lingering corpse")
	match_parent.free()

func test_own_death_label_tracks_respawn_without_kill_banner() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var holder := Node3D.new()
	tree.root.add_child(holder)
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	holder.add_child(pawn)
	pawn.set_physics_process(false)
	var hud := GameHud.new()
	tree.root.add_child(hud)
	hud.pawn = pawn
	hud.refresh_pawn()
	assert_true(not hud.own_death_label.visible, "living label hidden")
	pawn.bridge.state.health = 0
	pawn.bridge.state.shield = 0
	pawn.set_active(false)
	hud.refresh_pawn()
	assert_true(hud.own_death_label.visible and hud.respawn_label.visible, "dead labels shown together")
	assert_eq(hud.own_death_label.text, "YOU WERE HIT", "placeholder copy from data")
	assert_true(not hud.banner_label.visible, "kill/objective banner remains separate")
	pawn.respawn_at(Transform3D.IDENTITY)
	pawn.set_physics_process(false)
	hud.refresh_pawn()
	assert_true(not hud.own_death_label.visible and not hud.respawn_label.visible, "respawn hides both")
	hud.free()
	holder.free()
