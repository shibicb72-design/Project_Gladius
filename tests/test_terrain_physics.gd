extends "res://tests/test_case.gd"
## M2P1B commit 3: the terrain's one HeightMapShape3D collider under Nav/Ground, checked against Jolt: rays,
## a resting and a walking pawn, hitscan, the cover probe, footsteps and impacts, and a navigation bake.

const MAP := "res://data/maps/test_300.json"
const ALESIA := "res://data/maps/alesia_section.json"
const DT := 1.0 / 60.0
## Measured on Jolt: 0.00001 m on the anti-diagonal split; the other split is off by about 3 mm on the hill.
const RAY_TOL_M := 0.001


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## The built map scene of a map json, in the tree, after two physics frames (new bodies are queryable then).
func _build(json_path: String = MAP) -> Node3D:
	var map: Node3D = load(String(DataRegistry.parse_quiet(json_path)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", json_path)
	_tree().root.add_child(map)
	await _tree().physics_frame
	await _tree().physics_frame
	return map


func _terrain(map: Node3D) -> MapTerrain:
	return map.get_node("ArtBuilder").terrain


func _hill() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)["terrain"]["height_source"]["hills"][0]


## The hill's highest sample near its centre, as a world point.
func _peak(t: MapTerrain) -> Vector3:
	var c: Array = _hill()["centre"]
	var best := Vector3(0, -INF, 0)
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var x := float(c[0]) + dx
			var z := float(c[1]) + dz
			var h := t.height_at(x, z)
			if h > best.y:
				best = Vector3(x, h, z)
	return best


## A point `d` metres from the hill centre: toward the origin (gentle side) for d > 0, away from it for d < 0.
func _on_hill(d: float, side_m: float = 0.0) -> Vector2:
	var c: Array = _hill()["centre"]
	var centre := Vector2(float(c[0]), float(c[1]))
	var to_origin := -centre.normalized()
	return centre + to_origin * d + to_origin.orthogonal() * side_m


## The steepest point on the hill's centre line, gentle side (sign 1) or outer side (sign -1).
func _steepest(t: MapTerrain, sign_: float) -> Vector2:
	var best := Vector2.ZERO
	var best_deg := -1.0
	for i in range(4, 180):
		var p := _on_hill(sign_ * i * 0.25 + 0.13, 0.31)
		var deg := t.slope_deg_at(p.x, p.y)
		if deg > best_deg:
			best_deg = deg
			best = p
	return best


## The surface height on the other quad diagonal than MapTerrain uses (MapTerrain.SPLIT_ANTI_DIAGONAL flipped).
func _other_diagonal_height(t: MapTerrain, x: float, z: float) -> float:
	var half := t.size_m * 0.5
	var u := (clampf(x, -half, half) + half) / t.resolution_m
	var v := (clampf(z, -half, half) + half) / t.resolution_m
	var ix := clampi(floori(u), 0, t.samples - 2)
	var iz := clampi(floori(v), 0, t.samples - 2)
	var fx := u - ix
	var fz := v - iz
	var ha := t.sample(ix, iz)
	var hb := t.sample(ix + 1, iz)
	var hc := t.sample(ix, iz + 1)
	var hd := t.sample(ix + 1, iz + 1)
	if not MapTerrain.SPLIT_ANTI_DIAGONAL:
		if fx + fz <= 1.0:
			return ha + (hb - ha) * fx + (hc - ha) * fz
		return hd - (hd - hc) * (1.0 - fx) - (hd - hb) * (1.0 - fz)
	if fx >= fz:
		return ha + (hb - ha) * fx + (hd - hb) * fz
	return ha + (hd - hc) * fx + (hc - ha) * fz


## The first hit on the body named Ground along from -> to (layer 1); pieces in the way are looked past.
func _ground_hit(map: Node3D, from: Vector3, to: Vector3) -> Dictionary:
	var space := map.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	for i in 16:
		var q := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or (hit["collider"] as Node).name == &"Ground":
			hit["exclude"] = exclude
			return hit
		exclude.append(hit["rid"])
	return {}


func _down_hit(map: Node3D, x: float, z: float) -> Dictionary:
	return _ground_hit(map, Vector3(x, 100.0, z), Vector3(x, -100.0, z))


## Every Nav body but the ground off layer 1, so a pawn meets only the terrain (pieces on the hill are buried
## until step 4).
func _terrain_only(map: Node3D) -> void:
	for body in map.get_node("Nav").get_children():
		if body is CollisionObject3D and body.name != &"Ground":
			(body as CollisionObject3D).collision_layer = 0


func _pawn(map: Node3D, at: Vector3, facing: Vector3 = Vector3.FORWARD) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	map.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_transform = Transform3D(Basis.looking_at(Vector3(facing.x, 0.0, facing.z).normalized()), at)
	pawn.velocity = Vector3.ZERO
	return pawn


## One pawn tick through the normal input path (InputFrame -> set_frame -> _physics_process). Static bodies do
## not move, so the ticks run back to back without waiting for the physics step.
func _step(pawn: Pawn, move: Vector2 = Vector2.ZERO) -> void:
	var frame := InputFrame.new()
	frame.move = move
	pawn.set_frame(frame)
	pawn._physics_process(DT)


## Drops the pawn and ticks until it is on the floor and still; returns the ticks taken (-1: never settled).
func _settle(pawn: Pawn) -> int:
	for i in 300:
		_step(pawn)
		if pawn.is_on_floor() and pawn.velocity.length() < 0.01 and i > 5:
			return i
	return -1


## Origin height above the terrain at the origin's x, z.
func _gap(pawn: Pawn, t: MapTerrain) -> float:
	var p := pawn.global_position
	return p.y - t.height_at(p.x, p.z)


func test_rays_hit_the_height_map_at_height_at() -> void:
	var map: Node3D = await _build()
	var t := _terrain(map)
	var peak := _peak(t)
	var points: Array[Vector2] = [
		Vector2(0, 0), Vector2(12.3, -7.6), Vector2(-33.25, 41.75),
		_on_hill(32.3, 0.3), _on_hill(25.7, -1.85), _on_hill(18.45, 2.6), _on_hill(11.15, -0.4), Vector2(80.75, 68.4),
		_on_hill(-6.3, 0.55), _on_hill(-12.1, -0.85), _on_hill(-18.65, 1.3), Vector2(97.15, 110.45),
		Vector2(peak.x, peak.z), Vector2(90.7, 89.2),
		Vector2(50, 50), Vector2(100, 87.3), Vector2(72.4, 100), Vector2(-100, 50),
		Vector2(149.6, -120.3), Vector2(-149.75, 149.8),
	]
	assert_eq(points.size(), 20, "twenty ray points")
	var worst := 0.0
	var worst_other := 0.0
	var below_split := 0
	var above_split := 0
	var normal_worst_deg := 0.0
	var normal_count := 0
	for p in points:
		var hit := _down_hit(map, p.x, p.y)
		assert_true(not hit.is_empty(), "a ray at %s hits the Ground" % str(p))
		if hit.is_empty():
			continue
		var y := (hit["position"] as Vector3).y
		var err := absf(y - t.height_at(p.x, p.y))
		worst = maxf(worst, err)
		worst_other = maxf(worst_other, absf(y - _other_diagonal_height(t, p.x, p.y)))
		assert_true(err <= RAY_TOL_M, "ray at %s: hit y %.4f, height_at %.4f" % [str(p), y, t.height_at(p.x, p.y)])
		var f := Vector2(fposmod(p.x, 1.0), fposmod(p.y, 1.0))
		if f.x + f.y < 0.95:
			below_split += 1
		elif f.x + f.y > 1.05:
			above_split += 1
		# Normals only inside a triangle: on a grid line or the diagonal the hit may report either neighbour.
		var inside := minf(minf(f.x, f.y), minf(1.0 - f.x, 1.0 - f.y)) > 0.05 and absf(f.x + f.y - 1.0) > 0.05
		if t.slope_deg_at(p.x, p.y) > 5.0 and inside:
			normal_count += 1
			normal_worst_deg = maxf(normal_worst_deg, rad_to_deg((hit["normal"] as Vector3).angle_to(t.normal_at(p.x, p.y))))
	assert_true(below_split >= 3 and above_split >= 3, "points on both sides of a quad diagonal (%d, %d)" % [below_split, above_split])
	assert_true(normal_count >= 6, "nonvacuous: %d slope normals checked" % normal_count)
	assert_true(normal_worst_deg < 0.01, "hit normals match normal_at on the slope (worst %.4f deg)" % normal_worst_deg)
	# The test tells the two splits apart: the one Jolt uses is exact, the other is millimetres off.
	assert_true(worst_other > 5.0 * maxf(worst, RAY_TOL_M * 0.2), "MapTerrain.SPLIT_ANTI_DIAGONAL is the split Jolt uses (other split %.5f m)" % worst_other)
	print("JOLT_RAY max_err_m=%.6f other_diagonal_max_err_m=%.6f normal_worst_deg=%.4f" % [worst, worst_other, normal_worst_deg])
	map.free()


## A pawn's origin height above the terrain when it rests at `at` dropped from 2 m: [gap, slope_deg, ticks, drift].
func _rest(map: Node3D, t: MapTerrain, at: Vector2) -> Array:
	var pawn := _pawn(map, Vector3(at.x, t.height_at(at.x, at.y) + 2.0, at.y))
	var ticks := _settle(pawn)
	var gap := _gap(pawn, t)
	var on_floor := pawn.is_on_floor()
	var settled := pawn.global_position
	for i in 60:
		_step(pawn)
	var drift := pawn.global_position.distance_to(settled)
	assert_true(on_floor and ticks >= 0, "pawn at %s settles on the floor" % str(at))
	assert_true(_gap(pawn, t) > -0.03, "pawn at %s has not fallen through" % str(at))
	pawn.free()
	return [gap, t.slope_deg_at(at.x, at.y), ticks, drift]


func test_pawn_rests_on_the_terrain() -> void:
	var map: Node3D = await _build()
	_terrain_only(map)
	await _tree().physics_frame
	var t := _terrain(map)
	# A capsule (radius 0.4, bottom at the origin) on a plane of slope a touches it off-centre: its origin sits
	# 0.4 * (1 / cos a - 1) above the surface under the origin, on top of the flat offset.
	var radius := 0.4
	var flat: Array = _rest(map, t, Vector2(3.3, -4.7))
	var probe: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	var max_deg := rad_to_deg(probe.floor_max_angle)
	probe.free()
	var report := "flat=%.4f" % flat[0]
	assert_true(absf(flat[0]) < 0.01, "flat ground: feet at the terrain (offset %.4f)" % flat[0])
	var spots := {"gentle": _steepest(t, 1.0), "peak": Vector2(_peak(t).x, _peak(t).z), "outer": _steepest(t, -1.0)}
	for label: String in spots:
		var r: Array = _rest(map, t, spots[label])
		var expected: float = flat[0] + radius * (1.0 / cos(deg_to_rad(r[1])) - 1.0)
		var stands: bool = r[1] < max_deg
		if stands:
			assert_true(absf(r[0] - expected) < 0.02, "%s: origin %.4f above the terrain, expected %.4f at %.1f deg" % [label, r[0], expected, r[1]])
			assert_true(r[3] < 0.01, "%s: no slide over a second (%.4f m)" % [label, r[3]])
		report += " %s=%.4f(expected %.4f, %.1fdeg, ticks %d, drift %.4f)" % [label, r[0], expected, r[1], r[2], r[3]]
	print("JOLT_REST floor_max_angle_deg=%.1f %s" % [max_deg, report])
	map.free()


## Walks the pawn forward until `done` says stop (or max_ticks); returns [min_gap, max_gap, ticks].
func _walk(pawn: Pawn, t: MapTerrain, done: Callable, max_ticks: int = 1500) -> Array:
	var lo := INF
	var hi := -INF
	var ticks := 0
	while ticks < max_ticks and not done.call():
		_step(pawn, Vector2(0, -1))
		ticks += 1
		var gap := _gap(pawn, t)
		lo = minf(lo, gap)
		hi = maxf(hi, gap)
	return [lo, hi, ticks]


func test_pawn_walks_up_and_down_the_gentle_flank() -> void:
	var map: Node3D = await _build()
	_terrain_only(map)
	await _tree().physics_frame
	var t := _terrain(map)
	var c: Array = _hill()["centre"]
	var centre := Vector2(float(c[0]), float(c[1]))
	var foot := _on_hill(46.0)
	var top := _on_hill(4.0)
	var uphill := Vector3(centre.x - foot.x, 0.0, centre.y - foot.y)
	var pawn := _pawn(map, Vector3(foot.x, t.height_at(foot.x, foot.y) + 0.05, foot.y), uphill)
	assert_true(_settle(pawn) >= 0, "pawn settles at the foot")
	var start_y := pawn.global_position.y
	var dist := func() -> float: return Vector2(pawn.global_position.x, pawn.global_position.z).distance_to(centre)
	var up: Array = _walk(pawn, t, func() -> bool: return dist.call() <= 4.0)
	var gained := pawn.global_position.y - start_y
	var want := t.height_at(top.x, top.y) - t.height_at(foot.x, foot.y)
	assert_true(dist.call() <= 4.0, "pawn reaches the top (%.2f m from the centre)" % dist.call())
	assert_true(absf(gained - want) < 0.15, "pawn gains %.3f m going up (terrain %.3f m)" % [gained, want])
	pawn.global_transform = Transform3D(Basis.looking_at(-uphill.normalized()), pawn.global_position)
	var down: Array = _walk(pawn, t, func() -> bool: return dist.call() >= 46.0)
	for _i in 30:
		_step(pawn)
	assert_true(absf(pawn.global_position.y - start_y) < 0.05, "pawn returns to the foot height (%.3f vs %.3f)" % [pawn.global_position.y, start_y])
	var lo := minf(up[0], down[0])
	var hi := maxf(up[1], down[1])
	assert_true(lo > -0.03, "feet never sink into the terrain (lowest gap %.4f m)" % lo)
	assert_true(hi < 0.15, "feet stay on the terrain (highest gap %.4f m)" % hi)
	# Across the chunk border x = 100 on the hill's side (24 degrees there).
	pawn.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(96.0, t.height_at(96.0, 86.5) + 0.05, 86.5))
	pawn.velocity = Vector3.ZERO
	assert_true(_settle(pawn) >= 0, "pawn settles west of the border")
	var border: Array = _walk(pawn, t, func() -> bool: return pawn.global_position.x >= 104.0, 600)
	assert_true(pawn.global_position.x >= 104.0, "pawn crosses the chunk border x = 100")
	assert_true(border[0] > -0.03 and border[1] < 0.15, "across the border the feet stay on the terrain (%.4f..%.4f m)" % [border[0], border[1]])
	print("JOLT_WALK up_ticks=%d up_s=%.2f down_ticks=%d down_s=%.2f gained_m=%.3f terrain_m=%.3f gap_min_m=%.4f gap_max_m=%.4f border_gap_m=%.4f..%.4f" % [up[2], up[2] * DT, down[2], down[2] * DT, gained, want, lo, hi, border[0], border[1]])
	pawn.free()
	map.free()


