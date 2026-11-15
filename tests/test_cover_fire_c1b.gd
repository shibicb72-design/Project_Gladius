extends "res://tests/test_case.gd"
## M2 C1b stage 4: Fire in cover, Aim hold and the removal of the old path (decisions 3-6, 9; fixes 4, 7, 9, 15, 16,
## 21). The frame's fire bit (the right Fire button, Left Fire, mouse, keyboard, gamepad) leans out past an open edge
## of HIGH cover (PEEK_LEFT / PEEK_RIGHT) or rises over LOW cover (IN_COVER), fires as a normal weapon trigger once
## the out pose is complete and the wall ray is clear, and returns on release after fire_return_delay_s. The Aim
## toggle alone holds out. Behind HIGH cover away from an edge Fire does nothing and the Fire buttons dim. Every number
## is an OQ-COVER placeholder in data/cover.json.
## Pawn-level tests follow tests/test_cover_move_exit_c1b.gd (manual pawn ticks, the rig on real physics frames); the
## HUD tests use a real match with viewport touches (tests/test_cover_fire_fix.gd).

const DT := 1.0 / 60.0
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig
var _wall: StaticBody3D
var _shots := 0
## Per shot: [state, aimed_out, the collider the full-range shot ray hits or null].
var _shot_log: Array = []


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")


func _ticks(seconds: float) -> int:
	return ceili(seconds / DT - 0.0001)


func _body(at: Vector3, size: Vector3, tagged: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	if tagged:
		body.add_to_group(&"cover_wall")
	_root.add_child(body)
	return body


## Floor, a cover wall whose face is on z = 0 (normal +z, tangent +x), `width` m wide centred on x = 0, `height` m tall,
## and the local pawn with its rig at `at`, facing the wall. Enters by the Cover button. keep_turn true lets the
## automatic turn finish (the view looks ALONG the wall toward CoverController.side); false keeps the view on the wall.
func _fixture(at: Vector3, height: float = 2.2, keep_turn: bool = true, width: float = 4.0, enter: bool = true) -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	_body(Vector3(0, -0.1, 0), Vector3(30, 0.2, 30), false)
	_wall = _body(Vector3(0, height * 0.5, -0.5), Vector3(width, height, 1), true)
	_pawn = _PawnScene.instantiate()
	_pawn.position = at
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_pawn.loadout.get_active().fire_mode = "auto"  # the match default (a bare pawn has the legacy 3-round burst)
	_pawn.enable_cover(_cfg())
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	_shots = 0
	_shot_log = []
	_pawn.shot.connect(_on_shot)
	await _tree().physics_frame
	await _tree().physics_frame
	if not enter:
		return
	_pawn.handle_action_press("cover")
	for i in 150:
		if not keep_turn and _pawn.in_cover():
			_pawn.cancel_cover_turn()
		await _tick()
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0 and not _pawn.is_cover_turning():
			break
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "fixture: in cover")


func _on_shot(origin: Vector3, direction: Vector3, _id: String) -> void:
	_shots += 1
	var range_m := _pawn.loadout.get_active().def.range_m
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * range_m, 1, [_pawn.get_rid()])
	var hit := _pawn.get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = null if hit.is_empty() else hit["collider"]
	_shot_log.append([_pawn.cover.state, _pawn.cover.aimed_out, collider])
	if _pawn.in_cover():
		assert_true(collider == null or not (collider as Node).is_in_group(&"cover_wall"), "every cover shot clears the wall for the full weapon range")
		assert_true(_pawn.cover.aimed_out and _pawn.cover.crouch_amount == 0.0, "every cover shot leaves the completed, standing out pose")


func _tick(move: Vector2 = Vector2.ZERO, fire: bool = false, aim: bool = false) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.fire_pressed = fire
	frame.fire_just_pressed = fire and not _pawn._frame.fire_pressed
	frame.aim_pressed = aim
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _run(count: int, move: Vector2 = Vector2.ZERO, fire: bool = false, aim: bool = false) -> void:
	for i in count:
		await _tick(move, fire, aim)


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


# ---- data -----------------------------------------------------------------------------------------

