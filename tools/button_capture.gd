extends Node
## Desktop-render proof of the action-button feedback (GBTN). Run windowed (needs a display):
##   godot --path . res://tools/button_capture.tscn -- --out=build/shots
## Each shot renders the match with the touch HUD inside a SubViewport of the Fold size (2520x1080 cover,
## 2176x1812 inner; landscape only, OQ-PORTRAIT), taps the button through push_input and saves a PNG.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _TouchHud := preload("res://scripts/ui/touch_hud.gd")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

## [action, viewport size, file name]
const SHOTS: Array = [
	["fire", Vector2i(2520, 1080), "buttons_fire_cover_landscape"],
	["fire", Vector2i(2176, 1812), "buttons_fire_inner_landscape"],
	["reload", Vector2i(2176, 1812), "buttons_reload_inner_landscape"],
	["aim", Vector2i(2520, 1080), "buttons_aim_cover_landscape"],
	["swap_weapon", Vector2i(2176, 1812), "buttons_swap_inner_landscape"],
	["fire_far", Vector2i(2520, 1080), "buttons_fire_far_cover_landscape"],
	["fire_far", Vector2i(2176, 1812), "buttons_fire_far_inner_landscape"],
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


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _run() -> void:
	var failed := 0
	for spec in SHOTS:
		if not await _one(spec[0], spec[1], spec[2]):
			failed += 1
	get_tree().quit(1 if failed > 0 else 0)


func _tap(svp: SubViewport, touch: Control, action: String, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 1
	e.position = touch.get_button_rect(action).get_center()
	e.pressed = pressed
	svp.push_input(e, true)


func _save(svp: SubViewport, name: String) -> bool:
	await RenderingServer.frame_post_draw
	var err := svp.get_texture().get_image().save_png(_out.path_join("%s.png" % name))
	print("[button_capture] %s -> %s" % [name, error_string(err)])
	return err == OK


## Prints the on-screen pixel length of the tracer (Camera3D.unproject_position of both endpoints).
func _measure(svp: SubViewport, pawn: Pawn, name: String) -> bool:
	var cam := svp.get_camera_3d()
	var ep := pawn.shot_fx.get_tracer_endpoints()
	var a := cam.unproject_position(ep[0])
	var b := cam.unproject_position(ep[1])
	print("[button_capture] MEASURE %s fov=%.1f world_a=%s world_b=%s px_a=%s px_b=%s len_px=%.1f" % [name,
			cam.fov, ep[0], ep[1], a, b, a.distance_to(b)])
	return true


## Puts a target pawn straight ahead of the player at data/ui.json capture.far_target_distance_m, so the
## shot's hit point is far away (no fallback: a missing key is a loud error).
func _place_far_target(m: MatchRoot, pawn: Pawn) -> void:
	var dist := float(DataRegistry.new().load_file("res://data/ui.json")["capture"]["far_target_distance_m"])
	var target: Pawn = _PawnScene.instantiate()
	target.squad_id = 1
	m.add_child(target)
	target.set_physics_process(false)
	# The hill blocks the spawn-to-hill line, so aim along the chord to the neighbouring spawn spot.
	var from := pawn.global_position
	from.y = 0.0
	var chord := (from.rotated(Vector3.UP, PI / 3.0) - from).normalized()
	target.global_position = pawn.global_position + chord * dist
	pawn.rotation.y = atan2(-chord.x, -chord.z)
	pawn.pitch = 0.0


func _one(action: String, size: Vector2i, name: String) -> bool:
	_TouchHud.move_stick_override = "custom"
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
	m.begin()
	await _frames(25)
	var touch: Control = m.get_node("Hud/TouchHud")
	touch.cfg["force_touch_hud"] = true
	touch.refresh_visibility()
	await _frames(3)
	var pawn: Pawn = m.local_player
	var ok := false
	match action:
		"fire", "fire_far":
			if action == "fire_far":
				_place_far_target(m, pawn)
				await _frames(3)
			_tap(svp, touch, "fire", true)
			# Capture on a frame that really draws the tracer (it only lives ~0.08 s).
			for i in 120:
				await RenderingServer.frame_post_draw
				if pawn.shot_fx.is_tracer_visible() and _measure(svp, pawn, name):
					ok = await _save(svp, name)
					break
			_tap(svp, touch, "fire", false)
		"reload":
			_tap(svp, touch, "fire", true)
			await _frames(2)
			_tap(svp, touch, "fire", false)
			await _frames(15)
			_tap(svp, touch, "reload", true)
			await _frames(8)
			ok = pawn.loadout.get_active().reloading and await _save(svp, name)
			_tap(svp, touch, "reload", false)
		"aim":
			_tap(svp, touch, "aim", true)
			await _frames(40)
			ok = pawn.aiming and await _save(svp, name)
			_tap(svp, touch, "aim", false)
		"swap_weapon":
			_tap(svp, touch, "swap_weapon", true)
			await _frames(6)
			ok = await _save(svp, name)
			_tap(svp, touch, "swap_weapon", false)
	svp.queue_free()
	await _frames(2)
	return ok
