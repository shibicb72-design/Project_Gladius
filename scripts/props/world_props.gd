class_name WorldProps
extends Node
## M2 L1b: the match's breakables and loot chests (one node per match, a child of MatchRoot; MatchDirector.props).
## The state lives here: prop id -> INTACT / BROKEN (breakables) / OPEN (chests). On the authority (host or offline)
## a break or an opening rolls the prop's loot, seeded from the match seed and the prop id only (never from the
## order of events), and spills it through LootField.drop; `prop_changed` is for the network bridge. A client
## applies the host's states (apply_state): the look and the collider change, no loot is rolled. Numbers:
## data/props.json (OQ-PROPS-BREAK, OQ-PROPS-CHEST).
## M2 L1c: doors and gates (Door). Every door's state is stored from registration (OPEN or CLOSED, the cover file's
## start state), unlike breakables and chests (only non-INTACT is stored). The authority sets an ABSOLUTE state
## (set_door; toggle_door picks the other one) and emits prop_changed; a client applies every CHANGED door state.

signal prop_changed(prop_id: String, state: int)

const PATH := "res://data/props.json"
const INTACT := 0
const BROKEN := 1
## A chest that has been opened; a door or gate that is open.
const OPEN := 2
## M2 L1c: a door or gate that is closed.
const CLOSED := 3
const BREAKABLES_KEY := "breakables"
const CHESTS_KEY := "chests"
const DOORS_KEY := "doors"

var cfg: Dictionary = {}
var match_seed := 1
## True on the host and offline: loot is rolled and spilled. False on a client.
var authority := true
var loot: LootField
var breakables: Dictionary = {}  # id -> Breakable, in registration (build) order
var chests: Dictionary = {}  # id -> LootChest, in registration (build) order
var doors: Dictionary = {}  # id -> Door, in registration (build) order
var states: Dictionary = {}  # id -> state, for every prop that is no longer INTACT, and for every door
## LootField ids this node spilled (the sims count them apart from dropped guns).
var spilled: Array[int] = []


static func config() -> Dictionary:
	return DataRegistry.new().load_file(PATH)


func setup(props_cfg: Dictionary, seed_value: int, is_authority: bool, loot_field: LootField = null) -> void:
	cfg = props_cfg
	match_seed = seed_value
	authority = is_authority
	loot = loot_field


## Registers every breakable, chest and door under `root` (the map), in tree order.
func collect(root: Node) -> void:
	if root == null:
		return
	for node in root.find_children("*", "StaticBody3D", true, false):
		if node is Breakable:
			register_breakable(node)
		elif node is LootChest:
			register_chest(node)
		elif node is Door:
			register_door(node)


func register_breakable(b: Breakable) -> void:
	if breakables.has(b.prop_id):
		return
	breakables[b.prop_id] = b
	b.broken.connect(_on_broken)


func register_chest(c: LootChest) -> void:
	if not chests.has(c.prop_id):
		chests[c.prop_id] = c


## M2 L1c: a door's state is stored at once: its current target (the cover file's start state at build).
func register_door(d: Door) -> void:
	if doors.has(d.prop_id):
		return
	doors[d.prop_id] = d
	states[d.prop_id] = OPEN if d.open else CLOSED


## M2 L1c: data/props.json "door" with, for kind "gate", the "gate" block merged over it (the gate key itself
## removed).
static func door_cfg(props_cfg: Dictionary, kind: String) -> Dictionary:
	var out: Dictionary = (props_cfg.get("door", {}) as Dictionary).duplicate(true)
	var gate: Variant = out.get(Door.KIND_GATE, {})
	out.erase(Door.KIND_GATE)
	if kind == Door.KIND_GATE and gate is Dictionary:
		out.merge(gate, true)
	return out


## M2 L1c: the id of the nearest door (or gate) whose closed leaves' footprint lies within its kind's
## interact_range_m of `pos` on the ground plane and whose threshold lies within its height_limit_m of `pos`; "" if
## none. Open and closed doors both count (Interact toggles). Ties keep the first registered.
func door_near(pos: Vector3) -> String:
	var best := ""
	var best_d := INF
	for id: String in doors:
		var d: Door = doors[id]
		if not is_instance_valid(d) or absf(d.bottom_y() - pos.y) > d.height_limit_m:
			continue
		var dist := d.distance_to(pos)
		if dist <= d.interact_range_m and dist < best_d:
			best = id
			best_d = dist
	return best


## M2 L1c: authority only: sets a door to OPEN or CLOSED (absolute), starts its motion and emits prop_changed.
## False on a client, for an unknown id, a state other than OPEN / CLOSED, or the state it already has.
func set_door(prop_id: String, state: int) -> bool:
	if not authority or not doors.has(prop_id) or (state != OPEN and state != CLOSED) or state_of(prop_id) == state:
		return false
	var d: Door = doors[prop_id]
	if not is_instance_valid(d):
		return false
	states[prop_id] = state
	d.set_open(state == OPEN)
	prop_changed.emit(prop_id, state)
	return true


