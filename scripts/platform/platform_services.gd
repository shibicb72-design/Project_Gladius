class_name PlatformServices
extends RefCounted
## Platform-specific code lives here behind an OS.get_name() switch with no-op fallbacks.


## Tool/test hook: makes the desktop branch below behave as if the DisplayServer reported a
## touchscreen, so the real auto-detect path can be exercised off-device. Never set in shipping code.
static var simulate_touchscreen: bool = false


## Tool/test hook: pretend the screen reports this DPI (0 = use the DisplayServer). Never set in shipping code.
static var dpi_override: float = 0.0


## Screen DPI as the platform reports it (160 when unknown, so 1 dp = 1 px).
func get_screen_dpi() -> float:
	if dpi_override > 0.0:
		return dpi_override
	var dpi := float(DisplayServer.screen_get_dpi())
	return dpi if dpi > 0.0 else 160.0


## Window pixels per density-independent pixel (Android baseline: 160 dpi = 1.0).
func get_dp_scale() -> float:
	return get_screen_dpi() / 160.0


## Startup diagnostic so a device run can confirm the real density.
func log_display_info() -> void:
	print("[display] os=%s screen_get_dpi=%d screen_get_scale=%.3f dp_scale=%.3f window=%s" % [
			OS.get_name(), DisplayServer.screen_get_dpi(), DisplayServer.screen_get_scale(),
			get_dp_scale(), DisplayServer.window_get_size()])


func is_touch_device() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return true
		_:
			return simulate_touchscreen or DisplayServer.is_touchscreen_available()


## Turns touch-to-mouse emulation on or off at runtime (never the project setting) and
## returns the previous value.
func set_mouse_emulation_from_touch(enabled: bool) -> bool:
	var prev := Input.emulate_mouse_from_touch
	Input.emulate_mouse_from_touch = enabled
	return prev


func has_gyro() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return DisplayServer.get_name() != "headless"
		_:
			return false


## Angular rate in rad/s (x pitch, y yaw, z roll). Zero where unsupported.
func get_gyro_rate() -> Vector3:
	if not has_gyro():
		return Vector3.ZERO
	return Input.get_gyroscope()


func vibrate(ms: int) -> void:
	match OS.get_name():
		"Android", "iOS":
			if DisplayServer.get_name() != "headless":
				Input.vibrate_handheld(ms)
		_:
			pass
