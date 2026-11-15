class_name CoverController
extends RefCounted
## Pure wall-frame state machine. Physics and input routing are supplied by callers.
signal entered
signal exited

## M2 C1b stage 4: PEEK_LEFT / PEEK_RIGHT are the lean out past an open edge of HIGH cover (Fire or Aim); the rise
## over LOW cover happens in place in IN_COVER (aim_out_amount > 0). Nothing else enters PEEK_*.
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
var crouch_amount := 0.0
var crouched := false
## M2 C1b stage 4: the out pose is complete (aim_out_amount 1, standing, at the out target). Rounds leave only then.
var aimed_out := false
## 0 = at the wall, 1 = fully out (leaned past the edge or risen); eased over aim_out_s out and aim_return_s back.
var aim_out_amount := 0.0
var _facts: Dictionary = {}
## The lean / rise ("draw") in progress: from _draw_anchor (on the wall) to _draw_target (past the edge, or the same
## point for a rise), returning while _draw_returning.
var _draw_active := false
var _draw_returning := false
var _draw_anchor := Vector3.ZERO
var _draw_target := Vector3.ZERO
## M2 C1b stage 4 (fix 7): a Fire press not yet answered by a round. Taken in ENTERING / EXITING and kept until the
## state settles (both last at most input_lock_max_s); from IN_COVER only where a lean or rise is possible.
var _fire_buffered := false
var _fire_was := false
## Seconds left out after Fire is released with Aim off (cover.json fire_return_delay_s); a slide push ends it.
var _stay_out_left := 0.0
## M2 C1b stage 1: seconds left in the re-entry cooldown (cover.json reentry_cooldown_s, auto-snap only).
var _cooldown_left := 0.0
## M2 C1b stage 1: the snap lerp clock (cover.json snap_lerp_s): last tick's and this tick's time since entry.
var _snap_prev := 0.0
var _snap_t := 0.0

func _init(cfg: Dictionary) -> void:
	config = cfg.duplicate(true)

func state_name() -> String:
	return State.keys()[state]

func reset() -> void:
	var was_cover := state != State.FREE
	state = State.FREE
	_hold = 0.0
	_phase = 0.0
	_exit_hold = 0.0
	_lost_ticks = 0
	_candidate = null
	wall_key = null
	target_offset = Vector3.ZERO
	crouch_amount = 0.0
	crouched = false
	aimed_out = false
	aim_out_amount = 0.0
	_draw_active = false
	_draw_returning = false
	_fire_buffered = false
	_stay_out_left = 0.0
	_facts.clear()
	_snap_prev = 0.0
	_snap_t = 0.0
	if was_cover:
		_cooldown_left = float(config["reentry_cooldown_s"])
		exited.emit()

## M2 C1b stage 4 (decisions 3, 4; fix 21): in every cover state a round leaves only from the completed out pose with
## the full-range wall ray clear (CoverProbe.shot_clear, which Pawn refreshes after the move). No blind fire. FREE
## never blocks.
func blocks_fire() -> bool:
	if state == State.FREE:
		return false
	return not (aimed_out and bool(_facts.get("shot_clear", false)))

## M2 C1b stage 4: the weapon trigger for this tick (Pawn._apply_weapon; read-only). The held Fire or a buffered press,
## unless blocks_fire(). In FREE this is the held Fire or a press buffered through EXITING.
func fire_trigger(fire_pressed: bool) -> bool:
	if blocks_fire():
		return false
	return fire_pressed or _fire_buffered

## M2 C1b stage 4 (fix 7, [Shibi default]): false only where no lean or rise is possible: ENTERING / IN_COVER behind
## HIGH cover with no open edge within lean_reach_m, not already out. There Fire does not fire and spends no ammo; the
## touch HUD dims the Fire buttons on this (through Pawn.cover_fire_available). Read-only.
func fire_available() -> bool:
	if state == State.FREE or state == State.EXITING or _draw_active:
		return true
	return can_go_out()

## A lean or a rise is possible from here: LOW cover (height_m < muzzle_height_m, the automatic-crouch rule), or HIGH
## cover with an open edge (CoverProbe usable_left_m / usable_right_m) within cover.json lean_reach_m.
func can_go_out() -> bool:
	if _is_low():
		return true
	return minf(float(_facts.get("usable_left_m", INF)), float(_facts.get("usable_right_m", INF))) <= float(config["lean_reach_m"])

func _is_low() -> bool:
	return float(_facts.get("height_m", INF)) < float(_facts.get("muzzle_height_m", 0.0))

