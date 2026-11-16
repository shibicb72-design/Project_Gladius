class_name WorldClutter
extends RefCounted
## M2W1 item 5: clutter (low dressing round camps, gates, towers, aqueducts, stake rows and cover) and field scatter
## (grass clumps, dry weeds, scrub, stones), looks only. Data: data/art_clutter.json (placeholders, OQ-ART-WORLD);
## meshes: tools/blender/m2w1_clutter.py -> one glb, rebuilt with WorldKitMeshes.rebuild (the kit's vertex data and
## the one world material; the grass kinds take the swaying foliage shader instead).
## Every instance is a MapChunks instance (source "clutter", one batch per type and chunk): no body, no collider,
## nothing under Nav, in no group. The map builder (astra_map.gd) calls populate() after every body, door and ladder
## exists and after the ground paint, before chunks.build(); only for a map with a block under "maps" and only when
## the graphics preset's art_clutter_enabled is on. Nothing here touches a body list, the paint, or a gameplay RNG:
## placement is a hash of positions and ids (and FastNoiseLite with data seeds).
## Rules (data "rules"; tests/test_m2w1_clutter.gd asserts the built result breaks none): see the data note. The
## builder checks each instance with instance_problem() and skips one that breaks a rule. Doorway lanes here are
## the straight lines through each doorway (a NavigationServer map cannot be queried while the map is being built:
## map_force_update leaves a new map at iteration 0 in Godot 4.7.2); the test checks the real navigation paths.

const PATH := "res://data/art_clutter.json"
const SOURCE := "clutter"
const CELL_M := 8.0
static var _registry := DataRegistry.new()
## Tests: -1 = the graphics preset decides, 0 = off, 1 = on.
static var enabled_override := -1
static var _meshes := {}  # type -> ArrayMesh (null when missing; reported once)
static var _infos := {}  # type -> footprint info (info())
static var _foliage: ShaderMaterial


static func config() -> Dictionary:
	return _registry.load_file(PATH)


static func enabled() -> bool:
	if enabled_override >= 0:
		return enabled_override == 1
	return bool(GraphicsPresets.new().get_preset().get("art_clutter_enabled", false))


static func rules() -> Dictionary:
	return config().get("rules", {})


## The map's block in data "maps" (key: the map json's file name without .json), or {} (no clutter on that map).
static func map_block(map_json: String) -> Dictionary:
	return (config().get("maps", {}) as Dictionary).get(map_json.get_file().get_basename(), {})


static func types() -> Array:
	var out: Array = []
	for type: String in config().get("types", {}):
		if not type.begins_with("_"):
			out.append(type)
	return out


static func type_cfg(type: String) -> Dictionary:
	return (config().get("types", {}) as Dictionary).get(type, {})


static func clear_cache() -> void:
	_meshes.clear()
	_infos.clear()
	_foliage = null


## The swaying grass material of the foliage types (the world_foliage shader, white base: the vertex colours are the
## albedo, turned linear when the mesh is made).
static func foliage_material() -> ShaderMaterial:
	if _foliage == null:
		var f: Dictionary = config().get("foliage", {})
		_foliage = ShaderMaterial.new()
		_foliage.shader = load("res://scripts/visual/shaders/world_foliage.gdshader")
		_foliage.set_shader_parameter("amplitude", float(f.get("amplitude_m", 0.05)))
		_foliage.set_shader_parameter("speed", float(f.get("speed", 1.3)))
		_foliage.set_shader_parameter("frequency", float(f.get("frequency", 0.9)))
		_foliage.set_shader_parameter("roughness", float(f.get("roughness", 0.95)))
		_foliage.set_shader_parameter("height_m", float(f.get("height_m", 0.4)))
		_foliage.set_shader_parameter("base_color", Color(1, 1, 1, 1))
	return _foliage


static func uses_foliage(type: String) -> bool:
	return String(type_cfg(type).get("material", "kit")) == "foliage"


