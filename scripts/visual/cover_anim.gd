class_name CoverAnim
extends Node
## Local presentation only. The controller never rotates the Pawn or camera (M2 C1b: the pawn's own automatic look
## turn on entry lives in pawn.gd _tick_cover_turn, not here).
const NAMES: Array[String] = ["cover_enter", "cover_idle_l", "cover_idle_r", "peek_left", "peek_right", "cover_exit"]
## M2 AN2 items 3/5: states whose keyed clip depends on CoverController.side (the left one is the mirrored clip); the
## state's animation nodes are pointed at "<name>@l" while side < 0.
const SIDED: Array[String] = ["cover_enter", "cover_exit"]
## The upper-body bones the hug's rest layer takes from the keyed hug clip (never the Neck: it stays on the head hitbox).
const REST_BONES: Array[String] = ["Chest", "Head", "LeftUpperArm", "LeftForeArm", "LeftHand", "LeftFingers", "RightUpperArm", "RightForeArm", "RightHand", "RightFingers"]
var pawn: Pawn
var model: SoldierModel
var tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
var _cfg: Dictionary
var _last := ""
var _rest_yaw := 0.0
## Slots that resolved to a keyed (Blender) clip, e.g. "cover_idle_r" -> true (tests, captures).
var keyed: Dictionary = {}
var _side := 1
var _sided_nodes: Array = []  # [AnimationNodeAnimation, base animation name]
var _rest_keyed := false
var _rise := false
## M2 AN3 tools only (tools/head_motion_measure.gd): true keeps the keyed clips' own Neck tracks instead of the hitbox
## pin, to measure the pin's share. False (the shipped default) changes nothing.
static var measure_clip_neck := false
var _mix_shown := 0.0  # M2 AN3: cover_mix as shown (faded)
var _rest_shown := 0.0  # M2 AN3: cover_rest_mix as shown (faded)

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
	# M2 AN2: the risen fire stance the idle states blend to by aim_out_amount (keyed clip only).
	var rise := _keyed_clip("cover_rise", "cover_idle_r", false)
	_rise = rise != null
	if _rise:
		library.add_animation(&"cover_rise", rise)
	for name in NAMES:
		library.add_animation(name, _clip(name))
		library.add_animation(name + "_crouch", _clip(name, true))
		if SIDED.has(name):
			library.add_animation(name + "@l", _clip(name, false, -1))
			library.add_animation(name + "_crouch@l", _clip(name, true, -1))
		var pose := AnimationNodeBlendTree.new()
		var animation := AnimationNodeAnimation.new()
		animation.animation = name
		pose.add_node(&"standing", animation)
		var crouch := AnimationNodeAnimation.new()
		crouch.animation = name + "_crouch"
		pose.add_node(&"crouched", crouch)
		if SIDED.has(name):
			_sided_nodes.append([animation, name])
			_sided_nodes.append([crouch, name + "_crouch"])
		pose.add_node(&"crouch", AnimationNodeBlend2.new())
		if _rise and name.begins_with("cover_idle"):
			var risen := AnimationNodeAnimation.new()
			risen.animation = &"cover_rise"
			pose.add_node(&"risen", risen)
			pose.add_node(&"aim", AnimationNodeBlend2.new())
			pose.connect_node(&"aim", 0, &"standing")
			pose.connect_node(&"aim", 1, &"risen")
			pose.connect_node(&"crouch", 0, &"aim")
		else:
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
	for bone in ["Hips", "Neck", "Spine"]:  # Spine: the peek lean (M2 AN1 commit 4)
		mix.set_filter_path(NodePath("Skeleton3D:" + bone), true)
	if not keyed.is_empty():
		# M2 AN2: the keyed clips plant the feet with their own turn (the gait's leg solve keeps their positions).
		for bone in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
			mix.set_filter_path(NodePath("Skeleton3D:" + bone), true)
	graph.add_node(&"cover_mix", mix)
	graph.disconnect_node(&"output", 0)
	graph.connect_node(&"cover_mix", 0, &"reload")
	graph.connect_node(&"cover_mix", 1, &"cover")
	# A separate upper-body rest layer fades away with the controller's lean.
	# Left-hand IK continues to follow the existing right-hand-mounted rifle.
	if _build_keyed_rest(graph, library):
		return
	var rest_clip := Animation.new()
	rest_clip.length = float(_cfg["animation"]["idle_s"])
	rest_clip.loop_mode = Animation.LOOP_LINEAR
	var rest_mix := AnimationNodeBlend2.new()
	rest_mix.filter_enabled = true
	# M2 AN1 commit 6: the hugging soldier's arms come from data/anim_third_person.json cover.rest_upper_pose_deg when
	# it is there (the gun at a low ready angle against the wall), else from data/cover.json as before.
	var rest_pose: Dictionary = (SoldierRig.config()["cover"] as Dictionary).get("rest_upper_pose_deg", _cfg["animation"]["rest_upper_pose_deg"])
	for bone: String in rest_pose:
		if bone.begins_with("_"):
			continue
		var path := NodePath("Skeleton3D:" + bone)
		rest_mix.set_filter_path(path, true)
		var angles: Array = rest_pose[bone]
		var rotation := Quaternion.from_euler(Vector3(deg_to_rad(float(angles[0])), deg_to_rad(float(angles[1])), deg_to_rad(float(angles[2]))))
		var track := rest_clip.add_track(Animation.TYPE_ROTATION_3D)
		rest_clip.track_set_path(track, path)
		rest_clip.rotation_track_insert_key(track, 0.0, rotation)
		rest_clip.rotation_track_insert_key(track, rest_clip.length, rotation)
	library.add_animation(&"cover_rest_upper", rest_clip)
	var rest_animation := AnimationNodeAnimation.new()
	rest_animation.animation = &"cover_rest_upper"
	graph.add_node(&"cover_rest_upper", rest_animation)
	graph.add_node(&"cover_rest_mix", rest_mix)
	graph.connect_node(&"cover_rest_mix", 0, &"cover_mix")
	graph.connect_node(&"cover_rest_mix", 1, &"cover_rest_upper")
	graph.connect_node(&"output", 0, &"cover_rest_mix")
	_finish_graph()