## The lean side (-1 left end, +1 right end; CoverController.side): the open edge within lean_reach_m, or with both in
## reach the stick's along-wall direction, else the nearer edge.
func lean_side(wish: Vector3) -> int:
	var reach := float(config["lean_reach_m"])
	var left := float(_facts.get("usable_left_m", INF))
	var right := float(_facts.get("usable_right_m", INF))
	if left <= reach and right <= reach:
		var lateral := wish.dot(tangent)
		if absf(lateral) > 0.0:
			return -1 if lateral < 0.0 else 1
		return -1 if left < right else 1
	return -1 if left <= reach else 1

## Pawn acknowledges a round that left the weapon (any state): the buffered press is answered.
func round_fired() -> void:
	_fire_buffered = false

func refresh_shot_clear(clear: bool) -> void:
	_facts["shot_clear"] = clear

## Pawn refreshes arrival after move_and_slide, before the guarded weapon tick.
## tick also calls this so pure controller callers retain the same pose contract.
func refresh_completed_pose(position: Vector3) -> void:
	aimed_out = _draw_active and not _draw_returning and aim_out_amount >= 1.0 and crouch_amount == 0.0 and position.distance_to(_draw_target) <= float(config["motion_epsilon_m"])

## M2 C1b: fire_pressed (InputFrame.fire_pressed) gates the auto-snap and, in cover, drives the lean / rise and the Fire
## buffer (its rising edge is a press); aiming (the Aim toggle) holds the soldier out; sprinting gates the auto-snap.
func tick(delta: float, move: Vector2, fire_pressed: bool, probe: Dictionary, aiming: bool = false, sprinting: bool = false) -> void:
	_facts = probe.duplicate()
	var pressed := fire_pressed and not _fire_was
	_fire_was = fire_pressed
	var basis: Basis = probe.get("basis", Basis.IDENTITY)
	var wish := basis * Vector3(move.x, 0, move.y)
	wish.y = 0
	wish = wish.limit_length(1.0)
	var position: Vector3 = probe.get("position", Vector3.ZERO)
	if state == State.FREE:
		_fire_buffered = false  # a press handed over by EXITING was taken by the weapon tick that followed it
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
		_try_snap(delta, wish, probe, position, basis, fire_pressed, sprinting)
		return
	_buffer_fire(pressed)
	_snap_prev = _snap_t
	_snap_t = minf(_snap_t + delta, float(config["snap_lerp_s"]))
	if state != State.EXITING:
		# M2 C1b stage 3 (item 5, fix 19): the locked cover body was freed (or left the tree; CoverProbe reports
		# "wall_gone"): leave through EXITING, so the exit blends like every other exit. Any other lost sample (the
		# pawn pushed off the wall, the face ray missing, a body no longer tagged) keeps the instant reset below.
		if bool(probe.get("wall_gone", false)):
			_begin_exit()
		else:
			var same_wall: bool = bool(probe.get("hit", false)) and probe.get("wall_key") == wall_key
			_lost_ticks = 0 if same_wall else _lost_ticks + 1
			if _lost_ticks > 1:
				reset()
				return
	_phase += delta
	match state:
		State.ENTERING:
			_update_crouch(delta)
			if _phase + 0.000001 >= enter_duration():
				state = State.IN_COVER
				_phase = 0.0
				# A press buffered while entering is taken now, if a lean or rise is possible here (fix 7).
				_fire_buffered = _fire_buffered and can_go_out()
		State.IN_COVER, State.PEEK_LEFT, State.PEEK_RIGHT:
			# M2 C1b stage 3: the held away push exits from every in-cover state, also while leaned or risen out.
			if not _tick_away_exit(delta, wish) and not _tick_out(delta, position, wish, aiming, fire_pressed):
				# M2 C1b stage 3 (decision 8, fix 11): the along-wall (tangent) part of the camera-yaw stick slides, clamped
				# edge_margin_m short of the locked wall's ends; the into-wall part does nothing. Ignored while out.
				var lateral := wish.dot(tangent)
				var left := float(probe.get("left_m", INF))
				var right := float(probe.get("right_m", INF))
				var margin := float(config["edge_margin_m"])
				var speed := float(probe.get("slide_speed_mps", 0.0))
				var step := clampf(lateral * speed * delta, -maxf(left - margin, 0), maxf(right - margin, 0))
				target_position = _plane_position(position) + tangent * step
				_update_crouch(delta)
		State.EXITING:
			_update_crouch(delta)
			if _phase + 0.000001 >= exit_duration():
				var buffered := _fire_buffered
				reset()
				_fire_buffered = buffered  # a press during EXITING is taken by the next weapon tick, in FREE
				return
	if state != State.FREE:
		target_offset = target_position - position

