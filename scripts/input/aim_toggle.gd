class_name AimToggle
extends RefCounted
## ADS pure tap toggle (OQ-AIM, Shibi pick 1.1, Fold eye-test 2026-10-28). Each rising edge of the Aim button
## flips the latch; aim stays on after release until the next press. On by default (stats.json
## aim.aim_toggle_enabled); disabled = hold-to-aim passthrough. aim.aim_hold_threshold_s is not read (kept for data shape).

var enabled: bool = true
var toggled_aim: bool = false
var _was_pressed: bool = false


func configure(cfg: Dictionary) -> void:
	enabled = bool(cfg.get("aim_toggle_enabled", true))


## Maps raw aim-button pressed into effective aiming for this tick.
func resolve(raw_pressed: bool) -> bool:
	var just_pressed := raw_pressed and not _was_pressed
	_was_pressed = raw_pressed
	if not enabled:
		toggled_aim = false
		return raw_pressed
	if just_pressed:
		toggled_aim = not toggled_aim
	return toggled_aim


## Drops the latch (local death). The button's edge state is kept, so a finger still on Aim does not re-latch
## until it is lifted and pressed again.
func clear_latch() -> void:
	toggled_aim = false


func reset() -> void:
	toggled_aim = false
	_was_pressed = false