## The type's mesh: the glb node of the same name as one surface with the kit's vertex data and the world material
## (a foliage type: its colours linear and the foliage material). Null when the glb or node is missing (one error).
static func mesh(type: String) -> ArrayMesh:
	if _meshes.has(type):
		return _meshes[type]
	var made: ArrayMesh = null
	var glb := String(config().get("glb", ""))
	var source := WorldKitMeshes._source_mesh(glb, type)
	if source == null:
		push_error("WorldClutter: no mesh node %s in %s; that type is not placed" % [type, glb])
	else:
		made = WorldKitMeshes.rebuild(source)
		if uses_foliage(type):
			var arrays := made.surface_get_arrays(0)
			var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			for i in colours.size():
				colours[i] = colours[i].srgb_to_linear()
			arrays[Mesh.ARRAY_COLOR] = colours
			made = ArrayMesh.new()
			made.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			made.surface_set_material(0, foliage_material())
		made.resource_name = "M2W1_clutter_" + type
	_meshes[type] = made
	return made


## {centre: Vector2 (footprint box centre, local x/z), half: Vector2, radius (farthest vertex from that centre in
## x/z), top, bottom} of a type's mesh (unscaled).
static func info(type: String) -> Dictionary:
	if _infos.has(type):
		return _infos[type]
	var m := mesh(type)
	var out := {"centre": Vector2.ZERO, "half": Vector2.ZERO, "radius": 0.0, "top": 0.0, "bottom": 0.0}
	if m != null:
		var box := m.get_aabb()
		var centre := Vector2(box.position.x + box.size.x * 0.5, box.position.z + box.size.z * 0.5)
		var radius := 0.0
		for v: Vector3 in m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			radius = maxf(radius, Vector2(v.x, v.z).distance_to(centre))
		out = {"centre": centre, "half": Vector2(box.size.x, box.size.z) * 0.5, "radius": radius, "top": box.end.y, "bottom": box.position.y}
	_infos[type] = out
	return out


# --- small geometry (2D on the ground plane: Vector2(x, z)) ---

## An oriented box {c, ax (unit, its local x), half}; its local z is (-ax.y, ax.x).
static func obb(c: Vector2, ax: Vector2, half: Vector2) -> Dictionary:
	return {"c": c, "ax": ax, "half": half}


## The footprint box of a clutter instance at `xform` (yaw only, uniform scale).
static func instance_obb(type: String, xform: Transform3D) -> Dictionary:
	var i := info(type)
	var s := xform.basis.get_scale().x
	var centre: Vector2 = i["centre"]
	var at := xform.origin + xform.basis * Vector3(centre.x, 0.0, centre.y)
	var ax3 := xform.basis.x.normalized()
	return obb(Vector2(at.x, at.z), Vector2(ax3.x, ax3.z).normalized(), (i["half"] as Vector2) * s)


static func _corners(o: Dictionary) -> PackedVector2Array:
	var ax: Vector2 = o["ax"]
	var az := Vector2(-ax.y, ax.x)
	var h: Vector2 = o["half"]
	var c: Vector2 = o["c"]
	return PackedVector2Array([c - ax * h.x - az * h.y, c + ax * h.x - az * h.y, c + ax * h.x + az * h.y, c - ax * h.x + az * h.y])


## Distance from a point to an oriented box (0 inside).
static func point_obb_distance(p: Vector2, o: Dictionary) -> float:
	var ax: Vector2 = o["ax"]
	var az := Vector2(-ax.y, ax.x)
	var d: Vector2 = p - (o["c"] as Vector2)
	var h: Vector2 = o["half"]
	var lx := d.dot(ax)
	var lz := d.dot(az)
	return Vector2(lx - clampf(lx, -h.x, h.x), lz - clampf(lz, -h.y, h.y)).length()


