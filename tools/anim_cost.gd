extends SceneTree
## M2 AN2: desktop CPU cost of third-person animation for 18 soldiers (a PROXY on this PC, not a phone number):
##   godot.cmd --path . --script res://tools/anim_cost.gd [-- --frames=600 --block=100 --warmup=180]
## Builds 18 REAL pawns (scenes/player/pawn.tscn, as tools/soldier_capture.gd does: the pawn's own physics step off, the
## tool forces the read-only state the visuals read) on a flat stage in view of one camera: 6 idle (aiming pitch), 6
## jogging, 3 sprinting, 2 in cover (a CoverController forced IN_COVER, if the pawn has enable_cover) and 1 downed.
## Each pawn keeps its SoldierModel, AnimationTree, SoldierGait / SoldierPose / SoldierCrawl / HandSync modifiers and
## the left-arm TwoBoneIK3D. Movers advance by velocity x the real frame delta on a 14 m lane and wrap (the model's
## teleport filter drops the jump).
## After a warm-up, it alternates blocks of --block frames ACTIVE (everything on) and PAUSED (every AnimationTree
## active = false, every SkeletonModifier3D under the skeleton active = false, SoldierModel and CoverAnim
## set_process(false)) until each mode has --frames frames. Per frame it reads the wall time between two
## process_frame signals (Time.get_ticks_usec) and the engine's Performance TIME_PROCESS + TIME_PHYSICS_PROCESS.
## animation_ms = active - paused (process+physics monitors: the main method); the wall-frame difference is printed
## too (it also holds the render thread's skinning work). vsync off, no frame cap. Run it --headless: windowed, the
## frame stays on the vsync cap. Then ANIM_DIRECT: the trees and skeletons are switched to manual callback mode and
## SoldierModel._process, CoverAnim._process, AnimationTree.advance and Skeleton3D.advance (the modifiers + IK) are
## timed one by one for --frames frames. ANIM_COST_MEDIAN repeats the A/B with per-frame medians (robust to the
## spikes of a shared machine, which move the means by several ms). On this PC the headless wall frame is paced at
## about 6.9 ms in both modes, so the wall difference says nothing there. Uses only public members via
## get()/has_method(), so it also runs against an older checkout: --path <checkout> --script <absolute path of this>.

const ROLES: Array[String] = ["idle", "idle", "idle", "idle", "idle", "idle", "jog", "jog", "jog", "jog", "jog", "jog",
		"sprint", "sprint", "sprint", "cover", "cover", "downed"]
const LANE_M := 14.0

var _frames := 600
var _block := 100
var _warmup := 180
var _pawns: Array[Node] = []
var _roles: Array[String] = []
var _base: Array[Vector3] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			_frames = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--block="):
			_block = maxi(10, int(arg.substr(8)))
		elif arg.begins_with("--warmup="):
			_warmup = maxi(0, int(arg.substr(9)))
	_run.call_deferred()


func _stage() -> Node3D:
	var stage := Node3D.new()
	stage.name = "Stage"
	root.add_child(stage)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.56, 0.66, 0.78)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.environment = environment
	stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	stage.add_child(sun)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	ground.add_child(floor_mesh)
	stage.add_child(ground)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.global_position = Vector3(0, 6.0, 14.0)
	camera.look_at(Vector3(0, 0.9, -4.0), Vector3.UP)
	camera.current = true
	return stage


