extends SceneTree
## W1a: renderer probe. Draws a row of quads with the world material (and variants of its shader source) under
## three lights (ambient only, a sun, an omni) and prints the linear centre colour of every quad, so the Mobile and
## Compatibility renderers can be compared number for number without the match.
##   godot.cmd --path . --rendering-method gl_compatibility --resolution 1280x720 --log-file <log>
##       --script res://tools/compat_probe.gd -- --out=<absolute png path prefix>
## Prints PROBE <light> <column> r g b lines and writes <prefix>_<light>.png.

const COLUMNS := ["standard", "world", "world_kit", "no_arrays", "no_ao", "dbg_surf_b", "dbg_surf_a", "dbg_custom0",
		"min_unshaded", "min_lit", "min_source_color", "min_unshaded_flat", "metal_std", "world_gold", "hdr_x1", "hdr_x4", "hdr_x16"]
const SURFACE := "ashlar"

var _out := ""
var _tonemap := "linear"
var _glow := false
var _fog := false
var _sky := false  # a ProceduralSkyMaterial sky as background, ambient and reflections (the "sky" light pass)
var _sun_energy := 1.0
var _exposure := 1.0
var _cam: Camera3D
var _env: Environment
var _sun: DirectionalLight3D
var _omni: OmniLight3D


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--tonemap="):
			_tonemap = a.substr(10)
		elif a == "--glow":
			_glow = true
		elif a.begins_with("--fog"):
			_fog = true
		elif a == "--sky":
			_sky = true
		elif a.begins_with("--sun-energy="):
			_sun_energy = float(a.substr(13))
		elif a.begins_with("--exposure="):
			_exposure = float(a.substr(11))
	_run.call_deferred()


func _shader_variant(name: String) -> Shader:
	var src := FileAccess.get_file_as_string(WorldSurface.SHADER_PATH)
	match name:
		"min_source_color":
			src = "shader_type spatial;\nuniform vec4 c : source_color = vec4(0.7, 0.7, 0.7, 1.0);\nvoid fragment() {\n\tALBEDO = c.rgb;\n}\n"
		"hdr_x1", "hdr_x4", "hdr_x16":
			var k := name.substr(5)
			src = ("shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n\tvec3 c = vec3(0.1, 0.4, 0.6) * %s.0;\n"
					+ "#if CURRENT_RENDERER == RENDERER_COMPATIBILITY\n\tc = mix(vec3(1.055) * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));\n#endif\n"
					+ "\tALBEDO = c;\n}\n") % k
		"min_unshaded":
			src = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n\tALBEDO = vec3(0.25);\n}\n"
		"min_lit":
			src = "shader_type spatial;\nvoid fragment() {\n\tALBEDO = vec3(0.448);\n}\n"
		"min_unshaded_array":
			src = "shader_type spatial;\nrender_mode unshaded;\nuniform sampler2DArray surfaces;\nvoid fragment() {\n\tALBEDO = vec3(0.25) + texture(surfaces, vec3(UV, 0.0)).rgb * 0.0;\n}\n"
		"min_unshaded_flat":
			src = "shader_type spatial;\nrender_mode unshaded;\nvarying flat int v_i;\nvoid vertex() {\n\tv_i = 1;\n}\nvoid fragment() {\n\tALBEDO = vec3(0.25 * float(v_i));\n}\n"
		"min_unshaded_cam":
			src = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n\tALBEDO = vec3(0.25) + CAMERA_POSITION_WORLD * 0.0;\n}\n"
		"min_unshaded_time":
			src = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n\tALBEDO = vec3(0.25) + sin(TIME) * 0.0;\n}\n"
		"no_arrays":
			src = src.replace("vec4 a = surf_a[v_surface];", "vec4 a = vec4(%s);" % _vec4_text(_surf(true)))
			src = src.replace("vec4 b = surf_b[v_surface];", "vec4 b = vec4(%s);" % _vec4_text(_surf(false)))
		"no_ao":
			src = src.replace("AO = mix(ambient_down, 1.0, up * 0.5 + 0.5);", "")
			src = src.replace("AO_LIGHT_AFFECT = 0.0;", "")
		"dbg_surf_b":
			src = src.replace("shader_type spatial;", "shader_type spatial;\nrender_mode unshaded;")
			src = src.replace("ALBEDO = W1A_OUT(paint);", "ALBEDO = vec3(b.x, b.y, b.z);")
		"dbg_surf_a":
			src = src.replace("shader_type spatial;", "shader_type spatial;\nrender_mode unshaded;")
			src = src.replace("ALBEDO = W1A_OUT(paint);", "ALBEDO = vec3(a.x / 8.0, a.y, a.z);")
		"dbg_custom0":
			src = src.replace("shader_type spatial;", "shader_type spatial;\nrender_mode unshaded;\nvarying vec4 v_c0;")
			src = src.replace("v_surface = int(UV2.x + 0.5);", "v_surface = int(UV2.x + 0.5);\n\tv_c0 = CUSTOM0;")
			src = src.replace("ALBEDO = W1A_OUT(paint);", "ALBEDO = v_c0.xyz;")
	var s := Shader.new()
	s.code = src
	return s


