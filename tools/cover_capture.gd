extends SceneTree
## M2 C1b: frame-sequence proof captures of the cover rework (Cover button, auto-snap, cover camera, slide, lean / rise
## fire, Aim hold, the exits, the dimmed Fire buttons). Run windowed (needs a display), ONE process at a time:
##   godot.cmd --path . --resolution 2520x1080 --fixed-fps 60 --script res://tools/cover_capture.gd -- --out=<dir> --seed=1 --states=a,b
## Each state boots a FRESH real local match (the real local pawn, game HUD and touch HUD) in an offscreen SubViewport of
## 2520x1080 at 420 dpi, builds a flat arena far from the map (cover walls with visible meshes, targets, pillars) and
## drives the game the way tests/test_cover_*_c1b.gd do: real touch events on the touch HUD's button rects, the touch
## provider's move_value for the stick. MatchRoot's own physics step runs (nothing is paused). It saves one JPG per
## (60 / fps) physics frames from ~0.3 s before the first input to ~0.5 s after the motion ends:
##   <out>/<state>/<state>_NNN.jpg
## and prints one line per state with the cover states seen in order and the frame count. Presentation only: nothing
## here feeds back into the game code. Options: --out=<dir> --seed=<n> --states=<comma list> --fps=<n, default 30>.
## --fixed-fps 60 makes one rendered frame exactly one physics tick, so saving a frame never changes game time.

const STATES: Array[String] = ["enter_button", "enter_auto", "slide", "lean_fire", "rise_fire", "aim_hold", "exit_stick",
		"exit_cover", "exit_sprint", "fire_dim"]
const _MatchScene := preload("res://scenes/match/match.tscn")
const SIZE := Vector2i(2520, 1080)
const PRE := 18   # frames before the first input (0.3 s)
const POST := 30  # frames after the motion ends (0.5 s)
const HIGH_H := 2.2
const LOW_H := 1.1
## Arena x centres: the walls all have their face on z = 0 (normal +z); the pawn stands on +z facing -z.
const X_HIGH := 1000.0   # 6 m wide HIGH wall
const X_LOW := 1025.0    # 4 m wide LOW wall
const X_LONG := 960.0    # 16 m wide HIGH wall (the middle is 8 m from either edge)

var _out := "build/cover_shots"
var _seed := 0
var _fps := 30
var _states: Array[String] = []
var _svp: SubViewport
var _match: MatchRoot
var _pawn: Pawn
var _rig: CameraRig
var _touch: Control
var _cfg: Dictionary
var _fno := 0
var _rec := false
var _rec_start := 0
var _rec_n := 0
var _rec_dir := ""
var _rec_state := ""
var _seq: Array[String] = []
var _failed := 0
var _old_profile: Dictionary
var _old_dpi := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--seed="):
			_seed = int(a.substr(7))
		elif a == "--legacy-head":  # M2 AN3: before-captures of the pre-AN3 head and body (SoldierRig.head_legacy)
			SoldierRig.head_legacy = true
		elif a.begins_with("--fps="):
			_fps = maxi(1, int(a.substr(6)))
		elif a.begins_with("--states="):
			for s in a.substr(9).split(",", false):
				_states.append(s)
	if _states.is_empty():
		_states = STATES.duplicate()
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _log(line: String) -> void:
	print("[cover_capture] " + line)


func _cover_state() -> String:
	return CoverController.State.keys()[_pawn.cover.state] if _pawn != null and _pawn.cover != null else "none"


## One physics frame; while recording, saves a frame every (60 / fps) frames and notes cover state changes.
func _step(n: int = 1) -> void:
	for i in n:
		await physics_frame
		_fno += 1
		var cs := _cover_state()
		if _seq.is_empty() or _seq[-1] != cs:
			_seq.append(cs)
		if _rec and (_fno - _rec_start) % maxi(1, roundi(60.0 / _fps)) == 0:
			await RenderingServer.frame_post_draw
			var img := _svp.get_texture().get_image()
			var err := img.save_jpg(_rec_dir.path_join("%s_%03d.jpg" % [_rec_state, _rec_n]), 0.85)
			if err != OK:
				_failed += 1
				_log("SAVE failed %s %d: %s" % [_rec_state, _rec_n, error_string(err)])
			_rec_n += 1


