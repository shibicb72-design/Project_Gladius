extends "res://tests/test_case.gd"
## M2P1B commit 4: every piece stands on the terrain (the builder lifts it by the height under its origin, the
## piece files keep their y), and the generator keeps pieces off ground that is too steep or too uneven.

const _Gen := preload("res://tools/gen_test_map.gd")
const MAP := "res://data/maps/test_300.json"
const ALESIA := "res://data/maps/alesia_section.json"
const COVER_TYPES := "res://data/maps/alesia_cover.json"
const LIFT_TOL_M := 0.0001
const PIER_TOL_M := 0.001
const RAISED_M := 0.05  # a piece counts as on raised ground above this |height|


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


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


func _cover_types() -> Dictionary:
	return DataRegistry.parse_quiet(COVER_TYPES)["types"]


## id -> entry of a list.
func _by_id(list: Array) -> Dictionary:
	var out := {}
	for entry: Dictionary in list:
		out[String(entry["id"])] = entry
	return out


## Every piece of a layout ({"cover": cover file, "structures": structures file}) as [id, origin (x, z), footprint],
## the footprint as the generator computes it.
func _footprints(layout: Dictionary) -> Array:
	var types := _cover_types()
	var kit_types: Dictionary = WorldKit.config()["types"]
	var out: Array = []
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Dictionary in layout["cover"][list]:
			var at := Vector2(float(entry["at"][0]), float(entry["at"][2]))
			out.append([entry["id"], at, _Gen._box_rect(at, LowpolyKit.vec(types[entry["type"]]["size"]), 0.0)])
	for entry: Dictionary in layout["cover"]["decor"]:
		var at := Vector2(float(entry["at"][0]), float(entry["at"][2]))
		out.append([entry["id"], at, _Gen._box_rect(at, LowpolyKit.vec(entry["size"]), float(entry["yaw"]))])
	for entry: Dictionary in layout["structures"]["pieces"]:
		var at := Vector2(float(entry["at"][0]), float(entry["at"][2]))
		out.append([entry["id"], at, WorldKit.footprint(kit_types[entry["type"]], LowpolyKit.vec(entry["at"]), float(entry.get("yaw", 0.0)))])
	return out


func _corners(rect: Rect2) -> Array[Vector2]:
	return [rect.position, Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y), rect.end]


func _committed() -> Dictionary:
	var def := _def()
	return {"cover": DataRegistry.parse_quiet(String(def["cover_data"])), "structures": DataRegistry.parse_quiet(String(def["structure_data"]))}


func test_every_piece_is_lifted_with_its_look() -> void:
	var map: Node3D = await _build()
	var builder := map.get_node("ArtBuilder")
	var t: MapTerrain = builder.terrain
	assert_true(t != null, "test_300 has a terrain")
	var layout := _committed()
	var chunks: MapChunks = builder.chunks
	var raised := {"cover": 0, "ring": 0, "structure": 0, "decor": 0, "decor_solid": 0}
	var highest_id := ""
	var highest_h := -INF
	var groups := {"cover": [builder.cover_bodies, layout["cover"]["pieces"]], "ring": [builder.ring_bodies, layout["cover"]["ring_pieces"]], "structure": [builder.structure_bodies, layout["structures"]["pieces"]]}
	for source: String in groups:
		var bodies: Array = groups[source][0]
		var entries := _by_id(groups[source][1])
		assert_eq(bodies.size(), entries.size(), source + ": one body per file entry")
		for body: StaticBody3D in bodies:
			var entry: Dictionary = entries[String(body.name)]
			var at := LowpolyKit.vec(entry["at"])
			var h := t.height_at(at.x, at.z)
			assert_true(absf(body.position.y - (at.y + h)) < LIFT_TOL_M, "%s: y %.4f = file y %.4f + terrain %.4f" % [body.name, body.position.y, at.y, h])
			assert_true(is_equal_approx(body.position.x, at.x) and is_equal_approx(body.position.z, at.z), "%s: x, z unchanged" % body.name)
			var type := String(body.get_meta(&"structure_type")) if source == "structure" else String(entry["type"])
			assert_true(chunks.batch_of(source, type, body.transform) != null, "%s: its look is in the batch at the body's transform" % body.name)
			if absf(h) > RAISED_M:
				raised[source] += 1
			if h > highest_h:
				highest_h = h
				highest_id = String(body.name)
	var solid_of := {}
	for body: StaticBody3D in builder.decor_bodies:
		solid_of[String(body.get_meta(&"decor_id"))] = body
	for entry: Dictionary in layout["cover"]["decor"]:
		var id := String(entry["id"])
		var at := LowpolyKit.vec(entry["at"])
		var h := t.height_at(at.x, at.z)
		var xform := Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(float(entry["yaw"])), 0.0)), at + Vector3(0.0, h, 0.0))
		assert_true(chunks.batch_of("decor", String(builder.decor_types[id]), xform) != null, id + ": decor look at the lifted transform")
		if absf(h) > RAISED_M:
			raised["decor"] += 1
		if h > highest_h:
			highest_h = h
			highest_id = id
		if solid_of.has(id):
			var body: StaticBody3D = solid_of[id]
			assert_true(absf(body.position.y - (at.y + h)) < LIFT_TOL_M, id + ": solid decor body lifted")
			if absf(h) > RAISED_M:
				raised["decor_solid"] += 1
	for kind: String in raised:
		assert_true(int(raised[kind]) > 0, "nonvacuous: some %s stands on raised ground (%d)" % [kind, raised[kind]])
	print("PIECES_LIFT raised=%s highest=%s h=%.3f" % [str(raised), highest_id, highest_h])
	map.free()


