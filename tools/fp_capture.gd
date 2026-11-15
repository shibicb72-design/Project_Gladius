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
##   --seed=<int>         match seed (MatchRoot.seed_override; default 0 = random): fixes the match's look and sun
##   --hide-body          NO-OP since stage 4 (kept so old command lines still run): the game itself now hides the
##                        local body from the first-person camera by render layer (camera.json first_person.body_layer)
## States:
##   standing, walk (4 frames across one bob cycle), fire (a frame with the view-model tracer), reload (mid motion),
##   switch (mid motion), blade (idle), blade_swing (mid swing), wall (walked into the nearest wall), look_down,
##   ads_mid (the first frame at or past half the aim blend), ads (full ADS: the red dot on the centre, no crosshair),
##   ads_fire (a full-ADS frame with the view-model tracer), ads_walk (full ADS while walking: damped bob).
##   The ADS states use the class's gun: --class=hastati (Pilum) or --class=sagittarii (Sagittarii rifle).
##   Stage 4: cover_in (walks into a real cover wall of the match map: cover_in_0..5 from first person through the
##   blend to settled third person), cover_out (one back input, then cover_out_0..5 back to settled first person; runs
##   the entry first, unsaved, if not in cover), shadow (the real local pawn in sunlight on open ground: the ground
##   patch under its chest's shadow vs a lit patch beside it, first person as shipped and a control that lets the
##   camera draw the body layer from the same eye; prints FP SHADOW lines, saves shadow_fp and shadow_control).
##   Every frame is held still while it renders (pawn, rig and view model paused) and logs body=<drawn by the camera>.

const STATES: Array[String] = ["standing", "walk", "fire", "reload", "switch", "blade", "blade_swing", "wall", "look_down",
		"ads_mid", "ads", "ads_fire", "ads_walk", "cover_in", "cover_out", "shadow"]
const SEQ_FRAMES := 6
const _MatchScene := preload("res://scenes/match/match.tscn")

var _out := "build/shots"
var _tag := "fp"
var _states: Array[String] = []
var _size := Vector2i(2520, 1080)
var _class := "hastati"
var _hide_body := false
var _seed := 0  # --seed: MatchRoot.seed_override (0 = the usual random match seed); picks the match's look and sun
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
		elif a.begins_with("--seed="):
			_seed = int(a.substr(7))
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
	_log("SAVE %s -> %s | weight=%.2f shown=%s visible=%s body=%s muzzle_px=%s swap=%s reload=%s swing=%s tracer=%s aim=%.2f fov=%.1f dot_px=%s dot_err_px=%.2f crosshair=%s cover=%s" % [
			state, error_string(err), _rig.get_first_person_weight(), vm.get_shown_weapon_id() if vm else "-",
			vm.visible if vm else false, _body_drawn(), muzzle_px, vm.is_swapping() if vm else false,
			vm.is_reloading() if vm else false, vm.is_swinging() if vm else false, vm.is_tracer_visible() if vm else false,
			_pawn.aim_blend, cam.fov, dot_px, dot_px.distance_to(Vector2(_size) * 0.5),
			hud.crosshair.visible if hud != null else "?", _cover_state()])
	if err != OK:
		_failed += 1


## True iff the rig camera draws the local body's render layer (stage 4: false in first person).
func _body_drawn() -> bool:
	var layer := _rig.get_body_layer()
	return layer > 0 and (_rig.get_camera().cull_mask & (1 << (layer - 1))) != 0


func _cover_state() -> String:
	return CoverController.State.keys()[_pawn.cover.state] if _pawn.cover != null else "none"


## Saves with the pawn, the rig and the view model paused, so the frame shows exactly the logged state.
func _save_still(state: String) -> void:
	var vm := _rig.get_view_model()
	var nodes: Array[Node] = [_pawn, _rig]
	if vm != null:
		nodes.append(vm)
	for n in nodes:
		n.set_physics_process(false)
	await _save(state)
	for n in nodes:
		n.set_physics_process(true)


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
	if _seed != 0:
		_match.seed_override = _seed
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
		_log("--hide-body is a no-op since stage 4 (the body layer hides the local body in first person)")
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
			"cover_in":
				await _state_cover_in()
			"cover_out":
				await _state_cover_out()
			"shadow":
				await _state_shadow()
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


# --- stage 4: the switch into cover and back, and the shadow of the hidden body -----------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return _pawn.get_world_3d().direct_space_state


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var ex: Array[RID] = [_pawn.get_rid()]
	return _space().intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Hitscan.MASK_WORLD, ex))


