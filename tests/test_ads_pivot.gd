extends "res://tests/test_case.gd"
## Path A commit 5: GDQuest ADS over-shoulder pivot (code only; no NC art).

const _RigScene := preload("res://scenes/player/camera_rig.tscn")


func test_aim_blend_shortens_spring_toward_ads_length() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var rig: CameraRig = _RigScene.instantiate()
	tree.root.add_child(rig)
	await tree.physics_frame
	var cfg := DataRegistry.new().get_camera_cfg()
	var hip := float(cfg.get("arm_length_m", 3.5))
	var ads := float(cfg["arm_length_aim_m"]["value"])
	assert_true(ads < hip, "ADS arm shorter than hip")
	assert_true(absf(rig.get_spring_length() - hip) < 0.001, "starts at hip length")
	rig.set_aim_blend(1.0, 0.6)
	assert_true(absf(rig.get_spring_length() - ads) < 0.001, "full ADS uses aim spring_length")
	rig.set_aim_blend(0.0, 0.6)
	assert_true(absf(rig.get_spring_length() - hip) < 0.001, "release restores hip length")
	rig.queue_free()


func test_aim_raycast_exists_on_camera() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var rig: CameraRig = _RigScene.instantiate()
	tree.root.add_child(rig)
	await tree.physics_frame
	var cam := rig.get_camera()
	var ray := cam.get_node_or_null("AimRayCast") as RayCast3D
	assert_true(ray != null, "AimRayCast on camera (GDQuest pattern, code-built)")
	assert_true(ray.enabled, "aim ray enabled")
	rig.queue_free()


func test_camera_json_has_arm_length_aim() -> void:
	var cfg := DataRegistry.new().get_camera_cfg()
	assert_true(cfg.has("arm_length_aim_m"), "arm_length_aim_m present")
	assert_true(float(cfg["arm_length_aim_m"]["value"]) > 0.0, "positive aim length")


func test_ensure_current_still_works_after_ads_pivot() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var rig: CameraRig = _RigScene.instantiate()
	tree.root.add_child(rig)
	await tree.physics_frame
	rig.set_aim_blend(1.0, 0.6)
	assert_true(rig.ensure_current(), "ensure_current stays green under ADS")
	rig.queue_free()
