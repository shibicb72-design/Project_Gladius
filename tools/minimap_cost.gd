extends SceneTree
## M2 H1b commit 3: desktop cost of the HUD minimap (scripts/ui/hud_minimap.gd), for this PC only (not a phone number):
##   godot --path . --resolution 2520x1080 --log-file <log> --script res://tools/minimap_cost.gd -- --frames=300 --rounds=4
## Starts an offline 18-player squads match on alesia_1km (fixed seed, no drop, idle bots: their brains are off so the
## scene is the same in every block), vsync and the frame cap off, lets 120 frames pass, then alternates blocks of
## --frames frames with the minimap OFF (data switch minimap.enabled false, in memory), SMALL rotating, SMALL north up
## and EXPANDED, for --rounds rounds so drift cancels out. Prints per state: whole frame ms, render CPU / GPU ms, draw
## calls, primitives, and the minimap node's own script time per frame (HudMinimap.cost_usec). Changes no game code.
## M2 H1b commit 4: with --radar, the states are the radar's instead (the minimap on, small, rotating, in all of them):
## radar_off (radar.enabled false, in memory), radar_on (the data default, sweep on) and radar_nosweep; 6 enemies and 2
## squad mates are moved inside 25 m of the player first, so the radar draws 8 blips. Script time = HudRadar.cost_usec.

const MAP := "res://data/maps/alesia_1km.json"
const STATES := ["off", "small_rotate", "small_north", "expanded"]
const RADAR_STATES := ["radar_off", "radar_on", "radar_nosweep"]


func _initialize() -> void:
	var frames := 300
	var rounds := 4
	var radar_mode := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			frames = int(arg.substr(9))
		elif arg.begins_with("--rounds="):
			rounds = int(arg.substr(9))
		elif arg == "--radar":
			radar_mode = true
	await process_frame
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 20261109
	m.map_path_override = MAP
	root.add_child(m)
	await process_frame
	m.director.load_config(MAP)
	m.director.mode_cfg["teams"]["mode"]["value"] = "squads"
	if not m.begin():
		print("MINIMAP_COST match did not start")
		quit(1)
		return
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var mm: HudMinimap = m.hud.minimap
	var rd: HudRadar = m.hud.radar
	var mcfg: Dictionary = HudArrangement.ui()["minimap"]
	var rcfg: Dictionary = HudArrangement.ui()["radar"]
	var states: Array = RADAR_STATES if radar_mode else STATES
	if radar_mode:
		_place_near(m)
	else:
		rcfg["enabled"] = false  # commit 3's numbers: the minimap alone
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	for i in 120:
		await process_frame
	var sums := {}
	for s in states:
		sums[s] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for r in rounds:
		for s: String in states:
			if radar_mode:
				mcfg["enabled"] = true
				AppFlow.profile = {"minimap_rotate": true}
				mm.set_expanded(false)
				rcfg["enabled"] = s != "radar_off"
				rcfg["sweep"]["enabled"] = s == "radar_on"
			else:
				mcfg["enabled"] = s != "off"
				AppFlow.profile = {"minimap_rotate": s != "small_north"}
				mm.set_expanded(s == "expanded")
			for i in 10:  # settle
				await process_frame
			var started := Time.get_ticks_usec()
			var cost0 := rd.cost_usec if radar_mode else mm.cost_usec
			var acc: Array = sums[s]
			for i in frames:
				await process_frame
				acc[1] += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) + RenderingServer.get_frame_setup_time_cpu()
				acc[2] += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
				acc[3] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
				acc[4] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			acc[0] += (Time.get_ticks_usec() - started) / 1000.0
			acc[5] += ((rd.cost_usec if radar_mode else mm.cost_usec) - cost0) / 1000.0
			if radar_mode and s != "radar_off" and not rd.visible:
				print("MINIMAP_COST warning: the radar was hidden during an ON block (%s)" % s)
			elif not radar_mode and s != "off" and not mm.visible:
				print("MINIMAP_COST warning: the minimap was hidden during an ON block (%s)" % s)
	mcfg["enabled"] = true
	rcfg["enabled"] = true
	rcfg["sweep"]["enabled"] = true
	var n := float(frames * rounds)
	var size := root.get_viewport().get_visible_rect().size
	var off: Array = sums[states[0]]
	var tag := "RADAR_COST" if radar_mode else "MINIMAP_COST"
	for s: String in states:
		var a: Array = sums[s]
		print("%s desktop, not device: renderer=%s size=%dx%d state=%s frames=%d frame_ms=%.3f render_cpu_ms=%.3f render_gpu_ms=%.3f draw_calls=%.1f primitives=%.0f script_ms=%.4f | vs %s: frame_ms=%+.3f cpu=%+.3f gpu=%+.3f draws=%+.1f" % [
				tag, str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), int(size.x), int(size.y), s, int(n),
				a[0] / n, a[1] / n, a[2] / n, a[3] / n, a[4] / n, a[5] / n, states[0],
				(a[0] - off[0]) / n, (a[1] - off[1]) / n, (a[2] - off[2]) / n, (a[3] - off[3]) / n])
	if radar_mode:
		print("RADAR_COST blips=%d blip_updates=%d blip_draws=%d players=%d" % [rd.blips.size(), rd.blip_updates, rd.blip_draws, m.director.all_players().size()])
	else:
		print("MINIMAP_COST texture=%s %s overlay_updates=%d rotor_draws=%d" % [mm.map_id, str(mm.texture.get_size()) if mm.texture != null else "none", mm.overlay_updates, mm.rotor_draws])
	quit()


## 6 enemies and 2 squad mates on a ring 6..22 m around the player (ground height from the map), so the radar is busy.
func _place_near(m: MatchRoot) -> void:
	var me := m.local_player
	var at := Vector2(me.global_position.x, me.global_position.z)
	var terrain := MapTerrain.for_map(m.map_def)
	var enemies := 0
	var mates := 0
	var i := 0
	for id in m.director.all_players():
		var o: Pawn = m.director.player(id)
		if o == me:
			continue
		var mate := o.squad_id == me.squad_id
		if (mate and mates >= 2) or (not mate and enemies >= 6):
			continue
		var q := at + Vector2.from_angle(float(i) * 0.8) * (6.0 + float(i) * 2.0)
		o.global_position = Vector3(q.x, (terrain.height_at(q.x, q.y) if terrain != null else me.global_position.y) + 0.05, q.y)
		i += 1
		if mate:
			mates += 1
		else:
			enemies += 1