## Ground point under `p` (searched from 3 m above to 4 m below), or null.
func _ground(p: Vector3) -> Variant:
	var hit := _ray(p + Vector3.UP * 3.0, p + Vector3.DOWN * 4.0)
	return hit["position"] if not hit.is_empty() else null


## True iff a standing pawn capsule (a little wider than the real 0.4 m) at ground point `g` touches no world collider.
func _fits(g: Vector3) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = capsule
	q.transform = Transform3D(Basis.IDENTITY, g + Vector3.UP * 0.95)
	q.collision_mask = Hitscan.MASK_WORLD
	var ex: Array[RID] = [_pawn.get_rid()]
	q.exclude = ex
	return _space().intersect_shape(q, 1).is_empty()


## Teleports the local pawn to ground point `g`, facing the horizontal direction `facing`, at look pitch `pitch_rad`.
func _place(g: Vector3, facing: Vector3, pitch_rad: float) -> void:
	_frame = InputFrame.new()
	_pawn.global_position = g
	_pawn.velocity = Vector3.ZERO
	_pawn.rotation = Vector3(0.0, atan2(-facing.x, -facing.z), 0.0)
	_pawn.pitch = pitch_rad
	_rig.set_pitch(pitch_rad)


## The nearest real cover wall of the match map (group cover_wall, a box at least min_cover_height_m tall) with open
## ground 1.2 m in front of its +Z face: [ground point, face normal, wall name], or [] if none.
func _cover_spot() -> Array:
	var cfg := _pawn.cover.config
	var best: Array = []
	var best_d := INF
	for body in _match.get_tree().get_nodes_in_group(&"cover_wall"):
		if _match.map == null or not _match.map.is_ancestor_of(body):
			continue
		var shape := body.get_node_or_null("Shape") as CollisionShape3D
		if shape == null or not shape.shape is BoxShape3D:
			continue
		var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
		if half.y * 2.0 < float(cfg["min_cover_height_m"]):
			continue
		var n := shape.global_transform.basis.z
		n.y = 0.0
		if n.length() < 0.5:
			continue
		n = n.normalized()
		var g: Variant = _ground(shape.global_position + n * (half.z + 1.2))
		if g == null or not _fits(g):
			continue
		var d := (g as Vector3).distance_to(_pawn.global_position)
		if d < best_d:
			best_d = d
			best = [g, n, body.name]
	return best


## Walks the first-person pawn into a real map cover wall until IN_COVER and the blend is settled; with `save`,
## cover_in_0..5 span the switch: the frame ENTERING starts (first person), four frames through the blend, settled.
func _enter_cover(save: bool) -> bool:
	if _pawn.cover == null:
		_log("COVER none: the local pawn has no cover controller")
		_failed += 1
		return false
	var spot := _cover_spot()
	if spot.is_empty():
		_log("COVER no map cover wall with open ground in front")
		_failed += 1
		return false
	_place(spot[0], -(spot[1] as Vector3), 0.0)
	await _step(20)
	_log("COVER wall=%s at=%s state=%s weight=%.2f" % [spot[2], spot[0], _cover_state(), _rig.get_first_person_weight()])
	var gap := maxi(1, ceili(float(DataRegistry.new().get_camera_cfg()["first_person"]["blend_s"]["value"]) * 60.0 / 4.0))
	_frame.move = Vector2(0, -1)
	var saved := 0
	var since := -1
	for i in 240:
		await _step()
		if since < 0 and _pawn.cover.state != CoverController.State.FREE:
			since = 0
		elif since >= 0:
			since += 1
		if save and since >= 0 and saved < SEQ_FRAMES - 1 and since == saved * gap:
			await _save_still("cover_in_%d" % saved)
			saved += 1
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0 and since >= (SEQ_FRAMES - 2) * gap:
			break
	_frame.move = Vector2.ZERO
	await _step(45)
	if _pawn.cover.state != CoverController.State.IN_COVER:
		_log("COVER entry failed: state=%s" % _cover_state())
		_failed += 1
		return false
	if save:
		await _save_still("cover_in_%d" % (SEQ_FRAMES - 1))
	return true


func _state_cover_in() -> void:
	await _gun_out()
	await _enter_cover(true)


