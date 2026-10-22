class_name PlatformServices
extends RefCounted
## Platform-specific code lives here behind an OS.get_name() switch with no-op fallbacks.


func is_touch_device() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return true
		_:
			return DisplayServer.is_touchscreen_available()


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
