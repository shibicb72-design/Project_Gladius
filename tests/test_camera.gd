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
	# The real Galaxy Z Fold 7 inner screen (2176 x 1812, aspect 1.2009) must get the near-square row, and a
	# 4:3 tablet (1.333) the tablet row.
	assert_eq(_Rig.fov_for_aspect(cfg, 2176.0 / 1812.0), 95.0, "real Fold inner aspect gets the wide row")
	assert_eq(_Rig.fov_for_aspect(cfg, 4.0 / 3.0), 85.0, "4:3 tablet row")