static func _overlap(a: Dictionary, b: Dictionary) -> bool:
	var ca := _corners(a)
	var cb := _corners(b)
	for o: Dictionary in [a, b]:
		var ax: Vector2 = o["ax"]
		for axis: Vector2 in [ax, Vector2(-ax.y, ax.x)]:
			var a0 := INF
			var a1 := -INF
			var b0 := INF
			var b1 := -INF
			for p in ca:
				a0 = minf(a0, p.dot(axis))
				a1 = maxf(a1, p.dot(axis))
			for p in cb:
				b0 = minf(b0, p.dot(axis))
				b1 = maxf(b1, p.dot(axis))
			if a1 < b0 or b1 < a0:
				return false
	return true


## Gap between two oriented boxes (0 when they touch or overlap).
static func obb_distance(a: Dictionary, b: Dictionary) -> float:
	if _overlap(a, b):
		return 0.0
	var best := INF
	for p in _corners(a):
		best = minf(best, point_obb_distance(p, b))
	for p in _corners(b):
		best = minf(best, point_obb_distance(p, a))
	return best


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-9 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func polyline_distance(p: Vector2, line: PackedVector2Array) -> float:
	if line.size() == 1:
		return p.distance_to(line[0])
	var best := INF
	for i in line.size() - 1:
		best = minf(best, _segment_distance(p, line[i], line[i + 1]))
	return best


# --- the rule context ---