func test_stage4_data_keys_and_every_lock_respects_the_cap() -> void:
	var cfg := _cfg()
	var cap := float(cfg["input_lock_max_s"])
	var note := str(cfg["_c1b_stage4_todo"])
	for key in ["OQ-COVER", "aim_out_s", "aim_return_s", "fire_return_delay_s", "lean_reach_m", "peek_offset_m", "[Shibi default]"]:
		assert_true(note.contains(key), "the stage 4 OQ-COVER note names %s" % key)
	assert_eq(float(cfg["aim_out_s"]), 0.12, "lean / rise out placeholder")
	assert_eq(float(cfg["aim_return_s"]), 0.15, "return placeholder")
	assert_eq(float(cfg["fire_return_delay_s"]), 0.2, "stay-out after a release placeholder")
	assert_eq(float(cfg["lean_reach_m"]), 0.5, "lean reach placeholder (was cover_edge_quickdraw_m)")
	for dead in ["fire_requires_peek", "quick_draw_stay_out", "cover_edge_quickdraw_m"]:
		assert_true(not cfg.has(dead), "the dead key %s is gone" % dead)
	var locks := CoverController.new(cfg).lock_durations()
	for key in ["enter_s", "exit_s", "aim_out_s", "aim_return_s"]:
		assert_true(locks.has(key), "lock %s listed" % key)
	for key in locks:
		assert_true(float(locks[key]) <= cap + 0.000001, "lock %s = %s s <= input_lock_max_s %s" % [key, locks[key], cap])
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	for dead in ["cover_fire", "cover_crouch", "cover_buttons"]:
		assert_true(not ui.has(dead), "ui.json %s is gone" % dead)
	assert_true(ui.has("cover_button") and ui.has("cover_fire_dim"), "ui.json keeps cover_button and has cover_fire_dim")
	assert_true(str(ui["cover_fire_dim"]["_todo"]).contains("OQ-COVER"), "the dim style is an OQ-COVER placeholder")
	for path in ["res://scripts/ui/cover_fire_button.gd", "res://scripts/ui/cover_crouch_button.gd"]:
		var users := 0
		for dir_path in ["res://scripts/ui", "res://scripts/systems", "res://scripts/classes"]:
			for file in DirAccess.get_files_at(dir_path):
				if file.ends_with(".gd") and FileAccess.get_file_as_string(dir_path + "/" + file).contains(path.get_file().get_basename() + ".gd"):
					users += 1
		assert_eq(users, 0, "%s is referenced by no game script" % path)


# ---- the lean, the rise and the return --------------------------------------------------------------

## Behind HIGH cover 0.35 m from the right end (inside lean_reach_m): Fire held leans out past the edge (PEEK_RIGHT,
## side and the camera side +1), fires once the pose is complete, stays out fire_return_delay_s after the release and
## then returns over aim_return_s. No recoil, no camera knockback.
func test_fire_held_at_an_edge_leans_fires_and_returns_after_the_delay() -> void:
	await _fixture(Vector3(1.65, 0, 0.6))
	var cfg := _pawn.cover.config
	var anchor := _pawn.global_position
	var pitch := _pawn.pitch
	var yaw := _pawn.rotation.y
	var ammo := _pawn.loadout.get_active().ammo_in_mag
	var t_pose := -1
	var t_shot := -1
	var kicked := false
	for i in 40:
		await _tick(Vector2.ZERO, true)
		if i == 0:
			assert_eq(_pawn.cover.state, CoverController.State.PEEK_RIGHT, "the first Fire tick leans toward the open right edge")
		if t_pose < 0 and _pawn.cover.aimed_out:
			t_pose = i + 1
		if t_shot < 0 and _shots > 0:
			t_shot = i + 1
		kicked = kicked or _rig.get_knockback() != Vector2.ZERO
	var out_x := _pawn.global_position.x
	print("C1B FIRE edge lean: pose at %d ticks (%.3f s), first shot at %d ticks, out x %.3f, shots %d" % [t_pose, t_pose * DT, t_shot, out_x, _shots])
	assert_true(t_pose >= _ticks(float(cfg["aim_out_s"])) and t_pose <= _ticks(float(cfg["aim_out_s"])) + 6, "the lean completes over aim_out_s (speed bounded)")
	assert_true(t_shot == t_pose, "the first round leaves on the tick the pose completes")
	assert_true(_shots >= 1 and _pawn.loadout.get_active().ammo_in_mag < ammo, "Fire fires and spends ammo")
	assert_true(absf(out_x - (2.0 + float(cfg["peek_offset_m"]))) < 0.02, "leaned past the edge by peek_offset_m (x %.3f)" % out_x)
	assert_eq(_pawn.cover.side, 1, "the cover side is the lean side")
	assert_true(absf(_rig.get_cover_side() - 1.0) < 0.001, "the cover camera side follows")
	assert_true(absf(_pawn.pitch - pitch) < 1e-6 and absf(_pawn.rotation.y - yaw) < 1e-6, "no recoil in cover")
	assert_true(not kicked and _rig.get_knockback() == Vector2.ZERO, "no camera knockback in cover")
	var delay := _ticks(float(cfg["fire_return_delay_s"]))
	for i in delay - 1:
		await _tick()
	assert_true(_pawn.cover.aim_out_amount == 1.0 and _pawn.cover.state == CoverController.State.PEEK_RIGHT, "still out one tick before fire_return_delay_s")
	await _run(2)
	assert_true(_pawn.cover._draw_returning, "the return starts after fire_return_delay_s")
	var back := -1
	for i in 40:
		await _tick()
		if _pawn.cover.state == CoverController.State.IN_COVER:
			back = i + 1
			break
	print("C1B FIRE edge return: back in IN_COVER %d ticks after the return began" % back)
	assert_true(back >= _ticks(float(cfg["aim_return_s"])) - 1 and back <= _ticks(float(cfg["aim_return_s"])) + 8, "the return takes about aim_return_s")
	assert_true(_pawn.global_position.distance_to(anchor) < 0.02, "back at the wall anchor")
	await _cleanup()


