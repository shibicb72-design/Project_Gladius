extends SceneTree
## W1a: renderer parity captures (Mobile vs Compatibility). Tool only: it changes no game file and decides nothing.
##
## Capture mode (windowed: a headless run has no renderer). One run = one renderer + one look variant, every view:
##   godot.cmd --path . --rendering-method mobile --resolution 1920x1080 --fixed-fps 60 --log-file <log>
##       --script res://tools/parity_capture.gd -- --out=<absolute dir> --variant=dusk
##   (the same with --rendering-method gl_compatibility). --fixed-fps 60 is the engine's (a script cannot read it
##   back): keep it on every run so the settle frames are the same simulated time under both renderers.
## It starts the real match scene (scenes/match/match.tscn, as tools/frame_time.gd does: map alesia_500 by
## map_path_override, the views file's fixed seed by seed_override, no bots, no drop) with the look variant forced by
## MatchLook.variant_override (sky, sun, fog, post, wet and weather all follow it), hides the HUD layer, switches storm
## lightning off and refills the weather after every camera move (as tools/m2w1_capture.gd), and renders each view of
## tools/parity_views.json through its own Camera3D (near/far copied from the match's CameraRig camera) in the root
## viewport. Saves <view>_<variant>_<renderer>.png (renderer = RenderingServer.get_current_rendering_method()) and
## parity_<variant>_<renderer>.json: the renderer, driver and video adapter actually running, the variant, seed, the
## Environment the match built (tonemap, glow, fog, ...), and per view the camera, the frame's draw calls / objects /
## primitives, the lights whose range sphere meets the camera frustum, the image's mean colour and checks.
## Options: --variant=<id> (default art_look.json "variant"), --views=<res path> (default res://tools/parity_views.json),
##   --only=<text> (views whose name contains it), --size=<W>x<H> (the --resolution given; default the views file's
##   "size"), --settle=<frames> (default the views file's "settle_frames").
## A view fails (exit 1) when the PNG cannot be saved, the image is not the asked size, is black (mean luma < 0.01),
## is mostly the match's magenta clear colour (the world did not draw), or the camera stands inside a collider.
##
## Sheet mode (may run headless): one side-by-side per view per variant, left Mobile, right Compatibility, labelled:
##   godot.cmd --headless --path . --script res://tools/parity_capture.gd -- --sheets --out=<the same dir>
## Options: --variants=dusk,night,storm (default), --views=..., --scale=<0..1> (each half's scale, default 0.5).
## Writes sheet_<view>_<variant>.png into --out and one PARITY_SHEET line each with the mean absolute difference of
## the two halves (0..255 per channel, sampled). A view/variant with neither PNG is skipped; with only one it fails.
## W1a after-captures: write them to <dir>/after (same names) and build sheets there with --out=<dir>/after; the
##   line also gives full_res_pixels_differing and max_channel_diff (every pixel, before scaling).
##   --left-dir=<dir> takes the left (Mobile) PNG from <dir> instead (e.g. the before shots; the label says BEFORE).
##   --right=<renderer> puts that renderer's PNG on the right (default gl_compatibility; another name adds
##   _vs_<renderer> to the sheet name). --left-dir=<dir> --right=mobile --out=<dir>/after compares Mobile before/after.

const VIEWS_PATH := "res://tools/parity_views.json"
const MATCH_SCENE := "res://scenes/match/match.tscn"
const LEFT := "mobile"
const RIGHT := "gl_compatibility"
const TONEMAP_NAMES := {0: "linear", 1: "reinhard", 2: "filmic", 3: "aces", 4: "agx"}

var _out := ""
var _variant := ""
var _views_path := VIEWS_PATH
var _only := ""
var _size := Vector2i.ZERO
var _settle := -1
var _sheets := false
var _variants: PackedStringArray = ["dusk", "night", "storm"]
var _scale := 0.5
var _left_dir := ""
var _right := RIGHT
var _env_overrides := ""

