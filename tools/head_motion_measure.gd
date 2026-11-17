extends SceneTree
## M2 AN3 stage A: headless measurement of the third-person soldier's head-to-body motion (the "bobblehead").
##   godot.cmd --headless --path . --fixed-fps 60 --log-file <log> --script res://tools/head_motion_measure.gd -- --out=<dir>
## Each run builds a fresh REAL pawn (scenes/player/pawn.tscn) with its real SoldierModel, AnimationTree, SoldierGait,
## SoldierPose, SoldierCrawl, IK (and CoverAnim for the cover states). The pawn's physics step is off; the tool forces
## the read-only state the visuals read (velocity, yaw, pitch, drop_state + landed, life, flinch(), reload_started,
## the shot, CoverController fields, SoldierPose.force) and steps the model, tree and skeleton by hand at 1/60 s
## (as tests/test_soldier_footslide.gd does). Per frame, in the MODEL frame (skeleton global poses after every
## modifier of that frame, SoldierModel.pose_cache):
##   the Neck, Head and Chest transforms; the chest top (Chest * rest offset of Neck from Chest); the gap
##   (Neck origin - chest top: the visible neck stretch) and its rate; the Neck-vs-Chest and Head-vs-Chest rotation
##   relative to rest (pitch/yaw/roll, total) and its rate; the Neck and Head origins off their rest (the helmet
##   leaving the hitbox); a joint split of the chest-top motion (hips rotation, spine rotation, chest rotation,
##   translation) that, with the Neck's own offset, sums to the gap.
## Attribution: each source is switched off in its own run (data mutated in memory and restored, or the tool-only
## statics SoldierPose.measure_off / CoverAnim.measure_clip_neck; nothing shipped changes while they are default);
## its contribution is the largest per-frame difference from the baseline run (same frames, same inputs).
## Writes <out>/<state>.csv (baseline) and <out>/summary.md. Options: --out=<dir> --states=<a,b> --sources=<a,b|none>.
## Presentation measurement only; never touches the pawn's collider, hitboxes or gameplay state beyond the forced inputs.

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 10
const DEFAULT_OUT := "C:/Users/shibi/OpenBot/Agents/agent-afa1d96b-b33b-4ce0-8b3e-07b60fbebb5d/gladius/runs/M2AN3/measure_before"
const STATES: Array[String] = ["idle", "walk", "jog", "sprint", "strafe_left", "strafe_right", "backpedal",
	"turn_stand", "turn_jog", "aim_down", "aim_level", "aim_up", "aim_sweep", "fire", "reload", "hit_chest", "hit_head",
	"fall_land", "cover_stand", "cover_crouch", "cover_peek", "cover_rise", "downed_crawl", "revive"]
const ALL := ["*"]
## source id -> [label, states it is run on (ALL = every state)]
const SOURCES := {
	"aim": ["1 aim pitch on the Chest (aim clips' Chest key = identity)", ["aim_down", "aim_level", "aim_up", "aim_sweep"]],
	"cover_pin": ["2 cover Neck pin (keyed cover clips keep their own Neck tracks)", ["cover_stand", "cover_crouch", "cover_peek", "cover_rise"]],
	"carry_neck": ["3a _carry_neck (revive kneel carries no neck)", ["revive"]],
	"body_turn_neck": ["3b whole-body turn not applied to the Neck root (what-if: helmet held on the hitbox)", ALL],
	"lean": ["3c lean into movement (poses.lean = 0)", ALL],
	"pose_spine_chest": ["3d pose Spine/Chest bone angles (fall, land, downed, revive fallback) = 0", ["fall_land", "downed_crawl", "revive"]],
	"neck_drop": ["4a helmet sinks with the chest (gait.neck_drop_max_m = 0)", ALL],
	"hips_bob": ["4b residual hips bob (gait.hips_bob_scale = 0)", ALL],
	"hip_yaw": ["4c strafe hip yaw (gait.strafe.hip_yaw_max_deg = 0)", ["strafe_left", "strafe_right", "backpedal", "turn_jog"]],
	"spine_follow": ["4d library spine motion (gait.spine_follow = 0)", ALL],
	"chest_upright": ["4e chest keeps the clip lean residue (gait.chest_upright = 1)", ALL],
	"hit": ["5 hit flinch (no flinch requested)", ["hit_chest", "hit_head"]],
	"breath": ["6a breathing on the Chest (poses.breath.deg = 0)", ALL],
	"fall_glide": ["(extra) glide steering during the fall (no horizontal glide velocity: no run cycle under the fall pose)", ["fall_land"]],
	"fire_kick": ["(extra) fire kick on Spine/Chest (fire_chest_deg, fire_spine_deg = 0)", ["fire"]],
	"reload_chest": ["(extra) reload chest lean (reload_chest_deg = 0)", ["reload"]],
}

