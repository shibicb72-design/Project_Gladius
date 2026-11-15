extends SceneTree
## M2 L1b: on-screen check of the props (the tests only read the batch metas). Windowed, needs a renderer; the
## 1 km map built the way tools/render_layout.gd --shots builds it (ArtBuilder.map_json handed over, the match's
## Light + WorldEnvironment via GreyboxArt, no match, no pawns), a 2520 x 1080 offscreen SubViewport:
##   godot --path . --script res://tools/props_shots.gd --log-file <log> -- --out=<absolute dir>
## Saves crate_before.png (the first breakable crate, in camp 1), breaks it through its real take_hit, waits for the
## break effect to end and saves crate_after.png; then chest_closed.png (the first chest, in camp 1, seen from its
## front) and, after WorldProps.open_chest with a LootField (so the spill shows), chest_open.png. Prints one
## PROPS_SHOT line per file; exit 1 on a problem. Option: --map=res://data/maps/alesia_1km.json (default).

const MAP_PATH := "res://data/maps/alesia_1km.json"
const SHOT_SIZE := Vector2i(2520, 1080)
## The camera: this far from the prop on the ground and this high over the prop's ground.
const BACK_M := 4.5
const UP_M := 2.4
const SETTLE_FRAMES := 30


func _initialize() -> void:
	var out := ""
	var map_path := MAP_PATH
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--map="):
			map_path = a.substr(6)
	if out == "":
		printerr("props_shots: give --out=<absolute dir>")
		quit(1)
		return
	var ok: bool = await _run(map_path, out)
	quit(0 if ok else 1)


func _run(map_path: String, dir: String) -> bool:
	if DisplayServer.get_name() == "headless":
		printerr("props_shots needs a window (run without --headless)")
		return false
	var def := DataRegistry.parse_quiet(map_path)
	DirAccess.make_dir_recursive_absolute(dir)
	await process_frame
	var view := SubViewport.new()
	view.size = SHOT_SIZE
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.own_world_3d = true
	root.add_child(view)
	var stage := Node3D.new()
	stage.name = "Match"
	var light := DirectionalLight3D.new()
	light.name = "Light"
	stage.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))  # the match's look (light, sky, fog by preset)
	stage.add_child(world)
	view.add_child(stage)
	var map: Node3D = load(String(def["scene"])).instantiate()
	var builder := map.get_node("ArtBuilder")
	builder.set("map_json", map_path)
	stage.add_child(map)
	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 2000.0
	stage.add_child(camera)
	camera.make_current()
	var loot := LootField.new()
	loot.name = "Loot"
	loot.setup(DataRegistry.new().load_file(MatchDirector.LOOT_PATH), 1)
	loot.placed = true  # only the chest's spill
	stage.add_child(loot)
	var props := WorldProps.new()
	props.name = "WorldProps"
	props.setup(WorldProps.config(), 1, true, loot)
	props.collect(map)
	stage.add_child(props)
	var crate: Breakable = null
	for body: StaticBody3D in builder.call("breakable_bodies"):
		if (body as Breakable).prop_type == "breakable_crate":
			crate = body
			break
	var chest: LootChest = null
	var chests: Array = builder.get("chest_bodies")
	if not chests.is_empty():
		chest = chests[0]
	if crate == null or chest == null:
		printerr("props_shots: no crate (%s) or no chest (%s) on %s" % [crate != null, chest != null, map_path])
		view.queue_free()
		return false
	for frame in 10:
		await process_frame
	var ok := true
	# The crate: from the camp's open side (towards the map centre), before and after its real break.
	var crate_at := crate.global_position
	var crate_id := crate.prop_id
	var away := Vector3(-crate_at.x, 0.0, -crate_at.z).normalized()
	_aim(camera, crate_at, away)
	ok = await _save(view, camera, dir, "crate_before", "%s intact" % crate_id) and ok
	crate.take_hit(crate.health)
	var fx_s := float((WorldProps.config().get("break_fx", {}) as Dictionary).get("life_s", 0.6)) + 0.6
	await create_timer(fx_s).timeout
	ok = await _save(view, camera, dir, "crate_after", "%s after take_hit: broken=%s hidden=%s in_tree=%s" % [crate_id,
			props.state_of(crate_id) == WorldProps.BROKEN, (builder.get("chunks") as MapChunks).is_piece_hidden(crate_id), is_instance_valid(crate) and crate.is_inside_tree()]) and ok
	# The chest: from its front (where it opens towards and its loot lands).
	_aim(camera, chest.global_position, chest.front())
	ok = await _save(view, camera, dir, "chest_closed", "%s closed" % chest.prop_id) and ok
	var opened := props.open_chest(chest.prop_id)
	ok = await _save(view, camera, dir, "chest_open", "%s open_chest=%s spilled=%d" % [chest.prop_id, opened, props.spilled.size()]) and ok
	ok = ok and opened and props.state_of(crate_id) == WorldProps.BROKEN
	view.queue_free()
	await process_frame
	return ok


## Puts the camera BACK_M from `target` along `side` (on the ground plane), UP_M over it, looking at the target.
func _aim(camera: Camera3D, target: Vector3, side: Vector3) -> void:
	camera.global_position = target + side * BACK_M + Vector3(0.0, UP_M, 0.0)
	camera.look_at(target, Vector3.UP)


func _save(view: SubViewport, camera: Camera3D, dir: String, shot_name: String, what: String) -> bool:
	for frame in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := view.get_texture().get_image()
	var path := dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	print("PROPS_SHOT %s %dx%d err=%d camera=(%.1f, %.1f, %.1f): %s" % [path, img.get_width(), img.get_height(), err,
			camera.global_position.x, camera.global_position.y, camera.global_position.z, what])
	return err == OK
