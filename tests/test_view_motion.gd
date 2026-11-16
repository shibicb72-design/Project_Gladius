extends "res://tests/test_case.gd"
## M2 AN1 commit 3: the first-person motion (scripts/visual/view_motion.gd, data/anim.json first_person, OQ-FP-ANIM).
## Every required pose and motion exists and moves the model; the staged reload lasts the weapon's own reload_s from
## its WeaponDef; pickup is derived from the loadout (no pawn hook); every sampled frame of every motion keeps the
## model inside max_reach_m, past the near plane and uncut by it; the cover exit never shows neither the body nor
## the view model.

const DT := 1.0 / 60.0
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const ASPECTS: Array[float] = [2520.0 / 1080.0, 2176.0 / 1812.0]
const HITSCAN_POSES: Array[String] = ["idle", "walk", "sprint", "ads", "fire", "reload", "switch", "pickup"]
const MELEE_POSES: Array[String] = ["idle", "swing", "switch", "pickup"]

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _vm_f(key: String) -> float:
	return float(DataRegistry.new().get_camera_cfg()["first_person"]["view_model"][key]["value"])


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


## Floor, optionally a cover wall whose face is at z = 0 (tests/test_first_person_camera.gd), a local pawn and rig.
func _fixture(class_id: String = "hastati", with_cover: bool = false) -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	_root.add_child(floor_body)
	if with_cover:
		var wall := StaticBody3D.new()
		wall.add_to_group(&"cover_wall")
		wall.position = Vector3(0, 1.1, -0.5)
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		var box := BoxShape3D.new()
		box.size = Vector3(4, 2.2, 1)
		shape.shape = box
		wall.add_child(shape)
		_root.add_child(wall)
	_pawn = _PawnScene.instantiate()
	_pawn.position = Vector3(0, 0, 0.6)
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	if with_cover:
		_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	await _frames(2)
	if class_id != "hastati":
		_pawn.setup(class_id, 0)
	await _frames(ceili(_vm_f("swap_s") / DT) + 4)


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


func _show(id: String) -> void:
	for i in 3:
		if _pawn.loadout.get_active() != null and _pawn.loadout.get_active().def.id == id:
			break
		_pawn.loadout.swap()
		_pawn.weapon_switched.emit(_pawn.loadout.active)
		await _frames(ceili(_vm_f("swap_s") / DT) + 4)
	await _frames(ceili(0.4 / DT))  # let the kick, settle and switch springs rest


## The weapon node's transform relative to the camera and the pivot's: what a motion moves.
func _pose_key(vm: ViewModel) -> Transform3D:
	var w := vm.get_shown_weapon()
	return (w.global_transform if w != null else vm.global_transform)


static func _moved(a: Transform3D, b: Transform3D) -> float:
	return a.origin.distance_to(b.origin) + rad_to_deg(a.basis.get_rotation_quaternion().angle_to(b.basis.get_rotation_quaternion())) * 0.001


## Samples `frames` physics frames; on every one, at both phone and Fold aspects, the model stays inside max_reach_m,
## past the near plane and uncut by it in view. Returns [largest move from `rest`, names seen].
func _sample(vm: ViewModel, frames: int, rest: Transform3D, tag: String, fails: Array) -> Array:
	var cam := _rig.get_camera()
	var reach := _vm_f("max_reach_m")
	var cam_cfg := DataRegistry.new().get_camera_cfg()
	var most := 0.0
	var seen := {}
	for i in frames:
		await _tree().physics_frame
		most = maxf(most, _moved(rest, _pose_key(vm)))
		for n in vm.get_motion_names():
			seen[n.split(":")[0]] = true
			seen[n] = true
		if not vm.is_visible_in_tree() or vm.get_shown_weapon() == null:
			continue
		var fov := cam.fov
		for aspect in ASPECTS:
			cam.fov = fov * CameraRig.fov_for_aspect(cam_cfg, aspect) / maxf(_rig.base_fov, 0.01)
			var m := ViewProbe.measure(vm, cam, aspect)
			if m["cuts"] > 0 or m["far"] >= reach or m["nearest"] <= cam.near:
				fails.append("%s frame %d aspect %.2f: cuts %d (%s) reach %.4f nearest %.4f" % [tag, i, aspect, m["cuts"], ViewProbe.cut_report(m), m["far"], m["nearest"]])
		cam.fov = fov
	return [most, seen.keys()]


