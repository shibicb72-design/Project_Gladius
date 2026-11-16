class_name Backdrop
extends Node3D
## S6: what stands beyond the playable ground so the map has a horizon: a ground skirt, the outer wall ring
## with towers, far spires, the aqueduct's run towards the hills, and two rings of hills. Data:
## data/art_backdrop.json (placeholders, OQ-GFX-BACKDROP). Looks only: no body, no collider, nothing under the
## map's Nav node, and every piece is outside the ground square (tests/test_backdrop.gd), so it changes
## nowhere a player can walk, hide or shoot. One batch per kind of piece.

const PATH := "res://data/art_backdrop.json"
static var _registry := DataRegistry.new()
static var _meshes := {}

## For the tests: [{kind, at: Vector3, half: Vector2}] of everything placed (half = footprint half extents).
var placed: Array[Dictionary] = []


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func _mesh(key: String, parts: Array) -> ArrayMesh:
	if not _meshes.has(key):
		var kit_parts: Array = []
		for part: Dictionary in parts:
			kit_parts.append(WorldKit._kit_part(part))
		_meshes[key] = LowpolyKit.merge(kit_parts)
	return _meshes[key]


## M2W1 item 9: `map_json` names the map; a map with a block under data "maps" (key: the file name without .json)
## gets that block's far backdrop (_build_far) instead of the small maps' one, which stays exactly as before.
func build(ground_material: Material, map_json: String = "", terrain: MapTerrain = null) -> void:
	var cfg := config()
	var block: Dictionary = (cfg.get("maps", {}) as Dictionary).get(map_json.get_file().get_basename(), {}) if map_json != "" else {}
	if not block.is_empty():
		_build_far(block, ground_material, terrain)
		return
	_build_skirt(cfg["skirt"], ground_material)
	_build_wall(cfg["outer_wall"])
	_build_spires(cfg["spires"])
	_build_aqueduct(cfg["aqueduct_run"])
	_build_hills(cfg["hills"])


func _batch(batch_name: String, mesh: Mesh, transforms: Array[Transform3D], shadows: bool) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i in transforms.size():
		multi.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.name = batch_name
	node.multimesh = multi
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _note(kind: String, at: Vector3, half: Vector2, turn: Basis = Basis.IDENTITY) -> void:
	placed.append({"kind": kind, "at": at, "half": half, "basis": turn})


func _build_skirt(cfg: Dictionary, ground_material: Material) -> void:
	if ground_material == null:
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * float(cfg["size_m"])
	var node := MeshInstance3D.new()
	node.name = "GroundSkirt"
	node.mesh = plane
	node.material_override = ground_material
	node.position.y = float(cfg["y_m"])
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _build_wall(cfg: Dictionary) -> void:
	var radius := float(cfg["radius_m"])
	var count := int(cfg["segments"])
	var every := int(cfg["tower_every"])
	var walls: Array[Transform3D] = []
	var towers: Array[Transform3D] = []
	for i in count:
		var angle := TAU * (float(i) + 0.5) / count
		var at := Vector3(cos(angle), 0.0, sin(angle)) * radius
		walls.append(Transform3D(Basis.looking_at(-at.normalized()), at))  # -Z, the decorated face, looks at the map
		_note("wall", at, Vector2(float(cfg["segment_length_m"]) * 0.5, 2.4), walls[-1].basis)
		if every > 0 and i % every == 0:
			var joint := TAU * float(i) / count
			var tower_at := Vector3(cos(joint), 0.0, sin(joint)) * (radius + 0.6)
			towers.append(Transform3D(Basis.looking_at(-tower_at.normalized()), tower_at))
			_note("tower", tower_at, Vector2(4.2, 4.2), towers[-1].basis)
	var shadows := bool(cfg["cast_shadows"])
	_batch("OuterWall", _mesh("wall", cfg["segment_parts"]), walls, shadows)
	_batch("OuterTowers", _mesh("tower", cfg["tower_parts"]), towers, shadows)


