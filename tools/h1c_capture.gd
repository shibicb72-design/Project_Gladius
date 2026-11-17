extends Node
## M2 H1c: desktop-render proof of the H1c controls in a REAL solo hosted match on alesia_1km. Run windowed (needs a
## display: headless has a dummy renderer), ONE process:
##   godot.cmd --path . --audio-driver Dummy --fixed-fps 60 --log-file <log> res://tools/h1c_capture.tscn -- --out=<dir>
##       [--sheets=<dir>] [--sizes=2176x1812,2520x1080] [--variant=dusk] [--dpi=420]
## Per size it renders into an offscreen SubViewport of exactly that size (the desktop screen may be smaller), with the
## touchscreen simulated through PlatformServices.simulate_touchscreen (the touch HUD is NOT forced on: the real
## auto-detect path) at --dpi (default 420, as h1a / h1b / cover_capture). The match takes the menu route
## (tests/test_h1c_cover_button.gd): an isolated NetSession hosts, its lobby opens and starts, MatchRoot.begin() with the
## carrier, ground loot and map_select. Every input is a real touch event pushed into the SubViewport (Viewport.push_input):
##   drop_NN   the carrier, the Jump button tap, the fall (by height above ground), the landing, the ground after it
##   08_cover_ground  first person on the ground after the landing, not at a wall: the Cover button in the slot
##   01_rest .. 05_released  the move stick (not drawn) and the Sprint lock bubbles: rest, a held move drag, the push into
##                    the sprint zone (Lock target), the lift on the target (Locked), a tap on it (released)
##   06_crouch_standing / 07_crouched  the Crouch button standing, then after a tap (held look, lower eye)
##   09_cover_wall    the pawn 1.1 m from a real map cover_wall piece (fallback: a visible box), the Cover button highlighted
##   10_in_cover      after a tap on the Cover button
## Saves <out>/<WxH>/<shot>.png, <out>/<WxH>/drop_NN.png, <out>/report_<WxH>.txt (the measured state at each capture)
## and labelled contact sheets in --sheets: sheet_<WxH>.png and sheet_drop_<WxH>.png. Bot brains are switched off after
## the landing so nothing shoots the pawn during the stills. Presentation only: nothing here feeds back into the game.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _Platform := preload("res://scripts/platform/platform_services.gd")
const MAP_1KM := "res://data/maps/alesia_1km.json"
const SEED := 4242
const SHOTS: Array = ["01_rest", "02_move_held", "03_sprint_push", "04_locked", "05_released", "06_crouch_standing",
	"07_crouched", "08_cover_ground", "09_cover_wall", "10_in_cover"]
const FALL_MARKS: Array = [0.8, 0.6, 0.42, 0.28, 0.16, 0.08, 0.03]

var _out := "build/h1c_shots"
var _sheets := ""
var _sizes: Array = [Vector2i(2176, 1812), Vector2i(2520, 1080)]
var _variant := "dusk"
var _dpi := 420.0
var _failed := 0
var _svp: SubViewport
var _m: MatchRoot
var _s: NetSession
var _touch: Control
var _pawn: Pawn
var _tag := ""
var _report: PackedStringArray = []
var _captions: Dictionary = {}  # file base name -> caption (per size)
var _drop_names: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--sheets="):
			_sheets = a.substr(9)
		elif a.begins_with("--variant="):
			_variant = a.substr(10)
		elif a.begins_with("--dpi="):
			_dpi = float(a.substr(6))
		elif a.begins_with("--sizes="):
			_sizes = []
			for s in a.substr(8).split(",", false):
				var wh := s.split("x")
				_sizes.append(Vector2i(int(wh[0]), int(wh[1])))
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	if _sheets == "":
		_sheets = _out
	DirAccess.make_dir_recursive_absolute(_out)
	DirAccess.make_dir_recursive_absolute(_sheets)
	_run.call_deferred()