var _match: Node
var _camera: Camera3D
var _pawn: Node3D
var _terrain: Variant
var _look: Node
var _lights: Array[Node] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--variant="):
			_variant = a.substr(10)
		elif a.begins_with("--views="):
			_views_path = a.substr(8)
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a.begins_with("--size="):
			var parts := a.substr(7).split("x")
			if parts.size() == 2:
				_size = Vector2i(int(parts[0]), int(parts[1]))
		elif a.begins_with("--settle="):
			_settle = maxi(1, int(a.substr(9)))
		elif a == "--sheets":
			_sheets = true
		elif a.begins_with("--variants="):
			_variants = a.substr(11).split(",", false)
		elif a.begins_with("--scale="):
			_scale = clampf(float(a.substr(8)), 0.05, 1.0)
		elif a.begins_with("--left-dir="):
			_left_dir = a.substr(11)
		elif a.begins_with("--right="):
			_right = a.substr(8)
		elif a.begins_with("--env="):
			_env_overrides = a.substr(6)
	if _out == "":
		printerr("parity_capture: give --out=<absolute dir>")
		quit(2)
		return
	var cfg := DataRegistry.parse_quiet(_views_path)
	if (cfg.get("views", []) as Array).is_empty():
		printerr("parity_capture: no views in %s" % _views_path)
		quit(2)
		return
	var ok: bool
	if _sheets:
		ok = _build_sheets(cfg)
	else:
		ok = await _capture(cfg)
	quit(0 if ok else 1)


# --- capture mode ---

## W1a diagnosis only: --env=<prop>=<value>[,<prop>=<value>...] sets Environment properties (str_to_var values,
## e.g. fog_enabled=false,fog_aerial_perspective=0.0) on the match's Environment after it is built, for A/B
## captures. Write such runs to their own --out dir; the parity matrix never passes --env.
func _apply_env_overrides() -> void:
	if _env_overrides == "":
		return
	var world := _match.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world == null or world.environment == null:
		printerr("parity_capture: --env given but the match has no Environment")
		return
	for pair: String in _env_overrides.split(",", false):
		var kv := pair.split("=", false, 1)
		if kv.size() == 2:
			world.environment.set(kv[0], str_to_var(kv[1]))
			print("PARITY_ENV_OVERRIDE %s=%s" % [kv[0], world.environment.get(kv[0])])

