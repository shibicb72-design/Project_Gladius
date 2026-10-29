class_name CoverAnim
extends Node
## Local presentation only. The controller never rotates the Pawn or camera.
const NAMES: Array[String] = ["cover_enter", "cover_idle_l", "cover_idle_r", "peek_left", "peek_right", "cover_exit"]
var pawn: Pawn
var model: SoldierModel
var tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
var _cfg: Dictionary
var _last := ""
var _rest_yaw := 0.0

static func state_clip(state: CoverController.State, side: int) -> String:
	match state:
		CoverController.State.ENTERING: return "cover_enter"
		CoverController.State.IN_COVER: return "cover_idle_l" if side < 0 else "cover_idle_r"
		CoverController.State.PEEK_LEFT: return "peek_left"
		CoverController.State.PEEK_RIGHT: return "peek_right"
		CoverController.State.EXITING: return "cover_exit"
	return ""

func _ready() -> void:
	pawn = get_parent() as Pawn
	model = pawn.get_node_or_null("SoldierModel") as SoldierModel
	if model == null or pawn.cover == null:
		set_process(false)
		return
	tree = model.animation_tree
	_cfg = pawn.cover.config
	_rest_yaw = model.rotation.y
	_build_graph()

func _build_graph() -> void:
	var graph := tree.tree_root as AnimationNodeBlendTree
	var library := tree.get_animation_library(&"")
	var machine := AnimationNodeStateMachine.new()
	for name in NAMES:
		library.add_animation(name, _clip(name))
		library.add_animation(name + "_crouch", _clip(name, true))
		var pose := AnimationNodeBlendTree.new()
		var animation := AnimationNodeAnimation.new()
		animation.animation = name
		pose.add_node(&"standing", animation)
		var crouch := AnimationNodeAnimation.new()
		crouch.animation = name + "_crouch"
		pose.add_node(&"crouched", crouch)
		pose.add_node(&"crouch", AnimationNodeBlend2.new())
		pose.connect_node(&"crouch", 0, &"standing")
		pose.connect_node(&"crouch", 1, &"crouched")
		pose.connect_node(&"output", 0, &"crouch")
		machine.add_node(name, pose)
	for from in NAMES:
		for to in NAMES:
			if from == to:
				continue
			var transition := AnimationNodeStateMachineTransition.new()
			transition.xfade_time = float(_cfg["animation"]["xfade_s"])
			machine.add_transition(from, to, transition)
	graph.add_node(&"cover", machine)
	var mix := AnimationNodeBlend2.new()
	# Only leg poses are replaced. Existing aimed arms, hands, fire/reload and head stay intact.
	mix.filter_enabled = true
	for bone: String in _cfg["animation"]["bones"]:
		mix.set_filter_path(NodePath("Skeleton3D:" + bone), true)
	for bone in ["Hips", "Neck"]:
		mix.set_filter_path(NodePath("Skeleton3D:" + bone), true)
	graph.add_node(&"cover_mix", mix)
	graph.disconnect_node(&"output", 0)
	graph.connect_node(&"cover_mix", 0, &"reload")
	graph.connect_node(&"cover_mix", 1, &"cover")
	graph.connect_node(&"output", 0, &"cover_mix")
	tree.set("parameters/cover_mix/blend_amount", 0.0)
	playback = tree.get("parameters/cover/playback")
	playback.start(&"cover_idle_r")

func _clip(name: String, crouched: bool = false) -> Animation:
	var clip := Animation.new()
	var duration := float(_cfg["animation"]["idle_s"])
	if name == "cover_enter":
		duration = float(_cfg["enter_s"])
	elif name == "cover_exit":
		duration = float(_cfg["exit_s"])
	elif name.begins_with("peek_"):
		duration = float(_cfg["peek_s"])
	clip.length = duration
	clip.loop_mode = Animation.LOOP_LINEAR if name.contains("idle") or name.begins_with("peek") else Animation.LOOP_NONE
	var pose: Array = _cfg["animation"]["poses_deg"][name]
	if crouched:
		pose = _cfg["animation"]["crouch_pose_deg"]
	for i in pose.size():
		var track := clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(track, NodePath("Skeleton3D:" + String(_cfg["animation"]["bones"][i])))
		var rotation := Quaternion(Vector3.RIGHT, deg_to_rad(float(pose[i])))
		clip.rotation_track_insert_key(track, 0, Quaternion.IDENTITY if name == "cover_enter" else rotation)
		clip.rotation_track_insert_key(track, duration, Quaternion.IDENTITY if name == "cover_exit" else rotation)
	for bone in ["Hips", "Neck"]:
		var index := model.skeleton.find_bone(bone)
		var at := model.skeleton.get_bone_rest(index).origin
		if crouched:
			at.y -= pawn.cover_standing_height() - float(_cfg["crouch_height_m"]) if bone == "Hips" else pawn.cover_standing_head_y() - float(_cfg["crouch_head_y_m"])
		var track := clip.add_track(Animation.TYPE_POSITION_3D)
		clip.track_set_path(track, NodePath("Skeleton3D:" + bone))
		clip.position_track_insert_key(track, 0.0, at)
		clip.position_track_insert_key(track, duration, at)
	return clip

func _process(delta: float) -> void:
	sync_pose(delta)

func sync_pose(delta: float) -> void:
	if tree == null:
		return
	var controller := pawn.cover
	var amount := controller.crouch_amount if controller != null else 0.0
	for state in NAMES:
		tree.set("parameters/cover/" + state + "/crouch/blend_amount", amount)
	var name := "" if controller == null else state_clip(controller.state, controller.side)
	if name.is_empty():
		tree.set("parameters/cover_mix/blend_amount", 0.0)
		model.rotation.y = _rest_yaw
		_last = ""
		return
	tree.set("parameters/cover_mix/blend_amount", 1.0)
	if playback.get_current_node() == &"Start" or String(playback.get_current_node()).is_empty():
		playback.start(name)
		_last = name
	elif name != _last:
		playback.travel(name)
		_last = name
	var yaw := _rest_yaw
	if (controller.state == CoverController.State.IN_COVER or controller.state == CoverController.State.ENTERING) and controller.aim_out_amount == 0.0:
		var forward := -controller.normal
		yaw += atan2(-forward.x, -forward.z) + controller.side * PI * 0.5 - pawn.global_rotation.y
	var step := deg_to_rad(float(_cfg["animation"]["visual_turn_deg_s"])) * delta
	model.rotation.y += clampf(angle_difference(model.rotation.y, yaw), -step, step)
