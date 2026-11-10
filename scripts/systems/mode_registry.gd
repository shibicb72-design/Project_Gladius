class_name ModeRegistry
extends RefCounted
## Maps a mode's `rules` id (data/modes.json) to its rules script.

const _RULES := {
	"br": preload("res://scripts/systems/br_rules.gd"),
}


static func has_rules(rules_id: String) -> bool:
	return _RULES.has(rules_id)


## The mode's modes.json entry with its "data" file (e.g. br.json) merged in; {} if unusable.
static func merged_config(mode_id: String, modes: Dictionary) -> Dictionary:
	var entry: Dictionary = modes.get(mode_id, {})
	if entry.is_empty():
		return {}
	var cfg: Dictionary = entry.duplicate(true)
	cfg.erase("data")  # merged: re-merging an already merged entry must not overwrite edits
	if entry.has("data"):
		var path := str(entry["data"])
		if not FileAccess.file_exists(path):
			return {}
		var loaded: Dictionary = DataRegistry.new().load_file(path)
		if loaded.is_empty():
			return {}
		for key in loaded:
			cfg[key] = (loaded[key].duplicate(true) if loaded[key] is Array or loaded[key] is Dictionary else loaded[key])
	return cfg


## Returns a configured rules instance for a mode id such as "br", or null.
## An entry that already holds merged data (no "data" key) is used as is.
static func create(mode_id: String, modes: Dictionary) -> GameModeRules:
	var entry: Dictionary = modes.get(mode_id, {})
	var script: GDScript = _RULES.get(str(entry.get("rules", "")))
	if script == null:
		return null
	var cfg := merged_config(mode_id, modes)
	if cfg.is_empty():
		return null
	var rules: GameModeRules = script.new()
	rules.setup(cfg)
	return rules