func _capture(cfg: Dictionary) -> bool:
	if DisplayServer.get_name() == "headless":
		printerr("parity_capture: capture mode needs a window (run without --headless)")
		return false
	var variants: Dictionary = MatchLook.config()["variants"]
	if _variant == "":
		_variant = String(MatchLook.config()["variant"])
	if not variants.has(_variant):
		printerr("parity_capture: unknown variant %s (have %s)" % [_variant, ", ".join(PackedStringArray(variants.keys()))])
		return false
	if _size == Vector2i.ZERO:
		var s: Array = cfg.get("size", [1920, 1080])
		_size = Vector2i(int(s[0]), int(s[1]))
	if _settle < 0:
		_settle = int(cfg.get("settle_frames", 120))
	var renderer := RenderingServer.get_current_rendering_method()
	DirAccess.make_dir_recursive_absolute(_out)
	await process_frame
	await process_frame
	if root.size != _size:
		printerr("parity_capture: the window is %dx%d, asked %dx%d (pass --resolution %dx%d, or --size= the size the window gets)" % [
				root.size.x, root.size.y, _size.x, _size.y, _size.x, _size.y])
		return false
	GraphicsPresets.new().apply("", root)  # as scripts/ui/boot.gd does for the game's viewport (msaa, 3D scale)
	MatchLook.variant_override = _variant
	var map_path := String(cfg.get("map", "res://data/maps/alesia_500.json"))
	var seed_value := int(cfg.get("seed", 20261109))
	var t0 := Time.get_ticks_msec()
	_match = load(MATCH_SCENE).instantiate()
	_match.set("auto_start", false)
	_match.set("bake_navmesh", true)
	_match.set("fill_bots", false)
	_match.set("seed_override", seed_value)
	_match.set("map_path_override", map_path)
	root.add_child(_match)
	await process_frame
	(_match.get("director") as MatchDirector).load_config(map_path)
	if not _match.call("begin"):
		printerr("parity_capture: the match did not start")
		return false
	print("PARITY_BUILD renderer=%s map=%s variant=%s seed=%d build_ms=%d" % [renderer, map_path, _variant, seed_value, Time.get_ticks_msec() - t0])
	var hud := _match.get_node_or_null("Hud") as CanvasLayer
	if hud != null:
		hud.visible = false
	_apply_env_overrides()
	_look = _match.get_node_or_null("WorldEnvironment/MatchLook")
	_pawn = _match.get("local_player") as Node3D
	_pawn.set_physics_process(false)
	_pawn.visible = false
	var map: Node = _match.get("map")
	_terrain = map.get_node("ArtBuilder").get("terrain") if map.has_node("ArtBuilder") else null
	_camera = Camera3D.new()
	_camera.name = "ParityCamera"
	var rig_camera := _pawn.get_viewport().get_camera_3d()
	if rig_camera != null:
		_camera.near = rig_camera.near
		_camera.far = rig_camera.far
		_camera.keep_aspect = rig_camera.keep_aspect
	_match.add_child(_camera)
	_camera.make_current()
	_lights = _match.find_children("*", "Light3D", true, false)
	_no_lightning()
	for frame in int(cfg.get("first_settle_frames", 180)):
		await process_frame
	var report := _run_report(cfg, renderer, map_path, seed_value)
	var ok := true
	var made := 0
	var view_reports: Array = []
	for view: Dictionary in cfg["views"]:
		if _only != "" and not String(view["name"]).contains(_only):
			continue
		var r: Dictionary = await _take(view, renderer)
		view_reports.append(r)
		ok = ok and bool(r["ok"])
		made += 1
	report["views"] = view_reports
	report["ok"] = ok and made > 0
	var json_path := _out.path_join("parity_%s_%s.json" % [_variant, renderer])
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		printerr("parity_capture: cannot write %s" % json_path)
		ok = false
	else:
		f.store_string(JSON.stringify(report, "\t"))
		f.close()
	print("PARITY_DONE renderer=%s variant=%s views=%d ok=%s json=%s" % [renderer, _variant, made, ok, json_path])
	MatchLook.variant_override = ""
	_match.queue_free()
	await process_frame
	return ok and made > 0


func _ground(x: float, z: float) -> float:
	return (_terrain as MapTerrain).height_at(x, z) if _terrain is MapTerrain else 0.0


## Storm lightning off (MatchLook's next-flash timer), so every capture shows the variant's steady light.
func _no_lightning() -> void:
	if _look != null:
		_look.set("_flash_wait", -1.0)


## The weather restarted around the camera already spread out (as tools/m2w1_capture.gd).
func _refill_weather() -> void:
	if _look == null:
		return
	for key in ["weather", "splashes"]:
		var p := _look.get(key) as GPUParticles3D
		if p != null:
			p.preprocess = p.lifetime
			p.restart()


static func _forward(yaw_deg: float, pitch_deg: float) -> Vector3:
	var y := deg_to_rad(yaw_deg)
	var p := deg_to_rad(pitch_deg)
	return Vector3(sin(y) * cos(p), sin(p), -cos(y) * cos(p))