## M2 L1c: authority only: the other state (OPEN -> CLOSED, CLOSED -> OPEN), sent as that absolute value.
func toggle_door(prop_id: String) -> bool:
	return set_door(prop_id, CLOSED if state_of(prop_id) == OPEN else OPEN)


## M2 L1c: "door" or "gate" ("" for an unknown id).
func door_kind(prop_id: String) -> String:
	var d: Door = doors.get(prop_id)
	return d.kind if d != null and is_instance_valid(d) else ""


## The id of the nearest CLOSED chest whose centre lies within chest.interact_range_m of `pos` on the ground
## plane and whose bottom lies within chest.height_limit_m of `pos` in height; "" if none. Ties keep the first
## registered.
func chest_near(pos: Vector3) -> String:
	var chest_cfg: Dictionary = cfg.get("chest", {})
	var range_m := float(chest_cfg.get("interact_range_m", 0.0))
	var height_m := float(chest_cfg.get("height_limit_m", 2.0))
	var best := ""
	var best_d := INF
	for id: String in chests:
		var c: LootChest = chests[id]
		if states.has(id) or not is_instance_valid(c):
			continue
		var at := c.ground_point()
		if absf(at.y - pos.y) > height_m:
			continue
		var d := Vector2(at.x - pos.x, at.z - pos.z).length()
		if d <= range_m and d < best_d:
			best = id
			best_d = d
	return best


## Authority only: opens a closed chest (state OPEN, the look swapped, the seeded roll of chest.loot spilled on a
## ring in front of it, prop_changed). False on a client, for an unknown id or a chest already open.
func open_chest(prop_id: String) -> bool:
	if not authority or states.has(prop_id) or not chests.has(prop_id):
		return false
	var c: LootChest = chests[prop_id]
	if not is_instance_valid(c):
		return false
	states[prop_id] = OPEN
	c.open_look()
	var chest_cfg: Dictionary = cfg.get("chest", {})
	_spill(prop_id, chest_cfg.get("loot", {}), "chest", c.spill_centre(float(chest_cfg.get("spill_offset_m", 0.0))),
			float(chest_cfg.get("spill_radius_m", 0.0)), c.yaw_deg)
	prop_changed.emit(prop_id, OPEN)
	return true


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
## already applied state does nothing. BROKEN breaks a breakable (look and collider); OPEN swaps a chest's look.
## M2 L1c: a door takes every CHANGED OPEN / CLOSED (it always has a state; the motion runs on this peer).
func apply_state(prop_id: String, state: int) -> void:
	if doors.has(prop_id):
		if (state == OPEN or state == CLOSED) and state_of(prop_id) != state:
			states[prop_id] = state
			var d: Door = doors[prop_id]
			if is_instance_valid(d):
				d.set_open(state == OPEN)
		return
	if states.has(prop_id):
		return
	if state == BROKEN and breakables.has(prop_id):
		states[prop_id] = BROKEN
		var b: Breakable = breakables[prop_id]
		if is_instance_valid(b):
			b.break_now(false)
	elif state == OPEN and chests.has(prop_id):
		states[prop_id] = OPEN
		var c: LootChest = chests[prop_id]
		if is_instance_valid(c):
			c.open_look()


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
## fine). Ids are unique across pieces, ring pieces and breakables. M2 L1c: also data/props.json "door" and the
## cover file's optional "doors" (ids unique across every list).
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
	out.append_array(_chest_cfg_problems(props_cfg.get("chest")))
	var seen := {}
	for list: String in ["pieces", "ring_pieces"]:
		for entry: Variant in cover_file.get(list, []):
			if entry is Dictionary:
				seen[str(entry.get("id", ""))] = true
	out.append_array(_chest_entry_problems(cover_file, seen))
	out.append_array(_door_cfg_problems(props_cfg.get("door")))
	out.append_array(_door_entry_problems(cover_file, seen))
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