func _weapon() -> WeaponDef:
	var def := WeaponDef.new()
	def.range_m = 400.0
	def.spread_deg = 0.0
	return def


func test_hitscan_stops_at_the_terrain() -> void:
	var map: Node3D = await _build()
	var t := _terrain(map)
	var space := map.get_world_3d().direct_space_state
	var worst := 0.0
	var slope := _steepest(t, 1.0)
	var target := Vector3(slope.x, t.height_at(slope.x, slope.y), slope.y)
	for origin: Vector3 in [target + Vector3(-6.0, 30.0, 4.0), target + Vector3(3.0, 20.0, -9.0), target + Vector3(0.2, 15.0, 0.1)]:
		var plain := _ground_hit(map, origin, origin + (target - origin) * 3.0)
		assert_true(not plain.is_empty(), "the shot from %s meets the Ground" % str(origin))
		if plain.is_empty():
			continue
		var exclude: Array[RID] = plain["exclude"]
		var hit := Hitscan.cast(space, origin, target - origin, _weapon(), exclude)
		assert_true(not hit.is_empty() and hit["target"] == null, "the hitscan hits the world")
		if hit.is_empty():
			continue
		var at: Vector3 = hit["position"]
		assert_true(at.is_equal_approx(plain["position"]), "the hitscan ends where the Ground ray does")
		worst = maxf(worst, absf(at.y - t.height_at(at.x, at.z)))
	assert_true(worst < RAY_TOL_M, "hitscan ends on the terrain surface (worst %.5f m)" % worst)
	# Aimed at the old box top (y = 0) under the hill's centre: the hill takes the shot first.
	var c: Array = _hill()["centre"]
	var under := Vector3(float(c[0]), 0.0, float(c[1]))
	var from := Vector3(under.x - 60.0, 4.0, under.z)
	var blocked := _ground_hit(map, from, under)
	var no_rids: Array[RID] = []
	var exclude2: Array[RID] = blocked.get("exclude", no_rids)
	var shot := Hitscan.cast(space, from, under - from, _weapon(), exclude2)
	assert_true(not blocked.is_empty() and not shot.is_empty(), "the shot at the buried old ground top hits")
	if not shot.is_empty():
		var p: Vector3 = shot["position"]
		assert_true(p.distance_to(under) > 10.0 and p.y > 0.5, "the hill stops the shot first (%s)" % str(p))
		assert_true(absf(p.y - t.height_at(p.x, p.z)) < RAY_TOL_M, "on the hill's surface")
	print("JOLT_HITSCAN max_err_m=%.6f blocked_at=%s" % [worst, str(shot.get("position", "none"))])
	map.free()


