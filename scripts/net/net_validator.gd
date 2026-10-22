class_name NetValidator
extends RefCounted
## Pure host-side checks of client requests. No scene or network dependency.

var cfg: Dictionary = {}
var _last_fire_s: Dictionary = {}  # player id -> times of accepted fire requests in the last fire interval


func _init(validation_cfg: Dictionary = {}) -> void:
	cfg = validation_cfg


## Returns {ok: bool, reason: String}. active_weapon is the weapon the host believes is equipped.
func validate_fire(player_id: int, claimed_weapon_id: String, active_weapon: WeaponDef,
		now_s: float, claimed_origin: Vector3, host_muzzle: Vector3, direction: Vector3) -> Dictionary:
	if active_weapon == null or claimed_weapon_id != active_weapon.id:
		return {"ok": false, "reason": "wrong_weapon"}
	if direction.length_squared() < 0.0001 or not direction.is_finite() or not claimed_origin.is_finite():
		return {"ok": false, "reason": "bad_vector"}
	if claimed_origin.distance_to(host_muzzle) > float(cfg.get("fire_origin_max_error_m", 2.0)):
		return {"ok": false, "reason": "bad_origin"}
	# At most burst_count shots per fire interval, each at least one burst gap apart.
	var tol := float(cfg.get("fire_rate_tolerance", 0.8))
	var burst := maxi(active_weapon.burst_count, 1)
	var window: float = active_weapon.fire_interval_s * tol
	var gap: float = active_weapon.burst_interval_s * tol if burst > 1 else window
	var recent: Array = []
	for t in _last_fire_s.get(player_id, []):
		if now_s - float(t) < window:
			recent.append(t)
	if not recent.is_empty() and (now_s - float(recent[-1]) < gap or recent.size() >= burst):
		return {"ok": false, "reason": "rate"}
	recent.append(now_s)
	_last_fire_s[player_id] = recent
	return {"ok": true, "reason": ""}


## True if moving old_pos -> new_pos in dt seconds is plausible for max_speed_mps (horizontal only).
func validate_move(old_pos: Vector3, new_pos: Vector3, dt: float, max_speed_mps: float) -> bool:
	if not new_pos.is_finite():
		return false
	var window := maxf(dt, float(cfg.get("move_min_window_s", 0.05)))
	var flat := Vector2(new_pos.x - old_pos.x, new_pos.z - old_pos.z).length()
	return flat <= max_speed_mps * float(cfg.get("move_speed_tolerance", 1.5)) * window


func forget(player_id: int) -> void:
	_last_fire_s.erase(player_id)
