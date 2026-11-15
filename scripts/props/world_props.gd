class_name WorldProps
extends Node
## M2 L1b: the match's breakables (one node per match, a child of MatchRoot; MatchDirector.props). The state lives
## here: prop id -> INTACT / BROKEN (OPEN is the chests', commit 4). On the authority (host or offline) a break rolls the prop's loot, seeded from
## the match seed and the prop id only (never from the order of events), and spills it through LootField.drop;
## `prop_changed` is for the network bridge. A client applies the host's states (apply_state): the look and the
## collider change, no loot is rolled. Numbers: data/props.json (OQ-PROPS-BREAK).

signal prop_changed(prop_id: String, state: int)

const PATH := "res://data/props.json"
const INTACT := 0
const BROKEN := 1
## A chest that has been opened (commit 4: nothing reaches this state yet).
const OPEN := 2
const BREAKABLES_KEY := "breakables"

var cfg: Dictionary = {}
var match_seed := 1
## True on the host and offline: loot is rolled and spilled. False on a client.
var authority := true
var loot: LootField
var breakables: Dictionary = {}  # id -> Breakable, in registration (build) order
var states: Dictionary = {}  # id -> state, for every prop that is no longer INTACT
## LootField ids this node spilled (the sims count them apart from dropped guns).
var spilled: Array[int] = []


static func config() -> Dictionary:
	return DataRegistry.new().load_file(PATH)


func setup(props_cfg: Dictionary, seed_value: int, is_authority: bool, loot_field: LootField = null) -> void:
	cfg = props_cfg
	match_seed = seed_value
	authority = is_authority
	loot = loot_field


## Registers every breakable under `root` (the map), in tree order.
func collect(root: Node) -> void:
	if root == null:
		return
	for node in root.find_children("*", "StaticBody3D", true, false):
		if node is Breakable:
			register_breakable(node)


func register_breakable(b: Breakable) -> void:
	if breakables.has(b.prop_id):
		return
	breakables[b.prop_id] = b
	b.broken.connect(_on_broken)


func state_of(prop_id: String) -> int:
	return int(states.get(prop_id, INTACT))


func _on_broken(prop_id: String) -> void:
	if states.has(prop_id):
		return
	states[prop_id] = BROKEN
	var b: Breakable = breakables.get(prop_id)
	if authority and b != null:
		var type_cfg: Dictionary = (cfg.get("breakables", {}) as Dictionary).get(b.prop_type, {})
		_spill(prop_id, type_cfg.get("loot", {}), "break", b.ground_point(), 0.0, 0.0)
	prop_changed.emit(prop_id, BROKEN)


## Client: applies a state the host decided. No loot, no `prop_changed`. Unknown ids and states are ignored; an
## already applied state does nothing.
func apply_state(prop_id: String, state: int) -> void:
	if state == BROKEN and breakables.has(prop_id) and not states.has(prop_id):
		states[prop_id] = BROKEN
		var b: Breakable = breakables[prop_id]
		if is_instance_valid(b):
			b.break_now(false)


func _spill(prop_id: String, roll: Dictionary, salt: String, at: Vector3, radius: float, yaw_deg: float) -> void:
	if loot == null:
		return
	var ids := loot_roll(loot.cfg.get("items", {}), roll, match_seed, prop_id, salt)
	var points := spill_points(at, ids.size(), radius, yaw_deg)
	for i in ids.size():
		spilled.append(loot.drop({"item_id": ids[i]}, points[i]))


## The items one prop drops (pure): count_min..count_max (0 allowed) item ids picked with LootField.pick_item_ids
## from the loot table limited to roll.item_kinds (empty or missing = every kind). The stream is seeded from the
## match seed, the prop id and the salt only, so every peer and every order of events gets the same items.
static func loot_roll(item_defs: Dictionary, roll: Dictionary, seed_value: int, prop_id: String, salt: String) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_value, prop_id, salt])
	var lo := maxi(int(roll.get("count_min", 0)), 0)
	var hi := maxi(int(roll.get("count_max", 0)), lo)
	var count := rng.randi_range(lo, hi)
	var kinds: Array = roll.get("item_kinds", [])
	var defs := item_defs
	if not kinds.is_empty():
		defs = {}
		for k: String in item_defs:
			if kinds.has(String((item_defs[k] as Dictionary).get("kind", ""))):
				defs[k] = item_defs[k]
	return LootField.pick_item_ids(defs, count, rng)