func _log(line: String) -> void:
	print("[h1c_capture] " + line)
	_report.append(line)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _run() -> void:
	var saved_dpi: float = _Platform.dpi_override
	var saved_sim: bool = _Platform.simulate_touchscreen
	var saved_variant: String = MatchLook.variant_override
	_Platform.dpi_override = _dpi
	_Platform.simulate_touchscreen = true
	MatchLook.variant_override = _variant
	for size in _sizes:
		_report = PackedStringArray()
		_captions = {}
		_drop_names = []
		_tag = "%dx%d" % [size.x, size.y]
		DirAccess.make_dir_recursive_absolute(_out.path_join(_tag))
		_log("size %s dpi=%.0f variant=%s seed=%d" % [_tag, _dpi, _variant, SEED])
		var ok: bool = await _session(size)
		if not ok:
			_failed += 1
		var shot_files: Array = []
		var shot_caps: Array = []
		for k in SHOTS:
			var p := _out.path_join(_tag).path_join("%s.png" % k)
			if FileAccess.file_exists(p):
				shot_files.append(p)
				shot_caps.append(_captions.get(k, k))
		if not shot_files.is_empty():
			await _sheet(shot_files, shot_caps, 3, 900, _sheets.path_join("sheet_%s.png" % _tag))
		var drop_files: Array = []
		var drop_caps: Array = []
		for k in _drop_names:
			drop_files.append(_out.path_join(_tag).path_join("%s.png" % k))
			drop_caps.append(_captions.get(k, k))
		if not drop_files.is_empty():
			await _sheet(drop_files, drop_caps, 4, 640, _sheets.path_join("sheet_drop_%s.png" % _tag))
		var f := FileAccess.open(_out.path_join("report_%s.txt" % _tag), FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(_report) + "\n")
			f.close()
	_Platform.dpi_override = saved_dpi
	_Platform.simulate_touchscreen = saved_sim
	MatchLook.variant_override = saved_variant
	print("[h1c_capture] done failed=%d" % _failed)
	get_tree().quit(1 if _failed > 0 else 0)


# --- input ---------------------------------------------------------------------------------------------------------

