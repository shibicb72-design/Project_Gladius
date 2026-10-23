class_name HudLayoutModel
extends RefCounted
## G2e: the player's saved touch-HUD layouts. Slots 1-3 (stored 0-based), one active. A slot only holds
## what the player changed: element key -> {"pos": [x, y] (fractions of the HUD), "size_pct", "alpha_pct"}.
## An empty slot (or a missing field) means the data/input.json touch_layout default (G2L). Ranges come from
## data/input.json layout_editor (placeholders). Lives in the profile (user://) under "hud_layouts".

const ELEMENT_KEY_MAX_LEN := 40
const LOCK_KEY := "sprint_lock"  # element key of the Sprint lock button (same as TouchHud.LOCK_KEY)

var active: int = 0
var slots: Array = []  # slot index -> {element key -> {pos, size_pct, alpha_pct}}


static func cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/input.json")["layout_editor"]


func _init() -> void:
	for i in int(cfg()["slots"]):
		slots.append({})


static func from_dict(d: Variant) -> HudLayoutModel:
	var m := HudLayoutModel.new()
	if not (d is Dictionary):
		return m
	var raw: Variant = d.get("slots", [])
	if raw is Array:
		for i in mini(raw.size(), m.slots.size()):
			m.slots[i] = _sanitize_slot(raw[i])
	var a: Variant = d.get("active", 0)
	if a is float or a is int:
		m.active = clampi(int(a), 0, m.slots.size() - 1)
	return m


func to_dict() -> Dictionary:
	return {"active": active, "slots": slots.duplicate(true)}


static func _num(v: Variant) -> bool:
	return v is float or v is int


static func _range_value(v: float, range_cfg: Dictionary) -> float:
	return clampf(snappedf(v, float(range_cfg["step"])), float(range_cfg["min"]), float(range_cfg["max"]))


static func _sanitize_slot(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for key in v:
		if not (key is String) or key == "" or key.length() > ELEMENT_KEY_MAX_LEN or not (v[key] is Dictionary):
			continue
		var e: Dictionary = v[key]
		var clean := {}
		var p: Variant = e.get("pos", null)
		if p is Array and p.size() == 2 and _num(p[0]) and _num(p[1]):
			clean["pos"] = [clampf(float(p[0]), 0.0, 1.0), clampf(float(p[1]), 0.0, 1.0)]
		if _num(e.get("size_pct", null)):
			clean["size_pct"] = _range_value(float(e["size_pct"]), cfg()["size_pct"])
		if _num(e.get("alpha_pct", null)):
			clean["alpha_pct"] = _range_value(float(e["alpha_pct"]), cfg()["alpha_pct"])
		if not clean.is_empty():
			out[key] = clean
	return out


func active_slot() -> Dictionary:
	return slots[active]


func set_active(i: int) -> void:
	active = clampi(i, 0, slots.size() - 1)


func _entry(slot_i: int, key: String) -> Dictionary:
	if not slots[slot_i].has(key):
		slots[slot_i][key] = {}
	return slots[slot_i][key]


func set_pos(slot_i: int, key: String, frac: Vector2) -> void:
	_entry(slot_i, key)["pos"] = [clampf(frac.x, 0.0, 1.0), clampf(frac.y, 0.0, 1.0)]


## Not clamped to the 48 dp floor here: the HUD enforces that at render time for the current device.
func set_size_pct(slot_i: int, key: String, pct: float) -> void:
	_entry(slot_i, key)["size_pct"] = _range_value(pct, cfg()["size_pct"])


func set_alpha_pct(slot_i: int, key: String, pct: float) -> void:
	_entry(slot_i, key)["alpha_pct"] = _range_value(pct, cfg()["alpha_pct"])


## Reset for one slot: back to the G2L default layout.
func reset_slot(slot_i: int) -> void:
	slots[slot_i] = {}
