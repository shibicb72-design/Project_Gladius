class_name GyroProvider
extends InputProvider
## Gyro aim. No-op unless enabled and the platform reports a gyro (default off, OQ-34).

const _Platform := preload("res://scripts/platform/platform_services.gd")

var enabled: bool = false
var sensitivity: float = 1.0
var _platform := _Platform.new()


func configure(cfg: Dictionary) -> void:
	enabled = str(cfg.get("gyro_mode", "off")) != "off"


func get_look() -> Vector2:
	if not enabled or not _platform.has_gyro():
		return Vector2.ZERO
	var r := _platform.get_gyro_rate()
	return Vector2(r.y, r.x) * sensitivity