## The transform of `node` relative to `root` (works with or without a scene tree).
static func xform_to(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n := node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


## The footprint box of a 3D local box (centre, size) under `xform`, in the frame of xform's own x axis.
static func box_obb(xform: Transform3D, centre: Vector3, size: Vector3) -> Dictionary:
	var ax3 := Vector3(xform.basis.x.x, 0.0, xform.basis.x.z)
	if ax3.length() < 0.2:
		ax3 = Vector3.RIGHT
	var ax := Vector2(ax3.x, ax3.z).normalized()
	var az := Vector2(-ax.y, ax.x)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var corner := centre + Vector3(size.x * (0.5 if i & 1 else -0.5), size.y * (0.5 if i & 2 else -0.5), size.z * (0.5 if i & 4 else -0.5))
		var w := xform * corner
		var q := Vector2(w.x, w.z)
		var l := Vector2(q.dot(ax), q.dot(az))
		lo = lo.min(l)
		hi = hi.max(l)
	var mid := (lo + hi) * 0.5
	return obb(ax * mid.x + az * mid.y, ax, (hi - lo) * 0.5)


static func _shape_box(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var s := (shape as BoxShape3D).size
		return AABB(-s * 0.5, s)
	if shape is ConvexPolygonShape3D:
		var pts := (shape as ConvexPolygonShape3D).points
		var box := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			box = box.expand(p)
		return box
	var dbg := shape.get_debug_mesh()
	return dbg.get_aabb() if dbg != null else AABB()


## Everything the rules measure against, from the built map (`builder` = the ArtBuilder node; its parent is the map
## root holding Nav). items: [{kind: "box" | "point" | "lane", what, clear, obb | p | line}], indexed in a grid.
static func context(builder: Node, map_def: Dictionary) -> Dictionary:
	var r := rules()
	var root := builder.get_parent()
	var items: Array = []
	var nav := root.get_node_or_null("Nav") if root != null else null
	var bodies: Array = []
	if nav != null:
		bodies.append_array(nav.get_children())
	var props := builder.get_node_or_null("Props")
	if props != null:
		bodies.append_array(props.get_children())
	for body: Node in bodies:
		if not (body is StaticBody3D) or body.name == &"Ground":
			continue
		var what := "collider"
		var clear := 0.0
		if body.is_in_group(&"cover_wall"):
			what = "cover_edge"
			clear = float(r["cover_edge_clear_m"])
		elif body.is_in_group(&"loot_chest"):
			what = "chest"
			clear = float(r["chest_clear_m"])
		for shape: Node in body.find_children("*", "CollisionShape3D", true, false):
			var s := (shape as CollisionShape3D).shape
			if s == null:
				continue
			var box := _shape_box(s)
			items.append({"kind": "box", "what": what, "clear": clear, "obb": box_obb(xform_to(shape, root), box.get_center(), box.size)})
	# Structure walk and open volumes; ground-level openings are doorways (lanes through their thin axis).
	var half_lane := float(r["lane_half_m"])
	var kit_types: Dictionary = WorldKit.config()["types"]
	for body: Node in builder.get("structure_bodies"):
		var t := xform_to(body, root)
		var def: Dictionary = kit_types.get(String(body.get_meta(&"structure_type", "")), {})
		for v: Dictionary in def.get("open", []):
			var at := LowpolyKit.vec(v["at"])
			var size := LowpolyKit.vec(v["size"])
			items.append({"kind": "box", "what": "open", "clear": 0.0, "obb": box_obb(t, at, size)})
			# A doorway: open from the ground and thin across (a room's whole inside, 5.2 m deep, is no doorway).
			if at.y - size.y * 0.5 < 0.3 and minf(size.x, size.z) <= 3.0:
				var through := Vector3.BACK if size.z <= size.x else Vector3.RIGHT
				items.append(_lane(t * at, t.basis * through, half_lane))
		for v: Dictionary in def.get("walk", []):
			var wt := t * LowpolyShapes.transform_of(v) if v.has("rot") else t * Transform3D(Basis.IDENTITY, LowpolyKit.vec(v["at"]))
			var sz: Array = v["size"]
			items.append({"kind": "box", "what": "walk", "clear": 0.0, "obb": box_obb(wt, Vector3.ZERO, Vector3(float(sz[0]), 0.1, float(sz[1])))})
	# Doors and gates: the pocket the leaves slide into (Door.pawn_in_path's box) and a lane through the opening.
	for door: Node in builder.get("door_bodies"):
		var d := door as Door
		var t := xform_to(d, root)
		var cx := 0.0
		if d.slide == "left":
			cx = -d.size.x * 0.5
		elif d.slide == "right":
			cx = d.size.x * 0.5
		items.append({"kind": "box", "what": "door_pocket", "clear": 0.0, "obb": box_obb(t, Vector3(cx, 0.0, 0.0), Vector3(d.size.x * 2.0, d.size.y, d.size.z))})
		items.append(_lane(t.origin, t.basis * Vector3.BACK, half_lane))
	for ladder: Node in builder.get("ladders"):
		var t := xform_to(ladder, root)
		items.append({"kind": "point", "what": "ladder", "clear": float(r["ladder_clear_m"]), "p": Vector2(t.origin.x, t.origin.z)})
		var top: Variant = ladder.get("top") if "top" in ladder else null
		if top is Vector3:
			items.append({"kind": "point", "what": "ladder", "clear": float(r["ladder_clear_m"]), "p": Vector2((top as Vector3).x, (top as Vector3).z)})
	var cover := DataRegistry.parse_quiet(String(map_def.get("cover_data", "")))
	for e: Dictionary in cover.get("ladders", []):
		for key: String in ["at", "top"]:
			if e.has(key):
				items.append({"kind": "point", "what": "ladder", "clear": float(r["ladder_clear_m"]), "p": Vector2(float(e[key][0]), float(e[key][2]))})
	var landmark_path := String(map_def.get("landmarks", ""))
	if landmark_path != "":
		for lm: Dictionary in DataRegistry.parse_quiet(landmark_path).get("landmarks", []):
			items.append({"kind": "point", "what": "loot", "clear": float(r["loot_clear_m"]), "p": Vector2(float(lm["at"][0]), float(lm["at"][1]))})
	for spot: Dictionary in map_def.get("reserved_spots", []):
		items.append({"kind": "point", "what": "reserved", "clear": float(r["reserved_clear_m"]), "p": Vector2(float(spot["at"][0]), float(spot["at"][1]))})
	var ctx := {"items": items, "grid": {}, "terrain": builder.get("terrain"), "rules": r}
	index(ctx)
	return ctx


static func _lane(centre: Vector3, through: Vector3, half_m: float) -> Dictionary:
	var dir := Vector2(through.x, through.z).normalized()
	var c := Vector2(centre.x, centre.z)
	return {"kind": "lane", "what": "lane", "clear": float(rules()["lane_clear_m"]), "line": PackedVector2Array([c - dir * half_m, c + dir * half_m])}


static func _item_rect(item: Dictionary) -> Rect2:
	var pad := float(item["clear"]) + 2.5  # 2.5 m: more than any clutter footprint radius
	match String(item["kind"]):
		"box":
			var o: Dictionary = item["obb"]
			var reach := (o["half"] as Vector2).length()
			return Rect2(o["c"] - Vector2(reach, reach), Vector2(reach, reach) * 2.0).grow(pad)
		"point":
			return Rect2(item["p"], Vector2.ZERO).grow(pad)
		_:
			var line: PackedVector2Array = item["line"]
			var rect := Rect2(line[0], Vector2.ZERO)
			for p in line:
				rect = rect.expand(p)
			return rect.grow(pad)


## (Re)builds the context's grid (call after changing its items, as the test does with the navigation lanes).
static func index(ctx: Dictionary) -> void:
	var grid := {}
	var items: Array = ctx["items"]
	for i in items.size():
		var rect := _item_rect(items[i])
		for cz in range(floori(rect.position.y / CELL_M), floori(rect.end.y / CELL_M) + 1):
			for cx in range(floori(rect.position.x / CELL_M), floori(rect.end.x / CELL_M) + 1):
				var key := Vector2i(cx, cz)
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(i)  # an Array: a packed array in a Dictionary is a value (append to a copy)
	ctx["grid"] = grid


## Why the instance `type` at `xform` breaks a rule ("" = it breaks none). `scatter` = the scatter slope limit.
static func instance_problem(ctx: Dictionary, type: String, xform: Transform3D, scatter := false, footprint := {}) -> String:
	var r: Dictionary = ctx["rules"]
	var o := footprint if not footprint.is_empty() else instance_obb(type, xform)
	var i := info(type)
	var s := xform.basis.get_scale().x
	var radius := float(i["radius"]) * s
	var c: Vector2 = o["c"]
	var terrain: MapTerrain = ctx["terrain"]
	if float(i["top"]) * s > float(r["max_height_m"]) + 1e-4:
		return "height"
	if terrain != null:
		var limit := float(r["max_slope_scatter_deg"] if scatter else r["max_slope_deg"])
		if terrain.slope_deg_at(xform.origin.x, xform.origin.z) > limit:
			return "slope"
		if xform.origin.y + float(i["top"]) * s - terrain.height_at(xform.origin.x, xform.origin.z) > float(r["max_height_m"]) + 1e-3:
			return "height"
	var grid: Dictionary = ctx["grid"]
	var items: Array = ctx["items"]
	var seen := {}
	var reach := radius + 0.01
	for cz in range(floori((c.y - reach) / CELL_M), floori((c.y + reach) / CELL_M) + 1):
		for cx in range(floori((c.x - reach) / CELL_M), floori((c.x + reach) / CELL_M) + 1):
			var list: Variant = grid.get(Vector2i(cx, cz))
			if list == null:
				continue
			for k: int in list:
				if seen.has(k):
					continue
				seen[k] = true
				var item: Dictionary = items[k]
				var clear := float(item["clear"])
				match String(item["kind"]):
					"box":
						var ob: Dictionary = item["obb"]
						# Quick reject: the two boxes' circumcircles more than `clear` apart.
						if (ob["c"] as Vector2).distance_to(c) > (ob["half"] as Vector2).length() + (o["half"] as Vector2).length() + clear:
							continue
						if _overlap(o, ob) or (clear > 0.0 and obb_distance(o, ob) < clear):
							return String(item["what"])
					"point":
						if point_obb_distance(item["p"], o) < clear:
							return String(item["what"])
					"lane":
						if polyline_distance(c, item["line"]) < clear + radius:
							return "lane"
	return ""


# --- placement ---

static func _mix(h: int) -> int:
	h = (h ^ (h >> 16)) * 0x45d9f3b
	h &= 0xFFFFFFFF
	h = (h ^ (h >> 16)) * 0x45d9f3b
	h &= 0xFFFFFFFF
	return h ^ (h >> 16)


## A hash in [0, 1) of three integers (no RNG state).
static func hash01(a: int, b: int, c: int) -> float:
	var h := _mix((a & 0xFFFFFFFF) ^ _mix((b & 0xFFFFFFFF) ^ _mix(c & 0xFFFFFFFF)))
	return float(h & 0xFFFFFF) / 16777216.0


static func _key(text: String) -> int:
	return text.hash() & 0xFFFFFFFF


## The ground under a footprint: the lowest of its centre and corners (an instance sinks rather than floats).
static func _ground(terrain: MapTerrain, o: Dictionary, at: Vector3) -> float:
	if terrain == null:
		return at.y
	var y := terrain.height_at(at.x, at.z)
	for p in _corners(o):
		y = minf(y, terrain.height_at(p.x, p.y))
	return y


static func _placed_xform(type: String, terrain: MapTerrain, xz: Vector3, yaw: float, scale: float) -> Transform3D:
	var t := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale), Vector3(xz.x, 0.0, xz.z))
	t.origin.y = _ground(terrain, instance_obb(type, t), xz)
	return t


