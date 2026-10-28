class_name CameraKnockback
extends RefCounted
## Camera knockback on fire (Path A phase 2). Pattern from Kenney Starter-Kit-FPS objects/player.gd action_shoot (MIT):
## each shot kicks the view up and sideways, the sideways sign random per shot (random_vec2). Unlike Kenney, which also
## adds the kick to rotation_target so it stays, this offset recovers: it falls linearly to zero over recover_s after
## the latest kick. Pure math (no Node; time comes in as delta). Values: data/camera.json camera_knockback_* (Shibi-approved
## industry defaults 2026-10-28, OQ-CAM-KNOCKBACK).

## Recovery time left (seconds) that already counts as rest.
const REST_EPS_S := 1e-6

## Kick per shot in radians. Pitch > 0 tilts the view up; the yaw sign is picked per kick.
var pitch_rad: float = 0.0
var yaw_rad: float = 0.0
## Seconds from the latest kick back to rest; 0 turns the knockback off.
var recover_s: float = 0.0
## Current view offset in radians: x = pitch (+ up), y = yaw (Node3D rotation.y sense, + turns left).
var offset: Vector2 = Vector2.ZERO
## Picks the yaw sign; tests seed it.
var rng := RandomNumberGenerator.new()
var _peak: Vector2 = Vector2.ZERO
var _left_s: float = 0.0


func _init() -> void:
	rng.randomize()


## Reads camera_knockback_pitch_deg / _yaw_deg / _recover_s ({"value": x} entries or plain numbers). Missing keys read
## as 0, which turns the knockback off.
func configure(cfg: Dictionary) -> void:
	pitch_rad = deg_to_rad(_number(cfg, "camera_knockback_pitch_deg"))
	yaw_rad = absf(deg_to_rad(_number(cfg, "camera_knockback_yaw_deg")))
	recover_s = maxf(0.0, _number(cfg, "camera_knockback_recover_s"))
	reset()


## One shot: adds a kick on top of what is left of earlier ones and restarts the recovery. Returns the kick added.
func kick() -> Vector2:
	if recover_s <= 0.0:
		return Vector2.ZERO
	var add := Vector2(pitch_rad, yaw_rad if rng.randi() % 2 == 0 else -yaw_rad)
	_peak = offset + add
	_left_s = recover_s
	offset = _peak
	return add


## Advances the recovery by delta seconds and returns the new offset. Within REST_EPS_S of the end it is at rest, so
## float drift in the summed deltas (0.2 - 0.05 - 0.1 - 0.05 > 0) cannot leave a tiny offset behind.
func tick(delta: float) -> Vector2:
	if _left_s <= 0.0:
		return offset
	_left_s -= delta
	if _left_s <= REST_EPS_S or recover_s <= 0.0:
		reset()
		return offset
	offset = _peak * (_left_s / recover_s)
	return offset


func reset() -> void:
	offset = Vector2.ZERO
	_peak = Vector2.ZERO
	_left_s = 0.0


static func _number(cfg: Dictionary, key: String) -> float:
	var entry: Variant = cfg.get(key, 0.0)
	if entry is Dictionary:
		return float((entry as Dictionary).get("value", 0.0))
	return float(entry)