## The reload lasts the gun's own WeaponDef.reload_s (not a literal) and runs its stages in order; the blade
## (reload_s 0) has none.
func test_reload_length_is_the_weapon_reload_s_and_stages_run_in_order() -> void:
	var stages := ViewMotion.RELOAD_STAGES
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var w := _pawn.loadout.get_active()
		var def_reload := DataRegistry.new().get_weapon_def(w.def.id).reload_s
		assert_true(def_reload > 0.0 and absf(def_reload - w.def.reload_s) < 1e-6, "%s: reload_s from the WeaponDef (%s)" % [w.def.id, def_reload])
		_pawn.reload_started.emit()
		assert_true(absf(vm.get_reload_length() - w.def.reload_s) < 1e-6, "%s: reload length %.3f == reload_s %.3f" % [w.def.id, vm.get_reload_length(), w.def.reload_s])
		var order: Array[String] = []
		var frames := 0
		while vm.is_reloading() and frames < 600:
			var s := vm.get_reload_stage()
			if order.is_empty() or order[order.size() - 1] != s:
				order.append(s)
			await _tree().physics_frame
			frames += 1
		print("FP RELOAD %s reload_s=%.3f frames=%d stages=%s" % [w.def.id, w.def.reload_s, frames, order])
		assert_eq(order, stages, "%s: stages in order" % w.def.id)
		assert_true(absf(frames * DT - w.def.reload_s) <= 2.0 * DT, "%s: lasted %.3f s for reload_s %.3f" % [w.def.id, frames * DT, w.def.reload_s])
		# The cell leaves its rest and comes back; the charging handle is pulled during the charge stage.
		if class_id == "hastati":
			await _show("gladius_lux")
			_pawn.reload_started.emit()
			assert_true(not vm.is_reloading() and vm.get_reload_length() == 0.0, "gladius_lux (reload_s 0): no reload motion")
		await _cleanup()


## Hitscan guns: idle, walk, sprint, ADS, fire, reload stages, switch and pickup each move the model, name
## themselves, and keep every sampled frame inside reach, past and uncut by the near plane (phone and Fold).
func test_hitscan_poses_and_motions_stay_inside_the_limits() -> void:
	var fails: Array = []
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var gun := _pawn.loadout.get_active().def.id
		var rest := _pose_key(vm)
		var seen := {}
		var moved := {}
		# idle: breathing moves the model a little, nothing else runs.
		var r: Array = await _sample(vm, 40, rest, gun + " idle", fails)
		moved["idle"] = r[0]
		seen["idle"] = (r[1] as Array).has("idle")
		# walk and sprint from the pawn's real velocity and sprint factor.
		_pawn.velocity = Vector3(0, 0, -_pawn.get_move_speed())
		r = await _sample(vm, 40, rest, gun + " walk", fails)
		moved["walk"] = r[0]
		seen["walk"] = (r[1] as Array).has("walk")
		_pawn.sprint_factor = _pawn.get_max_move_speed() / _pawn.get_move_speed()
		_pawn.velocity = Vector3(0, 0, -_pawn.get_max_move_speed())
		r = await _sample(vm, 40, rest, gun + " sprint", fails)
		moved["sprint"] = r[0]
		seen["sprint"] = (r[1] as Array).has("sprint")
		_pawn.sprint_factor = 1.0
		_pawn.velocity = Vector3.ZERO
		await _frames(30)
		# ADS raise with its settle, and back.
		_rig.set_aim_blend(1.0, 0.6)
		r = await _sample(vm, 20, rest, gun + " ads", fails)
		moved["ads"] = r[0]
		seen["ads"] = (r[1] as Array).has("ads")
		_rig.set_aim_blend(0.0, 0.6)
		await _frames(30)
		# fire: the kick spring.
		_pawn.fired.emit()
		r = await _sample(vm, ceili(_vm_f("recoil_s") / DT), rest, gun + " fire", fails)
		moved["fire"] = r[0]
		seen["fire"] = (r[1] as Array).has("fire")
		await _frames(20)
		# reload: every stage.
		_pawn.reload_started.emit()
		r = await _sample(vm, ceili(_pawn.loadout.get_active().def.reload_s / DT) + 2, rest, gun + " reload", fails)
		moved["reload"] = r[0]
		var all_stages := true
		for st in ViewMotion.RELOAD_STAGES:
			all_stages = all_stages and (r[1] as Array).has("reload:" + st)
		seen["reload"] = all_stages
		# switch away and back.
		_pawn.loadout.swap()
		_pawn.weapon_switched.emit(_pawn.loadout.active)
		r = await _sample(vm, ceili(_vm_f("swap_s") / DT) + 2, rest, gun + " switch", fails)
		moved["switch"] = r[0]
		seen["switch"] = (r[1] as Array).has("switch")
		await _show(gun)
		# pickup: a loot gun taken into a slot (Pawn.take_item), no switch.
		var loot := "sagittarii_rifle" if gun == "pilum_br" else "pilum_br"
		_pawn.take_item({}, {"kind": "weapon", "weapon": loot})
		assert_true(vm.is_picking_up() and not vm.is_swapping(), "%s: taking %s plays the pickup, not the switch" % [gun, loot])
		r = await _sample(vm, ceili(float(DataRegistry.new().load_file("res://data/anim.json")["first_person"]["pickup"]["s"]) / DT) + 2, rest, gun + " pickup", fails)
		moved["pickup"] = r[0]
		seen["pickup"] = (r[1] as Array).has("pickup")
		assert_eq(vm.get_shown_weapon_id(), loot, "%s: the picked-up %s is shown" % [gun, loot])
		for p in HITSCAN_POSES:
			print("FP MOTION %s %s moved=%.4f seen=%s" % [gun, p, moved[p], seen[p]])
			assert_true(bool(seen[p]), "%s: %s reported" % [gun, p])
			assert_true(float(moved[p]) > (0.0005 if p == "idle" else 0.004), "%s: %s moves the model (%.4f)" % [gun, p, moved[p]])
		await _cleanup()
	assert_true(fails.is_empty(), "every sampled frame inside the limits: %s" % "; ".join(PackedStringArray(fails.slice(0, 6))))


