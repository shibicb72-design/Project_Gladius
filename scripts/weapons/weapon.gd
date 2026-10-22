class_name Weapon
extends RefCounted
## Fire timing, burst, magazine/reserve and reload for one weapon. Pure: time is injected (seconds).

var def: WeaponDef
var ammo_in_mag: int = 0
var reserve: int = 0
var reloading: bool = false

var _next_fire_time: float = 0.0
var _burst_left: int = 0
var _next_burst_time: float = 0.0
var _reload_end: float = 0.0


func _init(weapon_def: WeaponDef = null) -> void:
	def = weapon_def
	if def != null:
		ammo_in_mag = def.magazine
		reserve = def.reserve_ammo


## Advances the weapon to `now`; returns how many shots were fired since the last call.
func update(now: float, trigger_held: bool) -> int:
	if def == null:
		return 0
	if reloading and now >= _reload_end:
		var take: int = mini(def.magazine - ammo_in_mag, reserve)
		ammo_in_mag += take
		reserve -= take
		reloading = false
	if reloading:
		return 0
	var shots := 0
	# Finish a running burst.
	while _burst_left > 0 and ammo_in_mag > 0 and now >= _next_burst_time:
		shots += _shoot()
		_next_burst_time += def.burst_interval_s
	if ammo_in_mag <= 0:
		_burst_left = 0
	# Start a new burst.
	if _burst_left == 0 and trigger_held and ammo_in_mag > 0 and now >= _next_fire_time:
		_next_fire_time = now + def.fire_interval_s
		_burst_left = def.burst_count
		_next_burst_time = now
		shots += _shoot()
		_next_burst_time += def.burst_interval_s
	return shots


func _shoot() -> int:
	ammo_in_mag -= 1
	_burst_left -= 1
	return 1


## Starts a reload if one is useful. Returns true if it started.
func start_reload(now: float) -> bool:
	if def == null or reloading or ammo_in_mag >= def.magazine or reserve <= 0:
		return false
	reloading = true
	_reload_end = now + def.reload_s
	_burst_left = 0
	return true


func cancel_reload() -> void:
	reloading = false
