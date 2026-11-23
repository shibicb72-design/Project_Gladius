extends "res://tests/test_case.gd"
## W1a commit 2: the PC graphics presets (data/graphics_presets.json pc_medium / pc_high, GraphicsPresets active id),
## the choice by platform (PlatformServices.is_pc, Boot), the PC Settings rows and their save keys, the camera far
## plane (data/camera.json far_m, OQ-WEB-FAR) and the Field of view setting. Every test puts back every engine value,
## static hook and profile it changes (_snap / _restore).

const TMP := "user://test_w1a_gfx_profile.json"
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const EPS := 1e-4
## The "default" preset exactly as before W1a (data/graphics_presets.json at ea3b8d2; JSON numbers load as floats).
const DEFAULT_PRESET := {"max_fps": 60.0, "msaa_3d": 0.0, "scale_3d": 1.0, "art_shadows_enabled": true,
		"art_fog_enabled": true, "art_glow_enabled": true, "art_ambient_enabled": true, "art_grade_enabled": true,
		"art_weather_enabled": true, "art_shafts_enabled": true, "art_vignette_enabled": true,
		"art_backdrop_enabled": true, "art_debanding_enabled": true, "art_world_kit_enabled": true,
		"art_ground_detail_enabled": true, "art_clutter_enabled": true, "fx_ssr_enabled": false,
		"fx_ssao_enabled": false, "fx_ssil_enabled": false, "fx_volumetric_fog_enabled": false}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i: int in n:
		await _tree().process_frame


## Everything a test here may change.
func _snap() -> Dictionary:
	var vp := _tree().root
	return {"fps": Engine.max_fps, "scale": vp.scaling_3d_scale, "msaa": vp.msaa_3d, "aniso": vp.anisotropic_filtering_level,
			"vsync": DisplayServer.window_get_vsync_mode(), "profile": AppFlow.profile.duplicate(true),
			"overrides": GraphicsPresets.overrides.duplicate(true)}


func _restore(s: Dictionary) -> void:
	var vp := _tree().root
	Engine.max_fps = int(s["fps"])
	vp.scaling_3d_scale = float(s["scale"])
	vp.msaa_3d = s["msaa"]
	vp.anisotropic_filtering_level = s["aniso"]
	DisplayServer.window_set_vsync_mode(s["vsync"])
	RenderingServer.directional_shadow_atlas_set_size(GraphicsPresets.project_shadow_atlas_size(), GraphicsPresets.project_shadow_atlas_16_bits())
	AppFlow.profile = s["profile"]
	GraphicsPresets.overrides = s["overrides"]
	GraphicsPresets.active_id = ""
	GraphicsPresets.applied = {}
	PlatformServices.simulate_pc = false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _presets() -> Dictionary:
	return GraphicsPresets.config()["presets"]


func test_default_preset_is_unchanged_and_pc_presets_are_complete() -> void:
	var presets := _presets()
	assert_eq(presets["default"], DEFAULT_PRESET, "the default (Low) preset is byte for byte today's")
	assert_eq(str(GraphicsPresets.config()["default"]), "default", "the file default is still \"default\"")
	for id: String in ["pc_medium", "pc_high"]:
		assert_true(presets.has(id), "%s exists" % id)
		var p: Dictionary = presets.get(id, {})
		for key: String in presets["default"]:
			assert_true(p.has(key), "%s has the default's key %s" % [id, key])
		for key: String in ["vsync", "directional_shadow_size", "anisotropic_level", "shadow_max_distance_m", "shadow_mode"]:
			assert_true(p.has(key), "%s has the W1a key %s" % [id, key])
		assert_true(p.get("_placeholder", false) == true, "%s is marked a placeholder" % id)
		assert_true(int(p["msaa_3d"]) in [2, 4], "%s MSAA 2x or 4x" % id)
		assert_true(str(p["shadow_mode"]) in ["pssm2", "pssm4"], "%s PSSM sun shadows" % id)
		assert_true(float(p["shadow_max_distance_m"]) > 70.0, "%s shadows reach further than today's 70 m" % id)
		assert_eq(float(p["scale_3d"]), 1.0, "%s full 3D scale" % id)
		assert_eq(int(p["max_fps"]), 0, "%s no preset fps cap" % id)
		assert_eq(p["vsync"], true, "%s vsync on" % id)
		assert_true(GraphicsPresets.ANISO_LEVELS.has(int(p["anisotropic_level"])), "%s anisotropic level is 1/2/4/8/16" % id)
	for id: String in presets:
		for key: String in presets[id]:
			if key.begins_with("fx_"):
				assert_eq(presets[id][key], false, "%s: %s stays off" % [id, key])
	assert_eq(GraphicsPresets.quality_ids(), ["", "default", "pc_medium", "pc_high"], "quality levels Auto / Low / Medium / High")


