class_name AimMath
extends RefCounted
## Camera-centre aim point (client) and the muzzle-ray check of it (host). With the right-shoulder camera the
## camera ray and the muzzle ray differ, so the client sends a world point and the host fires muzzle -> point.


## Point under the screen centre: first world/body/head hit of the camera ray, else `far_m` along it.
static func camera_aim_point(cam: Camera3D, exclude: Array[RID], far_m: float) -> Vector3:
	var centre := cam.get_viewport().get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(centre)
	var dir := cam.project_ray_normal(centre)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * far_m,
			Hitscan.MASK_WORLD | Hitscan.MASK_BODY | Hitscan.MASK_HEAD)
	q.collide_with_areas = true
	q.exclude = exclude
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if not hit.is_empty() else from + dir * far_m


## Host check: the muzzle ray (world geometry only) must reach `point` within `epsilon_m`.
## Returns {ok, reason}; reasons: "bad_aim_point", "aim_blocked".
static func validate_aim(space: PhysicsDirectSpaceState3D, muzzle: Vector3, point: Vector3,
		epsilon_m: float, exclude: Array[RID]) -> Dictionary:
	if not point.is_finite() or muzzle.distance_squared_to(point) < 0.0001:
		return {"ok": false, "reason": "bad_aim_point"}
	var q := PhysicsRayQueryParameters3D.create(muzzle, point, Hitscan.MASK_WORLD)
	q.exclude = exclude
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and muzzle.distance_to(hit["position"]) < muzzle.distance_to(point) - epsilon_m:
		return {"ok": false, "reason": "aim_blocked"}
	return {"ok": true, "reason": ""}
