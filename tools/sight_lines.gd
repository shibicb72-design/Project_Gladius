extends SceneTree
## M2 L2a (OQ-ALESIA-500): how far a standing player sees on a map. Builds the map scene headless (as
## tests/test_alesia_1km.gd does) and casts, from eye points, horizontal rays against its real colliders
## (Hitscan.MASK_WORLD: terrain, cover, structures, solid decor, breakables, chests, doors in their start state).
## - Points: a grid every grid_m (10 m) over the play circle, at eye_m (1.65 m) above the ground, on WALKABLE ground
##   (no collider at the knee or at the eye), plus one eye point on the deck of every wall_walk piece.
## - Rays: rays_per_point (16, 22.5 degree steps), capped at max_m (200 m); a ray "travels past 80 m" (far_m) when
##   it hits nothing within far_m.
## - Districts: alesia_500 (a map with generator.town): arx_top, hill_ring_road (hill skirt and ring road up to the
##   inner wall), town, camps (inside a camp block), fields (to the outer wall), outside. alesia_1km: arx_top,
##   arx (the hill skirt), inner_ring (hill foot to the inner wall), camp_ring (to the outer wall), fields. Main
##   streets (within street_m of a gate road from the centre along any inner or outer gate bearing, or of the ring
##   road), wall walks and the Arx top are listed separately and kept out of the district numbers.
## Prints SIGHT_LINES map=<id> district=<d> points=<n> rays=<n> past_80m_share=<x> per district, then "all" (the
## districts together), and the map's report-only target (sight_lines.target_share_past_80m) when it has one.
##   godot --headless --path . --script res://tools/sight_lines.gd --log-file <log> -- --map=<id>
## Static use (tests): measure(map_root, map_def) after the map has been in the tree for a physics frame.

const SETTINGS := {"grid_m": 10.0, "eye_m": 1.65, "knee_m": 0.5, "rays_per_point": 16, "max_m": 200.0, "far_m": 80.0, "street_m": 4.0}


func _initialize() -> void:
	var id := "alesia_500"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			id = arg.substr(6)
	var path := id if id.begins_with("res://") else "res://data/maps/%s.json" % id
	var def := DataRegistry.parse_quiet(path)
	if def.is_empty():
		printerr("SIGHT_LINES problem: %s is missing" % path)
		quit(1)
		return
	await process_frame
	var map: Node3D = load(String(def["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", path)
	root.add_child(map)
	await physics_frame
	await physics_frame
	var started := Time.get_ticks_msec()
	var result := measure(map, def)
	for line: String in report_lines(String(def.get("id", id)), result, def):
		print(line)
	print("SIGHT_LINES map=%s ms=%d" % [String(def.get("id", id)), Time.get_ticks_msec() - started])
	map.queue_free()
	await process_frame
	quit(0)


## {district -> {points, rays, past}} for a built map (in the tree, physics registered).
static func measure(map: Node3D, def: Dictionary, settings: Dictionary = SETTINGS) -> Dictionary:
	var builder := map.get_node("ArtBuilder")
	var terrain: MapTerrain = builder.get("terrain")
	var space := map.get_world_3d().direct_space_state
	var gen: Dictionary = def.get("generator", {})
	var play_r := float(def["play_radius_m"])
	var step := float(settings["grid_m"])
	var out := {}
	var n := floori(play_r / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := Vector2(i * step, j * step)
			if p.length() > play_r:
				continue
			var ground := terrain.height_at(p.x, p.y) if terrain != null else 0.0
			if _inside(space, Vector3(p.x, ground + float(settings["knee_m"]), p.y)) or _inside(space, Vector3(p.x, ground + float(settings["eye_m"]), p.y)):
				continue  # not walkable: inside a collider
			_cast(space, Vector3(p.x, ground + float(settings["eye_m"]), p.y), district_of(p, def), out, settings)
	# One eye point on every wall walk's deck (the ray down from above lands on the piece itself).
	for entry: Dictionary in WorldKit.pieces_for(def):
		if String(entry["type"]) != "wall_walk":
			continue
		var at := LowpolyKit.vec(entry["at"])
		var top := (terrain.height_at(at.x, at.z) if terrain != null else 0.0) + 40.0
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(at.x, top, at.z), Vector3(at.x, top - 60.0, at.z), Hitscan.MASK_WORLD))
		if hit.is_empty() or String((hit["collider"] as Node).name) != String(entry["id"]):
			continue
		_cast(space, (hit["position"] as Vector3) + Vector3(0.0, float(settings["eye_m"]), 0.0), "wall_walks", out, settings)
	return out


static func _inside(space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = at
	q.collision_mask = Hitscan.MASK_WORLD
	return not space.intersect_point(q, 1).is_empty()


static func _cast(space: PhysicsDirectSpaceState3D, eye: Vector3, district: String, out: Dictionary, settings: Dictionary) -> void:
	if not out.has(district):
		out[district] = {"points": 0, "rays": 0, "past": 0}
	var d: Dictionary = out[district]
	d["points"] = int(d["points"]) + 1
	var rays := int(settings["rays_per_point"])
	for k in rays:
		var a := TAU * k / rays
		var dir := Vector3(sin(a), 0.0, -cos(a))
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + dir * float(settings["max_m"]), Hitscan.MASK_WORLD))
		var dist := float(settings["max_m"]) if hit.is_empty() else eye.distance_to(hit["position"])
		d["rays"] = int(d["rays"]) + 1
		if dist > float(settings["far_m"]):
			d["past"] = int(d["past"]) + 1