func test_get_preset_follows_the_active_id_and_overrides_merge_on_top() -> void:
	var s := _snap()
	var gp := GraphicsPresets.new()
	assert_eq(GraphicsPresets.active_id, "", "no active id outside Boot")
	assert_eq(gp.get_preset(), _presets()["default"], "\"\" = the default preset until one is set")
	GraphicsPresets.active_id = "pc_high"
	assert_eq(gp.get_preset(), _presets()["pc_high"], "\"\" follows the active id")
	assert_eq(gp.get_preset("pc_medium"), _presets()["pc_medium"], "an explicit id still wins")
	GraphicsPresets.overrides = {"art_glow_enabled": false, "msaa_3d": 0}
	var p := gp.get_preset()
	assert_eq(p["art_glow_enabled"], false, "overrides merge on top of the active preset")
	assert_eq(p["msaa_3d"], 0, "an override replaces the active preset's value")
	assert_eq(p["shadow_mode"], "pssm4", "the rest is the active preset's")
	_restore(s)
	assert_eq(gp.get_preset(), _presets()["default"], "restored")


func test_choose_id_by_platform_and_saved_quality() -> void:
	assert_eq(GraphicsPresets.choose_id("", true), "pc_high", "Auto on a PC = pc_high")
	assert_eq(GraphicsPresets.choose_id("", false), "default", "not a PC: default")
	assert_eq(GraphicsPresets.choose_id("pc_medium", true), "pc_medium", "a saved quality wins over Auto on a PC")
	assert_eq(GraphicsPresets.choose_id("default", true), "default", "Low saved on a PC")
	assert_eq(GraphicsPresets.choose_id("pc_high", false), "default", "the PC-only setting is ignored off a PC")
	assert_eq(GraphicsPresets.choose_id("ultra", true), "pc_high", "an unknown saved id means Auto")


func test_is_pc_is_false_headless_and_simulated_true() -> void:
	var ps := PlatformServices.new()
	assert_eq(DisplayServer.get_name(), "headless", "this suite runs headless")
	assert_true(not ps.is_pc(), "a headless run is not a PC (keeps the default preset)")
	PlatformServices.simulate_web = true
	assert_true(not ps.is_pc(), "simulate_web alone does not make a headless run a PC")
	PlatformServices.simulate_web = false
	PlatformServices.simulate_pc = true
	assert_true(ps.is_pc(), "simulate_pc forces the PC branch")
	PlatformServices.simulate_pc = false


func test_apply_sets_and_restores_every_live_key() -> void:
	var s := _snap()
	var vp := _tree().root
	var gp := GraphicsPresets.new()
	var p := gp.apply("pc_high", vp)
	assert_eq(Engine.max_fps, 0, "pc_high: no preset fps cap")
	assert_eq(vp.msaa_3d, Viewport.MSAA_4X, "pc_high: MSAA 4x")
	assert_eq(vp.scaling_3d_scale, 1.0, "pc_high: scale 1.0")
	assert_eq(vp.anisotropic_filtering_level, GraphicsPresets.ANISO_LEVELS[int(p["anisotropic_level"])], "pc_high: anisotropic level")
	assert_eq(GraphicsPresets.applied.get("vsync"), true, "pc_high: vsync handed to the DisplayServer")
	assert_eq(GraphicsPresets.applied.get("directional_shadow_size"), int(p["directional_shadow_size"]), "pc_high: shadow atlas size")
	gp.apply("pc_medium", vp)
	assert_eq(vp.msaa_3d, Viewport.MSAA_2X, "pc_medium: MSAA 2x")
	assert_eq(GraphicsPresets.applied.get("directional_shadow_size"), int(_presets()["pc_medium"]["directional_shadow_size"]), "pc_medium: atlas")
	# Back to Low: the project's own values return and nothing PC is left recorded.
	gp.apply("default", vp)
	assert_eq(Engine.max_fps, 60, "default: 60 fps")
	assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "default: no MSAA")
	assert_eq(vp.anisotropic_filtering_level, GraphicsPresets.project_anisotropy(), "default: project anisotropy")
	assert_true(GraphicsPresets.applied.is_empty(), "default: no PC value left (%s)" % GraphicsPresets.applied)
	_restore(s)


