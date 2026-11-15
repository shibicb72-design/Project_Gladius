extends SceneTree
## M2 C1a: desktop-render proof of the first-person view (the camera mode and the view model). Run windowed (needs
## a display; a window opens on the desktop):
##   godot --path . --resolution 2520x1080 --script res://tools/fp_capture.gd -- --out=build/shots
## Starts the real match scene (offline, no bots: the real local pawn and the match's CameraRig path), drives the local
## pawn with InputFrames (MatchRoot's own input step is paused for the run) and saves <out>/<tag>_<state>.png per
## state, rendered in an offscreen SubViewport of exactly --size (default 2520x1080, the Fold cover screen), with the
## HUD. Presentation only: nothing here feeds back into the game code.
## Options:
##   --out=<dir>          output folder (default build/shots, relative to the project)
##   --tag=<prefix>       file name prefix (default fp)
##   --states=a,b,...     states in order (default: all of STATES)
##   --size=WxH           image size (default 2520x1080)
##   --class=<class id>   the local pawn's class (default hastati: Pilum + Gladius Lux; sagittarii: Sagittarii rifle)
##   --hide-body          LOOK-DEV ONLY: hides the local third-person body, its ShotFx weapon box, tracer and flash
##                        (stage 4 will hide them by render layer in the game; until then they are drawn)
## States (later stages add the cover switch to this table):
##   standing, walk (4 frames across one bob cycle), fire (a frame with the view-model tracer), reload (mid motion),
##   switch (mid motion), blade (idle), blade_swing (mid swing), wall (walked into the nearest wall), look_down,
##   ads_mid (the first frame at or past half the aim blend), ads (full ADS: the red dot on the centre, no crosshair),
##   ads_fire (a full-ADS frame with the view-model tracer), ads_walk (full ADS while walking: damped bob).
##   The ADS states use the class's gun: --class=hastati (Pilum) or --class=sagittarii (Sagittarii rifle).

const STATES: Array[String] = ["standing", "walk", "fire", "reload", "switch", "blade", "blade_swing", "wall", "look_down",
		"ads_mid", "ads", "ads_fire", "ads_walk"]
const _MatchScene := preload("res://scenes/match/match.tscn")

var _out := "build/shots"
var _tag := "fp"
var _states: Array[String] = []
var _size := Vector2i(2520, 1080)
var _class := "hastati"
var _hide_body := false
var _svp: SubViewport
var _match: MatchRoot
var _pawn: Pawn
var _rig: CameraRig
var _frame := InputFrame.new()  # the next physics frame's input; reset after each step
var _failed := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--states="):
			for s in a.substr(9).split(",", false):
				_states.append(s)
		elif a.begins_with("--size="):
			var wh := a.substr(7).split("x")
			if wh.size() == 2:
				_size = Vector2i(int(wh[0]), int(wh[1]))
		elif a.begins_with("--class="):
			_class = a.substr(8)
		elif a == "--hide-body":
			_hide_body = true
	if _states.is_empty():
		_states = STATES.duplicate()
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _log(line: String) -> void:
	print("[fp_capture] " + line)


## One physics step with the queued input, then a fresh empty frame (just_pressed flags last one step).
func _step(n: int = 1) -> void:
	for i in n:
		await physics_frame
		_pawn.set_frame(_frame)
		var held := _frame
		_frame = InputFrame.new()
		_frame.move = held.move
		_frame.fire_pressed = held.fire_pressed and not held.fire_just_pressed
		_frame.sprint = held.sprint
		_frame.aim_pressed = held.aim_pressed  # ADS is held like AimToggle's resolved state


func _press(field: String) -> void:
	_frame.set(field + "_pressed", true)
	_frame.set(field + "_just_pressed", true)