func _until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await _step()
	return cond.call()


func _settled() -> bool:
	return _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0 \
			and not _pawn.is_cover_turning()


func _free_fp() -> bool:
	return _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0


func _ev(point: Vector2, down: bool, index: int) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = point
	_svp.push_input(event, true)


func _tap(point: Vector2, index: int = 47) -> void:
	_ev(point, true, index)
	await _step(2)
	_ev(point, false, index)
	await _step(1)


func _cover_button() -> Vector2:
	return _touch.get_button_rect(_touch.SHOULDER_KEY).get_center()


func _fire_button() -> Vector2:
	return _touch.get_button_rect(_touch.RIGHT_FIRE_KEY).get_center()


func _aim_button() -> Vector2:
	return (_touch._buttons["aim"] as Control).get_global_rect().get_center()


func _lock_button() -> Vector2:
	return (_touch.lock_button as Control).get_global_rect().get_center()


func _stick(v: Vector2) -> void:
	_touch.provider.move_value = v


# --- arena ------------------------------------------------------------------------------------------------------

func _box(at: Vector3, size: Vector3, color: Color, tagged: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var b := BoxShape3D.new()
	b.size = size
	shape.shape = b
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mat.emission_enabled = true  # the match's low sun leaves wall faces in shadow; a little self light keeps them readable
	mat.emission = color
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	body.add_child(mi)
	if tagged:
		body.add_to_group(&"cover_wall")
	_match.add_child(body)
	return body


func _build_arena() -> void:
	_box(Vector3(1000, -0.1, 0), Vector3(160, 0.2, 80), Color(0.42, 0.45, 0.36), false)
	# Cover walls, face on z = 0, 1 m thick behind it.
	_box(Vector3(X_HIGH, HIGH_H * 0.5, -0.5), Vector3(6, HIGH_H, 1), Color(0.62, 0.5, 0.38), true)
	_box(Vector3(X_LOW, LOW_H * 0.5, -0.5), Vector3(4, LOW_H, 1), Color(0.5, 0.56, 0.62), true)
	_box(Vector3(X_LONG, HIGH_H * 0.5, -0.5), Vector3(16, HIGH_H, 1), Color(0.55, 0.42, 0.42), true)
	# Dark stripes on each wall face (not tagged, not solid: a thin visual) so camera motion reads against the wall.
	for wall in [[X_HIGH, 6.0, HIGH_H], [X_LOW, 4.0, LOW_H], [X_LONG, 16.0, HIGH_H]]:
		var n := int(float(wall[1]) / 1.0)
		for i in n:
			if i % 2 == 0:
				_stripe(Vector3(float(wall[0]) - float(wall[1]) * 0.5 + 0.5 + i, float(wall[2]) * 0.5, 0.01), float(wall[2]))
	# Targets (red posts) and pillars (grey) along both sides of each wall, in front of it, for parallax and shots.
	for x in [X_HIGH + 9.0, X_HIGH + 15.0, X_HIGH - 9.0, X_HIGH - 15.0, X_LOW - 10.0, X_LOW + 9.0, X_LOW + 16.0,
			X_LONG - 13.0, X_LONG + 13.0, X_LONG + 20.0]:
		_box(Vector3(x, 0.9, 2.5), Vector3(0.6, 1.8, 0.6), Color(0.8, 0.2, 0.18), false)
		_box(Vector3(x + 2.0, 1.5, 7.0), Vector3(0.5, 3.0, 0.5), Color(0.6, 0.6, 0.62), false)
	for i in 14:
		_box(Vector3(940.0 + i * 8.0, 1.5, 12.0), Vector3(0.5, 3.0, 0.5), Color(0.55, 0.55, 0.6), false)


func _stripe(at: Vector3, height: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.18, height, 0.02)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.15, 0.12)
	mi.material_override = mat
	mi.position = at
	_match.add_child(mi)


# --- boot / teardown --------------------------------------------------------------------------------------------

