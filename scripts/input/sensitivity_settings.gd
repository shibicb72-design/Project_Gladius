class_name SensitivitySettings
extends RefCounted
## The player's sensitivity tables (Camera, ADS, Gyro, ADS Gyro, Free Look), preset, gyro mode and gyro
## inversion. Ranges, defaults and presets come from data/input.json "sensitivity_tables" (placeholders
## except the gyro max of 400); the values themselves live in the profile (SaveService, key "sensitivity").
## Values are percent: 100 = the base look rate in data/input.json (look / gyro blocks).

const TABLES: Array[String] = ["camera", "ads", "gyro", "ads_gyro"]
const FREE_LOOK := "free_look"
const CUSTOM := "custom"

var cfg: Dictionary = {}
var preset: String = ""
var gyro_mode: String = "off"
var gyro_invert_x: bool = false
var gyro_invert_y: bool = false
var values: Dictionary = {}  # table -> row -> percent (float)


func _init() -> void:
	cfg = DataRegistry.new().load_file("res://data/input.json")["sensitivity_tables"]
	reset()


## Data defaults: every row at its table's default, the default preset name, gyro off (OQ-34).
func reset() -> void:
	preset = str(cfg["default_preset"])
	gyro_mode = str(cfg["default_gyro_mode"]["value"])
	gyro_invert_x = false
	gyro_invert_y = false
	values = {}
	for t in all_tables():
		values[t] = {}
		for row in rows_of(t):
			values[t][row] = float(cfg["ranges"][t]["default"]["value"])


func all_tables() -> Array[String]:
	var out: Array[String] = TABLES.duplicate()
	out.append(FREE_LOOK)
	return out


func rows_of(table: String) -> Array:
	return cfg["free_look_rows"] if table == FREE_LOOK else cfg["scope_rows"]


func range_of(table: String) -> Dictionary:
	var r: Dictionary = cfg["ranges"][table]
	return {"min": float(r["min"]["value"]), "max": float(r["max"]["value"]),
			"step": float(r["step"]["value"]), "default": float(r["default"]["value"])}


## Snapped to the step and clamped to the table's range (gyro tables stop at 400).
func clamp_value(table: String, v: float) -> float:
	var r := range_of(table)
	return clampf(snappedf(v, r["step"]), r["min"], r["max"])


## Aim state (no_scope, red_dot, 2x, ...) to its table row; "" when the state is unknown.
func row_for_state(state: String) -> String:
	var states: Dictionary = cfg["states"]
	return str(states[state]) if state != "_note" and states.has(state) else ""


func percent(table: String, row: String) -> float:
	return float(values[table][row])


func multiplier(table: String, row: String) -> float:
	return percent(table, row) / 100.0


## A manual edit: the preset becomes Custom.
func set_value(table: String, row: String, v: float) -> void:
	values[table][row] = clamp_value(table, v)
	preset = CUSTOM


func preset_names() -> Array[String]:
	var out: Array[String] = []
	for k in cfg["presets"]:
		if not str(k).begins_with("_"):
			out.append(str(k))
	return out


## Sets every row of every table from the preset (one percent per table). Returns false for an unknown name.
func apply_preset(name: String) -> bool:
	if not preset_names().has(name):
		return false
	for t in all_tables():
		for row in rows_of(t):
			values[t][row] = clamp_value(t, float(cfg["presets"][name][t]))
	preset = name
	return true


func set_gyro_mode(mode: String) -> void:
	if cfg["gyro_modes"].has(mode):
		gyro_mode = mode


func to_dict() -> Dictionary:
	return {"preset": preset, "gyro_mode": gyro_mode, "gyro_invert_x": gyro_invert_x,
			"gyro_invert_y": gyro_invert_y, "values": values.duplicate(true)}


## Tolerant load: a missing or bad key keeps the data default. `legacy_gyro_enabled` is the old profile flag
## (true = always_on, false = off), used only when the dictionary has no valid gyro_mode.
static func from_dict(d: Variant, legacy_gyro_enabled: bool = false) -> SensitivitySettings:
	var s := SensitivitySettings.new()
	s.gyro_mode = "always_on" if legacy_gyro_enabled else "off"
	if not (d is Dictionary):
		return s
	var data: Dictionary = d
	if s.cfg["gyro_modes"].has(str(data.get("gyro_mode", ""))):
		s.gyro_mode = str(data["gyro_mode"])
	s.gyro_invert_x = bool(data.get("gyro_invert_x", false))
	s.gyro_invert_y = bool(data.get("gyro_invert_y", false))
	var saved: Variant = data.get("values", null)
	if saved is Dictionary:
		for t in s.all_tables():
			if not (saved.get(t, null) is Dictionary):
				continue
			for row in s.rows_of(t):
				var v: Variant = saved[t].get(row, null)
				if v is float or v is int:
					s.values[t][row] = s.clamp_value(t, float(v))
	var p := str(data.get("preset", ""))
	s.preset = p if p == CUSTOM or s.preset_names().has(p) else s.preset
	return s


static func from_profile(profile: Dictionary) -> SensitivitySettings:
	return from_dict(profile.get("sensitivity", null), bool(profile.get("gyro_enabled", false)))
