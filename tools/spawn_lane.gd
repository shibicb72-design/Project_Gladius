class_name SpawnLane
extends RefCounted
## Fixture helper (dev tool and tests): the line from a pawn to the neighbouring spawn spot, read from the map
## data (data/maps/alesia_section.json "spawns", same ids as the SquadSpawns Marker3Ds). Never invents a spawn.


## Returns {ok, reason, spot_id, spot, dir (flat, normalised), dir_to_muzzle_hit}. `ok` is false when the map has
## fewer than two spawns or world geometry blocks the muzzle-to-spot line (the caller must then stop and report).
static func neighbour_lane(pawn: Pawn, dist_m: float) -> Dictionary:
	var spawns: Dictionary = DataRegistry.new().load_file(DataRegistry.MAP_PATH)["spawns"]
	var ids: Array = spawns.keys()
	ids.sort()
	if ids.size() < 2:
		return {"ok": false, "reason": "fewer than two spawn spots in map data"}
	var here := pawn.global_position
	var nearest := 0
	var best := INF
	for i in ids.size():
		var p := _vec(spawns[ids[i]])
		var d := Vector2(p.x - here.x, p.z - here.z).length_squared()
		if d < best:
			best = d
			nearest = i
	# Both ring neighbours (next, then previous) are tried; camp blocks can close one of the lanes.
	var reasons: Array[String] = []
	for step in [1, ids.size() - 1]:
		var next_id: String = ids[(nearest + step) % ids.size()]
		var spot := _vec(spawns[next_id])
		var flat := Vector3(spot.x - here.x, 0.0, spot.z - here.z)
		if flat.length() < dist_m:
			reasons.append("neighbour spot %s is closer than the requested distance" % next_id)
			continue
		var dir := flat.normalized()
		var muzzle := pawn.get_muzzle_position()
		var q := PhysicsRayQueryParameters3D.create(muzzle, muzzle + dir * dist_m, Hitscan.MASK_WORLD)
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			reasons.append("lane to %s blocked at %s" % [next_id, hit["position"]])
			continue
		return {"ok": true, "reason": "", "spot_id": next_id, "spot": spot, "dir": dir}
	return {"ok": false, "reason": "; ".join(reasons)}


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
