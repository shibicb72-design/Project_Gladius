class_name SaveService
extends RefCounted
## Profile persistence in user:// (never hard-coded paths). Load is tolerant: a missing or corrupt
## file gives defaults, and never calls push_error.

const VERSION := 1
const DEFAULT_PATH := "user://profile.json"
const DEFAULT_GAMERTAG := "Player"  # OQ-39 placeholder

var path: String = DEFAULT_PATH


func _init(save_path: String = DEFAULT_PATH) -> void:
	path = save_path


static func defaults() -> Dictionary:
	return {"version": VERSION, "gamertag": DEFAULT_GAMERTAG, "last_ip": "", "gyro_enabled": false,  # OQ-34: gyro off by default
			"move_stick": "", "vjoy_layout": "",  # "" = use data/input.json touch_layout (see docs/CONTROLS.md)
			"sprint_sensitivity": DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]["default"],
			"sprint_lock_pos": []}  # [] = data/input.json touch_layout.sprint_lock_pos; G2e's layout editor writes [x, y] (fractions)


## Slider value from a file or menu: snapped to the step and clamped to the data range.
static func _sensitivity(value: Variant) -> float:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]
	if not (value is float or value is int):
		return float(cfg["default"])
	return SprintDetector.snap_sensitivity(float(value), cfg)


## Sprint lock button position: [x, y] fractions of the HUD, or [] for the data default.
static func _lock_pos(value: Variant) -> Array:
	if value is Array and value.size() == 2 and (value[0] is float or value[0] is int) and (value[1] is float or value[1] is int):
		return [clampf(float(value[0]), 0.0, 1.0), clampf(float(value[1]), 0.0, 1.0)]
	return []


## A touch-layout choice from a file or menu: only the listed values are kept, anything else means "unset".
static func _choice(value: Variant, allowed: Array) -> String:
	var s := str(value)
	return s if allowed.has(s) else ""


## Input config value for GyroProvider.configure(): "off" unless the profile turned gyro on.
static func gyro_mode(profile: Dictionary) -> String:
	return "on" if bool(profile.get("gyro_enabled", false)) else "off"


func load_profile() -> Dictionary:
	var profile := defaults()
	if not FileAccess.file_exists(path):
		return profile
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return profile
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return profile
	var data: Dictionary = json.data
	var tag := str(data.get("gamertag", ""))
	if not tag.strip_edges().is_empty():
		profile["gamertag"] = tag
	profile["last_ip"] = str(data.get("last_ip", ""))
	profile["gyro_enabled"] = bool(data.get("gyro_enabled", false))
	profile["move_stick"] = _choice(data.get("move_stick", ""), ["virtual", "custom"])
	profile["vjoy_layout"] = _choice(data.get("vjoy_layout", ""), ["floating", "fixed"])
	profile["sprint_sensitivity"] = _sensitivity(data.get("sprint_sensitivity", null))
	profile["sprint_lock_pos"] = _lock_pos(data.get("sprint_lock_pos", null))
	return profile


func save_profile(profile: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var out := defaults()
	out["gamertag"] = str(profile.get("gamertag", DEFAULT_GAMERTAG))
	out["last_ip"] = str(profile.get("last_ip", ""))
	out["gyro_enabled"] = bool(profile.get("gyro_enabled", false))
	out["move_stick"] = _choice(profile.get("move_stick", ""), ["virtual", "custom"])
	out["vjoy_layout"] = _choice(profile.get("vjoy_layout", ""), ["floating", "fixed"])
	out["sprint_sensitivity"] = _sensitivity(profile.get("sprint_sensitivity", null))
	out["sprint_lock_pos"] = _lock_pos(profile.get("sprint_lock_pos", null))
	f.store_string(JSON.stringify(out, "\t"))
	return true
