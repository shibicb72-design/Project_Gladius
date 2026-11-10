class_name GreyboxArt
extends Node
## Replaceable procedural presentation only. No geometry, collision, navigation or pawn state edits.

const PATH := "res://data/art_greybox.json"
static var _registry := DataRegistry.new()


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func color_value(value: Array) -> Color:
	return Color(value[0], value[1], value[2], value[3])


static func material_for(key: String, unshaded: bool = false) -> StandardMaterial3D:
	var cfg := config()
	var mat := StandardMaterial3D.new()
	mat.resource_name = "Placeholder_" + key
	mat.albedo_color = color_value(cfg["palette"][key])
	mat.roughness = float(cfg["material"]["roughness"])
	mat.metallic = float(cfg["material"]["metallic"])
	if unshaded:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _ready() -> void:
	var node: Node = self
	if node is WorldEnvironment:
		_apply_environment(node as WorldEnvironment)
	elif node is MeshInstance3D:
		# Shared neutral palette; squad setup can change after child _ready. Never infer squad colour.
		(node as MeshInstance3D).material_override = material_for("body", true)
	else:
		# S2: every built piece shows the shared textured world material, tinted per palette key
		# (data/art_materials.json "tints"); the ground keeps the blend material the map builder gave it.
		for body in get_node("Nav").get_children():
			var key := "citadel"
			if body.has_meta(&"cover_palette"):
				key = String(body.get_meta(&"cover_palette"))
			if body.name == &"Ground":
				continue
			elif body.name == &"InnerWall":
				key = "inner_wall"
			elif String(body.name).begins_with("CampBlock"):
				key = "camp"
			var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
			if mesh != null:
				mesh.material_override = WorldSurface.palette_material(key)


## S1: builds the Environment and sets the sun for one look variant ("" = the data's base variant). The base
## look's light and fog still come from art_greybox.json / art_astra.json "environment"; the sky, post and
## variant overrides from data/art_look.json (MatchLook.resolved). MatchLook calls this again when a match's
## seed picks another variant.
func _apply_environment(world: WorldEnvironment, variant: String = "") -> void:
	var look := MatchLook.resolved(variant)
	var cfg: Dictionary = look["light"]
	var astra: Dictionary = look["fog"]
	var sky_cfg: Dictionary = look["sky"]
	var post: Dictionary = look["post"]
	var preset := GraphicsPresets.new().get_preset()
	var env := Environment.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://scripts/visual/shaders/sky_astra.gdshader")
	sky_material.set_shader_parameter("noise_pack", load(String(WorldSurface.config()["noise"])))
	for key: String in sky_cfg:
		var value: Variant = sky_cfg[key]
		if key.begins_with("_") or key == "radiance_size":
			continue
		if value is Array and (value as Array).size() == 4:
			sky_material.set_shader_parameter(key, color_value(value))
		elif value is Array:
			sky_material.set_shader_parameter(key, Vector2(value[0], value[1]))
		else:
			sky_material.set_shader_parameter(key, float(value))
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256 if int(sky_cfg["radiance_size"]) >= 256 else (Sky.RADIANCE_SIZE_128 if int(sky_cfg["radiance_size"]) >= 128 else Sky.RADIANCE_SIZE_64)
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = color_value(cfg["ambient_color"])
	env.ambient_light_energy = float(cfg["ambient_energy"])
	env.tonemap_mode = Environment.TONE_MAPPER_ACES if astra["tonemap"] == "aces" else Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = float(cfg["tonemap_exposure"])
	env.glow_enabled = bool(preset["art_glow_enabled"])
	env.glow_intensity = float(post["glow_intensity"])
	env.glow_strength = float(post["glow_strength"])
	env.glow_bloom = float(post["glow_bloom"])
	env.glow_hdr_threshold = float(post["glow_hdr_threshold"])
	env.glow_blend_mode = {"additive": Environment.GLOW_BLEND_MODE_ADDITIVE, "screen": Environment.GLOW_BLEND_MODE_SCREEN,
			"softlight": Environment.GLOW_BLEND_MODE_SOFTLIGHT}.get(String(post["glow_blend"]), Environment.GLOW_BLEND_MODE_SCREEN)
	env.fog_enabled = bool(preset["art_fog_enabled"])
	env.fog_mode = Environment.FOG_MODE_DEPTH if astra["fog_mode"] == "depth" else Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = color_value(astra["fog_color"])
	env.fog_density = float(astra["fog_density"])
	env.fog_sky_affect = float(astra["fog_sky_affect"])
	env.fog_depth_begin = float(astra["fog_depth_begin_m"])
	env.fog_depth_end = float(astra["fog_depth_end_m"])
	env.fog_depth_curve = float(astra["fog_depth_curve"])
	env.fog_sun_scatter = float(post["fog_sun_scatter"])
	env.fog_aerial_perspective = float(post["fog_aerial_perspective"])
	env.adjustment_enabled = bool(preset.get("art_grade_enabled", false))
	env.adjustment_brightness = float(post["adjust_brightness"])
	env.adjustment_contrast = float(post["adjust_contrast"])
	env.adjustment_saturation = float(post["adjust_saturation"])
	world.environment = env
	var sun := world.get_parent().get_node("Light") as DirectionalLight3D
	sun.light_color = color_value(cfg["sun_color"])
	sun.light_energy = float(cfg["sun_energy"])
	var angles: Array = cfg["sun_rotation_degrees"]
	sun.rotation_degrees = Vector3(angles[0], angles[1], angles[2])
	sun.shadow_enabled = bool(preset["art_shadows_enabled"])
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if astra["shadow_mode"] == "orthogonal" else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = float(astra["shadow_max_distance_m"])
	sun.light_angular_distance = float(astra["light_angular_distance"])
	WorldSurface.set_wet(float(look["wet"]))
	var match_look := world.get_node_or_null("MatchLook") as MatchLook
	if match_look == null:
		match_look = MatchLook.new()
		match_look.name = "MatchLook"
		world.add_child(match_look)
	match_look.show_variant(look, preset)
	# S5: the match-wide sounds live beside the look and follow its variant (wind, rain, night, thunder).
	var match_audio := world.get_node_or_null("MatchAudio") as MatchAudio
	if match_audio == null:
		match_audio = MatchAudio.new()
		match_audio.name = "MatchAudio"
		world.add_child(match_audio)
	match_audio.show_look(look, match_look)
	# S6: the loot models and the carrier model follow the match from here too (looks only).
	if world.get_node_or_null("LootLook") == null:
		var loot_look := LootLook.new()
		loot_look.name = "LootLook"
		world.add_child(loot_look)
		var carrier := CarrierLook.new()
		carrier.name = "CarrierLook"
		world.add_child(carrier)
