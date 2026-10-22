class_name Melee
extends RefCounted
## Short-range melee swing (Gladius Lux energy blade, OQ-07). Range and arc come from the WeaponDef.
## Hits are reported to the same authority Callable as Hitscan: authority.call(attacker, target, def, false).


## True if `target_point` lies within def.melee_range_m of `origin` and inside the swing arc
## (def.melee_arc_deg is the full angle, centred on `forward`).
static func in_swing(origin: Vector3, forward: Vector3, target_point: Vector3, def: WeaponDef) -> bool:
	var to_target := target_point - origin
	var dist := to_target.length()
	if dist > def.melee_range_m:
		return false
	if dist < 0.0001:
		return true
	var half_arc := deg_to_rad(def.melee_arc_deg) * 0.5
	return forward.normalized().angle_to(to_target) <= half_arc


## Pawns the swing reaches, skipping the attacker, dead pawns and targets behind world geometry
## (space may be null in pure tests).
static func targets(space: PhysicsDirectSpaceState3D, attacker: Pawn, origin: Vector3, forward: Vector3,
		def: WeaponDef, candidates: Array) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for c in candidates:
		var p := c as Pawn
		if p == null or p == attacker or not p.is_alive():
			continue
		var point := p.get_muzzle_position()
		if not in_swing(origin, forward, point, def):
			continue
		if space != null:
			var q := PhysicsRayQueryParameters3D.create(origin, point, Hitscan.MASK_WORLD)
			if not space.intersect_ray(q).is_empty():
				continue
		out.append(p)
	return out


## Swings once: every reachable pawn goes to the authority. Returns the pawns reached.
static func swing(space: PhysicsDirectSpaceState3D, attacker: Pawn, origin: Vector3, forward: Vector3,
		def: WeaponDef, candidates: Array, authority: Callable) -> Array[Pawn]:
	var hit := targets(space, attacker, origin, forward, def, candidates)
	if authority.is_valid():
		for t in hit:
			authority.call(attacker, t, def, false)
	return hit
