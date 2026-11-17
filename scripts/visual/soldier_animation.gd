class_name SoldierAnimation
extends RefCounted
## Clip names and graph parameters remain independent of the procedural mesh.

static func _node(clip: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	return node


## M2 AN1: the moving gait slots. Library cycles are normalized (SoldierClips) and each blend point carries a
## TimeScale "speed" the model sets to ground speed / cycle_m, so the feet travel with the ground.
const GAITS: Array[String] = ["walk_slow", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd"]


static func _gait_point(clip: String) -> AnimationNodeBlendTree:
	var point := AnimationNodeBlendTree.new()
	var node := _node(clip)
	if clip.begins_with("strafe_"):
		node.set_meta(&"strafe", clip)  # SoldierModel swaps it to walk_back in the back half
	point.add_node(&"clip", node)
	point.add_node(&"speed", AnimationNodeTimeScale.new())
	point.connect_node(&"speed", 0, &"clip")
	point.connect_node(&"output", 0, &"speed")
	return point


static func build(skeleton: Skeleton3D, sprint: float, reload_s: float, sources: Variant = null) -> AnimationTree:
	var cfg: Dictionary = SoldierRig.config()["locomotion"]
	var gait_cfg: Dictionary = SoldierRig.config()["gait"]
	var clips := ClipLibrary.new(sources)
	var library := AnimationLibrary.new()
	var cycles: Dictionary = {}
	for clip in ["idle"] + GAITS:
		var resolved := clips.resolve(clip, _locomotion(clip, cfg), skeleton)
		if clip != "idle" and clips.source_for(clip) != "procedural":
			var gait := SoldierClips.gait(resolved, skeleton, clip == "walk_back")
			resolved = gait["clip"]
			# M2 AN1 commit 6: gait.cycle_scale corrects a measured stride where the gait's leg re-solve (SoldierGait)
			# moves the planted foot away from the raw clip's (data, per slot; 1 = as measured).
			cycles[clip] = float(gait["cycle_m"]) * float((gait_cfg.get("cycle_scale", {}) as Dictionary).get(clip, 1.0))
		library.add_animation(clip, resolved)
	var extras: Dictionary = {}
	for clip in ["jump_air", "hit_chest", "hit_head"]:
		var resolved := clips.resolve(clip, null, skeleton)
		if resolved != null:
			extras[clip] = resolved
	for clip in ["hit_chest", "hit_head"]:
		if extras.has(clip):
			library.add_animation(clip, _shared_additive(extras[clip]))
	if extras.has("jump_air"):
		library.add_animation("jump_air", extras["jump_air"])
	var upper_cfg: Dictionary = SoldierRig.config()["upper_body"]
	for name in ["aim_down", "aim", "aim_up"]:
		var pitch := -1.0 if name == "aim_down" else 1.0 if name == "aim_up" else 0.0
		library.add_animation(name, resolve_slot(clips, name, aim_clip(skeleton, upper_cfg, pitch), skeleton))
	library.add_animation("fire", resolve_slot(clips, "fire", fire_clip(upper_cfg), skeleton))
	library.add_animation("reload", resolve_slot(clips, "reload", reload_clip(skeleton, reload_s, upper_cfg), skeleton))
	var tree := AnimationTree.new()
	tree.set_meta(&"clip_library", clips)
	tree.set_meta(&"gait_cycles", cycles)
	tree.name = "AnimationTree"
	tree.root_node = NodePath("..")
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	tree.add_animation_library(&"", library)
	var graph := AnimationNodeBlendTree.new()
	var move := AnimationNodeBlendSpace2D.new()
	move.min_space = Vector2(-1.0, -sprint)
	move.max_space = Vector2.ONE
	# Every gait advances even at zero weight, so the normalized cycles stay in phase while they blend.
	move.sync = true
	move.add_blend_point(_node("idle"), Vector2.ZERO, -1, &"idle")
	move.add_blend_point(_gait_point("walk_slow"), Vector2(0, -float(gait_cfg["walk_slow_blend"])), -1, &"walk_slow")
	move.add_blend_point(_gait_point("walk_fwd"), Vector2(0, -1), -1, &"walk_fwd")
	move.add_blend_point(_gait_point("walk_back"), Vector2(0, 1), -1, &"walk_back")
	move.add_blend_point(_gait_point("strafe_l"), Vector2(-1, 0), -1, &"strafe_l")
	move.add_blend_point(_gait_point("strafe_r"), Vector2(1, 0), -1, &"strafe_r")
	move.add_blend_point(_gait_point("run_fwd"), Vector2(0, -sprint), -1, &"run_fwd")
	graph.add_node(&"locomotion", move)
	# Keep the public BlendSpace2D live at its original parameter path.
	var lower := AnimationNodeTransition.new()
	lower.input_count = 2 if extras.has("jump_air") else 1
	lower.set_input_name(0, "stand")
	lower.xfade_time = float(SoldierRig.config()["layers"]["lower_xfade_s"])
	graph.add_node(&"lower", lower)
	graph.connect_node(&"lower", 0, &"locomotion")
	# M2 AN3 stage C: the free crouch (out of cover) blends the locomotion toward the library crouch (the cover
	# crouch slots, UAL Crouch_Idle / Crouch_Fwd): idle and moving by ground speed, the move cycle normalized like the
	# gaits so its feet match the ground speed. SoldierModel drives crouch/blend_amount (0 = exactly as before).
	var crouch_idle := clips.resolve("cover_crouch_idle", null, skeleton)
	var crouch_move := clips.resolve("cover_crouch_move", null, skeleton)
	if crouch_idle != null and crouch_move != null:
		var crouch_gait := SoldierClips.gait(crouch_move, skeleton, false)
		library.add_animation("crouch_idle", crouch_idle)
		library.add_animation("crouch_move", crouch_gait["clip"])
		tree.set_meta(&"crouch_cycle_m", float(crouch_gait["cycle_m"]))  # none (0) = no crouch clips, no crouch nodes
		graph.add_node(&"crouch_idle", _node("crouch_idle"))
		graph.add_node(&"crouch_move", _gait_point("crouch_move"))
		graph.add_node(&"crouch_gait", AnimationNodeBlend2.new())
		graph.connect_node(&"crouch_gait", 0, &"crouch_idle")
		graph.connect_node(&"crouch_gait", 1, &"crouch_move")
		# The crouch blend sits between the aimed layer and the fire kick (connected below), filtered to the bones the
		# lower layer owns, so the aimed upper body, the graph's stand/upper links and every older path stay as they were.
		graph.add_node(&"crouch", AnimationNodeBlend2.new())
		graph.connect_node(&"crouch", 1, &"crouch_gait")
	if extras.has("jump_air"):
		lower.set_input_name(1, "air")
		graph.add_node(&"air", _node("jump_air"))
		graph.connect_node(&"lower", 1, &"air")
	var aim := AnimationNodeBlendSpace1D.new()
	aim.add_blend_point(_node("aim_down"), -1.0, -1, &"aim_down")
	aim.add_blend_point(_node("aim"), 0.0, -1, &"aim")
	aim.add_blend_point(_node("aim_up"), 1.0, -1, &"aim_up")
	graph.add_node(&"aim", aim)
	graph.add_node(&"fire_clip", _node("fire"))
	graph.add_node(&"reload_clip", _node("reload"))
	var upper := AnimationNodeBlend2.new()
	var fire := AnimationNodeOneShot.new()
	var reload := AnimationNodeOneShot.new()
	fire.mix_mode = AnimationNodeOneShot.MIX_MODE_ADD
	fire.fadein_time = float(upper_cfg["fade_in_s"])
	fire.fadeout_time = float(upper_cfg["fade_out_s"])
	reload.fadein_time = float(upper_cfg["fade_in_s"])
	reload.fadeout_time = float(upper_cfg["fade_out_s"])
	upper.filter_enabled = true
	fire.filter_enabled = true
	reload.filter_enabled = true
	# M2 AN1: the aimed layer owns the chest, arms and hands; the spine, neck and head keep the library body motion
	# (SoldierGait scales it) under the hands-on-the-gun arms. The additive fire kick still reaches every upper bone.
	var free_bones: Array = gait_cfg["upper_keeps_lower"]
	for i in skeleton.get_bone_count():
		var bone := String(skeleton.get_bone_name(i))
		# M2 AN2 item 2: the toes belong to the legs (the Blender clips bend them at the toe-off).
		if bone == "Hips" or bone.contains("Leg") or bone.contains("Foot") or bone.contains("Toes"):
			continue
		var path := NodePath("Skeleton3D:" + bone)
		upper.set_filter_path(path, not free_bones.has(bone))
		fire.set_filter_path(path, true)
		reload.set_filter_path(path, not free_bones.has(bone))
	graph.add_node(&"upper", upper)
	graph.add_node(&"fire", fire)
	graph.add_node(&"reload", reload)
	graph.connect_node(&"upper", 0, &"lower")
	graph.connect_node(&"upper", 1, &"aim")
	if graph.has_node(&"crouch"):
		var crouch_blend := graph.get_node(&"crouch") as AnimationNodeBlend2
		crouch_blend.filter_enabled = true
		for i in skeleton.get_bone_count():
			var bone := String(skeleton.get_bone_name(i))
			if bone == "Hips" or bone.contains("Leg") or bone.contains("Foot") or bone.contains("Toes") or free_bones.has(bone):
				crouch_blend.set_filter_path(NodePath("Skeleton3D:" + bone), true)
		graph.connect_node(&"crouch", 0, &"upper")
		graph.connect_node(&"fire", 0, &"crouch")
	else:
		graph.connect_node(&"fire", 0, &"upper")
	graph.connect_node(&"fire", 1, &"fire_clip")
	var before_reload := &"fire"
	if extras.has("hit_chest"):
		# M2 AN1: a flinch on top of everything above the hips (SoldierModel requests it when health or shield drops).
		var hit := AnimationNodeOneShot.new()
		hit.mix_mode = AnimationNodeOneShot.MIX_MODE_ADD
		hit.fadein_time = float(gait_cfg["hit"]["fade_in_s"])
		hit.fadeout_time = float(gait_cfg["hit"]["fade_out_s"])
		hit.filter_enabled = true
		for bone: String in gait_cfg["hit"]["bones"]:
			hit.set_filter_path(NodePath("Skeleton3D:" + bone), true)
		var which := AnimationNodeTransition.new()
		which.input_count = 2
		which.set_input_name(0, "chest")
		which.set_input_name(1, "head")
		graph.add_node(&"hit_chest", _node("hit_chest"))
		graph.add_node(&"hit_head", _node("hit_head" if extras.has("hit_head") else "hit_chest"))
		graph.add_node(&"hit_which", which)
		graph.connect_node(&"hit_which", 0, &"hit_chest")
		graph.connect_node(&"hit_which", 1, &"hit_head")
		graph.add_node(&"hit", hit)
		graph.connect_node(&"hit", 0, &"fire")
		graph.connect_node(&"hit", 1, &"hit_which")
		before_reload = &"hit"
	graph.connect_node(&"reload", 0, before_reload)
	graph.connect_node(&"reload", 1, &"reload_clip")
	graph.connect_node(&"output", 0, &"reload")
	tree.tree_root = graph
	tree.set("parameters/upper/blend_amount", 1.0)
	tree.active = true
	# Bake the slots other owners use (corpse, poses, cover) now, once, then drop the held source scene.
	for slot in SHARED_SLOTS:
		clips.resolve(slot, null, skeleton)
	# M2 AN3: the keyed reload of every gun the soldier can show (SoldierModel.play_reload picks one per reload).
	for gun: String in SoldierLook.config()["gun"]["weapons"]:
		clips.resolve("reload_" + gun, null, skeleton)
	ClipLibrary.release_sources()
	return tree


## M2 AN1: library slots used outside the graph (SoldierCorpse, SoldierPose, CoverAnim), baked with the graph.
## M2 AN2 items 3/5: the keyed clips (soldier_keyed.glb) CoverAnim and SoldierModel's action layer use.
const SHARED_SLOTS: Array[String] = ["death", "revive", "blade_swing", "cover_crouch_idle", "cover_crouch_move",
	"cover_idle_l", "cover_idle_r", "cover_idle_l_crouch", "cover_idle_r_crouch", "peek_left", "peek_right",
	"cover_enter", "cover_exit", "cover_enter_l", "cover_exit_l", "cover_rise",
	"ladder_up", "ladder_down", "ladder_top", "door_open", "chest_open", "pickup_ground"]
static var _additive: Dictionary = {}


## The shared baked clip of a library slot, or null when no library clip serves it (the caller keeps its own).
static func shared(slot: String, skeleton: Skeleton3D) -> Animation:
	var clips := ClipLibrary.new()
	var clip := clips.resolve(slot, null, skeleton)
	ClipLibrary.release_sources()
	return clip


## The flinch as a delta from its first frame, its rotations scaled by gait.hit.scale (the helmet stays locked
## on the head hitbox, so the torso and shoulders carry the whole reaction). Shared by every soldier.
static func _shared_additive(clip: Animation) -> Animation:
	var key := clip.get_instance_id()
	if not _additive.has(key):
		var delta := ClipLibrary.fit(clip, clip.length, Animation.LOOP_NONE, true)
		var scale := float(SoldierRig.config()["gait"]["hit"]["scale"])
		for track in delta.get_track_count():
			if delta.track_get_type(track) != Animation.TYPE_ROTATION_3D:
				continue
			for k in delta.track_get_key_count(track):
				var q: Quaternion = (delta.track_get_key_value(track, k) as Quaternion).normalized()
				var axis := Vector3(q.x, q.y, q.z)
				if axis.length() > 0.00001:
					delta.track_set_key_value(track, k, Quaternion(axis.normalized(), q.get_angle() * scale))
		_additive[key] = delta
	return _additive[key]


static func _locomotion(clip: String, cfg: Dictionary) -> Animation:
	var animation := Animation.new()
	animation.length = float(cfg["run_s"] if clip == "run_fwd" else cfg["idle_s"] if clip == "idle" else cfg["walk_s"])
	animation.loop_mode = Animation.LOOP_LINEAR
	var amplitude := deg_to_rad(float(cfg["run_hip_deg"] if clip == "run_fwd" else cfg["walk_hip_deg"]))
	var samples := int(cfg["samples"])
	for side in ["Left", "Right"]:
		for part in ["UpperLeg", "LowerLeg", "Foot"]:
			var track := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track, NodePath("Skeleton3D:" + side + part))
			for sample in samples + 1:
				var phase := TAU * sample / samples + (PI if side == "Right" else 0.0)
				var wave := sin(phase)
				var angle := wave * amplitude
				var axis := Vector3.FORWARD if clip.begins_with("strafe") and part == "UpperLeg" else Vector3.RIGHT
				if part == "LowerLeg":
					angle = -maxf(-wave, 0.0) * deg_to_rad(float(cfg["knee_deg"]))
				elif part == "Foot":
					angle = -wave * deg_to_rad(float(cfg["ankle_deg"]))
				if clip == "walk_back" or clip == "strafe_r":
					angle = -angle
				if clip == "idle":
					angle = 0.0
				animation.rotation_track_insert_key(track, animation.length * sample / samples, Quaternion(axis, angle))
	return animation


static func resolve_slot(clips: ClipLibrary, name: String, procedural: Animation, skeleton: Skeleton3D) -> Animation:
	var resolved := clips.resolve(name, procedural, skeleton)
	if clips.source_for(name) == "procedural":
		return procedural
	return ClipLibrary.fit(resolved, procedural.length, procedural.loop_mode, name == "fire")


## M2 AN3: the reload for the shown gun `gun` (a soldier.gun.weapons id): the Blender-keyed slot reload_<gun>
## (soldier_rifle.glb) when it resolves, scaled to the code-built clip's length (WeaponDef.reload_s) and cut to the
## code-built clip's tracks (the reload layer moves exactly the bones it moved before); otherwise the "reload" slot
## (the code-built `procedural`). `keyed` false: the code-built one even where a keyed one exists (tools, tests).
static func resolve_reload(clips: ClipLibrary, gun: String, procedural: Animation, skeleton: Skeleton3D, keyed: bool = true) -> Animation:
	var clip: Animation = clips.resolve("reload_" + gun, null, skeleton) if keyed else null
	if clip == null:
		return resolve_slot(clips, "reload", procedural, skeleton)
	var kept: Dictionary = {}
	for track in procedural.get_track_count():
		kept["%s|%d" % [procedural.track_get_path(track), procedural.track_get_type(track)]] = true
	var result := ClipLibrary.fit(clip, procedural.length, Animation.LOOP_NONE)
	for track in range(result.get_track_count() - 1, -1, -1):
		if not kept.has("%s|%d" % [result.track_get_path(track), result.track_get_type(track)]):
			result.remove_track(track)
	return result


static func _rotation_track(animation: Animation, bone: String, times: Array, values: Array[Quaternion]) -> void:
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, NodePath("Skeleton3D:" + bone))
	for i in times.size():
		animation.rotation_track_insert_key(track, float(times[i]), values[i])