func _finish_graph() -> void:
	tree.set("parameters/cover_mix/blend_amount", 0.0)
	tree.set("parameters/cover_rest_mix/blend_amount", 0.0)
	playback = tree.get("parameters/cover/playback")
	playback.start(&"cover_idle_r")


## M2 AN2: the hug's upper body (port arms at the wall, the chest and head) from the keyed hug clips, standing and
## crouched blended by crouch_amount, the left or right clip by side; it fades with aim_out_amount as before. False
## (and nothing built) when the hug clips are not keyed: the data rest pose below stays the fallback.
func _build_keyed_rest(graph: AnimationNodeBlendTree, library: AnimationLibrary) -> bool:
	if not (keyed.has("cover_idle_r") and keyed.has("cover_idle_l") and keyed.has("cover_idle_r_crouch") and keyed.has("cover_idle_l_crouch")):
		return false
	_rest_keyed = true
	var rest_mix := AnimationNodeBlend2.new()
	rest_mix.filter_enabled = true
	for bone in REST_BONES:
		if model.skeleton.find_bone(bone) >= 0:
			rest_mix.set_filter_path(NodePath("Skeleton3D:" + bone), true)
	for pair in [["cover_rest_upper", "cover_idle_r"], ["cover_rest_upper@l", "cover_idle_l"], ["cover_rest_upper_crouch", "cover_idle_r_crouch"], ["cover_rest_upper_crouch@l", "cover_idle_l_crouch"]]:
		library.add_animation(StringName(pair[0]), _upper_only(library.get_animation(StringName(pair[1]))))
	var rest := AnimationNodeBlendTree.new()
	var stand := AnimationNodeAnimation.new()
	stand.animation = &"cover_rest_upper"
	var low := AnimationNodeAnimation.new()
	low.animation = &"cover_rest_upper_crouch"
	rest.add_node(&"standing", stand)
	rest.add_node(&"crouched", low)
	rest.add_node(&"crouch", AnimationNodeBlend2.new())
	rest.connect_node(&"crouch", 0, &"standing")
	rest.connect_node(&"crouch", 1, &"crouched")
	rest.connect_node(&"output", 0, &"crouch")
	_sided_nodes.append([stand, "cover_rest_upper"])
	_sided_nodes.append([low, "cover_rest_upper_crouch"])
	graph.add_node(&"cover_rest_upper", rest)
	graph.add_node(&"cover_rest_mix", rest_mix)
	graph.connect_node(&"cover_rest_mix", 0, &"cover_mix")
	graph.connect_node(&"cover_rest_mix", 1, &"cover_rest_upper")
	graph.connect_node(&"output", 0, &"cover_rest_mix")
	_finish_graph()
	return true


func _upper_only(source: Animation) -> Animation:
	var clip := source.duplicate_deep() as Animation
	for i in range(clip.get_track_count() - 1, -1, -1):
		var bone := String(clip.track_get_path(i).get_concatenated_subnames())
		if clip.track_get_type(i) != Animation.TYPE_ROTATION_3D or not REST_BONES.has(bone):
			clip.remove_track(i)
	return clip


