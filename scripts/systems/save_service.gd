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
				"hud_layouts": HudLayoutModel.new().to_dict(),  # G2e: 3 saved touch-HUD layouts + the active slot (+ M2 H1a version)
				"layout_notice_pending": false,  # M2 H1a: true once a layout migration reset an edited layout; the touch HUD clears it
				"haptics": HapticsService.default_settings(),  # G2f: master switch, category toggles, High/Low quality
				"left_fire_enabled": _left_fire_default(),  # G3e: optional left Fire button, default from data (false)
				"shooting_mode": shooting_mode_default(),  # M2 H1a: "advanced" | "simple", default from data (OQ-SHOOT-MODE)
				"match_length": match_length_default(),  # M2 Z2: a br.json match_length option id, default from data (OQ-BR-LENGTH)
				"minimap_rotate": true}  # M2 H1b: the small minimap turns with the heading (true) or stays north up (OQ-MINIMAP)


## M2 Z2: the br config the lobby sees (data/br.json through modes.json, no map overrides).
static func _br_cfg() -> Dictionary:
	return ModeRegistry.merged_config(MatchDirector.MODE_ID, DataRegistry.new().load_file("res://data/modes.json"))


## M2 Z2: data/br.json match_length.default (OQ-BR-LENGTH placeholder, "15").
static func match_length_default() -> String:
	return MatchDirector.match_length_default_id(_br_cfg())


## M2 Z2: a match length id from a file or menu; only br.json match_length option ids are kept, anything else
## (missing, unknown, not a string) means the data default.
static func match_length(value: Variant) -> String:
	var cfg := _br_cfg()
	return MatchDirector.validated_match_length_id(cfg, str(value) if value is String else "")


## M2 H1a: data/input.json shooting.default_mode (OQ-SHOOT-MODE placeholder, "advanced").
static func shooting_mode_default() -> String:
	return str(DataRegistry.new().load_file("res://data/input.json")["shooting"]["default_mode"])


## M2 H1a: a shooting mode from a file or menu; only data/input.json shooting.modes are kept, anything else (missing,
## unknown, not a string) means the data default.
static func shooting_mode(value: Variant) -> String:
	var modes: Array = DataRegistry.new().load_file("res://data/input.json")["shooting"]["modes"]
	return str(value) if value is String and modes.has(value) else shooting_mode_default()


## M2 H1b (OQ-MINIMAP): the minimap's turn setting from a file or menu: a bool is kept, anything else (missing, not a
## bool) means the default, true (the small minimap turns with the player's heading).
static func minimap_rotate(value: Variant) -> bool:
	return value if value is bool else true


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
	var layouts := HudLayoutModel.from_dict(data.get("hud_layouts", null))
	profile["hud_layouts"] = layouts.to_dict()
	profile["layout_notice_pending"] = data.get("layout_notice_pending", false) == true
	profile["haptics"] = HapticsService.sanitize(data.get("haptics", null))
	profile["left_fire_enabled"] = _left_fire(data.get("left_fire_enabled", null))
	profile["shooting_mode"] = shooting_mode(data.get("shooting_mode", null))
	profile["match_length"] = match_length(data.get("match_length", null))
	profile["minimap_rotate"] = minimap_rotate(data.get("minimap_rotate", null))  # M2 H1b
	# M2 H1a layout migration (OQ-H1A-LAYOUT): saved layouts without the current layout version (or a pre-G2e file with
	# only the legacy sprint_lock_pos) were made for the old placement. They are reset to the new defaults once, the
	# legacy sprint_lock_pos with them, the touch HUD shows a one-time notice when something was discarded, and the
	# result is written back at once so the next load sees the new format and never resets again.
	var legacy_lock: bool = not data.has("hud_layouts") and not profile["sprint_lock_pos"].is_empty()
	if layouts.migrated or legacy_lock:
		if layouts.discarded or not profile["sprint_lock_pos"].is_empty():
			profile["layout_notice_pending"] = true
		profile["sprint_lock_pos"] = []
		save_profile(profile)
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
	out["layout_notice_pending"] = profile.get("layout_notice_pending", false) == true
	out["haptics"] = HapticsService.sanitize(profile.get("haptics", null))
	out["left_fire_enabled"] = _left_fire(profile.get("left_fire_enabled", null))
	out["shooting_mode"] = shooting_mode(profile.get("shooting_mode", null))
	out["match_length"] = match_length(profile.get("match_length", null))
	out["minimap_rotate"] = minimap_rotate(profile.get("minimap_rotate", null))  # M2 H1b
	f.store_string(JSON.stringify(out, "\t"))
	return true
