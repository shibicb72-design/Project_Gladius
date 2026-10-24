class_name SprintDetector
extends RefCounted
## Touch sprint trigger (docs/CONTROLS.md Sprint). Sprint starts on the tick the move stick reaches the forward
## extreme (deflection >= threshold AND inside the forward cone) and stops on the tick it leaves it; there is no hold.
## Shibi's decision (Oct 23 2026): "Start on the threshold like PUBG". The speed ramp itself lives in the pawn;
## this only decides "sprint requested".
## Sprint sensitivity (0..100) only moves the threshold; cone and speeds never change with it.

var threshold_at_0: float = 1.0
var threshold_at_100: float = 1.0
var cone_half_angle_deg: float = 0.0
var sensitivity: float = 0.0
var sprinting: bool = false
var configured: bool = false


## stats: data/stats.json "movement" (unused here, kept for the call signature); sprint: data/input.json "sprint";
## sens: data/input.json "sprint_sensitivity".
func configure(_stats: Dictionary, sprint: Dictionary, sens: Dictionary) -> void:
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


func update(move: Vector2, _delta: float) -> void:
	if not configured:
		return
	sprinting = at_forward_extreme(move)


func reset() -> void:
	sprinting = false
