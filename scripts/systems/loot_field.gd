class_name LootField
extends Node3D
## Battle royale ground loot (data/loot.json, placeholders OQ-BR-LOOT / OQ-BR-ARMOR). Places `count` seeded
## items on walkable ground on its first physics tick (downward rays; wall tops and roofs above
## max_ground_y_m are skipped), inside the zone's start circle when setup is given one, then answers "nearest item in range", hands items out (take) and accepts
## dropped ones (drop). Decides no rules; MatchDirector calls it on the authority.

var cfg: Dictionary = {}
## id -> {item_id, pos: Vector3, node: Node3D, ammo_in_mag?, reserve?}
var items: Dictionary = {}
var placed: bool = false
var _seed: int = 1
var _next_id: int = 1
## W2: the zone block of the merged mode config the match already holds (start_center [x, z], start_radius_m).
## Empty = no circle: items land anywhere in the square of area_half_m, as before.
var _zone: Dictionary = {}


func setup(loot_cfg: Dictionary, seed_value: int, zone: Dictionary = {}) -> void:
	cfg = loot_cfg
	_seed = seed_value
	_zone = zone


func _physics_process(_delta: float) -> void:
	if not placed and not cfg.is_empty():
		place_now()


## Weighted, seeded item ids (pure; tested without a scene).
static func pick_item_ids(item_defs: Dictionary, count: int, rng: RandomNumberGenerator) -> Array[String]:
	var keys := item_defs.keys()
	keys.sort()
	var total := 0.0
	for k in keys:
		total += maxf(float(item_defs[k].get("weight", 0.0)), 0.0)
	var out: Array[String] = []
	if total <= 0.0:
		return out
	for i in count:
		var r := rng.randf() * total
		for k in keys:
			r -= maxf(float(item_defs[k].get("weight", 0.0)), 0.0)
			if r <= 0.0:
				out.append(str(k))
				break
	return out


func place_now() -> void:
	placed = true
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 104729  # own stream, apart from the zone and the drop
	var space := get_world_3d().direct_space_state
	var half := float(cfg.get("area_half_m", 70.0))
	var max_y := float(cfg.get("max_ground_y_m", 1.5))
	# W2: with a zone circle, a try is a point in the part of the square area the circle's bounds cover (the
	# circle is short of the zone edge by zone_edge_margin_m); a point outside the circle is a spent try. A
	# circle wider than the square leaves the tries exactly as they were without one.
	var in_circle := _zone.has("start_radius_m")
	var center := Vector2.ZERO
	var radius := 0.0
	var low := Vector2(-half, -half)
	var high := Vector2(half, half)
	if in_circle:
		var c: Array = _zone.get("start_center", [0, 0])
		center = Vector2(float(c[0]), float(c[1]))
		radius = maxf(float(_zone["start_radius_m"]) - float(cfg.get("zone_edge_margin_m", 0.0)), 0.0)
		low = low.max(center - Vector2(radius, radius))
		high = high.min(center + Vector2(radius, radius))
		if low.x > high.x or low.y > high.y:
			return  # the circle lies outside the loot area: nowhere to place
	for item_id in pick_item_ids(cfg.get("items", {}), int(cfg.get("count", 0)), rng):
		for attempt in 12:
			var x := rng.randf_range(low.x, high.x)
			var z := rng.randf_range(low.y, high.y)
			if in_circle and Vector2(x, z).distance_to(center) > radius:
				continue
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60.0, z), Vector3(x, -5.0, z), Hitscan.MASK_WORLD)
			var hit := space.intersect_ray(q)
			if hit.is_empty() or float(hit["position"].y) > max_y or (hit["normal"] as Vector3).y < 0.8:
				continue
			_add(item_id, hit["position"] + Vector3(0.0, 0.25, 0.0), {})
			break


func _add(item_id: String, pos: Vector3, extra: Dictionary) -> int:
	var id := _next_id
	_next_id += 1
	var entry := {"item_id": item_id, "pos": pos}
	entry.merge(extra, true)
	entry["node"] = _make_node(item_id, pos)
	items[id] = entry
	return id


func _make_node(item_id: String, pos: Vector3) -> Node3D:
	var kind := str(def(item_id).get("kind", "ammo"))
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.3, 0.4) if kind == "weapon" else Vector3(0.45, 0.45, 0.45)
	var mat := StandardMaterial3D.new()
	var c: Array = cfg.get("colors", {}).get(kind, [1, 1, 1, 1])
	mat.albedo_color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.35
	box.material = mat
	mi.mesh = box
	mi.name = "Loot_%s" % item_id
	add_child(mi)
	mi.global_position = pos
	return mi


func def(item_id: String) -> Dictionary:
	return cfg.get("items", {}).get(item_id, {})


func display_name(id: int) -> String:
	return str(def(str(items[id]["item_id"])).get("display", items[id]["item_id"])) if items.has(id) else ""


## Nearest item within range_m of `pos` on the ground plane (and within 2 m height); -1 if none.
## `accept` (item_id -> bool), when valid, skips items it rejects.
func nearest(pos: Vector3, range_m: float, accept: Callable = Callable()) -> int:
	var best := -1
	var best_d := INF
	for id in items:
		var p: Vector3 = items[id]["pos"]
		if absf(p.y - pos.y) > 2.0:
			continue
		if accept.is_valid() and not bool(accept.call(str(items[id]["item_id"]))):
			continue
		var d := Vector2(p.x - pos.x, p.z - pos.z).length()
		if d <= range_m and d < best_d:
			best = id
			best_d = d
	return best


## Removes an item and returns it (without its node); {} if it is gone.
func take(id: int) -> Dictionary:
	if not items.has(id):
		return {}
	var entry: Dictionary = items[id]
	items.erase(id)
	var node: Node3D = entry["node"]
	if is_instance_valid(node):
		node.queue_free()
	entry.erase("node")
	return entry


## Puts an item (from take, or a weapon a pawn let go) on the ground at `pos`; returns its id.
func drop(item: Dictionary, pos: Vector3) -> int:
	var extra := item.duplicate()
	extra.erase("item_id")
	extra.erase("pos")
	return _add(str(item["item_id"]), pos + Vector3(0.0, 0.25, 0.0), extra)
