class_name CoverController
extends RefCounted
## Pure wall-frame state machine. Physics and input routing are supplied by callers.
signal entered
signal peeked(side: int)
signal exited

enum State { FREE, ENTERING, IN_COVER, PEEK_LEFT, PEEK_RIGHT, EXITING }
var state := State.FREE
var side := 1
var target_offset := Vector3.ZERO
var target_position := Vector3.ZERO
var normal := Vector3.ZERO
var tangent := Vector3.ZERO
var wall_point := Vector3.ZERO
var wall_key: Variant
var config: Dictionary
var _hold := 0.0
var _phase := 0.0
var _exit_hold := 0.0
var _lost_ticks := 0
var _candidate: Variant
var _anchor := Vector3.ZERO
var _peek_target := Vector3.ZERO
var _peek_complete := false
var _returning := false

func _init(cfg: Dictionary) -> void:
	config = cfg.duplicate(true)

func state_name() -> String:
	return State.keys()[state]

func reset() -> void:
	var was_cover := state != State.FREE
	state = State.FREE
	_returning = false
	_hold = 0.0
	_phase = 0.0
	_exit_hold = 0.0
	_lost_ticks = 0
	_candidate = null
	wall_key = null
	target_offset = Vector3.ZERO
	_peek_complete = false
	if was_cover:
		exited.emit()

func blocks_fire() -> bool:
	if state == State.FREE:
		return false
	return bool(config["fire_requires_peek"]) and not ((state == State.PEEK_LEFT or state == State.PEEK_RIGHT) and _peek_complete)

func tick(delta: float, move: Vector2, _fire_pressed: bool, probe: Dictionary) -> void:
	var basis: Basis = probe.get("basis", Basis.IDENTITY)
	var wish := basis * Vector3(move.x, 0, move.y)
	wish.y = 0
	wish = wish.limit_length(1.0)
	var position: Vector3 = probe.get("position", Vector3.ZERO)
	if state == State.FREE:
		_try_snap(delta, move, wish, probe, position, basis)
		return
	if state != State.EXITING:
		var same_wall: bool = bool(probe.get("hit", false)) and probe.get("wall_key") == wall_key
		_lost_ticks = 0 if same_wall else _lost_ticks + 1
		if _lost_ticks > 1:
			reset()
			return
	_phase += delta
	match state:
		State.ENTERING:
			if _phase + 0.000001 >= float(config["enter_s"]):
				state = State.IN_COVER
				_phase = 0.0
		State.IN_COVER:
			if _returning:
				target_position = _anchor
				_returning = position.distance_to(_anchor) > float(config["motion_epsilon_m"])
				if _returning:
					target_offset = target_position - position
					return
			var lateral := wish.dot(tangent)
			var left := float(probe.get("left_m", INF))
			var right := float(probe.get("right_m", INF))
			var margin := float(config["edge_margin_m"])
			if wish.dot(normal) >= float(config["back_exit_min"]):
				_begin_exit()
			elif absf(lateral) >= float(config["peek_stick_min"]) and ((lateral < 0 and left <= margin + 0.000001) or (lateral > 0 and right <= margin + 0.000001)):
				side = -1 if lateral < 0 else 1
				_anchor = _plane_position(position)
				var distance := left if side < 0 else right
				_peek_target = _anchor + tangent * side * (maxf(distance, 0) + float(config["peek_offset_m"]))
				state = State.PEEK_LEFT if side < 0 else State.PEEK_RIGHT
				_phase = 0.0
				_exit_hold = 0.0
				_peek_complete = false
				peeked.emit(side)
			else:
				var speed := float(probe.get("slide_speed_mps", 0.0))
				var step := clampf(lateral * speed * delta, -maxf(left - margin, 0), maxf(right - margin, 0))
				target_position = _plane_position(position) + tangent * step
		State.PEEK_LEFT, State.PEEK_RIGHT:
			target_position = _peek_target
			_peek_complete = _phase + 0.000001 >= float(config["peek_s"]) and position.distance_to(_peek_target) <= float(config["motion_epsilon_m"])
			var along := wish.dot(tangent) * side
			if along >= float(config["exit_stick_min"]):
				_exit_hold += delta
				if _exit_hold + 0.000001 >= float(config["exit_hold_s"]):
					_begin_exit()
			else:
				_exit_hold = 0.0
				if along < float(config["peek_stick_min"]):
					state = State.IN_COVER
					_returning = true
					target_position = _anchor
					_phase = 0.0
					_peek_complete = false
		State.EXITING:
			if _phase + 0.000001 >= float(config["exit_s"]):
				reset()
	if state != State.FREE:
		target_offset = target_position - position

func _try_snap(delta: float, move: Vector2, wish: Vector3, probe: Dictionary, position: Vector3, basis: Basis) -> void:
	var wall_normal: Vector3 = probe.get("normal", Vector3.ZERO)
	var facing := -basis.z
	facing.y = 0
	facing = facing.normalized()
	var valid := bool(probe.get("hit", false)) and float(probe.get("distance_m", INF)) <= float(config["probe_m"])
	valid = valid and float(probe.get("height_m", 0)) + 0.000001 >= float(config["min_cover_height_m"])
	valid = valid and -move.y >= float(config["enter_stick_min"]) and wish.dot(-wall_normal) >= float(config["enter_stick_min"])
	valid = valid and facing.dot(-wall_normal) >= cos(deg_to_rad(float(config["max_wall_angle_deg"])))
	if not valid:
		_hold = 0.0
		_candidate = null
		return
	if _candidate != probe.get("wall_key"):
		_hold = 0.0
		_candidate = probe.get("wall_key")
	_hold += delta
	if _hold + 0.000001 < float(config["snap_hold_s"]):
		return
	normal = wall_normal
	tangent = Vector3.UP.cross(normal).normalized()
	wall_point = probe["point"]
	wall_key = probe.get("wall_key")
	side = -1 if float(probe.get("left_m", INF)) < float(probe.get("right_m", INF)) else 1
	if absf(wish.dot(tangent)) > 0:
		side = -1 if wish.dot(tangent) < 0 else 1
	state = State.ENTERING
	_phase = 0.0
	target_position = _plane_position(position)
	target_offset = target_position - position
	entered.emit()

func _plane_position(position: Vector3) -> Vector3:
	return position + normal * (float(config["wall_offset_m"]) - (position - wall_point).dot(normal))

func _begin_exit() -> void:
	state = State.EXITING
	_phase = 0.0
	_peek_complete = false

## The owner still calls move_and_slide. No transform writes; every phase is speed bounded.
func movement_velocity(position: Vector3, free_wish: Vector3, max_speed: float, delta: float) -> Vector3:
	if state == State.FREE or state == State.EXITING:
		return free_wish.limit_length(max_speed)
	var offset := target_position - position
	offset.y = 0
	return (offset / delta).limit_length(max_speed) if delta > 0 else Vector3.ZERO