func _touch_ev(idx: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = p
	e.pressed = down
	_svp.push_input(e, true)


func _drag_ev(idx: int, p: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = p
	e.relative = rel
	_svp.push_input(e, true)


func _tap(idx: int, p: Vector2) -> void:
	_touch_ev(idx, p, true)
	await _frames(2)
	_touch_ev(idx, p, false)
	await _frames(2)


# --- state ---------------------------------------------------------------------------------------------------------

func _stick_drawn() -> bool:
	var s: Control = _touch.move_stick
	if s == null or not s.is_visible_in_tree():
		return false
	if s is StickVisual:
		return (s as StickVisual).drawn and s.modulate.a > 0.0
	return s.modulate.a * s.self_modulate.a > 0.0


func _agl() -> float:
	var from := _pawn.global_position + Vector3.UP * 0.2
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 6000.0)
	q.exclude = [_pawn.get_rid()]
	var hit := _pawn.get_world_3d().direct_space_state.intersect_ray(q)
	return _pawn.global_position.y - (hit["position"] as Vector3).y if not hit.is_empty() else -1.0


func _state() -> String:
	var rig := _pawn.get_node_or_null("CameraRig") as CameraRig
	var cb: Button = _touch._buttons.get("crouch")
	var sb: Button = _touch._buttons.get(_touch.SHOULDER_KEY)
	return ("stick_drawn=%s (data move_stick_drawn()=%s, kind=%s) move_touch=%d | lock_button.visible=%s ('%s') lock_target.visible=%s"
		+ " provider.sprint_locked=%s lock_target_visible()=%s | free_crouch=%s crouch_amount=%.2f crouch_button=%s look=%s"
		+ " eye_y=%.3f | slot='%s' visible=%s cover_slot_active=%s cover_slot_valid=%s engaged=%s in_cover=%s"
		+ " | drop_state=%s first_person=%s agl=%.1f pos=%s touch_hud.visible=%s lan=%s") % [
		_stick_drawn(), _touch.move_stick_drawn(), _touch.move_mode, _touch._move_touch,
		_touch.lock_button.visible, _touch.lock_button.text.replace("\n", " "), _touch.lock_target.visible,
		_touch.provider.sprint_locked, _touch.provider.lock_target_visible(),
		_pawn.free_crouch, _pawn.crouch_amount(), cb.visible if cb != null else false, _touch.crouch_look,
		rig.position.y if rig != null else -1.0,
		sb.text.replace("\n", " ") if sb != null else "-", sb.visible if sb != null else false,
		_touch.cover_slot_active, _touch.cover_slot_valid, _touch.cover_slot_engaged, _pawn.in_cover(),
		Pawn.Drop.keys()[_pawn.drop_state], _touch.first_person_active, _agl(), str(_pawn.global_position.snapped(Vector3.ONE * 0.1)),
		_touch.visible, _pawn.in_lan_session()]


func _save(name: String, caption: String) -> bool:
	await RenderingServer.frame_post_draw
	var path := _out.path_join(_tag).path_join("%s.png" % name)
	var err := _svp.get_texture().get_image().save_png(path)
	_captions[name] = caption
	_log("SHOT %s (%s) -> %s | %s" % [name, caption, error_string(err), _state()])
	if err != OK:
		_failed += 1
	return err == OK


# --- the match -----------------------------------------------------------------------------------------------------

func _session(size: Vector2i) -> bool:
	_svp = SubViewport.new()
	_svp.size = size
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_svp.transparent_bg = false
	add_child(_svp)
	_s = NetSession.new()
	_s.name = "H1cCaptureHost"
	_s.isolated = true
	add_child(_s)
	if _s.host_game() != OK:
		_log("FAIL host_game")
		return false
	_s.lobby.host_open(2, 3, "Host")
	if not _s.lobby.start_match():
		_log("FAIL lobby start")
		return false
	_m = _MatchScene.instantiate()
	_m.auto_start = false
	_m.session_override = _s
	_m.lobby_override = _s.lobby.state
	_m.seed_override = SEED
	_m.drop_from_sky = true
	_m.ground_loot = true
	_m.use_map_select = true
	var chosen: Dictionary = _m.chosen_map()
	if String(chosen["path"]) != MAP_1KM:
		_log("map_select gives %s; using map_path_override %s" % [chosen["path"], MAP_1KM])
		_m.map_path_override = MAP_1KM
	_svp.add_child(_m)
	await get_tree().physics_frame
	if not _m.begin():
		_log("FAIL begin")
		return false
	_pawn = _m.local_player
	_touch = _m.get_node("Hud/TouchHud")
	await _frames(30)
	_log("match: map=%s networked_match=%s touch_hud.visible=%s (force_touch_hud=%s, simulated touchscreen) buttons=%s" % [
		_m.chosen_map()["path"], _m.networked_match, _touch.visible, _touch.cfg.get("force_touch_hud", false), str(_touch.get_button_actions())])
	var ok: bool = await _drop()
	if ok:
		for b in _m.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
				brain.set_process(false)
		ok = await _ground_shots(size)
	_svp.queue_free()
	_s.leave()
	_s.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _frames(3)
	return ok


func _drop_save(caption: String) -> void:
	var name := "drop_%02d" % _drop_names.size()
	_drop_names.append(name)
	await _save(name, caption)


## The real opening: aboard the carrier, a tap on the touch HUD's Jump button, the fall, the landing, the ground.
func _drop() -> bool:
	if _pawn.drop_state != Pawn.Drop.ABOARD:
		_log("FAIL not aboard at the start (%s)" % Pawn.Drop.keys()[_pawn.drop_state])
		return false
	await _drop_save("aboard the carrier")
	await _frames(90)
	await _drop_save("aboard +1.5 s")
	var jumped := false
	if _touch.get_button_actions().has("jump"):
		var c: Vector2 = _touch.get_button_rect("jump").get_center()
		_log("tap Jump at %s" % str(c))
		await _tap(3, c)
		for i in 30:
			if _pawn.drop_state == Pawn.Drop.FALLING:
				jumped = true
				break
			await get_tree().physics_frame
	if not jumped:
		_log("Jump tap did not start the fall; pressing the jump action instead")
		Input.action_press("jump")
		await _frames(2)
		Input.action_release("jump")
	await _frames(12)
	await _drop_save("jumped (falling)")
	var h0 := _agl()
	var mark := 0
	var t := 0
	while _pawn.drop_state != Pawn.Drop.NONE and t < 60 * 240:
		await get_tree().physics_frame
		t += 1
		if mark < FALL_MARKS.size() and _agl() <= h0 * float(FALL_MARKS[mark]):
			await _drop_save("falling, %.0f m above ground" % _agl())
			mark += 1
	if _pawn.drop_state != Pawn.Drop.NONE:
		_log("FAIL no landing after %d physics frames" % t)
		return false
	_log("landed after %.1f s of fall from %.0f m" % [t / 60.0, h0])
	await _frames(2)
	await _drop_save("landed")
	await _frames(60)
	await _drop_save("ground +1 s")
	await _frames(90)
	await _drop_save("ground +2.5 s (Cover button)")
	return true


## A free point in the move zone for a move touch (no button, not the fire-mode or gear rect), with room above it for
## the Lock target.
func _move_point(size: Vector2i) -> Vector2:
	var zone: Rect2 = _touch._move_grab_rect()
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	var fm := FireModeButton.touch_rect(ui["fire_mode_button"], Vector2(size))
	var gear: Rect2 = (_m.get_node("Hud/PauseMenu") as PauseMenu).get_gear_touch_rect()
	for fy in [0.62, 0.55, 0.7, 0.48]:
		for fx in [0.35, 0.45, 0.25, 0.55]:
			var p := zone.position + zone.size * Vector2(fx, fy)
			if _touch._button_at(p) == "" and not fm.has_point(p) and not gear.has_point(p):
				return p
	return zone.get_center()


func _ground_shots(size: Vector2i) -> bool:
	_pawn.pitch = 0.0
	await _frames(4)
	for i in 4:
		if not _touch.cover_slot_valid:
			break
		_pawn.rotation.y += PI * 0.5
		await _frames(4)
	var ok := true
	ok = await _save("08_cover_ground", "08 Cover button on the ground after the landing") and ok
	if not (_touch.cover_slot_active and not _touch.cover_slot_valid):
		_log("CHECK 08: cover_slot_active=%s valid=%s" % [_touch.cover_slot_active, _touch.cover_slot_valid])
	# 01..05: the move stick and the Sprint lock bubbles.
	ok = await _save("01_rest", "01 rest: no stick, no sprint bubble") and ok
	var p := _move_point(size)
	var rad: float = _touch._radius()
	_log("move touch at %s radius=%.0f zone=%s" % [str(p), rad, str(_touch._move_grab_rect())])
	_touch_ev(1, p, true)
	await _frames(2)
	var q := p + Vector2(rad * 0.3, -rad * 0.45)
	_drag_ev(1, q, q - p)
	await _frames(20)
	ok = await _save("02_move_held", "02 thumb held, moving (not the forward extreme)") and ok
	var fwd := p + Vector2(0.0, -rad)
	_drag_ev(1, fwd, fwd - q)
	await _frames(4)
	ok = await _save("03_sprint_push", "03 pushed into the sprint zone: Lock target") and ok
	var target: Vector2 = _touch.get_lock_target_rect().get_center()
	_drag_ev(1, target, target - fwd)
	await _frames(3)
	_touch_ev(1, target, false)
	await _frames(12)
	ok = await _save("04_locked", "04 lifted on the target: Locked") and ok
	if not _touch.provider.sprint_locked:
		_log("CHECK 04: not locked")
	var lb: Vector2 = _touch.get_lock_button_rect().get_center()
	await _tap(2, lb)
	await _frames(15)
	ok = await _save("05_released", "05 tap on Locked: released") and ok
	# 06 / 07: the Crouch button.
	await _frames(30)
	ok = await _save("06_crouch_standing", "06 Crouch button, standing") and ok
	var stand_eye := (_pawn.get_node("CameraRig") as Node3D).position.y
	var cc: Vector2 = _touch.get_button_rect("crouch").get_center()
	await _tap(4, cc)
	for i in 120:
		if _pawn.crouch_amount() >= 1.0:
			break
		await get_tree().physics_frame
	await _frames(4)
	ok = await _save("07_crouched", "07 crouched: held look, lower eye") and ok
	_log("eye standing %.3f -> crouched %.3f" % [stand_eye, (_pawn.get_node("CameraRig") as Node3D).position.y])
	await _tap(4, cc)
	for i in 120:
		if _pawn.crouch_amount() <= 0.0:
			break
		await get_tree().physics_frame
	# 09 / 10: a real cover piece.
	if not await _place_at_cover():
		_log("no map cover piece accepted; using a visible box (cover_wall) 1.1 m ahead")
		_fallback_wall()
		await _frames(6)
	ok = await _save("09_cover_wall", "09 at a cover wall: Cover highlighted") and ok
	if not _touch.cover_slot_valid:
		_log("CHECK 09: not highlighted")
	var cv: Vector2 = _touch.get_button_rect(_touch.SHOULDER_KEY).get_center()
	await _tap(5, cv)
	for i in 240:
		if _pawn.in_cover() and not _pawn.is_cover_turning():
			break
		await get_tree().physics_frame
	await _frames(30)
	ok = await _save("10_in_cover", "10 in cover after the tap") and ok
	return ok


func _ground_y(x: float, z: float, top: float) -> Variant:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, top - 60.0, z))
	q.exclude = [_pawn.get_rid()]
	var hit := _pawn.get_world_3d().direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else (hit["position"] as Vector3).y


