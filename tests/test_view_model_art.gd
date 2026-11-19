extends "res://tests/test_case.gd"
## M2 AN1 commit 2: the first-person hands and weapons (scripts/visual/view_mesh.gd, view_hands.gd, view_weapons.gd,
## data/art_soldier.json, OQ-ART-SOLDIER). Budget, structure (skinned one-draw-call arms, finger poses as data, cell
## and charging handle as their own nodes), reach and near plane with the arms posed, and the red dot at full ADS.

const DT := 1.0 / 60.0
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const GUNS: Array[String] = ["pilum_br", "sagittarii_rifle"]
const REQUIRED_POSES: Array[String] = ["grip", "trigger", "foregrip", "open", "reach", "blade"]

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _vm_cfg() -> Dictionary:
	return DataRegistry.new().get_camera_cfg()["first_person"]["view_model"]


func _vm_f(key: String) -> float:
	return float(_vm_cfg()[key]["value"])


func _art() -> Dictionary:
	return DataRegistry.new().load_file("res://data/art_soldier.json")


## A floor and a local pawn (no Brain) with a CameraRig, of class `class_id`.
func _fixture(class_id: String = "hastati") -> void:
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
	_pawn = _PawnScene.instantiate()
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	await _tree().physics_frame
	await _tree().physics_frame
	if class_id != "hastati" or _pawn.bridge == null:
		_pawn.setup(class_id, 0)
	await _frames(ceili(_vm_f("swap_s") / DT) + 4)


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


## Shows `id` (swapping the loadout until it is active) and waits out the swap.
func _show(id: String) -> bool:
	for i in 3:
		if _pawn.loadout.get_active() != null and _pawn.loadout.get_active().def.id == id:
			break
		_pawn.loadout.swap()
		_pawn.weapon_switched.emit(_pawn.loadout.active)
		await _frames(ceili(_vm_f("swap_s") / DT) + 4)
	return _rig.get_view_model().get_shown_weapon_id() == id


## Reach (farthest posed vertex from the eye) and nearest posed vertex of the shown model, in camera metres.
func _reach(vm: ViewModel) -> Vector2:
	var to_cam := _rig.get_camera().global_transform.affine_inverse()
	var far := 0.0
	var near := INF
	for mi in vm.model_meshes():
		var xf := to_cam * mi.global_transform
		for v in vm.posed_faces(mi):
			var d := (xf * v).length()
			far = maxf(far, d)
			near = minf(near, d)
	return Vector2(far, near)


func test_budget_per_weapon_from_art_soldier() -> void:
	var budget: Dictionary = _art()["budget"]
	var max_tris := int(budget["max_triangles"])
	var max_calls := int(budget["max_draw_calls"])
	assert_true(max_tris == 4000 and max_calls == 12, "art_soldier.json budget is 4000 triangles / 12 draw calls")
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var ids: Array[String] = ["pilum_br" if class_id == "hastati" else "sagittarii_rifle", "gladius_lux"]
		for id in ids:
			assert_true(await _show(id), "%s shown" % id)
			var tris := vm.view_triangle_count()
			var calls := vm.view_draw_calls()
			print("FP VIEW BUDGET %s triangles=%d draw_calls=%d (max %d / %d) arm_triangles=%d" % [id, tris, calls, max_tris, max_calls, ViewHands.triangles_per_arm()])
			assert_true(tris > 0 and tris <= max_tris, "%s: %d triangles <= %d" % [id, tris, max_tris])
			assert_true(calls > 0 and calls <= max_calls, "%s: %d draw calls <= %d" % [id, calls, max_calls])
		await _cleanup()


## Each arm is one skinned mesh with one surface (one draw call) on a code-built skeleton with a wrist cuff
## and five fingers of three segments. The finger poses named in the brief are data and blendable.
func test_arms_are_one_skinned_mesh_with_finger_poses() -> void:
	var names := ViewHands.bone_names()
	assert_eq(names.size(), 18, "hand, forearm, wrist cuff, 5 x 3 finger segments")
	for p in REQUIRED_POSES:
		assert_true(ViewHands.pose_names().has(p), "pose %s in art_soldier.json hands.poses" % p)
	await _fixture()
	var vm := _rig.get_view_model()
	var gun := vm.get_shown_weapon()
	for arm_name in ["RightArm", "LeftArm"]:
		var arm := gun.get_node_or_null(arm_name) as Node3D
		assert_true(arm != null, "%s under the gun" % arm_name)
		if arm == null:
			continue
		var skel := arm.get_node("Skeleton") as Skeleton3D
		var mi := skel.get_node("Mesh") as MeshInstance3D
		assert_eq(skel.get_bone_count(), names.size(), "%s: %d bones" % [arm_name, names.size()])
		assert_eq(mi.mesh.get_surface_count(), 1, "%s: one surface = one draw call" % arm_name)
		assert_true(mi.skin != null and mi.get_node_or_null(mi.skeleton) == skel, "%s: skinned to its skeleton" % arm_name)
		# The pose is applied: the posed vertices differ from the bind pose (curled fingers, turned forearm).
		var posed := vm.posed_faces(mi)
		var bind := ViewHands._side_data(String(arm.get_meta(&"side")))["verts"] as PackedVector3Array
		var moved := 0
		for i in posed.size():
			if posed[i].distance_to(bind[i]) > 0.005:
				moved += 1
		assert_true(moved > posed.size() / 4, "%s: fingers and forearm posed (%d of %d vertices moved)" % [arm_name, moved, posed.size()])
	# Blending: halfway between open and grip lies between them for every joint.
	var mid := ViewHands.blend_poses(ViewHands.pose("open"), ViewHands.pose("grip"), 0.5)
	var a: Array = ViewHands.pose("open")["index"]
	var b: Array = ViewHands.pose("grip")["index"]
	assert_true(absf(float(mid["index"][1]) - (float(a[1]) + float(b[1])) * 0.5) < 1e-4, "blend_poses is per joint")
	await _cleanup()