func test_frame_cap_and_render_scale_layer_on_the_preset() -> void:
	var s := _snap()
	var vp := _tree().root
	var gp := GraphicsPresets.new()
	var p := gp.apply("pc_high", vp)
	for cap: int in [60, 120, 144, 0]:
		gp.apply_user_layer({"frame_cap": cap, "render_scale": 0.75}, vp, p)
		assert_eq(Engine.max_fps, cap, "frame cap %d applied" % cap)
		assert_true(absf(vp.scaling_3d_scale - 0.75) < EPS, "render scale 0.75 x scale_3d 1.0")
	gp.apply_user_layer({"frame_cap": 999, "render_scale": 3.0}, vp, p)
	assert_eq(Engine.max_fps, SaveService.FRAME_CAP_DEFAULT, "a bad frame cap means the default")
	assert_eq(vp.scaling_3d_scale, 1.0, "a bad render scale means 1.0")
	# apply_settings: the saved quality and the layer on a PC; the default preset alone off a PC.
	gp.apply_settings({"graphics_quality": "pc_medium", "frame_cap": 120, "render_scale": 0.5}, vp, true)
	assert_eq(GraphicsPresets.active_id, "pc_medium", "PC: the saved quality is active")
	assert_eq(Engine.max_fps, 120, "PC: the frame cap is layered")
	assert_true(absf(vp.scaling_3d_scale - 0.5) < EPS, "PC: the render scale is layered")
	gp.apply_settings({"graphics_quality": "pc_medium", "frame_cap": 120, "render_scale": 0.5}, vp, false)
	assert_eq(GraphicsPresets.active_id, "default", "not a PC: default")
	assert_eq(Engine.max_fps, 60, "not a PC: the preset's 60 fps, no layer")
	assert_eq(vp.scaling_3d_scale, 1.0, "not a PC: no render scale")
	_restore(s)
	assert_eq(Engine.max_fps, int(s["fps"]), "frame cap restored")


func test_boot_picks_the_preset_by_platform() -> void:
	var s := _snap()
	var vp := _tree().root
	for pc: bool in [false, true]:
		PlatformServices.simulate_pc = pc
		var boot: Boot = load("res://scenes/boot/boot.tscn").instantiate()
		boot.auto_advance = false
		boot.navigate = func() -> void: pass
		_tree().root.add_child(boot)
		await _frames(2)
		var want := GraphicsPresets.choose_id(SaveService.graphics_quality(AppFlow.profile.get("graphics_quality", null)), pc)
		assert_eq(GraphicsPresets.active_id, want, "Boot (pc=%s) picks %s" % [pc, want])
		if pc:
			assert_true(want != "default" or str(AppFlow.profile.get("graphics_quality", "")) == "default", "a PC with Auto gets a PC preset")
			assert_eq(Engine.max_fps, SaveService.frame_cap(AppFlow.profile.get("frame_cap", null)), "PC: the saved frame cap")
		else:
			assert_eq(want, "default", "headless: default")
			assert_eq(Engine.max_fps, 60, "headless: today's 60 fps")
			assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "headless: today's MSAA")
		boot.queue_free()
		await _frames(1)
		_restore(s)


func test_greybox_reads_the_preset_shadow_keys_on_the_next_match() -> void:
	var s := _snap()
	for id: String in ["pc_high", ""]:
		GraphicsPresets.active_id = id
		var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
		match_scene.auto_start = false
		_tree().root.add_child(match_scene)
		var sun := match_scene.get_node("Light") as DirectionalLight3D
		var fog: Dictionary = MatchLook.resolved()["fog"]
		if id == "pc_high":
			assert_eq(sun.directional_shadow_mode, DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "pc_high: PSSM 4 splits")
			assert_eq(sun.directional_shadow_max_distance, float(_presets()["pc_high"]["shadow_max_distance_m"]), "pc_high: its distance")
		else:
			assert_eq(sun.directional_shadow_mode, DirectionalLight3D.SHADOW_ORTHOGONAL if fog["shadow_mode"] == "orthogonal" else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "default: today's mode")
			assert_eq(sun.directional_shadow_max_distance, float(fog["shadow_max_distance_m"]), "default: today's data distance")
		match_scene.free()
	_restore(s)


