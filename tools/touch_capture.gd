extends Node
## Desktop-render proof of the touch HUD (the Android emulator cannot boot on this PC). Run windowed:
##   godot --path . --resolution 2520x1080 res://tools/touch_capture.tscn -- --out=build/shots --tag=folded
## Simulates a touchscreen through PlatformServices (the HUD is NOT forced on), drives it with real input
## events, saves PNGs with a "desktop render" overlay and writes <out>/<tag>_report.txt. Optional: --dpi=N (default: the desktop's reported DPI).

const _LobbyScene := preload("res://scenes/ui/lobby.tscn")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _Platform := preload("res://scripts/platform/platform_services.gd")
const MIN_TOUCH_DP := 48.0
const WALK_S := 1.0
const LOOK_S := 1.0

var _out: String = "build/shots"
var _tag: String = "shot"
var _dpi: float = 0.0
var _report: PackedStringArray = []
var _label: Label
var _real_mouse_swallowed: int = 0
var _trace_events: bool = false
var _vjoy_shot_name: String = ""
var _sprint_shot_name: String = ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--dpi="):
			_dpi = float(a.substr(6))
		elif a.begins_with("--vjoy-shot="):  # only save the VirtualJoystick move stick at rest as <out>/<value>.png
			_vjoy_shot_name = a.substr(12)
		elif a.begins_with("--sprint-shot="):  # sprint lock target mid-push ("sprint_lock_*") or locked state ("sprint_locked_*")
			_sprint_shot_name = a.substr(14)
	_Platform.dpi_override = _dpi  # 0 = leave the DisplayServer value alone
	if _dpi <= 0.0:
		_dpi = _Platform.new().get_screen_dpi()
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	# Overlay notes sit in the top-right corner: clear of the stat bars (top-left), the sticks and buttons
	# (bottom) and the lobby action bar (bottom); lobby rows are left-aligned so their right side is empty.
	var notes := VBoxContainer.new()
	notes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notes.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 8)
	notes.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	notes.offset_top = 56.0  # below the match timer / hill text in the HUD's top row
	layer.add_child(notes)
	_label = Label.new()
	_label.text = "desktop render, not device - %s" % _tag
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_color", Color(1, 1, 0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 6)
	notes.add_child(_label)
	var note := Label.new()
	note.text = "touch auto-detected (simulated touchscreen), not forced"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	note.add_theme_font_size_override("font_size", 14)
	note.add_theme_color_override("font_color", Color(0.6, 1, 0.6))
	note.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	note.add_theme_constant_override("outline_size", 4)
	notes.add_child(note)
	# Simulate a touchscreen device through the real auto-detect path (PlatformServices.is_touch_device).
	_Platform.simulate_touchscreen = true
	_run.call_deferred()


## Capture-only: real desktop mouse events (device != DEVICE_ID_EMULATION) would move Godot's hover/press state
## between an emulated touch press and release (BaseButton then drops the click). Swallow them before the GUI sees
## them; emulated-from-touch mouse events pass, so buttons still react to the simulated finger.
func _input(event: InputEvent) -> void:
	if (event is InputEventMouseMotion or event is InputEventMouseButton) and event.device != InputEvent.DEVICE_ID_EMULATION:
		_real_mouse_swallowed += 1
		get_viewport().set_input_as_handled()
	elif _trace_events:
		_log("trace tap event: %s" % str(event))


func _run() -> void:
	var win := get_window()
	# Park the OS cursor in the top-right corner (over the non-interactive overlay), away from every control.
	Input.warp_mouse(Vector2(get_viewport().get_visible_rect().size.x - 1.0, 1.0))
	_log("tag=%s window=%s viewport=%s dpi=%.0f (DisplayServer.screen_get_dpi()=%d; --dpi=N overrides, e.g. 420 folded / 373 unfolded)" % [
			_tag, win.size, get_viewport().get_visible_rect().size, _dpi, DisplayServer.screen_get_dpi()])
	await _frames(3)
	if _vjoy_shot_name != "":
		if _vjoy_shot_name.contains("portrait"):
			_log("skipped %s: portrait is out of scope (OQ-PORTRAIT); the project is landscape only" % _vjoy_shot_name)
			get_tree().quit(0)
			return
		await _vjoy_rest_shot()
		get_tree().quit(0)
		return
	if _sprint_shot_name != "":
		if _sprint_shot_name.contains("portrait"):
			_log("skipped %s: portrait is out of scope (OQ-PORTRAIT)" % _sprint_shot_name)
		else:
			await _sprint_shot()
		get_tree().quit(0)
		return
	await _lobby_shots()
	await _match_shots()
	var failed: PackedStringArray = []
	for line in _report:
		if line.begins_with("RESULT ") and line.contains("=false"):
			failed.append(line)
	if not failed.is_empty():
		_log("RESULT FAILED: %d false RESULT line(s): %s" % [failed.size(), " | ".join(failed)])
	var f := FileAccess.open(_out.path_join("%s_report.txt" % _tag), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_report) + "\n")
		f.close()
	else:
		push_error("cannot write report in %s" % _out)
	get_tree().quit(1 if not failed.is_empty() else 0)


