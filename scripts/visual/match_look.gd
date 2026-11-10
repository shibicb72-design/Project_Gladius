class_name MatchLook
extends Node3D
## S1: the parts of a match's look that are not the Environment itself: which variant shows (dusk, night,
## storm), weather around the camera, sun shafts, the vignette and storm lightning. A child of the match's
## WorldEnvironment (GreyboxArt adds it). Data: data/art_look.json (placeholders, OQ-GFX-LOOK); each effect is
## switched by the graphics preset. Presentation only: it reads the director's seed and decides nothing.

signal lightning_struck  ## storm: a flash has started (the audio layer answers with thunder)

const PATH := "res://data/art_look.json"
static var _registry := DataRegistry.new()
## Tools and tests: force a variant id for every match ("" = follow the data).
static var variant_override := ""

var look: Dictionary = {}
var preset: Dictionary = {}
var weather: GPUParticles3D
var splashes: GPUParticles3D
var shafts: MultiMeshInstance3D
var vignette: CanvasLayer
var _seed_checked := false
var _flash_left := 0.0
var _flash_wait := 0.0
var _rng := RandomNumberGenerator.new()


static func config() -> Dictionary:
	return _registry.load_file(PATH)


## Everything one variant shows, base values with the variant's overrides on top.
static func resolved(variant: String = "") -> Dictionary:
	var cfg := config()
	var id := variant
	if id == "":
		id = variant_override if variant_override != "" else String(cfg["variant"])
	var over: Dictionary = (cfg["variants"] as Dictionary).get(id, {})
	return {
		"id": id,
		"light": (GreyboxArt.config()["environment"] as Dictionary).merged(over.get("light", {}), true),
		"fog": (LowpolyKit.config()["environment"] as Dictionary).merged(over.get("fog", {}), true),
		"sky": (cfg["sky"] as Dictionary).merged(over.get("sky", {}), true),
		"post": (cfg["post"] as Dictionary).merged(over.get("post", {}), true),
		"wet": float(over.get("wet", cfg["wet"])),
		"weather": String(over.get("weather", cfg["weather"])),
	}


## The variant a match with this seed shows: the fixed one, or the rotation list's pick.
static func variant_for_seed(seed_value: int) -> String:
	var cfg := config()
	if variant_override != "":
		return variant_override
	var rotation: Dictionary = cfg["rotation"]
	var list: Array = rotation["by_seed"]
	if not bool(rotation["enabled"]) or list.is_empty():
		return String(cfg["variant"])
	return String(list[posmod(seed_value, list.size())])


## Called by GreyboxArt after it has built the Environment for `new_look`.
func show_variant(new_look: Dictionary, new_preset: Dictionary) -> void:
	look = new_look
	preset = new_preset
	for child in get_children():
		remove_child(child)
		child.queue_free()
	weather = null
	splashes = null
	shafts = null
	vignette = null
	_flash_left = 0.0
	if bool(preset.get("art_weather_enabled", false)):
		_build_weather()
	if bool(preset.get("art_shafts_enabled", false)):
		_build_shafts()
	if bool(preset.get("art_vignette_enabled", false)) and float(look["post"]["vignette"]) > 0.0:
		_build_vignette()
	_rng.seed = 7
	_next_flash()
	# S9: smooth dusk gradients band without dithering; debanding is a few instructions in the tonemap pass.
	if is_inside_tree() and preset.has("art_debanding_enabled"):
		get_viewport().use_debanding = bool(preset["art_debanding_enabled"])


func _director() -> MatchDirector:
	var world := get_parent()
	return world.get_parent().get_node_or_null("Director") as MatchDirector if world != null and world.get_parent() != null else null


func _sun() -> DirectionalLight3D:
	return get_parent().get_parent().get_node_or_null("Light") as DirectionalLight3D


func _weather_cfg() -> Dictionary:
	return (config()["weather_kinds"] as Dictionary).get(String(look.get("weather", "none")), {})


