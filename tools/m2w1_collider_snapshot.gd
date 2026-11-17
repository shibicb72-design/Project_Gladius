extends SceneTree
## M2W1: a deterministic snapshot of a map's play space (the proof that the world-art slice changes no collider).
## Headless. Builds the map the way tests/test_alesia_1km.gd _map() does (ArtBuilder.map_json handed over before the
## map enters the tree) and writes one JSON file:
##   entries: EVERY CollisionShape3D under Nav (the ground height map included) and under ArtBuilder/Props (breakables,
##            doors and gates, the ladders' Area3D triggers; the chests are under Nav), sorted by node path. One entry:
##            p = path from the map root, c = the owning body's class (its script's class_name when it has one), g =
##            the body's groups (sorted, internal "_" groups left out), l / m = collision layer / mask, t = the shape's
##            global transform (12 numbers, basis columns x, y, z then origin, rounded to 1e-4), s = the shape class and
##            its defining numbers (box size; convex: point count, AABB and the sha256 of its rounded points; height
##            map: width, depth, min / max and the sha256 of its height bytes), d = disabled.
##   cover_wall: the bodies of group cover_wall in group order (path, box size, transform); builder_lists: the
##            ArtBuilder body lists in their order (cover_bodies, ring_bodies, structure_bodies, decor_bodies,
##            chest_bodies, door_bodies, ladders); group_counts; ground_paint_inputs_sha256 (GroundPaint.inputs_hash of
##            the map as ArtBuilder computes it); entries_sha256 (sha256 over the canonical entry lines, in order).
##   godot --headless --path . --log-file <log> --script res://tools/m2w1_collider_snapshot.gd -- [--out=<path>]
## Default out: res://data/maps/snapshots/<map>_colliders.json. Option --map=<res path> (default alesia_1km).
## The snapshot is read by tests/test_m2w1_colliders.gd only; no game code, no navigation manifest reads it.

const MAP_PATH := "res://data/maps/alesia_1km.json"
const SNAPSHOT_DIR := "res://data/maps/snapshots/"
const LISTS: Array[String] = ["cover_bodies", "ring_bodies", "structure_bodies", "decor_bodies", "chest_bodies", "door_bodies", "ladders"]


static func snapshot_path(map_path: String) -> String:
	return SNAPSHOT_DIR + map_path.get_file().get_basename() + "_colliders.json"


func _initialize() -> void:
	var map_path := MAP_PATH
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--map="):
			map_path = a.substr(6)
	if out == "":
		out = snapshot_path(map_path)
	await process_frame
	var t0 := Time.get_ticks_msec()
	var map := build_map(map_path)
	root.add_child(map)
	var build_ms := Time.get_ticks_msec() - t0
	var snap := snapshot(map, map_path)
	var text := to_text(snap)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out).get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	var ok := f != null
	if ok:
		f.store_string(text)
		f.close()
	print("M2W1_SNAPSHOT out=%s entries=%d cover_wall=%d bytes=%d entries_sha256=%s ground_paint_inputs_sha256=%s build_ms=%d" % [out, (snap["entries"] as Array).size(),
			(snap["cover_wall"] as Array).size(), text.to_utf8_buffer().size(), snap["entries_sha256"], snap["ground_paint_inputs_sha256"], build_ms])
	map.free()
	quit(0 if ok else 1)


