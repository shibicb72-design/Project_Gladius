class_name CoverIndex
extends RefCounted
## M2P1C stop 6: a grid over the bodies of group "cover_wall", so CoverProbe's join of connected coplanar
## boxes looks only at walls near the current ends instead of walking the whole group (131 walls on alesia,
## 433 on test_300, ~4,800 expected at 1 km). It only narrows the candidates: CoverProbe still runs every
## per-wall check of the old walk live on each candidate, and the join's result (a min/max fixpoint over
## the accepted walls) does not depend on the order the candidates come in.
##
## Lifetime: one index per SceneTree, held as a meta on the tree's root (of()), so it goes with the tree and
## never lives in a static. It mirrors the whole group, exactly like the old walk (every cover_wall node in
## the tree, whatever map or world it belongs to); walls of a freed match leave it with the group.
##
## Staleness (refresh(), once per CoverProbe.sample before the join). Two tiers:
##  1. Every refresh, O(1): a dirty flag and the group's node COUNT (SceneTree.get_node_count_in_group)
##     against the count the index was built from; either one rebuilds at once. The flag is set by SceneTree
##     node_added / node_removed / node_renamed of a wall or of a wall's child (its "Shape": added, removed,
##     renamed, reparented) and by the `changed` signal of an indexed box (resized in place). So a wall added
##     to the tree, removed, freed, or tagged into / out of the group, and a box resized, are seen by the very
##     next sample with no frame in between. One gap: an in-tree node tagged in and another tagged out between
##     two samples of one frame, with no tree change, leaves the count equal; tier 2 sees it next frame.
##  2. At most once per frame, O(walls): when Engine.get_physics_frames() or Engine.get_process_frames() has
##     changed since the last build or full validation, the group's node array is compared with the one built
##     from (native Array ==) and every indexed wall's Shape global position and box resource with what was
##     indexed (_valid); any difference rebuilds. So a wall MOVED silently (itself, its Shape or an ancestor),
##     or a Shape given another box resource, is seen from the next frame on, not within the frame it happened
##     in. This is a deliberate difference from the old whole-group walk, limited to a wall moved between two
##     samples of one frame (map walls are static); it keeps the per-sample cost independent of the wall count.
##     The frame counters serve this cache validation only, never a gameplay decision. `validations` counts
##     these full validations.
## Disabled shapes and collision_layer are not indexed at all: CoverProbe checks them live per candidate.
## Cell size: data/map_build.json "spatial_index.cover_cell_m" (placeholder, OQ-MAP-INDEX).

const GROUP := &"cover_wall"
const META := &"cover_index"
const CFG_PATH := "res://data/map_build.json"
## Pad on every side of a query, for float rounding of the old test (float32 vectors; far below 1 mm at
## 1 km) and its n.n != 1 term (a wall's half-extent times |1 - n.n|, < 1e-3 m for any wall under 1 km).
const SLACK_M := 0.5
## A hit normal tilted more than this out of the horizontal plane, or with a horizontal part shorter than
## MIN_FLAT, gets every wall as a candidate (no narrowing; still exact).
const MAX_TILT := 0.001
const MIN_FLAT := 0.5
## A wall whose footprint spans more cells than this is checked on every query instead of being gridded.
const MAX_CELLS_PER_WALL := 256
## Coordinates beyond this (or a NaN) are not gridded: such a wall is always checked, such a query gets
## every wall (floori of a huge float is not a usable cell).
const BIG_M := 1.0e7

var cell_m := 16.0
var _tree: SceneTree
var _members: Array[Node] = []
var _dirty := true
## Per entry (every StaticBody3D of the group at build time, in group order).
var _bodies: Array = []
var _shapes: Array = []  # CollisionShape3D, or null for an entry that is checked on every query
var _boxes: Array = []  # its BoxShape3D at build time
var _pos := PackedVector3Array()  # the shape's global position at build time
var _size := PackedVector3Array()  # the box size at build time
var _always := PackedInt32Array()  # entries returned by every query (no box at build time, or too big)
var _cells: Dictionary = {}  # Vector2i -> PackedInt32Array of entries whose footprint overlaps the cell
var _stamp := PackedInt32Array()
var _query := 0
var _y_min := 0.0
var _y_max := 0.0
## The gridded entries' Shape nodes, box resources and global positions, compact, for _valid().
var _check_shapes: Array[CollisionShape3D] = []
var _check_boxes: Array = []
var _check_pos := PackedVector3Array()
## Box resources whose `changed` signal is connected to _on_box_changed.
var _watched: Array = []
## The engine's physics and process frame counters at the last build or full validation (cache validation
## only; never used for any gameplay decision).
var _checked_physics := -1
var _checked_process := -1
## Counters for tests: builds and full (O(walls)) validations so far.
var builds := 0
var validations := 0