static func _unshaded(color: Color, additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = true
	mat.disable_fog = true
	return mat


func _particles(amount: int, lifetime: float, box: Vector3, mesh: Mesh) -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.amount = amount
	node.lifetime = lifetime
	node.local_coords = false
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.draw_pass_1 = mesh
	node.visibility_aabb = AABB(-box, box * 2.0)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = box * 0.5
	process.gravity = Vector3.ZERO
	node.process_material = process
	add_child(node)
	return node


func _build_weather() -> void:
	var kind := String(look.get("weather", "none"))
	var w := _weather_cfg()
	if w.is_empty():
		return
	var box := LowpolyKit.vec(w["box_m"])
	var color := GreyboxArt.color_value(w["color"])
	if kind == "rain":
		var streak := QuadMesh.new()
		streak.size = Vector2(float(w["width_m"]), float(w["length_m"]))
		var mat := _unshaded(color, false)
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.billboard_keep_scale = true
		streak.material = mat
		weather = _particles(int(w["amount"]), float(w["lifetime_s"]), Vector3(box.x, 0.5, box.z), streak)
		weather.name = "Rain"
		weather.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Y_TO_VELOCITY
		var process := weather.process_material as ParticleProcessMaterial
		var fall := (Vector3.DOWN + LowpolyKit.vec(w["slant"])).normalized()
		process.direction = fall
		process.spread = 2.0
		process.initial_velocity_min = float(w["speed_mps"]) * 0.9
		process.initial_velocity_max = float(w["speed_mps"]) * 1.1
		weather.set_meta(&"height_m", box.y * 0.5)
		var ring := QuadMesh.new()
		ring.size = Vector2.ONE * float(w["splash_size_m"])
		ring.orientation = PlaneMesh.FACE_Y
		var ring_mat := ShaderMaterial.new()
		ring_mat.shader = load("res://scripts/visual/shaders/rain_splash.gdshader")
		ring_mat.set_shader_parameter("tint", color)
		ring.material = ring_mat
		splashes = _particles(int(w["splash_amount"]), float(w["splash_lifetime_s"]), Vector3(float(w["splash_box_m"]), 0.0, float(w["splash_box_m"])), ring)
		splashes.name = "RainSplashes"
	else:
		var mote := QuadMesh.new()
		mote.size = Vector2.ONE * float(w["size_m"])
		var mat := _unshaded(color, true)
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.billboard_keep_scale = true
		var dot := GradientTexture2D.new()  # a soft round speck instead of a square
		dot.width = 32
		dot.height = 32
		dot.fill = GradientTexture2D.FILL_RADIAL
		dot.fill_from = Vector2(0.5, 0.5)
		dot.fill_to = Vector2(1.0, 0.5)
		var falloff := Gradient.new()
		falloff.set_color(0, Color(1, 1, 1, 1))
		falloff.set_color(1, Color(1, 1, 1, 0))
		dot.gradient = falloff
		mat.albedo_texture = dot
		mote.material = mat
		weather = _particles(int(w["amount"]), float(w["lifetime_s"]), box, mote)
		weather.name = "Motes"
		var process := weather.process_material as ParticleProcessMaterial
		process.direction = Vector3(1.0, 0.25, 0.3).normalized()
		process.spread = 70.0
		process.initial_velocity_min = float(w["speed_mps"]) * 0.4
		process.initial_velocity_max = float(w["speed_mps"])
		process.scale_min = 0.5
		process.scale_max = 1.6
		var fade := Gradient.new()
		fade.set_color(0, Color(1, 1, 1, 0))
		fade.add_point(0.25, Color(1, 1, 1, 1))
		fade.add_point(0.75, Color(1, 1, 1, 1))
		fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0))
		var ramp := GradientTexture1D.new()
		ramp.gradient = fade
		process.color_ramp = ramp
		weather.set_meta(&"height_m", 1.5)