## M2 C1b stage 4 (fix 7): a Fire press (rising edge) is buffered in ENTERING and EXITING, and in IN_COVER / PEEK_*
## when the soldier is out or can go out; behind HIGH cover away from an edge it is dropped (no shot later). With the
## weapon empty or reloading nothing is buffered (combat.auto_reload_on_empty reloads; a still-held Fire goes out after).
func _buffer_fire(pressed: bool) -> void:
	if pressed:
		_fire_buffered = state == State.ENTERING or state == State.EXITING or _draw_active or can_go_out()
	if not bool(_facts.get("weapon_ready", true)):
		_fire_buffered = false
	# The completed out pose with the wall ray blocked (the view turned across the wall) cannot answer a press: drop it,
	# so it never holds the soldier out by itself (a held Fire or Aim still does).
	if aimed_out and not bool(_facts.get("shot_clear", false)) and not pressed:
		_fire_buffered = false

## The soldier wants out: the Aim toggle, the held Fire, a buffered press, the stay-out delay after a release, or a
## round the weapon still owes (a burst or an armed semi). Never with the weapon empty or reloading (decision 9).
func _wants_out(aiming: bool, fire_pressed: bool) -> bool:
	if not bool(_facts.get("weapon_ready", true)):
		return false
	return aiming or fire_pressed or _fire_buffered or _stay_out_left > 0.0 or bool(_facts.get("weapon_pending", false))

## M2 C1b stage 4 (decisions 3, 9; fix 16): the lean / rise. From IN_COVER, when wanted and possible: behind HIGH cover
## lean past the lean_side edge by usable + peek_offset_m in PEEK_LEFT / PEEK_RIGHT (side follows, so the cover camera
## does too); behind LOW cover rise in place (crouch to 0). Out over aim_out_s, back over aim_return_s. Returns true
## while the draw owns the move (the slide is ignored); false when there is none or it just ended at the wall.
func _tick_out(delta: float, position: Vector3, wish: Vector3, aiming: bool, fire_pressed: bool) -> bool:
	if not _draw_active:
		if state != State.IN_COVER or not _wants_out(aiming, fire_pressed) or not can_go_out():
			return false
		_draw_active = true
		_draw_returning = false
		_draw_anchor = position
		_draw_target = position
		_phase = 0.0
		if not _is_low():
			side = lean_side(wish)
			var usable := float(_facts.get("usable_left_m" if side < 0 else "usable_right_m", 0.0))
			_draw_target += tangent * side * (maxf(usable, 0.0) + float(config["peek_offset_m"]))
			state = State.PEEK_LEFT if side < 0 else State.PEEK_RIGHT
	if fire_pressed or _fire_buffered:
		_stay_out_left = float(config["fire_return_delay_s"])
	elif aiming or absf(wish.dot(tangent)) > 0.0:
		_stay_out_left = 0.0  # Aim holds by itself; a slide push ends the delay at once, so it never locks the stick
	else:
		_stay_out_left = maxf(0.0, _stay_out_left - delta)
	_draw_returning = not _wants_out(aiming, fire_pressed)
	var duration := float(config["aim_return_s"] if _draw_returning else config["aim_out_s"])
	aim_out_amount = move_toward(aim_out_amount, 0.0 if _draw_returning else 1.0, delta / duration)
	_update_crouch(delta, not _draw_returning)
	target_position = _draw_anchor.lerp(_draw_target, aim_out_amount)
	refresh_completed_pose(position)
	if _draw_returning and aim_out_amount <= 0.0 and position.distance_to(_draw_anchor) <= float(config["motion_epsilon_m"]):
		_draw_active = false
		_draw_returning = false
		_stay_out_left = 0.0
		state = State.IN_COVER
		_phase = 0.0
		return false
	return true

