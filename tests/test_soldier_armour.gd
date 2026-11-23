extends "res://tests/test_case.gd"

const Budget := preload("res://tests/test_soldier_budget.gd")
const LEGIONARY_HASH := "90bf11207ca4689484cc8c221250b47a669c7fda7b65bd3ab6375cd5419466d4"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _model(set_id: String = "") -> SoldierModel:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	if set_id != "":
		pawn.set_meta("armour_set", set_id)
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn.get_node("SoldierModel") as SoldierModel


func test_default_material_and_asset_survive_switching_sets() -> void:
	var legacy_path := SoldierRig.mesh_source()
	assert_eq(SoldierRig.armour_sets()["legionary"]["glb"], legacy_path, "the catalog names the legacy source")
	assert_eq(FileAccess.get_sha256(legacy_path), LEGIONARY_HASH, "the Legionary asset matches the launch base")
	var before := _model()
	var original_mesh := before.armor.mesh
	var original_material := SoldierSquadColour.material()
	var original_shader := original_material.shader
	var original_surfaces: Variant = original_material.get_shader_parameter("surf_a")
	var new_set := _model("murmillo")
	var after := _model()
	assert_true(after.armor.mesh == original_mesh and after.armor.mesh == SoldierRig.mesh, "the default cache entry is reused")
	assert_true(before.armor.mesh != new_set.armor.mesh, "Murmillo uses its own cache entry")
	assert_true(after.armor.mesh.surface_get_material(0) == original_material, "Legionary keeps its shared material object")
	assert_true(original_material.shader == original_shader, "Legionary keeps its shader")
	assert_eq(original_material.get_shader_parameter("surf_a"), original_surfaces, "loading Murmillo preserves the material parameters")
	for model in [before, new_set, after]:
		model.get_parent().free()


func test_textured_lods_have_skin_atlases_and_mask_fields_within_budget() -> void:
	var model := _model("murmillo")
	var look: Dictionary = SoldierRig.armour_sets()["murmillo"]
	var budgets: Dictionary = SoldierLook.config()["set_budgets"][look["budgets"]]
	var far_m := float(SoldierLook.config()["gun"]["far_m"])
	for lod: String in ["near", "far"]:
		var instance := model.armor if lod == "near" else model.armor_far
		var body := instance.mesh as ArrayMesh
		var weapon := model.rifle if lod == "near" else model.rifle_far
		var triangles := 0
		var painted := Vector3i.ZERO
		var atlas := body.surface_get_material(0) as ShaderMaterial
		var mask: Image
		for kind: String in ["albedo", "normal", "orm", "mask"]:
			var texture := atlas.get_shader_parameter(kind + "_atlas") as Texture2D
			var size := int(look["texture_sizes"][lod][kind])
			assert_true(texture != null, "%s %s texture bound" % [lod, kind])
			if texture == null:
				continue
			assert_eq(Vector2i(texture.get_size()), Vector2i(size, size), "%s %s dimensions" % [lod, kind])
			if kind == "mask":
				mask = texture.get_image()
		assert_true(mask != null and not mask.is_empty(), "%s mask readable" % lod)
		for surface in body.get_surface_count():
			assert_true(body.surface_get_material(surface) == atlas, "%s uses one shared atlas material" % lod)
			var arrays := body.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var influences := int(budgets["max_influences"])
			triangles += indices.size() / 3
			assert_eq(weights.size(), vertices.size() * influences, "%s influence cap" % lod)
			assert_eq(uv.size(), vertices.size(), "%s UV per vertex" % lod)
			assert_eq(tangents.size(), vertices.size() * 4, "%s tangent frame per vertex" % lod)
			var invalid_weights := 0
			var blended := 0
			var bad_mask := 0
			for v in vertices.size():
				var total := 0.0
				var valid := true
				for j in influences:
					var at := v * influences + j
					total += weights[at]
					if weights[at] > 0.0 and (bones[at] < 0 or bones[at] >= model.skeleton.get_bone_count()):
						valid = false
				if not valid or absf(total - 1.0) > 0.002:
					invalid_weights += 1
				if weights[v * influences] < 0.99:
					blended += 1
				if mask == null or mask.is_empty():
					continue
				var xy := Vector2i(uv[v] * Vector2(mask.get_size())).clamp(Vector2i.ZERO, mask.get_size() - Vector2i.ONE)
				var pixel := mask.get_pixelv(xy)
				if pixel.r > 0.5:
					painted.x += 1
				if pixel.g > 0.5:
					painted.y += 1
				if pixel.r < 0.01 and pixel.g < 0.01:
					painted.z += 1
				if pixel.b > 0.01 or (pixel.r > 0.01 and pixel.g > 0.01):
					bad_mask += 1
			assert_eq(invalid_weights, 0, "%s valid normalized binds" % lod)
			assert_true(blended > 0, "%s blended joints" % lod)
			assert_eq(bad_mask, 0, "%s paint fields are disjoint and sway is empty" % lod)
		assert_true(painted.x > 0 and painted.y > 0 and painted.z > 0, "%s squad, tier and neutral regions on the mesh" % lod)
		assert_true(triangles > 0 and triangles <= int(budgets["body_" + lod + "_triangles"]), "%s body triangle budget" % lod)
		var total := Budget.cost(model, Vector3.ZERO, far_m * 0.5 if lod == "near" else far_m + 1.0)
		assert_eq(total.y, body.get_surface_count() + weapon.mesh.get_surface_count(), "%s draw count includes the gun" % lod)
		assert_true(total.y <= int(budgets[lod + "_draw_calls"]), "%s draw budget" % lod)
		SoldierSquadColour.apply(instance, 2)
		SoldierSquadColour.apply_tier(instance, 3)
		var paint := SoldierSquadColour.paint(2)
		assert_eq(SoldierSquadColour.shown(instance), Vector3(paint.r, paint.g, paint.b), "%s squad instance uniform" % lod)
		var tier: Vector4 = instance.get_instance_shader_parameter(SoldierSquadColour.TIER_PARAM)
		assert_true(tier.w > 0.0, "%s tier instance uniform enables trim glow" % lod)
		print("A2_ARMOUR %s body_triangles=%d total_triangles=%d draws=%d mask_samples=%s" % [lod, triangles, total.x, total.y, painted])
	model.get_parent().free()


func test_murmillo_corpse_keeps_live_render_resources_and_paint() -> void:
	var model := _model("murmillo")
	SoldierSquadColour.apply(model.armor, 1)
	SoldierSquadColour.apply_tier(model.armor, 2)
	var corpse := SoldierCorpse.build(model)
	_tree().root.add_child(corpse)
	var mesh := corpse.get_node("Skeleton3D/Armor") as MeshInstance3D
	assert_true(mesh.mesh == model.armor.mesh and mesh.skin == model.armor.skin, "corpse shares the live Murmillo mesh and skin")
	assert_true(mesh.get_active_material(0) == model.armor.get_active_material(0), "corpse keeps the textured material")
	for field: StringName in [SoldierSquadColour.PARAM, SoldierSquadColour.TIER_PARAM]:
		assert_eq(mesh.get_instance_shader_parameter(field), model.armor.get_instance_shader_parameter(field), "corpse copies " + field)
	assert_eq(mesh.get_instance_shader_parameter(&"cape_lift"), model.armor.get_instance_shader_parameter(&"cape_lift"), "the cape instance input stays at rest on this capeless set")
	corpse.free()
	model.get_parent().free()
