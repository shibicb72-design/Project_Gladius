class_name CoverProbe
extends RefCounted
## Scene adapter. Only tagged box walls can enter the pure controller.
var _wall: StaticBody3D
var _normal := Vector3.ZERO
var _movement := DataRegistry.new().get_movement_cfg()

func reset() -> void:
	_wall = null
	_normal = Vector3.ZERO

func sample(pawn: Pawn, cfg: Dictionary, locked: bool) -> Dictionary:
	var out := {"hit": false, "position": pawn.global_position, "basis": pawn.global_basis, "slide_speed_mps": pawn.get_move_speed() * float(_movement["strafe_back_ratio"]["value"])}
	if not locked:
		reset()
		var from := pawn.global_position + Vector3.UP * float(cfg["probe_height_m"])
		var ahead := -pawn.global_basis.z
		ahead.y = 0
		var query := PhysicsRayQueryParameters3D.create(from, from + ahead.normalized() * float(cfg["probe_m"]), 1, [pawn.get_rid()])
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or not hit["collider"] is StaticBody3D or not hit["collider"].is_in_group(&"cover_wall"):
			return out
		_wall = hit["collider"]
		_normal = hit["normal"]
	if not is_instance_valid(_wall) or not _wall.is_inside_tree() or not _wall.is_in_group(&"cover_wall"):
		return out
	var shape := _wall.get_node_or_null("Shape") as CollisionShape3D
	if _wall.collision_layer & 1 == 0 or shape == null or shape.disabled or not shape.shape is BoxShape3D:
		return out
	var size := (shape.shape as BoxShape3D).size
	var center := shape.global_position
	var extent := size * 0.5
	var tangent := Vector3.UP.cross(_normal).normalized()
	var along_extent := absf(tangent.x) * extent.x + absf(tangent.z) * extent.z
	var normal_extent := absf(_normal.x) * extent.x + absf(_normal.z) * extent.z
	var point := center + _normal * normal_extent
	point.y = pawn.global_position.y
	var along := (pawn.global_position - center).dot(tangent)
	if locked:
		# Keep checking the same wall while the pawn passes its edge during a peek.
		# The ray stays just inside that wall's own box, never selecting another body.
		var inset := float(cfg["motion_epsilon_m"])
		var face := point + tangent * clampf(along, -along_extent + inset, along_extent - inset)
		face.y += float(cfg["probe_height_m"])
		var query := PhysicsRayQueryParameters3D.create(face + _normal * float(cfg["probe_m"]), face - _normal * inset, 1, [pawn.get_rid()])
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit["collider"] != _wall:
			return out
	out.merge({"hit": true, "normal": _normal, "point": point, "distance_m": absf((pawn.global_position - point).dot(_normal)), "left_m": along + along_extent, "right_m": along_extent - along, "height_m": center.y + extent.y - pawn.global_position.y, "wall_key": _wall.get_instance_id()}, true)
	return out