## The cell a footprint centre falls in for the clutter-to-clutter gap grid.
static func _gap_key(c: Vector2) -> Vector2i:
	return Vector2i(floori(c.x / CELL_M), floori(c.y / CELL_M))


static func _gap_free(gaps: Dictionary, o: Dictionary, gap: float) -> bool:
	var c: Vector2 = o["c"]
	var k := _gap_key(c)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for other: Dictionary in gaps.get(k + Vector2i(dx, dz), []):
				if (other["c"] as Vector2).distance_to(c) > (other["half"] as Vector2).length() + (o["half"] as Vector2).length() + gap:
					continue
				if obb_distance(o, other) < gap or _overlap(o, other):
					return false
	return true


static func _gap_add(gaps: Dictionary, o: Dictionary) -> void:
	var k := _gap_key(o["c"])
	if not gaps.has(k):
		gaps[k] = []
	(gaps[k] as Array).append(o)


## Places the map's clutter into `chunks` (not built yet). Returns a report: {"dressing": {piece type: [tried,
## kept]}, "dropped": {rule: n}, "scatter": {kind: n}, "capped": n, "instances": n, "ms": n}; {} when the map has
## no block or the switch is off.
static func populate(builder: Node, chunks: MapChunks, map_def: Dictionary) -> Dictionary:
	var block := map_block(String(builder.get("map_json")))
	if block.is_empty() or not enabled():
		return {}
	var started := Time.get_ticks_msec()
	var cfg := config()
	var r: Dictionary = cfg["rules"]
	var ctx := context(builder, map_def)
	var terrain: MapTerrain = ctx["terrain"]
	var root := builder.get_parent()
	var report := {"dressing": {}, "dropped": {}, "scatter": {}, "capped": 0, "instances": 0, "context_ms": Time.get_ticks_msec() - started}
	var placed: Array = []  # [type, Transform3D]
	var gaps := {}
	# Dressing: per placed piece (structures, then cover and ring cover from the cover file).
	var pieces: Array = []  # [piece type, id, Transform3D]
	for body: Node in builder.get("structure_bodies"):
		pieces.append([String(body.get_meta(&"structure_type", "")), String(body.name), xform_to(body, root)])
	var cover := DataRegistry.parse_quiet(String(map_def.get("cover_data", "")))
	for list: String in ["pieces", "ring_pieces"]:
		for e: Dictionary in cover.get(list, []):
			var at: Vector3 = builder.call("lifted", LowpolyKit.vec(e["at"]))
			pieces.append([String(e["type"]), String(e["id"]), Transform3D(Basis.IDENTITY, at)])
	var dressing: Dictionary = cfg.get("dressing", {})
	var gap := float(r["clutter_gap_m"])
	for piece: Array in pieces:
		var entries: Array = dressing.get(piece[0], [])
		if entries.is_empty():
			continue
		var pt: Transform3D = piece[2]
		var piece_yaw := pt.basis.get_euler().y
		var key := _key(String(piece[1]))
		var counts: Array = (report["dressing"] as Dictionary).get(piece[0], [0, 0])
		for n in entries.size():
			var e: Dictionary = entries[n]
			if hash01(key, n, 17) >= float(e.get("chance", 1.0)):
				continue
			var type := String(e["type"])
			if mesh(type) == null:
				continue
			counts[0] += 1
			var xz := pt.origin + pt.basis.orthonormalized() * Vector3(float(e["at"][0]), 0.0, float(e["at"][1]))
			var t := _placed_xform(type, terrain, xz, piece_yaw + deg_to_rad(float(e.get("yaw", 0.0))), 1.0)
			var why := instance_problem(ctx, type, t)
			var o := instance_obb(type, t)
			if why == "" and not _gap_free(gaps, o, gap):
				why = "clutter"
			if why != "":
				report["dropped"][why] = int((report["dropped"] as Dictionary).get(why, 0)) + 1
				continue
			_gap_add(gaps, o)
			placed.append([type, t])
			counts[1] += 1
		report["dressing"][piece[0]] = counts
	# Scatter by the ground paint and patch noise.
	var paint: Image = builder.get("ground_paint")
	var size_m := float(builder.get("ground_size_m"))
	var half := float(block.get("scatter_half_m", size_m * 0.5))
	var prop_gap := float(r["scatter_prop_gap_m"])
	var scatter: Dictionary = cfg.get("scatter", {})
	for kind: String in scatter:
		if kind.begins_with("_") or mesh(kind) == null:
			continue
		var k: Dictionary = scatter[kind]
		var kind_ms := Time.get_ticks_msec()
		var made := _scatter(kind, k, ctx, paint, size_m, half, gaps, prop_gap, placed)
		report["scatter"][kind] = made
		report["scatter_ms_" + kind] = Time.get_ticks_msec() - kind_ms
	# At most max_batches_per_chunk clutter types in one chunk: the types with the fewest instances there go first.
	var per_chunk := {}  # chunk index -> {type: count}
	for p: Array in placed:
		var idx := chunks.index_of((p[1] as Transform3D).origin)
		if not per_chunk.has(idx):
			per_chunk[idx] = {}
		per_chunk[idx][p[0]] = int((per_chunk[idx] as Dictionary).get(p[0], 0)) + 1
	var banned := {}  # "<index>/<type>" -> true
	var cap := int(r["max_batches_per_chunk"])
	for idx: Vector2i in per_chunk:
		var counts: Dictionary = per_chunk[idx]
		if counts.size() <= cap:
			continue
		var order: Array = counts.keys()
		order.sort_custom(func(a: String, b: String) -> bool: return counts[a] < counts[b] or (counts[a] == counts[b] and a < b))
		for i in counts.size() - cap:
			banned["%s/%s" % [idx, order[i]]] = true
	for p: Array in placed:
		var t: Transform3D = p[1]
		if banned.has("%s/%s" % [chunks.index_of(t.origin), p[0]]):
			report["capped"] = int(report["capped"]) + 1
			continue
		chunks.add(SOURCE, p[0], mesh(p[0]), foliage_material() if uses_foliage(p[0]) else null, t)
		report["instances"] = int(report["instances"]) + 1
	report["ms"] = Time.get_ticks_msec() - started
	return report


