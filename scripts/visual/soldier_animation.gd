class_name SoldierAnimation
extends RefCounted
## Clip names and graph parameters remain independent of the procedural mesh.

static func _node(clip: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	return node


static func build(skeleton: Skeleton3D, sprint: float) -> AnimationTree:
	var cfg: Dictionary = SoldierRig.config()["locomotion"]
	var library := AnimationLibrary.new()
	for clip in ["idle", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd"]:
		library.add_animation(clip, _locomotion(clip, cfg))
	# Neutral upper-body placeholders are replaced by the aim/fire/reload presentation slice.
	for clip in ["aim", "fire", "reload"]:
		var neutral := Animation.new()
		neutral.length = float(cfg["idle_s"])
		library.add_animation(clip, neutral)
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
	graph.add_node(&"aim", _node("aim"))
	graph.add_node(&"fire_clip", _node("fire"))
	graph.add_node(&"reload_clip", _node("reload"))
	var upper := AnimationNodeBlend2.new()
	var fire := AnimationNodeOneShot.new()
	var reload := AnimationNodeOneShot.new()
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
	graph.connect_node(&"upper", 0, &"locomotion")
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
