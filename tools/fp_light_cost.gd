extends SceneTree
## M2 AN1 commit 5: desktop cost of the first-person muzzle flash + muzzle light (one shadowless OmniLight3D on the
## local player's view model), for this PC only (not a phone number):
##   godot --path . --resolution 1920x824 --log-file build/fp_light.log --script tools/fp_light_cost.gd -- --frames=200 --rounds=4
## Starts the same offline 18-player match as tools/frame_time.gd (fixed seed, everyone on the map, vsync and the frame
## cap off), waits for the local view model, lets 120 frames pass, then alternates blocks of --frames frames with the
## flash and light held OFF and held ON (ViewModel.hold_muzzle_flash) for --rounds rounds, so drift cancels out, and
## prints the averages of each: whole frame ms, render CPU / GPU ms, draw calls, primitives. A transient light cannot be
## compared before / after across runs; this holds it on long enough to measure. Reads only; changes no game code.

func _initialize() -> void:
	var frames := 200
	var rounds := 4
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			frames = int(arg.substr(9))
		elif arg.begins_with("--rounds="):
			rounds = int(arg.substr(9))
	await process_frame
	var match_scene: Node = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = true
	match_scene.seed_override = 20261109
	root.add_child(match_scene)
	await process_frame
	match_scene.director.load_config()
	if not match_scene.begin():
		print("FP_LIGHT match did not start")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var vm: ViewModel = null
	for i in 600:
		await process_frame
		vm = root.find_child(ViewModel.NODE_NAME, true, false) as ViewModel
		if vm != null and vm.visible and vm.get_shown_weapon() != null and vm.get_shown_weapon().has_node("Muzzle"):
			break
	if vm == null or vm.get_shown_weapon() == null or not vm.get_shown_weapon().has_node("Muzzle"):
		print("FP_LIGHT no first-person view model with a gun")
		quit(1)
		return
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	for i in 120:
		await process_frame
	var sums := {false: [0.0, 0.0, 0.0, 0.0, 0.0], true: [0.0, 0.0, 0.0, 0.0, 0.0]}
	for r in rounds:
		for on in [false, true]:
			vm.hold_muzzle_flash(on)
			for i in 10:  # settle
				await process_frame
			var started := Time.get_ticks_usec()
			var s: Array = sums[on]
			for i in frames:
				await process_frame
				s[1] += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) + RenderingServer.get_frame_setup_time_cpu()
				s[2] += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
				s[3] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
				s[4] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			s[0] += (Time.get_ticks_usec() - started) / 1000.0
			if on and not vm.is_muzzle_light_on():
				print("FP_LIGHT warning: the light was not on during an ON block")
	vm.hold_muzzle_flash(false)
	var n := float(frames * rounds)
	var size := root.get_viewport().get_visible_rect().size
	for on in [false, true]:
		var s: Array = sums[on]
		print("FP_LIGHT desktop, not device: renderer=%s size=%dx%d light=%s frames=%d frame_ms=%.3f render_cpu_ms=%.3f render_gpu_ms=%.3f draw_calls=%.1f primitives=%.0f" % [
				str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), int(size.x), int(size.y), "ON" if on else "OFF",
				int(n), s[0] / n, s[1] / n, s[2] / n, s[3] / n, s[4] / n])
	var off: Array = sums[false]
	var onv: Array = sums[true]
	print("FP_LIGHT delta (on - off): frame_ms=%+.3f render_cpu_ms=%+.3f render_gpu_ms=%+.3f draw_calls=%+.1f primitives=%+.0f" % [
			(onv[0] - off[0]) / n, (onv[1] - off[1]) / n, (onv[2] - off[2]) / n, (onv[3] - off[3]) / n, (onv[4] - off[4]) / n])
	quit()