## A short tap (one Fire tick) is buffered: it leans out, fires exactly one round and returns.
func test_fire_tap_at_an_edge_fires_one_round_and_returns() -> void:
	await _fixture(Vector3(1.65, 0, 0.6))
	await _tick(Vector2.ZERO, true)
	await _run(60)
	assert_eq(_shots, 1, "a one-tick tap fires exactly one round")
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "and returns")
	assert_true(not _pawn.cover._draw_active and _pawn.cover.aim_out_amount == 0.0, "the draw ended")
	await _cleanup()


## LOW 1.1 m cover in the middle of the wall: Fire rises in place (IN_COVER, crouch to 0), fires and crouches back.
func test_fire_over_low_cover_rises_fires_and_crouches_back() -> void:
	await _fixture(Vector3(0, 0, 0.6), 1.1)
	await _run(15)
	assert_true(_pawn.cover.crouched and _pawn.cover.crouch_amount == 1.0, "LOW cover: crouched automatically")
	assert_true(_pawn.cover.fire_available() and _pawn.cover_fire_available(), "LOW cover: Fire available along the whole wall")
	var anchor := _pawn.global_position
	var t_up := -1
	for i in 30:
		await _tick(Vector2.ZERO, i < 6)
		assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "the rise stays in IN_COVER (no lean)")
		if t_up < 0 and _pawn.cover.crouch_amount == 0.0:
			t_up = i + 1
	print("C1B FIRE low rise: standing after %d ticks, shots %d" % [t_up, _shots])
	assert_true(t_up > 0 and t_up <= _ticks(float(_pawn.cover.config["aim_out_s"])) + 1, "the rise takes aim_out_s")
	assert_eq(_shots, 1, "a short press fires one round over the wall")
	await _run(40)
	assert_true(_pawn.cover.crouch_amount == 1.0 and not _pawn.cover._draw_active, "crouched back automatically")
	assert_true(_pawn.global_position.distance_to(anchor) < 0.01, "the rise is in place")
	await _cleanup()


# ---- where Fire does nothing (fix 7) ----------------------------------------------------------------

## Behind HIGH cover 2 m from both ends: Fire does not lean, rise or fire and spends no ammo; Aim only does its ADS.
func test_high_cover_away_from_an_edge_fire_does_nothing_aim_only_zooms() -> void:
	await _fixture(Vector3(0, 0, 0.6))
	var start := _pawn.global_position
	var ammo := _pawn.loadout.get_active().ammo_in_mag
	assert_true(not _pawn.cover.fire_available() and not _pawn.cover_fire_available(), "no lean or rise possible here")
	await _run(60, Vector2.ZERO, true)
	assert_eq(_shots, 0, "Fire held does not fire")
	assert_eq(_pawn.loadout.get_active().ammo_in_mag, ammo, "no ammo spent")
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "no lean")
	assert_true(_pawn.global_position.distance_to(start) < 0.0001, "the pawn does not move")
	await _run(5)
	await _run(60, Vector2.ZERO, false, true)
	assert_true(_pawn.aiming and _pawn.aim_blend == 1.0, "Aim still zooms (ADS)")
	assert_true(_pawn.cover.aim_out_amount == 0.0 and _pawn.cover.state == CoverController.State.IN_COVER, "Aim does not lean either")
	await _run(60, Vector2.ZERO, true, true)
	assert_eq(_shots, 0, "Aim plus Fire does not fire")
	await _cleanup()


