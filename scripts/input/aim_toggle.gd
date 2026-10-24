class_name AimToggle
extends RefCounted
## Optional ADS hold-vs-toggle (tps-demo player_input.gd timing pattern).
## Short press (< hold_threshold_s) latches aim until pressed again; longer hold is hold-to-aim.
## Disabled by default so existing hold-to-aim UX and tests stay unchanged.

var enabled: bool = false
var hold_threshold_s: float = 0.4
var toggled_aim: bool = false
var aiming_timer: float = 0.0
var _was_pressed: bool = false


func configure(cfg: Dictionary) -> void:
	enabled = bool(cfg.get("aim_toggle_enabled", false))
	hold_threshold_s = float(cfg.get("aim_hold_threshold_s", 0.4))


## Maps raw aim-button pressed into effective aiming for this tick.
func resolve(raw_pressed: bool, delta: float) -> bool:
	if not enabled:
		_was_pressed = raw_pressed
		toggled_aim = false
		aiming_timer = 0.0
		return raw_pressed
	var just_released := _was_pressed and not raw_pressed
	var just_pressed := (not _was_pressed) and raw_pressed
	_was_pressed = raw_pressed
	var current_aim := false
	if just_released and aiming_timer <= hold_threshold_s:
		current_aim = true
		toggled_aim = true
	else:
		current_aim = toggled_aim or raw_pressed
		if just_pressed:
			toggled_aim = false
	if current_aim:
		aiming_timer += delta
	else:
		aiming_timer = 0.0
	return current_aim


func reset() -> void:
	toggled_aim = false
	aiming_timer = 0.0
	_was_pressed = false