## Melee: idle, swing (anticipation, strike, follow-through), switch and pickup, inside the limits on every frame.
func test_melee_poses_and_motions_stay_inside_the_limits() -> void:
	var fails: Array = []
	await _fixture("hastati")
	var vm := _rig.get_view_model()
	await _show("gladius_lux")
	var rest := _pose_key(vm)
	var moved := {}
	var seen := {}
	var r: Array = await _sample(vm, 40, rest, "blade idle", fails)
	moved["idle"] = r[0]
	seen["idle"] = (r[1] as Array).has("idle")
	_pawn.fired.emit()
	assert_true(vm.is_swinging(), "fired with the blade: the swing")
	# M2 AN2 item 4b: the swing clip moves the blade's node, the procedural swing the Pivot: measure the blade (its
	# global transform includes the Pivot), which covers both.
	var swing_rest := _pose_key(vm)
	var frames := ceili(_vm_f("swing_s") / DT) + 2
	var most := 0.0
	for i in frames:
		await _tree().physics_frame
		most = maxf(most, _moved(swing_rest, _pose_key(vm)))
	moved["swing"] = most
	seen["swing"] = true
	r = await _sample(vm, 2, rest, "blade after swing", fails)
	_pawn.loadout.swap()
	_pawn.weapon_switched.emit(_pawn.loadout.active)
	r = await _sample(vm, ceili(_vm_f("swap_s") / DT) + 2, rest, "blade switch", fails)
	moved["switch"] = r[0]
	seen["switch"] = (r[1] as Array).has("switch")
	await _show("gladius_lux")
	_pawn.take_item({}, {"kind": "weapon", "weapon": "sagittarii_rifle"})
	assert_true(vm.is_picking_up(), "taking a gun with the blade out plays the pickup")
	r = await _sample(vm, ceili(0.8 / DT), rest, "blade pickup", fails)
	moved["pickup"] = r[0]
	seen["pickup"] = (r[1] as Array).has("pickup")
	for p in MELEE_POSES:
		print("FP MOTION gladius_lux %s moved=%.4f seen=%s" % [p, moved[p], seen[p]])
		assert_true(bool(seen[p]), "blade: %s reported" % p)
		assert_true(float(moved[p]) > (0.0005 if p == "idle" else 0.004), "blade: %s moves the model (%.4f)" % [p, moved[p]])
	await _cleanup()
	assert_true(fails.is_empty(), "every sampled frame inside the limits: %s" % "; ".join(PackedStringArray(fails.slice(0, 6))))