## data/props.json "chest": a range > 0, a height limit >= 0, a palette, two looks with parts, a look_size > 0, the
## spill numbers >= 0 and a loot roll.
static func _chest_cfg_problems(chest: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not chest is Dictionary:
		out.append("props chest must be a dictionary")
		return out
	if not _num(chest.get("interact_range_m")) or float(chest["interact_range_m"]) <= 0.0:
		out.append("props chest.interact_range_m must be a number > 0")
	for key: String in ["height_limit_m", "spill_offset_m", "spill_radius_m"]:
		if not _num(chest.get(key)) or float(chest[key]) < 0.0:
			out.append("props chest.%s must be a number >= 0" % key)
	if typeof(chest.get("palette")) != TYPE_STRING:
		out.append("props chest.palette must be a string")
	if not _vec3(chest.get("look_size"), true):
		out.append("props chest.look_size must be three numbers > 0")
	for key: String in ["look_closed", "look_open"]:
		var look: Variant = chest.get(key)
		if not look is Dictionary or typeof(look.get("parts")) != TYPE_ARRAY or (look["parts"] as Array).is_empty():
			out.append("props chest.%s must hold a non-empty parts list" % key)
	out.append_array(_roll_problems("chest.loot", chest.get("loot", {})))
	return out


## A cover file's optional "chests": {id, at, size, yaw}, ids unique across every list (adds them to `seen`), yaw a
## multiple of 90.
static func _chest_entry_problems(cover_file: Dictionary, seen: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if not cover_file.has(CHESTS_KEY):
		return out
	if typeof(cover_file[CHESTS_KEY]) != TYPE_ARRAY:
		out.append("cover file '%s' must be an array" % CHESTS_KEY)
		return out
	for entry: Variant in cover_file[CHESTS_KEY]:
		if not entry is Dictionary:
			out.append("cover file '%s' holds a non-dictionary entry" % CHESTS_KEY)
			continue
		var id := str(entry.get("id", ""))
		if id == "" or seen.has(id):
			out.append("chest id '%s' is empty or not unique" % id)
		seen[id] = true
		if not _vec3(entry.get("at")):
			out.append("chest %s: at must be [x, y, z]" % id)
		if not _vec3(entry.get("size"), true):
			out.append("chest %s: size must be three numbers > 0" % id)
		var yaw: Variant = entry.get("yaw")
		if not _num(yaw) or not is_equal_approx(fposmod(float(yaw), 90.0), 0.0):
			out.append("chest %s: yaw must be a multiple of 90" % id)
	return out


## M2 L1c: data/props.json "door" (and its kind "gate", merged): a range > 0, a height limit >= 0, a move time > 0,
## a retry > 0, a bot delay >= 0, a palette, a look_size > 0 and a non-empty look.
static func _door_cfg_problems(door: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not door is Dictionary:
		out.append("props door must be a dictionary")
		return out
	if door.has(Door.KIND_GATE) and not door[Door.KIND_GATE] is Dictionary:
		out.append("props door.gate must be a dictionary")
		return out
	for kind: String in [Door.KIND_DOOR, Door.KIND_GATE]:
		var c := door_cfg({"door": door}, kind)
		for key: String in ["interact_range_m", "move_time_s", "blocked_retry_s"]:
			if not _num(c.get(key)) or float(c[key]) <= 0.0:
				out.append("props door (%s).%s must be a number > 0" % [kind, key])
		for key: String in ["height_limit_m", "bot_open_delay_s"]:
			if not _num(c.get(key)) or float(c[key]) < 0.0:
				out.append("props door (%s).%s must be a number >= 0" % [kind, key])
		if typeof(c.get("palette")) != TYPE_STRING:
			out.append("props door (%s).palette must be a string" % kind)
		if not _vec3(c.get("look_size"), true):
			out.append("props door (%s).look_size must be three numbers > 0" % kind)
		var look: Variant = c.get("look")
		if not look is Dictionary or typeof(look.get("parts")) != TYPE_ARRAY or (look["parts"] as Array).is_empty():
			out.append("props door (%s).look must hold a non-empty parts list" % kind)
	return out


## M2 L1c: a cover file's optional "doors": {id, kind (door | gate), at, yaw (a number), size (three numbers > 0),
## slide (left | right | apart), start (open | closed)}, ids unique across every list (adds them to `seen`).
static func _door_entry_problems(cover_file: Dictionary, seen: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if not cover_file.has(DOORS_KEY):
		return out
	if typeof(cover_file[DOORS_KEY]) != TYPE_ARRAY:
		out.append("cover file '%s' must be an array" % DOORS_KEY)
		return out
	for entry: Variant in cover_file[DOORS_KEY]:
		if not entry is Dictionary:
			out.append("cover file '%s' holds a non-dictionary entry" % DOORS_KEY)
			continue
		var id := str(entry.get("id", ""))
		if id == "" or seen.has(id):
			out.append("door id '%s' is empty or not unique" % id)
		seen[id] = true
		if not str(entry.get("kind", "")) in [Door.KIND_DOOR, Door.KIND_GATE]:
			out.append("door %s: kind must be door or gate" % id)
		if not _vec3(entry.get("at")):
			out.append("door %s: at must be [x, y, z]" % id)
		if not _vec3(entry.get("size"), true):
			out.append("door %s: size must be three numbers > 0" % id)
		if not _num(entry.get("yaw")):
			out.append("door %s: yaw must be a number" % id)
		if not str(entry.get("slide", "")) in Door.SLIDES:
			out.append("door %s: slide must be left, right or apart" % id)
		if not str(entry.get("start", "")) in Door.STARTS:
			out.append("door %s: start must be open or closed" % id)
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
