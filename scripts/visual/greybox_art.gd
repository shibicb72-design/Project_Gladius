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
		var materials := {}
		for key in ["ground", "citadel", "inner_wall", "camp"]:
			materials[key] = material_for(key)
		for body in get_node("Nav").get_children():
			var key := "citadel"
			if body.has_meta(&"cover_palette"):
				key = String(body.get_meta(&"cover_palette"))
			if body.name == &"Ground":
				key = "ground"
			elif body.name == &"InnerWall":
				key = "inner_wall"
			elif String(body.name).begins_with("CampBlock"):
				key = "camp"
			var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
			if mesh != null:
				mesh.material_override = materials[key]
				if body.has_meta(&"cover_palette"):
					var cover_material := (materials[key] as StandardMaterial3D).duplicate() as StandardMaterial3D
					cover_material.vertex_color_use_as_albedo = true
					mesh.material_override = cover_material


func _apply_environment(world: WorldEnvironment) -> void:
	var cfg: Dictionary = config()["environment"]
	var astra: Dictionary = LowpolyKit.config()["environment"]
	var preset := GraphicsPresets.new().get_preset()
	var env := Environment.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = color_value(cfg["sky_top"])
	sky_material.sky_horizon_color = color_value(cfg["sky_horizon"])
	sky_material.ground_bottom_color = color_value(cfg["ground_bottom"])
	sky_material.ground_horizon_color = color_value(cfg["ground_horizon"])
	sky_material.sky_curve = float(cfg["sky_curve"])
	sky_material.ground_curve = float(cfg["ground_curve"])
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = color_value(cfg["ambient_color"])
	env.ambient_light_energy = float(cfg["ambient_energy"])
	env.tonemap_mode = Environment.TONE_MAPPER_ACES if astra["tonemap"] == "aces" else Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = float(cfg["tonemap_exposure"])
	env.glow_enabled = bool(preset["art_glow_enabled"])
	env.fog_enabled = bool(preset["art_fog_enabled"])
	env.fog_mode = Environment.FOG_MODE_DEPTH if astra["fog_mode"] == "depth" else Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = color_value(astra["fog_color"])
	env.fog_density = float(astra["fog_density"])
	env.fog_sky_affect = float(astra["fog_sky_affect"])
	env.fog_depth_begin = float(astra["fog_depth_begin_m"])
	env.fog_depth_end = float(astra["fog_depth_end_m"])
	env.fog_depth_curve = float(astra["fog_depth_curve"])
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