## The district of a ground point (x, z) on `def`'s map (see the header).
static func district_of(p: Vector2, def: Dictionary, street_m: float = float(SETTINGS["street_m"])) -> String:
	var gen: Dictionary = def.get("generator", {})
	var r := p.length()
	var hill: Dictionary = gen.get("hill", {})
	if not hill.is_empty() and r < float(hill["top_radius_m"]):
		return "arx_top"
	var ring_road := _ring_road(def)
	if ring_road > 0.0 and absf(r - ring_road) <= street_m:
		return "main_streets"
	var bearings: Array = []
	for key: String in ["inner_wall", "outer_wall"]:
		bearings.append_array((gen.get(key, {}) as Dictionary).get("gate_bearings_deg", []))
	for b: Variant in bearings:
		var d := Vector2(sin(deg_to_rad(float(b))), -cos(deg_to_rad(float(b))))
		var along := p.dot(d)
		if along > 0.0 and absf(p.x * d.y - p.y * d.x) <= street_m:
			return "main_streets"
	var inner := float((gen.get("inner_wall", {}) as Dictionary).get("radius_m", 0.0))
	var outer := float((gen.get("outer_wall", {}) as Dictionary).get("radius_m", 0.0))
	if gen.has("town"):
		if r < inner:
			return "hill_ring_road"
		var camps: Dictionary = gen["camps"]
		var half := float(camps["half_size_m"])
		for c in (camps["names"] as Array).size():
			var b := deg_to_rad(float(camps["first_bearing_deg"]) + 60.0 * c)
			var centre := Vector2(sin(b), -cos(b)) * float(camps["radius_m"])
			if absf(p.x - centre.x) <= half and absf(p.y - centre.y) <= half:
				return "camps"
		var town: Dictionary = gen["town"]
		if r <= float(town["band_to_m"]) + float(town["block_m"]) * 0.5:
			return "town"
		return "fields" if r <= outer else "outside"
	if r < float(hill.get("radius_m", 0.0)):
		return "arx"
	if r < inner:
		return "inner_ring"
	return "camp_ring" if r <= outer else "fields"


static func _ring_road(def: Dictionary) -> float:
	for key: Variant in def:
		if typeof(def[key]) == TYPE_DICTIONARY and (def[key] as Dictionary).has("ring_road_radius_m"):
			return float(def[key]["ring_road_radius_m"])
	return 0.0


## The report: one line per district (sorted), the separate lists, then "all" over the districts only.
static func report_lines(map_id: String, result: Dictionary, def: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var separate := ["arx_top", "main_streets", "wall_walks"]
	var total := {"points": 0, "rays": 0, "past": 0}
	var keys: Array = result.keys()
	keys.sort()
	for key: String in keys:
		var d: Dictionary = result[key]
		lines.append("SIGHT_LINES map=%s district=%s points=%d rays=%d past_80m_share=%.3f%s" % [map_id, key, int(d["points"]), int(d["rays"]),
			float(d["past"]) / maxf(1.0, float(d["rays"])), " (listed separately)" if separate.has(key) else ""])
		if not separate.has(key):
			for k: String in total:
				total[k] = int(total[k]) + int(d[k])
	lines.append("SIGHT_LINES map=%s district=all points=%d rays=%d past_80m_share=%.3f (the districts, without the separate lists)" % [map_id, int(total["points"]), int(total["rays"]), float(total["past"]) / maxf(1.0, float(total["rays"]))])
	var target: Variant = (def.get("sight_lines", {}) as Dictionary).get("target_share_past_80m")
	if target != null:
		lines.append("SIGHT_LINES map=%s target_share_past_80m=%s (report only, OQ-ALESIA-500)" % [map_id, str(target)])
	return lines
