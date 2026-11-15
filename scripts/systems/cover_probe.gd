class_name CoverProbe
extends RefCounted
## Scene adapter. Only tagged box walls can enter the pure controller.
var _wall: StaticBody3D
## M2 C1b stage 3: the locked wall's instance id (0 = none), so a freed body is told apart without touching it.
var _wall_id := 0
var _normal := Vector3.ZERO
var _movement := DataRegistry.new().get_movement_cfg()

func reset() -> void:
	_wall = null
	_wall_id = 0
	_normal = Vector3.ZERO

## distance_m < 0 = the auto-snap reach cfg probe_m. M2 C1b: the Cover button passes cfg cover_button_range_m for
## its own longer unlocked ray; the cover_wall contract and every later check are the same.
func sample(pawn: Pawn, cfg: Dictionary, locked: bool, distance_m: float = -1.0) -> Dictionary:
	var out := {"hit": false, "position": pawn.global_position, "basis": pawn.global_basis, "slide_speed_mps": pawn.get_move_speed() * float(_movement["strafe_back_ratio"]["value"])}
	out["shot_clear"] = shot_clear(pawn)
	out["stand_clear"] = standing_clear(pawn)
	out["muzzle_height_m"] = float(_movement["muzzle_height_m"])
	var weapon := pawn.loadout.get_active()
	if weapon != null:
		out["weapon_hold_s"] = weapon.def.fire_interval_s / maxi(weapon.def.burst_count, 1) if not weapon.fire_mode.is_empty() else weapon.def.fire_interval_s + maxf(0, weapon.def.burst_count - 1) * weapon.def.burst_interval_s
		out["weapon_repeats"] = weapon.fire_mode != "semi"
		out["weapon_pending"] = weapon.has_ammo() and not weapon.reloading and (weapon._semi_armed or weapon._burst_left > 0)
	if not locked:
		reset()
		var from := pawn.global_position + Vector3.UP * float(cfg["probe_height_m"])
		var ahead := -pawn.global_basis.z
		ahead.y = 0
		var reach := float(cfg["probe_m"]) if distance_m < 0.0 else distance_m
		var query := PhysicsRayQueryParameters3D.create(from, from + ahead.normalized() * reach, 1, [pawn.get_rid()])
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or not hit["collider"] is StaticBody3D or not hit["collider"].is_in_group(&"cover_wall"):
			return out
		_wall = hit["collider"]
		_wall_id = _wall.get_instance_id()
		_normal = hit["normal"]
	# M2 C1b stage 3 (item 5, fix 19): a locked wall whose body was freed (its instance id is no longer valid) or taken
	# out of the tree is "wall_gone"; CoverController then exits through EXITING instead of the lost-sample reset. The
	# freed body itself is never dereferenced.
	if locked and _wall_id != 0 and (not is_instance_id_valid(_wall_id) or not (instance_from_id(_wall_id) as Node).is_inside_tree()):
		out["wall_gone"] = true
		return out
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
	# Connected coplanar boxes share their usable outside ends; C slide retains own ends.
	var ends := Vector2(-along_extent, along_extent)
	var epsilon := float(cfg["motion_epsilon_m"])
	# M2P1C stop 6: the walls near the current ends from the tree's CoverIndex, re-asked each pass as the
	# ends grow; every check below stays live per candidate, so the result is the old whole-group walk's.
	var index := CoverIndex.of(pawn.get_tree())
	index.refresh()
	var changed := true
	while changed:
		changed = false
		for body in index.walls_near(_normal, point, center, tangent, ends, epsilon):
			if not body is StaticBody3D or body == _wall:
				continue
			var other := body.get_node_or_null("Shape") as CollisionShape3D
			if other == null or other.disabled or not other.shape is BoxShape3D or body.collision_layer & 1 == 0:
				continue
			var half := (other.shape as BoxShape3D).size * 0.5
			var face := other.global_position + _normal * (absf(_normal.x) * half.x + absf(_normal.z) * half.z)
			if absf((face - point).dot(_normal)) > epsilon or other.global_position.y + half.y <= pawn.global_position.y:
				continue
			var mid := (other.global_position - center).dot(tangent)
			var radius := absf(tangent.x) * half.x + absf(tangent.z) * half.z
			if mid - radius > ends.y + epsilon or mid + radius < ends.x - epsilon:
				continue
			var expanded := Vector2(minf(ends.x, mid - radius), maxf(ends.y, mid + radius))
			if expanded != ends:
				ends = expanded
				changed = true
	out["usable_left_m"] = along - ends.x if _edge_clear(pawn, cfg, center, tangent, ends.x, -1) else INF
	out["usable_right_m"] = ends.y - along if _edge_clear(pawn, cfg, center, tangent, ends.y, 1) else INF
	return out

func _edge_clear(pawn: Pawn, cfg: Dictionary, center: Vector3, tangent: Vector3, edge: float, side: int) -> bool:
	var start := center + tangent * edge
	start += _normal * ((pawn.global_position - center).dot(_normal))
	start.y = pawn.global_position.y + float(cfg["probe_height_m"])
	var query := PhysicsRayQueryParameters3D.create(start, start + tangent * side * float(cfg["peek_offset_m"]), 1, [pawn.get_rid()])
	return pawn.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

## Full weapon range, refreshed after movement too; joined cover pieces all participate.
func shot_clear(pawn: Pawn) -> bool:
	var weapon := pawn.loadout.get_active()
	if weapon == null:
		return false
	var start := pawn.get_muzzle_position()
	var query := PhysicsRayQueryParameters3D.create(start, start + pawn.get_aim_direction() * weapon.def.range_m, 1, [pawn.get_rid()])
	var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or not hit["collider"].is_in_group(&"cover_wall")

## World-only full standing shapes. Contact with the floor is not penetration (margin zero).
func standing_clear(pawn: Pawn) -> bool:
	var body := pawn.get_node("CollisionShape3D") as CollisionShape3D
	var capsule := body.shape.duplicate() as CapsuleShape3D
	capsule.height = pawn.cover_standing_height()
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(pawn.global_basis, pawn.global_position + Vector3.UP * capsule.height * 0.5)
	query.collision_mask = 1
	query.exclude = [pawn.get_rid()]
	if not pawn.get_world_3d().direct_space_state.intersect_shape(query).is_empty():
		return false
	query.shape = pawn.get_node("Head/CollisionShape3D").shape
	query.transform.origin = pawn.global_position + Vector3.UP * pawn.cover_standing_head_y()
	return pawn.get_world_3d().direct_space_state.intersect_shape(query).is_empty()