var _out := DEFAULT_OUT
var _states: Array[String] = []
var _sources: Array = []
var _undo: Array = []  # [dict, key, old value]
var _no_flinch := false
var _no_glide := false
var _info: PackedStringArray = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--states="):
			for s in a.substr(9).split(",", false):
				_states.append(s)
		elif a == "--legacy-head":  # M2 AN3: the pre-AN3 head and body paths (SoldierRig.head_legacy)
			SoldierRig.head_legacy = true
		elif a.begins_with("--sources="):
			for s in a.substr(10).split(",", false):
				if s != "none":
					_sources.append(s)
			if _sources.is_empty():
				_sources = ["none"]
	if _states.is_empty():
		_states = STATES.duplicate()
	if _sources.is_empty():
		_sources = SOURCES.keys()
	elif _sources == ["none"]:
		_sources = []
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _log(line: String) -> void:
	print("[head_motion] " + line)


func _run() -> void:
	var started := Time.get_ticks_msec()
	var summary: Array = []  # per state: stats dictionary
	var attribution := {}  # state -> {source: [d_gap_m, d_angle_deg, peak_gap_m_without, peak_angle_deg_without]}
	for state in _states:
		var base: Dictionary = await _measure(state, "")
		_write_csv(state, base)
		var stats := _stats(state, base)
		summary.append(stats)
		_log("state=%s frames=%d gap_max_m=%.4f gap_rate_max=%.3f neck_chest_max_deg=%.2f rate_max=%.1f head_chest_max_deg=%.2f neck_off_max_m=%.4f" % [
			state, stats["frames"], stats["gap_max"], stats["gap_rate_max"], stats["ang_max"], stats["ang_rate_max"], stats["head_max"], stats["neck_off_max"]])
		attribution[state] = {}
		for source: String in _sources:
			var scope: Array = SOURCES[source][1]
			if scope != ALL and not scope.has(state):
				continue
			var off: Dictionary = await _measure(state, source)
			var d := _difference(base, off)
			attribution[state][source] = d
			_log("  source=%s d_gap_m=%.4f d_angle_deg=%.2f gap_max_without=%.4f angle_max_without=%.2f" % [source, d[0], d[1], d[2], d[3]])
	_write_summary(summary, attribution)
	_log("DONE out=%s seconds=%.1f" % [_out, (Time.get_ticks_msec() - started) / 1000.0])
	quit(0)


# --- switches -------------------------------------------------------------------------------------------------

func _override(dict: Dictionary, key: String, value: Variant) -> void:
	_undo.append([dict, key, dict[key]])
	dict[key] = value


func _apply_source(source: String) -> void:
	var cfg := SoldierRig.config()
	var gait: Dictionary = cfg["gait"]
	var poses: Dictionary = cfg["poses"]
	match source:
		"cover_pin":
			CoverAnim.measure_clip_neck = true
		"carry_neck", "body_turn_neck":
			SoldierPose.measure_off[source] = true
		"lean":
			_override(poses["lean"], "forward_deg", 0.0)
			_override(poses["lean"], "side_deg", 0.0)
		"pose_spine_chest":
			for state in ["fall", "land", "downed", "revive"]:
				var bones: Dictionary = poses[state]["bones"]
				for bone in ["Spine", "Chest"]:
					if bones.has(bone):
						_override(bones, bone, [0, 0, 0])
		"neck_drop":
			_override(gait, "neck_drop_max_m", 0.0)
		"hips_bob":
			_override(gait, "hips_bob_scale", 0.0)
		"hip_yaw":
			_override(gait["strafe"], "hip_yaw_max_deg", 0.0)
		"spine_follow":
			_override(gait, "spine_follow", 0.0)
		"chest_upright":
			_override(gait, "chest_upright", 1.0)
		"hit":
			_no_flinch = true
		"fall_glide":
			_no_glide = true
		"breath":
			_override(poses["breath"], "deg", 0.0)
		"fire_kick":
			_override(cfg["upper_body"], "fire_chest_deg", 0.0)
			_override(cfg["upper_body"], "fire_spine_deg", 0.0)
		"reload_chest":
			var zeros: Array = []
			for v in cfg["upper_body"]["reload_chest_deg"]:
				zeros.append(0)
			_override(cfg["upper_body"], "reload_chest_deg", zeros)


