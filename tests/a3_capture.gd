extends SceneTree
## A3 in-game proof pictures (NOT collected by tests/run_tests.gd: no test_ prefix). Windowed, ONE process:
##   godot.cmd --path . --resolution 800x600 --script res://tests/a3_capture.gd -- --out=<dir> [--only=<subject,...>]
## Subjects: downed, death, crouch, grip, headgear, slash, hit, victory. Each builds a flat floor (0.5 m grid, sun with
## shadows) in an own-world SubViewport and REAL pawns (scenes/player/pawn.tscn) driven the way the A3 tests drive them
## (physics off, model/tree/skeleton advanced by hand at 60 Hz). Both armour sets (pawn meta "armour_set"). Presentation
## only: nothing here changes game code or data.

const SIZE := Vector2i(640, 480)
const DT := 1.0 / 60.0
const SETS: Array[String] = ["legionary", "murmillo"]
const MELEE := "gladius_lux"

var _out := "build/a3/shots_game"
var _only: Array[String] = []
var _svp: SubViewport
var _floor: Node3D
var _cam: Camera3D
var _stage: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			for s in a.substr(7).split(","):
				_only.append(s)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _want(subject: String) -> bool:
	return _only.is_empty() or _only.has(subject)


func _run() -> void:
	for set_id in SETS:
		if _want("downed"):
			await _downed(set_id)
		if _want("death"):
			await _death(set_id)
		if _want("grip"):
			await _grip(set_id)
		if _want("slash"):
			await _slash(set_id)
		if _want("hit"):
			await _hit(set_id)
		if _want("victory"):
			await _victory(set_id)
	if _want("crouch"):
		await _crouch("murmillo")
	if _want("headgear"):
		await _headgear("murmillo")
	print("A3_CAPTURE done out=%s renderer=%s" % [_out, RenderingServer.get_current_rendering_method()])
	quit(0)


# ---- stage -----------------------------------------------------------------------------------------------------

func _begin() -> void:
	_svp = SubViewport.new()
	_svp.size = SIZE
	_svp.own_world_3d = true
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_svp.msaa_3d = Viewport.MSAA_4X
	root.add_child(_svp)
	_stage = Node3D.new()
	_svp.add_child(_stage)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.72)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	_svp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	_svp.add_child(sun)
	_floor = Node3D.new()
	_svp.add_child(_floor)
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	plane.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.5, 0.46, 0.4)
	fm.roughness = 1.0
	plane.material_override = fm
	_floor.add_child(plane)
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.2, 0.18, 0.15)
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(-12, 13):
		for horizontal in [true, false]:
			var line := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(30.0, 0.004, 0.012) if horizontal else Vector3(0.012, 0.004, 30.0)
			line.mesh = bm
			line.material_override = lm
			line.position = Vector3(0, 0.003, i * 0.5) if horizontal else Vector3(i * 0.5, 0.003, 0)
			_floor.add_child(line)
	_cam = Camera3D.new()
	_svp.add_child(_cam)
	_cam.current = true


func _end() -> void:
	_svp.queue_free()
	await process_frame


func _pawn(set_id: String, weapon_id: String = "") -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.set_meta("armour_set", set_id)
	_stage.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	if weapon_id != "":
		pawn.loadout.slots[pawn.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def(weapon_id))
	return pawn


func _model(pawn: Pawn) -> SoldierModel:
	return pawn.get_node("SoldierModel") as SoldierModel


func _tick(pawn: Pawn, velocity: Vector3 = Vector3.ZERO) -> void:
	var model := _model(pawn)
	pawn.velocity = velocity
	pawn.global_position += velocity * DT
	model._process(DT)
	model.animation_tree.advance(DT)
	model.skeleton.advance(DT)
	await process_frame


func _ticks(pawn: Pawn, n: int, velocity: Vector3 = Vector3.ZERO) -> void:
	for i in n:
		await _tick(pawn, velocity)


## One picture from `offset` (world axes; the pawn faces -Z, its right is +X) looking at `target`.
func _snap(target: Vector3, offset: Vector3, fov: float = 30.0) -> Image:
	_cam.fov = fov
	_cam.look_at_from_position(target + offset, target)
	_floor.position = Vector3(snappedf(target.x, 1.0), 0, snappedf(target.z, 1.0))
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _svp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _bone(model: SoldierModel, bone: String) -> Vector3:
	return model.skeleton.global_transform * model.pose_cache[model.skeleton.find_bone(bone)].origin


func _save(name: String, tiles: Array, cols: int, tile: Vector2i = SIZE) -> void:
	var rows := ceili(float(tiles.size()) / cols)
	var sheet := Image.create(tile.x * cols, tile.y * rows, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.1, 0.1, 0.1))
	for i in tiles.size():
		var img: Image = (tiles[i] as Image).duplicate()
		if tile != SIZE:
			img.resize(tile.x, tile.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, tile), Vector2i((i % cols) * tile.x, (i / cols) * tile.y))
	var path := _out.path_join(name + ".png")
	print("A3_CAPTURE file=%s tiles=%d err=%d size=%s" % [path, tiles.size(), sheet.save_png(path), sheet.get_size()])


