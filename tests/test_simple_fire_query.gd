extends "res://tests/test_case.gd"
## M2 H1a: Pawn.simple_fire_target(), the read-only query behind the Simple shooting mode. It names the live enemy the
## active gun's real shot would hit now (the shot's own muzzle origin and aim direction, the weapon's range_m, world
## geometry in the way, the host's AimMath.validate_aim wall rule on the frame's aim point), else null. Never a squad
## mate, a downed or dead pawn, or the shooter; it changes nothing.
## The fixture is far from anything else (x = 3000), the shooter faces -z with pitch 0 (muzzle 1.3 m up), and every pawn
## runs no physics of its own.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const ORIGIN := Vector3(3000, 0, 0)

var _root: Node3D
var _shooter: Pawn


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _fixture() -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	_shooter = _pawn_at(Vector3.ZERO, 0)


func _pawn_at(offset: Vector3, squad: int) -> Pawn:
	var p: Pawn = _PawnScene.instantiate()
	p.position = ORIGIN + offset
	_root.add_child(p)
	p.set_physics_process(false)
	p.set_squad(squad)
	return p


func _wall_at(z: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = ORIGIN + Vector3(0, 1.5, z)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 3, 0.3)
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	return body


## Lets the physics server register what was just added.
func _settle() -> void:
	await _tree().physics_frame
	await _tree().physics_frame


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	await _tree().process_frame


func _frame_with_point(point: Vector3) -> InputFrame:
	var f := InputFrame.new()
	f.aim_point = point
	f.has_aim_point = true
	return f


func test_live_enemy_under_the_crosshair_in_range_and_clear() -> void:
	await _fixture()
	var enemy := _pawn_at(Vector3(0, 0, -10), 1)
	await _settle()
	assert_true(_shooter.simple_fire_target() == enemy, "a live enemy 10 m ahead is the target (no aim point)")
	_shooter.set_frame(_frame_with_point(enemy.global_position + Vector3(0, 1.3, 0)))
	assert_true(_shooter.simple_fire_target() == enemy, "and with a camera aim point on its body")
	await _cleanup()


func test_nothing_under_the_crosshair() -> void:
	await _fixture()
	var enemy := _pawn_at(Vector3(5, 0, -10), 1)  # well off to the side
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "no pawn on the shot ray: null")
	_shooter.rotation.y = PI  # facing away from everything
	assert_true(_shooter.simple_fire_target() == null, "facing away: null")
	assert_true(enemy.is_alive(), "fixture: the enemy is alive")
	await _cleanup()


func test_squad_mate_never() -> void:
	await _fixture()
	_pawn_at(Vector3(0, 0, -10), 0)
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "a squad mate under the crosshair: null")
	await _cleanup()


func test_downed_squad_mate_never() -> void:
	await _fixture()
	var mate := _pawn_at(Vector3(0, 0, -10), 0)
	mate.life = Pawn.Life.DOWNED
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "a downed squad mate: null")
	await _cleanup()


func test_downed_enemy_never_and_it_shields_a_live_one_behind() -> void:
	await _fixture()
	var downed := _pawn_at(Vector3(0, 0, -10), 1)
	downed.life = Pawn.Life.DOWNED
	_pawn_at(Vector3(0, 0, -20), 2)
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "the first pawn on the ray is a downed enemy: null (the round would hit it)")
	await _cleanup()


func test_dead_enemy_never() -> void:
	await _fixture()
	var dead := _pawn_at(Vector3(0, 0, -10), 1)
	dead.life = Pawn.Life.DEAD  # still collidable here, so the ray reaches it: the life state alone rules it out
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "a dead enemy: null")
	await _cleanup()


func test_enemy_behind_a_wall_never() -> void:
	await _fixture()
	var enemy := _pawn_at(Vector3(0, 0, -10), 1)
	_wall_at(-5.0)
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "a wall between muzzle and enemy: null (no aim point)")
	_shooter.set_frame(_frame_with_point(enemy.global_position + Vector3(0, 1.3, 0)))
	assert_true(_shooter.simple_fire_target() == null, "and with a camera aim point on the enemy")
	await _cleanup()


