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
			"sensitivity": SensitivitySettings.new().to_dict(),  # G2d: tables, preset, gyro mode and inversion
				"move_stick": "", "vjoy_layout": "",  # "" = use data/input.json touch_layout (see docs/CONTROLS.md)
			"sprint_sensitivity": DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]["default"],
			"sprint_lock_pos": [],  # [] = data/input.json touch_layout.sprint_lock_pos; G2e's layout editor writes [x, y] (fractions)
				"hud_layouts": HudLayoutModel.new().to_dict(),  # G2e: 3 saved touch-HUD layouts + the active slot
				"haptics": HapticsService.default_settings(),  # G2f: master switch, category toggles, High/Low quality
				"left_fire_enabled": _left_fire_default()}  # G3e: optional left Fire button, default from data (false)


static func _left_fire_default() -> bool:
	return bool(DataRegistry.new().load_file("res://data/input.json")["touch_layout"]["left_fire"]["enabled_default"])


## A bool from a file or menu; anything else means the data default.
static func _left_fire(value: Variant) -> bool:
	return value if value is bool else _left_fire_default()


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


## Writes "sensitivity" (and the derived legacy "gyro_enabled") into `target` from `source`. An old profile
## with only gyro_enabled maps true to gyro mode always_on and false to off (G2d migration).
static func _set_sensitivity(target: Dictionary, source: Dictionary) -> void:
	var s := SensitivitySettings.from_profile(source)
	target["sensitivity"] = s.to_dict()
	target["gyro_enabled"] = s.gyro_mode != "off"


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
	_set_sensitivity(profile, data)
	profile["move_stick"] = _choice(data.get("move_stick", ""), ["virtual", "custom"])
	profile["vjoy_layout"] = _choice(data.get("vjoy_layout", ""), ["floating", "fixed"])
	profile["sprint_sensitivity"] = _sensitivity(data.get("sprint_sensitivity", null))
	profile["sprint_lock_pos"] = _lock_pos(data.get("sprint_lock_pos", null))
	profile["hud_layouts"] = HudLayoutModel.from_dict(data.get("hud_layouts", null)).to_dict()
	profile["haptics"] = HapticsService.sanitize(data.get("haptics", null))
	profile["left_fire_enabled"] = _left_fire(data.get("left_fire_enabled", null))
	return profile


func save_profile(profile: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var out := defaults()
	out["gamertag"] = str(profile.get("gamertag", DEFAULT_GAMERTAG))
	out["last_ip"] = str(profile.get("last_ip", ""))
	_set_sensitivity(out, profile)
	out["move_stick"] = _choice(profile.get("move_stick", ""), ["virtual", "custom"])
	out["vjoy_layout"] = _choice(profile.get("vjoy_layout", ""), ["floating", "fixed"])
	out["sprint_sensitivity"] = _sensitivity(profile.get("sprint_sensitivity", null))
	out["sprint_lock_pos"] = _lock_pos(profile.get("sprint_lock_pos", null))
	out["hud_layouts"] = HudLayoutModel.from_dict(profile.get("hud_layouts", null)).to_dict()
	out["haptics"] = HapticsService.sanitize(profile.get("haptics", null))
	out["left_fire_enabled"] = _left_fire(profile.get("left_fire_enabled", null))
	f.store_string(JSON.stringify(out, "\t"))
	return true
