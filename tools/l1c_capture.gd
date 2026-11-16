extends SceneTree
## M2 L1c: on-screen proof shots of the doors, gates, ladders and the aqueduct ramp guards (windowed, needs a
## renderer). The 1 km map is built the way tools/props_shots.gd builds it (ArtBuilder.map_json handed over, the match's
## Light + WorldEnvironment via GreyboxArt) in a 2520 x 1080 offscreen SubViewport; nothing here feeds back into the
## game: it only reads public API and node state, and places its own proof cameras (not the game camera).
##   godot --path . --resolution 2520x1080 --log-file <log> --script res://tools/l1c_capture.gd -- --out=<absolute dir>
## Writes door_closed / door_opening / door_open, gate_closed / gate_open, ladder_bottom / ladder_middle / ladder_top,
## ramp_before / ramp_after / ramp2_after (PNG, 2520 x 1080) and the contact sheets sheet_doors / sheet_ladder /
## sheet_ramp (each a row of the shots scaled to 840 px wide). Prints one L1C_SHOT line per file; exit 1 on a problem.
## ladder_fp (the game's own camera on a ladder) needs a real match with its CameraRig: not made here.
## Options: --map=res://data/maps/alesia_1km.json (default), --sheets-only (rebuild the sheets from the PNGs in --out).

const MAP_PATH := "res://data/maps/alesia_1km.json"
const SHOT_SIZE := Vector2i(2520, 1080)
const SHEET_W := 840
const SHEET_GAP := 16
const SETTLE_FRAMES := 20
const DOOR_BACK_M := 6.0
const LADDER_SIDE_M := 7.0
const RAMP_UP_M := 26.0
const RAMP_ID := "AquaMarcia_Ramp_In"
const RAMP2_ID := "AquaMarcia_Ramp_Out"
const STUCK_POINT := Vector2(116.3, 13.8)  # where the bots stood (the commit-1 measurement)
const STRUCTURES_PATH := "res://data/maps/alesia_1km_structures.json"

var _view: SubViewport
var _camera: Camera3D
var _dir := ""


func _initialize() -> void:
	var map_path := MAP_PATH
	var sheets_only := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_dir = a.substr(6)
		elif a.begins_with("--map="):
			map_path = a.substr(6)
		elif a == "--sheets-only":
			sheets_only = true
	if _dir == "":
		printerr("l1c_capture: give --out=<absolute dir>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var ok := true
	if not sheets_only:
		ok = await _run(map_path)
	ok = _sheets() and ok
	quit(0 if ok else 1)


func _run(map_path: String) -> bool:
	if DisplayServer.get_name() == "headless":
		printerr("l1c_capture needs a window (run without --headless)")
		return false
	var def := DataRegistry.parse_quiet(map_path)
	await process_frame
	_view = SubViewport.new()
	_view.size = SHOT_SIZE
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.own_world_3d = true
	root.add_child(_view)
	var stage := Node3D.new()
	stage.name = "Match"
	var light := DirectionalLight3D.new()
	light.name = "Light"
	stage.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))
	stage.add_child(world)
	_view.add_child(stage)
	var map: Node3D = load(String(def["scene"])).instantiate()
	var builder := map.get_node("ArtBuilder")
	builder.set("map_json", map_path)
	stage.add_child(map)
	_camera = Camera3D.new()
	_camera.fov = 60.0
	_camera.far = 2000.0
	stage.add_child(_camera)
	_camera.make_current()
	for frame in 10:
		await process_frame
	var ok := true
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var pieces := _piece_centres()
	var door: Door = null
	var gate: Door = null
	for d: Door in builder.get("door_bodies"):
		if d.kind == Door.KIND_DOOR and door == null:
			door = d
		elif d.kind == Door.KIND_GATE and gate == null:
			gate = d
	if door == null or gate == null:
		printerr("l1c_capture: no door (%s) or gate (%s)" % [door != null, gate != null])
		return false
	# Doors: closed, half way through the slide, open.
	var door_piece := ""
	for e: Dictionary in cover.get("doors", []):
		if String(e["id"]) == door.prop_id:
			door_piece = String(e.get("piece", ""))
	var out_sign := _out_sign(door, pieces.get(door_piece, Vector3.INF))
	_settle_door(door, false)
	_aim_door(door, out_sign)
	ok = await _save("door_closed", "%s closed, leaf phase %.2f blocks=%s" % [door.prop_id, door.phase, door.blocks()]) and ok
	door.set_open(true)
	door.set_physics_process(false)  # driven by hand from here: the shot is held still
	door.step(door.move_time_s * 0.5)
	ok = await _save("door_opening", "%s mid slide, phase %.2f moving=%s" % [door.prop_id, door.phase, door.moving]) and ok
	door.step(door.move_time_s)
	door.set_physics_process(false)
	ok = await _save("door_open", "%s open, phase %.2f blocks=%s" % [door.prop_id, door.phase, door.blocks()]) and ok
	# Gates: closed, open (a gate may start open: close it first).
	_settle_door(gate, false)
	_aim_door(gate, 1.0, 9.0)
	ok = await _save("gate_closed", "%s closed, phase %.2f blocks=%s" % [gate.prop_id, gate.phase, gate.blocks()]) and ok
	_settle_door(gate, true)
	ok = await _save("gate_open", "%s open, phase %.2f blocks=%s" % [gate.prop_id, gate.phase, gate.blocks()]) and ok
	ok = await _ladder_shots(stage, map, builder, cover) and ok
	ok = await _ramp_shots(builder) and ok
	_view.queue_free()
	await process_frame
	return ok