func _save(state: String) -> void:
	await RenderingServer.frame_post_draw
	var path := _out.path_join("%s_%s.png" % [_tag, state])
	var err := _svp.get_texture().get_image().save_png(path)
	var vm := _rig.get_view_model()
	var cam := _rig.get_camera()
	var muzzle_px := cam.unproject_position(vm.get_muzzle_position()) if vm != null else Vector2.ZERO
	var dot := vm.get_red_dot() if vm != null else null
	var dot_px := cam.unproject_position(dot.global_position) if dot != null else Vector2(-1, -1)
	var hud := _match.get_node_or_null("Hud/GameHud") as GameHud
	_log("SAVE %s -> %s | weight=%.2f shown=%s visible=%s muzzle_px=%s swap=%s reload=%s swing=%s tracer=%s aim=%.2f fov=%.1f dot_px=%s dot_err_px=%.2f crosshair=%s" % [
			state, error_string(err), _rig.get_first_person_weight(), vm.get_shown_weapon_id() if vm else "-",
			vm.visible if vm else false, muzzle_px, vm.is_swapping() if vm else false, vm.is_reloading() if vm else false,
			vm.is_swinging() if vm else false, vm.is_tracer_visible() if vm else false, _pawn.aim_blend, cam.fov,
			dot_px, dot_px.distance_to(Vector2(_size) * 0.5), hud.crosshair.visible if hud != null else "?"])
	if err != OK:
		_failed += 1


func _run() -> void:
	_svp = SubViewport.new()
	_svp.size = _size
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_svp)
	_match = _MatchScene.instantiate()
	_match.auto_start = false
	_match.bake_navmesh = false
	_match.fill_bots = false
	_svp.add_child(_match)
	await physics_frame
	_match.director.load_config()
	if not _match.begin():
		_log("RESULT match_started=false")
		quit(1)
		return
	_pawn = _match.local_player
	if _pawn.class_id != _class:
		_pawn.setup(_class, _pawn.squad_id)
	_rig = _pawn.get_node("CameraRig") as CameraRig
	_match.set_physics_process(false)  # this tool feeds the local pawn's InputFrames
	if _hide_body:
		(_pawn.get_node("SoldierModel") as Node3D).visible = false
		_pawn.shot_fx.weapon_mesh.visible = false
		_pawn.shot_fx.tracer.layers = 0
		_pawn.shot_fx.flash.layers = 0
	await _step(40)
	var vm := _rig.get_view_model()
	_log("START class=%s weapon=%s view_model=%s near=%.3f fov=%.1f meshes=%d nodes=%d" % [_class,
			_pawn.loadout.get_active().def.id, vm != null, _rig.get_camera().near, _rig.get_camera().fov,
			vm.mesh_instances().size() if vm else 0, vm.find_children("*", "", true, false).size() if vm else 0])
	for state in _states:
		if not STATES.has(state):
			_log("unknown state %s (known: %s)" % [state, ", ".join(STATES)])
			_failed += 1
			continue
		match state:
			"standing":
				await _state_standing()
			"walk":
				await _state_walk()
			"fire":
				await _state_fire()
			"reload":
				await _state_reload()
			"switch":
				await _state_switch()
			"blade":
				await _state_blade()
			"blade_swing":
				await _state_blade_swing()
			"wall":
				await _state_wall()
			"look_down":
				await _state_look_down()
			"ads_mid":
				await _state_ads_mid()
			"ads":
				await _state_ads()
			"ads_fire":
				await _state_ads_fire()
			"ads_walk":
				await _state_ads_walk()
	_log("RESULT failed=%d" % _failed)
	quit(1 if _failed > 0 else 0)


func _gun_out() -> void:
	var w := _pawn.loadout.get_active()
	if w != null and w.def.is_melee():
		_press("swap_weapon")
		await _step(40)


func _state_standing() -> void:
	await _gun_out()
	await _step(20)
	await _save("standing")


func _state_walk() -> void:
	await _gun_out()
	_frame.move = Vector2(0, -1)
	await _step(45)
	var period := 1.0 / float(DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]["bob_hz"]["value"])
	var gap := maxi(1, roundi(period * 60.0 / 4.0))
	for i in 4:
		await _save("walk_%d" % i)
		await _step(gap)
	_frame.move = Vector2.ZERO
	await _step(30)


func _state_fire() -> void:
	await _gun_out()
	var vm := _rig.get_view_model()
	_press("fire")
	for i in 30:
		await _step()
		if vm.is_tracer_visible():
			var ep := vm.get_tracer_endpoints()
			_log("TRACER start=%s end=%s muzzle=%s px_start=%s" % [ep[0], ep[1], vm.get_muzzle_position(),
					_rig.get_camera().unproject_position(ep[0])])
			await _save("fire")
			break
	await _step(40)


