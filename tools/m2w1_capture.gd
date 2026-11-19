extends SceneTree
## M2W1: the world-art audit captures of a map (windowed, needs a renderer). The map is built the way MatchRoot builds
## it (the "Match" stage holds Light, WorldEnvironment with GreyboxArt, then the map scene with ArtBuilder.map_json
## handed over before it enters the tree), so the ground, the kit batches, the cover, the props ArtBuilder builds itself
## (doors and gates, ladders, chests, breakables under ArtBuilder/Props and Nav), the ambient decor and the backdrop
## (when the map wants it) are the match's. The look is the match's own GreyboxArt environment + MatchLook for one
## variant (MatchLook.variant_override, so sky, sun, fog, post, wet and weather all follow it). No match, no director,
## no loot on the ground, no zone wall, no HUD. Read-only: it changes no game file and decides nothing.
##   godot --path . --resolution 2520x1080 --log-file <log> --script res://tools/m2w1_capture.gd -- --out=<absolute dir>
## Options:
##   --variant=dusk|night|storm   the look variant (default: data/art_look.json "variant")
##   --only=<text>                only shots whose name contains this text
##   --tag=<prefix>               file name prefix (default m2w1)
##   --map=<res path>             the map json (default res://data/maps/alesia_1km.json)
##   --shots=<name or path>       the shot list (default res://data/m2w1_capture.json)
##   --settle=<frames>            frames to wait after each camera move (default 45)
##   --size=<W>x<H>               the picture size wanted (pass the same as --resolution, which the engine consumes and
##                                a script cannot read back); when the window did not get it, an offscreen SubViewport
##                                of this size renders instead
## Shots: data/m2w1_capture.json (format note there). Saves <tag>_<variant>_<W>x<H>_<name>.png at the window's real
## size (the root viewport, so the vignette layer is in the picture) or the SubViewport's; the M2W1_MODE line says which. One M2W1_SHOT line per file with the camera, the look point, the fov, whether the camera point
## is clear of colliders and what the line of sight to the look point meets first. Exit 1 on a problem.
## Determinism: storm lightning is switched off (MatchLook's next-flash timer), and the weather particles are restarted
## with a full lifetime of preprocess after every camera move (in a match they follow a moving camera and are always
## spread out). Contact sheets: tools/contact_sheet.gd --dir=<out> --filter=<tag>_<variant>_<W>x<H>_ --cols=4 --tile=640.

const MAP_PATH := "res://data/maps/alesia_1km.json"
const SHOTS_PATH := "res://data/m2w1_capture.json"
const EYE_M := 1.7
const SOLDIER_AHEAD_M := 6.0
const FIRST_SETTLE := 90
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _out := ""
var _tag := "m2w1"
var _variant := ""
var _only := ""
var _map_path := MAP_PATH
var _shots_path := SHOTS_PATH
var _shot_list_key := "shots"
var _settle := 45
var _asked := Vector2i.ZERO
var _view: Viewport
var _stage: Node3D
var _camera: Camera3D
var _terrain: MapTerrain
var _soldier: Node3D
var _look: MatchLook


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--variant="):
			_variant = a.substr(10)
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--map="):
			_map_path = a.substr(6)
		elif a.begins_with("--shots="):
			_shots_path = a.substr(8)
			if _shots_path.is_valid_identifier():
				_shot_list_key = _shots_path
				_shots_path = SHOTS_PATH
		elif a.begins_with("--settle="):
			_settle = maxi(1, int(a.substr(9)))
		elif a.begins_with("--size="):
			var parts := a.substr(7).split("x")
			if parts.size() == 2:
				_asked = Vector2i(int(parts[0]), int(parts[1]))
	if _out == "":
		printerr("m2w1_capture: give --out=<absolute dir>")
		quit(1)
		return
	var ok: bool = await _run()
	quit(0 if ok else 1)