## M2 C1b stage 2 (decision 7, fix 10): crouched behind LOW cover, standing behind HIGH cover, from the probe's height_m
## (cover_probe.gd): LOW iff height_m < muzzle_height_m (stats.json movement, the can_go_out rule). Re-read every
## tick, so a slide from a low to a high section follows; standing up still waits for stand_clear. A tick without the
## wall's height (a lost sample) keeps the last stance. M2 C1b stage 4: while a rise is out or returning the crouch
## follows its timing (aim_out_s up, aim_return_s back down), otherwise crouch_blend_s.
func _update_crouch(delta: float, rising: bool = false) -> void:
	if state != State.EXITING and state != State.FREE and _facts.has("height_m"):
		crouched = float(_facts["height_m"]) < float(_facts.get("muzzle_height_m", 0.0))
	var target := 1.0 if crouched and not rising else 0.0
	if state == State.EXITING or state == State.FREE:
		crouched = false
		target = 0.0
	if target < crouch_amount and not bool(_facts.get("stand_clear", false)):
		target = crouch_amount
	var blend := float(config["crouch_blend_s"])
	if _draw_active:
		blend = float(config["aim_return_s"] if _draw_returning else config["aim_out_s"])
	crouch_amount = move_toward(crouch_amount, target, delta / blend)

## M2 C1b stage 3 (decision 8, fix 11): the outward wall-normal part of the camera-yaw stick at or above
## back_exit_min, held exit_away_hold_s (both cover.json, OQ-COVER), begins the exit. A shorter push, or a push below
## the threshold, does nothing (the hold restarts). Returns true on the tick the exit begins.
func _tick_away_exit(delta: float, wish: Vector3) -> bool:
	if wish.dot(normal) + 0.000001 < float(config["back_exit_min"]):
		_exit_hold = 0.0
		return false
	_exit_hold += delta
	if _exit_hold + 0.000001 < float(config["exit_away_hold_s"]):
		return false
	_begin_exit()
	return true

## M2 C1b stage 1: how long ENTERING ignores the stick: min(enter_s, input_lock_max_s). The move onto the wall
## plane keeps easing over snap_lerp_s after the state has settled (movement_velocity).
func enter_duration() -> float:
	return minf(float(config["enter_s"]), float(config["input_lock_max_s"]))

## M2 C1b stage 3 (fix 25): how long EXITING lasts: min(exit_s, input_lock_max_s). EXITING never locks the stick, the
## look, Jump or the Sprint lock (movement_velocity is the free wish); it ignores the Cover button and auto-snap, and
## a Fire press is buffered to FREE (stage 4). The camera's exit blend (camera.json cover_blend_s) runs on independently.
func exit_duration() -> float:
	return minf(float(config["exit_s"]), float(config["input_lock_max_s"]))

## M2 C1b: every span in which the controller ignores an input, from data, keyed by its cover.json source. Each must
## be <= input_lock_max_s (tests/test_cover_move_exit_c1b.gd, tests/test_cover_fire_c1b.gd). ENTERING ignores the
## stick and buffers Fire; EXITING ignores the Cover button and buffers Fire; the move out and back (aim_out_s /
## aim_return_s) ignore the slide. Not locks: Fire or Aim held out (the player's own hold) and fire_return_delay_s
## (a slide push ends it).
func lock_durations() -> Dictionary:
	return {"enter_s": enter_duration(), "exit_s": exit_duration(), "aim_out_s": float(config["aim_out_s"]),
		"aim_return_s": float(config["aim_return_s"])}

## M2 C1b stage 3: Jump (fix 14) and a Sprint lock press (fixes 3, 24) leave cover through EXITING, from ENTERING,
## IN_COVER or a lean. Only Pawn calls this. Returns true when the exit began.
func request_exit() -> bool:
	if state == State.ENTERING or state == State.IN_COVER or state == State.PEEK_LEFT or state == State.PEEK_RIGHT:
		_begin_exit()
		return true
	return false

## Auto-snap anti-sticky rules (OQ-COVER, cover.json): the stick pushed into the wall (length >= enter_stick_min, its
## direction within max_wall_angle_deg of the wall normal), the facing within the same angle, the wall within probe_m
## and at least min_cover_height_m tall, held snap_hold_s on the same wall, not while sprinting, not while Fire is
## held and not within reentry_cooldown_s after an exit.
func _try_snap(delta: float, wish: Vector3, probe: Dictionary, position: Vector3, basis: Basis, fire_pressed: bool, sprinting: bool) -> void:
	var wall_normal: Vector3 = probe.get("normal", Vector3.ZERO)
	var facing := -basis.z
	facing.y = 0
	facing = facing.normalized()
	var min_dot := cos(deg_to_rad(float(config["max_wall_angle_deg"])))
	# M2 C1b stage 3: cover.json auto_snap_blocked_by_sprint (OQ-COVER). On touch a full forward push is the sprint
	# gesture, so with the default true a full push into a wall never auto-snaps (only a partial push does).
	var sprint_blocks := sprinting and bool(config["auto_snap_blocked_by_sprint"])
	var valid := not fire_pressed and not sprint_blocks and _cooldown_left <= 0.0
	valid = valid and bool(probe.get("hit", false)) and float(probe.get("distance_m", INF)) <= float(config["probe_m"])
	valid = valid and float(probe.get("height_m", 0)) + 0.000001 >= float(config["min_cover_height_m"])
	valid = valid and wish.length() >= float(config["enter_stick_min"]) and wish.normalized().dot(-wall_normal) + 0.000001 >= min_dot
	valid = valid and facing.dot(-wall_normal) + 0.000001 >= min_dot
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
	_enter(probe, position, wish)