func _state_reload() -> void:
	await _gun_out()
	_press("fire")
	await _step(40)
	_press("reload")
	await _step(1)
	var total := _pawn.loadout.get_active().def.reload_s
	await _step(roundi(total * 60.0 * 0.45))
	await _save("reload")
	await _step(roundi(total * 60.0) + 10)


func _state_switch() -> void:
	await _gun_out()
	_press("swap_weapon")
	await _step(1)
	var swap_s := float(DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]["swap_s"]["value"])
	await _step(maxi(1, roundi(swap_s * 60.0 * 0.4)))
	await _save("switch")
	await _step(40)


func _blade_out() -> void:
	var w := _pawn.loadout.get_active()
	if w == null or not w.def.is_melee():
		_press("swap_weapon")
		await _step(40)


func _state_blade() -> void:
	await _blade_out()
	await _step(10)
	await _save("blade")


func _state_blade_swing() -> void:
	await _blade_out()
	_press("fire")
	await _step(1)
	var swing_s := float(DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]["swing_s"]["value"])
	await _step(maxi(1, roundi(swing_s * 60.0 * 0.4)))
	await _save("blade_swing")
	await _step(40)


func _state_look_down() -> void:
	await _gun_out()
	_frame.look = Vector2(0.0, 0.35)
	await _step(1)
	await _step(20)
	await _save("look_down")
	_frame.look = Vector2(0.0, -0.35)
	await _step(1)
	await _step(10)


func _ads_off() -> void:
	_frame.aim_pressed = false
	_frame.move = Vector2.ZERO
	await _step(30)


func _state_ads_mid() -> void:
	await _gun_out()
	_frame.aim_pressed = true
	for i in 60:
		await _step()
		if _pawn.aim_blend >= 0.5:
			break
	_pawn.set_physics_process(false)  # hold the blend still while the frame renders
	await _save("ads_mid")
	_pawn.set_physics_process(true)
	await _ads_off()


func _state_ads() -> void:
	await _gun_out()
	_frame.aim_pressed = true
	await _step(30)
	await _save("ads")
	await _ads_off()


func _state_ads_fire() -> void:
	await _gun_out()
	_frame.aim_pressed = true
	await _step(30)
	var vm := _rig.get_view_model()
	_press("fire")
	for i in 30:
		await _step()
		if vm.is_tracer_visible():
			var ep := vm.get_tracer_endpoints()
			var cam := _rig.get_camera()
			_log("ADS TRACER start=%s end=%s px_start=%s px_dot=%s" % [ep[0], ep[1], cam.unproject_position(ep[0]),
					cam.unproject_position(vm.get_red_dot().global_position)])
			await _save("ads_fire")
			break
	await _step(40)
	await _ads_off()


func _state_ads_walk() -> void:
	await _gun_out()
	_frame.aim_pressed = true
	_frame.move = Vector2(0, -1)
	await _step(45)
	await _save("ads_walk")
	await _ads_off()


## Turns to the nearest wall around the eye (16 rays, 25 m) and walks into it for three seconds.
func _state_wall() -> void:
	await _gun_out()
	var space := _pawn.get_world_3d().direct_space_state
	var eye := _rig.get_camera().global_position
	var best := INF
	var best_dir := Vector3.ZERO
	for i in 16:
		var a := TAU * i / 16.0
		var dir := Vector3(-sin(a), 0.0, -cos(a))
		var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 25.0, Hitscan.MASK_WORLD)
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and eye.distance_to(hit["position"]) < best:
			best = eye.distance_to(hit["position"])
			best_dir = dir
	if best_dir == Vector3.ZERO:
		_log("WALL none within 25 m")
		_failed += 1
		return
	_pawn.rotation.y = atan2(-best_dir.x, -best_dir.z)
	_frame.move = Vector2(0, -1)
	await _step(180)
	_frame.move = Vector2.ZERO
	await _step(20)
	eye = _rig.get_camera().global_position
	var fwd := -_rig.get_camera().global_transform.basis.z
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + Vector3(fwd.x, 0.0, fwd.z).normalized() * 5.0, Hitscan.MASK_WORLD))
	_log("WALL start_dist=%.2f eye_to_wall_now=%s" % [best, ("%.3f" % eye.distance_to(hit["position"])) if not hit.is_empty() else "none"])
	await _save("wall")
