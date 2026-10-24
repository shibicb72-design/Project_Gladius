extends "res://tests/test_case.gd"
## Path A commit 4: Kenney-style ShotFx muzzle/impact/viewmodel presentation (Hitscan untouched).

const _PawnScene := preload("res://scenes/player/pawn.tscn")


func test_show_shot_shows_impact_and_keeps_tracer() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = _PawnScene.instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	await tree.process_frame
	var origin := pawn.get_muzzle_position()
	var end := origin + Vector3(0, 0, -10)
	pawn.shot_fx.show_shot(origin, end)
	assert_true(pawn.shot_fx.is_tracer_visible(), "tracer visible")
	assert_true(pawn.shot_fx.is_flash_visible(), "flash visible")
	assert_true(pawn.shot_fx.is_impact_visible(), "impact visible at end")
	assert_true(pawn.shot_fx.impact.global_position.distance_to(end) < 0.01, "impact at end point")
	pawn.queue_free()


func test_ui_shot_fx_has_kenney_presentation_keys() -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/ui.json")["shot_fx"]
	for key in ["flash_scale_min", "flash_scale_max", "flash_spin_deg", "impact_size_m",
			"impact_duration_s", "impact_color", "viewmodel_recoil_m", "viewmodel_recoil_recover_s"]:
		assert_true(cfg.has(key), "shot_fx.%s present" % key)