# ---- the ENTERING / EXITING buffer (fix 7) ---------------------------------------------------------

## A Fire press during ENTERING is buffered and taken when IN_COVER settles (here: at an edge, so it leans and fires);
## a press during EXITING is taken in FREE. Each state lasts at most input_lock_max_s.
func test_fire_press_buffered_through_entering_and_exiting() -> void:
	await _fixture(Vector3(1.65, 0, 0.6), 2.2, false, 4.0, false)
	var cap := float(_pawn.cover.config["input_lock_max_s"])
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.ENTERING, "the Cover press enters")
	_pawn.cancel_cover_turn()
	await _tick(Vector2.ZERO, true)
	assert_eq(_pawn.cover.state, CoverController.State.ENTERING, "the press lands in ENTERING")
	var settled := -1
	for i in 60:
		await _tick()
		_pawn.cancel_cover_turn()
		if settled < 0 and _pawn.cover.state != CoverController.State.ENTERING:
			settled = i + 2
	assert_true(settled > 0 and settled * DT <= cap + DT + 0.0001, "ENTERING settled within the cap (%d ticks)" % settled)
	assert_eq(_shots, 1, "the press buffered in ENTERING fired one round from the lean")
	assert_true(_shot_log[0][0] == CoverController.State.PEEK_RIGHT and _shot_log[0][1], "from the completed lean")
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "and returned")
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "the Cover press exits")
	await _tick(Vector2.ZERO, true)
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "the press lands in EXITING")
	for i in 20:
		await _tick()
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "the exit completed")
	assert_eq(_shots, 2, "the press buffered in EXITING fired one round")
	assert_eq(_shot_log[1][0], CoverController.State.FREE, "in FREE")
	await _cleanup()


## A press during ENTERING onto HIGH cover away from an edge is dropped when the state settles: no shot later.
func test_buffered_press_dropped_where_fire_is_unavailable() -> void:
	await _fixture(Vector3(0, 0, 0.6), 2.2, false, 4.0, false)
	_pawn.handle_action_press("cover")
	await _tick(Vector2.ZERO, true)
	await _run(60)
	assert_eq(_shots, 0, "no lean possible: the buffered press is dropped")
	assert_true(not _pawn.cover._fire_buffered, "nothing stays buffered")
	await _cleanup()


# ---- Aim (fix 16) -----------------------------------------------------------------------------------

## The Aim toggle alone leans out at an edge and holds out until it is toggled off; Fire then fires from the held pose
## at once; Aim off returns.
func test_aim_alone_holds_out_until_off_and_fire_fires_from_it() -> void:
	await _fixture(Vector3(1.65, 0, 0.6))
	await _run(120, Vector2.ZERO, false, true)
	assert_true(_pawn.cover.aimed_out and _pawn.cover.state == CoverController.State.PEEK_RIGHT, "Aim alone leans out and holds two seconds")
	assert_true(_pawn.aiming and _pawn.aim_blend == 1.0, "and zooms")
	assert_eq(_shots, 0, "Aim never fires")
	await _tick(Vector2.ZERO, true, true)
	assert_eq(_shots, 1, "Fire fires from the held pose on the press tick")
	await _run(30, Vector2.ZERO, false, true)
	assert_true(_pawn.cover.aimed_out, "still out while Aim is on")
	var back := -1
	for i in 40:
		await _tick()
		if _pawn.cover.state == CoverController.State.IN_COVER:
			back = i + 1
			break
	assert_true(back > 0 and back <= _ticks(float(_pawn.cover.config["aim_return_s"])) + 8, "Aim off returns at once (%d ticks)" % back)
	await _cleanup()


# ---- the empty magazine (decision 9) ------------------------------------------------------------------

