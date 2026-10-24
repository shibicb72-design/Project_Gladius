extends "res://tests/test_case.gd"

const _Rig := preload("res://scripts/systems/camera_rig.gd")
const _Registry := preload("res://scripts/systems/data_registry.gd")


func test_fov_for_aspect_picks_table_row() -> void:
	var cfg: Dictionary = _Registry.new().get_camera_cfg()
	var phone: float = _Rig.fov_for_aspect(cfg, 19.5 / 9.0)
	var fold: float = _Rig.fov_for_aspect(cfg, 1.0)
	assert_true(fold > phone, "Fold inner FOV wider than phone")
	assert_eq(phone, 75.0, "phone row")
	assert_eq(fold, 95.0, "near-square row")