## The tree's index, made on first use.
static func of(tree: SceneTree) -> CoverIndex:
	var root := tree.root
	if root.has_meta(META):
		return root.get_meta(META)
	var index := CoverIndex.new()
	index._attach(tree)
	root.set_meta(META, index)
	return index


func _attach(tree: SceneTree) -> void:
	_tree = tree
	var cfg: Dictionary = DataRegistry.new().load_file(CFG_PATH).get("spatial_index", {})
	cell_m = maxf(float(cfg.get("cover_cell_m", cell_m)), 1.0)
	tree.node_added.connect(_on_tree_change)
	tree.node_removed.connect(_on_tree_change)
	tree.node_renamed.connect(_on_tree_change)


func _on_tree_change(node: Node) -> void:
	if _dirty:
		return
	if node.is_in_group(GROUP):
		_dirty = true
		return
	var parent := node.get_parent()
	if parent != null and parent.is_in_group(GROUP):
		_dirty = true


## Brings the index up to date (see the class notes). Call once per sample before walls_near().
func refresh() -> void:
	if _dirty or _tree.get_node_count_in_group(GROUP) != _members.size():
		_build(_tree.get_nodes_in_group(GROUP))
		return
	var physics := Engine.get_physics_frames()
	var process := Engine.get_process_frames()
	if physics == _checked_physics and process == _checked_process:
		return
	_checked_physics = physics
	_checked_process = process
	validations += 1
	var members := _tree.get_nodes_in_group(GROUP)
	if members != _members or not _valid():
		_build(members)


## True while every gridded wall's Shape still has its indexed box resource and global position. Kept to
## two reads per wall: a Shape freed, removed or renamed arrives through the tree signals (_dirty), and a
## box resized through its `changed` signal (_on_box_changed), all before this runs.
func _valid() -> bool:
	for i in _check_shapes.size():
		var node: CollisionShape3D = _check_shapes[i]
		if node.global_position != _check_pos[i] or node.shape != _check_boxes[i]:
			return false
	return true


func _on_box_changed() -> void:
	_dirty = true


func _build(members: Array[Node]) -> void:
	builds += 1
	_dirty = false
	_members = members
	_checked_physics = Engine.get_physics_frames()
	_checked_process = Engine.get_process_frames()
	_bodies.clear()
	_always.clear()
	_cells.clear()
	_check_shapes.clear()
	_check_boxes.clear()
	_check_pos.clear()
	for box: Resource in _watched:
		if is_instance_valid(box) and box.changed.is_connected(_on_box_changed):
			box.changed.disconnect(_on_box_changed)
	_watched.clear()
	_y_min = 0.0
	_y_max = 0.0
	var have_y := false
	for node in members:
		if not node is StaticBody3D:
			continue
		var i := _bodies.size()
		_bodies.append(node)
		var shape := node.get_node_or_null("Shape") as CollisionShape3D
		var box: BoxShape3D = shape.shape as BoxShape3D if shape != null else null
		if box == null:
			_always.append(i)  # no box now: checked on every query (a box given later shows in _valid)
			if shape != null:
				_check_shapes.append(shape)
				_check_boxes.append(shape.shape)
				_check_pos.append(shape.global_position)
			continue
		var p := shape.global_position
		var half := box.size * 0.5
		_check_shapes.append(shape)
		_check_boxes.append(box)
		_check_pos.append(p)
		if not box.changed.is_connected(_on_box_changed):
			box.changed.connect(_on_box_changed)
			_watched.append(box)
		_y_min = p.y if not have_y else minf(_y_min, p.y)
		_y_max = p.y if not have_y else maxf(_y_max, p.y)
		have_y = true
		# Gridded square: centre p, half-side w = hx + hz on both axes (see walls_near: an accepted wall's centre
		# lies within w of the query rectangle on each world axis, whatever the normal's direction).
		var w := absf(half.x) + absf(half.z)
		var x0 := floori((p.x - w) / cell_m)
		var x1 := floori((p.x + w) / cell_m)
		var z0 := floori((p.z - w) / cell_m)
		var z1 := floori((p.z + w) / cell_m)
		if not (w <= cell_m * 8.0 and absf(p.x) < BIG_M and absf(p.z) < BIG_M) or float(x1 - x0 + 1) * float(z1 - z0 + 1) > MAX_CELLS_PER_WALL:
			_always.append(i)
			continue
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var key := Vector2i(cx, cz)
				if not _cells.has(key):
					_cells[key] = PackedInt32Array()
				var list: PackedInt32Array = _cells[key]
				list.append(i)
				_cells[key] = list
	_stamp.resize(_bodies.size())
	_stamp.fill(0)
	_query = 0


