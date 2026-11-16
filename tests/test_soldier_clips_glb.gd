extends "res://tests/test_case.gd"
## M2 AN2 item 2: assets/generated/characters/soldier_clips.glb (tools/blender/build_soldier_clips.py), the UAL clips
## retargeted, cleaned and baked in Blender onto the soldier's own rig. The file has exactly one skeleton whose bones
## and rests are the runtime skeleton's and no mesh; every clip the slots use is there with a sane length; the looping
## clips close; the shipped slots resolve to the "blender" source and play the authored clip key for key; the death
## clip ends with the body lying on the ground.

const GLB := "res://assets/generated/characters/soldier_clips.glb"
## clip -> loops. Names as Godot sees them (the importer drops _Loop and loops those).
const CLIPS := {"Idle": true, "Walk": true, "Jog_Fwd": true, "Sprint": true, "Jump": true, "Crouch_Idle": true,
	"Crouch_Fwd": true, "Hit_Chest": false, "Hit_Head": false, "Death01": false, "Fixing_Kneeling": false, "Sword_Attack": false}
## Slots that resolve to the Blender clips.
const SLOTS: Array[String] = ["idle", "walk_slow", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd", "jump_air",
	"hit_chest", "hit_head", "death", "revive", "blade_swing", "cover_crouch_idle", "cover_crouch_move"]
## Seam limits of a looping clip (first against last sample): every bone's local rotation and the pelvis position.
const SEAM_DEG := 0.5
const SEAM_M := 0.001


func _pawn() -> Pawn:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


func _source() -> Dictionary:
	var instance: Node = (load(GLB) as PackedScene).instantiate()
	var skeletons := instance.find_children("*", "Skeleton3D", true, false)
	var players := instance.find_children("*", "AnimationPlayer", true, false)
	return {"node": instance, "skeletons": skeletons, "meshes": instance.find_children("*", "MeshInstance3D", true, false),
		"player": players[0] if players.size() == 1 else null}


func _angle_deg(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(2.0 * acos(clampf(absf(a.normalized().dot(b.normalized())), 0.0, 1.0)))


func test_one_skeleton_with_the_runtime_rests_no_mesh_and_every_clip() -> void:
	var pawn := _pawn()
	var target := (pawn.get_node("SoldierModel") as SoldierModel).skeleton
	var src := _source()
	assert_eq((src["skeletons"] as Array).size(), 1, "exactly one skeleton in soldier_clips.glb")
	assert_eq((src["meshes"] as Array).size(), 0, "no mesh in soldier_clips.glb")
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
	print("SOLDIER_CLIPS_GLB bones=%d rest_err_m=%.6f" % [skeleton.get_bone_count(), worst])
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
		print("SOLDIER_CLIPS_SEAM %s rot_deg=%.4f pos_m=%.5f" % [clip, rot, pos])
		assert_true(rot <= SEAM_DEG and pos <= SEAM_M, "%s closes: %.3f deg, %.4f m" % [clip, rot, pos])
	(src["node"] as Node).free()


func test_shipped_slots_play_the_authored_clip() -> void:
	var pawn := _pawn()
	var target := (pawn.get_node("SoldierModel") as SoldierModel).skeleton
	var src := _source()
	var skeleton: Skeleton3D = src["skeletons"][0]
	var player: AnimationPlayer = src["player"]
	var library := ClipLibrary.new()
	var table: Dictionary = library.sources["clips"]
	for slot in SLOTS:
		var played := library.resolve(slot, Animation.new(), target)
		assert_eq(library.source_for(slot), "blender", "%s resolves to the Blender clips" % slot)
		var name: String = table[slot]["blender"][0]["clip"]
		var authored := player.get_animation(name)
		var rot := 0.0
		var pos := 0.0
		for k in 21:
			var t := authored.length * k / 20.0
			var want := AnimRetarget.sample_globals(authored, skeleton, t)
			var got := AnimRetarget.sample_globals(played, target, t)
			for i in target.get_bone_count():
				var j := skeleton.find_bone(target.get_bone_name(i))
				rot = maxf(rot, _angle_deg(got[i].basis.get_rotation_quaternion(), want[j].basis.get_rotation_quaternion()))
				pos = maxf(pos, got[i].origin.distance_to(want[j].origin))
		print("SOLDIER_CLIPS_RESAMPLE %s clip=%s rot_err_deg=%.5f pos_err_m=%.6f" % [slot, name, rot, pos])
		assert_true(rot <= 0.1 and pos <= 0.001, "%s plays %s as authored (%.4f deg, %.5f m)" % [slot, name, rot, pos])
	(src["node"] as Node).free()
	ClipLibrary.release_sources()
	pawn.free()


func test_death_clip_ends_lying_on_the_ground() -> void:
	var pawn := _pawn()
	var target := (pawn.get_node("SoldierModel") as SoldierModel).skeleton
	var death := SoldierAnimation.shared("death", target)
	assert_true(death != null, "the death clip resolves")
	var poses := AnimRetarget.sample_globals(death, target, death.length)
	var parts: Array = SoldierLook.parts()
	var bounds := SoldierRig.part_local_bounds(parts, target)
	var mapping: Dictionary = SoldierRig.config()["part_bones"]
	var lowest := INF
	var lowest_part := ""
	var torso_low := INF
	for i in parts.size():
		# The cape is cloth: its proxy box hangs straight down the back ~10 cm thick and the shader lifts the real one
		# (cape_lift); the posed mesh, cape included, is kept on the floor by the Blender script's ground check.
		if String(parts[i]["name"]).contains("cape"):
			continue
		var bone := target.find_bone(mapping[parts[i]["name"]])
		var box: AABB = poses[bone] * bounds[i]
		if box.position.y < lowest:
			lowest = box.position.y
			lowest_part = parts[i]["name"]
		if ["Hips", "Spine", "Chest"].has(String(mapping[parts[i]["name"]])):
			torso_low = minf(torso_low, box.position.y)
	print("SOLDIER_CLIPS_DEATH end lowest_part=%s lowest_y=%.3f torso_lowest_y=%.3f" % [lowest_part, lowest, torso_low])
	# Part boxes are the parts' bounding boxes (a box around a tilted part reaches a little lower than the part).
	assert_true(lowest >= -0.05, "no part box more than 5 cm under the ground at the end of the death (%.3f, %s)" % [lowest, lowest_part])
	assert_true(torso_low <= 0.1, "the torso lies on the ground at the end of the death (lowest torso box %.3f m)" % torso_low)
	pawn.free()