## Guns: Mesh, a Cell and a Charge node of their own (the reload moves them), a Muzzle, the red dot in SightAnchor;
## the blade: a hilt-and-blade mesh with a glow pass. Every material class used exists.
func test_weapon_structure() -> void:
	var art := _art()
	var mats: Dictionary = art["materials"]
	for id: String in (art["weapons"] as Dictionary).keys():
		for key in ["parts"]:
			for part: Dictionary in art["weapons"][id][key]:
				assert_true(mats.has(String(part.get("mat", ""))), "%s.%s: material %s exists" % [id, part["name"], part.get("mat", "")])
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var id := vm.get_shown_weapon_id()
		var gun := vm.get_shown_weapon()
		for child in ["Mesh", "Cell/Mesh", "Charge/Mesh", "Muzzle", "SightAnchor/RedDot", "RightArm", "LeftArm"]:
			assert_true(gun.get_node_or_null(child) != null, "%s: %s" % [id, child])
		var mesh := (gun.get_node("Mesh") as MeshInstance3D).mesh
		assert_true(mesh.get_surface_count() >= 2, "%s: opaque and glass passes (%d surfaces)" % [id, mesh.get_surface_count()])
		assert_true(vm.get_red_dot() != null, "%s: red dot" % id)
		if class_id == "hastati":
			assert_true(await _show("gladius_lux"), "blade shown")
			var blade := vm.get_shown_weapon()
			var bm := (blade.get_node("Mesh") as MeshInstance3D).mesh
			assert_true(bm.get_surface_count() >= 2, "blade: opaque hilt and core plus the glow edge")
			assert_true(blade.get_node_or_null("RightArm") != null, "blade: right hand on the hilt")
			assert_true(vm.get_red_dot() == null, "blade: no red dot")
		await _cleanup()


## At rest, posed, every weapon's model (arms included) lies inside max_reach_m and past the near plane.
func test_posed_model_inside_reach_and_past_the_near_plane() -> void:
	var reach := _vm_f("max_reach_m")
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var near := _rig.get_camera().near
		var ids: Array[String] = ["pilum_br" if class_id == "hastati" else "sagittarii_rifle", "gladius_lux"]
		for id in ids:
			assert_true(await _show(id), "%s shown" % id)
			var r := _reach(vm)
			print("FP VIEW REACH %s reach_m=%.4f nearest_m=%.4f (limit %.2f, near %.3f)" % [id, r.x, r.y, reach, near])
			assert_true(r.x < reach, "%s: reach %.4f < %.2f" % [id, r.x, reach])
			assert_true(r.y > near, "%s: nearest %.4f > near %.3f" % [id, r.y, near])
		await _cleanup()


## Hip to full ADS at every fov_table row: no view-model triangle is cut by the near plane inside the view, every
## vertex inside max_reach_m and past the near plane; a failure names the meshes (ViewProbe.cut_report).
func test_hip_to_ads_has_no_near_plane_cuts() -> void:
	var reach := _vm_f("max_reach_m")
	var fov_mult := float(DataRegistry.new().load_file(DataRegistry.STATS_PATH)["aim"]["aim_fov_mult"])
	var cam_cfg := DataRegistry.new().get_camera_cfg()
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var cam := _rig.get_camera()
		for blend: float in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
			for aspect: float in [2520.0 / 1080.0, 2048.0 / 1536.0, 2176.0 / 1812.0]:
				_rig.base_fov = CameraRig.fov_for_aspect(cam_cfg, aspect)
				_rig.set_aim_blend(blend, fov_mult)
				await _tree().physics_frame
				var m := ViewProbe.measure(vm, cam, aspect)
				var tag := "%s blend %.1f aspect %.2f" % [vm.get_shown_weapon_id(), blend, aspect]
				assert_true(m["cuts"] == 0, "%s: no near-plane cut in view (%s)" % [tag, ViewProbe.cut_report(m)])
				assert_true(m["far"] < reach and m["nearest"] > cam.near, "%s: reach %.4f, nearest %.4f" % [tag, m["far"], m["nearest"]])
		await _cleanup()


## The red dot is on the screen centre at full ADS for both guns (the default viewport).
func test_red_dot_centred_at_full_ads_for_both_guns() -> void:
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(class_id)
		var vm := _rig.get_view_model()
		var cam := _rig.get_camera()
		_rig.set_aim_blend(1.0, float(DataRegistry.new().load_file(DataRegistry.STATS_PATH)["aim"]["aim_fov_mult"]))
		await _frames(45)  # past the ADS settle
		var dot := vm.get_red_dot()
		assert_true(dot != null and vm.get_ads_weight() == 1.0, "%s: full ADS with a red dot" % vm.get_shown_weapon_id())
		if dot != null:
			var local := cam.global_transform.affine_inverse() * dot.global_position
			var off_deg := rad_to_deg(Vector2(local.x, local.y).length() / maxf(-local.z, 0.0001))
			assert_true(local.z < -cam.near and off_deg < 0.05, "%s: dot on the centre ray (%.4f deg off, depth %.4f)" % [vm.get_shown_weapon_id(), off_deg, -local.z])
		await _cleanup()