func _take(view: Dictionary, renderer: String) -> Dictionary:
	var view_name := String(view["name"])
	var pos: Array = view["pos"]
	var at := Vector3(float(pos[0]), 0.0, float(pos[1]))
	at.y = _ground(at.x, at.z) + float(view.get("eye_m", 1.7))
	var forward := _forward(float(view.get("yaw_deg", 0.0)), float(view.get("pitch_deg", 0.0)))
	_camera.fov = float(view.get("fov_deg", 75.0))
	_camera.global_position = at
	_camera.look_at(at + forward * 100.0, Vector3.UP)
	var soldier_at := Vector3.INF
	if view.has("soldier"):
		var s: Dictionary = view["soldier"]
		var spot: Array = s["at"]
		soldier_at = Vector3(float(spot[0]), 0.0, float(spot[1]))
		soldier_at.y = _ground(soldier_at.x, soldier_at.z)
		var facing := Vector3(at.x - soldier_at.x, 0.0, at.z - soldier_at.z).normalized()
		_pawn.global_transform = Transform3D(Basis.looking_at(facing).rotated(Vector3.UP, deg_to_rad(float(s.get("turn_deg", 30.0)))), soldier_at)
		_pawn.visible = true
	else:
		_pawn.visible = false
	await process_frame
	_refill_weather()
	_no_lightning()
	for frame in _settle:
		await process_frame
	await RenderingServer.frame_post_draw
	var info := {
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
	}
	var img := root.get_texture().get_image()
	var file := "%s_%s_%s.png" % [view_name, _variant, renderer]
	var path := _out.path_join(file)
	var err := img.save_png(path)
	var stats := _image_stats(img)
	var clear := _clearance(at, at + forward * 60.0)
	var problems := PackedStringArray()
	if err != OK:
		problems.append("save_png err %d" % err)
	if img.get_size() != _size:
		problems.append("image %dx%d, asked %dx%d" % [img.get_width(), img.get_height(), _size.x, _size.y])
	if float(stats["mean_luma"]) < 0.01:
		problems.append("black (mean luma %.4f)" % float(stats["mean_luma"]))
	if float(stats["magenta_fraction"]) > 0.5:
		problems.append("mostly the magenta clear colour (%.2f): the world did not draw" % float(stats["magenta_fraction"]))
	if not bool(clear["clear"]):
		problems.append("camera inside a collider: %s" % clear["sight"])
	var lights := _lights_in_frustum()
	var r := {
		"name": view_name, "file": file, "ok": problems.is_empty(), "problems": problems,
		"camera": [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01)],
		"yaw_deg": float(view.get("yaw_deg", 0.0)), "pitch_deg": float(view.get("pitch_deg", 0.0)), "fov_deg": _camera.fov,
		"soldier_at": [snappedf(soldier_at.x, 0.01), snappedf(soldier_at.y, 0.01), snappedf(soldier_at.z, 0.01)] if soldier_at != Vector3.INF else null,
		"sight": clear["sight"], "render_info_last_frame": info, "lights": lights, "image": stats,
	}
	print("PARITY_VIEW %s %dx%d err=%d ok=%s draw_calls=%d objects=%d omni_in_frustum=%d spot_in_frustum=%d mean_luma=%.3f sight=%s%s" % [
			path, img.get_width(), img.get_height(), err, r["ok"], int(info["draw_calls"]), int(info["objects"]),
			int(lights["omni_in_frustum"]), int(lights["spot_in_frustum"]), float(stats["mean_luma"]), clear["sight"],
			"" if problems.is_empty() else " PROBLEMS: " + "; ".join(problems)])
	return r


## Lights whose range sphere meets the camera frustum (geometry only: no occlusion, no per-object assignment),
## of the lights visible in the tree with energy > 0, past any distance fade excluded.
func _lights_in_frustum() -> Dictionary:
	var planes := _camera.get_frustum()
	var out := {"omni_total": 0, "spot_total": 0, "directional": 0, "omni_in_frustum": 0, "spot_in_frustum": 0,
			"omni_in_frustum_shadowed": 0, "nearest_in_frustum_m": -1.0}
	var nearest := INF
	for node in _lights:
		var light := node as Light3D
		if light == null or not is_instance_valid(light) or not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		if light is DirectionalLight3D:
			out["directional"] += 1
			continue
		var kind := "omni" if light is OmniLight3D else "spot"
		out[kind + "_total"] += 1
		var radius := (light as OmniLight3D).omni_range if light is OmniLight3D else (light as SpotLight3D).spot_range
		var centre := light.global_position
		var d := centre.distance_to(_camera.global_position)
		if light.distance_fade_enabled and d > light.distance_fade_begin + light.distance_fade_length:
			continue
		var inside := true
		for plane in planes:
			if plane.distance_to(centre) > radius:
				inside = false
				break
		if inside:
			out[kind + "_in_frustum"] += 1
			if light.shadow_enabled and kind == "omni":
				out["omni_in_frustum_shadowed"] += 1
			nearest = minf(nearest, d)
	if nearest < INF:
		out["nearest_in_frustum_m"] = snappedf(nearest, 0.1)
	return out