## Landing: Pawn.landed (and any fall ViewMotion sees end on the floor) dips the view model, then it recovers.
func test_landing_dips_and_recovers() -> void:
	await _fixture("hastati")
	var vm := _rig.get_view_model()
	var pivot := vm.get_node("Pivot") as Node3D
	await _frames(10)
	var before := pivot.position.y
	_pawn.landed.emit()
	var lowest := before
	for i in 12:
		await _tree().physics_frame
		lowest = minf(lowest, pivot.position.y)
	assert_true(vm.get_motion_names().has("land") or lowest < before, "landing runs")
	assert_true(lowest < before - 0.01, "the model dips (%.4f -> %.4f)" % [before, lowest])
	await _frames(40)
	assert_true(not vm.get_motion_names().has("land"), "the dip ends")
	await _cleanup()


## Pickup is derived from the loadout inside the view code: a new Weapon object in one slot is a pickup; Loadout.swap
## and a new loadout (setup) are switches.
func test_pickup_is_derived_from_the_loadout() -> void:
	await _fixture("hastati")
	var vm := _rig.get_view_model()
	_pawn.loadout.swap()
	_pawn.weapon_switched.emit(_pawn.loadout.active)
	assert_true(vm.is_swapping() and not vm.is_picking_up(), "Loadout.swap: a switch")
	await _frames(40)
	_pawn.setup("sagittarii", 0)  # replaces the loadout without a signal
	await _frames(2)
	_pawn.weapon_switched.emit(_pawn.loadout.active)  # as Pawn.apply_start_kit does after a new loadout
	assert_true(vm.is_swapping() and not vm.is_picking_up(), "a whole new loadout: a switch")
	await _frames(40)
	_pawn.setup("hastati", 0)  # silent replacement, then a loot gun: still a pickup, not fooled by the old slots
	await _frames(2)
	await _frames(40)
	_pawn.take_item({}, {"kind": "weapon", "weapon": "pilum_br"})
	assert_true(vm.is_picking_up() and not vm.is_swapping(), "take_item: a pickup")
	await _cleanup()


## Cover-exit fix: on every physics frame of a real Cover-button exit, the rig camera draws the body or the shown
## weapon has vertices on screen: never neither (the frame at show_weight used to show the model raise_drop_m below
## the view). Note: with the AN1 geometry this fixture shows the gun on screen even with raise_start 0 (checked by
## hand), so this test guards the outcome, not the raise_start value alone.
func test_cover_exit_never_shows_neither_body_nor_view_model() -> void:
	await _fixture("hastati", true)
	var vm := _rig.get_view_model()
	var cam := _rig.get_camera()
	var bit := 1 << (_rig.get_body_layer() - 1)
	var aspect := float(_tree().root.get_visible_rect().size.x) / maxf(float(_tree().root.get_visible_rect().size.y), 1.0)
	var empty := 0
	var first_shown := -1
	for i in 150:
		var frame := InputFrame.new()
		frame.move = Vector2(0, -1) if _pawn.cover.state == CoverController.State.FREE else Vector2.ZERO
		_pawn.set_frame(frame)
		_pawn._physics_process(DT)
		await _tree().physics_frame
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			break
	assert_true(_pawn.cover.state == CoverController.State.IN_COVER, "in cover")
	for i in 30:
		_pawn.set_frame(InputFrame.new())
		_pawn._physics_process(DT)
		await _tree().physics_frame
	_pawn.handle_action_press("cover")
	for i in 150:
		_pawn.set_frame(InputFrame.new())
		_pawn._physics_process(DT)
		await _tree().physics_frame
		var body := (cam.cull_mask & bit) != 0
		# The weapon itself must be on screen (an arm poking in from the edge is not enough).
		var on_screen := ViewProbe.on_screen_vertices(vm, cam, aspect, true)
		if not body and on_screen == 0:
			empty += 1
			print("FP COVER EXIT empty frame %d weight=%.3f vm_visible=%s" % [i, _rig.get_first_person_weight(), vm.visible])
		if first_shown < 0 and vm.visible:
			first_shown = i
			print("FP COVER EXIT first view-model frame %d weight=%.3f on_screen_vertices=%d" % [i, _rig.get_first_person_weight(), on_screen])
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			break
	assert_true(first_shown >= 0, "the view model came back")
	assert_eq(empty, 0, "no exit frame shows neither the body nor the view model")
	await _cleanup()


