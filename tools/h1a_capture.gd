extends Node
## M2 H1a: desktop-render proof of the in-match touch layout on three sizes. Run windowed (needs a display), ONE process:
##   godot.cmd --path . --log-file <log> res://tools/h1a_capture.tscn -- --out=<dir>
## For each size (2176x1812 Fold inner, 2520x1080 Fold outer, 3120x1440 Ultra) it renders a real local match with the touch
## HUD forced on inside a SubViewport and saves, into <dir>:
##   advanced_<WxH>.png   default layout, shooting mode advanced (Fire below Aim)
##   simple_<WxH>.png     shooting mode simple (no right Fire button)
##   cover_<WxH>.png      the pawn in real cover (flat arena far from the map, Cover button pressed through the touch HUD)
##   editor_<WxH>.png     the layout editor on the default layout
##   lookarea_<WxH>.png   like advanced, with the look area as a translucent overlay and every control rect outlined
##                        (drawn here by a throw-away Control; the game scripts have no debug drawing)
## then sheet_<WxH>.png: the five shots in a 3x2 grid, in the order above (row 1: advanced, simple, cover; row 2: editor,
## lookarea). The shooting mode is set in AppFlow.profile in memory only and restored; the editor saves to a temporary
## profile file that is deleted. Presentation only: nothing here feeds back into the game.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _Editor := preload("res://scenes/ui/layout_editor.tscn")
const TMP_PROFILE := "user://shots_h1a_editor_profile.json"
const SIZES: Array = [Vector2i(2176, 1812), Vector2i(2520, 1080), Vector2i(3120, 1440)]
const ORDER: Array = ["advanced", "simple", "cover", "editor", "lookarea"]
const DPI := 420.0
const SHEET_CELL_W := 900
const ARENA_X := 1000.0

var _out: String = "build/shots"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _tag(size: Vector2i) -> String:
	return "%dx%d" % [size.x, size.y]


func _run() -> void:
	var failed := 0
	var saved_profile: Dictionary = AppFlow.profile
	var saved_dpi: float = PlatformServices.dpi_override
	PlatformServices.dpi_override = DPI
	_TouchHud.move_stick_override = "custom"
	for size in SIZES:
		AppFlow.profile = {}
		if not await _match_shots(size):
			failed += 1
		AppFlow.profile = {}
		if not await _editor_shot(size):
			failed += 1
		if not _sheet(size):
			failed += 1
	AppFlow.profile = saved_profile
	PlatformServices.dpi_override = saved_dpi
	_TouchHud.move_stick_override = ""
	if FileAccess.file_exists(TMP_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PROFILE))
	print("[h1a_capture] done failed=%d" % failed)
	get_tree().quit(1 if failed > 0 else 0)


func _save(svp: SubViewport, name: String) -> bool:
	await RenderingServer.frame_post_draw
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % name))
	print("[h1a_capture] %s %s -> %s" % [name, str(svp.size), error_string(err)])
	return err == OK


func _tap(svp: SubViewport, point: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 5
	e.position = point
	e.pressed = down
	svp.push_input(e, true)


func _box(m: Node, at: Vector3, size: Vector3, color: Color, tagged: bool) -> void:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var b := BoxShape3D.new()
	b.size = size
	shape.shape = b
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	body.add_child(mi)
	if tagged:
		body.add_to_group(&"cover_wall")
	m.add_child(body)


## Draws the look area (translucent) and an outline per control rect on top of the HUD; capture only.
class Overlay extends Control:
	var look := Rect2()
	var rects: Dictionary = {}

	func _draw() -> void:
		draw_rect(look, Color(0.1, 0.8, 0.3, 0.28), true)
		draw_rect(look, Color(0.1, 1.0, 0.3, 0.9), false, 4.0)
		for k in rects:
			var r: Rect2 = rects[k]
			draw_rect(r, Color(1.0, 0.85, 0.1, 0.95), false, 3.0)
			draw_string(ThemeDB.fallback_font, r.position + Vector2(6, 26), String(k), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 0.3))