## Mean colour, mean luma and the fraction of pixels in the match's magenta clear colour, on an 8 px grid.
static func _image_stats(img: Image) -> Dictionary:
	var sum := Vector3.ZERO
	var magenta := 0
	var n := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			var c := img.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
			if c.r > 0.9 and c.g < 0.1 and c.b > 0.9:
				magenta += 1
			n += 1
	var mean := sum / maxf(1.0, n)
	return {"mean_rgb": [snappedf(mean.x, 0.001), snappedf(mean.y, 0.001), snappedf(mean.z, 0.001)],
			"mean_luma": snappedf(0.2126 * mean.x + 0.7152 * mean.y + 0.0722 * mean.z, 0.0001),
			"magenta_fraction": snappedf(magenta / maxf(1.0, n), 0.001), "samples": n}


## Whether the camera point is outside every collider (a 0.2 m sphere on the world mask), and what the line of sight
## meets first (as tools/m2w1_capture.gd).
func _clearance(at: Vector3, target: Vector3) -> Dictionary:
	var space := _camera.get_world_3d().direct_space_state
	var probe := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.2
	probe.shape = sphere
	probe.transform = Transform3D(Basis.IDENTITY, at)
	probe.collision_mask = Hitscan.MASK_WORLD
	var inside := space.intersect_shape(probe, 4)
	var names := PackedStringArray()
	for hit: Dictionary in inside:
		names.append(String((hit["collider"] as Node).name))
	var ray := space.intersect_ray(PhysicsRayQueryParameters3D.create(at, target, Hitscan.MASK_WORLD))
	var sight := "open_60m"
	if not ray.is_empty():
		sight = "%s@%.1fm" % [(ray["collider"] as Node).name, at.distance_to(ray["position"])]
	return {"clear": inside.is_empty(), "sight": sight if inside.is_empty() else "inside " + ",".join(names)}


