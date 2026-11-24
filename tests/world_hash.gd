extends RefCounted
## W1c stage B (binding fix 12): a SHA-256 of a built match's world, tests/kit_hash.gd's approach widened to the whole
## map: every node under the map root in tree order (its path, class, script and sorted groups, then every STORED
## property and every script variable: transforms, visibility, materials and their shader parameters, mesh surface
## arrays (ArrayMesh "_surfaces"), MultiMesh buffers (instance transforms, colours, custom data), collision shapes
## (box sizes, hull points, height maps), metadata, collision layers), plus the navigation mesh (resource path,
## vertices, polygons), the map builder's results (body lists, decor types, the place map and ground paint bytes,
## the clutter report) and the match's loot spawns and prop states. Values are hashed by content: a Node reference
## by its path, a Mesh / Resource without a file by its stored properties, an ImageTexture / Image by its pixels.
## Excluded (not world state): engine-made name counters ("@Node@123" -> "@#"), timing fields (_is_timing) and the
## builder's own W1c slicing bookkeeping (BUILD_BOOKKEEPING).

## Timing fields: a property or dictionary key that is "ms" or has "ms" as an underscore-separated word (build_ms,
## context_ms, scatter_ms_<kind>: WorldClutter's report). Milliseconds of work are not world state.
static var _timing := RegEx.create_from_string("(^|_)ms(_|$)")


static func _is_timing(key: String) -> bool:
	return _timing.search(key) != null
const BUILD_BOOKKEEPING := ["sliced", "slice_budget_ms", "build_slices", "_steps", "_step_at", "_cur", "_fresh", "_frac",
		"_deadline", "_mark", "_script_usec", "_wall_usec"]
const MAX_DEPTH := 4

static var _auto_name := RegEx.create_from_string("@[0-9]+")


## The world's hash and one line per node ("<path> <class> <sha256 of its content>") for finding a first difference.
## `detail_paths` (map-relative, folded): those nodes also get "detail" {path: {property: hash}} (to name a difference).
static func compute(match_root: Node, detail_paths: Array = []) -> Dictionary:
	var map: Node = match_root.get("map")
	var lines := PackedStringArray()
	var cache := {}  # resource instance id -> its content hash (a mesh shared by many batches is hashed once)
	var detail := {}
	var nodes: Array[Node] = [map]
	nodes.append_array(map.find_children("*", "", true, false))
	for n in nodes:
		var path := _fold(str(map.get_path_to(n)))
		lines.append("%s %s %s" % [path, n.get_class(), node_hash(n, map, cache)])
		if detail_paths.has(path):
			detail[path] = property_hashes(n, map)
	var builder := map.get_node_or_null("ArtBuilder")
	if builder != null:
		lines.append("builder.place_map %s" % _value_hash(builder.get("place_map"), map, cache))
		lines.append("builder.ground_paint %s" % _value_hash(builder.get("ground_paint"), map, cache))
	var nav := map.get_node_or_null("Nav") as NavigationRegion3D
	lines.append("navmesh %s" % _navmesh_hash(nav.navigation_mesh if nav != null else null))
	lines.append("loot %s" % _value_hash(loot_state(match_root), map, cache))
	lines.append("props %s" % _value_hash(props_state(match_root), map, cache))
	return {"hash": "\n".join(lines).sha256_text(), "lines": lines, "detail": detail}


## property -> hash of its value, for one node (the same properties node_hash reads), for naming a difference.
static func property_hashes(n: Node, map: Node) -> Dictionary:
	var out := {}
	var skip: Array = BUILD_BOOKKEEPING if n.name == &"ArtBuilder" else []
	for p: Dictionary in n.get_property_list():
		var pname := String(p["name"])
		if int(p["usage"]) & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or skip.has(pname) or _is_timing(pname):
			continue
		out[pname] = _value_hash(n.get(pname), map, {})
	return out


static func loot_state(m: Node) -> Array:
	var out: Array = []
	var loot: Variant = m.get("loot")
	if loot == null:
		return out
	for id: Variant in loot.items:
		out.append([id, loot.items[id]["item_id"], loot.items[id]["pos"]])
	return out


static func props_state(m: Node) -> Array:
	var wp: Variant = m.get("world_props")
	if wp == null:
		return []
	return [wp.states.duplicate(), wp.breakables.keys(), wp.chests.keys(), wp.doors.keys()]


