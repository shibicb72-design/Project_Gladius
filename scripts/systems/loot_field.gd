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
## W3: the map's landmarks ([{id, at [x, z], radius_m, ...}], data/maps/alesia_landmarks.json "landmarks"). The
## clusters of loot.json name them by id. Empty = no clusters: every item is scattered.
var _landmarks: Array = []
## M2P1C stop 6: a grid over the items, so nearest() and the bots' loot goal look only at items near the
## query. Cell: data/map_build.json "spatial_index.loot_cell_m" (placeholder, OQ-MAP-INDEX). _add and take
## keep it current; an `items` changed from outside (its size no longer matching) rebuilds it. Each item
## has a rank (its insertion order in `items`), and items_near() returns ids in rank order, so a loop over
## it meets the items in the same order as a loop over `items` and keeps the "first inserted wins" ties.
var _grid_m := 0.0
var _grid: Dictionary = {}  # Vector2i cell -> PackedInt32Array of ranks
var _grid_cell: Dictionary = {}  # id -> Vector2i
var _rank: Dictionary = {}  # id -> rank
var _rank_id: Dictionary = {}  # rank -> id
var _next_rank: int = 0
## Pad of the grid query on every side (float32 rounding of the distances; far below 1 mm at 1 km).
const GRID_SLACK_M := 0.5


func setup(loot_cfg: Dictionary, seed_value: int, zone: Dictionary = {}, landmarks: Array = []) -> void:
	cfg = loot_cfg
	_seed = seed_value
	_zone = zone
	_landmarks = landmarks


## Where each of the first items goes when clusters apply: one [centre, radius] per clustered item, in cluster
## order. A cluster whose landmark the map does not have is skipped (its items are scattered).
func _cluster_slots() -> Array:
	var slots: Array = []
	for cluster: Dictionary in cfg.get("clusters", []):
		for landmark: Dictionary in _landmarks:
			if String(landmark.get("id", "")) == String(cluster.get("landmark", "")):
				var at: Array = landmark["at"]
				for i in int(cluster.get("items", 0)):
					slots.append([Vector2(float(at[0]), float(at[1])), float(landmark["radius_m"])])
	return slots


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
	# W3: the first items go to the landmark clusters (same tries, same ground rules, inside the landmark's
	# area); the rest are scattered.
	var slots := _cluster_slots()
	var picks := pick_item_ids(cfg.get("items", {}), int(cfg.get("count", 0)), rng)
	for index in picks.size():
		var item_id := picks[index]
		var from := low
		var to := high
		var place := Vector2.ZERO
		var place_radius := -1.0
		if index < slots.size():
			place = slots[index][0]
			place_radius = slots[index][1]
			from = from.max(place - Vector2(place_radius, place_radius))
			to = to.min(place + Vector2(place_radius, place_radius))
			if from.x > to.x or from.y > to.y:
				continue  # the landmark lies outside the loot area or the zone: this item is not placed
		for attempt in 12:
			var x := rng.randf_range(from.x, to.x)
			var z := rng.randf_range(from.y, to.y)
			if in_circle and Vector2(x, z).distance_to(center) > radius:
				continue
			if place_radius >= 0.0 and Vector2(x, z).distance_to(place) > place_radius:
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
	_grid_sync()
	items[id] = entry
	_grid_insert(id, pos)
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
	for id in items_near(pos, range_m):
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
	_grid_sync()
	items.erase(id)
	_grid_remove(id)
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


## M2P1C stop 6: ids of every item that could lie within range_m of `pos` on the ground plane (a superset:
## whole grid cells, padded by GRID_SLACK_M), in `items` order. A range or position that is not finite (or
## beyond 1e6 m) returns every id.
func items_near(pos: Vector3, range_m: float) -> Array:
	_grid_sync()
	if not (absf(pos.x) + range_m < 1.0e6 and absf(pos.z) + range_m < 1.0e6):
		return items.keys()  # not finite or too big for cells (floori overflow): every id, still a superset
	var m := _grid_cell_m()
	var reach := range_m + GRID_SLACK_M
	var x0 := floori((pos.x - reach) / m)
	var x1 := floori((pos.x + reach) / m)
	var z0 := floori((pos.z - reach) / m)
	var z1 := floori((pos.z + reach) / m)
	var ranks := PackedInt32Array()
	if x1 < x0 or z1 < z0:
		return []
	if not (float(x1 - x0 + 1) * float(z1 - z0 + 1) <= float(_grid.size())):
		for key: Vector2i in _grid:
			if key.x >= x0 and key.x <= x1 and key.y >= z0 and key.y <= z1:
				ranks.append_array(_grid[key])
	else:
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var list: Variant = _grid.get(Vector2i(cx, cz))
				if list != null:
					ranks.append_array(list)
	ranks.sort()
	var out: Array = []
	out.resize(ranks.size())
	for i in ranks.size():
		out[i] = _rank_id[ranks[i]]
	return out


func _grid_cell_m() -> float:
	if _grid_m <= 0.0:
		var cfg: Dictionary = DataRegistry.new().load_file("res://data/map_build.json").get("spatial_index", {})
		_grid_m = maxf(float(cfg.get("loot_cell_m", 20.0)), 1.0)
	return _grid_m


## Rebuilds the grid when `items` was changed other than through _add / take (its size no longer matches).
func _grid_sync() -> void:
	if _grid_cell.size() == items.size():
		return
	_grid.clear()
	_grid_cell.clear()
	_rank.clear()
	_rank_id.clear()
	for id: int in items:
		_grid_insert(id, items[id]["pos"])


func _grid_insert(id: int, pos: Vector3) -> void:
	var m := _grid_cell_m()
	var key := Vector2i(floori(pos.x / m), floori(pos.z / m))
	var rank := _next_rank
	_next_rank += 1
	_rank[id] = rank
	_rank_id[rank] = id
	_grid_cell[id] = key
	var list: PackedInt32Array = _grid.get(key, PackedInt32Array())
	list.append(rank)
	_grid[key] = list


func _grid_remove(id: int) -> void:
	if not _grid_cell.has(id):
		return
	var key: Vector2i = _grid_cell[id]
	var rank: int = _rank[id]
	_grid_cell.erase(id)
	_rank.erase(id)
	_rank_id.erase(rank)
	var list: PackedInt32Array = _grid[key]
	var at := list.find(rank)
	if at >= 0:
		list.remove_at(at)
	if list.is_empty():
		_grid.erase(key)
	else:
		_grid[key] = list
