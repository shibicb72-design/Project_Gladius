class_name SprintDetector
extends RefCounted
## Touch sprint trigger (docs/CONTROLS.md Sprint). Sprint starts once the move stick has been held at the
## forward extreme (deflection >= threshold AND inside the forward cone) for sprint_hold_s. Breaking the
## condition restarts the timer. The speed ramp itself lives in the pawn; this only decides "sprint requested".
## Sprint sensitivity (0..100) only moves the threshold; hold time, cone and speeds never change with it.

var hold_s: float = 0.0
var threshold_at_0: float = 1.0
var threshold_at_100: float = 1.0
var cone_half_angle_deg: float = 0.0
var sensitivity: float = 0.0
var held_s: float = 0.0
var sprinting: bool = false
var configured: bool = false


## stats: data/stats.json "movement"; sprint: data/input.json "sprint"; sens: data/input.json "sprint_sensitivity".
func configure(stats: Dictionary, sprint: Dictionary, sens: Dictionary) -> void:
	hold_s = float(stats["sprint_hold_s"]["value"])
	threshold_at_0 = float(sprint["threshold_at_sensitivity_0"]["value"])
	threshold_at_100 = float(sprint["threshold_at_sensitivity_100"]["value"])
	cone_half_angle_deg = float(sprint["forward_cone_half_angle_deg"]["value"])
	sensitivity = float(sens["default"])
	configured = true


## Sensitivity snapped to the slider step and clamped to [min, max].
static func snap_sensitivity(value: float, sens: Dictionary) -> float:
	var step := float(sens["step"])
	return clampf(roundf(value / step) * step, float(sens["min"]), float(sens["max"]))


## Forward deflection threshold (fraction of stick radius) for the current sensitivity; linear in between.
func get_threshold() -> float:
	return lerpf(threshold_at_0, threshold_at_100, clampf(sensitivity / 100.0, 0.0, 1.0))


## Forward is -y (the same convention as InputFrame.move). True when the stick is pushed far enough, inside the cone.
func at_forward_extreme(move: Vector2) -> bool:
	if not configured or move.y >= 0.0 or move.length() < get_threshold():
		return false
	return rad_to_deg(atan2(absf(move.x), -move.y)) <= cone_half_angle_deg


func update(move: Vector2, delta: float) -> void:
	if not configured:
		return
	if at_forward_extreme(move):
		held_s += delta
	else:
		held_s = 0.0
	sprinting = held_s >= hold_s


func reset() -> void:
	held_s = 0.0
	sprinting = false