func _buttons_under(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	for c in node.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_buttons_under(c))
	return out


## Texts under `root` that name keyboard keys or mouse clicks (empty = none shown).
func _keyboard_prompts(root: Node) -> PackedStringArray:
	var found: PackedStringArray = []
	var rx := RegEx.create_from_string("(?i)\\b(wasd|esc|escape|enter|return|space|spacebar|tab|shift|ctrl|click|mouse|keyboard|press [a-z]\\b|\\[[a-z0-9]\\])")
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is Control and (n as Control).is_visible_in_tree() and ("text" in n) and rx.search(str(n.get("text"))) != null:
			found.append(str(n.get("text")))
	return found


func _log(s: String) -> void:
	_report.append(s)
	print("[touch_capture] ", s)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out.path_join("%s_%s.png" % [_tag, name])
	var err := img.save_png(path)
	_log("saved %s (%dx%d) err=%d" % [path, img.get_width(), img.get_height(), err])


## Window pixels per canvas unit (canvas_items stretch), so heights can be reported in real px and dp.
func _px_scale() -> float:
	return get_viewport().get_screen_transform().get_scale().y


func _height_line(what: String, canvas_h: float) -> void:
	var px := canvas_h * _px_scale()
	_log("height %s: %.1f canvas px = %.1f window px = %.1f dp (dpi %.0f)" % [what, canvas_h, px, px / (_dpi / 160.0), _dpi])


func _to_window(canvas_pos: Vector2) -> Vector2:
	return get_viewport().get_screen_transform() * canvas_pos


## A real tap: ScreenTouch index 0 in window coordinates (as Android delivers it), press, 2 frames, release.
func _tap(canvas_pos: Vector2) -> void:
	_touch_event(0, canvas_pos, true)
	await _frames(2)
	_touch_event(0, canvas_pos, false)
	await _frames(3)


func _lobby_shots() -> void:
	# Host first (as test_ui.gd:_host_lobby), so the host-only bot class cycling is reachable (OQ-55).
	var sess := NetSession.new()
	sess.name = "CaptureSession"
	sess.isolated = true
	add_child(sess)
	AppFlow.session = sess
	sess.host_game()
	var lobby: Lobby = _LobbyScene.instantiate()
	add_child(lobby)
	await _frames(4)
	_log("lobby hosted: is_host=%s" % str(lobby.is_host))
	_height_line("lobby class toggle button", lobby.class_button.size.y)
	_height_line("lobby Start button", lobby.start_button.size.y)
	_height_line("lobby first slot row", lobby.slot_buttons[0].size.y if not lobby.slot_buttons.is_empty() else 0.0)
	var checked := 0
	var too_small: PackedStringArray = []
	for b in _buttons_under(lobby):
		if not b.is_visible_in_tree():
			continue
		checked += 1
		var dp := b.size.y * _px_scale() / (_dpi / 160.0)
		if dp < MIN_TOUCH_DP:
			too_small.append("'%s' %.1f dp" % [b.text, dp])
	_log("lobby buttons checked: %d, all >= %.0f dp tall: %s%s" % [checked, MIN_TOUCH_DP,
			str(too_small.is_empty() and checked > 0), "" if too_small.is_empty() else " TOO SMALL: " + ", ".join(too_small)])
	_log("RESULT lobby_buttons_min_%.0fdp=%s" % [MIN_TOUCH_DP, str(too_small.is_empty() and checked > 0)])
	var vp_rect := get_viewport().get_visible_rect()
	var outside: PackedStringArray = []
	for b in _buttons_under(lobby):
		if b.is_visible_in_tree() and b not in lobby.slot_buttons and not vp_rect.encloses(b.get_global_rect()):
			outside.append("'%s' %s" % [b.text, b.get_global_rect()])
	_log("RESULT lobby_action_buttons_inside_viewport=%s%s" % [str(outside.is_empty()), "" if outside.is_empty() else " OUTSIDE: " + ", ".join(outside)])
	_log("lobby keyboard prompts: %s" % str(_keyboard_prompts(lobby)))
	await _shot("lobby_before")
	var before_player := lobby.class_button.text
	_trace_events = true  # log every event delivered during the first (Class) tap
	await _tap(lobby.class_button.get_global_rect().get_center())
	_trace_events = false
	_log("real desktop mouse events swallowed so far: %d" % _real_mouse_swallowed)
	var bot_idx := -1
	for s in lobby.state.slots:
		if bool(s["is_bot"]):
			bot_idx = int(s["player_id"])
			break
	var bot_before := lobby.slot_buttons[bot_idx].text if bot_idx >= 0 else ""
	var bot_class_before := str(lobby.state.assign()[bot_idx]["class_id"]) if bot_idx >= 0 else ""
	if bot_idx >= 0:
		await _tap(lobby.slot_buttons[bot_idx].get_global_rect().get_center())
	var bot_class_after := str(lobby.state.assign()[bot_idx]["class_id"]) if bot_idx >= 0 else ""
	_log("lobby player class toggle: '%s' -> '%s'" % [before_player, lobby.class_button.text])
	if bot_idx >= 0:
		_log("lobby bot row tap: '%s' -> '%s' (class %s -> %s, is_host=%s, OQ-55)" % [
				bot_before, lobby.slot_buttons[bot_idx].text, bot_class_before, bot_class_after, str(lobby.is_host)])
	_log("RESULT player_class_toggled=%s" % str(lobby.class_button.text != before_player))
	_log("RESULT bot_class_cycled=%s" % str(bot_idx >= 0 and bot_class_after != bot_class_before and bot_class_after in Lobby.CLASSES))
	await _shot("lobby_after")
	remove_child(lobby)
	lobby.free()
	AppFlow.end_session()
	await _frames(2)