func _run() -> bool:
	if DisplayServer.get_name() == "headless":
		printerr("m2w1_capture needs a window (run without --headless)")
		return false
	var def := DataRegistry.parse_quiet(_map_path)
	var shot_list: Array = DataRegistry.parse_quiet(_shots_path).get(_shot_list_key, [])
	if def.is_empty() or shot_list.is_empty():
		printerr("m2w1_capture: cannot read %s or %s" % [_map_path, _shots_path])
		return false
	var variants: Dictionary = MatchLook.config()["variants"]
	if _variant == "":
		_variant = String(MatchLook.config()["variant"])
	if not variants.has(_variant):
		printerr("m2w1_capture: unknown variant %s (have %s)" % [_variant, ", ".join(PackedStringArray(variants.keys()))])
		return false
	DirAccess.make_dir_recursive_absolute(_out)
	await process_frame
	await process_frame
	# The window's real size, or an offscreen viewport of the asked size when the window could not get it.
	var asked := _asked
	var window_size := root.size
	if asked == Vector2i.ZERO or asked == window_size:
		_view = root
		print("M2W1_MODE window %dx%d (asked %s)" % [window_size.x, window_size.y, str(asked)])
	else:
		var sub := SubViewport.new()
		sub.size = asked
		sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sub.own_world_3d = true
		root.add_child(sub)
		_view = sub
		print("M2W1_MODE subviewport %dx%d (the window got %dx%d for --resolution %dx%d)" % [asked.x, asked.y, window_size.x, window_size.y, asked.x, asked.y])
	GraphicsPresets.new().apply("", _view)  # as boot.gd does for the game's viewport (msaa, 3D scale)
	MatchLook.variant_override = _variant
	var t0 := Time.get_ticks_msec()
	_stage = Node3D.new()
	_stage.name = "Match"
	var light := DirectionalLight3D.new()
	light.name = "Light"
	_stage.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))
	_stage.add_child(world)
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", _map_path)
	_stage.add_child(map)
	_camera = Camera3D.new()
	_camera.name = "M2W1Camera"
	_stage.add_child(_camera)
	_view.add_child(_stage)
	_camera.make_current()
	_terrain = map.get_node("ArtBuilder").get("terrain")
	_look = world.get_node_or_null("MatchLook") as MatchLook
	if _look != null:
		_look.set("_flash_wait", -1.0)  # no storm lightning: every capture shows the variant's steady light
	print("M2W1_BUILD map=%s variant=%s build_ms=%d" % [_map_path, _variant, Time.get_ticks_msec() - t0])
	# M2W1 astraB: the place map (when the map built one), saved beside the shots for review.
	var place: Variant = map.get_node("ArtBuilder").get("place_map")
	if place != null:
		var clutter: Dictionary = map.get_node("ArtBuilder").get("clutter_report")
		print("M2W1_PLACE px=%d build_ms=%d stamps=%d clutter_instances=%d clutter_ms=%d" % [place.px, place.build_ms, place.stamps,
				int(clutter.get("instances", 0)), int(clutter.get("ms", 0))])
		print("M2W1_CLUTTER scatter=%s dressing=%s dropped=%s capped=%d" % [str(clutter.get("scatter", {})), str(clutter.get("dressing", {})),
				str(clutter.get("dropped", {})), int(clutter.get("capped", 0))])
		print("M2W1_CLUTTER_DROPPED_BY %s" % str(clutter.get("dropped_by", {})))
		place.image().save_png(_out.path_join("%s_place_map.png" % _tag))
	_soldier = _PawnScene.instantiate()
	_soldier.name = "M2W1Soldier"
	_stage.add_child(_soldier)
	_soldier.set_physics_process(false)
	_soldier.visible = false
	for frame in FIRST_SETTLE:
		await process_frame
	# Pixels: the window's (or SubViewport's) size. Neither the visible rect (stretched canvas units) nor the root
	# texture's get_size() (it reported 4200x1800 for a 2520x1080 window here) is the saved image's size.
	var size := Vector2(root.size if _view == root else (_view as SubViewport).size)
	var default_fov := CameraRig.fov_for_aspect(DataRegistry.new().get_camera_cfg(), size.x / size.y)
	var ok := true
	var made := 0
	for shot: Dictionary in shot_list:
		var shot_name := String(shot["name"])
		if _only != "" and not shot_name.contains(_only):
			continue
		ok = await _take(shot, default_fov, Vector2i(size)) and ok
		made += 1
	print("M2W1_DONE variant=%s size=%dx%d shots=%d ok=%s" % [_variant, int(size.x), int(size.y), made, ok])
	MatchLook.variant_override = ""
	_stage.queue_free()
	await process_frame
	return ok and made > 0


func _ground(x: float, z: float) -> float:
	return _terrain.height_at(x, z) if _terrain != null else 0.0


