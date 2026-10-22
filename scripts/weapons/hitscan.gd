class_name Hitscan
extends RefCounted
## Physics raycast for hitscan weapons. Body hitbox is on layer WORLD+BODY, head hitbox is an Area3D on
## layer HEAD. Hits are reported to an injected authority Callable so the host can own them (S9):
## authority.call(attacker_pawn, target_pawn, weapon_def, is_headshot)

const MASK_WORLD := 1
const MASK_BODY := 2
const MASK_HEAD := 4


## Returns {} on a miss, else {position, target (Pawn or null), is_headshot}.
static func cast(space: PhysicsDirectSpaceState3D, origin: Vector3, direction: Vector3,
		weapon_def: WeaponDef, exclude: Array[RID], rng: RandomNumberGenerator = null) -> Dictionary:
	var dir := direction.normalized()
	if rng != null and weapon_def.spread_deg > 0.0:
		var basis := Basis.looking_at(dir)
		var ang := rng.randf() * TAU
		var r := tan(deg_to_rad(weapon_def.spread_deg)) * sqrt(rng.randf())
		dir = (dir + basis.x * cos(ang) * r + basis.y * sin(ang) * r).normalized()
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * weapon_def.range_m,
			MASK_WORLD | MASK_BODY | MASK_HEAD)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = exclude
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var collider: Object = hit["collider"]
	var is_head: bool = collider is Area3D and (collider as Area3D).is_in_group("head_hitbox")
	var target: Node = null
	if is_head:
		target = collider.get_parent()
	elif collider is CharacterBody3D:
		target = collider
	return {"position": hit["position"], "target": target, "is_headshot": is_head}


## Casts and forwards a pawn hit to the authority. Returns the cast result.
static func fire(space: PhysicsDirectSpaceState3D, attacker: Node, origin: Vector3, direction: Vector3,
		weapon_def: WeaponDef, exclude: Array[RID], authority: Callable,
		rng: RandomNumberGenerator = null) -> Dictionary:
	var res := cast(space, origin, direction, weapon_def, exclude, rng)
	if not res.is_empty() and res["target"] != null and authority.is_valid():
		authority.call(attacker, res["target"], weapon_def, res["is_headshot"])
	return res
