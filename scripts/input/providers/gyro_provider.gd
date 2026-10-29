class_name GyroProvider
extends InputProvider
## Gyro aim. No-op unless the mode allows it and the platform reports a gyro (default off, OQ-34).
## Modes: "off", "scope_on" (only while aiming, ADS), "always_on". The legacy value "on" means always_on.
## The engine sensor is switched on in project.godot (input_devices/sensors/enable_gyroscope); the
## profile mode is what gates use. No aim assist on gyro (DESIGN.md). Table percentages and inversion are
## applied by InputRouter. iOS motion permission string: export_presets.cfg [preset.1.options]
## application/additional_plist_content (NSMotionUsageDescription).
## Look is a rate source like the right stick (look_math.gd): the gyro's rad/s become radians per
## physics tick, times `sensitivity`, capped by look.max_turn_rate_deg_s. Sensitivity 1.0 at 100 %
## turns the camera as far as the phone turns.

const _Platform := preload("res://scripts/platform/platform_services.gd")
const _LookMath := preload("res://scripts/input/look_math.gd")
const MODES: Array[String] = ["off", "scope_on", "always_on"]

var enabled: bool = false  # mode != "off"
var mode: String = "off"
var ads: bool = false
var sensitivity: float = 1.0  # overwritten from data/input.json gyro.sensitivity (placeholder, OQ-36)
var _platform := _Platform.new()
var _cfg: Dictionary = {}  # the whole data/input.json; clamp_turn reads its "look" block


func _init() -> void:
	look_source = "gyro"
	_cfg = DataRegistry.new().load_file("res://data/input.json")


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
	var r := _platform.get_gyro_rate()  # rad/s: x pitch, y yaw, z roll
	var v := Vector2(r.y, r.x) / _LookMath.tick_hz() * sensitivity
	return _LookMath.clamp_turn(v, _cfg, _LookMath.tick_hz())