## After the pawn is built: switches that edit this pawn's own clips.
func _apply_source_built(source: String, model: SoldierModel) -> void:
	if source != "aim":
		return
	var library := model.animation_tree.get_animation_library(&"")
	for name in [&"aim_down", &"aim", &"aim_up"]:
		var clip := library.get_animation(name).duplicate(true) as Animation
		var track := clip.find_track(NodePath("Skeleton3D:Chest"), Animation.TYPE_ROTATION_3D)
		if track >= 0:
			for k in clip.track_get_key_count(track):
				clip.track_set_key_value(track, k, Quaternion.IDENTITY)
		library.remove_animation(name)
		library.add_animation(name, clip)


func _restore() -> void:
	for i in range(_undo.size() - 1, -1, -1):
		var entry: Array = _undo[i]
		(entry[0] as Dictionary)[entry[1]] = entry[2]
	_undo.clear()
	SoldierPose.measure_off.clear()
	CoverAnim.measure_clip_neck = false
	_no_flinch = false
	_no_glide = false


# --- one run --------------------------------------------------------------------------------------------------

var _pawn: Pawn
var _model: SoldierModel
var _cover: CoverAnim
var _rows: Array = []
var _t := 0.0
var _bones := {}
var _neck_from_chest := Transform3D.IDENTITY
var _rest := {}


func _measure(state: String, source: String) -> Dictionary:
	if source != "":
		_apply_source(source)
	var cover := state.begins_with("cover_")
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_model = _pawn.get_node("SoldierModel") as SoldierModel
	_model.set_process(false)
	_model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	_cover = null
	if cover:
		_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
		_cover = _pawn.get_node_or_null("CoverAnim") as CoverAnim
		if _cover != null:
			_cover.set_process(false)
	if source != "":
		_apply_source_built(source, _model)
	var skeleton := _model.skeleton
	for name in ["Hips", "Spine", "Chest", "Neck", "Head", "LeftFoot"]:
		_bones[name] = skeleton.find_bone(name)
	for name: String in _bones:
		_rest[name] = skeleton.get_bone_global_rest(int(_bones[name]))
	_neck_from_chest = (_rest["Chest"] as Transform3D).affine_inverse() * (_rest["Neck"] as Transform3D)
	if source == "" and state == _states[0] and _info.is_empty():
		_probe_clips(skeleton)
	_rows = []
	_t = 0.0
	for i in SETTLE_FRAMES:
		await _step(Vector3.ZERO, false)
	await _script(state)
	var rows := _rows
	_pawn.free()
	_pawn = null
	if source != "":
		_restore()
	await process_frame
	return {"rows": rows}


func _probe_clips(skeleton: Skeleton3D) -> void:
	for slot in ["cover_idle_r", "cover_idle_r_crouch", "peek_right", "cover_rise", "revive", "hit_chest", "hit_head", "idle", "walk_fwd"]:
		var clip := SoldierAnimation.shared(slot, skeleton)
		if clip == null:
			_info.append("clip %s: none (procedural)" % slot)
			continue
		var tracks := PackedStringArray()
		for t in clip.get_track_count():
			var bone := String(clip.track_get_path(t).get_concatenated_subnames())
			if bone in ["Neck", "Head"]:
				var kind := clip.track_get_type(t)
				var spread := ""
				if kind == Animation.TYPE_POSITION_3D or kind == Animation.TYPE_ROTATION_3D:
					# The key range: max distance (m) or angle (deg) of any key from the first one, and the first key.
					var first: Variant = clip.track_get_key_value(t, 0)
					var far := 0.0
					for k in clip.track_get_key_count(t):
						var v: Variant = clip.track_get_key_value(t, k)
						far = maxf(far, (v as Vector3).distance_to(first) if kind == Animation.TYPE_POSITION_3D else _q_angle(first, v))
					spread = " first=%s range=%.3f" % [str(first) if kind == Animation.TYPE_POSITION_3D else str(_euler_deg(first).round()), far]
				tracks.append("%s:%s%s" % [bone, "pos" if kind == Animation.TYPE_POSITION_3D else "rot" if kind == Animation.TYPE_ROTATION_3D else str(kind), spread])
		_info.append("clip %s: Neck/Head tracks [%s]" % [slot, "; ".join(tracks)])
	var neck := skeleton.find_bone("Neck")
	_info.append("Neck rest origin %s; Head rest origin %s (the hitbox centre)" % [skeleton.get_bone_global_rest(neck).origin, skeleton.get_bone_global_rest(skeleton.find_bone("Head")).origin])