## Every wall that the old walk's test could accept against `ends` (plus walls that are always checked).
## A wall (shape centre p, box half-size hx, hz) passes the old test only if (1) |(face - point).n| <=
## epsilon, face = p + n * k, k = |n.x| hx + |n.z| hz, and (2) [mid - r, mid + r] meets [ends.x - epsilon,
## ends.y + epsilon], mid = (p - center).t, r = |t.x| hx + |t.z| hz. With n^ the unit horizontal normal
## (t = (n^z, 0, -n^x)) and u = (p - point).n^: (1) gives u in band B = [-e' - k^, e' - k^], e' = (epsilon +
## |n.y| |p.y - point.y|) / |n_h|, k^ = |n^x| hx + |n^z| hz; (2) gives mid within r of [ends.x - epsilon,
## ends.y + epsilon]. So p = q + t a + n^ b with q in the query rectangle Q (s along t from center in that
## strip, |u| <= e'), |a| <= r and |b| <= k^. On world x, |t.x a + n^x b| <= |n^z| r + |n^x| k^ = hx + 2
## |n^x n^z| hz <= hx + hz (z likewise). The two conditions are tested separately, so the box's own
## footprint need not meet Q; but its centre is always within hx + hz of Q on each axis. Walls are gridded
## by that square around p (_build) and the query takes Q's x/z bounds plus SLACK_M, so none is missed.
func walls_near(normal: Vector3, point: Vector3, center: Vector3, tangent: Vector3, ends: Vector2, epsilon: float) -> Array:
	var flat := Vector2(normal.x, normal.z)
	var flat_len := flat.length()
	if absf(normal.y) > MAX_TILT or flat_len < MIN_FLAT:
		return _bodies
	var out: Array = []
	for i in _always:
		out.append(_bodies[i])
	if _cells.is_empty():
		return out
	_query += 1
	var nh := flat / flat_len
	var t := Vector2(tangent.x, tangent.z)
	var y_dev := maxf(absf(_y_max - point.y), absf(_y_min - point.y))
	var band := (epsilon + absf(normal.y) * y_dev) / flat_len + SLACK_M
	var s0 := ends.x - epsilon - SLACK_M
	var s1 := ends.y + epsilon + SLACK_M
	var c := Vector2(center.x, center.z)
	var u_mid := (Vector2(point.x, point.z) - c).dot(nh)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for s in [s0, s1]:
		for u in [u_mid - band, u_mid + band]:
			var q: Vector2 = c + t * float(s) + nh * float(u)
			lo = lo.min(q)
			hi = hi.max(q)
	if not (absf(lo.x) < BIG_M and absf(lo.y) < BIG_M and absf(hi.x) < BIG_M and absf(hi.y) < BIG_M):
		return _bodies
	var x0 := floori(lo.x / cell_m)
	var x1 := floori(hi.x / cell_m)
	var z0 := floori(lo.y / cell_m)
	var z1 := floori(hi.y / cell_m)
	if not (float(x1 - x0 + 1) * float(z1 - z0 + 1) <= float(_cells.size())):
		for key: Vector2i in _cells:
			if key.x >= x0 and key.x <= x1 and key.y >= z0 and key.y <= z1:
				_collect(_cells[key], out)
	else:
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var list: Variant = _cells.get(Vector2i(cx, cz))
				if list != null:
					_collect(list, out)
	return out


func _collect(list: PackedInt32Array, out: Array) -> void:
	for i in list:
		if _stamp[i] != _query:
			_stamp[i] = _query
			out.append(_bodies[i])


## Entries in the index (tests).
func size() -> int:
	return _bodies.size()
