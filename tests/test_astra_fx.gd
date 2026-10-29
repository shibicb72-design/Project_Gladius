extends "res://tests/test_case.gd"

func test_star_flash_tracer_fade_and_bounded_cpu_impact_bursts() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var fx := pawn.shot_fx
	fx.set_physics_process(false)
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]
	assert_true(fx.flash.mesh is ArrayMesh, "star mesh replaces sphere")
	assert_true(fx.impact.mesh is SphereMesh and fx.tracer.mesh is BoxMesh, "public primitive contracts")
	var flash_mat := fx.flash.mesh.surface_get_material(0) as StandardMaterial3D
	assert_eq(flash_mat.blend_mode, BaseMaterial3D.BLEND_MODE_ADD, "additive flash")
	assert_eq(flash_mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "unshaded flash")
	var tracer_mat := (fx.tracer.mesh as BoxMesh).material as StandardMaterial3D
	assert_eq(tracer_mat.no_depth_test, bool(cfg["tracer_draw_on_top"]), "depth test contract")
	assert_eq(tracer_mat.render_priority, int(cfg["tracer_render_priority"]), "render priority contract")
	fx.show_shot(Vector3.ZERO, Vector3(0, 1, -10))
	var duration := float(cfg["tracer_duration_s"])
	fx._physics_process(duration * 0.5)
	assert_true(fx.is_tracer_visible(), "tracer alive until timer ends")
	assert_true(tracer_mat.albedo_color.a > 0 and tracer_mat.albedo_color.a < 1, "alpha fades midlife")
	fx._physics_process(duration)
	assert_true(not fx.is_tracer_visible(), "timer still owns visibility")
	for key in ["sparks", "dust"]:
		var burst := fx.get_node(key.capitalize()) as CPUParticles3D
		assert_true(burst != null and burst.one_shot, "CPU one-shot " + key)
		assert_true(burst.amount > 0 and burst.amount <= 24 and burst.lifetime <= 0.5, "particle budget " + key)
		assert_eq(burst.amount, int(cfg[key]["amount"]), "amount from data")
		assert_true(burst.global_position.is_equal_approx(Vector3(0, 1, -10)), "impact endpoint " + key)
	pawn.free()
