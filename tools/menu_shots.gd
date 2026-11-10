extends Node
## Before/after proof of the front-end screens (M2U1). Run windowed (needs a display; headless gives no image):
##   godot --path . --audio-driver Dummy res://tools/menu_shots.tscn -- --out=build/shots/before
##       [--only=<substring of screen name>] [--sizes=1512x648,1152x959] [--safe=l,t,r,b]
## Every screen renders in a fresh SubViewport per phone size that emulates the project's canvas_items/expand
## stretch (size = device px, canvas = base window scaled to fit), with that phone's DPI and a temporary profile.
## Output: <out>/<screen>_<W>x<H>.png (screen gets a "_safe" suffix with --safe). Exit 0 if every shot saved.

const TMP_PROFILE := "user://shots_menu_profile.json"

const _Boot := preload("res://scenes/boot/boot.tscn")
const _MainMenu := preload("res://scenes/ui/main_menu.tscn")
const _Lobby := preload("res://scenes/ui/lobby.tscn")
const _End := preload("res://scenes/ui/end_screen.tscn")
const _Pause := preload("res://scenes/ui/pause_menu.tscn")
const _Sensitivity := preload("res://scenes/ui/sensitivity_screen.tscn")
const _Haptics := preload("res://scenes/ui/haptics_screen.tscn")
const _Editor := preload("res://scenes/ui/layout_editor.tscn")

class FakeSupported extends HapticsBackend:
	func is_supported() -> bool:
		return true

	func vibrate(_duration_ms: int, _amplitude: float) -> void:
		pass

## [device px, screen dpi, note]. Phone sizes live only here (not in data/input.json).
const SIZES: Array = [
	[Vector2i(2520, 1080), 420.0, "Fold 7 cover"],
	[Vector2i(2176, 1812), 373.0, "Fold 7 inner"],
	[Vector2i(1512, 648), 252.0, "cover stand-in: same canvas, 60% pixels"],
	[Vector2i(1152, 959), 197.5, "inner stand-in: same canvas"],
	[Vector2i(2340, 1080), 500.0, "S24/S25 Ultra default resolution; dpi is a GUESS"],
	[Vector2i(3120, 1440), 500.0, "S24/S25 Ultra full resolution; dpi is a GUESS"],
]

const SCREENS: Array[String] = [
	"boot", "main_menu", "main_menu_settings", "lobby", "end_victory", "end_placed",
	"pause", "pause_confirm", "pause_settings", "sensitivity", "haptics", "layout_editor",
]

const END_RESULT := {
	"winner": 4, "draw": false, "placements": {4: 1, 7: 2, 9: 3}, "kills": {4: 3, 7: 0},
	"local_player_id": 4, "local_squad_id": 4, "squad_count": 3,
}

var _out: String = "build/shots"
var _only: String = ""
var _sizes: PackedStringArray = PackedStringArray()
var _safe: Variant = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a.begins_with("--sizes="):
			_sizes = a.substr(8).split(",", false)
		elif a.begins_with("--safe="):
			var p := a.substr(7).split(",")
			if p.size() == 4:
				_safe = Vector4(p[0].to_float(), p[1].to_float(), p[2].to_float(), p[3].to_float())
			else:
				push_error("[menu_shots] --safe needs four fractions l,t,r,b; ignored")
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	var failed := 0
	var saved_profile: Dictionary = AppFlow.profile
	AppFlow.profile = {}
	PlatformServices.safe_insets_override = _safe
	for screen in SCREENS:
		if _only != "" and not screen.contains(_only):
			continue
		for spec in SIZES:
			var px: Vector2i = spec[0]
			var tag := "%dx%d" % [px.x, px.y]
			if not _sizes.is_empty() and not _sizes.has(tag):
				continue
			if not await _one(screen, px, float(spec[1])):
				failed += 1
	PlatformServices.dpi_override = 0.0
	PlatformServices.safe_insets_override = null
	AppFlow.profile = saved_profile
	if FileAccess.file_exists(TMP_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PROFILE))
	get_tree().quit(1 if failed > 0 else 0)


## SubViewport of `px` device pixels whose canvas follows the canvas_items/expand stretch (as tools/touch_capture.gd).
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


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _one(screen: String, px: Vector2i, dpi: float) -> bool:
	PlatformServices.dpi_override = dpi
	var svp := _viewport(px)
	var lobby: Lobby = null
	var wait := 6
	match screen:
		"boot":
			var boot: Node = _Boot.instantiate()
			if "auto_advance" in boot:
				boot.set("auto_advance", false)
			else:
				boot.set_script(null)  # old boot changes scene in _ready; without it only its static Label shows
			svp.add_child(boot)
		"main_menu", "main_menu_settings":
			var menu: MainMenu = _MainMenu.instantiate()
			menu.save = SaveService.new(TMP_PROFILE)
			svp.add_child(menu)
			if screen == "main_menu_settings":
				await _frames(4)
				if menu.has_method("open_settings"):
					menu.call("open_settings")
				else:  # old UI: settings are inline in the scrolling column
					menu.scroll.ensure_control_visible(menu.settings.haptics_button)
		"lobby":
			var s := NetSession.new()
			s.name = "MenuShotsSession"
			s.isolated = true
			get_tree().root.add_child(s)
			AppFlow.session = s
			s.host_game()
			lobby = _Lobby.instantiate()
			svp.add_child(lobby)
			lobby.ips_label.text = "Your IP: 192.168.43.1"  # fixed sample: shots never carry this machine's addresses
		"end_victory", "end_placed":
			var end: EndScreen = _End.instantiate()
			var r: Dictionary = END_RESULT.duplicate(true)
			if screen == "end_placed":
				r["local_player_id"] = 7
				r["local_squad_id"] = 7
			end.result = r
			svp.add_child(end)
		"pause", "pause_confirm", "pause_settings":
			var game := ColorRect.new()  # stand-in for the match behind the menu
			game.color = Color(0.33, 0.36, 0.33)
			game.set_anchors_preset(Control.PRESET_FULL_RECT)
			svp.add_child(game)
			var pm: PauseMenu = _Pause.instantiate()
			svp.add_child(pm)
			if pm.settings != null:
				pm.settings.save = SaveService.new(TMP_PROFILE)  # never touch the real profile
			pm.open()
			if screen == "pause_confirm":
				pm.quit_button.pressed.emit()
			elif screen == "pause_settings":
				pm.settings_button.pressed.emit()
		"sensitivity":
			var sens: SensitivityScreen = _Sensitivity.instantiate()
			sens.save = SaveService.new(TMP_PROFILE)
			svp.add_child(sens)
		"haptics":
			var hap: HapticsScreen = _Haptics.instantiate()
			hap.save = SaveService.new(TMP_PROFILE)
			hap.service = HapticsService.new({}, FakeSupported.new())
			svp.add_child(hap)
		"layout_editor":
			var ed: LayoutEditor = _Editor.instantiate()
			ed.save = SaveService.new(TMP_PROFILE)
			svp.add_child(ed)
			wait = 8  # it refreshes two frames after _ready
	await _frames(wait)
	await RenderingServer.frame_post_draw
	var label := screen + ("_safe" if _safe != null else "")
	var file := "%s_%dx%d.png" % [label, px.x, px.y]
	var err := svp.get_texture().get_image().save_png(_out.path_join(file))
	print("[menu_shots] %s %dx%d -> %s" % [label, px.x, px.y, error_string(err)])
	if lobby != null:
		lobby.free()
		AppFlow.end_session()
	svp.free()
	return err == OK