## Fire held with one round left: the round empties the magazine, the soldier returns with Fire still held, the existing
## combat.auto_reload_on_empty reloads, and the still-held Fire goes out again and fires. With no reserve it just
## returns and stays, even with Aim held.
func test_empty_magazine_returns_reloads_and_goes_out_again() -> void:
	await _fixture(Vector3(1.65, 0, 0.6))
	var w := _pawn.loadout.get_active()
	w.ammo_in_mag = 1
	assert_true(w.reserve > 0, "fixture: reserve left")
	var returned := false
	var reloaded_out := false
	for i in 240:
		await _tick(Vector2.ZERO, true)
		if _shots == 1 and w.reloading and _pawn.cover.state == CoverController.State.IN_COVER and _pawn.cover.aim_out_amount == 0.0:
			returned = true
		if returned and not w.reloading and _shots >= 2:
			reloaded_out = true
			break
	print("C1B FIRE empty mag: returned=%s reloaded_and_out_again=%s shots=%d" % [returned, reloaded_out, _shots])
	assert_true(returned, "the empty magazine sends the soldier back with Fire held, and the reload starts by itself")
	assert_true(reloaded_out, "after the reload the held Fire goes out again and fires")
	await _run(30)
	w.ammo_in_mag = 1
	w.reserve = 0
	var before := _shots
	await _run(60, Vector2.ZERO, true, true)
	assert_eq(_shots, before + 1, "the last round fires")
	assert_true(w.ammo_in_mag == 0 and not w.reloading, "no reserve: no reload")
	assert_true(_pawn.cover.state == CoverController.State.IN_COVER and _pawn.cover.aim_out_amount == 0.0, "back in cover even with Fire and Aim held")
	await _cleanup()


# ---- the lean side (decision 9) ---------------------------------------------------------------------

func _side_probe(left: float, right: float) -> Dictionary:
	return {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": Vector3(0, 0, 0.45),
		"basis": Basis.IDENTITY, "distance_m": 0.45, "left_m": left, "right_m": right, "height_m": 2.2,
		"muzzle_height_m": 1.3, "usable_left_m": left, "usable_right_m": right, "slide_speed_mps": 4.0,
		"shot_clear": true, "stand_clear": true}


func test_lean_side_is_the_open_edge_or_the_stick_when_both_are_open() -> void:
	var cases := [
		[0.3, 0.4, Vector2.ZERO, -1, "both open, no stick: the nearer (left) edge"],
		[0.45, 0.2, Vector2.ZERO, 1, "both open, no stick: the nearer (right) edge"],
		[0.3, 0.4, Vector2(1, 0), 1, "both open: the stick's along-wall direction (right)"],
		[0.45, 0.2, Vector2(-1, 0), -1, "both open: the stick's along-wall direction (left)"],
		[INF, 0.4, Vector2(-1, 0), 1, "only the right edge open: right, whatever the stick"],
		[0.4, INF, Vector2(1, 0), -1, "only the left edge open: left, whatever the stick"],
	]
	for c in cases:
		var k := CoverController.new(_cfg())
		assert_true(k.request_cover(_side_probe(c[0], c[1])), "enters")
		for i in 20:
			k.tick(DT, Vector2.ZERO, false, _side_probe(c[0], c[1]))
		assert_eq(k.state, CoverController.State.IN_COVER, "settled")
		k.tick(DT, c[2], true, _side_probe(c[0], c[1]))
		assert_eq(k.side, c[3], c[4])
		assert_eq(k.state, CoverController.State.PEEK_LEFT if c[3] < 0 else CoverController.State.PEEK_RIGHT, c[4] + " (state)")


## On a 0.9 m wide HIGH wall both ends are within reach; the entry side is the nearer (right) end, a Fire press with
## the stick toward the left end leans left, and the cover camera's side follows it there.
func test_camera_side_follows_the_lean_side() -> void:
	await _fixture(Vector3(0.05, 0, 0.6), 2.2, false, 0.9)
	assert_eq(_pawn.cover.side, 1, "fixture: entry side is the nearer right end")
	await _run(30)
	assert_true(absf(_rig.get_cover_side() - 1.0) < 0.001, "fixture: camera on the right")
	# The view stays on the wall (facing -z), so stick left is world -x, the left end.
	await _tick(Vector2(-1, 0), true)
	assert_eq(_pawn.cover.state, CoverController.State.PEEK_LEFT, "leans toward the stick's end")
	assert_eq(_pawn.cover.side, -1, "the cover side follows the lean")
	var side_s := float(DataRegistry.new().get_camera_cfg()["cover"]["side_ease_s"]["value"])
	await _run(_ticks(side_s) + 4, Vector2.ZERO, true)
	assert_true(absf(_rig.get_cover_side() + 1.0) < 0.001, "the cover camera side eased to the left (%s)" % _rig.get_cover_side())
	await _cleanup()