## One node's content hash.
static func node_hash(n: Node, map: Node, cache: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var script: Variant = n.get_script()
	ctx.update(("script=%s" % (script.resource_path if script != null else "")).to_utf8_buffer())
	var groups: Array = n.get_groups().map(func(g: StringName) -> String: return String(g))
	groups.sort()
	ctx.update(var_to_bytes(groups))
	var skip: Array = BUILD_BOOKKEEPING if n.name == &"ArtBuilder" else []
	for p: Dictionary in n.get_property_list():
		var usage := int(p["usage"])
		if usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var pname := String(p["name"])
		if pname == "name" or pname == "script" or skip.has(pname) or _is_timing(pname):
			continue
		ctx.update(pname.to_utf8_buffer())
		_feed(ctx, n.get(pname), map, cache, 0)
	return ctx.finish().hex_encode()


static func _value_hash(v: Variant, map: Node, cache: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	_feed(ctx, v, map, cache, 0)
	return ctx.finish().hex_encode()


static func _fold(s: String) -> String:
	return _auto_name.sub(s, "@#", true)


static func _feed(ctx: HashingContext, v: Variant, map: Node, cache: Dictionary, depth: int) -> void:
	match typeof(v):
		TYPE_NIL:
			ctx.update("nil".to_utf8_buffer())
		TYPE_OBJECT:
			_feed_object(ctx, v, map, cache, depth)
		TYPE_ARRAY:
			ctx.update(("[%d" % (v as Array).size()).to_utf8_buffer())
			for e: Variant in v:
				_feed(ctx, e, map, cache, depth)
		TYPE_DICTIONARY:
			ctx.update(("{%d" % (v as Dictionary).size()).to_utf8_buffer())
			for k: Variant in v:
				if _is_timing(str(k)):
					continue
				_feed(ctx, k, map, cache, depth)
				_feed(ctx, (v as Dictionary)[k], map, cache, depth)
		TYPE_CALLABLE:
			var c: Callable = v
			ctx.update(("callable:%s" % (String(c.get_method()) if c.is_valid() else "")).to_utf8_buffer())
		TYPE_SIGNAL:
			ctx.update("signal".to_utf8_buffer())
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			ctx.update(("s:" + _fold(str(v))).to_utf8_buffer())  # never empty (HashingContext rejects an empty update)
		_:
			ctx.update(var_to_bytes(v))


static func _feed_object(ctx: HashingContext, o: Object, map: Node, cache: Dictionary, depth: int) -> void:
	if o == null or not is_instance_valid(o):
		ctx.update("freed".to_utf8_buffer())
		return
	if o is Node:
		var node := o as Node
		var where := str(map.get_path_to(node)) if node.is_inside_tree() and (node == map or map.is_ancestor_of(node)) else "outside"
		ctx.update(("node:%s:%s" % [node.get_class(), _fold(where)]).to_utf8_buffer())
		return
	if o is Image:
		var img := o as Image
		ctx.update(("img:%d:%d:%d" % [img.get_width(), img.get_height(), img.get_format()]).to_utf8_buffer())
		if not img.is_empty():
			ctx.update(img.get_data())
		return
	if o is ImageTexture:
		_feed_object(ctx, (o as ImageTexture).get_image(), map, cache, depth)
		return
	if o is NavigationMesh:
		ctx.update(_navmesh_hash(o as NavigationMesh).to_utf8_buffer())
		return
	if o is Resource and (o as Resource).resource_path != "" and not (o as Resource).resource_path.contains("::"):
		ctx.update(("res:%s" % (o as Resource).resource_path).to_utf8_buffer())
		return
	var id := o.get_instance_id()
	if cache.has(id):
		ctx.update(String(cache[id]).to_utf8_buffer())
		return
	if depth >= MAX_DEPTH:
		ctx.update(("deep:%s" % o.get_class()).to_utf8_buffer())
		return
	# A runtime resource or RefCounted (mesh, multimesh, shape, material, place map, terrain): by its content.
	var sub := HashingContext.new()
	sub.start(HashingContext.HASH_SHA256)
	sub.update(o.get_class().to_utf8_buffer())
	var script: Variant = o.get_script()
	if script != null:
		sub.update(("script:" + (script as Script).resource_path).to_utf8_buffer())
	for p: Dictionary in o.get_property_list():
		var usage := int(p["usage"])
		if usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var pname := String(p["name"])
		if pname == "script" or _is_timing(pname):
			continue
		sub.update(pname.to_utf8_buffer())
		_feed(sub, o.get(pname), map, cache, depth + 1)
	var h := sub.finish().hex_encode()
	cache[id] = h
	ctx.update(h.to_utf8_buffer())


static func _navmesh_hash(nm: NavigationMesh) -> String:
	if nm == null:
		return "none"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("path:" + nm.resource_path).to_utf8_buffer())
	ctx.update(var_to_bytes(nm.get_vertices()))
	ctx.update(var_to_bytes(nm.get_polygon_count()))
	for i in nm.get_polygon_count():
		ctx.update(var_to_bytes(nm.get_polygon(i)))
	return ctx.finish().hex_encode()
