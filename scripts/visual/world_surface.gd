class_name WorldSurface
extends RefCounted
## S2: the textured surfaces of the built world. Data: data/art_materials.json (placeholders, OQ-GFX-MATERIALS).
## A kit vertex stores the id of its paint's surface in UV2.x (LowpolyKit writes it); the shared shader
## (shaders/world_surface.gdshader) reads that surface's texture layer and numbers from two uniform arrays.
## Presentation only: nothing here is read by gameplay. The footstep sounds ask surface_name() for a name.

const PATH := "res://data/art_materials.json"
const SHADER_PATH := "res://scripts/visual/shaders/world_surface.gdshader"
const GROUND_SHADER_PATH := "res://scripts/visual/shaders/ground.gdshader"
const MAX_SURFACES := 32
static var _registry := DataRegistry.new()
static var _ids := {}
static var _materials := {}
static var _ground: ShaderMaterial
static var _wet := 0.0


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func _color(value: Array) -> Color:
	return Color(value[0], value[1], value[2], value[3] if value.size() > 3 else 1.0)


## Id of a named surface (its place in "surface_order"); 0 ("plain") for an unknown name.
static func surface_id(surface: String) -> int:
	if _ids.is_empty():
		var order: Array = config()["surface_order"]
		for i in order.size():
			_ids[String(order[i])] = i
	return int(_ids.get(surface, 0))


static func surface_name(id: int) -> String:
	var order: Array = config()["surface_order"]
	return String(order[id]) if id >= 0 and id < order.size() else "plain"


## Surface id a paint colour shows: the kit kind's own choice ("kinds") first, then "paint", then plain.
static func id_for_paint(color_name: String, kind: String = "") -> int:
	var cfg := config()
	if kind != "" and (cfg["kinds"] as Dictionary).has(kind) and (cfg["kinds"][kind] as Dictionary).has(color_name):
		return surface_id(String(cfg["kinds"][kind][color_name]))
	return surface_id(String((cfg["paint"] as Dictionary).get(color_name, "plain")))


static func _apply_shared(material: ShaderMaterial) -> void:
	var cfg := config()
	var layers: Array = cfg["layers"]
	var a := PackedVector4Array()
	var b := PackedVector4Array()
	a.resize(MAX_SURFACES)
	b.resize(MAX_SURFACES)
	var order: Array = cfg["surface_order"]
	for i in MAX_SURFACES:
		var s: Dictionary = cfg["surfaces"][order[i]] if i < order.size() else cfg["surfaces"]["plain"]
		a[i] = Vector4(float(layers.find(s["layer"])), 1.0 / float(s["tile_m"]), float(s["contrast"]), float(s["bump"]))
		b[i] = Vector4(float(s["rough_scale"]), float(s["rough_bias"]), float(s["metallic"]), float(s["glow"]))
	material.set_shader_parameter("surfaces", load(String(cfg["texture"])))
	material.set_shader_parameter("surf_a", a)
	material.set_shader_parameter("surf_b", b)
	var shading: Dictionary = cfg["shading"]
	material.set_shader_parameter("ambient_down", float(shading["ambient_down"]))
	material.set_shader_parameter("bounce_color", _color(shading["bounce_color"]))
	material.set_shader_parameter("bounce", float(shading["bounce"]))
	material.set_shader_parameter("grime_height", float(shading["grime_height_m"]))
	material.set_shader_parameter("grime_dark", float(shading["grime_dark"]))
	material.set_shader_parameter("glow_pulse", float(shading["glow_pulse"]))
	material.set_shader_parameter("glow_pulse_speed", float(shading["glow_pulse_speed"]))
	material.set_shader_parameter("wet_dark", float(cfg["wet"]["dark"]))
	material.set_shader_parameter("wet_roughness", float(cfg["wet"]["roughness"]))
	material.set_shader_parameter("wet", _wet)


