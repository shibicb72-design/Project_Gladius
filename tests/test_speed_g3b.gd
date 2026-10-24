extends "res://tests/test_case.gd"
## G3b-1: run 4.7 m/s and sprint 6.3 m/s (4.7 x 1.34), both community-measured on PC (not official); ramp rate stays 40 m/s^2.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _Range := preload("res://scenes/test/weapon_range.tscn")
const DT := 1.0 / 60.0
const RUN_MPS := 4.7
const SPRINT_MPS := 6.3
const RAMP_RATE := 40.0


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _pawn() -> Array:
	var scene: Node3D = _Range.instantiate()
	_tree().root.add_child(scene)
	var p: Pawn = _PawnScene.instantiate()
	scene.add_child(p)
	p.global_position = Vector3(40.0, 0.0, 0.0)
	p.set_frame(InputFrame.new())
	p._movement = p._movement.duplicate(true)
	await _tree().physics_frame
	return [scene, p]


func _speed(p: Pawn) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()


func _drive(p: Pawn, sprint: bool, ticks: int) -> void:
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)
	f.sprint = sprint
	p.set_frame(f)
	for i in ticks:
		p._apply_movement(DT)


func test_run_speed_settles_at_4_7() -> void:
	var g := await _pawn()
	var p: Pawn = g[1]
	_drive(p, false, 60)
	assert_true(absf(_speed(p) - RUN_MPS) / RUN_MPS < 0.01, "run settles at 4.7 within 1%%, got %s" % _speed(p))
	g[0].queue_free()


func test_full_sprint_settles_at_6_3() -> void:
	var g := await _pawn()
	var p: Pawn = g[1]
	_drive(p, true, 150)
	assert_true(absf(_speed(p) - SPRINT_MPS) / SPRINT_MPS < 0.01, "full sprint settles at 6.3 (4.7 x 1.34) within 1%%, got %s" % _speed(p))
	g[0].queue_free()


func test_ramp_rate_is_still_40() -> void:
	var m: Dictionary = DataRegistry.new().get_movement_cfg()
	var accel := float(m["base_speed_mps"]) / float(m["ground_accel"]["time_s"])
	var decel := float(m["base_speed_mps"]) / float(m["ground_decel"]["time_s"])
	assert_true(absf(accel - RAMP_RATE) < 1e-6, "accel rate 40 m/s^2, got %s" % accel)
	assert_true(absf(decel - RAMP_RATE) < 1e-6, "decel rate 40 m/s^2, got %s" % decel)
	var g := await _pawn()
	var p: Pawn = g[1]
	_drive(p, false, 3)
	assert_true(absf(_speed(p) - RAMP_RATE * 3.0 * DT) < 0.05, "three ticks from rest reach 40 m/s^2 x 3 ticks, got %s" % _speed(p))
	g[0].queue_free()