## M2 AN2: the keyed clip of `slot` adapted to this pawn's cover heights, or null (the procedural clip is built).
## The pelvis keeps the clip's motion but sits at CoverAnim's crouched height when crouched; the Neck stays where the
## procedural clips put it (on the head hitbox: rest, or lowered by the crouch) and never turns (the head keeps its
## own turn, which does not move the helmet off the hitbox).
func _keyed_clip(slot: String, state: String, crouched: bool) -> Animation:
	var source := SoldierAnimation.shared(slot, model.skeleton)
	if source == null:
		return null
	keyed[slot] = true
	var clip: Animation
	if state == "cover_enter" and not crouched:
		clip = ClipLibrary.fit(source, float(_cfg["enter_s"]), Animation.LOOP_NONE)
	elif state == "cover_exit" and not crouched:
		clip = ClipLibrary.fit(source, float(_cfg["exit_s"]), Animation.LOOP_NONE)
	else:
		clip = source.duplicate_deep() as Animation
	var neck_at := model.skeleton.get_bone_rest(model.skeleton.find_bone("Neck")).origin
	var lift := 0.0
	if crouched:
		neck_at.y -= pawn.cover_standing_head_y() - float(_cfg["crouch_head_y_m"])
		var hips_rest := model.skeleton.get_bone_rest(model.skeleton.find_bone("Hips")).origin
		var keyed_cfg: Dictionary = SoldierRig.config().get("keyed", {})
		var cover_cfg: Dictionary = keyed_cfg.get("cover", {})
		var nominal := float(cover_cfg.get("crouch_hips_y_m", hips_rest.y))
		lift = (hips_rest.y - (pawn.cover_standing_height() - float(_cfg["crouch_height_m"]))) - nominal
	for i in range(clip.get_track_count() - 1, -1, -1):
		var bone := String(clip.track_get_path(i).get_concatenated_subnames())
		if bone == "Neck":
			if not measure_clip_neck:
				clip.remove_track(i)
		elif bone == "Hips" and clip.track_get_type(i) == Animation.TYPE_POSITION_3D and lift != 0.0:
			for k in clip.track_get_key_count(i):
				clip.track_set_key_value(i, k, (clip.track_get_key_value(i, k) as Vector3) + Vector3(0.0, lift, 0.0))
	if measure_clip_neck:
		return clip
	var track := clip.add_track(Animation.TYPE_POSITION_3D)
	clip.track_set_path(track, NodePath("Skeleton3D:Neck"))
	clip.position_track_insert_key(track, 0.0, neck_at)
	clip.position_track_insert_key(track, clip.length, neck_at)
	return clip


## The keyed slot that serves a state (side -1: the mirrored one), or "" (procedural).
static func keyed_slot(name: String, crouched: bool, side: int) -> String:
	if not crouched:
		if SIDED.has(name):
			return name + ("_l" if side < 0 else "")
		return name
	if name.begins_with("cover_idle"):
		return name + "_crouch"
	if SIDED.has(name):
		return "cover_idle_l_crouch" if side < 0 else "cover_idle_r_crouch"
	return ""


func _clip(name: String, crouched: bool = false, side: int = 1) -> Animation:
	var slot := keyed_slot(name, crouched, side)
	if not slot.is_empty():
		var keyed_clip := _keyed_clip(slot, name, crouched)
		if keyed_clip != null:
			return keyed_clip
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
	var look: Dictionary = SoldierRig.config()["cover"]
	if name.begins_with("peek_"):
		# M2 AN1 commit 4: a real lean-out: the spine rolls toward the peek side (the head stays on its hitbox).
		var track := clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(track, NodePath("Skeleton3D:Spine"))
		var lean := Quaternion(Vector3.BACK, deg_to_rad(float(look["peek_lean_deg"])) * (1.0 if name == "peek_left" else -1.0))
		clip.rotation_track_insert_key(track, 0.0, lean)
		clip.rotation_track_insert_key(track, duration, lean)
	if crouched:
		pose = _cfg["animation"]["crouch_pose_deg"]
		var library := SoldierAnimation.shared("cover_crouch_idle", model.skeleton)
		if library != null:
			# M2 AN1 commit 4: the crouched legs and pelvis are the library's crouch (UAL Crouch_Idle) at its
			# hold_s frame; SoldierGait bends the knees further so the boots stay on the floor at the lower,
			# hitbox-matched pelvis height below.
			for bone: String in look["crouch_bones"]:
				var source := library.find_track(NodePath("Skeleton3D:" + bone), Animation.TYPE_ROTATION_3D)
				if source < 0:
					continue
				var track := clip.add_track(Animation.TYPE_ROTATION_3D)
				clip.track_set_path(track, NodePath("Skeleton3D:" + bone))
				var held := library.rotation_track_interpolate(source, float(look["crouch_hold_s"]))
				clip.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY if name == "cover_enter" else held)
				clip.rotation_track_insert_key(track, duration, Quaternion.IDENTITY if name == "cover_exit" else held)
			pose = []
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