## Drives a door to its target pose by hand (steps of 0.1 s until it rests), physics processing left off.
func _settle_door(door: Door, open: bool) -> void:
	door.set_open(open)
	for i in 200:
		if door.settled():
			break
		door.step(0.1)
	door.set_physics_process(false)


## Camera `back_m` in front of the doorway (the side `out_sign` along its local z), at eye height, looking at its centre.
func _aim_door(door: Door, out_sign: float, back_m: float = DOOR_BACK_M) -> void:
	var out := door.global_transform.basis.z * out_sign
	out.y = 0.0
	out = out.normalized()
	var centre := door.global_position
	_camera.global_position = Vector3(centre.x, door.bottom_y() + 1.6, centre.z) + out * back_m
	_camera.look_at(centre + Vector3.UP * 0.2, Vector3.UP)


## +1 or -1: which side of the door's local z points away from the building's centre (the outside).
func _out_sign(door: Door, piece_centre: Vector3) -> float:
	if piece_centre == Vector3.INF:
		return 1.0
	var to_door := door.global_position - piece_centre
	return 1.0 if to_door.dot(door.global_transform.basis.z) >= 0.0 else -1.0


## {piece id: world position} from the structures file (the pieces' own `at`).
func _piece_centres() -> Dictionary:
	var out := {}
	var data := DataRegistry.parse_quiet(STRUCTURES_PATH)
	for p: Dictionary in data.get("pieces", []):
		out[String(p["id"])] = LowpolyKit.vec(p["at"])
	return out


func _ladder_shots(stage: Node3D, map: Node3D, builder: Node, cover: Dictionary) -> bool:
	var ladders: Array = builder.get("ladders")
	if ladders.is_empty():
		printerr("l1c_capture: no ladders")
		return false
	var ladder := ladders[0] as Ladder
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	stage.add_child(pawn)
	pawn.set_physics_process(false)
	var into := ladder.into_dir()
	var start := ladder.foot() - into * 1.8 + Vector3.UP * 0.05
	pawn.global_transform = Transform3D(Basis.looking_at(into), start)
	await physics_frame
	var frame := InputFrame.new()
	frame.move = Vector2(0, -1)
	pawn.set_frame(frame)
	var grabbed := false
	for i in 240:
		pawn._physics_process(1.0 / 60.0)
		if pawn.climbing:
			grabbed = true
			break
		await physics_frame
	var ok := grabbed
	if not grabbed:
		printerr("l1c_capture: the pawn did not grab %s" % ladder.prop_id)
		return false
	_aim_ladder(ladder)
	ok = await _save("ladder_bottom", "%s just grabbed, feet y %.2f over the foot %.2f, climbing=%s" % [ladder.prop_id, pawn.global_position.y, ladder.foot().y, pawn.climbing]) and ok
	for i in 600:
		if not pawn.climbing or pawn.global_position.y >= ladder.foot().y + ladder.height * 0.5:
			break
		pawn._physics_process(1.0 / 60.0)
	ok = await _save("ladder_middle", "%s half way, feet y %.2f (ledge %.2f), climbing=%s" % [ladder.prop_id, pawn.global_position.y, ladder.top_y(), pawn.climbing]) and ok
	for i in 600:
		if not pawn.climbing:
			break
		pawn._physics_process(1.0 / 60.0)
	for i in 20:
		pawn._physics_process(1.0 / 60.0)
	ok = await _save("ladder_top", "%s on the roof, feet y %.2f (ledge %.2f), climbing=%s floor=%s" % [ladder.prop_id, pawn.global_position.y, ladder.top_y(), pawn.climbing, pawn.is_on_floor()]) and ok
	pawn.queue_free()
	return ok


## A proof camera beside the ladder (along the wall, a little out in front), level with the ladder's middle.
func _aim_ladder(ladder: Ladder) -> void:
	var side := ladder.global_transform.basis.x
	side.y = 0.0
	side = side.normalized()
	var out := -ladder.into_dir()
	var mid := ladder.foot() + Vector3.UP * (ladder.height * 0.5 + 0.3) - out * 0.3
	_camera.global_position = mid + side * LADDER_SIDE_M + out * 2.5 + Vector3.UP * 0.4
	_camera.look_at(mid, Vector3.UP)