func _boot(x: float, z: float) -> bool:
	_old_profile = AppFlow.profile
	_old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {}
	PlatformServices.dpi_override = 420.0
	load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"
	_svp = SubViewport.new()
	_svp.size = SIZE
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_svp)
	_match = _MatchScene.instantiate()
	_match.auto_start = false
	_match.fill_bots = false
	_match.bake_navmesh = false
	_svp.add_child(_match)
	await physics_frame
	_match.director.load_config()
	if _seed != 0:
		_match.seed_override = _seed
	if not _match.begin():
		_log("match_started=false")
		return false
	_pawn = _match.local_player
	_rig = _pawn.get_node("CameraRig") as CameraRig
	_touch = _match.get_node("Hud/TouchHud")
	_touch.cfg["force_touch_hud"] = true
	_touch.refresh_visibility()
	_build_arena()
	_cfg = DataRegistry.new().load_file("res://data/cover.json")
	_place(x, z)
	await _step(2)
	var w := _pawn.loadout.get_active()
	if w != null and w.def.is_melee():
		_pawn.loadout.swap()
	await _step(40)
	return true


func _place(x: float, z: float) -> void:
	_pawn.position = Vector3(x, 0, z)
	_pawn.rotation = Vector3.ZERO
	_pawn.pitch = 0.0
	_pawn.velocity = Vector3.ZERO
	_pawn.enable_cover(_cfg)


func _teardown() -> void:
	_rec = false
	_stick(Vector2.ZERO)
	_touch.provider.cancel_sprint_lock()
	for action in ["fire", "jump", "aim", "swap_shoulder", "cover"]:
		Input.action_release(action)
	_svp.queue_free()
	await process_frame
	await process_frame
	_svp = null
	AppFlow.profile = _old_profile
	PlatformServices.dpi_override = _old_dpi
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""


func _begin_rec(state: String) -> void:
	_rec_state = state
	_rec_dir = _out.path_join(state)
	DirAccess.make_dir_recursive_absolute(_rec_dir)
	for f in DirAccess.get_files_at(_rec_dir):
		DirAccess.remove_absolute(_rec_dir.path_join(f))
	_rec_n = 0
	_seq = []
	_rec_start = _fno
	_rec = true


## Unrecorded: the Cover button through the real touch HUD until the entry and the turn along the wall have settled.
func _enter_quiet() -> bool:
	await _tap(_cover_button())
	var ok := await _until(_settled, 150)
	_stick(Vector2.ZERO)
	await _step(10)
	return ok


# --- run --------------------------------------------------------------------------------------------------------

func _run() -> void:
	for state in _states:
		if not STATES.has(state):
			_log("unknown state %s (known: %s)" % [state, ", ".join(STATES)])
			_failed += 1
			continue
		await _dispatch(state)
	_log("RESULT failed=%d" % _failed)
	quit(1 if _failed > 0 else 0)


func _dispatch(state: String) -> void:
	# Each state: a fresh match at its own start pose, the sequence, a log line, teardown.
	var start := _start_of(state)
	if not await _boot(start.x, start.y):
		_failed += 1
		return
	await call("_do_" + state)
	_rec = false
	_log("STATE %s frames=%d cover_states=%s" % [state, _rec_n, ">".join(_seq)])
	if _rec_n == 0:
		_failed += 1
	await _teardown()


## Start pose (x, z) of the pawn per state.
func _start_of(state: String) -> Vector2:
	match state:
		"enter_button":
			return Vector2(X_HIGH, 3.4)
		"enter_auto":
			return Vector2(X_HIGH, 2.4)
		"lean_fire", "aim_hold", "exit_sprint":
			return Vector2(X_HIGH + 2.75, 0.6)  # 0.25 m from the wall's right end
		"rise_fire":
			return Vector2(X_LOW, 0.6)
		"fire_dim":
			return Vector2(X_LONG, 0.6)
	return Vector2(X_HIGH, 0.6)


func _do_enter_button() -> void:
	await _begin_rec("enter_button")
	await _step(PRE)
	_stick(Vector2(0, -0.6))
	await _until(func(): return _pawn.global_position.z <= 1.3, 240)
	_stick(Vector2.ZERO)
	await _step(24)  # standing at the wall: the Cover button highlighted
	await _tap(_cover_button())
	await _until(_settled, 150)
	await _step(POST)


func _do_enter_auto() -> void:
	await _begin_rec("enter_auto")
	await _step(PRE)
	_stick(Vector2(0, -0.8))
	await _until(func(): return _pawn.cover.state != CoverController.State.FREE, 240)
	await _until(func(): return _pawn.cover.state == CoverController.State.IN_COVER, 60)
	_stick(Vector2.ZERO)
	await _until(_settled, 150)
	await _step(POST)