## The pawn 1.1 m in front of a face of the nearest real cover_wall pieces, facing it; the first spot where the pawn
## offers a valid Cover press wins.
func _place_at_cover() -> bool:
	var pieces: Array = []
	for n in get_tree().get_nodes_in_group(&"cover_wall"):
		if not (n is StaticBody3D) or not (n as Node).is_inside_tree():
			continue
		var shape := (n as Node).get_node_or_null("Shape") as CollisionShape3D
		if shape == null or not (shape.shape is BoxShape3D):
			continue
		pieces.append([shape.global_position.distance_to(_pawn.global_position), n, shape])
	pieces.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_log("cover_wall pieces: %d" % pieces.size())
	var home := _pawn.global_position
	var home_yaw := _pawn.rotation.y
	var tried := 0
	for entry in pieces:
		if tried >= 30:
			break
		tried += 1
		var shape: CollisionShape3D = entry[2]
		var b := shape.global_basis
		var sz := (shape.shape as BoxShape3D).size
		var ext := Vector3(
			absf(b.x.x) * sz.x + absf(b.y.x) * sz.y + absf(b.z.x) * sz.z,
			absf(b.x.y) * sz.x + absf(b.y.y) * sz.y + absf(b.z.y) * sz.z,
			absf(b.x.z) * sz.x + absf(b.y.z) * sz.y + absf(b.z.z) * sz.z)
		var c := shape.global_position
		for dir in [Vector3.BACK, Vector3.FORWARD, Vector3.RIGHT, Vector3.LEFT]:
			var half: float = ext.z * 0.5 if dir.z != 0.0 else ext.x * 0.5
			var width: float = ext.x if dir.z != 0.0 else ext.z
			if width < 1.2:
				continue
			var at: Vector3 = c + dir * (half + 1.1)
			var gy: Variant = _ground_y(at.x, at.z, c.y + ext.y * 0.5 + 3.0)
			if gy == null or absf(float(gy) - (c.y - ext.y * 0.5)) > 1.0:
				continue
			_pawn.global_position = Vector3(at.x, float(gy) + 0.05, at.z)
			_pawn.velocity = Vector3.ZERO
			var f: Vector3 = -dir
			_pawn.rotation.y = atan2(-f.x, -f.z)
			_pawn.pitch = -0.05
			await _frames(6)
			if _pawn.cover_button_valid() and _touch.cover_slot_valid:
				_log("cover piece %s (%s) size=%s face %s, pawn at %s, %.0f m from the landing" % [(entry[1] as Node).name,
					(entry[1] as Node).get_parent().name, str(ext.snapped(Vector3.ONE * 0.01)), str(dir), str(_pawn.global_position.snapped(Vector3.ONE * 0.01)),
					home.distance_to(_pawn.global_position)])
				return true
	_pawn.global_position = home
	_pawn.rotation.y = home_yaw
	return false