func test_cover_probe_on_the_height_map_ground() -> void:
	var map: Node3D = await _build()
	var builder := map.get_node("ArtBuilder")
	var cfg := DataRegistry.new().load_file("res://data/cover.json")
	var pawn := _pawn(map, Vector3(0, 0, -149))
	await _tree().physics_frame
	var probe := CoverProbe.new()
	var found := 0
	var space := map.get_world_3d().direct_space_state
	for body: StaticBody3D in builder.cover_bodies:
		if found >= 2:
			break
		if not body.is_in_group(&"cover_wall") or Vector2(body.position.x, body.position.z).length() > 60.0:
			continue
		var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		var normal := Vector3.BACK if size.x >= size.z else Vector3.RIGHT
		var at := Vector3(body.position.x, 0.0, body.position.z) + normal * (minf(size.x, size.z) * 0.5 + 0.55)
		var box := BoxShape3D.new()
		box.size = Vector3(0.8, 1.6, 0.8)
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = box
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0, 0.9, 0))
		query.exclude = [map.get_node("Nav/Ground").get_rid(), pawn.get_rid()]
		if not space.intersect_shape(query, 1).is_empty():
			continue
		pawn.global_transform = Transform3D(Basis.looking_at(-normal), at)
		await _tree().physics_frame
		await _tree().physics_frame
		var result := probe.sample(pawn, cfg, false)
		assert_true(bool(result["hit"]) and int(result.get("wall_key", 0)) == body.get_instance_id(), "the probe finds %s on the height-map ground" % body.name)
		found += 1
	assert_eq(found, 2, "two flat-centre cover pieces probed")
	pawn.free()
	map.free()