func test_settings_round_trip_and_bad_values() -> void:
	var s := _snap()
	var save := SaveService.new(TMP)
	var d := SaveService.defaults()
	assert_eq(d["graphics_quality"], "", "default quality Auto")
	assert_eq(d["frame_cap"], 60, "default frame cap 60")
	assert_eq(d["render_scale"], 1.0, "default render scale 1.0")
	assert_eq(d["fov"], "", "default fov Auto")
	var p := save.load_profile()
	p["graphics_quality"] = "pc_medium"
	p["frame_cap"] = 144
	p["render_scale"] = 0.65
	p["fov"] = 80.0
	assert_true(save.save_profile(p), "saved")
	var back := save.load_profile()
	assert_eq(back["graphics_quality"], "pc_medium", "quality round trip")
	assert_eq(back["frame_cap"], 144, "frame cap round trip (an int after JSON)")
	assert_true(absf(float(back["render_scale"]) - 0.65) < EPS, "render scale round trip")
	assert_true(back["fov"] is float and absf(float(back["fov"]) - 80.0) < EPS, "fov round trip")
	p["fov"] = ""
	p["frame_cap"] = 0
	save.save_profile(p)
	back = save.load_profile()
	assert_eq(back["fov"], "", "fov Auto round trip")
	assert_eq(back["frame_cap"], 0, "Unlimited round trip")
	# One bad value per key, written straight to the file: each falls back to its default.
	var bad := {"graphics_quality": "ultra", "frame_cap": 75, "render_scale": 0.2, "fov": 170}
	for key: String in bad:
		var raw := save.load_profile()
		raw[key] = bad[key]
		var f := FileAccess.open(TMP, FileAccess.WRITE)
		f.store_string(JSON.stringify(raw))
		f.close()
		assert_eq(save.load_profile()[key], d[key], "bad %s (%s) falls back to the default" % [key, bad[key]])
	assert_eq(SaveService.graphics_quality(3), "", "a non-string quality means Auto")
	assert_eq(SaveService.frame_cap("120"), 60, "a string frame cap means the default")
	assert_eq(SaveService.frame_cap(120.5), 60, "a fractional frame cap means the default")
	assert_eq(SaveService.render_scale("x"), 1.0, "a string render scale means 1.0")
	assert_eq(SaveService.fov("90"), "", "a string fov means Auto")
	_restore(s)


func test_settings_rows_are_pc_only_and_apply_live() -> void:
	var s := _snap()
	var vp := _tree().root
	# Not a PC (headless): no GRAPHICS rows, and saving leaves the stored values alone.
	var panel := SettingsPanel.new()
	panel.save = SaveService.new(TMP)
	vp.add_child(panel)
	assert_true(not panel.graphics_built and panel.quality_button == null, "headless: no graphics rows")
	assert_true(not panel.fields().has("frame_cap"), "headless: the panel does not own the graphics keys")
	panel.free()
	PlatformServices.simulate_pc = true
	panel = SettingsPanel.new()
	panel.save = SaveService.new(TMP)
	vp.add_child(panel)
	assert_true(panel.graphics_built, "PC: graphics rows built")
	assert_true(panel.quality_button.visible and panel.frame_cap_button.visible, "PC: Quality and Frame cap show")
	var adv := SettingsPanel.show_advanced_graphics()
	assert_eq(panel.fov_button.visible, adv, "Field of view follows show_advanced_graphics")
	assert_eq(panel.render_scale_slider.visible, adv, "Render scale follows show_advanced_graphics")
	assert_eq(panel.quality_button.text, "Quality: Auto", "Auto by default")
	assert_eq(panel.frame_cap_button.text, "Frame cap: 60 fps", "60 fps by default")
	assert_eq(SettingsPanel.frame_cap_choices(), [60, 120] if not adv else [60, 120, 144, 0], "the frame caps the row offers")
	panel.cycle_quality()  # Auto -> Low
	assert_eq(panel.quality_button.text, "Quality: Low", "cycles to Low")
	panel.cycle_quality()  # -> Medium
	assert_eq(SaveService.new(TMP).load_profile()["graphics_quality"], "pc_medium", "saved at once")
	assert_eq(GraphicsPresets.active_id, "pc_medium", "applied at once")
	assert_eq(vp.msaa_3d, Viewport.MSAA_2X, "Medium's MSAA live")
	panel.cycle_frame_cap()
	assert_eq(panel.frame_cap_button.text, "Frame cap: 120 fps", "cycles to 120")
	assert_eq(Engine.max_fps, 120, "frame cap live")
	assert_eq(AppFlow.profile["frame_cap"], 120, "AppFlow.profile updated")
	panel.render_scale_slider.value = 0.8
	assert_true(absf(vp.scaling_3d_scale - 0.8) < 0.01, "render scale live")
	assert_eq(panel.render_scale_label.text, "Render scale: 80%", "render scale text")
	panel.cycle_fov()
	assert_true(panel.fov is float, "Field of view leaves Auto")
	assert_eq(SaveService.new(TMP).load_profile()["fov"], panel.fov, "fov saved")
	panel.free()
	_restore(s)