func _surf(first: bool) -> Vector4:
	var arr: PackedVector4Array = WorldSurface.material().get_shader_parameter("surf_a" if first else "surf_b")
	return arr[WorldSurface.surface_id(SURFACE)]


static func _vec4_text(v: Vector4) -> String:
	return "%f, %f, %f, %f" % [v.x, v.y, v.z, v.w]


func _quad(custom: Vector4, surface: String = SURFACE) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var p := PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0)])
	var idx := PackedInt32Array([0, 2, 1, 0, 3, 2])
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var c0 := PackedFloat32Array()
	for v in p:
		n.append(Vector3(0, 0, 1))
		t.append_array([1.0, 0.0, 0.0, 1.0])
		c.append(Color(0.7, 0.7, 0.7))
		uv.append(Vector2(v.x, v.y))
		uv2.append(Vector2(WorldSurface.surface_id(surface), 0.5))
		c0.append_array([custom.x, custom.y, custom.z, custom.w])
	arrays[Mesh.ARRAY_VERTEX] = p
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TANGENT] = t
	arrays[Mesh.ARRAY_COLOR] = c
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var flags := 0
	if custom != Vector4.ZERO:
		arrays[Mesh.ARRAY_CUSTOM0] = c0
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh


func _run() -> void:
	var root3d := Node3D.new()
	root.add_child(root3d)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 12.0
	_cam.position = Vector3(COLUMNS.size() * 0.6, 0, 5)
	root3d.add_child(_cam)
	_cam.make_current()
	var world := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color.BLACK
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_env.tonemap_mode = GreyboxArt.TONEMAPPERS.get(_tonemap, Environment.TONE_MAPPER_LINEAR)
	_env.glow_enabled = _glow
	_env.glow_hdr_threshold = 8.0  # nothing in the probe blooms: glow only switches the post path on
	_env.fog_enabled = _fog
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = 1000.0
	_env.fog_depth_end = 2000.0
	world.environment = _env
	root3d.add_child(world)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(0, 0, 0)  # shines along -Z: straight onto the quads
	_sun.light_energy = _sun_energy
	_env.tonemap_exposure = _exposure
	root3d.add_child(_sun)
	_omni = OmniLight3D.new()
	_omni.omni_range = 6.0
	root3d.add_child(_omni)
	var std := StandardMaterial3D.new()
	std.albedo_color = Color(0.7, 0.7, 0.7)
	for i in COLUMNS.size():
		var name: String = COLUMNS[i]
		var mi := MeshInstance3D.new()
		var kit := name == "world_kit" or name.begins_with("dbg")
		mi.mesh = _quad(Vector4(1.0, 0.3, 1.0, 0.0) if kit else Vector4.ZERO, "gold" if name == "world_gold" else SURFACE)
		mi.position = Vector3(1.2 * i + 0.6, 0, 0)
		if name == "standard":
			mi.material_override = std
		elif name == "metal_std":
			var metal := StandardMaterial3D.new()
			metal.albedo_color = Color(0.85, 0.65, 0.3)
			metal.metallic = 1.0
			metal.roughness = 0.4
			mi.material_override = metal
		elif name == "world" or name == "world_kit" or name == "world_gold":
			mi.material_override = WorldSurface.material()
		else:
			var m := WorldSurface.material().duplicate() as ShaderMaterial
			m.shader = _shader_variant(name)
			mi.material_override = m
		root3d.add_child(mi)
	print("PROBE renderer %s surf_a %s surf_b %s" % [RenderingServer.get_current_rendering_method(), _surf(true), _surf(false)])
	_omni.position = Vector3(COLUMNS.size() * 0.6, 0, 1.0)
	var passes := ["ambient", "sun", "omni"]
	if _sky:
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		_env.sky = sky
		passes.append("sky")
	for light: String in passes:
		_env.background_mode = Environment.BG_SKY if light == "sky" else Environment.BG_COLOR
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY if light == "sky" else Environment.AMBIENT_SOURCE_COLOR
		_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY if light == "sky" else Environment.REFLECTION_SOURCE_DISABLED
		_env.ambient_light_color = Color(0.5, 0.5, 0.5) if light == "ambient" else Color.BLACK
		_env.ambient_light_energy = 1.0 if light == "ambient" or light == "sky" else 0.0
		_sun.visible = light == "sun"
		_omni.visible = light == "omni"
		for f in 8:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if _out != "":
			img.save_png("%s_%s.png" % [_out, light])
		var size := img.get_size()
		var ppm := size.y / _cam.size
		var bg := img.get_pixel(10, 10)
		print("PROBE %s %-12s %.3f %.3f %.3f" % [light, "background", bg.r, bg.g, bg.b])
		for i in COLUMNS.size():
			var x := int(size.x * 0.5 + (1.2 * i + 0.6 - _cam.position.x) * ppm)
			var col := img.get_pixel(clampi(x, 0, size.x - 1), size.y / 2)
			print("PROBE %s %-12s %.3f %.3f %.3f" % [light, COLUMNS[i], col.r, col.g, col.b])
	quit(0)