# ---- recoil and knockback (decision 6, fix 15) -------------------------------------------------------

## No recoil and no camera knockback for any cover shot (lean and rise); outside cover a shot still kicks the camera.
func test_no_recoil_no_knockback_in_cover_and_knockback_outside() -> void:
	for height in [2.2, 1.1]:
		await _fixture(Vector3(1.65, 0, 0.6), height)
		var pitch := _pawn.pitch
		var yaw := _pawn.rotation.y
		var kicked := false
		for i in 90:
			await _tick(Vector2.ZERO, true)
			kicked = kicked or _rig.get_knockback() != Vector2.ZERO
		assert_true(_shots >= 2, "height %s: several cover shots" % height)
		assert_true(absf(_pawn.pitch - pitch) < 1e-6 and absf(_pawn.rotation.y - yaw) < 1e-6, "height %s: no recoil" % height)
		assert_true(not kicked, "height %s: no camera knockback in cover" % height)
		await _run(40)
		_pawn.handle_action_press("cover")
		for i in 30:
			await _tick()
		assert_eq(_pawn.cover.state, CoverController.State.FREE, "height %s: left cover" % height)
		var before := _shots
		await _tick(Vector2.ZERO, true)
		assert_true(_shots > before, "height %s: a shot outside cover" % height)
		assert_true(_rig.get_knockback() != Vector2.ZERO, "height %s: outside cover the shot kicks the camera" % height)
		await _cleanup()


# ---- the wall rule (fix 21 and the full-range ray) -------------------------------------------------------

## A target straight behind HIGH cover is never hit from IN_COVER or mid-lean: no round leaves before the lean is
## complete with the full-range ray clear; every round clears the wall. With the view turned back across the wall
## the out pose fires nothing and keeps its ammo.
func test_shots_never_pass_through_the_wall() -> void:
	await _fixture(Vector3(1.65, 0, 0.6), 2.2, false)
	var target := _body(Vector3(1.65, 1.3, -4.0), Vector3(0.6, 2.6, 0.2), false)
	for i in 40:
		await _tick(Vector2.ZERO, true)
	assert_true(_shots >= 1, "the completed lean fires")
	for entry in _shot_log:
		assert_true(entry[0] == CoverController.State.PEEK_RIGHT and entry[1], "every round from the completed lean")
		assert_true(entry[2] != target, "the target straight behind the wall is never hit")
		assert_true(entry[2] == null or not (entry[2] as Node).is_in_group(&"cover_wall"), "no round into the wall")
	var before := _shots
	var ammo := _pawn.loadout.get_active().ammo_in_mag
	_pawn.rotation.y = PI / 4.0  # back across the wall: toward -x and -z, into the wall's end
	for i in 30:
		await _tick(Vector2.ZERO, true)
		_pawn.rotation.y = PI / 4.0
	assert_true(not _pawn._cover_probe.shot_clear(_pawn), "fixture: the ray hits the wall")
	assert_eq(_shots, before, "no round into the wall")
	assert_eq(_pawn.loadout.get_active().ammo_in_mag, ammo, "no ammo spent against the wall")
	await _cleanup()


## Fix 21: a rise shot over 1.0 m and 1.2 m LOW cover at small down-pitch. The view faces the wall; the target stands
## 6 m behind the wall face. Every pitch is measured and printed; the rule (CoverProbe.shot_clear) is not changed.
func test_fix21_rise_shot_over_1_0_and_1_2_m_cover_at_small_down_pitch() -> void:
	var report: Array[String] = []
	for height in [1.0, 1.2]:
		for pitch_deg in [-1.0, -2.0, -3.0, -5.0, -8.0]:
			await _fixture(Vector3(0, 0, 0.6), height, false)
			var target := _body(Vector3(0, 1.0, -6.0), Vector3(1.0, 2.0, 0.2), false)
			_pawn.pitch = deg_to_rad(pitch_deg)
			await _run(15)
			for i in 30:
				await _tick(Vector2.ZERO, i < 25)
			var clear := _pawn._cover_probe.shot_clear(_pawn)
			var hit := false
			for entry in _shot_log:
				hit = hit or entry[2] == target
			report.append("height %.1f m pitch %.0f deg: shot_clear=%s shots=%d target_hit=%s" % [height, pitch_deg, clear, _shots, hit])
			if pitch_deg >= -2.0:
				assert_true(hit, "height %.1f m at %.0f deg down: the rise shot hits the target behind the wall" % [height, pitch_deg])
			if not clear:
				assert_eq(_shots, 0, "height %.1f m at %.0f deg: blocked by shot_clear, no round" % [height, pitch_deg])
			await _cleanup()
	for line in report:
		print("C1B FIX21 " + line)