func test_arch_piers_end_at_the_terrain() -> void:
	var map: Node3D = await _build()
	var builder := map.get_node("ArtBuilder")
	var t: MapTerrain = builder.terrain
	var entries := _by_id(_committed()["cover"]["decor"])
	var arches := 0
	var raised := 0
	for body: StaticBody3D in builder.decor_bodies:
		var left := body.get_node_or_null("PierLeft") as CollisionShape3D
		if left == null:
			continue
		arches += 1
		var entry: Dictionary = entries[String(body.get_meta(&"decor_id"))]
		var flat := WorldKit.decor_body(entry, "piers_and_lintel", null)
		var ground := t.height_at(body.position.x, body.position.z)
		if absf(ground) > RAISED_M:
			raised += 1
		for pier: String in ["PierLeft", "PierRight"]:
			var node := body.get_node(pier) as CollisionShape3D
			var half := (node.shape as BoxShape3D).size.y * 0.5
			var bottom := body.position.y + node.position.y - half
			assert_true(absf(bottom - ground) < PIER_TOL_M, "%s %s: pier bottom %.4f on the ground %.4f" % [body.name, pier, bottom, ground])
			var ref := flat.get_node(pier) as CollisionShape3D
			var top := node.position.y + half
			var ref_top := ref.position.y + (ref.shape as BoxShape3D).size.y * 0.5
			assert_true(absf(top - ref_top) < LIFT_TOL_M, "%s %s: pier top unchanged relative to the piece" % [body.name, pier])
		flat.free()
	assert_true(arches > 0 and raised > 0, "nonvacuous: %d arches, %d on raised ground" % [arches, raised])
	map.free()
	# Direct calls: lift 5 puts the pier bottoms at y = 5; lift 0 is exactly the 3-argument call.
	var entry := {"id": "ArchTest", "kind": "arch", "size": [6.0, 5.0, 1.5], "at": [3.0, 2.5, -4.0], "yaw": 90.0}
	var lifted := WorldKit.decor_body(entry, "piers_and_lintel", null, 5.0)
	for pier: String in ["PierLeft", "PierRight"]:
		var node := lifted.get_node(pier) as CollisionShape3D
		var bottom := lifted.position.y + node.position.y - (node.shape as BoxShape3D).size.y * 0.5
		assert_true(absf(bottom - 5.0) < PIER_TOL_M, "lift 5: pier bottom at y = 5 (%.4f)" % bottom)
	var zero := WorldKit.decor_body(entry, "piers_and_lintel", null, 0.0)
	var plain := WorldKit.decor_body(entry, "piers_and_lintel", null)
	assert_eq(zero.transform, plain.transform, "lift 0: same body transform")
	assert_eq(zero.get_child_count(), plain.get_child_count(), "lift 0: same shapes")
	for i in plain.get_child_count():
		var a := zero.get_child(i) as CollisionShape3D
		var b := plain.get_child(i) as CollisionShape3D
		assert_true(a.name == b.name and a.transform == b.transform and (a.shape as BoxShape3D).size == (b.shape as BoxShape3D).size, "lift 0: %s identical" % b.name)
	for body: Node in [lifted, zero, plain]:
		body.free()


