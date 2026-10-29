class_name Weapon
extends RefCounted
## Fire timing, burst, magazine/reserve and reload for one weapon. Pure: time is injected (seconds).

var def: WeaponDef
var ammo_in_mag: int = 0
var reserve: int = 0
var reloading: bool = false
## Empty preserves legacy bursts. Only the local HUD opts its weapon into semi/auto.
var fire_mode: String = ""
var _trigger_was_held: bool = false
var _semi_armed: bool = false
var _last_mode_shot: float = -INF

var _next_fire_time: float = 0.0
var _burst_left: int = 0
var _next_burst_time: float = 0.0
var _reload_end: float = 0.0
var _reload_start: float = 0.0


func _init(weapon_def: WeaponDef = null) -> void:
	def = weapon_def
	if def != null:
		ammo_in_mag = def.magazine
		reserve = def.reserve_ammo


## Advances the weapon to `now`; returns how many shots were fired since the last call.
func update(now: float, trigger_held: bool) -> int:
	var edge := trigger_held and not _trigger_was_held
	_trigger_was_held = trigger_held
	if def == null:
		return 0
	if reloading and now >= _reload_end:
		var take: int = mini(def.magazine - ammo_in_mag, reserve)
		ammo_in_mag += take
		reserve -= take
		reloading = false
	if reloading:
		return 0
	if fire_mode == "semi" or fire_mode == "auto":
		if fire_mode == "semi" and edge:
			_semi_armed = true
		var wants_round := _semi_armed if fire_mode == "semi" else trigger_held
		var interval := def.fire_interval_s / maxi(def.burst_count, 1)
		if wants_round and has_ammo() and now >= _next_fire_time and now - _last_mode_shot >= interval:
			_semi_armed = false
			_burst_left = 1
			_last_mode_shot = now
			_next_fire_time = now + interval
			return _shoot()
		return 0
	var shots := 0
	# Finish a running burst.
	while _burst_left > 0 and has_ammo() and now >= _next_burst_time:
		shots += _shoot()
		_next_burst_time += def.burst_interval_s
	if not has_ammo():
		_burst_left = 0
	# Start a new burst.
	if _burst_left == 0 and trigger_held and has_ammo() and now >= _next_fire_time:
		_next_fire_time = now + def.fire_interval_s
		_burst_left = def.burst_count
		_next_burst_time = now
		shots += _shoot()
		_next_burst_time += def.burst_interval_s
	return shots


## Melee weapons never run dry.
func has_ammo() -> bool:
	return def != null and (def.is_melee() or ammo_in_mag > 0)


func _shoot() -> int:
	if not def.is_melee():
		ammo_in_mag -= 1
	_burst_left -= 1
	return 1


## Starts a reload if one is useful. Returns true if it started.
func start_reload(now: float) -> bool:
	if def == null or def.is_melee() or reloading or ammo_in_mag >= def.magazine or reserve <= 0:
		return false
	reloading = true
	_reload_start = now
	_reload_end = now + def.reload_s
	_burst_left = 0
	_semi_armed = false
	return true


## 0..1 progress of a running reload at `now` (0 when not reloading).
func reload_fraction(now: float) -> float:
	if not reloading or _reload_end <= _reload_start:
		return 0.0
	return clampf((now - _reload_start) / (_reload_end - _reload_start), 0.0, 1.0)


func cancel_reload() -> void:
	reloading = false