func _run_report(cfg: Dictionary, renderer: String, map_path: String, seed_value: int) -> Dictionary:
	var env_node := _match.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env := env_node.environment if env_node != null else null
	var env_r := {}
	if env != null:
		env_r = {
			"background_mode": env.background_mode,
			"sky_material": _sky_material(env),
			"tonemap_mode": env.tonemap_mode, "tonemap_name": TONEMAP_NAMES.get(int(env.tonemap_mode), str(env.tonemap_mode)),
			"tonemap_exposure": env.tonemap_exposure, "tonemap_white": env.tonemap_white,
			"glow_enabled": env.glow_enabled, "glow_intensity": env.glow_intensity, "glow_strength": env.glow_strength,
			"glow_bloom": env.glow_bloom, "glow_hdr_threshold": env.glow_hdr_threshold, "glow_blend_mode": env.glow_blend_mode,
			"fog_enabled": env.fog_enabled, "fog_mode": env.fog_mode, "fog_density": env.fog_density,
			"fog_sun_scatter": env.fog_sun_scatter, "fog_aerial_perspective": env.fog_aerial_perspective,
			"fog_sky_affect": env.fog_sky_affect, "fog_height_density": env.fog_height_density,
			"volumetric_fog_enabled": env.volumetric_fog_enabled, "ssao_enabled": env.ssao_enabled,
			"ssr_enabled": env.ssr_enabled, "ssil_enabled": env.ssil_enabled, "sdfgi_enabled": env.sdfgi_enabled,
			"adjustment_enabled": env.adjustment_enabled, "adjustment_brightness": env.adjustment_brightness,
			"adjustment_contrast": env.adjustment_contrast, "adjustment_saturation": env.adjustment_saturation,
			"ambient_light_source": env.ambient_light_source, "ambient_light_energy": env.ambient_light_energy,
			"reflected_light_source": env.reflected_light_source,
		}
	var sun := _match.get_node_or_null("Light") as DirectionalLight3D
	var sun_r := {}
	if sun != null:
		sun_r = {"energy": sun.light_energy, "color": [sun.light_color.r, sun.light_color.g, sun.light_color.b],
				"rotation_deg": [sun.rotation_degrees.x, sun.rotation_degrees.y, sun.rotation_degrees.z],
				"shadow_enabled": sun.shadow_enabled, "shadow_mode": sun.directional_shadow_mode,
				"shadow_max_distance": sun.directional_shadow_max_distance}
	return {
		"tool": "tools/parity_capture.gd",
		"rendering_method": renderer,
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"project_rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"video_adapter_api": RenderingServer.get_video_adapter_api_version(),
		"godot": Engine.get_version_info()["string"],
		"variant": _variant, "seed": seed_value, "map": map_path,
		"window": [root.size.x, root.size.y], "settle_frames": _settle,
		"first_settle_frames": int(cfg.get("first_settle_frames", 180)),
		"viewport": {"msaa_3d": root.msaa_3d, "scaling_3d_scale": root.scaling_3d_scale, "scaling_3d_mode": root.scaling_3d_mode,
				"screen_space_aa": root.screen_space_aa, "use_hdr_2d": root.use_hdr_2d},
		"limits": {
			"opengl_max_renderable_lights": ProjectSettings.get_setting("rendering/limits/opengl/max_renderable_lights"),
			"opengl_max_lights_per_object": ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object"),
			"opengl_max_renderable_elements": ProjectSettings.get_setting("rendering/limits/opengl/max_renderable_elements"),
		},
		"camera": {"near": _camera.near, "far": _camera.far, "keep_aspect": _camera.keep_aspect},
		"director_running": bool((_match.get("director") as MatchDirector).running),
		"lights_in_scene": _lights.size(),
		"environment": env_r,
		"sun": sun_r,
	}


static func _sky_material(env: Environment) -> String:
	if env.sky == null or env.sky.sky_material == null:
		return "none"
	var mat := env.sky.sky_material
	if mat is ShaderMaterial and (mat as ShaderMaterial).shader != null:
		return "ShaderMaterial:" + (mat as ShaderMaterial).shader.resource_path
	return mat.get_class()


# --- sheet mode ---

