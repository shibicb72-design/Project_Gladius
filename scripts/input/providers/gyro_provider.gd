class_name GyroProvider
extends InputProvider
## Gyro aim. No-op unless the mode allows it and the platform reports a gyro (default off, OQ-34).
## Modes: "off", "scope_on" (only while aiming, ADS), "always_on". The legacy value "on" means always_on.
## The engine sensor is switched on in project.godot (input_devices/sensors/enable_gyroscope); the
## profile mode is what gates use. No aim assist on gyro (DESIGN.md). Table percentages and inversion are
## applied by InputRouter. iOS port: add the motion-usage permission string
## (NSMotionUsageDescription) to the iOS export before shipping there.

const _Platform := preload("res://scripts/platform/platform_services.gd")
const MODES: Array[String] = ["off", "scope_on", "always_on"]

var enabled: bool = false  # mode != "off"
var mode: String = "off"
var ads: bool = false
var sensitivity: float = 1.0  # overwritten from data/input.json gyro.sensitivity (placeholder, OQ-36)
var _platform := _Platform.new()


func _init() -> void:
	look_source = "gyro"


func configure(cfg: Dictionary) -> void:
	var m := str(cfg.get("gyro_mode", "off"))
	mode = "always_on" if m == "on" else (m if MODES.has(m) else "off")
	enabled = mode != "off"
	if cfg.has("sensitivity"):
		sensitivity = float(cfg["sensitivity"])


func set_look_context(is_ads: bool, _row: String) -> void:
	ads = is_ads


## True when the current mode lets the gyro steer the camera right now.
func allows_gyro() -> bool:
	return mode == "always_on" or (mode == "scope_on" and ads)


func get_look() -> Vector2:
	if not allows_gyro() or not _platform.has_gyro():
		return Vector2.ZERO
	var r := _platform.get_gyro_rate()
	return Vector2(r.y, r.x) * sensitivity