# ---- subjects --------------------------------------------------------------------------------------------------

## downed_<set>_side / _tq: still, then four crawl samples 0.2 s apart (a stride is about 0.7 s).
func _downed(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	var pct := float(DataRegistry.new().load_file("res://data/br.json")["downed"]["downed_move_speed_pct"])
	pawn.downed_move_speed_pct = pct
	pawn.life = Pawn.Life.DOWNED
	var crawl := Vector3.FORWARD * pawn.get_move_speed() * pct / 100.0
	await _ticks(pawn, 70)
	var side: Array = []
	var tq: Array = []
	var focus := func() -> Vector3: return pawn.global_position + Vector3(0, 0.5, 0)
	side.append(await _snap(focus.call(), Vector3(3.8, 0.2, 0)))
	tq.append(await _snap(focus.call(), Vector3(2.7, 1.1, -2.7)))
	await _ticks(pawn, 70, crawl)
	for k in 4:
		await _ticks(pawn, 12, crawl)
		side.append(await _snap(focus.call(), Vector3(3.8, 0.2, 0)))
		tq.append(await _snap(focus.call(), Vector3(2.7, 1.1, -2.7)))
	_save("downed_%s_side" % set_id, side, 3)
	_save("downed_%s_tq" % set_id, tq, 3)
	await _end()


## death_<set>_side (ground level, t = 0.5 / 1.0 / 1.5 s and settled) and death_<set>_tq (settled: 3/4, other side, from above).
func _death(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	await _ticks(pawn, 60)
	var model := _model(pawn)
	var corpse := model.make_corpse()
	var player := corpse.get_node("Collapse") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_stage.add_child(corpse)
	corpse.global_transform = pawn.global_transform
	pawn.free()  # as DeathFx: the living pawn is gone, only the corpse remains
	var length := player.get_animation(&"collapse").length
	var focus := Vector3(0, 0.4, 0.5)
	var side: Array = []
	for t in [0.5, 1.0, 1.5, length + 1.0]:
		player.seek(t, true)
		side.append(await _snap(focus, Vector3(5.0, 0.25, 0), 30.0))
	var tq: Array = [await _snap(focus, Vector3(3.2, 2.0, -3.2)), await _snap(focus, Vector3(-3.2, 2.0, 3.2)), await _snap(focus, Vector3(0.01, 5.0, 0.01), 28.0)]
	# Close-ups of the settled pose: the feet (ground level, from the side and the front-left), the hips and the hands.
	var rig := corpse.get_node("Skeleton3D") as Skeleton3D
	var at := func(bone: String) -> Vector3: return rig.global_transform * rig.get_bone_global_pose(rig.find_bone(bone)).origin
	var feet: Vector3 = (at.call("LeftFoot") + at.call("RightFoot")) * 0.5
	var hips: Vector3 = at.call("Hips")
	var hands: Vector3 = (at.call("LeftHand") + at.call("RightHand")) * 0.5
	var close: Array = [await _snap(feet, Vector3(2.2, 0.1, 0), 16.0), await _snap(feet, Vector3(-1.6, 0.5, 1.6), 16.0),
		await _snap(hips, Vector3(2.2, 0.1, 0), 16.0), await _snap(hands, Vector3(2.2, 0.1, 0), 16.0)]
	_save("death_%s_close" % set_id, close, 2)
	print("A3_CAPTURE death set=%s collapse_s=%.2f feet=%s hips=%s hands=%s" % [set_id, length, feet, hips, hands])
	_save("death_%s_side" % set_id, side, 2)
	_save("death_%s_tq" % set_id, tq, 3)
	await _end()


## crouch_run_<set>: crouched walk, then the crouch released while the stick goes to a run; right side camera.
func _crouch(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	var registry := DataRegistry.new()
	var crouch: Dictionary = registry.get_movement_cfg()["crouch"]
	var blend := maxi(1, ceili(float(crouch["blend_s"]) * 60.0))
	var run := pawn.get_move_speed()
	var slow := run * float(crouch["speed_multiplier"])
	await _ticks(pawn, 20)
	for i in range(1, blend + 1):
		pawn.free_crouch_amount = float(i) / blend
		pawn._apply_body_shapes()
		await _tick(pawn, Vector3.FORWARD * slow * float(i) / blend)
	await _ticks(pawn, 45, Vector3.FORWARD * slow)
	var tiles: Array = []
	var focus := func() -> Vector3: return pawn.global_position + Vector3(0, 0.9, 0)
	tiles.append(await _snap(focus.call(), Vector3(3.6, 0.1, 0), 32.0))
	var n := blend + 18
	for f in range(1, n + 1):
		var amount := clampf(1.0 - float(f) / blend, 0.0, 1.0)
		pawn.free_crouch_amount = amount
		pawn._apply_body_shapes()
		await _tick(pawn, Vector3.FORWARD * lerpf(run, slow, amount))
		if f % 3 == 0 and tiles.size() < 8:
			tiles.append(await _snap(focus.call(), Vector3(3.6, 0.1, 0), 32.0))
	print("A3_CAPTURE crouch blend_frames=%d run=%.2f slow=%.2f tiles=%d" % [blend, run, slow, tiles.size()])
	_save("crouch_run_%s" % set_id, tiles, 4)
	await _end()


## grip_<set>: the left hand on the foregrip, aiming (default weapon): left-front close, left side, from above/left, front.
func _grip(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	await _ticks(pawn, 60)
	var model := _model(pawn)
	var hand := _bone(model, "LeftHand")
	print("A3_CAPTURE grip set=%s weapon=%s left_hand=%s" % [set_id, pawn.loadout.get_active().def.id, hand])
	var tiles: Array = [
		await _snap(hand, Vector3(-0.8, 0.25, -0.8), 22.0),
		await _snap(hand, Vector3(-1.1, 0.1, 0.0), 22.0),
		await _snap(hand, Vector3(-0.4, 0.9, -0.2), 22.0),
		await _snap(hand, Vector3(0.0, 0.15, -1.1), 22.0)]
	# The same two close views with the Sagittarii rifle (the other long gun).
	pawn.loadout.slots[pawn.loadout.active] = Weapon.new(DataRegistry.new().get_weapon_def("sagittarii_rifle"))
	await _ticks(pawn, 40)
	hand = _bone(model, "LeftHand")
	tiles.append(await _snap(hand, Vector3(-0.8, 0.25, -0.8), 22.0))
	tiles.append(await _snap(hand, Vector3(-1.1, 0.1, 0.0), 22.0))
	_save("grip_%s" % set_id, tiles, 2)
	await _end()


## helmet_<set> (3/4 right, front, 3/4 left) and boots_<set> (3/4, side): near LOD close-ups.
func _headgear(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	await _ticks(pawn, 60)
	var model := _model(pawn)
	var head := _bone(model, "Head") + Vector3(0, 0.1, 0)
	_save("helmet_%s" % set_id, [await _snap(head, Vector3(1.3, 0.15, -1.3), 18.0), await _snap(head, Vector3(0, 0.1, -1.9), 18.0),
		await _snap(head, Vector3(-1.3, 0.15, -1.3), 18.0)], 3)
	var feet := (_bone(model, "LeftFoot") + _bone(model, "RightFoot")) * 0.5
	_save("boots_%s" % set_id, [await _snap(feet, Vector3(1.4, 0.45, -1.4), 18.0), await _snap(feet, Vector3(1.8, 0.2, 0.0), 18.0)], 2)
	await _end()


## strip_slash_<set>: two consecutive melee swings (blade_swing_a then _b), 5 samples each.
func _slash(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id, MELEE)
	var model := _model(pawn)
	await _ticks(pawn, 60)
	var tiles: Array = []
	var slots: Array = []
	var focus := Vector3(0, 1.05, 0)
	for swing in 2:
		pawn.shot.emit(pawn.get_muzzle_position(), pawn.get_aim_direction(), MELEE)
		slots.append(model.pose.swing_slot)
		var done := 0
		for target in [2, 6, 10, 14, 19]:
			await _ticks(pawn, target - done)
			done = target
			tiles.append(await _snap(focus, Vector3(2.4, 0.5, -2.4), 34.0))
		var guard := 0
		while model.pose.swing_left_s > 0.0 and guard < 120:
			await _tick(pawn)
			guard += 1
		await _ticks(pawn, 6)
	print("A3_CAPTURE slash set=%s slots=%s" % [set_id, slots])
	_save("strip_slash_%s" % set_id, tiles, 5, Vector2i(480, 360))
	await _end()


## strip_hit_<side>_<set>: the four directional flinches, 8 samples each.
func _hit(set_id: String) -> void:
	for side in ["front", "back", "left", "right"]:
		await _begin()
		var pawn := _pawn(set_id)
		var model := _model(pawn)
		await _ticks(pawn, 50)
		model.flinch(false, side)
		var tiles: Array = []
		var done := 0
		for target in [2, 5, 8, 11, 14, 18, 24, 32]:
			await _ticks(pawn, target - done)
			done = target
			tiles.append(await _snap(Vector3(0, 1.05, 0), Vector3(2.4, 0.5, -2.4), 34.0))
		_save("strip_hit_%s_%s" % [side, set_id], tiles, 4, Vector2i(480, 360))
		await _end()


## strip_victory_<set>: the cheer (2.4 s), 10 samples.
func _victory(set_id: String) -> void:
	await _begin()
	var pawn := _pawn(set_id)
	var model := _model(pawn)
	await _ticks(pawn, 50)
	var started := model.play_victory(pawn.squad_id)
	var tiles: Array = []
	var done := 0
	for k in 10:
		var target := 8 + k * 15
		await _ticks(pawn, target - done)
		done = target
		tiles.append(await _snap(Vector3(0, 1.1, 0), Vector3(2.0, 0.5, -2.6), 36.0))
	print("A3_CAPTURE victory set=%s started=%s" % [set_id, started])
	_save("strip_victory_%s" % set_id, tiles, 5, Vector2i(480, 360))
	await _end()