## The shared world material for one tint (cached: every caller with the same tint gets the same resource).
static func material(tint: Color = Color.WHITE, paint_mix: float = 1.0) -> ShaderMaterial:
	var key := "%s/%.2f" % [tint.to_html(), paint_mix]
	if not _materials.has(key):
		var made := ShaderMaterial.new()
		made.resource_name = "WorldSurface"
		made.shader = load(SHADER_PATH)
		_apply_shared(made)
		made.set_shader_parameter("tint", tint)
		made.set_shader_parameter("paint_mix", paint_mix)
		_materials[key] = made
	return _materials[key]


## Gives another shader material (the soldier's) the same surface arrays and wet look, and keeps it in step
## with set_wet(). The shader declares the uniforms it wants; the others are ignored.
static func adopt(other: ShaderMaterial) -> void:
	_apply_shared(other)
	_materials["adopted/%d" % other.get_instance_id()] = other


## The world material tinted for a map palette key ("citadel", "camp", "inner_wall"): data "tints", white if absent.
static func palette_material(key: String) -> ShaderMaterial:
	var tints: Dictionary = config().get("tints", {})
	return material(_color(tints[key]) if tints.has(key) else Color.WHITE)


## The ground material; `paint_map` is GroundPaint's image as a texture, `map_size_m` the ground's side.
static func ground_material(paint_map: Texture2D, map_size_m: float) -> ShaderMaterial:
	var cfg := config()
	var g: Dictionary = cfg["ground"]
	var layers: Array = cfg["layers"]
	if _ground == null:
		_ground = ShaderMaterial.new()
		_ground.resource_name = "WorldGround"
		_ground.shader = load(GROUND_SHADER_PATH)
		_ground.set_shader_parameter("surfaces", load(String(cfg["texture"])))
		_ground.set_shader_parameter("noise_pack", load(String(cfg["noise"])))
		_ground.set_shader_parameter("layer_ids", Vector3(layers.find("dirt"), layers.find("grass"), layers.find("paving")))
		_ground.set_shader_parameter("tiles_per_m", Vector3(1.0 / float(g["earth_tile_m"]), 1.0 / float(g["grass_tile_m"]), 1.0 / float(g["paving_tile_m"])))
		_ground.set_shader_parameter("earth_color", _color(g["earth_color"]))
		_ground.set_shader_parameter("grass_color", _color(g["grass_color"]))
		_ground.set_shader_parameter("grass_dry_color", _color(g["grass_dry_color"]))
		_ground.set_shader_parameter("paving_color", _color(g["paving_color"]))
		_ground.set_shader_parameter("macro_per_m", 1.0 / float(g["macro_tile_m"]))
		_ground.set_shader_parameter("macro_strength", float(g["macro_strength"]))
		_ground.set_shader_parameter("edge_noise", float(g["edge_noise"]))
		_ground.set_shader_parameter("puddle_level", float(g["puddle_level"]))
		_ground.set_shader_parameter("puddle_soft", float(g["puddle_soft"]))
		_ground.set_shader_parameter("wet_dark", float(cfg["wet"]["dark"]))
		_ground.set_shader_parameter("wet_roughness", float(cfg["wet"]["roughness"]))
		_ground.set_shader_parameter("wet", _wet)
	_ground.set_shader_parameter("paint_map", paint_map)
	_ground.set_shader_parameter("map_size_m", map_size_m)
	return _ground


## How wet the world looks, 0..1 (set by the sky variant). Applies to every material made here.
static func set_wet(amount: float) -> void:
	_wet = clampf(amount, 0.0, 1.0)
	for key in _materials:
		(_materials[key] as ShaderMaterial).set_shader_parameter("wet", _wet)
	if _ground != null:
		_ground.set_shader_parameter("wet", _wet)


static func wet() -> float:
	return _wet


## True for a material that takes light: a per-pixel StandardMaterial3D, or one of the shaders above
## (neither is unshaded). The art tests use it where they used to ask for a StandardMaterial3D.
static func is_lit(candidate: Material) -> bool:
	if candidate is BaseMaterial3D:
		return (candidate as BaseMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL
	if candidate is ShaderMaterial and (candidate as ShaderMaterial).shader != null:
		for line in (candidate as ShaderMaterial).shader.code.split("\n"):
			if line.strip_edges().begins_with("render_mode") and line.contains("unshaded"):
				return false
		return true
	return false