func _take(shot: Dictionary, default_fov: float, size: Vector2i) -> bool:
	var cam: Array = shot["cam"]
	var at := Vector3(float(cam[0]), 0.0, float(cam[1]))
	at.y = _ground(at.x, at.z) + float(shot.get("eye_m", EYE_M))
	var target: Vector3
	var mode := String(shot.get("look_mode", ""))
	if mode == "sun" or mode == "antisun":
		var light := _stage.get_node("Light") as DirectionalLight3D
		var towards := light.global_transform.basis.z  # a directional light shines along its -Z
		var flat := Vector3(towards.x, 0.0, towards.z).normalized() * (1.0 if mode == "sun" else -1.0)
		var pitch := deg_to_rad(float(shot.get("pitch_deg", 15.0)))
		target = at + (flat * cos(pitch) + Vector3.UP * sin(pitch)) * 100.0
	else:
		var look: Array = shot["look"]
		target = Vector3(float(look[0]), _ground(float(look[0]), float(look[2])) + float(look[1]), float(look[2]))
	_camera.fov = float(shot.get("fov", default_fov))
	_camera.global_position = at
	_camera.look_at(target, Vector3.UP)
	_soldier.visible = bool(shot.get("soldier", false))
	var soldier_at := Vector3.INF
	if _soldier.visible:
		var ahead := Vector3(target.x - at.x, 0.0, target.z - at.z).normalized()
		var spot := Vector2(at.x + ahead.x * SOLDIER_AHEAD_M, at.z + ahead.z * SOLDIER_AHEAD_M)
		if shot.has("soldier_at"):
			spot = Vector2(float(shot["soldier_at"][0]), float(shot["soldier_at"][1]))
		soldier_at = Vector3(spot.x, _ground(spot.x, spot.y), spot.y)
		var facing := Vector3(at.x - soldier_at.x, 0.0, at.z - soldier_at.z).normalized()
		# Turned 30 degrees off the camera so the front and one side catch the light.
		_soldier.global_transform = Transform3D(Basis.looking_at(facing).rotated(Vector3.UP, deg_to_rad(30.0)), soldier_at)
	await process_frame
	_refill_weather()
	for frame in _settle:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _view.get_texture().get_image()
	var file := "%s_%s_%dx%d_%s.png" % [_tag, _variant, img.get_width(), img.get_height(), String(shot["name"])]
	if img.get_size() != size:
		print("M2W1_WARN %s: the image is %dx%d, the view %dx%d" % [shot["name"], img.get_width(), img.get_height(), size.x, size.y])
	var path := _out.path_join(file)
	var err := img.save_png(path)
	var check := _clearance(at, target)
	print("M2W1_SHOT %s %dx%d err=%d cam=(%.2f, %.2f, %.2f) look=(%.2f, %.2f, %.2f) fov=%.1f soldier=%s cam_clear=%s sight=%s : %s" % [path, img.get_width(), img.get_height(), err,
			at.x, at.y, at.z, target.x, target.y, target.z, _camera.fov, ("(%.2f, %.2f, %.2f)" % [soldier_at.x, soldier_at.y, soldier_at.z]) if soldier_at != Vector3.INF else "none",
			check["clear"], check["sight"], String(shot.get("note", ""))])
	return err == OK and bool(check["clear"])


## Restarts the weather around the camera already spread out (MatchLook moves the emitters to the camera each frame;
## a jump of hundreds of metres would otherwise show an empty box for a particle lifetime).
func _refill_weather() -> void:
	if _look == null:
		return
	for p: GPUParticles3D in [_look.weather, _look.splashes]:
		if p != null:
			p.preprocess = p.lifetime
			p.restart()


## Whether the camera point is outside every collider (a 0.2 m sphere on the world mask), and the first collider on
## the line of sight to the look point (name and distance, "open" when none).
func _clearance(at: Vector3, target: Vector3) -> Dictionary:
	var space := _stage.get_world_3d().direct_space_state
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
	var sight := "open"
	if not ray.is_empty():
		sight = "%s@%.1fm_of_%.1fm" % [(ray["collider"] as Node).name, at.distance_to(ray["position"]), at.distance_to(target)]
	return {"clear": inside.is_empty(), "sight": sight if inside.is_empty() else "inside " + ",".join(names)}