## One frame at 1/60 s: the pawn moves by its forced ground velocity, then the cover presentation, the model, the
## tree and the skeleton (its modifiers) advance; the row is the frame's final pose (pose_cache).
func _step(velocity: Vector3, record: bool = true) -> void:
	_pawn.velocity = velocity
	_pawn.global_position += Vector3(velocity.x, 0.0, velocity.z) * DT
	if _cover != null:
		_cover.sync_pose(DT)
	_model._process(DT)
	_model.animation_tree.advance(DT)
	_model.skeleton.advance(DT)
	await process_frame
	if record:
		_rows.append(_row())
		_t += DT


func _hold(seconds: float, velocity: Vector3 = Vector3.ZERO, each: Callable = Callable()) -> void:
	for i in roundi(seconds / DT):
		if each.is_valid():
			each.call(i * DT)
		await _step(velocity if not each.is_valid() else _pawn.get_meta(&"measure_velocity", velocity))


func _forward(speed: float) -> Vector3:
	return -_pawn.global_transform.basis.z * speed


func _script(state: String) -> void:
	var speed := _pawn.get_move_speed()
	var registry := DataRegistry.new()
	var ratio := float(registry.get_movement_cfg()["strafe_back_ratio"]["value"])
	var limit := deg_to_rad(float(SoldierRig.config()["upper_body"]["aim_pitch_limit_deg"]))
	match state:
		"idle":
			await _hold(2.5)
		"walk":
			await _hold(2.5, Vector3.FORWARD * speed * float(SoldierRig.config()["gait"]["walk_slow_blend"]))
		"jog":
			await _hold(2.5, Vector3.FORWARD * speed)
		"sprint":
			await _hold(2.5, Vector3.FORWARD * _pawn.get_max_move_speed())
		"strafe_left":
			await _hold(2.5, Vector3.LEFT * speed * ratio)
		"strafe_right":
			await _hold(2.5, Vector3.RIGHT * speed * ratio)
		"backpedal":
			await _hold(2.5, Vector3.BACK * speed * ratio)
		"turn_stand", "turn_jog":
			# Yaw sweep +-90 degrees, 2 s period (peak 283 deg/s); jogging: the ground velocity stays world forward
			# while the pawn turns, so the motion passes through strafe and back-pedal (looking around while running).
			var moving := state == "turn_jog"
			await _hold(3.0, Vector3.ZERO, func(t: float) -> void:
				_pawn.rotation.y = deg_to_rad(90.0) * sin(TAU * t / 2.0)
				_pawn.set_meta(&"measure_velocity", Vector3.FORWARD * speed if moving else Vector3.ZERO))
		"aim_down", "aim_level", "aim_up":
			_pawn.pitch = limit * (-1.0 if state == "aim_down" else 1.0 if state == "aim_up" else 0.0)
			await _hold(2.0)
		"aim_sweep":
			# -1 .. +1 x aim_pitch_limit_deg and back, 1 s period, then a 3 x limit flick (the blend saturates at 1).
			await _hold(2.0, Vector3.ZERO, func(t: float) -> void:
				_pawn.pitch = limit * sin(TAU * t) if t < 1.5 else limit * 3.0 * signf(sin(TAU * t * 2.0)))
		"fire":
			for shot in 10:
				_model._on_shot_shown(Vector3.ZERO, Vector3.FORWARD)
				await _hold(0.12)
			await _hold(0.4)
		"reload":
			_pawn.reload_started.emit()
			await _hold(maxf(_model.reload_duration_s, 0.5) + 0.5)
		"hit_chest", "hit_head":
			await _hold(0.3)
			for hit in 3:
				if not _no_flinch:
					_model.flinch(state == "hit_head")
				await _hold(0.7)
		"fall_land":
			# The drop: 0.8 s falling with no stick, 0.8 s gliding forward (stick held), then the landing
			# (drop_state NONE + landed, as Pawn._apply_fall) and 1.4 s standing.
			_pawn.drop_state = Pawn.Drop.FALLING
			var fall := -float(_pawn.drop_max_fall_mps)
			await _hold(0.8, Vector3(0, fall, 0))
			await _hold(0.8, Vector3.ZERO, func(_t: float) -> void:
				_pawn.set_meta(&"measure_velocity", (Vector3.ZERO if _no_glide else _forward(float(_pawn.drop_glide_mps))) + Vector3(0, fall, 0)))
			_pawn.drop_state = Pawn.Drop.NONE
			_pawn.landed.emit()
			await _hold(1.4)
		"cover_stand", "cover_crouch", "cover_peek", "cover_rise":
			var controller := _pawn.cover
			controller.side = 1
			controller.tangent = Vector3.RIGHT
			controller.normal = Vector3.BACK
			var low := state == "cover_crouch" or state == "cover_rise"
			controller.crouch_amount = 1.0 if low else 0.0
			controller.crouched = low
			controller.state = CoverController.State.ENTERING
			await _hold(0.4)
			controller.state = CoverController.State.IN_COVER
			await _hold(1.0)
			if state == "cover_peek":
				# Lean out right (aim_out ramps over 0.25 s), hold, back to the hug.
				controller.state = CoverController.State.PEEK_RIGHT
				await _hold(1.0, Vector3.ZERO, func(t: float) -> void:
					controller.aim_out_amount = clampf(t / 0.25, 0.0, 1.0))
				controller.state = CoverController.State.IN_COVER
				await _hold(0.6, Vector3.ZERO, func(t: float) -> void:
					controller.aim_out_amount = clampf(1.0 - t / 0.25, 0.0, 1.0))
			elif state == "cover_rise":
				# Rise from the low hug to fire over the wall (aim_out up, crouch down over 0.25 s), hold, back down.
				await _hold(1.0, Vector3.ZERO, func(t: float) -> void:
					controller.aim_out_amount = clampf(t / 0.25, 0.0, 1.0)
					controller.crouch_amount = 1.0 - controller.aim_out_amount)
				await _hold(0.6, Vector3.ZERO, func(t: float) -> void:
					controller.aim_out_amount = clampf(1.0 - t / 0.25, 0.0, 1.0)
					controller.crouch_amount = 1.0 - controller.aim_out_amount)
			else:
				await _hold(1.0)
		"downed_crawl":
			var pct := float(registry.load_file("res://data/br.json")["downed"]["downed_move_speed_pct"])
			_pawn.downed_move_speed_pct = pct
			_pawn.life = Pawn.Life.DOWNED
			await _hold(0.6)
			await _hold(2.0, Vector3.FORWARD * speed * pct / 100.0)
		"revive":
			_model.pose.force["revive"] = 1.0
			await _hold(3.0)
		_:
			push_error("head_motion: unknown state " + state)