## M2 AN3: the cover layer and the hug's rest layer move toward their targets over head.cover_mix_fade_s /
## cover_rest_fade_s (one-frame snaps under SoldierRig.head_legacy, as before).
func _fade_mixes(head: Dictionary, mix: float, rest: float, delta: float) -> void:
	if head.is_empty():
		_mix_shown = mix
		_rest_shown = rest
	else:
		var mix_s := float(head["cover_mix_fade_s"])
		var rest_s := float(head["cover_rest_fade_s"])
		_mix_shown = move_toward(_mix_shown, mix, delta / mix_s) if mix_s > 0.0 else mix
		_rest_shown = move_toward(_rest_shown, rest, delta / rest_s) if rest_s > 0.0 else rest
	tree.set("parameters/cover_mix/blend_amount", _mix_shown)
	tree.set("parameters/cover_rest_mix/blend_amount", _rest_shown)


func sync_pose(delta: float) -> void:
	if tree == null:
		return
	var controller := pawn.cover
	var amount := controller.crouch_amount if controller != null else 0.0
	for state in NAMES:
		tree.set("parameters/cover/" + state + "/crouch/blend_amount", amount)
	if _rest_keyed:
		tree.set("parameters/cover_rest_upper/crouch/blend_amount", amount)
	if _rise:
		var out := controller.aim_out_amount if controller != null else 0.0
		for state in ["cover_idle_l", "cover_idle_r"]:
			tree.set("parameters/cover/" + state + "/aim/blend_amount", out)
	# M2 AN2: the side-dependent keyed clips (enter, exit, the hug's upper body) follow the controller's side.
	var side := (-1 if controller.side < 0 else 1) if controller != null else _side
	if side != _side:
		_side = side
		for pair: Array in _sided_nodes:
			(pair[0] as AnimationNodeAnimation).animation = StringName(String(pair[1]) + ("@l" if side < 0 else ""))
	var name := "" if controller == null else state_clip(controller.state, controller.side)
	var head := SoldierRig.head_cfg()
	if name.is_empty():
		_fade_mixes(head, 0.0, 0.0, delta)
		model.gait.cover_crouch = amount * _mix_shown
		# M2 AN2: on a ladder (and stepping off its top) the model turns itself to face the ladder.
		if not model.owns_yaw():
			model.rotation.y = _rest_yaw
		_last = ""
		return
	var resting := controller.state == CoverController.State.IN_COVER or controller.state == CoverController.State.ENTERING
	# M2 AN3: the hug's rest layer follows 1 - aim_out in the lean states too (it snapped off in one frame there).
	var leaning := controller.state == CoverController.State.PEEK_LEFT or controller.state == CoverController.State.PEEK_RIGHT
	var rest := 1.0 - controller.aim_out_amount if resting or (leaning and not head.is_empty()) else 0.0
	_fade_mixes(head, 1.0, rest, delta)
	model.gait.cover_crouch = amount * _mix_shown
	if playback.get_current_node() == &"Start" or String(playback.get_current_node()).is_empty():
		playback.start(name)
		_last = name
	elif name != _last:
		playback.travel(name)
		_last = name
	var yaw := _rest_yaw
	if (controller.state == CoverController.State.IN_COVER or controller.state == CoverController.State.ENTERING) and controller.aim_out_amount == 0.0:
		# M2 C1b stage 2: hug the wall, facing along it toward the cover side, turned out by hug_out_deg (back and
		# shoulder to the wall), like the reference; only this visual model turns.
		var out := deg_to_rad(float(_cfg["animation"].get("hug_out_deg", 90.0)))
		var forward := controller.tangent * float(controller.side) * cos(out) + controller.normal * sin(out)
		yaw += atan2(-forward.x, -forward.z) - pawn.global_rotation.y
	var step := deg_to_rad(float(_cfg["animation"]["visual_turn_deg_s"])) * delta
	model.rotation.y += clampf(angle_difference(model.rotation.y, yaw), -step, step)
