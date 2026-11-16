extends "res://tests/test_case.gd"
## M2 AN2 items 3 and 5: assets/generated/characters/soldier_keyed.glb (tools/blender/build_soldier_keyed.py), the
## hand-keyed clips. The file has exactly one skeleton whose bones and rests are the runtime skeleton's and no mesh;
## every shipped clip is there with a sane length and the loops close; the wired slots resolve to the "blender" source;
## CoverAnim builds its states from them (the head stays on the hitbox: tests/test_cover_*.gd); SoldierModel plays the
## ladder clips from pawn.climbing (gun slung, back after), the top step, and play_action one-shots that end and give
## the body back.

const GLB := "res://assets/generated/characters/soldier_keyed.glb"
## clip -> loops (names as Godot sees them: the importer drops _Loop and loops those).
const CLIPS := {"cover_hug_high": true, "cover_hug_high_l": true, "cover_hug_low": true, "cover_hug_low_l": true,
	"cover_lean_right": true, "cover_lean_left": true, "cover_rise": true, "cover_enter": false, "cover_enter_l": false,
	"cover_exit": false, "cover_exit_l": false, "ladder_up": true, "ladder_down": true, "ladder_top": false,
	"door_open": false, "chest_open": false, "pickup_ground": false}
## Slots wired to the keyed clips.
const SLOTS: Array[String] = ["cover_idle_r", "cover_idle_l", "cover_idle_r_crouch", "cover_idle_l_crouch", "peek_left",
	"peek_right", "cover_enter", "cover_exit", "cover_enter_l", "cover_exit_l", "cover_rise", "ladder_up", "ladder_down",
	"ladder_top", "door_open", "chest_open", "pickup_ground"]
const SEAM_DEG := 0.5
const SEAM_M := 0.001
const DT := 1.0 / 30.0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _pawn() -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func _source() -> Dictionary:
	var instance: Node = (load(GLB) as PackedScene).instantiate()
	var players := instance.find_children("*", "AnimationPlayer", true, false)
	return {"node": instance, "skeletons": instance.find_children("*", "Skeleton3D", true, false),
		"meshes": instance.find_children("*", "MeshInstance3D", true, false), "player": players[0] if players.size() == 1 else null}


func _angle_deg(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.normalized().dot(b.normalized())), 0.0, 1.0)))


func test_one_skeleton_with_the_runtime_rests_no_mesh_and_every_clip() -> void:
	var pawn := _pawn()
	var target := (pawn.get_node("SoldierModel") as SoldierModel).skeleton
	var src := _source()
	assert_eq((src["skeletons"] as Array).size(), 1, "exactly one skeleton in soldier_keyed.glb")
	assert_eq((src["meshes"] as Array).size(), 0, "no mesh in soldier_keyed.glb")
	var skeleton: Skeleton3D = src["skeletons"][0]
	assert_eq(skeleton.get_bone_count(), target.get_bone_count(), "the soldier's 22 bones")
	var worst := 0.0
	for i in target.get_bone_count():
		var j := skeleton.find_bone(target.get_bone_name(i))
		assert_true(j >= 0, "bone %s in the clip file" % target.get_bone_name(i))
		if j < 0:
			continue
		worst = maxf(worst, skeleton.get_bone_global_rest(j).origin.distance_to(target.get_bone_global_rest(i).origin))
		assert_true(skeleton.get_bone_rest(j).basis.is_equal_approx(Basis.IDENTITY), "identity rest basis: %s" % target.get_bone_name(i))
	print("SOLDIER_KEYED_GLB bones=%d rest_err_m=%.6f" % [skeleton.get_bone_count(), worst])
	assert_true(worst <= 0.001, "rests equal the runtime skeleton's within 1 mm (%.6f m)" % worst)
	assert_true(AnimRetarget.same_rig(skeleton, target), "AnimRetarget.same_rig accepts the file")
	var player: AnimationPlayer = src["player"]
	assert_true(player != null, "one AnimationPlayer")
	for clip: String in CLIPS:
		assert_true(player.has_animation(clip), "clip %s" % clip)
		if not player.has_animation(clip):
			continue
		var anim := player.get_animation(clip)
		assert_true(anim.length >= 0.3 and anim.length <= 6.0, "%s: sane length %.3f s" % [clip, anim.length])
		assert_eq(anim.loop_mode == Animation.LOOP_LINEAR, bool(CLIPS[clip]), "%s loops: %s" % [clip, CLIPS[clip]])
	(src["node"] as Node).free()
	pawn.free()