func _build_spires(cfg: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	for entry: Array in cfg["at"]:
		var at := Vector3(float(entry[0]), 0.0, float(entry[1]))
		var scale := float(entry[3])
		transforms.append(Transform3D(Basis(Vector3.UP, deg_to_rad(float(entry[2]))).scaled(Vector3.ONE * scale), at))
		_note("spire", at, Vector2(4.5, 4.5) * scale, Basis(Vector3.UP, deg_to_rad(float(entry[2]))))
	_batch("Spires", _mesh("spire", cfg["parts"]), transforms, bool(cfg["cast_shadows"]))


func _build_aqueduct(cfg: Dictionary) -> void:
	var type := String(cfg["type"])
	if not (WorldKit.config()["types"] as Dictionary).has(type):
		return
	var transforms: Array[Transform3D] = []
	var turn := Basis(Vector3.UP, deg_to_rad(float(cfg["yaw_deg"])))
	var rect := WorldKit.footprint(WorldKit.config()["types"][type], Vector3.ZERO, float(cfg["yaw_deg"]))
	for run: Dictionary in cfg["runs"]:
		for i in int(run["count"]):
			var at := Vector3(float(run["first"][0]) + float(run["step"][0]) * i, 0.0, float(run["first"][1]) + float(run["step"][1]) * i)
			transforms.append(Transform3D(turn, at))
			_note("aqueduct", at, rect.size * 0.5)
	_batch("AqueductRun", WorldKit.mesh_for(type), transforms, bool(cfg["cast_shadows"]))


## Two rings of hills: a jagged ridge between an inner and an outer foot, flat shaded like the kit.
func _build_hills(cfg: Dictionary) -> void:
	if not _meshes.has("hills"):
		_meshes["hills"] = _hills_mesh(cfg)
	var node := MeshInstance3D.new()
	node.name = "Hills"
	node.mesh = _meshes["hills"]
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _hills_mesh(cfg: Dictionary) -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.seed = int(cfg["seed"])
	noise.frequency = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	LowpolyKit._surface = WorldSurface.surface_id(String(cfg["surface"]))
	var ring_index := 0
	for ring: Dictionary in cfg["rings"]:
		var segments := int(ring["segments"])
		var radius := float(ring["radius_m"])
		var depth := float(ring["depth_m"])
		var color := GreyboxArt.color_value(ring["color"])
		var inner: Array[Vector3] = []
		var ridge: Array[Vector3] = []
		var outer: Array[Vector3] = []
		for i in segments:
			var angle := TAU * float(i) / segments
			var out := Vector3(cos(angle), 0.0, sin(angle))
			var n := noise.get_noise_2d(cos(angle) * 1.7 + ring_index * 9.0, sin(angle) * 1.7) * 0.5 + 0.5
			var n2 := noise.get_noise_2d(cos(angle) * 9.3 + 3.0, sin(angle) * 9.3 + ring_index * 5.0) * 0.5 + 0.5
			# Peaks and saddles: every other ridge point is pulled down, the broad noise sets the range.
			var jag := 1.0 if i % 2 == 0 else 0.55
			var height := float(ring["height_m"]) * lerpf(1.0 - float(ring["rough"]), 1.0, clampf((n * 0.6 + n2 * 0.4) * 1.4 - 0.2, 0.0, 1.0)) * jag
			inner.append(out * radius - Vector3.UP * 2.0)
			ridge.append(out * (radius + depth * (0.35 + 0.2 * n2)) + Vector3.UP * height)
			outer.append(out * (radius + depth) - Vector3.UP * 2.0)
		for i in segments:
			var j := (i + 1) % segments
			LowpolyKit._shade = 0.5 + 0.5 * sin(float(i) * 12.9898 + ring_index)
			# Towards the map: inner foot up to the ridge. Away from it: ridge down to the outer foot.
			# Corner order: (b - a) x (c - a) points out of the hill (up and towards the viewer's side).
			LowpolyKit._triangle(st, inner[i], ridge[j], ridge[i], color)
			LowpolyKit._triangle(st, inner[i], inner[j], ridge[j], color)
			LowpolyKit._triangle(st, ridge[i], outer[j], outer[i], color)
			LowpolyKit._triangle(st, ridge[i], ridge[j], outer[j], color)
		ring_index += 1
	LowpolyKit._surface = -1
	var mesh := st.commit()
	mesh.surface_set_material(0, WorldSurface.material())
	return mesh


# --- M2W1 item 9: the far backdrop of a large map (data "maps".<map>; placeholders, OQ-ART-WORLD) ---
## A rolling ground skirt from the ground square out to its outer steps (the ground material, so the ground shader's
## macro variety carries on), rings of low-poly hills and far mountains (seeded noise on radius and height), a far
## aqueduct line on arches, watch beacons with glowing tips on the near ridge and dark cypress clumps on the skirt.
## No wall ring, towers or spires (the map's own outer wall is its edge). One node per kind, no shadows, no body.

var _far_cfg := {}
var _far_half := 500.0
var _far_terrain: MapTerrain
var _far_noise: FastNoiseLite
## Ridge tops of the first hill ring, in ring order (the beacons stand on them).
var _near_ridge: Array[Vector3] = []


func _build_far(block: Dictionary, ground_material: Material, terrain: MapTerrain) -> void:
	_far_cfg = block
	_far_half = float(block.get("ground_half_m", 500.0))
	_far_terrain = terrain
	_far_noise = FastNoiseLite.new()
	_far_noise.seed = int(block["skirt"]["seed"])
	_far_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_far_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_far_noise.fractal_octaves = 3
	_far_noise.frequency = 1.0 / float(block["skirt"]["roll_noise_m"])
	if ground_material != null:
		_build_far_skirt(block["skirt"], ground_material)
	_build_far_hills(block["hills"])
	if block.has("aqueduct"):
		_build_far_aqueduct(block["aqueduct"])
	if block.has("beacons"):
		_build_far_beacons(block["beacons"])
	if block.has("trees"):
		_build_far_trees(block["trees"])


## The skirt's height at (x, z): the terrain at the nearest point of the ground square's edge, blending into a
## rolling noise field from roll_from_m to roll_full_m beyond the edge (minus sink_m, so the terrain wins at the seam).
func skirt_height(x: float, z: float) -> float:
	var s: Dictionary = _far_cfg["skirt"]
	var edge := Vector2(clampf(x, -_far_half, _far_half), clampf(z, -_far_half, _far_half))
	var d := Vector2(x, z).distance_to(edge)
	var base := 0.0
	if _far_terrain != null:
		base = _far_terrain.height_at(clampf(edge.x, -_far_half + 0.01, _far_half - 0.01), clampf(edge.y, -_far_half + 0.01, _far_half - 0.01))
	var t := smoothstep(float(s["roll_from_m"]), float(s["roll_full_m"]), d)
	var roll := (_far_noise.get_noise_2d(x, z) * 0.5 + 0.5) * float(s["roll_m"]) + d * float(s.get("rise_per_m", 0.0))
	return lerpf(base, roll, t) - float(s["sink_m"])


func _axis_coords(s: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var far := PackedFloat32Array()
	var at := _far_half
	for step: Variant in s["outer_steps_m"]:
		at += float(step)
		far.append(at)
	for i in range(far.size() - 1, -1, -1):
		out.append(-far[i])
	var n := roundi(_far_half * 2.0 / float(s["edge_step_m"]))
	for i in n + 1:
		out.append(-_far_half + _far_half * 2.0 * float(i) / float(n))
	out.append_array(far)
	return out


func _build_far_skirt(s: Dictionary, ground_material: Material) -> void:
	var xs := _axis_coords(s)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var e := 2.0  # metres for the normal's finite differences
	for iz in xs.size() - 1:
		for ix in xs.size() - 1:
			if absf((xs[ix] + xs[ix + 1]) * 0.5) < _far_half and absf((xs[iz] + xs[iz + 1]) * 0.5) < _far_half:
				continue  # the ground square: the terrain draws it
			var corners := [Vector2i(ix, iz), Vector2i(ix + 1, iz), Vector2i(ix + 1, iz + 1), Vector2i(ix, iz + 1)]
			for k: int in [0, 1, 2, 0, 2, 3]:
				var c: Vector2i = corners[k]
				var x := xs[c.x]
				var z := xs[c.y]
				st.set_normal(Vector3(skirt_height(x - e, z) - skirt_height(x + e, z), 2.0 * e, skirt_height(x, z - e) - skirt_height(x, z + e)).normalized())
				st.add_vertex(Vector3(x, skirt_height(x, z), z))
	var node := MeshInstance3D.new()
	node.name = "GroundSkirt"
	node.mesh = st.commit()
	node.material_override = ground_material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


## Rings of hills: inner foot (on the skirt), a shoulder, the ridge and the back foot, flat shaded; radius and
## height follow seeded noise round the ring (broad swells, smaller bumps, every other ridge point a saddle).
func _build_far_hills(cfg: Dictionary) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = int(cfg["seed"])
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	LowpolyKit._surface = WorldSurface.surface_id(String(cfg["surface"]))
	var ring_index := 0
	for ring: Dictionary in cfg["rings"]:
		var segments := int(ring["segments"])
		var radius := float(ring["radius_m"])
		var depth := float(ring["depth_m"])
		var h_lo := float(ring["height_m"][0])
		var h_hi := float(ring["height_m"][1])
		var wobble := float(ring.get("radius_noise", 0.12))
		var near := GreyboxArt.color_value(ring["color"])
		var top := GreyboxArt.color_value(ring.get("ridge_color", ring["color"]))
		var rows: Array = [[], [], [], []]  # inner foot, shoulder, ridge, back foot
		for i in segments:
			var angle := TAU * float(i) / segments
			var dir := Vector3(cos(angle), 0.0, sin(angle))
			var broad := noise.get_noise_2d(cos(angle) * 1.3 + ring_index * 7.0, sin(angle) * 1.3) * 0.5 + 0.5
			var fine := noise.get_noise_2d(cos(angle) * 6.1 + 2.0, sin(angle) * 6.1 + ring_index * 3.0) * 0.5 + 0.5
			var r := radius * (1.0 + wobble * (broad - 0.5) * 2.0)
			var h := lerpf(h_lo, h_hi, clampf(broad * 0.75 + fine * 0.45 - 0.1, 0.0, 1.0)) * (1.0 if i % 2 == 0 else lerpf(0.72, 0.92, fine))
			var foot := dir * r
			var ground := skirt_height(foot.x, foot.z)
			(rows[0] as Array).append(foot + Vector3.UP * (ground - 3.0))
			(rows[1] as Array).append(dir * (r + depth * (0.18 + 0.1 * fine)) + Vector3.UP * (ground + h * lerpf(0.35, 0.6, broad)))
			var ridge := dir * (r + depth * (0.42 + 0.16 * fine)) + Vector3.UP * (ground + h)
			(rows[2] as Array).append(ridge)
			(rows[3] as Array).append(dir * (r + depth) + Vector3.UP * (ground - 3.0))
			if ring_index == 0:
				_near_ridge.append(ridge)
		for i in segments:
			var j := (i + 1) % segments
			LowpolyKit._shade = 0.5 + 0.35 * sin(float(i) * 12.9898 + ring_index)
			for row in 3:
				var a: Vector3 = rows[row][i]
				var b: Vector3 = rows[row][j]
				var c: Vector3 = rows[row + 1][i]
				var d: Vector3 = rows[row + 1][j]
				var colour := near.lerp(top, float(row) / 2.0)
				# The hills code above: (b - a) x (c - a) points out of the hill.
				LowpolyKit._triangle(st, a, d, c, colour)
				LowpolyKit._triangle(st, a, b, d, colour)
		ring_index += 1
	LowpolyKit._surface = -1
	var mesh := st.commit()
	mesh.surface_set_material(0, WorldSurface.material())
	var node := MeshInstance3D.new()
	node.name = "Hills"
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


## A far aqueduct line: the kit's far aqueduct span (its LOD mesh) scaled up, one every span length on a straight line.
func _build_far_aqueduct(cfg: Dictionary) -> void:
	var type := String(cfg["type"])
	var lod := WorldKit.lod_for(type)
	var mesh: Mesh = lod[0] if not lod.is_empty() else WorldKit.mesh_for(type)
	var a := Vector2(float(cfg["from"][0]), float(cfg["from"][1]))
	var b := Vector2(float(cfg["to"][0]), float(cfg["to"][1]))
	var scale := float(cfg["scale"])
	var span := 10.0 * scale
	var count := maxi(1, floori(a.distance_to(b) / span))
	var dir := (b - a).normalized()
	var turn := Basis(Vector3.UP, atan2(-dir.y, dir.x)).scaled(Vector3.ONE * scale)
	var transforms: Array[Transform3D] = []
	var deck := -INF
	for i in count:
		var p := a + dir * span * (float(i) + 0.5)
		deck = maxf(deck, skirt_height(p.x, p.y))
	for i in count:
		var p := a + dir * span * (float(i) + 0.5)
		# A level deck (an aqueduct runs level): the piers reach down to the skirt (sunk where it falls away).
		transforms.append(Transform3D(turn, Vector3(p.x, deck - float(cfg.get("sink_m", 1.0)), p.y)))
		_note("far_aqueduct", transforms[-1].origin, Vector2(span * 0.5, 1.5 * scale))
	_batch("FarAqueduct", mesh, transforms, false)


func _build_far_beacons(cfg: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	for bearing: Variant in cfg["bearings_deg"]:
		if _near_ridge.is_empty():
			break
		# Compass bearing (0 = north = -z, 90 = east = +x) to the ring's angle (x = cos, z = sin).
		var angle := fposmod(deg_to_rad(float(bearing) - 90.0), TAU)
		var i := roundi(angle / TAU * _near_ridge.size()) % _near_ridge.size()
		if i % 2 == 1:
			i = (i + 1) % _near_ridge.size()  # a peak, not a saddle
		var at: Vector3 = _near_ridge[i] - Vector3.UP * 1.0
		transforms.append(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * float(cfg.get("scale", 1.0))), at))
		_note("beacon", at, Vector2(3.0, 3.0))
	_batch("Beacons", _mesh("far_beacon", cfg["parts"]), transforms, false)


## Dark cypress clumps on the skirt between radius_m[0] and [1] (its own seeded stream), never within
## clear_of_square_m of the ground square and never closer than min_from_wall_m beyond the outer wall's radius.
func _build_far_trees(cfg: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg["seed"])
	var cone: Dictionary = cfg["cone"]
	var transforms: Array[Transform3D] = []
	var r0 := float(cfg["radius_m"][0])
	var r1 := float(cfg["radius_m"][1])
	var min_r := float(cfg["wall_radius_m"]) + float(cfg["min_from_wall_m"])
	var clear := float(cfg.get("clear_of_square_m", 150.0))
	for k in int(cfg["clumps"]):
		var angle := rng.randf() * TAU
		var c := Vector2(cos(angle), sin(angle)) * lerpf(r0, r1, rng.randf())
		for m in rng.randi_range(int(cfg["per_clump"][0]), int(cfg["per_clump"][1])):
			var p := c + Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * float(cfg["clump_spread_m"])
			var edge := Vector2(clampf(p.x, -_far_half, _far_half), clampf(p.y, -_far_half, _far_half))
			var s := rng.randf_range(0.7, 1.25)
			var tall := rng.randf_range(0.85, 1.3)
			var yaw := rng.randf() * TAU
			if p.distance_to(edge) < clear or p.length() < min_r:
				continue
			var at := Vector3(p.x, skirt_height(p.x, p.y) - 0.5, p.y)
			transforms.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * tall, s)), at))
			_note("tree", at, Vector2.ONE * float(cone["radius_m"]) * s)
	_batch("Cypresses", _cypress_mesh(cone, GreyboxArt.color_value(cfg["color"])), transforms, false)


