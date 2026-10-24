class_name ModeRegistry
extends RefCounted
## Maps a mode's `rules` id (data/modes.json) to its rules script.

const _RULES := {
	"koth": preload("res://scripts/systems/koth_rules.gd"),
}


static func has_rules(rules_id: String) -> bool:
	return _RULES.has(rules_id)


## Returns a configured rules instance for a mode id such as "koth", or null.
static func create(mode_id: String, modes: Dictionary) -> GameModeRules:
	var entry: Dictionary = modes.get(mode_id, {})
	var script: GDScript = _RULES.get(str(entry.get("rules", "")))
	if script == null:
		return null
	var rules: GameModeRules = script.new()
	rules.setup(entry)
	return rules