func test_footprints_stay_on_fit_ground() -> void:
	var t := MapTerrain.for_map(_def())
	assert_eq(t.max_piece_float_m, 0.3, "the data's float limit")
	var worst_corner := 0.0
	var worst_slope := 0.0
	var pieces := _footprints(_committed())
	for piece: Array in pieces:
		var at: Vector2 = piece[1]
		var origin := t.height_at(at.x, at.y)
		var slope := t.slope_deg_at(at.x, at.y)
		worst_slope = maxf(worst_slope, slope)
		assert_true(slope <= t.max_piece_slope_deg, "%s: origin slope %.2f deg within the limit" % [piece[0], slope])
		for corner in _corners(piece[2]):
			var d := absf(t.height_at(corner.x, corner.y) - origin)
			worst_corner = maxf(worst_corner, d)
			assert_true(d <= t.max_piece_float_m, "%s: corner %s within %.2f m of the origin height (%.3f)" % [piece[0], str(corner), t.max_piece_float_m, d])
	assert_true(pieces.size() > 500, "nonvacuous: %d pieces" % pieces.size())
	print("PIECES_FLOAT max_corner_m=%.4f max_origin_slope_deg=%.3f pieces=%d" % [worst_corner, worst_slope, pieces.size()])


func test_the_ground_filter_bites() -> void:
	var def := _def()
	var t := MapTerrain.for_map(def)
	var flat_def := def.duplicate(true)
	flat_def.erase("terrain")
	var flat := _Gen.generate(flat_def)
	assert_eq(int(flat["ground_rejects"]), 0, "no terrain, no ground rejects")
	var bad_flat := 0
	for piece: Array in _footprints(flat):
		if not _Gen.ground_fits(t, piece[1], piece[2]):
			bad_flat += 1
	var bad_committed := 0
	for piece: Array in _footprints(_committed()):
		if not _Gen.ground_fits(t, piece[1], piece[2]):
			bad_committed += 1
	assert_true(bad_flat > 0, "the flat layout would put %d pieces on unfit ground" % bad_flat)
	assert_eq(bad_committed, 0, "the committed layout has none")
	print("PIECES_FILTER flat_layout_unfit=%d committed_unfit=%d" % [bad_flat, bad_committed])


func test_spawns_stay_on_flat_ground() -> void:
	var def := _def()
	var t := MapTerrain.for_map(def)
	var spawns: Dictionary = def["spawns"]
	for id: String in spawns:
		assert_eq(t.height_at(float(spawns[id][0]), float(spawns[id][2])), 0.0, id + ": terrain exactly 0 at the spawn")
	var scene: Node3D = load(String(def["scene"])).instantiate()
	var markers := scene.get_node("SquadSpawns").get_children()
	assert_eq(markers.size(), spawns.size(), "one marker per spawn")
	for marker: Node3D in markers:
		assert_true(is_equal_approx(marker.position.y, 0.1), "%s: marker y stays 0.1" % marker.name)
	scene.free()


func test_alesia_pieces_unchanged() -> void:
	var map: Node3D = await _build(ALESIA)
	var builder := map.get_node("ArtBuilder")
	assert_true(builder.terrain == null, "alesia has no terrain")
	var cfg := DataRegistry.parse_quiet(COVER_TYPES)
	var entries := _by_id(cfg["pieces"])
	assert_true(builder.cover_bodies.size() > 0, "nonvacuous: alesia cover bodies")
	for body: StaticBody3D in builder.cover_bodies:
		assert_eq(body.position, LowpolyKit.vec(entries[String(body.name)]["at"]), String(body.name) + ": at its file position")
	var decor := _by_id(cfg["decor"])
	for body: StaticBody3D in builder.decor_bodies:
		assert_eq(body.position, LowpolyKit.vec(decor[String(body.get_meta(&"decor_id"))]["at"]), String(body.name) + ": decor body at its file position")
	map.free()


