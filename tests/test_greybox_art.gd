extends "res://tests/test_case.gd"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_map_materials_and_explicit_dusk_environment() -> void:
	var map: Node = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var cfg := GreyboxArt.config()
	assert_true(bool(cfg["_placeholder"]), "art values remain placeholders")
	for body in map.get_node("Nav").get_children():
		var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
		assert_true(mesh != null and mesh.material_override is StandardMaterial3D, "material on " + String(body.name))
		if mesh != null and mesh.material_override != null:
			assert_eq((mesh.material_override as StandardMaterial3D).shading_mode, BaseMaterial3D.SHADING_MODE_PER_PIXEL, "world is lit")
	map.free()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	# The serialized fallback is explicit too (before scripts have run).
	var world := match_scene.get_node("WorldEnvironment") as WorldEnvironment
	assert_true(world.environment.background_mode != Environment.BG_CLEAR_COLOR, "serialized explicit background")
	_tree().root.add_child(match_scene)
	assert_eq(world.environment.background_mode, Environment.BG_SKY, "procedural sky overrides magenta diagnostic")
	assert_true(world.environment.sky.sky_material is ProceduralSkyMaterial, "no sky asset dependency")
	assert_eq(world.environment.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR, "explicit colour fill")
	assert_true(world.environment.glow_enabled == bool(GraphicsPresets.new().get_preset()["art_glow_enabled"]) and world.environment.fog_enabled == bool(GraphicsPresets.new().get_preset()["art_fog_enabled"]), "cost toggles follow preset")
	assert_true(not world.environment.ssao_enabled and not world.environment.ssil_enabled and not world.environment.sdfgi_enabled
			and not world.environment.ssr_enabled and not world.environment.volumetric_fog_enabled, "no advanced renderer dependency")
	assert_eq((match_scene.get_node("Light") as DirectionalLight3D).shadow_enabled, bool(GraphicsPresets.new().get_preset()["art_shadows_enabled"]), "shadows follow preset")
	match_scene.free()


func _luminance(c: Color) -> float:
	var linear := c.srgb_to_linear()
	return linear.r * 0.2126 + linear.g * 0.7152 + linear.b * 0.0722


func _contrast(a: Color, b: Color) -> float:
	return (maxf(_luminance(a), _luminance(b)) + 0.05) / (minf(_luminance(a), _luminance(b)) + 0.05)


func test_pawn_materials_head_lock_and_albedo_readability_proxy() -> void:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	var body := pawn.get_node("Body") as MeshInstance3D
	var head := pawn.get_node("Head/HeadMesh") as MeshInstance3D
	assert_true(body.mesh is CapsuleMesh and head.mesh is SphereMesh, "placeholder silhouettes retained")
	assert_true(body.material_override != null and head.material_override != null, "material overrides retained")
	var head_mat := head.material_override as StandardMaterial3D
	assert_eq(head_mat.albedo_color, Color(1, 0.9, 0.2, 1), "Fold yellow gate exact")
	assert_eq(head_mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "head stays unshaded")
	var cfg := GreyboxArt.config()
	var ground := GreyboxArt.color_value(cfg["palette"]["ground"])
	var ratios := {}
	ratios["body_ground"] = _contrast((body.material_override as StandardMaterial3D).albedo_color, ground)
	ratios["head_ground"] = _contrast(head_mat.albedo_color, ground)
	for key in ["citadel", "inner_wall", "camp"]:
		ratios[key + "_ground"] = _contrast(GreyboxArt.color_value(cfg["palette"][key]), ground)
	for key in ratios:
		assert_true(float(ratios[key]) >= float(cfg["readability_proxy"]["minimum_albedo_contrast"]), key + " placeholder proxy floor")
	print("ART_ALBEDO_CONTRAST_PROXY ", ratios)
	pawn.free()


func test_hill_visual_tracks_dimensions_and_real_occupancy() -> void:
	var zone := HillZone.new()
	_tree().root.add_child(zone)
	var base := Vector3(0, 50, 0)
	zone.configure(base, 4.0, 3.0)
	var mesh := zone.visual.mesh as CylinderMesh
	assert_eq(mesh.top_radius, 4.0, "visual radius")
	assert_eq(mesh.bottom_radius, 4.0, "visual bottom radius")
	assert_eq(mesh.height, 3.0, "visual height")
	assert_eq(zone.position, base + Vector3(0, 1.5, 0), "base centre contract")
	assert_eq(zone.collision_layer, 0, "visual adds no collision layer")
	assert_eq(zone.collision_mask, 2, "occupancy mask unchanged")
	assert_eq(zone.visual.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadow")
	var pawns: Array[Pawn] = []
	for squad in 2:
		var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
		pawn.squad_id = squad
		_tree().root.add_child(pawn)
		pawn.set_physics_process(false)
		pawn.position = base + Vector3(squad * 10, 0, 0)
		pawns.append(pawn)
	await _settle()
	assert_eq(zone.occupancy(), {0: 1}, "one squad held")
	assert_eq(zone._visual_state, "held", "held colour")
	pawns[1].position = base + Vector3(1, 0, 0)
	await _settle()
	assert_eq(zone.occupancy(), {0: 1, 1: 1}, "two squads contested")
	assert_eq(zone._visual_state, "contested", "contested colour")
	assert_eq((zone.visual.material_override as StandardMaterial3D).albedo_color,
			GreyboxArt.color_value(GreyboxArt.config()["hill"]["contested"]), "colour from data")
	for pawn in pawns:
		pawn.bridge.state.health = 0.0
		pawn.bridge.state.shield = 0.0
	await _settle()
	assert_true(zone.occupancy().is_empty(), "dead pawns excluded")
	assert_eq(zone._visual_state, "empty", "empty colour")
	zone.configure(base, 6.0, 2.0)
	assert_eq(mesh.top_radius, 6.0, "reconfigure radius")
	assert_eq(mesh.height, 2.0, "reconfigure height")
	for pawn in pawns:
		pawn.free()
	zone.free()


func _settle() -> void:
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	await _tree().process_frame
