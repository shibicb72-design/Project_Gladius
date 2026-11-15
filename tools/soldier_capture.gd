extends SceneTree
## M2 AN1 commit 4: frame-sequence captures of the third-person soldier. Run windowed (needs a display), ONE process:
##   godot.cmd --path . --resolution 2520x1080 --fixed-fps 60 --script res://tools/soldier_capture.gd -- --out=<dir>
## Each state builds a fresh flat stage (ground with a 0.5 m grid so a planted foot can be judged against it, sun,
## sky) in an offscreen SubViewport and a fresh REAL pawn (scenes/player/pawn.tscn) with its real SoldierModel,
## AnimationTree, SoldierGait, SoldierPose, IK, ShotFx and DeathFx. The pawn's own physics step is off; the tool
## forces the read-only state the visuals read, the way the game sets it: velocity (and the position it implies),
## life (DOWNED), drop/air vertical speed, shield/health (a hit), set_active(false) (death), reload_started,
## show_shot_fx (a shot), loadout.swap + the shot signal (blade), SoldierPose.force (revive, the tool hook the
## pose already has). A fixed side / three-quarter camera follows the pawn's position (not its pose).
## Saves <out>/<state>/<state>_NNN.jpg every (60 / fps) frames and prints one line per state. Presentation only.
## Cover hug / lean / rise: use tools/cover_capture.gd (real cover sequences in a real match).
## Options: --out=<dir> --states=<comma list> --fps=<n, default 20> --size=<w>x<h> (default 1440x810);
## --procedural passes the library over (ClipLibrary.skip_sources) for before-captures of the code-built clips.
## Contact sheets: tools/contact_sheet.gd -- --dir=<out>/<state>.

const STATES: Array[String] = ["idle", "walk", "run", "sprint", "strafe", "strafe_left", "backpedal", "back_diag",
		"aim_fire", "reload", "hit", "jump", "death", "downed_crawl", "revive", "blade"]

var _out := "build/an1_after/c4_soldier"
var _fps := 20
var _size := Vector2i(1440, 810)
var _states: Array[String] = []
var _svp: SubViewport
var _stage: Node3D
var _pawn: Pawn
var _camera: Camera3D
var _cam_offset := Vector3(3.4, 1.25, -0.6)
var _fno := 0
var _saved := 0
var _dir := ""
var _state := ""
var _vy := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--fps="):
			_fps = maxi(1, int(a.substr(6)))
		elif a.begins_with("--size="):
			var wh := a.substr(7).split("x")
			_size = Vector2i(int(wh[0]), int(wh[1]))
		elif a.begins_with("--states="):
			for s in a.substr(9).split(",", false):
				_states.append(s)
		elif a == "--procedural":  # before-captures: the code-built clips, library passed over
			ClipLibrary.skip_sources.assign(["ual"])
	if _states.is_empty():
		_states = STATES.duplicate()
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _log(line: String) -> void:
	print("[soldier_capture] " + line)


func _run() -> void:
	_svp = SubViewport.new()
	_svp.size = _size
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_svp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_svp)
	for state in _states:
		await _capture(state)
	_log("DONE out=" + _out)
	quit(0)


func _build_stage() -> void:
	_stage = Node3D.new()
	_stage.name = "Stage"
	_svp.add_child(_stage)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.56, 0.66, 0.78)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.62, 0.66, 0.72)
	environment.ambient_light_energy = 0.7
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = environment
	_stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	_stage.add_child(sun)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.58, 0.55, 0.5)
	floor_mesh.material_override = floor_mat
	ground.add_child(floor_mesh)
	_stage.add_child(ground)
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.3, 0.29, 0.27)
	for i in range(-40, 41):
		for axis in 2:
			var line := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(0.015, 0.002, 40.0) if axis == 0 else Vector3(40.0, 0.002, 0.015)
			line.mesh = mesh
			line.material_override = line_mat
			line.position = Vector3(i * 0.5, 0.001, -10.0) if axis == 0 else Vector3(0.0, 0.001, -10.0 + i * 0.5)
			_stage.add_child(line)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_stage.add_child(_camera)
	_camera.current = true


func _spawn() -> void:
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_stage.add_child(_pawn)
	_pawn.set_physics_process(false)
	_pawn.global_position = Vector3.ZERO
	_vy = 0.0


func _aim_camera() -> void:
	var at := _pawn.global_position + Vector3(0, 0.95, 0)
	_camera.global_position = Vector3(_pawn.global_position.x, 0.0, _pawn.global_position.z) + _cam_offset
	_camera.look_at(at, Vector3.UP)


