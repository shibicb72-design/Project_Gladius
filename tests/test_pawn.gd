extends "res://tests/test_case.gd"

const _PawnScene := preload("res://scenes/player/pawn.tscn")


func test_pawn_speed_scales_with_class() -> void:
	var h: Pawn = _PawnScene.instantiate()
	h.class_id = "hastati"
	var s: Pawn = _PawnScene.instantiate()
	s.class_id = "sagittarii"
	h.setup("hastati", 0)
	s.setup("sagittarii", 0)
	assert_true(absf(s.get_move_speed() - h.get_move_speed() * 0.95) < 0.0001, "Sagittarii is 95% of Hastati")
	h.free()
	s.free()
