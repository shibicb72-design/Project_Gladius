extends SceneTree
## Desktop-render shots of a real match opening (S9): the carrier ride, the fall, the landing and the first
## seconds on the ground, as the game itself starts a match (drop from the sky, ground loot, bots).
##   godot --path . --resolution 2520x1080 --audio-driver Dummy --script res://tools/drop_capture.gd -- --out=<dir> --tag=<tag> [--variant=dusk] [--hud]
## Nobody presses the drop button: the carrier lets the local pawn go at the end of its line, as the director
## does for an idle player. Shots are taken at the times in data/capture_shots.json "drop_capture" (seconds
## after the match began) and saved as <tag>_drop_<name>.png. The HUD is hidden unless --hud is given.

func _initialize() -> void:
	var out := "build/shots"
	var tag := "drop"
	var hud := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
		elif arg.begins_with("--tag="):
			tag = arg.substr(6)
		elif arg.begins_with("--variant="):
			MatchLook.variant_override = arg.substr(10)
		elif arg == "--hud":
			hud = true
		elif arg.begins_with("--on=") or arg.begins_with("--off="):
			for key in arg.get_slice("=", 1).split(","):
				GraphicsPresets.overrides[key] = arg.begins_with("--on=")
		elif arg.begins_with("--set="):
			for pair in arg.substr(6).split(","):
				var value := pair.get_slice(":", 1)
				GraphicsPresets.overrides[pair.get_slice(":", 0)] = float(value) if value.is_valid_float() else value
	if MatchLook.variant_override == "":
		MatchLook.variant_override = String(MatchLook.config()["variant"])
	if not out.is_absolute_path():
		out = ProjectSettings.globalize_path("res://").path_join(out)
	DirAccess.make_dir_recursive_absolute(out)
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/capture_shots.json")["drop_capture"]
	await process_frame
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.seed_override = int(cfg["match_seed"])
	root.add_child(match_scene)  # auto_start: the real opening
	(match_scene.get_node("Hud") as CanvasLayer).visible = hud
	var started := Time.get_ticks_msec()
	for shot: Dictionary in cfg["shots"]:
		while (Time.get_ticks_msec() - started) / 1000.0 < float(shot["at_s"]):
			await process_frame
		await RenderingServer.frame_post_draw
		var pawn := match_scene.local_player
		var path := out.path_join("%s_drop_%s.png" % [tag, shot["name"]])
		var err := root.get_viewport().get_texture().get_image().save_png(path)
		print("[drop_capture] saved %s err=%d t=%.1f s drop_state=%d height=%.1f m alive=%d" % [path, err, float(shot["at_s"]),
				pawn.drop_state, pawn.global_position.y, match_scene.director.players_alive()])
	quit()