func test_footsteps_and_impacts_on_the_terrain() -> void:
	var map: Node3D = await _build()
	_terrain_only(map)
	await _tree().physics_frame
	var t := _terrain(map)
	var builder := map.get_node("ArtBuilder")
	var report := ""
	for at: Vector2 in [Vector2(2.4, 6.1), _steepest(t, 1.0), Vector2(_peak(t).x, _peak(t).z)]:
		var pawn := _pawn(map, Vector3(at.x, t.height_at(at.x, at.y) + 0.3, at.y))
		assert_true(_settle(pawn) >= 0, "pawn settles at %s" % str(at))
		pawn.velocity.y = -0.5  # one tick pressing into the floor, so a slide collision names it
		_step(pawn)
		var floor_body: Object = null
		for i in pawn.get_slide_collision_count():
			if pawn.get_slide_collision(i).get_normal().y > 0.6:
				floor_body = pawn.get_slide_collision(i).get_collider()
		assert_true(floor_body is Node and (floor_body as Node).name == &"Ground", "the floor under %s is the Ground body" % str(at))
		var audio := pawn.get_node("Audio") as PawnAudio
		var want := GroundPaint.surface_at(builder.ground_paint, float(builder.ground_size_m), pawn.global_position)
		assert_eq(audio.surface_under(), want, "footstep surface at %s is the ground paint's" % str(at))
		var origin := pawn.global_position + Vector3(1.5, 3.0, 0.5)
		var end := Vector3(at.x + 0.7, t.height_at(at.x + 0.7, at.y - 0.4), at.y - 0.4)
		var self_rids: Array[RID] = [pawn.get_rid()]
		var hit := Hitscan.cast(map.get_world_3d().direct_space_state, origin, end - origin, _weapon(), self_rids)
		assert_true(not hit.is_empty(), "a shot at the ground near %s hits" % str(at))
		if not hit.is_empty():
			assert_eq(audio.impact_material_at(origin, hit["position"]), String(audio.impacts["ground"]), "a hit on the Ground sounds like the data's ground material")
		report += " %s=%s" % [str(at), want]
		pawn.free()
	print("TERRAIN_AUDIO", report)
	map.free()


