class_name HillZone
extends Area3D
## Presentation node for the hill. Reports occupancy (squad id -> living pawns inside); scores nothing.

var _shape := CylinderShape3D.new()


func _init() -> void:
	collision_layer = 0
	collision_mask = 2
	var cs := CollisionShape3D.new()
	cs.shape = _shape
	add_child(cs)


## center is the hill's base centre; the cylinder is raised by half its height.
func configure(center: Vector3, radius_m: float, height_m: float) -> void:
	_shape.radius = radius_m
	_shape.height = height_m
	position = center + Vector3(0.0, height_m * 0.5, 0.0)


func occupancy() -> Dictionary:
	var result: Dictionary = {}
	for body in get_overlapping_bodies():
		if body is Pawn and body.is_alive():
			result[body.squad_id] = int(result.get(body.squad_id, 0)) + 1
	return result