static func _paint_at(paint: Image, size_m: float, p: Vector2) -> Color:
	if paint == null or size_m <= 0.0:
		return Color(0, 0, 0, 1)
	var px := paint.get_width()
	return paint.get_pixel(clampi(int((p.x / size_m + 0.5) * px), 0, px - 1), clampi(int((p.y / size_m + 0.5) * px), 0, px - 1))


## One scatter kind on a jittered grid: a cell holds at most one instance; in a noise patch every cell may, outside
## one only `outside / density` of them. Returns the number placed.
static func _scatter(kind: String, k: Dictionary, ctx: Dictionary, paint: Image, size_m: float, half: float, gaps: Dictionary, prop_gap: float, placed: Array) -> int:
	var density := maxf(float(k["density"]), 0.01)
	var step := sqrt(100.0 / density)
	var cells := ceili(half * 2.0 / step)
	var jitter := clampf(1.0 - float(k.get("min_spacing_m", 0.0)) / step, 0.0, 1.0)
	var noise := FastNoiseLite.new()
	noise.seed = int(k["seed"])
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / maxf(float(k["noise_m"]), 1.0)
	var threshold := float(k["threshold"])
	var soft := maxf(float(k.get("soft", 0.2)), 0.01)
	var outside := clampf(float(k.get("outside", 0.0)) / density, 0.0, 1.0)
	var surface := String(k.get("surface", "any"))
	var grass_min := float(k.get("grass_min", 0.5))
	var edge: Dictionary = k.get("paving_edge", {})
	var seed := int(k["seed"])
	var scale_lo := float(k["scale"][0])
	var scale_hi := float(k["scale"][1])
	var top := float(info(kind)["top"])
	var max_scale := float((ctx["rules"] as Dictionary)["max_height_m"]) / maxf(top, 0.01)
	var terrain: MapTerrain = ctx["terrain"]
	var made := 0
	for iz in cells:
		for ix in cells:
			# The patch noise at the cell's centre first: most cells end here (cheap), before the paint is read.
			var cx := -half + (float(ix) + 0.5) * step
			var cz := -half + (float(iz) + 0.5) * step
			var w := clampf((noise.get_noise_2d(cx, cz) - threshold) / soft, 0.0, 1.0)
			var roll := hash01(seed + 2, ix, iz)
			if edge.is_empty() and roll >= w + (1.0 - w) * outside:
				continue
			var h1 := hash01(seed, ix, iz)
			var h2 := hash01(seed + 1, ix, iz)
			var p := Vector2(cx + (h1 - 0.5) * jitter * step, cz + (h2 - 0.5) * jitter * step)
			var c := _paint_at(paint, size_m, p)
			var ok := false
			var chance := w + (1.0 - w) * outside
			match surface:
				"grass":
					ok = c.r < 0.5 and c.g >= grass_min
				"earth":
					ok = c.r < 0.5 and c.g < 0.5
				_:
					ok = c.r < 0.5
			if not edge.is_empty() and c.r >= float(edge["paving_min"]) and c.r <= float(edge["paving_max"]):
				ok = true
				chance = 1.0
			if not ok or roll >= chance:
				continue
			var h3 := hash01(seed + 3, ix, iz)
			var grow := minf(lerpf(scale_lo, scale_hi, h3 * (0.5 + 0.5 * w)), max_scale)
			var t := Transform3D(Basis(Vector3.UP, hash01(seed + 4, ix, iz) * TAU).scaled(Vector3.ONE * grow), Vector3(p.x, 0.0, p.y))
			var o := instance_obb(kind, t)
			t.origin.y = _ground(terrain, o, t.origin)
			if instance_problem(ctx, kind, t, true, o) != "":
				continue
			if not _gap_free(gaps, o, prop_gap):
				continue
			placed.append([kind, t])
			made += 1
	return made
