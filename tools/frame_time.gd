extends SceneTree
## Desktop render time of a running match, for before / after comparisons on this PC (not a phone number):
##   godot --path . --resolution 1920x824 --script res://tools/frame_time.gd [-- --variant=storm --frames=400]
## Starts an offline 18-player match with a fixed seed (no drop: everyone stands on the map), turns vsync and
## the frame cap off, lets 120 frames pass, then averages the viewport's measured CPU and GPU render times,
## the whole frame time and the renderer's draw call and primitive counts over the next frames.
## --off=<preset keys> switches single effects off for the run (GraphicsPresets.overrides), so each effect's
## cost on this PC can be read as a difference.

func _initialize() -> void:
	var frames := 400
	var variant := ""
	var off := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			frames = int(arg.substr(9))
		elif arg.begins_with("--variant="):
			variant = arg.substr(10)
		elif arg.begins_with("--off="):  # preset switches to turn off for this run, e.g. --off=art_glow_enabled,art_weather_enabled
			for key in arg.substr(6).split(","):
				off[key] = false
	await process_frame
	# The look variant exists from the S1 commit on; an older checkout has no such script and ignores the flag.
	if variant != "" and ResourceLoader.exists("res://scripts/visual/match_look.gd"):
		load("res://scripts/visual/match_look.gd").variant_override = variant
	if not off.is_empty():
		GraphicsPresets.overrides = off
	var match_scene: Node = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = true
	match_scene.seed_override = 20261109
	root.add_child(match_scene)
	await process_frame
	match_scene.director.load_config()
	if not match_scene.begin():
		print("FRAME_TIME match did not start")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	for i in 120:
		await process_frame
	var cpu := 0.0
	var gpu := 0.0
	var draws := 0.0
	var primitives := 0.0
	var worst := 0.0
	var started := Time.get_ticks_usec()
	var last := started
	for i in frames:
		await process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) + RenderingServer.get_frame_setup_time_cpu()
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var whole := (Time.get_ticks_usec() - started) / 1000.0 / frames
	var size := root.get_viewport().get_visible_rect().size
	print("FRAME_TIME desktop, not device: renderer=%s size=%dx%d variant=%s frames=%d frame_ms=%.2f worst_ms=%.1f render_cpu_ms=%.2f render_gpu_ms=%.2f draw_calls=%.0f primitives=%.0f texture_mem_mb=%.1f video_mem_mb=%.1f" % [
			str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), int(size.x), int(size.y), variant if variant != "" else "(data)", frames,
			whole, worst, cpu / frames, gpu / frames, draws / frames, primitives / frames,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0])
	quit()