func test_ground_structure_on_both_maps() -> void:
	var map: Node3D = await _build()
	var t := _terrain(map)
	var nav := map.get_node("Nav")
	var grounds := 0
	for child in nav.get_children():
		if child.name == &"Ground":
			grounds += 1
	assert_eq(grounds, 1, "Nav has exactly one Ground")
	var ground := nav.get_node("Ground") as StaticBody3D
	assert_true(ground != null and ground.collision_layer == 1, "Ground is a StaticBody3D on layer 1")
	assert_eq(ground.get_child_count(), 1, "Ground holds one child")
	assert_true(ground.get_node_or_null("Mesh") == null, "Ground has no Mesh")
	assert_true(ground.transform == Transform3D.IDENTITY, "Ground at the origin")
	var shape := ground.get_node_or_null("Shape") as CollisionShape3D
	var hm := shape.shape as HeightMapShape3D if shape != null else null
	assert_true(hm != null, "Ground/Shape holds a HeightMapShape3D")
	if hm != null:
		assert_eq(hm.map_width, t.samples, "map_width is the sample count")
		assert_eq(hm.map_depth, t.samples, "map_depth is the sample count")
		assert_true(hm.map_data == t.heights, "map_data is the terrain's heights")
		assert_true(shape.transform == Transform3D.IDENTITY, "resolution 1 m needs no scale")
	map.free()
	var alesia: Node3D = await _build(ALESIA)
	var a_ground := alesia.get_node("Nav/Ground")
	assert_true((a_ground.get_node("Mesh") as MeshInstance3D).mesh is BoxMesh, "alesia keeps its box mesh")
	assert_true((a_ground.get_node("Shape") as CollisionShape3D).shape is BoxShape3D, "alesia keeps its box shape")
	alesia.free()