func _run() -> void:
	var stage := _stage()
	var cover_cfg := {}
	if FileAccess.file_exists("res://data/cover.json"):
		cover_cfg = DataRegistry.new().load_file("res://data/cover.json")
	for i in ROLES.size():
		var pawn: Node = load("res://scenes/player/pawn.tscn").instantiate()
		stage.add_child(pawn)
		pawn.set_physics_process(false)
		var column := i % 6
		var row := i / 6
		var at := Vector3((column - 2.5) * 2.6, 0.0, -row * 5.0)
		(pawn as Node3D).global_position = at
		_pawns.append(pawn)
		_base.append(at)
		_roles.append(ROLES[i])
	for i in 6:
		await process_frame
	for i in _pawns.size():
		var pawn := _pawns[i]
		match _roles[i]:
			"idle":
				pawn.set("pitch", 0.08 * float(i % 3))
			"downed":
				pawn.set("life", Pawn.Life.DOWNED)
			"cover":
				if pawn.has_method("enable_cover") and not cover_cfg.is_empty():
					pawn.call("enable_cover", cover_cfg)
					var cover: Variant = pawn.get("cover")
					if cover != null:
						cover.set("state", CoverController.State.IN_COVER)
						cover.set("side", 1 if i % 2 == 0 else -1)
						cover.set("tangent", Vector3.RIGHT)
						cover.set("normal", Vector3.BACK)
						cover.set("crouch_amount", 1.0 if i % 2 == 1 else 0.0)
						cover.set("crouched", i % 2 == 1)
				else:
					_roles[i] = "idle"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_print_mesh_facts()
	for i in _warmup:
		await _step()
	var sums := {true: [0.0, 0.0, 0], false: [0.0, 0.0, 0]}  # mode -> [wall ms, process+physics ms, frames]
	var samples := {true: [], false: []}  # process+physics ms per frame (medians)
	var active := true
	var last := Time.get_ticks_usec()
	while int(sums[true][2]) < _frames or int(sums[false][2]) < _frames:
		_set_active(active)
		for i in 10:  # let the switch settle (the tree's first frame, a modifier's first pass)
			await _step()
		last = Time.get_ticks_usec()
		for i in mini(_block, _frames - int(sums[active][2])):
			await _step()
			var now := Time.get_ticks_usec()
			sums[active][0] += (now - last) / 1000.0
			var proc := (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
			sums[active][1] += proc
			sums[active][2] += 1
			(samples[active] as Array).append(proc)
			last = now
		active = not active
	_set_active(true)
	var direct := await _direct()
	var a_wall := float(sums[true][0]) / float(sums[true][2])
	var p_wall := float(sums[false][0]) / float(sums[false][2])
	var a_proc := float(sums[true][1]) / float(sums[true][2])
	var p_proc := float(sums[false][1]) / float(sums[false][2])
	var counts := {}
	for r in _roles:
		counts[r] = int(counts.get(r, 0)) + 1
	print("ANIM_COST desktop proxy, not device: soldiers=%d roles=%s frames_per_mode=%d active_ms=%.3f paused_ms=%.3f animation_ms=%.3f per_soldier_us=%.1f wall_active_ms=%.3f wall_paused_ms=%.3f wall_diff_ms=%.3f" % [
			_pawns.size(), str(counts), _frames, a_proc, p_proc, a_proc - p_proc, (a_proc - p_proc) * 1000.0 / _pawns.size(),
			a_wall, p_wall, a_wall - p_wall])
	var a_med := _median(samples[true])
	var p_med := _median(samples[false])
	print("ANIM_COST_MEDIAN desktop proxy, not device: active_ms=%.3f paused_ms=%.3f animation_ms=%.3f per_soldier_us=%.1f frames=%d/%d" % [
			a_med, p_med, a_med - p_med, (a_med - p_med) * 1000.0 / _pawns.size(), (samples[true] as Array).size(), (samples[false] as Array).size()])
	print("ANIM_DIRECT desktop proxy, not device: soldiers=%d frames=%d model_process_ms=%.3f tree_advance_ms=%.3f skeleton_advance_ms=%.3f total_ms=%.3f per_soldier_us=%.1f" % [
			_pawns.size(), _frames, direct[0], direct[1], direct[2], direct[0] + direct[1] + direct[2],
			(direct[0] + direct[1] + direct[2]) * 1000.0 / _pawns.size()])
	quit()


## The direct method: every AnimationTree and Skeleton3D switched to manual callback mode, the SoldierModel /
## CoverAnim _process and both advance() calls made here in the engine's order, each timed with Time.get_ticks_usec.
## advance() only marks a skeleton dirty, so the tool sends NOTIFICATION_UPDATE_SKELETON right after it inside the timer
## (the modifiers, the IK, the bone poses and the skin); any deferred second pass the engine still makes is not timed.
func _direct() -> Array[float]:
	var models: Array[Node] = []
	var covers: Array[Node] = []
	var trees: Array[AnimationTree] = []
	var skeletons: Array[Skeleton3D] = []
	for pawn in _pawns:
		var model := pawn.get_node_or_null("SoldierModel")
		models.append(model)
		covers.append(pawn.get_node_or_null("CoverAnim"))
		model.set_process(false)
		if covers[-1] != null:
			covers[-1].set_process(false)
		var tree := model.get("animation_tree") as AnimationTree
		tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		trees.append(tree)
		var skeleton := model.get("skeleton") as Skeleton3D
		skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		skeletons.append(skeleton)
	var sums: Array[float] = [0.0, 0.0, 0.0]
	for frame in _frames + 30:
		await _step()
		var delta := root.get_process_delta_time()
		var t0 := Time.get_ticks_usec()
		for i in models.size():
			models[i].call("_process", delta)
			if covers[i] != null:
				covers[i].call("_process", delta)
		var t1 := Time.get_ticks_usec()
		for tree in trees:
			tree.advance(delta)
		var t2 := Time.get_ticks_usec()
		for skeleton in skeletons:
			skeleton.advance(delta)
			# advance() only marks the skeleton dirty; its modifiers, IK and skin run in this (normally deferred) update.
			skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
		var t3 := Time.get_ticks_usec()
		if frame >= 30:
			sums[0] += (t1 - t0) / 1000.0
			sums[1] += (t2 - t1) / 1000.0
			sums[2] += (t3 - t2) / 1000.0
	return [sums[0] / _frames, sums[1] / _frames, sums[2] / _frames]


## One frame: movers advance along their lane by their forced velocity (wrapping), then the tree runs.
func _step() -> void:
	var delta := root.get_process_delta_time()
	for i in _pawns.size():
		var pawn := _pawns[i] as Node3D
		var speed := 0.0
		if _roles[i] == "jog":
			speed = float(pawn.call("get_move_speed"))
		elif _roles[i] == "sprint":
			speed = float(pawn.call("get_max_move_speed"))
		var velocity := Vector3.FORWARD * speed
		pawn.set("velocity", velocity)
		if speed > 0.0:
			var p := pawn.global_position + velocity * maxf(delta, 0.0)
			if _base[i].z - p.z > LANE_M:
				p.z = _base[i].z
			pawn.global_position = p
	await process_frame


func _set_active(on: bool) -> void:
	for pawn in _pawns:
		var model := pawn.get_node_or_null("SoldierModel")
		if model == null:
			continue
		model.set_process(on)
		var tree: Variant = model.get("animation_tree")
		if tree is AnimationTree:
			(tree as AnimationTree).active = on
		var skeleton: Variant = model.get("skeleton")
		if skeleton is Skeleton3D:
			for child in (skeleton as Skeleton3D).get_children():
				if child is SkeletonModifier3D:
					(child as SkeletonModifier3D).active = on
		var cover_anim := pawn.get_node_or_null("CoverAnim")
		if cover_anim != null:
			cover_anim.set_process(on)


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2]) if sorted.size() > 0 else 0.0


