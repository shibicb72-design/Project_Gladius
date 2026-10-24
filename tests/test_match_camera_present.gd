extends "res://tests/test_case.gd"
## P0c: after MatchRoot.begin() the third-person CameraRig exists and its Camera3D is the current camera, and the
## auto_start path never swallows begin()'s bool.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _SRC := "res://scripts/systems/match_root.gd"


func test_begin_attaches_current_camera() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	var ok: bool = m.begin()
	assert_true(ok, "begin() returned true")
	var rig := m.local_player.get_node_or_null("CameraRig") as CameraRig
	assert_true(rig != null, "local_player has a CameraRig")
	if rig != null:
		var cam: Camera3D = rig.get_camera()
		assert_true(cam.is_current() or m.get_viewport().get_camera_3d() == cam,
				"rig camera is current / the viewport camera")
	m.queue_free()
	await tree.process_frame


func test_auto_start_checks_begin_result() -> void:
	var f := FileAccess.open(_SRC, FileAccess.READ)
	assert_true(f != null, "match_root.gd readable")
	if f == null:
		return
	var src := f.get_as_text()
	var i := src.find("if auto_start:")
	assert_true(i >= 0, "auto_start block present")
	var block := src.substr(i, 300)
	assert_true(block.contains("= begin()"), "auto_start captures begin()'s return")
	assert_true(block.contains("push_error"), "auto_start push_errors when begin() returns false")
