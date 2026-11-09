extends "res://tests/test_case.gd"
## C3 (decision D2, Shibi, Nov 9 2026): a colour per squad through one shared material and a per-instance
## shader value. What a headless run can prove is here; that the Mobile renderer draws the value is a windowed
## check (the squad shots in the build report).


func _spawn(tree: SceneTree, squad: int) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.squad_id = squad
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func _armor(pawn: Pawn) -> MeshInstance3D:
	return (pawn.get_node("SoldierModel") as SoldierModel).armor


func _as_vector(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


func test_two_squads_differ_per_instance_and_share_one_material() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var first := _spawn(tree, 0)
	var second := _spawn(tree, 1)
	var mate := _spawn(tree, 1)
	var armors: Array[MeshInstance3D] = [_armor(first), _armor(second), _armor(mate)]
	var shared := SoldierSquadColour.material()
	for armor in armors:
		assert_true(armor.mesh == armors[0].mesh and armor.mesh.get_surface_count() == 1, "one shared mesh, one surface")
		assert_true(armor.mesh.surface_get_material(0) == shared, "every soldier draws with the one material resource")
		assert_true(armor.material_override == null and armor.get_surface_override_material(0) == null, "no per-soldier material")
	assert_true(shared.shader.get_code().contains("instance uniform vec3 " + String(SoldierSquadColour.PARAM)), "the squad colour is an instance uniform")
	var shown: Array = [SoldierSquadColour.shown(armors[0]), SoldierSquadColour.shown(armors[1]), SoldierSquadColour.shown(armors[2])]
	assert_eq(shown[0], _as_vector(SoldierSquadColour.paint(0)), "squad 0 shows palette colour 0")
	assert_eq(shown[1], _as_vector(SoldierSquadColour.paint(1)), "squad 1 shows palette colour 1")
	assert_true(shown[0] != shown[1], "two squads give different per-instance colours")
	assert_eq(shown[1], shown[2], "squad mates share a colour")
	print("SQUAD_COLOUR squad0=", shown[0], " squad1=", shown[1], " material_rid_shared=", armors[0].mesh.surface_get_material(0).get_rid() == armors[1].mesh.surface_get_material(0).get_rid())
	first.free()
	second.free()
	mate.free()


func test_colour_follows_a_squad_change_that_has_no_signal() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn := _spawn(tree, 0)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	assert_eq(model.shown_squad, 0, "starts on the pawn's squad")
	pawn.set_squad(4)  # what MatchDirector.start does
	await tree.process_frame
	await tree.process_frame
	assert_eq(model.shown_squad, 4, "the model's own process step saw the change")
	assert_eq(SoldierSquadColour.shown(model.armor), _as_vector(SoldierSquadColour.paint(4)), "armor shows the new squad's colour")
	# A hidden pawn still takes the change, so it is right the moment it shows again.
	pawn.visible = false
	pawn.set_squad(2)
	await tree.process_frame
	await tree.process_frame
	assert_eq(SoldierSquadColour.shown(model.armor), _as_vector(SoldierSquadColour.paint(2)), "hidden pawn updated too")
	pawn.free()


func test_corpse_keeps_the_squad_colour_and_the_shared_material() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn := _spawn(tree, 3)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	await tree.process_frame
	var corpse := model.make_corpse()
	tree.root.add_child(corpse)
	var armor := corpse.get_node("Skeleton3D/Armor") as MeshInstance3D
	assert_eq(SoldierSquadColour.shown(armor), _as_vector(SoldierSquadColour.paint(3)), "corpse shows its squad's colour")
	assert_true(armor.mesh.surface_get_material(0) == SoldierSquadColour.material() and armor.material_override == null, "corpse uses the shared material")
	pawn.set_squad(5)
	await tree.process_frame
	await tree.process_frame
	assert_eq(SoldierSquadColour.shown(armor), _as_vector(SoldierSquadColour.paint(3)), "a later squad change does not repaint the corpse")
	corpse.free()
	pawn.free()


func test_palette_is_placeholder_data_and_the_mesh_marks_squad_fields() -> void:
	var cfg := SoldierSquadColour.config()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-3D-SQUAD-COLOUR"), "palette is a placeholder with an OQ id")
	var palette: Array = cfg["palette"]
	assert_eq(palette.size(), 18, "one colour per solo player")
	var seen := {}
	for entry: Array in palette:
		seen[GreyboxArt.color_value(entry)] = true
	assert_eq(seen.size(), palette.size(), "no colour twice")
	assert_eq(SoldierSquadColour.paint(palette.size() + 1), SoldierSquadColour.paint(1), "ids past the palette wrap around")
	assert_eq(SoldierSquadColour.paint(-1), GreyboxArt.color_value(cfg["no_squad"]), "a negative id is no squad")
	# Squad fields are the faces whose vertex alpha is 0; the mesh needs both kinds.
	var tree: SceneTree = Engine.get_main_loop()
	var pawn := _spawn(tree, 0)
	var colors: PackedColorArray = _armor(pawn).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var fields := 0
	for c in colors:
		assert_true(c.a == 0.0 or c.a == 1.0, "vertex alpha is a mask: 0 or 1")
		if c.a == 0.0:
			fields += 1
	assert_true(fields > 0 and fields < colors.size(), "some faces are squad fields, most are not: %d of %d vertices" % [fields, colors.size()])
	print("SQUAD_COLOUR field_vertices=", fields, " of ", colors.size())
	pawn.free()