func _build_sheets(cfg: Dictionary) -> bool:
	var made := 0
	var failed := 0
	for view: Dictionary in cfg["views"]:
		var view_name := String(view["name"])
		if _only != "" and not view_name.contains(_only):
			continue
		for variant in _variants:
			var lp := (_left_dir if _left_dir != "" else _out).path_join("%s_%s_%s.png" % [view_name, variant, LEFT])
			var rp := _out.path_join("%s_%s_%s.png" % [view_name, variant, _right])
			var have_l := FileAccess.file_exists(lp)
			var have_r := FileAccess.file_exists(rp)
			if not have_l and not have_r:
				print("PARITY_SHEET_SKIP %s %s: neither capture" % [view_name, variant])
				continue
			if not (have_l and have_r):
				print("PARITY_SHEET_MISSING %s" % (rp if have_l else lp))
				failed += 1
				continue
			var l := Image.load_from_file(lp)
			var r := Image.load_from_file(rp)
			if l == null or r == null:
				print("PARITY_SHEET_BAD %s %s" % [lp, rp])
				failed += 1
				continue
			l.convert(Image.FORMAT_RGB8)
			r.convert(Image.FORMAT_RGB8)
			var exact := _exact_diff(l, r)
			var w := maxi(1, int(l.get_width() * _scale))
			var h := maxi(1, int(l.get_height() * _scale))
			l.resize(w, h, Image.INTERPOLATE_LANCZOS)
			r.resize(w, h, Image.INTERPOLATE_LANCZOS)
			var px := 4 if w >= 800 else 2
			var bar := 5 * px + 4 * px
			var gap := 8
			var sheet := Image.create(w * 2 + gap, h + bar, false, Image.FORMAT_RGB8)
			sheet.fill(Color(0.06, 0.06, 0.07))
			sheet.blit_rect(l, Rect2i(Vector2i.ZERO, Vector2i(w, h)), Vector2i(0, bar))
			sheet.blit_rect(r, Rect2i(Vector2i.ZERO, Vector2i(w, h)), Vector2i(w + gap, bar))
			var left_label := "MOBILE BEFORE" if _left_dir != "" else "MOBILE"
			_text(sheet, "%s  %s  %s" % [left_label, view_name, variant], Vector2i(2 * px, 2 * px), px, Color(1, 1, 1))
			_text(sheet, "%s  %s  %s" % [_right.to_upper(), view_name, variant], Vector2i(w + gap + 2 * px, 2 * px), px, Color(1, 0.85, 0.4))
			var suffix := "" if _right == RIGHT else "_vs_" + _right
			var out := _out.path_join("sheet_%s_%s%s.png" % [view_name, variant, suffix])
			var err := sheet.save_png(out)
			print("PARITY_SHEET %s %dx%d err=%d mean_abs_diff_0_255=%.2f full_res_pixels_differing=%d max_channel_diff=%d" % [
					out, sheet.get_width(), sheet.get_height(), err, _mean_abs_diff(l, r), exact.x, exact.y])
			if err != OK:
				failed += 1
			else:
				made += 1
	print("PARITY_SHEETS made=%d failed=%d" % [made, failed])
	return failed == 0 and made > 0


## W1a: every pixel of two same-size RGB8 images: (pixels that differ at all, the largest channel difference 0..255).
## (-1, -1) when the sizes differ.
static func _exact_diff(a: Image, b: Image) -> Vector2i:
	if a.get_size() != b.get_size():
		return Vector2i(-1, -1)
	var da := a.get_data()
	var db := b.get_data()
	var pixels := 0
	var worst := 0
	var i := 0
	while i < da.size():
		var d := maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), absi(da[i + 2] - db[i + 2]))
		if d > 0:
			pixels += 1
			worst = maxi(worst, d)
		i += 3
	return Vector2i(pixels, worst)


## Mean absolute per-channel difference of two same-size images, 0..255, on a 4 px grid.
static func _mean_abs_diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 3
	return sum / maxf(1.0, n) * 255.0


## A 3x5 pixel font (upper case, digits, a few marks), each cell px x px: labels without a font or a renderer.
const GLYPHS := {
	"A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
	"E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
	"I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
	"M": "101111111101101", "N": "110101101101101", "O": "010101101101010", "P": "110101110100100",
	"Q": "010101101110011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
	"U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
	"Y": "101101010010010", "Z": "111001010100111",
	"0": "111101101101111", "1": "010110010010111", "2": "110001010100111", "3": "110001010001110",
	"4": "101101111001001", "5": "111100110001110", "6": "011100111101111", "7": "111001010010010",
	"8": "111101111101111", "9": "111101111001110",
	"_": "000000000000111", "-": "000000111000000", ".": "000000000000010", ":": "000010000010000",
	"(": "001010010010001", ")": "100010010010100", "/": "001001010100100", "=": "000111000111000",
}


static func _text(img: Image, text: String, at: Vector2i, px: int, color: Color) -> void:
	var x := at.x
	for ch in text.to_upper():
		var g := String(GLYPHS.get(ch, "000000000000000"))
		for i in 15:
			if g[i] == "1":
				var cx := x + (i % 3) * px
				var cy := at.y + (i / 3) * px
				if cx + px <= img.get_width() and cy + px <= img.get_height():
					img.fill_rect(Rect2i(cx, cy, px, px), color)
		x += 4 * px
