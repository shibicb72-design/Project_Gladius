extends Node
## Desktop-render proof of the code-drawn menu art (M2U1): MenuBackdrop and MenuLogo. Run windowed (needs a display):
##   godot --path . --audio-driver Dummy res://tools/menu_art_capture.tscn -- --out=build/shots/art
## For each size it saves art_hero_<WxH>.png (hero backdrop + logo top-left), art_page_<WxH>.png (page backdrop)
## and art_boot_<WxH>.png (hero backdrop + centred logo). The backdrop clock is fixed so shots are deterministic.

const SIZES: Array[Vector2i] = [Vector2i(1512, 648), Vector2i(1152, 959), Vector2i(2340, 1080)]
const KINDS: Array[String] = ["hero", "page", "boot"]
const SHOT_TIME_S := 7.5

var _out: String = "build/shots/art"


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
	for px in SIZES:
		for kind in KINDS:
			if not await _one(px, kind):
				failed += 1
	get_tree().quit(1 if failed > 0 else 0)


## SubViewport of `px` device pixels whose canvas follows the canvas_items/expand stretch (as tools/menu_shots.gd).
func _viewport(px: Vector2i) -> SubViewport:
	var base := Vector2(
			float(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
			float(ProjectSettings.get_setting("display/window/size/viewport_height", 648)))
	var p := Vector2(px)
	var s: float = minf(p.x / base.x, p.y / base.y)
	var svp := SubViewport.new()
	svp.size = px
	svp.size_2d_override = Vector2i(roundi(p.x / s), roundi(p.y / s))
	svp.size_2d_override_stretch = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.transparent_bg = false
	add_child(svp)
	return svp


func _one(px: Vector2i, kind: String) -> bool:
	var svp := _viewport(px)
	var canvas := Vector2(svp.size_2d_override)
	var root := Control.new()
	root.size = canvas
	svp.add_child(root)
	var bd := MenuBackdrop.make("page" if kind == "page" else "hero")
	root.add_child(bd)
	bd.set_animated(false)
	bd.set_time(SHOT_TIME_S)
	var logo: MenuLogo = null
	if kind != "page":
		logo = MenuLogo.new()
		if kind == "hero":
			var m := 0.0375 * canvas.y
			logo.align = HORIZONTAL_ALIGNMENT_LEFT
			logo.position = Vector2(m, m)
			logo.size = Vector2(0.55 * canvas.x, 0.0)
		else:
			logo.align = HORIZONTAL_ALIGNMENT_CENTER
			logo.anchor_left = 0.2
			logo.anchor_right = 0.8
			logo.anchor_top = 0.5
			logo.anchor_bottom = 0.5
			logo.grow_vertical = Control.GROW_DIRECTION_BOTH
		root.add_child(logo)
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var shot := "art_%s_%dx%d" % [kind, px.x, px.y]
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % shot))
	var extra := "" if logo == null else " logo_px=%d" % int(logo.get_font_px())
	print("[menu_art_capture] %s canvas=%s%s -> %s" % [shot, str(canvas), extra, error_string(err)])
	svp.queue_free()
	return err == OK
