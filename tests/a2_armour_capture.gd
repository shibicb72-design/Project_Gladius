extends SceneTree
## Run windowed with --fixed-fps 60 --script res://tests/a2_armour_capture.gd -- --out=<shots directory>.
## Repeat with --rendering-method gl_compatibility. Use actual distance LODs and the pawn's normal animation paths.

const CELL := Vector2i(320, 394)
const ANGLES := [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3(0.72, 0, -0.69)]
const VIEWS := ["Front", "Right", "Back", "Three-quarter"]
const POSES := ["Idle", "Run", "Crouch", "Downed", "Death"]
var _out := ""
var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _label: Label
var _pawn: Pawn


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if _out.is_empty() or DisplayServer.get_name() == "headless":
		push_error("A2 capture needs a window and --out=<directory>")
		quit(1)
		return
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_out)
	_viewport = SubViewport.new()
	_viewport.size = CELL
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(_viewport)
	var preview := TextureRect.new()
	preview.texture = _viewport.get_texture()
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(preview)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#353d46")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#a7a9bb")
	environment.ambient_light_energy = 0.7
	env.environment = environment
	_viewport.add_child(env)
	_light(Vector3(-38, -28, 0), Color("#ffe5c9"), 1.30, true)
	_light(Vector3(-24, 145, 0), Color("#b7d6ff"), 0.70, false)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	floor_mesh.mesh = plane
	var floor_paint := StandardMaterial3D.new()
	floor_paint.albedo_color = Color("#4a4540")
	floor_paint.roughness = 0.96
	floor_mesh.material_override = floor_paint
	_viewport.add_child(floor_mesh)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(18, 1, 18)
	floor_shape.shape = box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	_viewport.add_child(floor_body)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 2.52
	_viewport.add_child(_camera)
	_camera.make_current()
	var canvas := CanvasLayer.new()
	_viewport.add_child(canvas)
	var banner := ColorRect.new()
	banner.position = Vector2(0, CELL.y - 34)
	banner.size = Vector2(CELL.x, 34)
	banner.color = Color("#1a2029")
	canvas.add_child(banner)
	_label = Label.new()
	_label.position = Vector2(12, 6)
	_label.add_theme_font_size_override("font_size", 15)
	banner.add_child(_label)
	var views := Image.create(CELL.x * 4, CELL.y * 2, false, Image.FORMAT_RGB8)
	var colours := Image.create(CELL.x * 3, CELL.y * 2, false, Image.FORMAT_RGB8)
	var tiers := Image.create(CELL.x * 3, CELL.y * 2, false, Image.FORMAT_RGB8)
	var poses := Image.create(CELL.x * 5, CELL.y * 2, false, Image.FORMAT_RGB8)

	for lod in 2:
		_spawn(0, 0)
		await _tick(20)
		_pause_pose()
		for angle in VIEWS.size():
			await _tile(views, angle, lod, ANGLES[angle], VIEWS[angle])
		for n in 3:
			_pawn.squad_id = n
			_pawn.armor_tier = 0
			_apply_paint()
			await _tile(colours, n, lod, ANGLES[3], "Squad %d" % (n + 1))
			_pawn.squad_id = 0
			_pawn.armor_tier = n + 1
			_apply_paint()
			await _tile(tiers, n, lod, ANGLES[3], "Tier " + ["I", "II", "III"][n])
		for pose in POSES.size():
			await _pose(POSES[pose])
			await _tile(poses, pose, lod, ANGLES[3], POSES[pose], pose >= 2)
	var renderer := RenderingServer.get_current_rendering_method()
	for item in [["views", views], ["squads", colours], ["tiers", tiers], ["poses", poses]]:
		var path := _out.path_join("%s_%s.png" % [renderer, item[0]])
		var result: Error = (item[1] as Image).save_png(path)
		if result != OK:
			push_error("A2 capture could not save %s with error %d" % [path, result])
			quit(1)
			return
		print("A2_CAPTURE ", path)
	quit(0)


func _light(rotation: Vector3, colour: Color, energy: float, shadows: bool) -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = rotation
	light.light_color = colour
	light.light_energy = energy
	light.shadow_enabled = shadows
	_viewport.add_child(light)


func _spawn(squad: int, tier: int) -> void:
	if is_instance_valid(_stage):
		_stage.free()
	_stage = Node3D.new()
	_viewport.add_child(_stage)
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_pawn.set_meta("armour_set", "murmillo")
	_pawn.squad_id = squad
	_pawn.armor_tier = tier
	_stage.add_child(_pawn)
	_pawn.set_physics_process(false)


func _apply_paint() -> void:
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	for armour in [model.armor, model.armor_far]:
		SoldierSquadColour.apply(armour, _pawn.squad_id)
		SoldierSquadColour.apply_tier(armour, _pawn.armor_tier)


func _pause_pose() -> void:
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.active = false


func _tick(count: int) -> void:
	for frame in count:
		await process_frame


func _pose(which: String) -> void:
	_spawn(0, 0)
	await _tick(12)
	match which:
		"Run":
			_pawn.velocity = Vector3.FORWARD * _pawn.get_move_speed()
			await _tick(34)
		"Crouch":
			_pawn.free_crouch_amount = 1.0
			_pawn._apply_body_shapes()
			await _tick(36)
		"Downed":
			_pawn.life = Pawn.Life.DOWNED
			_pawn.velocity = Vector3.FORWARD * 0.9
			await _tick(43)
		"Death":
			_pawn.bridge.state.health = 0
			_pawn.bridge.state.shield = 0
			_pawn.set_active(false)
			await _tick(124)
	_pause_pose()


func _tile(sheet: Image, col: int, lod: int, angle: Vector3, title: String, low: bool = false) -> void:
	var far_m := float(SoldierLook.config()["gun"]["far_m"])
	var distance := far_m + 6.0 if lod == 1 else 4.0
	var focus := Vector3(0, 0.63 if low else 1.04, 0)
	var offset := (angle + Vector3.UP * (0.29 if low else 0.14)).normalized() * distance
	_camera.position = focus + offset
	_camera.look_at(focus)
	_label.text = "%s  |  %s LOD" % [title, "Far" if lod == 1 else "Near"]
	if title == "Death" and lod == 1:
		var corpse := _stage.find_child("SoldierCorpse", true, false)
		if corpse != null:
			var armour := corpse.get_node("Skeleton3D/Armor") as MeshInstance3D
			var model := _pawn.get_node("SoldierModel") as SoldierModel
			armour.mesh = model.armor_far.mesh
			SoldierSquadColour.copy(model.armor_far, armour)
			_label.text = "Death  |  Far LOD preview"
	await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	sheet.blit_rect(image, Rect2i(Vector2i.ZERO, CELL), Vector2i(col, lod) * CELL)
