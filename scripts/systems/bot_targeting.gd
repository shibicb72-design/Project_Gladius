class_name BotTargeting
extends RefCounted
## Pure bot maths: target selection and aim error. No nodes.


## candidates: Array of {id, pos: Vector3, squad: int, alive: bool, visible: bool}.
## Returns the id of the nearest living, visible enemy within range, or -1.
static func pick_target(origin: Vector3, my_squad: int, candidates: Array, max_range_m: float) -> int:
	var best := -1
	var best_d := INF
	for c in candidates:
		if int(c["squad"]) == my_squad or not bool(c["alive"]) or not bool(c["visible"]):
			continue
		var d := origin.distance_to(c["pos"])
		if d <= max_range_m and d < best_d:
			best_d = d
			best = int(c["id"])
	return best


## Random (yaw, pitch) error in radians. accuracy 1.0 gives zero error. `scale` multiplies the limit at the draw
## (the M2B2 aim settle); 1.0 gives the same floats as before, and the two draws are the same whatever the scale.
static func aim_error(accuracy: float, max_error_deg: float, rng: RandomNumberGenerator, scale: float = 1.0) -> Vector2:
	var limit := deg_to_rad(max_error_deg) * (1.0 - clampf(accuracy, 0.0, 1.0)) * scale
	return Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))


## M2B2 aim settle (big maps; brain.fight placeholders, OQ-BOT-FIGHT): the aim-error scale after keeping the same
## visible target for settle_s seconds. full_s <= 0: no settle (1.0). The scale falls linearly from 1.0 toward the
## floor over full_s; a target at speed_ref_mps or faster does not settle (its floor is 1.0); the settle only fully
## applies at range_ref_m or farther (a nearer target settles in proportion; range_ref_m <= 0: always full).
static func settle_scale(settle_s: float, target_speed_mps: float, dist_m: float, full_s: float, floor_frac: float,
		speed_ref_mps: float, range_ref_m: float) -> float:
	if full_s <= 0.0:
		return 1.0
	var t := clampf(settle_s / full_s, 0.0, 1.0)
	var moving := clampf(target_speed_mps / speed_ref_mps, 0.0, 1.0) if speed_ref_mps > 0.0 else 0.0
	var floor_eff := lerpf(floor_frac, 1.0, moving)
	var reach := clampf(dist_m / range_ref_m, 0.0, 1.0) if range_ref_m > 0.0 else 1.0
	return lerpf(1.0, floor_eff, t * reach)


## Yaw of a world direction as the Y rotation that makes a node's -Z face it.
static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


static func pitch_of(dir: Vector3) -> float:
	return asin(clampf(dir.normalized().y, -1.0, 1.0))


## Look delta in the Pawn convention (rotate_y(-look.x), pitch -= look.y), limited per tick.
static func look_toward(cur_yaw: float, cur_pitch: float, want_yaw: float, want_pitch: float, max_step: float) -> Vector2:
	var dyaw := clampf(wrapf(want_yaw - cur_yaw, -PI, PI), -max_step, max_step)
	var dpitch := clampf(want_pitch - cur_pitch, -max_step, max_step)
	return Vector2(-dyaw, -dpitch)