## The builder's collider for a small synthetic terrain at resolution 2 m (shape scale (2, 1, 2)): rays hit at
## height_at, so resolution_m other than 1 is supported.
func test_resolution_two_collider() -> void:
	var block := {"size_m": 40, "resolution_m": 2, "height_source": {"type": "generated", "seed": 7,
			"hills": [{"id": "h", "centre": [4, -3], "height_m": 6, "radius_m": 15, "falloff": "smoothstep"}]}}
	var t := MapTerrain.from_block(block)
	assert_true(t != null and t.samples == 21, "a 40 m terrain at 2 m has 21 samples")
	if t == null:
		return
	var root := Node3D.new()
	_tree().root.add_child(root)
	var nav := Node3D.new()
	root.add_child(nav)
	var builder: Node3D = load("res://scripts/visual/astra_map.gd").new()
	builder.terrain = t
	builder._build_terrain_collider(nav)
	builder.free()
	await _tree().physics_frame
	await _tree().physics_frame
	var shape := nav.get_node("Ground/Shape") as CollisionShape3D
	assert_eq(shape.scale, Vector3(2, 1, 2), "the shape scales x and z by the resolution")
	var space := root.get_world_3d().direct_space_state
	var worst := 0.0
	var count := 0
	for p: Vector2 in [Vector2(0, 0), Vector2(4.3, -2.6), Vector2(-3.7, 1.9), Vector2(9.1, -8.45), Vector2(-17.3, 15.2), Vector2(12.0, 3.3), Vector2(6.6, -11.9)]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 50, p.y), Vector3(p.x, -50, p.y), 1))
		assert_true(not hit.is_empty(), "a ray at %s hits" % str(p))
		if hit.is_empty():
			continue
		count += 1
		worst = maxf(worst, absf((hit["position"] as Vector3).y - t.height_at(p.x, p.y)))
	assert_true(count == 7 and worst < RAY_TOL_M, "resolution 2: rays hit at height_at (worst %.6f m)" % worst)
	print("JOLT_RES2 max_err_m=%.6f" % worst)
	root.free()