func _match_shots(size: Vector2i) -> bool:
	var tag := _tag(size)
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	svp.add_child(m)
	await get_tree().physics_frame
	m.director.load_config()
	if not m.begin():
		push_error("[h1a_capture] match did not start")
		return false
	await _frames(25)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await _frames(5)
	var ok := true
	# 1 advanced (data default)
	ok = await _save(svp, "advanced_" + tag) and ok
	# 5 look area overlay on the same state
	var ov := Overlay.new()
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.look = touch.get_look_area_rect()
	for k in touch.get_element_keys():
		var r: Rect2 = touch.get_element_rect(k)
		if r.size != Vector2.ZERO:
			ov.rects[k] = r
	svp.add_child(ov)
	await _frames(2)
	ok = await _save(svp, "lookarea_" + tag) and ok
	ov.queue_free()
	# 2 simple, in memory only
	AppFlow.profile = {"shooting_mode": "simple"}
	touch.refresh_shooting_mode()
	await _frames(5)
	ok = await _save(svp, "simple_" + tag) and ok
	print("[h1a_capture] simple buttons=%s" % str(touch.get_button_actions()))
	AppFlow.profile = {}
	touch.refresh_shooting_mode()
	# 3 real cover: a wall in a flat arena far from the map, Cover button through the touch HUD
	var pawn: Pawn = m.local_player
	_box(m, Vector3(ARENA_X, -0.1, 0), Vector3(160, 0.2, 80), Color(0.42, 0.45, 0.36), false)
	_box(m, Vector3(ARENA_X, 1.1, -0.5), Vector3(6, 2.2, 1), Color(0.62, 0.5, 0.38), true)
	_box(m, Vector3(ARENA_X + 14.0, 0.9, -6.0), Vector3(0.6, 1.8, 0.6), Color(0.8, 0.2, 0.18), false)
	var cfg := DataRegistry.new().load_file("res://data/cover.json")
	pawn.position = Vector3(ARENA_X, 0, 0.6)
	pawn.rotation = Vector3.ZERO
	pawn.pitch = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.enable_cover(cfg)
	await _frames(40)
	var w := pawn.loadout.get_active()
	if w != null and w.def.is_melee():
		pawn.loadout.swap()
	var p: Vector2 = touch.get_button_rect(touch.SHOULDER_KEY).get_center()
	_tap(svp, p, true)
	await _frames(2)
	_tap(svp, p, false)
	var settled := false
	for i in 200:
		await get_tree().physics_frame
		if pawn.cover.state == CoverController.State.IN_COVER and not pawn.is_cover_turning():
			settled = true
			break
	await _frames(30)
	print("[h1a_capture] cover state=%s settled=%s" % [CoverController.State.keys()[pawn.cover.state], settled])
	ok = await _save(svp, "cover_" + tag) and ok and settled
	svp.queue_free()
	await _frames(2)
	return ok


func _editor_shot(size: Vector2i) -> bool:
	var svp := SubViewport.new()
	svp.size = size
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	# The editor's own TouchHud releases the virtual-joystick actions on build; outside a match they are not registered,
	# which logs an ERROR per call. Register them for the shot only.
	var added: Array = []
	for a in _TouchHud._VJOY_ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			added.append(a)
	var ed: LayoutEditor = _Editor.instantiate()
	ed.save = SaveService.new(TMP_PROFILE)
	svp.add_child(ed)
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var ok := await _save(svp, "editor_" + _tag(size))
	svp.queue_free()
	await _frames(2)
	for a in added:
		InputMap.erase_action(a)
	return ok


## Contact sheet: the five shots scaled to SHEET_CELL_W wide, 3 columns x 2 rows, in ORDER, on a dark background.
func _sheet(size: Vector2i) -> bool:
	var tag := _tag(size)
	var cw := SHEET_CELL_W
	var ch := int(round(float(cw) * size.y / size.x))
	var gap := 12
	var sheet := Image.create_empty(3 * cw + 4 * gap, 2 * ch + 3 * gap, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.08, 0.08, 0.1))
	for i in ORDER.size():
		var img := Image.load_from_file(_out.path_join("%s_%s.png" % [ORDER[i], tag]))
		if img == null:
			push_error("[h1a_capture] missing %s_%s.png" % [ORDER[i], tag])
			return false
		img.convert(Image.FORMAT_RGB8)
		img.resize(cw, ch, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, cw, ch), Vector2i(gap + (i % 3) * (cw + gap), gap + (i / 3) * (ch + gap)))
	var err := sheet.save_png(_out.path_join("sheet_%s.png" % tag))
	print("[h1a_capture] sheet_%s %dx%d -> %s" % [tag, sheet.get_width(), sheet.get_height(), error_string(err)])
	return err == OK
