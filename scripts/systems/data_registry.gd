class_name DataRegistry
extends RefCounted
## Typed loader for data/*.json with a cache. No autoload needed.

const _ClassDefScript := preload("res://scripts/classes/class_def.gd")
const _WeaponDefScript := preload("res://scripts/weapons/weapon_def.gd")
const STATS_PATH := "res://data/stats.json"
const LOADOUTS_PATH := "res://data/loadouts.json"
const CAMERA_PATH := "res://data/camera.json"

var _cache: Dictionary = {}


## Returns the parsed dictionary, or {} if missing/invalid (no push_error).
func load_file(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var data: Dictionary = {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
	_cache[path] = data
	return data


func get_class_def(id: String) -> ClassDef:
	var classes: Dictionary = load_file(STATS_PATH).get("classes", {})
	if not classes.has(id):
		return null
	return ClassDef.from_dict(id, classes[id])


func get_weapon_def(id: String) -> WeaponDef:
	var weapons: Dictionary = load_file(STATS_PATH).get("weapons", {})
	if not weapons.has(id):
		return null
	return WeaponDef.from_dict(id, weapons[id])


func get_combat_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("combat", {})


func get_movement_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("movement", {})


func get_aim_assist_cfg() -> Dictionary:
	return load_file(STATS_PATH).get("aim_assist", {})


## Slot ids ("primary", "secondary", "sidearm") for a class, or {} if unknown.
func get_loadout_ids(class_id: String) -> Dictionary:
	return load_file(LOADOUTS_PATH).get("classes", {}).get(class_id, {})


func get_camera_cfg() -> Dictionary:
	return load_file(CAMERA_PATH)


## Returns a list of problems; empty means clean.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	var data := load_file(STATS_PATH)
	if data.is_empty():
		problems.append("stats.json missing or invalid")
		return problems
	var classes: Dictionary = data.get("classes", {})
	for id in classes:
		var c := ClassDef.from_dict(id, classes[id])
		if c.shield <= 0.0 or c.health <= 0.0 or c.speed_pct <= 0.0:
			problems.append("class %s has non-positive stat" % id)
	var weapons: Dictionary = data.get("weapons", {})
	for id in weapons:
		var w := WeaponDef.from_dict(id, weapons[id])
		if w.damage <= 0.0 or w.fire_interval_s <= 0.0 or w.magazine <= 0 or w.burst_count <= 0:
			problems.append("weapon %s has invalid stat" % id)
		if w.headshot_multiplier < 1.0:
			problems.append("weapon %s headshot_multiplier < 1" % id)
	var combat: Dictionary = data.get("combat", {})
	for k in ["shield_regen_delay_s", "shield_regen_rate_per_s", "overflow_to_health"]:
		if not combat.has(k):
			problems.append("combat.%s missing" % k)
	return problems
