class_name HapticsBackend
extends RefCounted
## Platform vibration behind an OS.get_name() switch. Android and iOS call Input.vibrate_handheld(duration_ms,
## amplitude) (docs: class_input.md:1834-1840, "implemented on Android, iOS, and Web"). Android needs the VIBRATE
## permission in the export preset (class_input.md:1842). iOS honours the duration only on iOS 13 and later
## (class_input.md:1844). Desktop, web and the headless server are a no-op. Tests subclass this as a fake.


func is_supported() -> bool:
	match OS.get_name():
		"Android", "iOS":
			return DisplayServer.get_name() != "headless"
		_:
			return false


func vibrate(duration_ms: int, amplitude: float) -> void:
	if not is_supported():
		return
	Input.vibrate_handheld(duration_ms, amplitude)