func _ramp_shots(builder: Node) -> bool:
	var chunks: MapChunks = builder.get("chunks")
	var terrain: MapTerrain = builder.get("terrain")
	var ok := true
	var guards: Array[String] = []
	for suffix in ["_Guard_L0", "_Guard_R0"]:
		guards.append(RAMP_ID + suffix)
	var marker := MeshInstance3D.new()
	marker.name = "StuckMarker"
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.4
	marker.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 1.0)
	marker.material_override = mat
	marker.position = Vector3(STUCK_POINT.x, terrain.height_at(STUCK_POINT.x, STUCK_POINT.y) + 0.2, STUCK_POINT.y)
	_camera.get_parent().add_child(marker)
	# hide_piece only knows pieces added with a piece_id; the structure pieces are not (world_kit.gd adds them
	# without), so the guard's instance is found by its body's transform and zero-scaled in the batch here, shot only.
	var hid := 0
	var saved: Array = []  # [batch, index, original transform]
	for g in guards:
		if chunks.hide_piece(g):
			hid += 1
			continue
		var body: Node3D = null
		for b: Node3D in builder.get("structure_bodies"):
			if b.name == g:
				body = b
		if body == null:
			continue
		var batch := chunks.batch_of("structure", "stake_row", body.transform)
		if batch == null:
			continue
		var tr: Array = batch.get_meta(&"transforms")
		for i in tr.size():
			if (tr[i] as Transform3D).is_equal_approx(body.transform):
				saved.append([batch, i, tr[i]])
				batch.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), body.transform.origin))
				hid += 1
				break
	var hidden_ok := hid == guards.size()
	_aim_down(Vector2(118.0, 12.0), terrain)
	ok = await _save("ramp_before", "%s guards hidden=%s (hide_piece worked on %d of %d), marker at the stuck point" % [RAMP_ID, hidden_ok, hid, guards.size()]) and ok
	for s: Array in saved:
		(s[0] as MultiMeshInstance3D).multimesh.set_instance_transform(int(s[1]), s[2])
	ok = await _save("ramp_after", "%s guards restored (%d instances), marker at the stuck point" % [RAMP_ID, saved.size()]) and ok
	marker.visible = false
	_aim_down(Vector2(351.0, 12.0), terrain)
	ok = await _save("ramp2_after", "%s guards shown, no marker" % RAMP2_ID) and ok
	return ok and hidden_ok


## Straight down from RAMP_UP_M over `at` (x, z), image up = world -z.
func _aim_down(at: Vector2, terrain: MapTerrain) -> void:
	_camera.global_position = Vector3(at.x, terrain.height_at(at.x, at.y) + RAMP_UP_M, at.y)
	_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)


func _save(shot_name: String, what: String) -> bool:
	for frame in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _view.get_texture().get_image()
	var path := _dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	print("L1C_SHOT %s %dx%d err=%d camera=(%.1f, %.1f, %.1f): %s" % [path, img.get_width(), img.get_height(), err,
			_camera.global_position.x, _camera.global_position.y, _camera.global_position.z, what])
	return err == OK


## The three contact sheets from the PNGs in the out dir (a missing shot is skipped and said so).
func _sheets() -> bool:
	var ok := true
	ok = _sheet("sheet_doors", ["door_closed", "door_opening", "door_open", "gate_closed", "gate_open"]) and ok
	ok = _sheet("sheet_ladder", ["ladder_bottom", "ladder_middle", "ladder_top", "ladder_fp"]) and ok
	ok = _sheet("sheet_ramp", ["ramp_before", "ramp_after", "ramp2_after"]) and ok
	return ok


func _sheet(sheet_name: String, shots: Array) -> bool:
	var imgs: Array[Image] = []
	for s: String in shots:
		var p := _dir.path_join(s + ".png")
		if not FileAccess.file_exists(p):
			print("L1C_SHEET %s: %s missing, skipped" % [sheet_name, s])
			continue
		var img := Image.load_from_file(p)
		if img == null or img.is_empty():
			print("L1C_SHEET %s: %s unreadable, skipped" % [sheet_name, s])
			continue
		img.convert(Image.FORMAT_RGBA8)
		img.resize(SHEET_W, int(round(float(img.get_height()) * SHEET_W / float(img.get_width()))), Image.INTERPOLATE_LANCZOS)
		imgs.append(img)
	if imgs.is_empty():
		return false
	var h := 0
	for i in imgs:
		h = maxi(h, i.get_height())
	var sheet := Image.create_empty(imgs.size() * SHEET_W + (imgs.size() - 1) * SHEET_GAP, h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.08, 0.08, 0.08))
	for k in imgs.size():
		sheet.blit_rect(imgs[k], Rect2i(Vector2i.ZERO, imgs[k].get_size()), Vector2i(k * (SHEET_W + SHEET_GAP), 0))
	var path := _dir.path_join(sheet_name + ".png")
	var err := sheet.save_png(path)
	print("L1C_SHEET %s %dx%d err=%d from %d shots" % [path, sheet.get_width(), sheet.get_height(), err, imgs.size()])
	return err == OK