## The host refuses a shot whose muzzle ray to the client's aim point is blocked (AimMath.validate_aim "aim_blocked",
## NetMatchBridge.host_handle_fire), even when a pawn stands in front of the wall. Simple must agree.
func test_host_aim_blocked_rule_is_honoured() -> void:
	await _fixture()
	var enemy := _pawn_at(Vector3(0, 0, -5), 1)
	_wall_at(-8.0)
	await _settle()
	var point := ORIGIN + Vector3(0, 1.3, -12)  # beyond the wall
	var epsilon := float(DataRegistry.new().get_camera_cfg()["aim_validate_epsilon_m"]["value"])
	var host := AimMath.validate_aim(_shooter.get_world_3d().direct_space_state, _shooter.get_muzzle_position(), point,
			epsilon, _shooter.hitscan_exclude())
	assert_eq(host["reason"], "aim_blocked", "fixture: the host would refuse this aim point")
	_shooter.set_frame(_frame_with_point(point))
	assert_true(_shooter.simple_fire_target() == null, "aim_blocked on the host: null although an enemy is on the muzzle ray")
	_shooter.set_frame(InputFrame.new())
	assert_true(_shooter.simple_fire_target() == enemy, "without the aim point the same enemy is the target")
	await _cleanup()


func test_enemy_beyond_range_never() -> void:
	await _fixture()
	var range_m := _shooter.loadout.get_active().def.range_m
	var far := _pawn_at(Vector3(0, 0, -(range_m + 5.0)), 1)
	var near := _pawn_at(Vector3(0, 0, -(range_m - 5.0)), 1)
	near.position.x += 3.0  # out of the ray: only `far` is on it
	await _settle()
	assert_true(_shooter.simple_fire_target() == null, "an enemy %.0f m away, beyond range_m %.0f: null" % [range_m + 5.0, range_m])
	near.position.x = ORIGIN.x
	await _settle()
	assert_true(_shooter.simple_fire_target() == near, "the same line inside range_m: the target")
	assert_true(far.is_alive(), "fixture: the far enemy is alive")
	await _cleanup()


func test_melee_weapon_never() -> void:
	await _fixture()
	_pawn_at(Vector3(0, 0, -2), 1)
	await _settle()
	var blade := WeaponDef.new()
	blade.kind = "melee"
	blade.range_m = 50.0
	_shooter.loadout.slots[_shooter.loadout.active] = Weapon.new(blade)
	assert_true(_shooter.simple_fire_target() == null, "a melee weapon: null (Simple never swings)")
	await _cleanup()


func test_the_shooter_itself_never() -> void:
	await _fixture()
	await _settle()
	_shooter.pitch = deg_to_rad(-70.0)  # steeply down, through its own body
	assert_true(_shooter.simple_fire_target() == null, "looking down through its own body: null")
	_shooter.set_frame(_frame_with_point(_shooter.global_position + Vector3(0, 0.5, 0)))
	assert_true(_shooter.simple_fire_target() == null, "an aim point inside its own body: null")
	await _cleanup()


func test_query_does_not_mutate_the_pawn() -> void:
	await _fixture()
	var enemy := _pawn_at(Vector3(0, 0, -10), 1)
	await _settle()
	_shooter.pitch = 0.05
	_shooter.set_frame(_frame_with_point(enemy.global_position + Vector3(0, 1.2, 0)))
	var w := _shooter.loadout.get_active()
	var signals := [0]
	for sig in ["fired", "shot", "shot_resolved", "fire_empty", "reload_started"]:
		_shooter.connect(sig, func(_a = null, _b = null, _c = null) -> void: signals[0] += 1)
	var before := [_shooter.get_aim_direction(), _shooter.global_transform, _shooter.pitch, _shooter.aiming,
			_shooter.aim_blend, w.ammo_in_mag, w.reserve, w._semi_armed, w._next_fire_time, w._trigger_was_held,
			_shooter.get_clock(), _shooter._frame, enemy.global_transform, enemy.life, enemy.bridge.state.health]
	for i in 5:
		assert_true(_shooter.simple_fire_target() == enemy, "fixture: the enemy is the target")
	var after := [_shooter.get_aim_direction(), _shooter.global_transform, _shooter.pitch, _shooter.aiming,
			_shooter.aim_blend, w.ammo_in_mag, w.reserve, w._semi_armed, w._next_fire_time, w._trigger_was_held,
			_shooter.get_clock(), _shooter._frame, enemy.global_transform, enemy.life, enemy.bridge.state.health]
	for i in before.size():
		assert_true(before[i] == after[i], "field %d unchanged: %s vs %s" % [i, str(before[i]), str(after[i])])
	assert_eq(signals[0], 0, "no signal emitted")
	await _cleanup()
