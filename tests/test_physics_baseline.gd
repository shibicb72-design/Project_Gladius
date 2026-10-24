extends "res://tests/test_case.gd"
## Pawn movement on the test map must feel the same on Jolt as it did on GodotPhysics3D (G1).
## Pawns are driven through InputFrame (the output of the input-abstraction layer) at the fixed physics
## tick. The GodotPhysics3D numbers are recorded in data/physics_baseline.json; Jolt must stay within
## its tolerance_pct (5%) of them. Run with `-- --only=physics_baseline` to see the measured numbers.

const _Range := preload("res://scenes/test/weapon_range.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const BASELINE_PATH := "res://data/physics_baseline.json"
const MAX_TOLERANCE_PCT := 5.0
const TICKS := 180
const SETTLE_TICKS := 20
const LANE_SPACING := 1.0
const LANE_WIDTH := 0.9
const OBSTACLE_Z := -2.0
const STEP_DEPTH := 3.0
const RAMP_LENGTH := 6.0
const RAMP_THICKNESS := 1.0
const RAMP_CLIMB_M := 1.0
## Walk speed is the average over this tick window (steady state, after the acceleration ramp).
const WALK_FROM_TICK := 30
const WALK_TO_TICK := 90
const STEP_HEIGHTS_M: Array[float] = [
	0.005, 0.01, 0.015, 0.02, 0.025, 0.03, 0.035, 0.04, 0.045, 0.05, 0.055, 0.06, 0.065, 0.07, 0.075,
	0.08, 0.085, 0.09, 0.095, 0.10, 0.105, 0.11, 0.115, 0.12, 0.125, 0.13, 0.135, 0.14, 0.145, 0.15,
	0.16, 0.17, 0.18, 0.19, 0.20, 0.22, 0.24, 0.26, 0.28, 0.30, 0.35, 0.40, 0.45, 0.50]
const SLOPE_DEGREES: Array[float] = [
	30.0, 32.0, 34.0, 36.0, 38.0, 39.0, 40.0, 41.0, 42.0, 43.0, 44.0, 44.5, 45.0, 45.5, 46.0, 47.0,
	48.0, 49.0, 50.0, 52.0, 54.0, 56.0, 58.0, 60.0]


func test_movement_within_tolerance_of_physics_baseline() -> void:
	var base: Dictionary = _read_baseline()
	assert_true(not base.is_empty(), "data/physics_baseline.json loads")
	var tol: float = float(base.get("tolerance_pct", 0.0))
	assert_true(tol > 0.0 and tol <= MAX_TOLERANCE_PCT, "baseline tolerance_pct is in (0, 5]")
	var measured: Dictionary = await measure_all()
	print("PHYSICS_METRICS %s" % JSON.stringify(measured))
	var recorded: Dictionary = base.get("metrics", {})
	for key in measured:
		assert_true(recorded.has(key), "baseline has metric " + str(key))
		if not recorded.has(key):
			continue
		var b: float = float(recorded[key])
		var v: float = float(measured[key])
		var diff_pct: float = absf(v - b) / b * 100.0 if b != 0.0 else 100.0
		assert_true(diff_pct <= tol, "%s: %.4f vs baseline %.4f (%.2f%% > %.1f%%)" % [key, v, b, diff_pct, tol])


func test_physics_engine_is_jolt() -> void:
	assert_eq(str(ProjectSettings.get_setting("physics/3d/physics_engine")), "Jolt Physics", "physics engine")


## Measures every metric on fresh copies of the test map. Returns metric name -> float.
func measure_all() -> Dictionary:
	var out: Dictionary = await _measure_free_lane()
	out["max_step_up_m"] = await _measure_max_step()
	out["max_slope_deg"] = await _measure_max_slope()
	return out


func _read_baseline() -> Dictionary:
	var text := FileAccess.get_file_as_string(BASELINE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _new_world() -> Node3D:
	var scene: Node3D = _Range.instantiate()
	_tree().root.add_child(scene)
	var course := StaticBody3D.new()
	course.name = "Course"
	course.collision_layer = 1
	scene.add_child(course)
	return scene


func _add_box(scene: Node3D, size: Vector3, xform: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = xform
	scene.get_node("Course").add_child(cs)


func _spawn(scene: Node3D, x: float) -> Dictionary:
	var p: Pawn = _PawnScene.instantiate()
	scene.add_child(p)
	p.global_position = Vector3(x, 0.0, 0.0)
	var f := InputFrame.new()
	p.set_frame(f)
	return {"pawn": p, "frame": f}


func _ticks(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func _measure_free_lane() -> Dictionary:
	var scene := _new_world()
	var walker := _spawn(scene, 40.0)
	var jumper := _spawn(scene, 42.0)
	await _ticks(SETTLE_TICKS)
	var wp: Pawn = walker["pawn"]
	var jp: Pawn = jumper["pawn"]
	var start_y: float = jp.global_position.y
	var wf: InputFrame = walker["frame"]
	var jf: InputFrame = jumper["frame"]
	wf.move = Vector2(0.0, -1.0)
	jf.jump_pressed = true
	jf.jump_just_pressed = true
	var z_from := 0.0
	var z_to := 0.0
	var apex := 0.0
	var air_ticks := 0
	var landed := false
	for t in TICKS:
		await _tree().physics_frame
		jf.jump_just_pressed = false
		if t == WALK_FROM_TICK:
			z_from = wp.global_position.z
		if t == WALK_TO_TICK:
			z_to = wp.global_position.z
		apex = maxf(apex, jp.global_position.y - start_y)
		if not landed:
			if jp.is_on_floor() and t > 0:
				landed = true
			else:
				air_ticks += 1
	scene.queue_free()
	var tps: float = float(Engine.physics_ticks_per_second)
	return {
		"walk_speed_mps": (z_from - z_to) / (float(WALK_TO_TICK - WALK_FROM_TICK) / tps),
		"jump_apex_m": apex,
		"jump_air_time_s": float(air_ticks) / tps,
	}


func _measure_max_step() -> float:
	var scene := _new_world()
	var lanes: Array = []
	var x0 := -0.5 * LANE_SPACING * float(STEP_HEIGHTS_M.size() - 1)
	for i in STEP_HEIGHTS_M.size():
		var x: float = x0 + LANE_SPACING * float(i)
		var h: float = STEP_HEIGHTS_M[i]
		_add_box(scene, Vector3(LANE_WIDTH, h, STEP_DEPTH),
				Transform3D(Basis.IDENTITY, Vector3(x, h * 0.5, OBSTACLE_Z - STEP_DEPTH * 0.5)))
		lanes.append(_spawn(scene, x))
	await _ticks(SETTLE_TICKS)
	for lane in lanes:
		lane["frame"].move = Vector2(0.0, -1.0)
	await _ticks(TICKS)
	var best := 0.0
	for i in lanes.size():
		var p: Pawn = lanes[i]["pawn"]
		if p.global_position.z < OBSTACLE_Z - STEP_DEPTH - 0.5:
			best = maxf(best, STEP_HEIGHTS_M[i])
	scene.queue_free()
	return best


func _measure_max_slope() -> float:
	var scene := _new_world()
	var lanes: Array = []
	var x0 := -0.5 * LANE_SPACING * float(SLOPE_DEGREES.size() - 1)
	for i in SLOPE_DEGREES.size():
		var x: float = x0 + LANE_SPACING * float(i)
		var ang := deg_to_rad(SLOPE_DEGREES[i])
		# Top surface starts flush with the floor at OBSTACLE_Z and rises toward -z.
		var dir := Vector3(0.0, sin(ang), -cos(ang))
		var normal := Vector3(0.0, cos(ang), sin(ang))
		var center := Vector3(x, 0.0, OBSTACLE_Z) + dir * RAMP_LENGTH * 0.5 - normal * RAMP_THICKNESS * 0.5
		_add_box(scene, Vector3(LANE_WIDTH, RAMP_THICKNESS, RAMP_LENGTH),
				Transform3D(Basis(Vector3.RIGHT, ang), center))
		lanes.append(_spawn(scene, x))
	await _ticks(SETTLE_TICKS)
	for lane in lanes:
		lane["frame"].move = Vector2(0.0, -1.0)
	var max_y: Array[float] = []
	max_y.resize(lanes.size())
	max_y.fill(0.0)
	for t in TICKS:
		await _tree().physics_frame
		for i in lanes.size():
			max_y[i] = maxf(max_y[i], (lanes[i]["pawn"] as Pawn).global_position.y)
	var best := 0.0
	for i in lanes.size():
		if max_y[i] >= RAMP_CLIMB_M:
			best = maxf(best, SLOPE_DEGREES[i])
	scene.queue_free()
	return best