func test_fov_setting_replaces_base_fov_only() -> void:
	var s := _snap()
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig: CameraRig = _RigScene.instantiate()
	root.add_child(rig)
	await _frames(2)
	var cfg := DataRegistry.new().get_camera_cfg()
	var size := rig.get_viewport().get_visible_rect().size
	var table := CameraRig.fov_for_aspect(cfg, size.x / size.y)
	assert_true(absf(rig.base_fov - table) < EPS, "headless: the aspect table")
	AppFlow.profile = {"fov": 80.0}
	rig.apply_fov()
	assert_true(absf(rig.base_fov - table) < EPS, "not a PC: a saved fov is ignored")
	PlatformServices.simulate_pc = true
	AppFlow.profile = {"fov": ""}
	_tree().call_group(CameraRig.GROUP, "apply_fov")
	assert_true(absf(rig.base_fov - table) < EPS, "PC, \"\" = Auto = the aspect table")
	AppFlow.profile = {"fov": 80.0}
	_tree().call_group(CameraRig.GROUP, "apply_fov")
	assert_true(absf(rig.base_fov - 80.0) < EPS, "PC: the saved fov replaces base_fov (%s)" % rig.base_fov)
	rig.set_aim_blend(1.0, 0.6)
	assert_true(absf(rig.get_fov() - 80.0 * 0.6) < EPS, "the aim multiplier still applies (%s)" % rig.get_fov())
	rig.set_aim_blend(0.0, 1.0)
	rig._set_fp_weight(1.0)
	rig._apply_zoom()
	var fp_mult := float(cfg["first_person"]["fov_mult"]["value"])
	assert_true(absf(rig.get_fov() - 80.0 * fp_mult) < EPS, "the first-person multiplier still applies")
	AppFlow.profile = {"fov": 300.0}
	rig.apply_fov()
	assert_true(absf(rig.base_fov - table) < EPS, "an out-of-range fov means Auto")
	root.queue_free()
	await _frames(1)
	_restore(s)


func test_far_plane_from_data_reaches_the_farthest_backdrop() -> void:
	var cfg := DataRegistry.new().get_camera_cfg()
	var far_m := float(cfg["far_m"]["value"])
	var margin := float(cfg["far_margin_m"]["value"])
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig: CameraRig = _RigScene.instantiate()
	root.add_child(rig)
	await _frames(1)
	assert_eq(rig.get_camera().far, far_m, "the rig camera's far = camera.json far_m")
	root.queue_free()
	await _frames(1)
	# The farthest Hills vertex seen from any corner of each map's ground square (the maps with a far backdrop).
	var farthest := 0.0
	for path: String in ["res://data/maps/alesia_1km.json", "res://data/maps/alesia_500.json"]:
		var def := DataRegistry.parse_quiet(path)
		var map: Node3D = load(String(def["scene"])).instantiate()
		map.get_node("ArtBuilder").set("map_json", path)
		_tree().root.add_child(map)
		var half := float(map.get_node("ArtBuilder").get("ground_size_m")) * 0.5
		var hills := map.get_node_or_null("ArtBuilder/Backdrop/Hills") as MeshInstance3D
		assert_true(hills != null and half > 0.0, "%s builds its far hills" % path)
		if hills != null:
			var xf := hills.global_transform
			for v: Vector3 in hills.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
				var w := xf * v
				for corner: Vector3 in [Vector3(half, 0, half), Vector3(-half, 0, half), Vector3(half, 0, -half), Vector3(-half, 0, -half)]:
					farthest = maxf(farthest, corner.distance_to(w))
		map.free()
	print("W1A_FAR far_m=%.0f farthest_hill_from_corner_m=%.0f margin_m=%.0f" % [far_m, farthest, margin])
	assert_true(farthest > 1000.0, "measured a real backdrop (%.0f m)" % farthest)
	assert_true(far_m >= farthest + margin, "far %.0f m >= farthest hill %.0f m + margin %.0f m" % [far_m, farthest, margin])