func _cypress_mesh(cone: Dictionary, color: Color) -> ArrayMesh:
	if _meshes.has("far_cypress"):
		return _meshes["far_cypress"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	LowpolyKit._surface = WorldSurface.surface_id("cloth")
	var segs := int(cone["segments"])
	var h := float(cone["height_m"])
	var r := float(cone["radius_m"])
	var rings := [Vector2(0.0, r * 0.55), Vector2(h * 0.3, r), Vector2(h * 0.75, r * 0.6), Vector2(h, 0.0)]  # (y, radius): a flame
	for k in rings.size() - 1:
		var lo: Vector2 = rings[k]
		var hi: Vector2 = rings[k + 1]
		for i in segs:
			var a0 := TAU * float(i) / segs
			var a1 := TAU * float(i + 1) / segs
			LowpolyKit._shade = 0.4 + 0.2 * float(i % 2)
			var lo0 := Vector3(cos(a0) * lo.y, lo.x, sin(a0) * lo.y)
			var lo1 := Vector3(cos(a1) * lo.y, lo.x, sin(a1) * lo.y)
			var hi0 := Vector3(cos(a0) * hi.y, hi.x, sin(a0) * hi.y)
			var hi1 := Vector3(cos(a1) * hi.y, hi.x, sin(a1) * hi.y)
			LowpolyKit._triangle(st, lo0, hi1, lo1, color)
			if hi.y > 0.0:
				LowpolyKit._triangle(st, lo0, hi0, hi1, color)
	LowpolyKit._surface = -1
	var mesh := st.commit()
	mesh.surface_set_material(0, WorldSurface.material())
	_meshes["far_cypress"] = mesh
	return mesh
