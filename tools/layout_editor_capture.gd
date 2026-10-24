extends Node
## Desktop-render proof of the HUD layout editor (G2e). Run windowed (needs a display):
##   godot --path . res://tools/layout_editor_capture.tscn -- --out=build/shots
## Each shot renders the editor inside a SubViewport of a Fold size (2520x1080 cover, 2176x1812 inner, and the two
## small stand-ins 1512x648 and 1152x959; landscape only, OQ-PORTRAIT) with a temporary profile. The cover_small
## shot shows the off-screen warning.

const _Editor := preload("res://scenes/ui/layout_editor.tscn")
const TMP_PROFILE := "user://shots_layout_editor_profile.json"

## [viewport size, file name, scene of edits]
const SHOTS: Array = [
	[Vector2i(2520, 1080), "layout_editor_cover_landscape", "edited"],
	[Vector2i(2176, 1812), "layout_editor_inner_landscape", "default"],
	[Vector2i(1512, 648), "layout_editor_cover_small_landscape", "offscreen"],
	[Vector2i(1152, 959), "layout_editor_inner_small_landscape", "slot2"],
]

var _out: String = "build/shots"
var _left_fire_shot: String = ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--left-fire-shot="):  # G3e: one shot with the left Fire button on: "cover" or "inner"
			_left_fire_shot = a.substr(17)
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	var failed := 0
	var saved: Dictionary = AppFlow.profile
	AppFlow.profile = {}
	var shots: Array = SHOTS
	if _left_fire_shot != "":
		AppFlow.profile = {"left_fire_enabled": true}
		var sz := Vector2i(2520, 1080) if _left_fire_shot == "cover" else Vector2i(2176, 1812)
		shots = [[sz, "layout_editor_left_fire_%s_landscape" % _left_fire_shot, "left_fire"]]
	for spec in shots:
		if not await _one(spec[0], spec[1], spec[2]):
			failed += 1
	AppFlow.profile = saved
	if FileAccess.file_exists(TMP_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PROFILE))
	get_tree().quit(1 if failed > 0 else 0)


func _one(size: Vector2i, name: String, scene: String) -> bool:
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	var ed: LayoutEditor = _Editor.instantiate()
	ed.save = SaveService.new(TMP_PROFILE)
	svp.add_child(ed)
	for i in 4:
		await get_tree().process_frame
	match scene:
		"edited":
			ed.select_element("jump")
			ed.move_selected_to(Vector2(0.62, 0.22))
			ed.size_slider.value = 140.0
			ed.select_element("sprint_lock")
			ed.move_selected_to(Vector2(0.45, 0.5))
			ed.alpha_slider.value = 60.0
		"default":
			ed.select_element("look_stick")
		"left_fire":
			ed.select_element("fire_left")
		"offscreen":
			ed.select_element("fire")
			ed.move_selected_to(Vector2(0.995, 0.5))
		"slot2":
			ed.select_slot(1)
			ed.select_element("move_stick")
			ed.move_selected_to(Vector2(0.25, 0.7))
			ed.size_slider.value = 70.0
			ed.alpha_slider.value = 50.0
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % name))
	print("[layout_editor_capture] %s %s warn=%s -> %s" % [name, str(size), ed.warn_label.text.replace("\n", " | "), error_string(err)])
	svp.queue_free()
	return err == OK
