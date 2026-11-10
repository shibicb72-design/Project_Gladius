extends "res://tests/test_case.gd"
## S6: the loot models (scripts/visual/loot_look.gd) and the carrier model (scripts/visual/carrier_look.gd).
## Both only read gameplay objects: the loot field's items and the director's carrier line.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_loot_batches_mirror_the_loot_field_without_changing_it() -> void:
	var cfg := LootLook.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-GFX-LOOT"), "loot look numbers are placeholders with an OQ id")
	var loot_cfg: Dictionary = DataRegistry.new().load_file("res://data/loot.json")
	for item_id: String in loot_cfg["items"]:
		assert_true(LootLook.model_mesh(item_id) != null, "every loot item has a model: " + item_id)
	var holder := Node3D.new()
	_tree().root.add_child(holder)
	var loot := LootField.new()
	loot.setup(loot_cfg, 1)
	loot.placed = true
	holder.add_child(loot)
	var ids: Array[int] = []
	for i in 5:
		ids.append(loot.drop({"item_id": "ammo"}, Vector3(i * 2.0, 0, 0)))
	ids.append(loot.drop({"item_id": "armor_2"}, Vector3(0, 0, 4)))
	var items_before := loot.items.duplicate(true)
	var look := LootLook.new()
	holder.add_child(look)
	look.bind(loot)
	await _tree().process_frame
	assert_eq(look.shown, 6, "six items are drawn")
	assert_true(look.batches.has("ammo") and look.batches.has("armor_2") and look.batches.size() == 2, "one batch per item id present")
	assert_eq((look.batches["ammo"] as MultiMeshInstance3D).multimesh.instance_count, 5, "five ammo boxes in the ammo batch")
	assert_eq(look.glow.multimesh.instance_count, 6, "one glow per item, in one batch")
	for id in ids:
		assert_true(not (loot.items[id]["node"] as Node3D).visible, "the loot field's plain box is hidden behind the model")
		assert_eq(loot.items[id]["pos"], items_before[id]["pos"], "the item itself is untouched")
	assert_eq(loot.items.size(), items_before.size(), "no item added or removed by the look")
	# Taking an item updates the batches on the next frame.
	loot.take(ids[0])
	await _tree().process_frame
	await _tree().process_frame
	assert_eq(look.shown, 5, "a taken item leaves the batches")
	assert_eq((look.batches["ammo"] as MultiMeshInstance3D).multimesh.instance_count, 4, "four ammo boxes remain")
	loot.take(ids[5])
	await _tree().process_frame
	await _tree().process_frame
	assert_true(not look.batches.has("armor_2"), "an item id with nothing left has no batch")
	holder.free()


func test_carrier_model_follows_the_directors_carrier_line() -> void:
	var cfg := CarrierLook.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-GFX-CARRIER"), "carrier look numbers are placeholders with an OQ id")
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = false
	match_scene.drop_from_sky = true
	_tree().root.add_child(match_scene)
	var look := match_scene.get_node_or_null("WorldEnvironment/CarrierLook") as CarrierLook
	assert_true(look != null and look.model != null and not look.model.visible, "the carrier model exists and is hidden before a drop")
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "the match starts")
	await _tree().process_frame
	await _tree().process_frame
	var director := match_scene.director
	if director.drop_active:
		assert_true(look.model.visible, "the model shows while the drop is active")
		var offset := LowpolyKit.vec(cfg["offset_m"])
		assert_true(look.model.global_position.distance_to(director.carrier_position()) < offset.length() + float(cfg["bob_m"]) + 0.5, "it rides at the carrier position (plus its offset)")
		var heading := (director.carrier_to - director.carrier_from).normalized()
		assert_true((-look.model.global_transform.basis.z).dot(heading) > 0.95, "its nose points along the carrier line")
		var colliders := 0
		for child in look.get_children():
			if child is CollisionObject3D:
				colliders += 1
		assert_eq(colliders, 0, "the carrier model has no collider")
	else:
		assert_true(false, "the mode config has no drop to test with")
	match_scene.free()