## M2 C1b stage 1: true when a Cover button press in FREE would enter with these probe facts (the pawn samples them
## with the cover_button_range_m ray): a cover_wall within that range, at least min_cover_height_m tall. No stick,
## angle, sprint, Fire or cooldown rule applies to the button.
func can_enter_by_button(probe: Dictionary) -> bool:
	if state != State.FREE or not bool(probe.get("hit", false)):
		return false
	if float(probe.get("distance_m", INF)) > float(config["cover_button_range_m"]) + 0.000001:
		return false
	return float(probe.get("height_m", 0)) + 0.000001 >= float(config["min_cover_height_m"])

## M2 C1b stage 1: the Cover button press (Pawn.handle_action_press("cover") is the only caller in the game). From FREE
## it enters when can_enter_by_button(probe), ignoring the re-entry cooldown; in IN_COVER / PEEK_LEFT / PEEK_RIGHT it
## begins the exit. ENTERING and EXITING ignore it. Returns true when the state changed.
func request_cover(probe: Dictionary) -> bool:
	match state:
		State.FREE:
			if not can_enter_by_button(probe):
				return false
			_facts = probe.duplicate()
			_enter(probe, probe.get("position", Vector3.ZERO), Vector3.ZERO)
			return true
		State.IN_COVER, State.PEEK_LEFT, State.PEEK_RIGHT:
			_begin_exit()
			return true
	return false

func _enter(probe: Dictionary, position: Vector3, wish: Vector3) -> void:
	normal = probe["normal"]
	tangent = Vector3.UP.cross(normal).normalized()
	wall_point = probe["point"]
	wall_key = probe.get("wall_key")
	side = -1 if float(probe.get("left_m", INF)) < float(probe.get("right_m", INF)) else 1
	if absf(wish.dot(tangent)) > 0:
		side = -1 if wish.dot(tangent) < 0 else 1
	state = State.ENTERING
	_phase = 0.0
	_hold = 0.0
	_exit_hold = 0.0
	_candidate = null
	_lost_ticks = 0
	_snap_prev = 0.0
	_snap_t = 0.0
	target_position = _plane_position(position)
	target_offset = target_position - position
	entered.emit()

func _plane_position(position: Vector3) -> Vector3:
	return position + normal * (float(config["wall_offset_m"]) - (position - wall_point).dot(normal))

## Every exit (away push, Cover, Sprint lock, Jump, a vanished wall) goes through EXITING. A buffered Fire press stays
## and is taken in FREE.
func _begin_exit() -> void:
	state = State.EXITING
	_phase = 0.0
	_exit_hold = 0.0
	_draw_active = false
	_draw_returning = false
	aimed_out = false
	_stay_out_left = 0.0

## The owner still calls move_and_slide. No transform writes; every phase is speed bounded.
func movement_velocity(position: Vector3, free_wish: Vector3, max_speed: float, delta: float) -> Vector3:
	if state == State.FREE or state == State.EXITING:
		return free_wish.limit_length(max_speed)
	if delta <= 0:
		return Vector3.ZERO
	var offset := target_position - position
	offset.y = 0
	# M2 C1b stage 1: during the first snap_lerp_s after entry the wall-normal part of the move eases (smoothstep)
	# instead of arriving in one tick; the along-wall part is unchanged. Still speed bounded below.
	var lerp_s := float(config["snap_lerp_s"])
	if lerp_s > 0.0 and _snap_prev < lerp_s:
		var s0 := smoothstep(0.0, 1.0, _snap_prev / lerp_s)
		var s1 := smoothstep(0.0, 1.0, _snap_t / lerp_s)
		var frac := 1.0 if s0 >= 1.0 else clampf((s1 - s0) / (1.0 - s0), 0.0, 1.0)
		var along_normal := normal * offset.dot(normal)
		offset += along_normal * (frac - 1.0)
	return (offset / delta).limit_length(max_speed)
