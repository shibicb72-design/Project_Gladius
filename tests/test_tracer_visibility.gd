extends "res://tests/test_case.gd"
## GBTN2: the tracer must be visible ON SCREEN, not just `visible`. Fires through the Fire button, projects both
## world endpoints with the active Camera3D and checks the pixel length (docs/LESSONS.md "GBTN ITERATE").

const _Rig := preload("res://tests/button_rig.gd")


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]


func test_tracer_projects_to_a_readable_segment_and_draws_on_top() -> void:
	var min_px: float = _cfg()["tracer_min_screen_px"]
	for size in _Rig.SIZES:
		for mode in _Rig.MODES:
			var ctx: Dictionary = await _Rig.setup(size, mode)
			var tag: String = ctx["tag"]
			var pawn: Pawn = ctx["pawn"]
			_Rig.press(ctx, "fire", true)
			await _Rig.frames(2)
			_Rig.press(ctx, "fire", false)
			assert_true(pawn.shot_fx.is_tracer_visible(), "%s: tracer visible" % tag)
			var cam: Camera3D = (ctx["m"] as Node).get_viewport().get_camera_3d()
			assert_true(cam != null, "%s: an active camera exists" % tag)
			var ep := pawn.shot_fx.get_tracer_endpoints()
			assert_true(not ep[0].is_equal_approx(ep[1]), "%s: tracer endpoints differ" % tag)
			assert_true(not cam.is_position_behind(ep[0]) and not cam.is_position_behind(ep[1]),
					"%s: both endpoints are in front of the camera" % tag)
			var a := cam.unproject_position(ep[0])
			var b := cam.unproject_position(ep[1])
			assert_true(not a.is_equal_approx(b), "%s: projected endpoints differ" % tag)
			assert_true(a.distance_to(b) > min_px,
					"%s: tracer on-screen length %.1f px > %.1f px" % [tag, a.distance_to(b), min_px])
			var mat := (pawn.shot_fx.tracer.mesh as BoxMesh).material as StandardMaterial3D
			assert_true(mat.no_depth_test, "%s: tracer drawn on top (the pawn body must not hide it)" % tag)
			await _Rig.teardown(ctx)