## Coverable cover and ring bodies on raised ground, highest first.
func _raised_cover(builder: Node, t: MapTerrain) -> Array:
	var out: Array = []
	for list: Array in [builder.cover_bodies, builder.ring_bodies]:
		for body: StaticBody3D in list:
			if body.is_in_group(&"cover_wall") and t.height_at(body.position.x, body.position.z) > RAISED_M:
				out.append(body)
	out.sort_custom(func(a: StaticBody3D, b: StaticBody3D) -> bool: return t.height_at(a.position.x, a.position.z) > t.height_at(b.position.x, b.position.z))
	return out


func test_cover_probe_on_a_lifted_piece() -> void:
	var map: Node3D = await _build()
	var builder := map.get_node("ArtBuilder")
	var t: MapTerrain = builder.terrain
	var cfg := DataRegistry.new().load_file("res://data/cover.json")
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	map.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = Vector3(0, 0, -149)
	await _tree().physics_frame
	var probe := CoverProbe.new()
	var space := map.get_world_3d().direct_space_state
	var found := 0
	var probed := ""
	for body: StaticBody3D in _raised_cover(builder, t):
		if found >= 2:
			break
		var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		var normal := Vector3.BACK if size.x >= size.z else Vector3.RIGHT
		var at := Vector3(body.position.x, 0.0, body.position.z) + normal * (minf(size.x, size.z) * 0.5 + 0.55)
		at.y = t.height_at(at.x, at.z)
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
		var h := t.height_at(body.position.x, body.position.z)
		assert_true(bool(result["hit"]) and int(result.get("wall_key", 0)) == body.get_instance_id(), "the probe finds %s on ground %.2f m up (slope %.1f deg)" % [body.name, h, t.slope_deg_at(body.position.x, body.position.z)])
		probed += "%s@%.2f " % [body.name, h]
		found += 1
	assert_eq(found, 2, "two lifted cover pieces probed")
	print("PIECES_PROBE ", probed)
	pawn.free()
	map.free()


func test_hitscan_hits_a_lifted_piece() -> void:
	var map: Node3D = await _build()
	var builder := map.get_node("ArtBuilder")
	var t: MapTerrain = builder.terrain
	var space := map.get_world_3d().direct_space_state
	var weapon := WeaponDef.new()
	weapon.range_m = 400.0
	weapon.spread_deg = 0.0
	var shot := false
	for body: StaticBody3D in _raised_cover(builder, t):
		var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		var centre := body.position
		# Shoot level at the piece's centre from 3 m off its downhill face (the terrain stays under the shot).
		var best := Vector3.ZERO
		var best_h := INF
		for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
			var reach := absf(dir.x) * size.x * 0.5 + absf(dir.z) * size.z * 0.5 + 3.0
			var p := centre + dir * reach
			if t.height_at(p.x, p.z) < best_h:
				best_h = t.height_at(p.x, p.z)
				best = p
		if best_h > centre.y - 0.2:
			continue
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(best, centre, 1))
		if hit.is_empty() or hit["collider"] != body:
			continue
		var none: Array[RID] = []
		var cast := Hitscan.cast(space, best, centre - best, weapon, none)
		assert_true(not cast.is_empty() and cast["target"] == null, "%s: the hitscan hits the world" % body.name)
		if cast.is_empty():
			break
		var at: Vector3 = cast["position"]
		var h := t.height_at(body.position.x, body.position.z)
		assert_true(at.is_equal_approx(hit["position"]), "%s: the hitscan ends on the piece" % body.name)
		assert_true(absf(at.y - centre.y) < PIER_TOL_M and at.y > h, "%s: hit at the lifted height %.3f (ground %.3f)" % [body.name, at.y, h])
		assert_true(absf(at.y - t.height_at(at.x, at.z)) > 0.1, "%s: the hit is not on the terrain surface" % body.name)
		print("PIECES_HITSCAN piece=%s ground_m=%.3f hit_y=%.3f" % [body.name, h, at.y])
		shot = true
		break
	assert_true(shot, "a lifted piece was shot")
	map.free()
