class_name GyroProvider
extends InputProvider
## Gyro aim. No-op unless enabled and the platform reports a gyro (default off, OQ-34).
## The engine sensor is switched on in project.godot (input_devices/sensors/enable_gyroscope); the
## profile toggle is what gates use. iOS port: add the motion-usage permission string
## (NSMotionUsageDescription) to the iOS export before shipping there.

const _Platform := preload("res://scripts/platform/platform_services.gd")

var enabled: bool = false
var sensitivity: float = 1.0  # overwritten from data/input.json gyro.sensitivity (placeholder, OQ-36)
var _platform := _Platform.new()


func configure(cfg: Dictionary) -> void:
	enabled = str(cfg.get("gyro_mode", "off")) != "off"
	if cfg.has("sensitivity"):
		sensitivity = float(cfg["sensitivity"])


func get_look() -> Vector2:
	if not enabled or not _platform.has_gyro():
		return Vector2.ZERO
	var r := _platform.get_gyro_rate()
	return Vector2(r.y, r.x) * sensitivity