static func aim_clip(skeleton: Skeleton3D, cfg: Dictionary, pitch: float) -> Animation:
	var animation := Animation.new()
	animation.length = float(SoldierRig.config()["locomotion"]["idle_s"])
	animation.loop_mode = Animation.LOOP_LINEAR
	for side in ["Left", "Right"]:
		var key: String = side.to_lower()
		var shift := shoulder_offset(side, cfg)
		var poses := SoldierRig.arm_rotations(skeleton, side, LowpolyKit.vec(cfg[key + "_hand_m"]) - shift, LowpolyKit.vec(cfg[key + "_pole"]), float(cfg["epsilon_m"]))
		for i in 3:
			_rotation_track(animation, side + ["UpperArm", "ForeArm", "Hand"][i], [0.0], [poses[i]])
		var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(position_track, NodePath("Skeleton3D:" + side + "UpperArm"))
		animation.position_track_insert_key(position_track, 0.0, skeleton.get_bone_rest(skeleton.find_bone(side + "UpperArm")).origin + shift)
	_rotation_track(animation, "Chest", [0.0], [Quaternion(Vector3.RIGHT, pitch * deg_to_rad(float(cfg["aim_pitch_limit_deg"])) )])
	return animation


static func shoulder_offset(side: String, cfg: Dictionary) -> Vector3:
	return Vector3(float(cfg["shoulder_inset_m"]) * (1.0 if side == "Left" else -1.0), -float(cfg["shoulder_drop_m"]), 0.0)