## `count` points evenly on a ring of `radius` around `centre` (the first at `yaw_deg`'s forward, -z turned);
## radius 0 = all at the centre. Pure, no random draw.
static func spill_points(centre: Vector3, count: int, radius: float, yaw_deg: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in count:
		var a := deg_to_rad(yaw_deg) + TAU * float(i) / float(maxi(count, 1))
		out.append(centre + Vector3(-sin(a), 0.0, -cos(a)) * radius)
	return out


## What is wrong with a map cover file's "breakables" (optional) against data/props.json, one line each (empty:
## fine). Ids are unique across pieces, ring pieces and breakables.
static func problems(cover_file: Dictionary, props_cfg: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var types: Dictionary = props_cfg.get("breakables", {})
	if types.is_empty():
		out.append("props breakables is empty")
	for type: String in types:
		var t: Variant = types[type]
		if not t is Dictionary or not _num(t.get("health")) or float(t["health"]) <= 0.0:
			out.append("props breakables.%s: health must be a number > 0" % type)
			continue
		if not _num(t.get("melee_damage")) or float(t["melee_damage"]) < 0.0:
			out.append("props breakables.%s: melee_damage must be a number >= 0" % type)
		if typeof(t.get("look")) != TYPE_DICTIONARY:
			out.append("props breakables.%s: look must be a dictionary" % type)
		out.append_array(_roll_problems("breakables.%s.loot" % type, t.get("loot", {})))
	var seen := {}
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Variant in cover_file.get(list, []):
			if entry is Dictionary:
				seen[str(entry.get("id", ""))] = true
	if not cover_file.has(BREAKABLES_KEY):
		return out
	if typeof(cover_file[BREAKABLES_KEY]) != TYPE_ARRAY:
		out.append("cover file '%s' must be an array" % BREAKABLES_KEY)
		return out
	for entry: Variant in cover_file[BREAKABLES_KEY]:
		if not entry is Dictionary:
			out.append("cover file '%s' holds a non-dictionary entry" % BREAKABLES_KEY)
			continue
		var id := str(entry.get("id", ""))
		if id == "" or seen.has(id):
			out.append("breakable id '%s' is empty or not unique" % id)
		seen[id] = true
		if not _vec3(entry.get("at")):
			out.append("breakable %s: at must be [x, y, z]" % id)
		if not _vec3(entry.get("size"), true):
			out.append("breakable %s: size must be three numbers > 0" % id)
		if not types.has(str(entry.get("type", ""))):
			out.append("breakable %s: type '%s' is not in data/props.json breakables" % [id, str(entry.get("type", ""))])
	return out


static func _roll_problems(what: String, roll: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not roll is Dictionary:
		out.append("props %s must be a dictionary" % what)
		return out
	var lo: Variant = roll.get("count_min", 0)
	var hi: Variant = roll.get("count_max", 0)
	if not _num(lo) or not _num(hi) or float(lo) < 0.0 or float(hi) < float(lo):
		out.append("props %s: 0 <= count_min <= count_max" % what)
	if typeof(roll.get("item_kinds", [])) != TYPE_ARRAY:
		out.append("props %s: item_kinds must be an array" % what)
	return out


static func _num(v: Variant) -> bool:
	return v is float or v is int


static func _vec3(v: Variant, positive := false) -> bool:
	if typeof(v) != TYPE_ARRAY or (v as Array).size() != 3:
		return false
	for c: Variant in v:
		if not _num(c) or (positive and float(c) <= 0.0):
			return false
	return true