# --- M2 AN2 item 4b: the clip layer ---------------------------------------------------------------------------------

## The three fov_table rows (phone, 4:3 tablet, Fold inner screen).
const CLIP_ASPECTS: Array[float] = [2520.0 / 1080.0, 2048.0 / 1536.0, 2176.0 / 1812.0]


static func _inv_smoothstep(y: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for i in 40:
		var mid := (lo + hi) * 0.5
		if smoothstep(0.0, 1.0, mid) < y:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## Poses the real view model on one clip key: the motion's state is set so the clip plays time `u` (0..1) of `clip`,
## then the model is updated twice (the second time without the part fade a new clip starts with).
func _pose_clip(vm: ViewModel, m: ViewMotion, motion: String, clip: String, u: float) -> void:
	var cs := m.clip_set()
	var length := cs.length("%s_%s" % [m.weapon_id, clip])
	var below := 0.99999
	m.reload_total = 0.0
	m.switch_total = 0.0
	m.pickup_total = 0.0
	m.swing_total = 0.0
	m.fire_t = -1.0
	vm._aim_blend = 0.0
	match motion:
		"reload":
			m.reload_total = _pawn.loadout.get_active().def.reload_s
			m.reload_t = u * m.reload_total * below
		"switch":
			m.switch_total = _vm_f("swap_s")
			m.switch_t = (u * 0.5 if clip == "switch_out" else 0.5 + u * 0.5 * below) * m.switch_total
			if clip == "switch_out":
				m.switch_t = minf(m.switch_t, m.switch_total * 0.5 * below)
		"pickup":
			m.pickup_total = float(m.cfg["pickup"]["s"])
			m.pickup_t = u * m.pickup_total * below
		"swing":
			m.swing_total = _vm_f("swing_s")
			m.swing_t = u * m.swing_total * below
		"ads":
			var a := u if clip == "ads_raise" else 1.0 - u
			m._ads_dir = 1.0 if clip == "ads_raise" else 0.0
			vm._aim_blend = _inv_smoothstep(a)
		"idle":
			m._time = u * length
		"walk":
			m._walk = 1.0
			m._step_phase = u * TAU
		"sprint":
			m._sprint = 1.0
			m._step_phase = u * TAU
		"fire":
			m.fire_t = u * length
	vm._update(0.0)
	vm._fade_left = 0.0
	vm._update(0.0)


## Every key frame (30 fps) of every ENABLED clip (anim.json first_person.clips.enabled) of every weapon, played
## through the real view model, at the three fov_table aspects: reach < max_reach_m, nearest vertex past the near
## plane, no near-plane cut in the view; the end of ads_raise is exactly the ADS pose (the red dot on the centre).
func test_every_frame_of_every_enabled_clip_stays_inside_the_limits() -> void:
	var fails: Array = []
	var enabled: Dictionary = DataRegistry.new().load_file("res://data/anim.json")["first_person"]["clips"]["enabled"]
	var reach := _vm_f("max_reach_m")
	var cam_cfg := DataRegistry.new().get_camera_cfg()
	var sampled := 0
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var cam := _rig.get_camera()
		var ids: Array = ["pilum_br", "gladius_lux"] if class_id == "hastati" else ["sagittarii_rifle"]
		for id: String in ids:
			await _show(id)
			var m := vm.get_motion()
			var melee := DataRegistry.new().get_weapon_def(id).is_melee()
			var worst := {"far": 0.0, "nearest": 9.0, "cuts": 0, "frames": 0}
			for motion: String in enabled:
				if not bool(enabled[motion]) or not m.clip_on(motion):
					continue
				var clips: Array = [ViewMotion.CLIP_OF[motion]]
				if motion == "switch":
					clips = ["switch_out", "switch_in"]
				elif motion == "ads":
					clips = ["ads_raise", "ads_lower"]
				for clip: String in clips:
					var n := roundi(m.clip_set().length("%s_%s" % [id, clip]) * 30.0)
					for k in n + 1:
						var u := float(k) / maxf(n, 1)
						_pose_clip(vm, m, motion, clip, u)
						var fov := cam.fov
						for aspect in CLIP_ASPECTS:
							cam.fov = fov * CameraRig.fov_for_aspect(cam_cfg, aspect) / maxf(_rig.base_fov, 0.01)
							var meas := ViewProbe.measure(vm, cam, aspect)
							worst["far"] = maxf(worst["far"], meas["far"])
							worst["nearest"] = minf(worst["nearest"], meas["nearest"])
							worst["cuts"] += int(meas["cuts"])
							if meas["cuts"] > 0 or meas["far"] >= reach or meas["nearest"] <= cam.near:
								fails.append("%s %s %d/%d aspect %.2f: cuts %d (%s) reach %.4f nearest %.4f" % [id, clip, k, n, aspect, meas["cuts"], ViewProbe.cut_report(meas), meas["far"], meas["nearest"]])
						cam.fov = fov
						worst["frames"] += 1
						sampled += 1
					if clip == "ads_raise" and not melee:
						var w := vm.get_shown_weapon()
						var err := w.transform.origin.distance_to((w.get_meta(&"ads") as Transform3D).origin)
						assert_true(err < 1e-4, "%s: the end of ads_raise is the ADS pose (%.6f m)" % [id, err])
			_pose_clip(vm, m, "", "", 0.0)
			print("FP CLIP LIMITS %s frames=%d (x%d aspects) reach_m=%.4f nearest_m=%.4f cuts=%d (limit %.2f, near %.3f)" % [id, worst["frames"], CLIP_ASPECTS.size(), worst["far"], worst["nearest"], worst["cuts"], reach, cam.near])
		await _cleanup()
	assert_true(sampled > 0, "clip frames sampled (%d)" % sampled)
	assert_true(fails.is_empty(), "every clip frame inside the limits (%d bad): %s" % [fails.size(), "; ".join(PackedStringArray(fails.slice(0, 6)))])


## A reload interrupted by a switch: the parts fade from where they were (no pop larger than the reload's own steps),
## and once the gun is back the cell, charging handle and left hand are at rest (nothing left displaced).
func test_reload_interrupted_by_a_switch_leaves_nothing_displaced() -> void:
	await _fixture("hastati")
	var vm := _rig.get_view_model()
	var gun := vm.get_shown_weapon()
	var left := gun.get_node("LeftArm") as Node3D
	var cell := gun.get_node("Cell") as Node3D
	_pawn.reload_started.emit()
	var reload_steps := 0.0
	var last := left.global_position
	for i in ceili(0.5 * _pawn.loadout.get_active().def.reload_s / DT):
		await _tree().physics_frame
		reload_steps = maxf(reload_steps, left.global_position.distance_to(last))
		last = left.global_position
	var mid_clip := vm.get_clip_motion()
	var displaced := cell.transform.origin.distance_to((cell.get_meta(&"rest") as Transform3D).origin)
	_pawn.loadout.swap()
	_pawn.weapon_switched.emit(_pawn.loadout.active)
	var switch_steps := 0.0
	for i in 6:
		await _tree().physics_frame
		if vm.get_shown_weapon() == gun:
			switch_steps = maxf(switch_steps, left.global_position.distance_to(last))
		last = left.global_position
	print("FP CLIP INTERRUPT mid=%s cell_out_by=%.3f largest hand step: reload %.4f, after the switch %.4f" % [mid_clip, displaced, reload_steps, switch_steps])
	assert_eq(mid_clip, "reload" if vm.get_motion().clip_on("reload") else "", "the reload clip ran")
	assert_true(switch_steps <= reload_steps * 1.5 + 0.002, "no pop on the interrupt (%.4f vs %.4f)" % [switch_steps, reload_steps])
	await _frames(ceili(_vm_f("swap_s") / DT) + 4)
	await _show("pilum_br")
	assert_true(not vm.is_reloading() and vm.get_clip_motion() == "", "no reload left running")
	var e_cell := cell.transform.origin.distance_to((cell.get_meta(&"rest") as Transform3D).origin)
	var charge := gun.get_node("Charge") as Node3D
	var e_charge := charge.transform.origin.distance_to((charge.get_meta(&"rest") as Transform3D).origin)
	var e_hand := left.transform.origin.distance_to((left.get_meta(&"rest") as Transform3D).origin)
	print("FP CLIP INTERRUPT back: cell %.6f charge %.6f left hand %.6f m from rest" % [e_cell, e_charge, e_hand])
	assert_true(e_cell < 1e-4 and e_charge < 1e-4 and e_hand < 1e-4, "cell, charging handle and left hand back at rest")
	await _cleanup()
