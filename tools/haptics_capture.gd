extends Node
## Desktop-render proof of the Haptics settings screen (G2f). Run windowed (needs a display):
##   godot --path . res://tools/haptics_capture.tscn -- --out=build/shots
## Each shot renders the screen inside a SubViewport of a Fold size (2520x1080 cover, 2176x1812 inner, and the
## two small stand-ins 1512x648 and 1152x959; landscape only, OQ-PORTRAIT) with a temporary profile and a fake
## backend that reports "supported" (a desktop has no vibration, so the real one would show the unsupported text).

const _Screen := preload("res://scenes/ui/haptics_screen.tscn")
const TMP_PROFILE := "user://shots_haptics_profile.json"

class FakeSupported extends HapticsBackend:
	func is_supported() -> bool:
		return true

	func vibrate(_duration_ms: int, _amplitude: float) -> void:
		pass

## [viewport size, file name]
const SHOTS: Array = [
	[Vector2i(2520, 1080), "haptics_settings_cover_landscape"],
	[Vector2i(2176, 1812), "haptics_settings_inner_landscape"],
	[Vector2i(1512, 648), "haptics_settings_cover_small_landscape"],
	[Vector2i(1152, 959), "haptics_settings_inner_small_landscape"],
]

var _out: String = "build/shots"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	var failed := 0
	for spec in SHOTS:
		if not await _one(spec[0], spec[1]):
			failed += 1
	if FileAccess.file_exists(TMP_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PROFILE))
	get_tree().quit(1 if failed > 0 else 0)


func _one(size: Vector2i, name: String) -> bool:
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	var screen: HapticsScreen = _Screen.instantiate()
	screen.save = SaveService.new(TMP_PROFILE)
	screen.service = HapticsService.new({}, FakeSupported.new())
	svp.add_child(screen)
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % name))
	print("[haptics_capture] %s %s -> %s" % [name, str(size), error_string(err)])
	svp.queue_free()
	return err == OK
