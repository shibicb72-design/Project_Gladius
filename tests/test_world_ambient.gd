extends "res://tests/test_case.gd"

func _tree() -> SceneTree:
	return Engine.get_main_loop()

func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/art_world.json")

func test_ambient_counts_shader_parameters_and_off_toggle() -> void:
	var cfg := _cfg()
	var ambient := WorldAmbient.new()
	_tree().root.add_child(ambient)
	ambient.configure(cfg, true)
	assert_true(ambient.visible and ambient.is_processing(), "enabled driver and visibility")
	assert_eq(ambient.find_children("Banner*", "Node3D", true, false).size(), cfg["flags"]["positions"].size(), "flag count")
	assert_eq(ambient.find_children("Tent*", "Node3D", true, false).size(), cfg["tents"]["positions"].size(), "tent count")
	assert_eq(ambient.lights.size(), cfg["braziers"]["positions"].size(), "brazier lights")
	assert_eq(ambient.beacons.size(), cfg["beacons"]["positions"].size(), "searchlight count")
	assert_eq(ambient.particles.size(), cfg["dust"]["positions"].size(), "dust emitters")
	assert_eq((ambient.get_node("Foliage") as MultiMeshInstance3D).multimesh.instance_count, int(cfg["foliage"]["count"]), "tuft count")
	for dust in ambient.particles:
		assert_eq(dust.amount, int(cfg["dust"]["amount"]), "dust count from data")
		assert_true(dust.emitting and not dust.one_shot, "continuous ambient dust")
	for pair in [[ambient.cloth_material, cfg["cloth"]], [ambient.foliage_material, cfg["foliage"]]]:
		var mat: ShaderMaterial = pair[0]
		var section: Dictionary = pair[1]
		assert_eq(mat.get_shader_parameter("amplitude"), float(section["amplitude_m"]), "sway amplitude data")
		assert_eq(mat.get_shader_parameter("speed"), float(section["speed"]), "sway speed data")
		assert_eq(mat.get_shader_parameter("frequency"), float(section["frequency"]), "sway frequency data")
		assert_eq(mat.get_shader_parameter("base_color"), GreyboxArt.color_value(section["color"]), "sway color data")
	assert_true(ambient.find_children("*", "CollisionObject3D", true, false).is_empty(), "no ambient colliders")
	ambient.configure(cfg, false)
	assert_true(not ambient.visible and not ambient.is_processing(), "off disables driver/visibility")
	assert_eq(ambient.get_child_count(), 0, "off leaves no emitters or lights processing")
	assert_eq(ambient.cloth_material.get_shader_parameter("amplitude"), 0.0, "cloth off")
	assert_eq(ambient.foliage_material.get_shader_parameter("amplitude"), 0.0, "foliage off")
	await _tree().process_frame
	ambient.configure(cfg, true)
	assert_eq(ambient.particles.size(), cfg["dust"]["positions"].size(), "toggle restores exactly one set")
	ambient.queue_free()
	await _tree().process_frame

func test_ambient_motion_never_changes_world_colliders() -> void:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var ambient := map.get_node("ArtBuilder/Ambient") as WorldAmbient
	assert_true(bool(GraphicsPresets.new().get_preset()["art_ambient_enabled"]), "default ambient on")
	var bodies: Array[Node] = map.get_node("Nav").get_children()
	var transforms: Array[Transform3D] = []
	for body: Node3D in bodies:
		transforms.append(body.transform)
	var initial_energy := ambient.lights[0].light_energy
	var initial_angle := ambient.beacons[0].rotation.y
	for frame in 60:
		await _tree().process_frame
		for i in bodies.size():
			assert_eq(bodies[i].transform, transforms[i], "collider immobile during ambient animation")
	assert_true(ambient.elapsed > 0, "single driver advanced")
	assert_true(not is_equal_approx(ambient.lights[0].light_energy, initial_energy), "brazier energy noise advanced")
	assert_true(not is_equal_approx(ambient.beacons[0].rotation.y, initial_angle), "searchlight sweep advanced")
	assert_true(map.get_node("Nav").get_child_count() == transforms.size(), "no collider growth")
	print("WORLD_AMBIENT flags=", _cfg()["flags"]["positions"].size(), " tents=", _cfg()["tents"]["positions"].size(), " tufts=", _cfg()["foliage"]["count"], " dust_emitters=", ambient.particles.size(), " particles_each=", _cfg()["dust"]["amount"], " lights=", ambient.lights.size(), " beacons=", ambient.beacons.size())
	map.queue_free()
	await _tree().process_frame

func test_ambient_custom_configuration_is_not_a_baked_count() -> void:
	var cfg := _cfg().duplicate(true)
	cfg["foliage"]["count"] = 7
	cfg["flags"]["positions"] = [[18, 0, 18]]
	cfg["dust"]["amount"] = 17
	cfg["cloth"]["amplitude_m"] = 0.31
	var ambient := WorldAmbient.new()
	_tree().root.add_child(ambient)
	ambient.configure(cfg, true)
	assert_eq((ambient.get_node("Foliage") as MultiMeshInstance3D).multimesh.instance_count, 7, "custom count")
	assert_eq(ambient.find_children("Banner*", "Node3D", true, false).size(), 1, "custom flag positions")
	assert_eq(ambient.particles[0].amount, 17, "custom dust count")
	assert_eq(ambient.cloth_material.get_shader_parameter("amplitude"), 0.31, "custom amplitude")
	ambient.queue_free()
	await _tree().process_frame