func _fallback_wall() -> void:
	var body := StaticBody3D.new()
	body.add_to_group(&"cover_wall")
	_pawn.rotation.y = 0.0
	body.position = _pawn.global_position + Vector3.FORWARD * 1.6 + Vector3.UP * 0.55
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 1.1, 1)
	shape.shape = box
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	body.add_child(mi)
	_m.add_child(body)


# --- contact sheets ------------------------------------------------------------------------------------------------

## Labelled sheet: each image scaled to cell_w wide with its caption above, `cols` columns, rendered by a 2D SubViewport.
func _sheet(files: Array, caps: Array, cols: int, cell_w: int, out_path: String) -> void:
	var first := Image.load_from_file(files[0])
	if first == null:
		_failed += 1
		return
	var cell_h := int(round(float(cell_w) * first.get_height() / first.get_width()))
	var cap_h := 40
	var gap := 12
	var rows := int(ceil(files.size() / float(cols)))
	var sv := SubViewport.new()
	sv.disable_3d = true
	sv.transparent_bg = false
	sv.size = Vector2i(cols * (cell_w + gap) + gap, rows * (cell_h + cap_h + gap) + gap)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.size = Vector2(sv.size)
	sv.add_child(bg)
	for i in files.size():
		var img := Image.load_from_file(files[i])
		if img == null:
			continue
		img.resize(cell_w, cell_h, Image.INTERPOLATE_LANCZOS)
		var at := Vector2(gap + (i % cols) * (cell_w + gap), gap + (i / cols) * (cell_h + cap_h + gap))
		var lab := Label.new()
		lab.text = "%s  [%s]" % [caps[i], files[i].get_file()]
		lab.position = at
		lab.add_theme_font_size_override("font_size", 22)
		lab.add_theme_color_override("font_color", Color(1, 1, 0.75))
		sv.add_child(lab)
		var tr := TextureRect.new()
		tr.texture = ImageTexture.create_from_image(img)
		tr.position = at + Vector2(0, cap_h)
		tr.size = Vector2(cell_w, cell_h)
		sv.add_child(tr)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := sv.get_texture().get_image().save_png(out_path)
	print("[h1c_capture] sheet %s %s -> %s" % [out_path, str(sv.size), error_string(err)])
	if err != OK:
		_failed += 1
	sv.queue_free()