static func fire_clip(cfg: Dictionary) -> Animation:
	var animation := Animation.new()
	animation.length = float(DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]["viewmodel_recoil_recover_s"])
	for bone in ["Spine", "Chest", "LeftUpperArm", "RightUpperArm"]:
		var key := "fire_spine_deg" if bone == "Spine" else "fire_chest_deg" if bone == "Chest" else "fire_arm_deg"
		_rotation_track(animation, bone, [0.0, animation.length], [Quaternion(Vector3.RIGHT, deg_to_rad(float(cfg[key]))), Quaternion.IDENTITY])
	return animation


static func reload_clip(skeleton: Skeleton3D, duration: float, cfg: Dictionary) -> Animation:
	var animation := aim_clip(skeleton, cfg, 0.0)
	animation.loop_mode = Animation.LOOP_NONE
	animation.length = duration
	# M2 AN1 commit 4: staged reload, every stage a fraction of the weapon's own reload time (WeaponDef.reload_s):
	# the left hand goes to the magazine, pulls it out and down, reaches the belt pouch, seats the new one, runs
	# the charging handle and returns to the foregrip, while the right hand cants the rifle and the chest leans in
	# to watch. Keys: data/anim_third_person.json upper_body reload_* (OQ-ANIM placeholders).
	for i in range(animation.get_track_count() - 1, -1, -1):
		var path := String(animation.track_get_path(i))
		if animation.track_get_type(i) == Animation.TYPE_ROTATION_3D and (path.begins_with("Skeleton3D:Left") or path == "Skeleton3D:RightHand" or path == "Skeleton3D:Chest"):
			animation.remove_track(i)
	var fractions: Array = cfg["reload_key_fractions"]
	var offsets: Array = cfg["reload_left_offsets_m"]
	var times: Array = []
	for f in fractions:
		times.append(float(f) * duration)
	for bone in 3:
		var rotations: Array[Quaternion] = []
		for i in fractions.size():
			var target := LowpolyKit.vec(cfg["left_hand_m"]) - shoulder_offset("Left", cfg) + LowpolyKit.vec(offsets[i])
			var poses := SoldierRig.arm_rotations(skeleton, "Left", target, LowpolyKit.vec(cfg["left_pole"]), float(cfg["epsilon_m"]))
			rotations.append(poses[bone])
		_rotation_track(animation, "Left" + ["UpperArm", "ForeArm", "Hand"][bone], times, rotations)
	var right := SoldierRig.arm_rotations(skeleton, "Right", LowpolyKit.vec(cfg["right_hand_m"]) - shoulder_offset("Right", cfg), LowpolyKit.vec(cfg["right_pole"]), float(cfg["epsilon_m"]))
	var cants: Array[Quaternion] = []
	var leans: Array[Quaternion] = []
	for i in fractions.size():
		cants.append(right[2] * Quaternion(Vector3.FORWARD, deg_to_rad(float(cfg["reload_cant_deg"][i]))))
		leans.append(Quaternion(Vector3.RIGHT, deg_to_rad(float(cfg["reload_chest_deg"][i]))))
	_rotation_track(animation, "RightHand", times, cants)
	_rotation_track(animation, "Chest", times, leans)
	return animation
