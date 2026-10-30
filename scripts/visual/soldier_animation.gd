class_name SoldierAnimation
extends RefCounted
## Clip names and graph parameters remain independent of the procedural mesh.

static func _node(clip: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	return node


static func build(skeleton: Skeleton3D, sprint: float, reload_s: float) -> AnimationTree:
	var cfg: Dictionary = SoldierRig.config()["locomotion"]
	var library := AnimationLibrary.new()
	for clip in ["idle", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd"]:
		library.add_animation(clip, _locomotion(clip, cfg))
	var upper_cfg: Dictionary = SoldierRig.config()["upper_body"]
	for name in ["aim_down", "aim", "aim_up"]:
		var pitch := -1.0 if name == "aim_down" else 1.0 if name == "aim_up" else 0.0
		library.add_animation(name, aim_clip(skeleton, upper_cfg, pitch))
	library.add_animation("fire", fire_clip(upper_cfg))
	library.add_animation("reload", reload_clip(skeleton, reload_s, upper_cfg))
	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	tree.root_node = NodePath("..")
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	tree.add_animation_library(&"", library)
	var graph := AnimationNodeBlendTree.new()
	var move := AnimationNodeBlendSpace2D.new()
	move.min_space = Vector2(-1.0, -sprint)
	move.max_space = Vector2.ONE
	move.add_blend_point(_node("idle"), Vector2.ZERO, -1, &"idle")
	move.add_blend_point(_node("walk_fwd"), Vector2(0, -1), -1, &"walk_fwd")
	move.add_blend_point(_node("walk_back"), Vector2(0, 1), -1, &"walk_back")
	move.add_blend_point(_node("strafe_l"), Vector2(-1, 0), -1, &"strafe_l")
	move.add_blend_point(_node("strafe_r"), Vector2(1, 0), -1, &"strafe_r")
	move.add_blend_point(_node("run_fwd"), Vector2(0, -sprint), -1, &"run_fwd")
	graph.add_node(&"locomotion", move)
	# Keep the public BlendSpace2D live at its original parameter path.
	var lower := AnimationNodeTransition.new()
	lower.input_count = 1
	lower.set_input_name(0, "stand")
	lower.xfade_time = float(SoldierRig.config()["layers"]["lower_xfade_s"])
	graph.add_node(&"lower", lower)
	graph.connect_node(&"lower", 0, &"locomotion")
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
	for i in skeleton.get_bone_count():
		var bone := String(skeleton.get_bone_name(i))
		if bone == "Hips" or bone.contains("Leg") or bone.contains("Foot"):
			continue
		var path := NodePath("Skeleton3D:" + bone)
		upper.set_filter_path(path, true)
		fire.set_filter_path(path, true)
		reload.set_filter_path(path, true)
	graph.add_node(&"upper", upper)
	graph.add_node(&"fire", fire)
	graph.add_node(&"reload", reload)
	graph.connect_node(&"upper", 0, &"lower")
	graph.connect_node(&"upper", 1, &"aim")
	graph.connect_node(&"fire", 0, &"upper")
	graph.connect_node(&"fire", 1, &"fire_clip")
	graph.connect_node(&"reload", 0, &"fire")
	graph.connect_node(&"reload", 1, &"reload_clip")
	graph.connect_node(&"output", 0, &"reload")
	tree.tree_root = graph
	tree.set("parameters/upper/blend_amount", 1.0)
	tree.active = true
	return tree


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
	# Replace the left arm's static aim tracks with a magazine reach and return.
	for i in range(animation.get_track_count() - 1, -1, -1):
		if animation.track_get_type(i) == Animation.TYPE_ROTATION_3D and String(animation.track_get_path(i)).begins_with("Skeleton3D:Left"):
			animation.remove_track(i)
	var fractions: Array = cfg["reload_key_fractions"]
	for bone in 3:
		var times: Array = []
		var rotations: Array[Quaternion] = []
		for i in fractions.size():
			var target := LowpolyKit.vec(cfg["left_hand_m"]) - shoulder_offset("Left", cfg) + LowpolyKit.vec(cfg["reload_hand_offset_m"]) * float(cfg["reload_key_weights"][i])
			var poses := SoldierRig.arm_rotations(skeleton, "Left", target, LowpolyKit.vec(cfg["left_pole"]), float(cfg["epsilon_m"]))
			times.append(float(fractions[i]) * duration)
			rotations.append(poses[bone])
		_rotation_track(animation, "Left" + ["UpperArm", "ForeArm", "Hand"][bone], times, rotations)
	return animation