func _match_shots() -> void:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	add_child(m)
	await _frames(2)
	m.begin()
	await _frames(5)
	var hud: Control = m.get_node("Hud/TouchHud")
	# No forcing: the HUD decides from PlatformServices.is_touch_device() (touchscreen simulated in _ready).
	hud.relayout()
	await _frames(3)
	var forced := bool(hud.cfg.get("force_touch_hud", false))
	_log("touch default: force_touch_hud=%s is_touch_device=%s HUD visible=%s keyboard prompts in HUD: %s" % [
			str(forced), str(_Platform.new().is_touch_device()), str(hud.visible),
			str(_keyboard_prompts(hud))])
	_log("RESULT touch_on_by_default=%s (not forced)" % str(hud.visible and not forced))
	for action in hud.get_button_actions():
		_height_line("HUD button %s (%s)" % [action, hud.get_button_label(action)], hud.get_button_rect(action).size.y)
	await _shot("hud_rest")

	# (c) left-stick walk: finger down in the move zone, drag up, held for WALK_S.
	var pawn: Pawn = m.local_player
	var move_c: Vector2 = hud._zone_rect("move_zone").get_center()
	var start_pos := pawn.global_position
	await _hold_drag(0, move_c, move_c + Vector2(0, -hud._radius()), WALK_S, "walk")
	var mid_pos := pawn.global_position
	await _shot("hud_walk")
	_touch_up(0, move_c + Vector2(0, -hud._radius()))
	_log("walk: start %s end %s moved %.2f m in %.1f s (left stick held)" % [start_pos, mid_pos,
			Vector2(mid_pos.x - start_pos.x, mid_pos.z - start_pos.z).length(), WALK_S])

	# (d) right-side drag: up-right so both yaw and pitch change; pitch must stay in the data clamp.
	var look_c: Vector2 = hud._zone_rect("look_zone").get_center()
	var yaw0 := rad_to_deg(pawn.rotation.y)
	var pitch0 := rad_to_deg(pawn.pitch)
	var tgt := look_c + Vector2(hud._radius(), -hud._radius()) * 0.8
	await _hold_drag(1, look_c, tgt, LOOK_S, "look")
	var yaw1 := rad_to_deg(pawn.rotation.y)
	var pitch1 := rad_to_deg(pawn.pitch)
	var rate_cap: float = float(hud.cfg["look"].get("max_turn_rate_deg_s", 0.0))
	var rate := sqrt(pow(yaw1 - yaw0, 2.0) + pow(pitch1 - pitch0, 2.0)) / LOOK_S
	_log("look rate: %.1f deg/s over %.1f s vs data cap max_turn_rate_deg_s=%.1f -> exceeds cap: %s (reported only, cap unchanged)" % [
			rate, LOOK_S, rate_cap, str(rate_cap > 0.0 and rate > rate_cap + 0.001)])
	await _shot("hud_look")
	_touch_up(1, tgt)
	var lo := float(pawn._camera.get("pitch_min_deg", -70.0))
	var hi := float(pawn._camera.get("pitch_max_deg", 70.0))
	_log("look: yaw %.1f -> %.1f deg (delta %.1f), pitch %.1f -> %.1f deg, clamp [%.1f, %.1f], within clamp: %s" % [
			yaw0, yaw1, yaw1 - yaw0, pitch0, pitch1, lo, hi, str(pitch1 >= lo - 0.001 and pitch1 <= hi + 0.001)])
	_log("RESULT walk_moved=%s look_changed=%s pitch_bounded=%s" % [
			str(Vector2(mid_pos.x - start_pos.x, mid_pos.z - start_pos.z).length() > 0.05),
			str(not is_equal_approx(yaw0, yaw1) or not is_equal_approx(pitch0, pitch1)),
			str(pitch1 >= lo - 0.001 and pitch1 <= hi + 0.001)])
	m.queue_free()
	await _frames(2)