func test_navigation_bakes_on_the_terrain() -> void:
	var map: Node3D = await _build()
	var t := _terrain(map)
	var nav := map.get_node("Nav") as NavigationRegion3D
	# The scene's NavigationMesh is shared by every instance of the cached scene: bake a copy.
	nav.navigation_mesh = nav.navigation_mesh.duplicate()
	var started := Time.get_ticks_msec()
	nav.bake_navigation_mesh(false)
	var bake_ms := Time.get_ticks_msec() - started
	var mesh := nav.navigation_mesh
	var verts := mesh.get_vertices()
	var c: Array = _hill()["centre"]
	var centre := Vector2(float(c[0]), float(c[1]))
	var peak := _peak(t)
	var near_peak := 0
	var low_under_hill := 0
	var on_buried_piece := 0
	for v in verts:
		if Vector2(v.x, v.z).distance_to(Vector2(peak.x, peak.z)) < 6.0 and absf(v.y - peak.y) < 1.5:
			near_peak += 1
		if Vector2(v.x, v.z).distance_to(centre) >= 15.0 or v.y >= 2.0:
			continue
		# Pieces stay at y = 0 until step 4 lifts them, so a buried piece's top is a small island inside the
		# hill. Those are allowed here; anything else below 2 m (the old y = 0 ground) is not.
		var buried := false
		for body in nav.get_children():
			if body is StaticBody3D and body.name != &"Ground" and v.y > 0.5 and Vector2(body.position.x, body.position.z).distance_to(Vector2(v.x, v.z)) < 3.0:
				buried = true
		if buried:
			on_buried_piece += 1
		else:
			low_under_hill += 1
	assert_true(mesh.get_polygon_count() > 0, "the bake makes polygons")
	assert_true(near_peak > 0, "the navigation mesh climbs the hill (vertices near the %.2f m peak)" % peak.y)
	assert_eq(low_under_hill, 0, "no walkable layer at y = 0 under the hill")
	print("NAV_TERRAIN polygons=%d vertices=%d bake_ms=%d near_peak=%d buried_piece_island_vertices=%d" % [mesh.get_polygon_count(), verts.size(), bake_ms, near_peak, on_buried_piece])
	map.free()