func _build_shafts() -> void:
	var s: Dictionary = config()["shafts"]
	var sun := _sun()
	if sun == null or float(look["light"]["sun_energy"]) < float(s["min_sun_energy"]):
		return
	var places: Array = s["at"]
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/visual/shaders/sun_shaft.gdshader")
	mat.set_shader_parameter("tint", GreyboxArt.color_value(s["color"]))
	mat.set_shader_parameter("strength", float(s["strength"]))
	mat.set_shader_parameter("length_m", float(s["length_m"]))
	mat.set_shader_parameter("width_m", float(s["width_m"]))
	mat.set_shader_parameter("axis", -sun.global_transform.basis.z)
	mat.set_shader_parameter("noise_pack", load(String(WorldSurface.config()["noise"])))
	quad.material = mat
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = quad
	batch.instance_count = places.size()
	for i in places.size():
		batch.set_instance_transform(i, Transform3D(Basis.IDENTITY, LowpolyKit.vec(places[i])))
	shafts = MultiMeshInstance3D.new()
	shafts.name = "SunShafts"
	shafts.multimesh = batch
	shafts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shafts.custom_aabb = AABB(Vector3(-120, -10, -120), Vector3(240, 60, 240))
	add_child(shafts)


func _build_vignette() -> void:
	vignette = CanvasLayer.new()
	vignette.name = "Vignette"
	vignette.layer = 0  # under the HUD (layer 1), over the 3D view
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/visual/shaders/vignette.gdshader")
	mat.set_shader_parameter("tint", GreyboxArt.color_value(look["post"]["vignette_color"]))
	mat.set_shader_parameter("strength", float(look["post"]["vignette"]))
	rect.material = mat
	vignette.add_child(rect)
	add_child(vignette)


func _next_flash() -> void:
	var w := _weather_cfg()
	if not w.has("lightning_every_s"):
		_flash_wait = -1.0
		return
	_flash_wait = _rng.randf_range(float(w["lightning_every_s"][0]), float(w["lightning_every_s"][1]))


func _process(delta: float) -> void:
	# The match seed is known once the director runs: show the variant it picks (once per match).
	if not _seed_checked:
		var director := _director()
		if director != null and director.running:
			_seed_checked = true
			var id := variant_for_seed(director.match_seed)
			if id != String(look.get("id", "")):
				get_parent().call("_apply_environment", get_parent(), id)
				return
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		var at := camera.global_position
		if weather != null:
			weather.global_position = at + Vector3.UP * float(weather.get_meta(&"height_m", 0.0)) - camera.global_transform.basis.z * 4.0
		if splashes != null:
			splashes.global_position = Vector3(at.x, 0.03, at.z) - camera.global_transform.basis.z * Vector3(1, 0, 1) * 5.0
	if _flash_wait >= 0.0:
		_flash_wait -= delta
		if _flash_wait <= 0.0:
			_flash_left = float(_weather_cfg()["lightning_s"])
			lightning_struck.emit()
			_next_flash()
	if _flash_left > 0.0:
		_flash_left -= delta
		var w := _weather_cfg()
		var sun := _sun()
		var world := get_parent() as WorldEnvironment
		var k := clampf(_flash_left / float(w["lightning_s"]), 0.0, 1.0)
		var flicker := k * (0.6 + 0.4 * sin(_flash_left * 90.0)) if _flash_left > 0.0 else 0.0  # the last step puts the light back exactly
		if sun != null:
			sun.light_energy = float(look["light"]["sun_energy"]) + float(w["lightning_energy"]) * flicker
			sun.light_color = GreyboxArt.color_value(look["light"]["sun_color"]).lerp(GreyboxArt.color_value(w["lightning_color"]), flicker)
		if world != null and world.environment != null:
			world.environment.ambient_light_energy = float(look["light"]["ambient_energy"]) * (1.0 + flicker * 1.5)