# --- per-frame measures ---------------------------------------------------------------------------------------

func _row() -> Dictionary:
	var cache := _model.pose_cache
	var hips: Transform3D = cache[int(_bones["Hips"])]
	var spine_g: Transform3D = cache[int(_bones["Spine"])]
	var chest: Transform3D = cache[int(_bones["Chest"])]
	var neck: Transform3D = cache[int(_bones["Neck"])]
	var head: Transform3D = cache[int(_bones["Head"])]
	var top := (chest * _neck_from_chest).origin
	var neck_rest: Vector3 = (_rest["Neck"] as Transform3D).origin
	# Joint split of the chest top's motion (telescoping: hips rotation, spine rotation, chest rotation, translation).
	var spine_l := hips.affine_inverse() * spine_g
	var chest_l := spine_g.affine_inverse() * chest
	var hips_t := Transform3D(Basis.IDENTITY, hips.origin)
	var spine_t := Transform3D(Basis.IDENTITY, spine_l.origin)
	var chest_t := Transform3D(Basis.IDENTITY, chest_l.origin)
	var t1 := (hips_t * spine_l * chest_l * _neck_from_chest).origin
	var t2 := (hips_t * spine_t * chest_l * _neck_from_chest).origin
	var t3 := (hips_t * spine_t * chest_t * _neck_from_chest).origin
	var cq := chest.basis.get_rotation_quaternion()
	return {
		"t": _t, "neck": neck, "head": head, "chest": chest, "top": top,
		"gap": neck.origin - top,
		"neck_off": neck.origin - neck_rest,
		"head_off": head.origin - (_rest["Head"] as Transform3D).origin,
		# The helmet centre (Head origin) against the pawn's real head hitbox (its Head Area3D, in the model frame).
		"hitbox_off": head.origin.distance_to(_model.skeleton.global_transform.affine_inverse() * (_pawn.get_node("Head") as Node3D).global_position),
		"rel": cq.inverse() * neck.basis.get_rotation_quaternion(),
		"rel_head": cq.inverse() * head.basis.get_rotation_quaternion(),
		"head_local": neck.basis.get_rotation_quaternion().inverse() * head.basis.get_rotation_quaternion(),
		"j_hips_rot": top - t1, "j_spine_rot": t1 - t2, "j_chest_rot": t2 - t3, "j_trans": t3 - neck_rest,
		"a_hips": hips.basis.get_rotation_quaternion().get_angle(),
		"a_spine": spine_l.basis.get_rotation_quaternion().get_angle(),
		"a_chest": chest_l.basis.get_rotation_quaternion().get_angle(),
		"a_neck": neck.basis.get_rotation_quaternion().get_angle(),
		"hips_o": hips.origin, "foot_o": (cache[int(_bones["LeftFoot"])] as Transform3D).origin,
	}