func _do_slide() -> void:
	if not await _enter_quiet():
		_log("slide: entry did not settle")
		_failed += 1
	await _begin_rec("slide")
	await _step(PRE)
	_stick(Vector2(0, -0.8))  # the cover camera looks along the wall: stick forward slides toward the edge it faces
	var last := _pawn.global_position.x
	var still := 0
	for i in 240:
		await _step()
		var x := _pawn.global_position.x
		still = still + 1 if absf(x - last) < 0.0005 else 0
		last = x
		if still >= 8:
			break
	await _step(12)
	_stick(Vector2(0, 0.8))
	await _step(36)
	_stick(Vector2.ZERO)
	await _step(POST)


func _do_lean_fire() -> void:
	if not await _enter_quiet():
		_log("lean_fire: entry did not settle")
		_failed += 1
	await _begin_rec("lean_fire")
	await _step(PRE)
	_ev(_fire_button(), true, 42)
	await _step(48)
	_ev(_fire_button(), false, 42)
	await _step(24)
	await _until(func(): return _pawn.cover.state == CoverController.State.IN_COVER and not _pawn.cover.aimed_out, 60)
	await _step(POST)


func _do_rise_fire() -> void:
	await _begin_rec("rise_fire")
	await _step(PRE)
	await _tap(_cover_button())
	await _until(_settled, 150)
	await _step(36)  # the automatic crouch behind LOW cover, in view
	_ev(_fire_button(), true, 42)
	await _step(48)
	_ev(_fire_button(), false, 42)
	await _step(24)
	await _until(func(): return _pawn.cover.state == CoverController.State.IN_COVER and not _pawn.cover.aimed_out, 60)
	await _step(POST)


func _do_aim_hold() -> void:
	if not await _enter_quiet():
		_log("aim_hold: entry did not settle")
		_failed += 1
	await _begin_rec("aim_hold")
	await _step(PRE)
	await _tap(_aim_button(), 43)
	await _step(60)
	await _tap(_aim_button(), 43)
	await _step(24)
	await _until(func(): return _pawn.cover.state == CoverController.State.IN_COVER and not _pawn.cover.aimed_out, 60)
	await _step(POST)


func _do_exit_stick() -> void:
	if not await _enter_quiet():
		_log("exit_stick: entry did not settle")
		_failed += 1
	await _begin_rec("exit_stick")
	await _step(PRE)
	# Away from the wall: the camera-right component along the wall's normal (+z) decides the stick's x sign.
	var away := 1.0 if _pawn.global_basis.x.dot(_pawn.cover.normal) > 0.0 else -1.0
	_stick(Vector2(away, 0))
	await _until(func(): return _pawn.cover.state == CoverController.State.EXITING or _pawn.cover.state == CoverController.State.FREE, 90)
	await _step(30)  # keeps walking 0.5 s
	_stick(Vector2.ZERO)
	await _until(_free_fp, 90)
	await _step(POST)


func _do_exit_cover() -> void:
	if not await _enter_quiet():
		_log("exit_cover: entry did not settle")
		_failed += 1
	await _begin_rec("exit_cover")
	await _step(PRE)
	await _tap(_cover_button())
	await _until(_free_fp, 120)
	await _step(POST)


func _do_exit_sprint() -> void:
	if not await _enter_quiet():
		_log("exit_sprint: entry did not settle")
		_failed += 1
	await _begin_rec("exit_sprint")
	_stick(Vector2(0, -0.5))
	await _step(PRE)
	await _tap(_lock_button(), 44)
	await _until(func(): return _pawn.cover.state == CoverController.State.FREE, 60)
	await _step(60)  # leaves and sprints
	_stick(Vector2.ZERO)
	_touch.provider.cancel_sprint_lock()
	await _step(POST)


func _do_fire_dim() -> void:
	await _begin_rec("fire_dim")
	await _step(PRE)
	await _tap(_cover_button())
	await _until(_settled, 150)
	await _step(POST)
	_log("fire_dim: fire_dimmed=%s cover_fire_available=%s" % [_touch.fire_dimmed, _pawn.cover_fire_available()])