## G2 trial: the touch HUD with the VirtualJoystick move stick at rest (no touch), over a flat backdrop.
func _vjoy_rest_shot() -> void:
	# No override: the shot shows whatever the shipped default is (data/input.json touch_layout.move_stick).
	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.2, 0.24)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var hud: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	add_child(hud)
	await _frames(4)
	hud.relayout()
	await _frames(3)
	var vj_ok: bool = hud.move_mode == "virtual" and hud.vjoy_layout == "floating" and hud.move_stick is VirtualJoystick and hud.move_stick.is_visible_in_tree() and hud._move_touch == -1
	_log("vjoy rest: visible=%s dp=%.1f RESULT vjoy_rest_visible=%s" % [str(hud.visible), hud.get_move_target_dp(), str(vj_ok)])
	var img_name := _vjoy_shot_name
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_out.path_join("%s.png" % img_name))
	_log("saved %s.png (%dx%d) err=%d" % [img_name, img.get_width(), img.get_height(), err])


## G2c: the touch HUD with the sprint-lock target visible mid-push, or in the locked state. The HUD's touch handlers are
## called directly and the VirtualJoystick output is simulated through its InputMap actions (as the joystick would press them).
func _sprint_shot() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.2, 0.24)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var hud: Control = load("res://scenes/ui/touch_hud.tscn").instantiate()
	add_child(hud)
	await _frames(4)
	hud.relayout()
	var start: Vector2 = hud.get_move_rest() if hud.vjoy_layout == "fixed" and hud.move_mode == "virtual" else Vector2(0.18, 0.7) * hud.size
	hud._on_down(0, start)
	var up: Vector2 = start + Vector2(0.0, -hud._radius())
	hud._on_drag(0, up, Vector2.ZERO)
	if hud.move_mode == "virtual":
		Input.action_press("vjoy_move_up", 1.0)
	await _frames(3)
	var ok: bool = hud.provider.lock_target_visible()
	if _sprint_shot_name.begins_with("sprint_locked"):
		var t: Rect2 = hud.get_lock_target_rect()
		hud._on_drag(0, t.get_center(), Vector2.ZERO)
		hud._on_up(0)
		if hud.move_mode == "virtual":
			Input.action_release("vjoy_move_up")
		await _frames(3)
		ok = hud.provider.sprint_locked
	_log("sprint shot %s: dp=%.1f target_or_locked=%s RESULT sprint_state_ok=%s" % [_sprint_shot_name, hud.get_lock_button_rect().size.x / _Platform.new().get_dp_scale(), str(ok), str(ok)])
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_out.path_join("%s.png" % _sprint_shot_name))
	_log("saved %s.png (%dx%d) err=%d" % [_sprint_shot_name, img.get_width(), img.get_height(), err])
	Input.action_release("vjoy_move_up")


func _touch_event(idx: int, canvas_pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = _to_window(canvas_pos)
	e.pressed = pressed
	Input.parse_input_event(e)


func _touch_up(idx: int, canvas_pos: Vector2) -> void:
	_touch_event(idx, canvas_pos, false)


## Touch down at `from`, then drag to `to` and keep sending drag events each frame for `seconds`.
func _hold_drag(idx: int, from: Vector2, to: Vector2, seconds: float, _what: String) -> void:
	_touch_event(idx, from, true)
	await _frames(2)
	var t := 0.0
	var prev := from
	while t < seconds:
		var e := InputEventScreenDrag.new()
		e.index = idx
		e.position = _to_window(to)
		e.relative = _to_window(to) - _to_window(prev)
		Input.parse_input_event(e)
		prev = to
		await get_tree().process_frame
		t += get_process_delta_time()