## Back input until EXITING starts; then no input. cover_out_0 is the first FREE frame (the blend's start, third
## person), four frames through the blend, and cover_out_5 settled in first person.
func _state_cover_out() -> void:
	if _pawn.cover == null or _pawn.cover.state != CoverController.State.IN_COVER:
		await _gun_out()
		if not await _enter_cover(false):
			return
	var gap := maxi(1, ceili(float(DataRegistry.new().get_camera_cfg()["first_person"]["blend_s"]["value"]) * 60.0 / 4.0))
	var held := await _back_out()
	_log("COVER exit state=%s weight=%.2f back_input_frames=%d" % [_cover_state(), _rig.get_first_person_weight(), held])
	# EXITING plays out in third person; the blend starts when the controller is FREE again.
	var wait := 0
	while wait < 180 and _pawn.cover.state != CoverController.State.FREE:
		await _step()
		wait += 1
	_log("COVER exit FREE after %d frames, weight=%.2f" % [wait, _rig.get_first_person_weight()])
	for k in SEQ_FRAMES - 1:
		await _save_still("cover_out_%d" % k)
		await _step(gap)
	for i in 120:
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			break
		await _step()
	await _step(20)
	await _save_still("cover_out_%d" % (SEQ_FRAMES - 1))
	if _pawn.cover.state != CoverController.State.FREE or _rig.get_first_person_weight() != 1.0:
		_log("COVER exit did not return to first person: state=%s weight=%.2f" % [_cover_state(), _rig.get_first_person_weight()])
		_failed += 1


## Holds back input (stick down) until the cover controller leaves IN_COVER (at most 90 frames), then releases it;
## returns the number of frames held.
func _back_out() -> int:
	_frame.move = Vector2(0, 1)
	var n := 0
	while n < 90 and _pawn.cover != null and _pawn.cover.state == CoverController.State.IN_COVER:
		await _step()
		n += 1
	_frame.move = Vector2.ZERO
	return n


## Screen pixel of world point `p` in the capture viewport, by the camera's own projection (as build/shadow_probe.gd:
## Camera3D.unproject_position was off under the project's canvas_items stretch there).
func _px(p: Vector3) -> Vector2:
	var cam := _rig.get_camera()
	var clip := cam.get_camera_projection() * Projection(cam.global_transform.affine_inverse()) * Vector4(p.x, p.y, p.z, 1.0)
	return Vector2((clip.x / clip.w * 0.5 + 0.5) * _size.x, (0.5 - clip.y / clip.w * 0.5) * _size.y)


## Median luminance of a 21x21 patch around pixel `px` (the median rides over grass blades and rain rings).
func _lum(img: Image, px: Vector2) -> float:
	var vals: Array[float] = []
	for dx in range(-10, 11):
		for dy in range(-10, 11):
			vals.append(img.get_pixel(clampi(int(px.x) + dx, 0, img.get_width() - 1), clampi(int(px.y) + dy, 0, img.get_height() - 1)).get_luminance())
	vals.sort()
	return vals[vals.size() / 2]


## Saves `state` held still and returns [lum at the shadow patch, lum at the reference patch].
func _shadow_shot(state: String, shadow_at: Vector3, ref_at: Vector3) -> Array:
	await _save_still(state)
	var img := _svp.get_texture().get_image()
	return [_lum(img, _px(shadow_at)), _lum(img, _px(ref_at))]