## The map scene with ArtBuilder.map_json set (not yet in the tree).
static func build_map(map_path: String) -> Node3D:
	var map: Node3D = load(String(DataRegistry.parse_quiet(map_path)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", map_path)
	return map


static func num(v: float) -> String:
	var r := snappedf(v, 0.0001)
	if absf(r) < 0.00005:
		r = 0.0
	return "%.4f" % r


static func vec_text(v: Vector3) -> String:
	return "%s,%s,%s" % [num(v.x), num(v.y), num(v.z)]


static func xform_text(t: Transform3D) -> String:
	return "%s,%s,%s,%s" % [vec_text(t.basis.x), vec_text(t.basis.y), vec_text(t.basis.z), vec_text(t.origin)]


static func _class_of(node: Node) -> String:
	var script := node.get_script() as Script
	if script != null and script.get_global_name() != &"":
		return String(script.get_global_name())
	return node.get_class()


static func _groups_of(node: Node) -> Array:
	var out: Array = []
	for g in node.get_groups():
		if not String(g).begins_with("_"):
			out.append(String(g))
	out.sort()
	return out


static func shape_text(shape: Shape3D) -> String:
	if shape == null:
		return "none"
	if shape is BoxShape3D:
		return "Box size=" + vec_text((shape as BoxShape3D).size)
	if shape is ConvexPolygonShape3D:
		var pts := (shape as ConvexPolygonShape3D).points
		var lines := PackedStringArray()
		var box := AABB(pts[0], Vector3.ZERO) if not pts.is_empty() else AABB()
		for p in pts:
			lines.append(vec_text(p))
			box = box.expand(p)
		return "Convex n=%d aabb=%s/%s sha=%s" % [pts.size(), vec_text(box.position), vec_text(box.end), ";".join(lines).sha256_text()]
	if shape is HeightMapShape3D:
		var hm := shape as HeightMapShape3D
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(hm.map_data.to_byte_array())
		return "HeightMap w=%d d=%d min=%s max=%s sha=%s" % [hm.map_width, hm.map_depth, num(hm.get_min_height()), num(hm.get_max_height()), ctx.finish().hex_encode()]
	if shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces()
		var lines := PackedStringArray()
		for p in faces:
			lines.append(vec_text(p))
		return "Concave n=%d sha=%s" % [faces.size(), ";".join(lines).sha256_text()]
	return "%s %s" % [shape.get_class(), var_to_str(shape).sha256_text()]


## Every CollisionShape3D under Nav and ArtBuilder/Props, one canonical dictionary each, sorted by path.
static func entries_of(map: Node) -> Array:
	var shapes: Array[Node] = []
	shapes.append_array(map.get_node("Nav").find_children("*", "CollisionShape3D", true, false))
	var props := map.get_node_or_null("ArtBuilder/Props")
	if props != null:
		shapes.append_array(props.find_children("*", "CollisionShape3D", true, false))
	var out: Array = []
	for node: Node in shapes:
		var cs := node as CollisionShape3D
		var body := cs.get_parent() as CollisionObject3D
		out.append({
			"p": String(map.get_path_to(cs)),
			"c": _class_of(body) if body != null else "none",
			"g": _groups_of(body) if body != null else [],
			"l": body.collision_layer if body != null else -1,
			"m": body.collision_mask if body != null else -1,
			"t": xform_text(cs.global_transform),
			"s": shape_text(cs.shape),
			"d": cs.disabled,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["p"]) < String(b["p"]))
	return out


## One canonical line per entry (keys sorted): the text compared, hashed and stored.
static func entry_line(e: Dictionary) -> String:
	return JSON.stringify(e, "", true)


static func ground_paint_hash(map: Node, map_path: String) -> String:
	var builder := map.get_node("ArtBuilder")
	var def := DataRegistry.parse_quiet(map_path)
	var landmark_path := String(def.get("landmarks", ""))
	var landmarks: Array = DataRegistry.parse_quiet(landmark_path).get("landmarks", []) if landmark_path != "" else []
	var trodden := PackedVector2Array()
	for list: String in ["cover_bodies", "ring_bodies", "structure_bodies"]:
		for body: Node3D in builder.get(list):
			trodden.append(Vector2(body.position.x, body.position.z))
	return GroundPaint.inputs_hash(float(builder.get("ground_size_m")), landmarks, trodden, GroundPaint.settings_for(def))


## The whole snapshot of a built map (in the tree).
static func snapshot(map: Node, map_path: String) -> Dictionary:
	var entries := entries_of(map)
	var lines := PackedStringArray()
	for e: Dictionary in entries:
		lines.append(entry_line(e))
	var walls: Array = []
	var counts := {}
	var tree := map.get_tree()
	for node in tree.get_nodes_in_group(&"cover_wall"):
		if not map.is_ancestor_of(node):
			continue
		var shape := node.get_node_or_null("Shape") as CollisionShape3D
		var box := shape.shape as BoxShape3D if shape != null else null
		walls.append("%s|%s|%s" % [map.get_path_to(node), vec_text(box.size) if box != null else "none", xform_text((node as Node3D).global_transform)])
	for node in map.find_children("*", "CollisionObject3D", true, false):
		for g in _groups_of(node):
			counts[g] = int(counts.get(g, 0)) + 1
	var builder := map.get_node("ArtBuilder")
	var lists := {}
	for list: String in LISTS:
		var names: Array = []
		for body: Node in builder.get(list):
			names.append(String(body.name))
		lists[list] = names
	return {
		"map": map_path,
		"entries": entries,
		"entries_sha256": "\n".join(lines).sha256_text(),
		"cover_wall": walls,
		"builder_lists": lists,
		"group_counts": counts,
		"ground_paint_inputs_sha256": ground_paint_hash(map, map_path),
	}


## The file text: a small header, then one entry per line (diffable, deterministic).
static func to_text(snap: Dictionary) -> String:
	var head := {}
	for k: String in snap:
		if k != "entries":
			head[k] = snap[k]
	var parts := PackedStringArray()
	parts.append("{")
	parts.append("\"_note\": \"M2W1: the collider snapshot of %s (tools/m2w1_collider_snapshot.gd writes it, tests/test_m2w1_colliders.gd compares a fresh build with it). Generated: do not edit by hand. Read by that test only; not a navigation input.\"," % snap["map"])
	for k: String in ["map", "entries_sha256", "ground_paint_inputs_sha256", "group_counts", "builder_lists", "cover_wall"]:
		parts.append("%s: %s," % [JSON.stringify(k), JSON.stringify(head[k], "", true)])
	parts.append("\"entries\": [")
	var entries: Array = snap["entries"]
	for i in entries.size():
		parts.append(entry_line(entries[i]) + ("," if i < entries.size() - 1 else ""))
	parts.append("]")
	parts.append("}")
	return "\n".join(parts) + "\n"
