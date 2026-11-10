extends "res://tests/test_case.gd"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_map_materials_and_explicit_dusk_environment() -> void:
	var map: Node = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	var cfg := GreyboxArt.config()
	assert_true(bool(cfg["_placeholder"]), "art values remain placeholders")
	for body in map.get_node("Nav").get_children():
		if body.is_in_group(WorldKit.GROUP) or body.is_in_group(&"ring_cover"):
			continue  # W1, W3: kit pieces and ring cover hold colliders only; their look is the batches checked below
		# S2: the world's material is the textured surface shader (or a per-pixel StandardMaterial3D); either
		# way it must take light (WorldSurface.is_lit), which is what this check has always been about.
		var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
		assert_true(mesh != null and mesh.material_override != null, "material on " + String(body.name))
		if mesh != null and mesh.material_override != null:
			assert_true(WorldSurface.is_lit(mesh.material_override), "world is lit: " + String(body.name))
	var batches := map.get_node("ArtBuilder/Structures").get_children()
	assert_true(not batches.is_empty(), "world kit batches present")
	for batch: MultiMeshInstance3D in batches:
		var material := batch.multimesh.mesh.surface_get_material(0)
		assert_true(material != null and batch.material_override == null, "material on " + String(batch.name))
		assert_true(WorldSurface.is_lit(material), "world kit is lit")
	var ring_batches := map.get_node("ArtBuilder/RingCover").get_children()
	assert_true(not ring_batches.is_empty(), "ring cover batches present")
	for batch: MultiMeshInstance3D in ring_batches:
		assert_true(WorldSurface.is_lit(batch.material_override), "lit material on " + String(batch.name))
	var unlit := StandardMaterial3D.new()
	unlit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	assert_true(not WorldSurface.is_lit(unlit) and not WorldSurface.is_lit(null), "the lit check tells an unshaded material apart")
	var flat_shader := ShaderMaterial.new()
	flat_shader.shader = load("res://scripts/visual/shaders/sun_shaft.gdshader")
	assert_true(not WorldSurface.is_lit(flat_shader), "the lit check tells an unshaded shader apart")
	map.free()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	# The serialized fallback is explicit too (before scripts have run).
	var world := match_scene.get_node("WorldEnvironment") as WorldEnvironment
	assert_true(world.environment.background_mode != Environment.BG_CLEAR_COLOR, "serialized explicit background")
	_tree().root.add_child(match_scene)
	assert_eq(world.environment.background_mode, Environment.BG_SKY, "procedural sky overrides magenta diagnostic")
	# S1: the sky is the project's own sky shader fed by data and one generated noise tile (was a
	# ProceduralSkyMaterial): still no sky image and no third-party asset.
	var sky_material := world.environment.sky.sky_material as ShaderMaterial
	assert_true(sky_material != null and sky_material.shader.resource_path == "res://scripts/visual/shaders/sky_astra.gdshader", "the sky is the in-engine sky shader")
	if sky_material != null:
		var noise := sky_material.get_shader_parameter("noise_pack") as Texture2D
		assert_true(noise != null and noise.resource_path.begins_with("res://assets/generated/"), "its only texture is generated in the project: no sky asset dependency")
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
	# D1 (Shibi, Nov 9 2026): the yellow sphere is a debug overlay, hidden by default. It keeps the exact
	# colour the Fold detector looks for, for the builds that turn it on.
	assert_true(not head.visible, "yellow head sphere hidden by default")
	var head_mat := head.material_override as StandardMaterial3D
	assert_eq(head_mat.albedo_color, Color(1, 0.9, 0.2, 1), "Fold yellow gate exact")
	assert_eq(head_mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "head stays unshaded")
	var cfg := GreyboxArt.config()
	var ground := GreyboxArt.color_value(cfg["palette"]["ground"])
	var ratios := {}
	ratios["body_ground"] = _contrast((body.material_override as StandardMaterial3D).albedo_color, ground)
	# Was "head_ground" with the yellow sphere: the head a player now sees is the helmet's plate colour.
	var shell_color := ""
	for part: Dictionary in LowpolyKit.config()["soldier"]["parts"]:
		if part["name"] == LowpolyKit.config()["soldier"]["helmet"]["shell_part"]:
			shell_color = part["color"]
	ratios["helmet_ground"] = _contrast(GreyboxArt.color_value(LowpolyKit.config()["colors"][shell_color]), ground)
	for key in ["citadel", "inner_wall", "camp"]:
		ratios[key + "_ground"] = _contrast(GreyboxArt.color_value(cfg["palette"][key]), ground)
	for key in ratios:
		assert_true(float(ratios[key]) >= float(cfg["readability_proxy"]["minimum_albedo_contrast"]), key + " placeholder proxy floor")
	print("ART_ALBEDO_CONTRAST_PROXY ", ratios)
	pawn.free()




func _settle() -> void:
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	await _tree().process_frame