## [measured] fix 15 on the real local pawn: in sunlight on open ground, facing away from the sun and looking down at
## where its chest's shadow falls; the patch there vs a lit patch 0.8 m to the left, first person as shipped (body layer
## left out by the rig camera) and a control that lets the same camera, at the same eye, draw the body layer.
func _state_shadow() -> void:
	await _gun_out()
	if _pawn.cover != null and _pawn.cover.state != CoverController.State.FREE:
		await _back_out()
		await _step(60)
	var sun: DirectionalLight3D = null
	for n in _match.find_children("*", "DirectionalLight3D", true, false):
		if (n as DirectionalLight3D).is_visible_in_tree():
			sun = n
			break
	if sun == null:
		_log("FP SHADOW no DirectionalLight3D in the match")
		_failed += 1
		return
	var light_dir := -sun.global_transform.basis.z.normalized()  # the way the sunlight travels
	var elev := rad_to_deg(asin(clampf(-light_dir.y, -1.0, 1.0)))
	_log("FP SHADOW sun=%s shadow_enabled=%s rotation_deg=%s elevation_deg=%.1f mode=%d max_distance_m=%.1f" % [sun.name,
			sun.shadow_enabled, sun.rotation_degrees, elev, sun.directional_shadow_mode, sun.directional_shadow_max_distance])
	if not sun.shadow_enabled or light_dir.y >= -0.05:
		_log("FP SHADOW the map's sun casts no shadow here (shadow_enabled=%s, elevation %.1f deg)" % [sun.shadow_enabled, elev])
	var flat := Vector3(light_dir.x, 0.0, light_dir.z).normalized()
	var side := Vector3.UP.cross(flat).normalized()  # the screen's left when facing along the light (clear of the view model)
	var to_sun := -light_dir
	# The chest's shadow (0.7 of the head height): a wide dark patch, unlike the soft tip of the helmet's shadow.
	var head_y := (_pawn.get_node("Head") as Node3D).position.y * 0.7
	var eye_y := float(DataRegistry.new().get_camera_cfg()["first_person"]["eye_height_m"]["value"])
	var origin := _pawn.global_position
	var found: Array = []
	for r in range(0, 64, 4):
		for k in (1 if r == 0 else 16):
			var a := TAU * k / 16.0
			var g: Variant = _ground(origin + Vector3(cos(a), 0.0, sin(a)) * float(r))
			if g == null or not _fits(g):
				continue
			var head := (g as Vector3) + Vector3.UP * head_y
			var hit := _ray(head, head + light_dir * 30.0)
			if hit.is_empty() or absf((hit["position"] as Vector3).y - (g as Vector3).y) > 0.3:
				continue
			var shadow_at: Vector3 = hit["position"]
			var ref: Variant = _ground(shadow_at + side * 0.8)  # out of the chest shadow, inside the control's body frame
			if ref == null:
				continue
			var eye := (g as Vector3) + Vector3.UP * eye_y
			var lit := _ray(head, head + to_sun * 200.0).is_empty() and _ray(shadow_at + Vector3.UP * 0.05, shadow_at + to_sun * 200.0).is_empty() \
					and _ray((ref as Vector3) + Vector3.UP * 0.05, (ref as Vector3) + to_sun * 200.0).is_empty()
			var seen := _ray(eye, shadow_at + Vector3.UP * 0.05).is_empty() and _ray(eye, (ref as Vector3) + Vector3.UP * 0.05).is_empty()
			if lit and seen:
				found = [g, shadow_at, ref]
				break
		if not found.is_empty():
			break
	if found.is_empty():
		_log("FP SHADOW no open sunlit ground within 60 m of the spawn")
		_failed += 1
		return
	var g: Vector3 = found[0]
	var shadow_at: Vector3 = found[1]
	var ref_at: Vector3 = found[2]
	var eye := g + Vector3.UP * eye_y
	var aim := ((shadow_at + ref_at) * 0.5)
	var horiz := Vector2(aim.x - eye.x, aim.z - eye.z).length()
	_place(g, flat, -atan2(eye.y - aim.y, horiz))
	await _step(30)
	var bit := 1 << (_rig.get_body_layer() - 1)
	var cam := _rig.get_camera()
	_log("FP SHADOW spot ground=%s chest_shadow=%s ref=%s shadow_dist_m=%.2f weight=%.2f body_drawn=%s px_shadow=%s px_ref=%s" % [
			g, shadow_at, ref_at, Vector2(shadow_at.x - g.x, shadow_at.z - g.z).length(), _rig.get_first_person_weight(),
			_body_drawn(), _px(shadow_at), _px(ref_at)])
	if _rig.get_first_person_weight() != 1.0 or _body_drawn():
		_log("FP SHADOW not in first person at the spot (weight %.2f, cover %s)" % [_rig.get_first_person_weight(), _cover_state()])
		_failed += 1
		return
	var fp := await _shadow_shot("shadow_fp", shadow_at, ref_at)
	_log("FP SHADOW first_person shadow=%s lum_shadow=%.3f lum_ref=%.3f body_drawn=%s" % [fp[0] < fp[1] * 0.8, fp[0], fp[1], _body_drawn()])
	var mask := cam.cull_mask
	cam.cull_mask = mask | bit  # the control: third-person-style cull mask, same eye
	var ctl := await _shadow_shot("shadow_control", shadow_at, ref_at)
	_log("FP SHADOW control_layer_drawn shadow=%s lum_shadow=%.3f lum_ref=%.3f body_drawn=%s" % [ctl[0] < ctl[1] * 0.8, ctl[0], ctl[1], _body_drawn()])
	cam.cull_mask = mask
	if ctl[0] >= ctl[1] * 0.8:
		_log("FP SHADOW the control shows no pawn shadow either: the sun casts no measurable shadow at this spot")