# ---- the vanished wall while firing -------------------------------------------------------------------

## The cover body is freed while the soldier is leaned out and firing: the pawn leaves through EXITING to FREE with no
## script error (the runner fails a test on any logged error) and keeps firing normally in FREE.
func test_vanished_wall_while_firing_exits_without_an_error() -> void:
	await _fixture(Vector3(1.65, 0, 0.6))
	for i in 30:
		await _tick(Vector2.ZERO, true)
	assert_true(_pawn.cover.aimed_out and _shots >= 1, "fixture: out and firing")
	_wall.free()
	var states: Array = []
	for i in 60:
		await _tick(Vector2.ZERO, true)
		if states.is_empty() or states[-1] != _pawn.cover.state:
			states.append(_pawn.cover.state)
	assert_eq(states[0], CoverController.State.EXITING, "the vanished wall exits through EXITING")
	assert_eq(states[-1], CoverController.State.FREE, "then FREE")
	assert_eq(_shot_log[-1][0], CoverController.State.FREE, "Fire keeps working in FREE")
	await _cleanup()


# ---- the touch HUD in a real match (decision 5, fixes 7, 9) --------------------------------------------

var match_scene: MatchRoot
var touch: Control
var old_size: Vector2i
var old_profile: Dictionary
var old_dpi: float


func frames(count: int) -> void:
	for i in count:
		await _tree().physics_frame
		await _tree().process_frame


func _match_box(at: Vector3, dimensions: Vector3, tagged: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var bounds := BoxShape3D.new()
	bounds.size = dimensions
	shape.shape = bounds
	body.add_child(shape)
	if tagged:
		body.add_to_group(&"cover_wall")
	match_scene.add_child(body)
	return body


## 2520 x 1080 at 420 dpi with the custom stick and Left Fire on; a 4 m, 2.2 m wall far from the map with the pawn
## `edge` m from its right end; enters with the real Cover button and lets the automatic turn finish.
func _match_setup(edge: float) -> void:
	old_size = _tree().root.size
	old_profile = AppFlow.profile
	old_dpi = PlatformServices.dpi_override
	AppFlow.profile = {"left_fire_enabled": true}
	PlatformServices.dpi_override = 420.0
	_tree().root.size = Vector2i(2520, 1080)
	load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"
	match_scene = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.fill_bots = false
	match_scene.bake_navmesh = false
	_tree().root.add_child(match_scene)
	await _tree().process_frame
	match_scene.director.load_config()
	assert_true(match_scene.begin(), "real match begins")
	_pawn = match_scene.local_player
	touch = match_scene.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	touch.refresh_left_fire()
	_match_box(Vector3(1000, -0.1, 0), Vector3(30, 0.2, 30), false)
	_wall = _match_box(Vector3(1000, 1.1, -0.5), Vector3(4, 2.2, 1), true)
	_pawn.position = Vector3(1002 - edge, 0, 0.6)
	_pawn.rotation = Vector3.ZERO
	_pawn.pitch = 0.0
	_pawn.velocity = Vector3.ZERO
	_pawn.enable_cover(_cfg())
	_shots = 0
	_pawn.fired.connect(func(): _shots += 1)
	await frames(2)
	await _hold(touch.get_button_rect(touch.SHOULDER_KEY).get_center(), 2)
	for i in 90:
		await frames(1)
		if _pawn.cover.state == CoverController.State.IN_COVER and not _pawn.is_cover_turning():
			break
	touch.provider.move_value = Vector2.ZERO
	touch.provider.cancel_sprint_lock()
	await frames(2)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "fixture: the real Cover button entered")


func _match_cleanup() -> void:
	match_scene.queue_free()
	await _tree().process_frame
	_tree().root.size = old_size
	AppFlow.profile = old_profile
	PlatformServices.dpi_override = old_dpi
	load("res://scripts/ui/touch_hud.gd").move_stick_override = ""
	for action in ["fire", "jump", "aim", "swap_shoulder", "cover"]:
		Input.action_release(action)
	await _tree().process_frame