static func _euler_deg(q: Quaternion) -> Vector3:
	var e := Basis(q).get_euler()
	return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))


static func _q_angle(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg((a.inverse() * b).normalized().get_angle())


func _write_csv(state: String, run: Dictionary) -> void:
	var file := FileAccess.open(_out.path_join(state + ".csv"), FileAccess.WRITE)
	file.store_line(",".join(["t_s", "neck_x", "neck_y", "neck_z", "head_x", "head_y", "head_z", "chest_x", "chest_y", "chest_z",
		"top_x", "top_y", "top_z", "gap_x", "gap_y", "gap_z", "gap_m", "gap_rate_mps",
		"neck_chest_pitch", "neck_chest_yaw", "neck_chest_roll", "neck_chest_deg", "neck_chest_rate_dps",
		"head_chest_pitch", "head_chest_yaw", "head_chest_roll", "head_chest_deg", "head_chest_rate_dps", "head_local_deg",
		"neck_off_x", "neck_off_y", "neck_off_z", "neck_off_m", "head_off_m",
		"chest_gpitch", "neck_gpitch", "head_gpitch", "split_hips_rot_m", "split_spine_rot_m", "split_chest_rot_m", "split_trans_m",
		"hips_deg", "spine_deg", "chest_local_deg", "neck_deg"]))
	var rows: Array = run["rows"]
	for i in rows.size():
		var r: Dictionary = rows[i]
		var p: Dictionary = rows[maxi(i - 1, 0)]
		var gap: Vector3 = r["gap"]
		var rel := _euler_deg(r["rel"])
		var relh := _euler_deg(r["rel_head"])
		var off: Vector3 = r["neck_off"]
		var values: Array = [r["t"], r["neck"].origin.x, r["neck"].origin.y, r["neck"].origin.z, r["head"].origin.x, r["head"].origin.y, r["head"].origin.z,
			r["chest"].origin.x, r["chest"].origin.y, r["chest"].origin.z, r["top"].x, r["top"].y, r["top"].z,
			gap.x, gap.y, gap.z, gap.length(), (gap - (p["gap"] as Vector3)).length() / DT,
			rel.x, rel.y, rel.z, rad_to_deg((r["rel"] as Quaternion).get_angle()), _q_angle(p["rel"], r["rel"]) / DT,
			relh.x, relh.y, relh.z, rad_to_deg((r["rel_head"] as Quaternion).get_angle()), _q_angle(p["rel_head"], r["rel_head"]) / DT,
			rad_to_deg((r["head_local"] as Quaternion).get_angle()),
			off.x, off.y, off.z, off.length(), (r["head_off"] as Vector3).length(),
			_euler_deg(r["chest"].basis.get_rotation_quaternion()).x, _euler_deg(r["neck"].basis.get_rotation_quaternion()).x,
			_euler_deg(r["head"].basis.get_rotation_quaternion()).x,
			(r["j_hips_rot"] as Vector3).length(), (r["j_spine_rot"] as Vector3).length(), (r["j_chest_rot"] as Vector3).length(), (r["j_trans"] as Vector3).length(),
			rad_to_deg(r["a_hips"]), rad_to_deg(r["a_spine"]), rad_to_deg(r["a_chest"]), rad_to_deg(r["a_neck"])]
		var text := PackedStringArray()
		for v in values:
			text.append("%.5f" % float(v))
		file.store_line(",".join(text))
	file.close()


func _stats(state: String, run: Dictionary) -> Dictionary:
	var rows: Array = run["rows"]
	var s := {"state": state, "frames": rows.size(), "gap_max": 0.0, "gap_ss": 0.0, "gap_rate_max": 0.0, "gap_rate_ss": 0.0,
		"ang_max": 0.0, "ang_ss": 0.0, "ang_rate_max": 0.0, "ang_rate_ss": 0.0, "head_max": 0.0, "head_rate_max": 0.0,
		"head_local_max": 0.0, "neck_off_max": 0.0, "head_off_max": 0.0, "hitbox_off_max": 0.0,
		"split_hips_rot": 0.0, "split_spine_rot": 0.0, "split_chest_rot": 0.0, "split_trans": 0.0,
		"hips_deg": 0.0, "spine_deg": 0.0, "chest_local_deg": 0.0, "neck_deg": 0.0, "fall": []}
	for i in rows.size():
		var r: Dictionary = rows[i]
		var p: Dictionary = rows[maxi(i - 1, 0)]
		var gap := (r["gap"] as Vector3).length()
		var gap_rate := ((r["gap"] as Vector3) - (p["gap"] as Vector3)).length() / DT
		var ang := rad_to_deg((r["rel"] as Quaternion).get_angle())
		var ang_rate := _q_angle(p["rel"], r["rel"]) / DT
		s["gap_max"] = maxf(s["gap_max"], gap)
		s["gap_ss"] += gap * gap
		s["gap_rate_max"] = maxf(s["gap_rate_max"], gap_rate)
		s["gap_rate_ss"] += gap_rate * gap_rate
		s["ang_max"] = maxf(s["ang_max"], ang)
		s["ang_ss"] += ang * ang
		s["ang_rate_max"] = maxf(s["ang_rate_max"], ang_rate)
		s["ang_rate_ss"] += ang_rate * ang_rate
		s["head_max"] = maxf(s["head_max"], rad_to_deg((r["rel_head"] as Quaternion).get_angle()))
		s["head_rate_max"] = maxf(s["head_rate_max"], _q_angle(p["rel_head"], r["rel_head"]) / DT)
		s["head_local_max"] = maxf(s["head_local_max"], rad_to_deg((r["head_local"] as Quaternion).get_angle()))
		s["neck_off_max"] = maxf(s["neck_off_max"], (r["neck_off"] as Vector3).length())
		s["head_off_max"] = maxf(s["head_off_max"], (r["head_off"] as Vector3).length())
		for key in ["hips_rot", "spine_rot", "chest_rot", "trans"]:
			s["split_" + key] = maxf(s["split_" + key], (r["j_" + key] as Vector3).length())
		s["hips_deg"] = maxf(s["hips_deg"], rad_to_deg(r["a_hips"]))
		s["spine_deg"] = maxf(s["spine_deg"], rad_to_deg(r["a_spine"]))
		s["chest_local_deg"] = maxf(s["chest_local_deg"], rad_to_deg(r["a_chest"]))
		s["neck_deg"] = maxf(s["neck_deg"], rad_to_deg(r["a_neck"]))
		s["hitbox_off_max"] = maxf(s["hitbox_off_max"], float(r["hitbox_off"]))
		if state == "fall_land" and i % 15 == 0:
			s["fall"].append([r["t"], _euler_deg(r["chest"].basis.get_rotation_quaternion()).x, _euler_deg(r["neck"].basis.get_rotation_quaternion()).x,
				_euler_deg(r["head"].basis.get_rotation_quaternion()).x, gap, ang, (r["neck_off"] as Vector3).length(), (r["neck"] as Transform3D).origin.y,
				(r["hips_o"] as Vector3).y, (r["hips_o"] as Vector3).z, (r["foot_o"] as Vector3).y, (r["foot_o"] as Vector3).z, float(r["hitbox_off"])])
	var n := maxf(rows.size(), 1.0)
	for key in ["gap", "gap_rate", "ang", "ang_rate"]:
		s[key + "_rms"] = sqrt(float(s[key + "_ss"]) / n)
	return s


## [peak per-frame |gap difference| m, peak per-frame rotation difference deg, peak gap without m, peak angle without deg]
func _difference(base: Dictionary, off: Dictionary) -> Array:
	var a: Array = base["rows"]
	var b: Array = off["rows"]
	var d_gap := 0.0
	var d_ang := 0.0
	var gap_without := 0.0
	var ang_without := 0.0
	for i in mini(a.size(), b.size()):
		d_gap = maxf(d_gap, ((a[i]["gap"] as Vector3) - (b[i]["gap"] as Vector3)).length())
		d_ang = maxf(d_ang, _q_angle(a[i]["rel"], b[i]["rel"]))
		gap_without = maxf(gap_without, (b[i]["gap"] as Vector3).length())
		ang_without = maxf(ang_without, rad_to_deg((b[i]["rel"] as Quaternion).get_angle()))
	if a.size() != b.size():
		_log("WARNING frame count differs %d vs %d" % [a.size(), b.size()])
	return [d_gap, d_ang, gap_without, ang_without]


func _write_summary(summary: Array, attribution: Dictionary) -> void:
	var lines := PackedStringArray()
	lines.append("# M2 AN3 head-motion measurement (%s)" % ("legacy head: SoldierRig.head_legacy" if SoldierRig.head_legacy else "current head"))
	lines.append("")
	lines.append("Tool: tools/head_motion_measure.gd, headless, 1/60 s steps, model (skeleton) frame, final pose of each frame. [measured]")
	lines.append("gap = Neck origin - chest top (Chest * rest Neck-from-Chest offset); angle = Neck (or Head) rotation vs Chest rotation, rest = 0.")
	lines.append("")
	lines.append("## Summary per state (baseline)")
	lines.append("")
	lines.append("| state | frames | gap max m | gap RMS m | gap rate max m/s | gap rate RMS m/s | neck-chest max deg | RMS deg | rate max deg/s | rate RMS deg/s | head-chest max deg | head-chest rate max deg/s | head local max deg | neck off rest max m | head off rest max m |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for s: Dictionary in summary:
		lines.append("| %s | %d | %.3f | %.3f | %.2f | %.2f | %.1f | %.1f | %.0f | %.0f | %.1f | %.0f | %.1f | %.3f | %.3f |" % [s["state"], s["frames"],
			s["gap_max"], s["gap_rms"], s["gap_rate_max"], s["gap_rate_rms"], s["ang_max"], s["ang_rms"], s["ang_rate_max"], s["ang_rate_rms"],
			s["head_max"], s["head_rate_max"], s["head_local_max"], s["neck_off_max"], s["head_off_max"]])
	lines.append("")
	lines.append("## Helmet centre (Head origin) off the pawn's head hitbox (Head Area3D), max m")
	lines.append("")
	lines.append("| state | helmet off hitbox max m |")
	lines.append("|---|---|")
	for s: Dictionary in summary:
		lines.append("| %s | %.4f |" % [s["state"], s["hitbox_off_max"]])
	lines.append("")
	lines.append("## Joint split of the chest-top motion (peak |vector| m; telescoping hips rot -> spine rot -> chest rot -> translation) and peak joint angles (deg)")
	lines.append("")
	lines.append("| state | hips rot m | spine rot m | chest rot m | translation m | neck off m | hips deg | spine local deg | chest local deg | neck deg |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|")
	for s: Dictionary in summary:
		lines.append("| %s | %.3f | %.3f | %.3f | %.3f | %.3f | %.1f | %.1f | %.1f | %.1f |" % [s["state"], s["split_hips_rot"], s["split_spine_rot"],
			s["split_chest_rot"], s["split_trans"], s["neck_off_max"], s["hips_deg"], s["spine_deg"], s["chest_local_deg"], s["neck_deg"]])
	lines.append("")
	lines.append("## Attribution: source switched off -> peak per-frame change of the gap (mm) / of the neck-chest rotation (deg)")
	lines.append("")
	var header := "| state |"
	var rule := "|---|"
	for source: String in _sources:
		header += " %s |" % source
		rule += "---|"
	lines.append(header)
	lines.append(rule)
	for s: Dictionary in summary:
		var line := "| %s |" % s["state"]
		for source: String in _sources:
			if (attribution[s["state"]] as Dictionary).has(source):
				var d: Array = attribution[s["state"]][source]
				line += " %.0f / %.1f |" % [float(d[0]) * 1000.0, d[1]]
			else:
				line += " - |"
		lines.append(line)
	lines.append("")
	lines.append("Peak gap (m) / peak neck-chest angle (deg) WITH the source switched off:")
	lines.append("")
	lines.append(header)
	lines.append(rule)
	for s: Dictionary in summary:
		var line := "| %s |" % s["state"]
		for source: String in _sources:
			if (attribution[s["state"]] as Dictionary).has(source):
				var d: Array = attribution[s["state"]][source]
				line += " %.3f / %.1f |" % [d[2], d[3]]
			else:
				line += " - |"
		lines.append(line)
	lines.append("")
	lines.append("Sources:")
	for source: String in _sources:
		lines.append("- %s: %s" % [source, SOURCES[source][0]])
	for s: Dictionary in summary:
		if s["state"] == "fall_land" and not (s["fall"] as Array).is_empty():
			lines.append("")
			lines.append("## fall_land detail (global pitch in the model frame, deg; forward = negative)")
			lines.append("")
			lines.append("| t s | chest pitch | neck pitch | head pitch | gap m | neck-chest deg | neck off rest m | neck y m | hips y | hips z | left foot y | left foot z | helmet off hitbox m |")
			lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
			for f: Array in s["fall"]:
				lines.append("| %.2f | %.1f | %.1f | %.1f | %.3f | %.1f | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f |" % f)
	lines.append("")
	lines.append("## Clip probe")
	lines.append("")
	for line in _info:
		lines.append("- " + line)
	var file := FileAccess.open(_out.path_join("summary.md"), FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("\n".join(lines))