func test_looping_clips_close() -> void:
	var src := _source()
	var player: AnimationPlayer = src["player"]
	for clip: String in CLIPS:
		if not bool(CLIPS[clip]):
			continue
		var anim := player.get_animation(clip)
		var rot := 0.0
		var pos := 0.0
		for t in anim.get_track_count():
			match anim.track_get_type(t):
				Animation.TYPE_ROTATION_3D:
					rot = maxf(rot, _angle_deg(anim.rotation_track_interpolate(t, 0.0), anim.rotation_track_interpolate(t, anim.length)))
				Animation.TYPE_POSITION_3D:
					pos = maxf(pos, anim.position_track_interpolate(t, 0.0).distance_to(anim.position_track_interpolate(t, anim.length)))
		print("SOLDIER_KEYED_SEAM %s rot_deg=%.4f pos_m=%.5f" % [clip, rot, pos])
		assert_true(rot <= SEAM_DEG and pos <= SEAM_M, "%s closes: %.3f deg, %.4f m" % [clip, rot, pos])
	(src["node"] as Node).free()


func test_wired_slots_resolve_to_the_blender_clips_and_cover_uses_them() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	var library := ClipLibrary.new()
	for slot in SLOTS:
		var clip := library.resolve(slot, Animation.new(), model.skeleton)
		assert_eq(library.source_for(slot), "blender", "%s resolves to the keyed clips" % slot)
		assert_true(clip != null and clip.length > 0.0, "%s has a clip" % slot)
	pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var presentation := pawn.get_node("CoverAnim") as CoverAnim
	for slot in ["cover_idle_r", "cover_idle_l", "cover_idle_r_crouch", "cover_idle_l_crouch", "peek_left", "peek_right", "cover_enter", "cover_exit", "cover_enter_l", "cover_exit_l", "cover_rise"]:
		assert_true(presentation.keyed.has(slot), "CoverAnim plays the keyed %s" % slot)
	var tree := model.animation_tree
	assert_true(tree.has_animation(&"cover_enter@l") and tree.has_animation(&"cover_rest_upper@l"), "the left-side clips are in the library")
	# The keyed cover clips keep CoverAnim's own neck (on the head hitbox) and never turn it.
	var idle := tree.get_animation(&"cover_idle_r_crouch")
	assert_eq(idle.find_track(NodePath("Skeleton3D:Neck"), Animation.TYPE_ROTATION_3D), -1, "no neck turn in a cover clip")
	var neck := idle.position_track_interpolate(idle.find_track(NodePath("Skeleton3D:Neck"), Animation.TYPE_POSITION_3D), 0.5)
	var cfg: Dictionary = pawn.cover.config
	var want := model.skeleton.get_bone_rest(model.skeleton.find_bone("Neck")).origin.y - (pawn.cover_standing_head_y() - float(cfg["crouch_head_y_m"]))
	assert_true(absf(neck.y - want) < 0.0001, "crouched neck on the lowered head hitbox (%.4f vs %.4f)" % [neck.y, want])
	pawn.free()


## A ladder (data/props.json "ladder") at the origin facing -z, and a pawn on its climb line, climbing.
func _ladder_rig() -> Dictionary:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var ladder := Ladder.make({"id": "Ladder_K", "piece": "", "at": [0, 0, 0], "yaw": 0.0, "height": 3.3, "width": 0.6, "top": [0, 3.3, -0.6]}, WorldProps.config()["ladder"])
	root.add_child(ladder)
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = ladder.climb_point(0.4)
	# Look away from the ladder: the model must turn itself to face it.
	pawn.rotation.y = PI * 0.5
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	return {"root": root, "ladder": ladder, "pawn": pawn, "model": model}