func _event_at(point: Vector2, down: bool, index: int = 48) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = _tree().root.get_screen_transform() * point
	_tree().root.push_input(event, false)


## Touch down, `count` frames, up, two frames. `seen` collects whether the HUD pressed "fire" while held.
var _fire_seen := false


func _hold(point: Vector2, count: int) -> void:
	_fire_seen = false
	_event_at(point, true)
	for i in count:
		await frames(1)
		_fire_seen = _fire_seen or Input.is_action_pressed("fire")
	_event_at(point, false)
	await frames(2)


func _look_point() -> Vector2:
	return Vector2(touch.size.x * 0.95, touch.size.y * 0.7)


func _fire_bg_alpha(key: String) -> float:
	var sb := (touch._buttons[key] as Button).get_theme_stylebox("normal") as StyleBoxFlat
	return sb.bg_color.a


func test_hud_only_the_fire_buttons_fire_in_cover_and_they_dim_away_from_an_edge() -> void:
	var dim: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["cover_fire_dim"]
	# Middle of HIGH cover: dimmed, and nothing fires.
	await _match_setup(2.0)
	await frames(2)
	assert_true(touch.fire_dimmed, "mid-wall HIGH cover: the Fire buttons dim")
	for key in [touch.RIGHT_FIRE_KEY, touch.LEFT_FIRE_KEY]:
		assert_true(absf(_fire_bg_alpha(key) - float(dim["bg_alpha"])) < 0.001, "%s uses the ui.json cover_fire_dim style" % key)
	await _hold(touch.get_button_rect(touch.RIGHT_FIRE_KEY).get_center(), 30)
	assert_eq(_shots, 0, "the dimmed right Fire does not fire")
	await _match_cleanup()
	# 0.35 m from the right end: not dimmed; right Fire and Left Fire fire; look-zone taps and holds do not.
	await _match_setup(0.35)
	await frames(2)
	assert_true(not touch.fire_dimmed, "at an edge the Fire buttons are not dimmed")
	assert_true(_fire_bg_alpha(touch.RIGHT_FIRE_KEY) > float(dim["bg_alpha"]) + 0.01, "normal Fire style at the edge")
	# M2 H1a: the look_hold_fire.hold_min_s data key is gone; a 60-frame hold is well past the old 0.2 s threshold.
	await _hold(_look_point(), 3)
	await frames(30)
	assert_true(not _fire_seen and _shots == 0, "a look-zone tap does not fire in cover")
	await _hold(_look_point(), 60)
	await frames(30)
	assert_true(not _fire_seen and _shots == 0, "a look-zone hold does not fire in cover")
	await _hold(touch.get_button_rect(touch.RIGHT_FIRE_KEY).get_center(), 30)
	assert_true(_fire_seen, "the right Fire button presses fire in cover")
	await frames(40)
	var after_right := _shots
	assert_true(after_right >= 1, "the right Fire button fires in cover (%d)" % after_right)
	await _hold(touch.get_button_rect(touch.LEFT_FIRE_KEY).get_center(), 30)
	await frames(40)
	assert_true(_fire_seen and _shots > after_right, "Left Fire fires in cover")
	# M2 H1a: outside cover the look-zone tap and hold do not fire either (was: outside cover a look-zone tap fired);
	# the right Fire button still does.
	await _hold(touch.get_button_rect(touch.SHOULDER_KEY).get_center(), 2)
	for i in 60:
		await frames(1)
		if _pawn.cover.state == CoverController.State.FREE:
			break
	await frames(5)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "left cover with the Cover button")
	assert_true(not touch.fire_dimmed, "no dim outside cover")
	var before := _shots
	await _hold(_look_point(), 3)
	await frames(20)
	assert_true(not _fire_seen and _shots == before, "outside cover a look-zone tap does not fire")
	await _hold(_look_point(), 60)
	await frames(20)
	assert_true(not _fire_seen and _shots == before, "outside cover a look-zone hold does not fire")
	await _hold(touch.get_button_rect(touch.RIGHT_FIRE_KEY).get_center(), 30)
	await frames(20)
	assert_true(_fire_seen and _shots > before, "outside cover the right Fire button fires")
	await _match_cleanup()