## One rendered frame at --fixed-fps 60 (delta 1/60): the pawn moves by its forced velocity first.
func _frame(velocity: Vector3) -> void:
	var delta := 1.0 / 60.0
	_pawn.velocity = Vector3(velocity.x, _vy, velocity.z)
	_pawn.global_position += Vector3(velocity.x, _vy, velocity.z) * delta
	if _pawn.global_position.y < 0.0:
		_pawn.global_position.y = 0.0
	_aim_camera()
	await process_frame
	_fno += 1
	if _fno % maxi(1, roundi(60.0 / _fps)) == 0:
		await RenderingServer.frame_post_draw
		var img := _svp.get_texture().get_image()
		img.save_jpg(_dir.path_join("%s_%03d.jpg" % [_state, _saved]), 0.85)
		_saved += 1


func _hold(seconds: float, velocity: Vector3 = Vector3.ZERO) -> void:
	for i in roundi(seconds * 60.0):
		await _frame(velocity)


func _capture(state: String) -> void:
	_build_stage()
	_spawn()
	_state = state
	_dir = _out.path_join(state)
	DirAccess.make_dir_recursive_absolute(_dir)
	_saved = 0
	_fno = 0
	_cam_offset = Vector3(3.4, 1.25, -0.6)
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	var speed := _pawn.get_move_speed()
	var registry := DataRegistry.new()
	var ratio := float(registry.get_movement_cfg()["strafe_back_ratio"]["value"])
	# settle the tree and the IK before recording
	for i in 6:
		await process_frame
	match state:
		"idle":
			_cam_offset = Vector3(2.4, 1.3, -2.4)
			await _hold(2.5)
		"walk":
			await _hold(2.0, Vector3.FORWARD * speed * float(SoldierRig.config()["gait"]["walk_slow_blend"]))
		"run":
			await _hold(1.6, Vector3.FORWARD * speed)
		"sprint":
			await _hold(1.6, Vector3.FORWARD * _pawn.get_max_move_speed())
		"strafe":
			_cam_offset = Vector3(0.6, 1.3, -3.6)
			await _hold(1.6, Vector3.RIGHT * speed * ratio)
		"strafe_left":
			_cam_offset = Vector3(0.6, 1.3, -3.6)
			await _hold(1.6, Vector3.LEFT * speed * ratio)
		"backpedal":
			await _hold(1.6, Vector3.BACK * speed * ratio)
		"back_diag":
			_cam_offset = Vector3(2.6, 1.3, -2.6)
			await _hold(1.6, (Vector3.BACK + Vector3.RIGHT).normalized() * speed * ratio)
		"aim_fire":
			_cam_offset = Vector3(2.0, 1.4, -2.6)
			for shot in 10:
				_pawn.show_shot_fx(_pawn.get_muzzle_position(), _pawn.get_muzzle_position() + Vector3(0, 0, -30))
				await _hold(0.12)
			await _hold(0.4)
		"reload":
			_cam_offset = Vector3(2.0, 1.4, -2.6)
			_pawn.reload_started.emit()
			await _hold(maxf(model.reload_duration_s, 0.5) + 0.5)
		"hit":
			_cam_offset = Vector3(2.4, 1.3, -2.4)
			await _hold(0.3)
			for hit in 3:
				_pawn.bridge.state.health -= 15.0 if hit < 2 else 45.0
				await _hold(0.7)
		"jump":
			await _hold(0.3, Vector3.FORWARD * speed)
			_vy = float(registry.get_movement_cfg()["jump_velocity"])
			for i in 120:
				_vy -= float(registry.get_movement_cfg()["gravity"]) / 60.0
				await _frame(Vector3.FORWARD * speed)
				if _pawn.global_position.y <= 0.0 and _vy < 0.0:
					_vy = 0.0
					break
			await _hold(0.6, Vector3.FORWARD * speed)
		"death":
			_cam_offset = Vector3(3.0, 1.6, -2.2)
			await _hold(0.3)
			_pawn.bridge.state.health = 0
			_pawn.bridge.state.shield = 0
			_pawn.set_active(false)
			await _hold(3.0)
		"downed_crawl":
			_pawn.life = Pawn.Life.DOWNED
			var pct := float(registry.load_file("res://data/br.json")["downed"]["downed_move_speed_pct"])
			_pawn.downed_move_speed_pct = pct
			await _hold(0.6)
			await _hold(2.4, Vector3.FORWARD * speed * pct / 100.0)
		"revive":
			_cam_offset = Vector3(2.6, 1.3, -2.6)
			model.pose.force["revive"] = 1.0
			await _hold(3.0)
		"blade":
			_cam_offset = Vector3(2.4, 1.4, -2.6)
			for attempt in 3:
				if _pawn.loadout.get_active().def.is_melee():
					break
				_pawn.loadout.swap()
			await _hold(0.5)
			for swing in 2:
				_pawn.shot.emit(_pawn.get_muzzle_position(), Vector3.FORWARD, _pawn.loadout.get_active().def.id)
				await _hold(0.8)
	_log("state=%s frames=%d gait_rate=%.3f" % [state, _saved, model.gait_rate if is_instance_valid(model) else 0.0])
	_stage.queue_free()
	await process_frame
	await process_frame