func test_climbing_plays_the_ladder_clips_with_the_gun_slung_and_gives_the_body_back() -> void:
	var rig := _ladder_rig()
	var pawn: Pawn = rig["pawn"]
	var model: SoldierModel = rig["model"]
	var ladder: Ladder = rig["ladder"]
	pawn.climbing = true
	pawn.ladder_id = ladder.prop_id
	pawn._ladder = ladder  # the read-only climb state, set the way Pawn._ladder_tick sets it
	pawn.velocity = Vector3(0, 2.0, 0)
	for i in 10:
		model.drive_actions(DT)
		model._show_weapon()
	assert_eq(model.climb_clip, "ladder_up", "climbing up plays ladder_up")
	assert_eq(model.climb_weight, 1.0, "the climb is fully faded in")
	assert_true(model.pose.action_clip != null and model.pose.action_weight == 1.0 and model.pose.action_bones.is_empty(), "whole body through SoldierPose")
	assert_true(model.gun_slung() and not model.rifle.visible, "the gun is slung on the ladder")
	assert_true(model.left_ik.influence <= 0.001 or model.pose.arms_weight >= 0.999, "the left hand lets go of the rifle")
	var face := -model.global_basis.z
	assert_true(face.dot(ladder.into_dir()) > 0.99, "the model faces into the ladder (%s)" % face)
	# The clip time is the feet's height on the ladder: one cycle_m higher is the same pose; a held stick holds it.
	var cycle := float(SoldierRig.config()["keyed"]["ladder"]["cycle_m"])
	var t0 := model.pose.action_time
	pawn.global_position.y += cycle
	model.drive_actions(DT)
	assert_true(absf(model.pose.action_time - t0) < 0.001, "one cycle_m up: same clip time (%.4f vs %.4f)" % [model.pose.action_time, t0])
	pawn.global_position.y += cycle * 0.25
	model.drive_actions(DT)
	var clip_len := model.pose.action_clip.length
	assert_true(absf(model.pose.action_time - fposmod(t0 + 0.25 * clip_len, clip_len)) < 0.001, "a quarter cycle up: a quarter clip on")
	pawn.velocity = Vector3(0, -2.0, 0)
	model.drive_actions(DT)
	assert_eq(model.climb_clip, "ladder_down", "climbing down plays ladder_down")
	# Let go at the bottom (not a top step): the climb fades out, the gun comes back, the yaw returns.
	pawn.climbing = false
	pawn._ladder = null
	pawn.velocity = Vector3.ZERO
	for i in 30:
		model.drive_actions(DT)
		model._show_weapon()
	assert_eq(model.climb_weight, 0.0, "the climb faded out")
	assert_true(model.pose.action_weight == 0.0 and model.action_name.is_empty(), "no action left (not a top step)")
	assert_true(not model.gun_slung() and model.rifle.visible, "the gun is back in the hands")
	assert_true(absf(model.rotation.y) < 0.0001 and not model.owns_yaw(), "the model faces the pawn's way again")
	(rig["root"] as Node).free()


func test_the_top_step_plays_ladder_top_once() -> void:
	var rig := _ladder_rig()
	var pawn: Pawn = rig["pawn"]
	var model: SoldierModel = rig["model"]
	var ladder: Ladder = rig["ladder"]
	pawn.climbing = true
	pawn._ladder = ladder
	pawn.global_position = ladder.climb_point(ladder.top_y() + 0.1)
	pawn.velocity = Vector3(0, 2.0, 0)
	for i in 6:
		model.drive_actions(DT)
	# Pawn._ladder_tick's top step: let go, the feet set on the top point.
	pawn.climbing = false
	pawn._ladder = null
	pawn.global_position = ladder.top_point()
	pawn.velocity = Vector3.ZERO
	model.drive_actions(DT)
	assert_eq(model.action_name, "ladder_top", "the top step plays ladder_top")
	assert_true(model.pose.action_weight > 0.99 and model.pose.action_bones.is_empty(), "whole body at once (it continues the climbing pose)")
	assert_true(model.gun_slung(), "the gun stays slung over the top")
	assert_true(model.owns_yaw(), "still facing the ladder's way")
	var length: float = model.pose.action_clip.length
	for i in ceili(length / DT) + 20:
		model.drive_actions(DT)
	assert_true(model.action_name.is_empty() and model.pose.action_weight == 0.0, "ladder_top ends")
	assert_true(not model.gun_slung(), "the gun is back")
	(rig["root"] as Node).free()


func test_play_action_plays_and_returns_and_is_ignored_while_climbing_or_downed() -> void:
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	assert_true(not model.play_action(&"dance"), "an unknown action is ignored")
	for action: StringName in [&"door_open", &"chest_open", &"pickup_ground"]:
		assert_true(model.play_action(action), "%s plays" % action)
		var length := (model.pose.action_clip.length if model.pose.action_clip != null else 0.0)
		model.drive_actions(DT)
		assert_eq(model.action_name, String(action), "%s is the action" % action)
		var peak := 0.0
		for i in 60:
			model.drive_actions(DT)
			model._show_weapon()
			peak = maxf(peak, model.pose.action_weight)
			if model.action_name.is_empty():
				break
		assert_true(peak > 0.99, "%s reaches full weight (%.3f)" % [action, peak])
		assert_true(model.action_name.is_empty() and model.pose.action_weight == 0.0, "%s ends and gives the body back" % action)
		assert_true(model.rifle.visible, "%s: the gun is in the hands after" % action)
		assert_true(length >= 0.0, "length read")
	var full: Array = SoldierRig.config()["keyed"]["actions"]["full_body"]
	model.play_action(&"door_open")
	model.drive_actions(DT)
	assert_true(not model.pose.action_bones.is_empty() and not full.has("door_open"), "the door is upper body only (the legs keep walking)")
	model.play_action(&"chest_open")
	model.drive_actions(DT)
	assert_true(model.pose.action_bones.is_empty(), "the chest is whole body")
	pawn.climbing = true
	assert_true(not model.play_action(&"door_open"), "ignored while climbing")
	pawn.climbing = false
	model.pose.force["downed"] = 1.0
	model.pose.weights["downed"] = 1.0
	assert_true(not model.play_action(&"pickup_ground"), "ignored while downed")
	pawn.free()