func _print_mesh_facts() -> void:
	var model := _pawns[0].get_node_or_null("SoldierModel")
	var skeleton: Variant = model.get("skeleton")
	var near: Variant = model.get("armor")
	var far: Variant = model.get("armor_far")
	var modifiers := 0
	for child in (skeleton as Skeleton3D).get_children():
		if child is SkeletonModifier3D:
			modifiers += 1
	print("ANIM_MESH bones=%d modifiers=%d near_verts=%d near_tris=%d far_verts=%s far_tris=%s visibility_switch_m=%s" % [
			(skeleton as Skeleton3D).get_bone_count(), modifiers, _verts(near), _tris(near),
			str(_verts(far)) if far != null else "none", str(_tris(far)) if far != null else "none",
			str((near as MeshInstance3D).visibility_range_end) if near != null else "?"])


func _verts(mi: Variant) -> int:
	if not (mi is MeshInstance3D) or (mi as MeshInstance3D).mesh == null:
		return 0
	var mesh := (mi as MeshInstance3D).mesh
	var n := 0
	for s in mesh.get_surface_count():
		n += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n


func _tris(mi: Variant) -> int:
	if not (mi is MeshInstance3D) or (mi as MeshInstance3D).mesh == null:
		return 0
	var mesh := (mi as MeshInstance3D).mesh
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var index: Variant = arrays[Mesh.ARRAY_INDEX]
		n += ((index as PackedInt32Array).size() if index != null and (index as PackedInt32Array).size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n
