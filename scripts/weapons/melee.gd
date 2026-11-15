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


## DESIGN.md:15 front/back: the angle (flat, XZ) between the TARGET's facing and the direction from the
## target to the attacker. Beyond `back_angle_deg` (stats.json melee.melee_back_angle_deg, placeholder
## OQ-56) the hit counts as from behind; exactly at the threshold it is still a front hit.
static func is_from_behind(target_pos: Vector3, target_forward: Vector3, attacker_pos: Vector3,
		back_angle_deg: float) -> bool:
	var facing := Vector3(target_forward.x, 0.0, target_forward.z)
	var to_attacker := Vector3(attacker_pos.x - target_pos.x, 0.0, attacker_pos.z - target_pos.z)
	if facing.length() < 0.0001 or to_attacker.length() < 0.0001:
		return false
	return rad_to_deg(facing.angle_to(to_attacker)) > back_angle_deg


## Pawns the swing reaches, skipping the attacker, dead pawns and targets behind world geometry
## (space may be null in pure tests). A DOWNED pawn is a valid target (the finish).
static func targets(space: PhysicsDirectSpaceState3D, attacker: Pawn, origin: Vector3, forward: Vector3,
		def: WeaponDef, candidates: Array) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for c in candidates:
		var p := c as Pawn
		if p == null or p == attacker or not (p.is_alive() or p.is_downed()):
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
## M2 L1b: on the authority only, every breakable the swing reaches (breakables_in_swing) takes a melee hit; the
## returned pawns and every pawn rule are unchanged.
static func swing(space: PhysicsDirectSpaceState3D, attacker: Pawn, origin: Vector3, forward: Vector3,
		def: WeaponDef, candidates: Array, authority: Callable) -> Array[Pawn]:
	var hit := targets(space, attacker, origin, forward, def, candidates)
	if authority.is_valid():
		for t in hit:
			authority.call(attacker, t, def, false)
		for b in breakables_in_swing(space, attacker, origin, forward, def):
			b.call(&"take_hit", def.damage, true)
	return hit


## M2 L1b: the unbroken breakables (group "breakable") a swing from `origin` reaches: the box point nearest the
## origin (Breakable.closest_point) lies within def's range and arc (in_swing), and a world ray to it hits nothing
## or that same breakable (its own box is no cover against itself). Needs the attacker in a tree; space may be
## null (no line-of-sight test, as targets()).
static func breakables_in_swing(space: PhysicsDirectSpaceState3D, attacker: Node, origin: Vector3, forward: Vector3,
		def: WeaponDef) -> Array[Node]:
	var out: Array[Node] = []
	if attacker == null or not attacker.is_inside_tree():
		return out
	for node: Node in attacker.get_tree().get_nodes_in_group(&"breakable"):
		if not node.has_method(&"closest_point") or bool(node.get(&"is_broken")):
			continue
		var point: Vector3 = node.call(&"closest_point", origin)
		if not in_swing(origin, forward, point, def):
			continue
		if space != null:
			var q := PhysicsRayQueryParameters3D.create(origin, point, Hitscan.MASK_WORLD)
			var ray := space.intersect_ray(q)
			if not ray.is_empty() and ray["collider"] != node:
				continue
		out.append(node)
	return out
