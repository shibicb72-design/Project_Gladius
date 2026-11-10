class_name BotCommands
extends RefCounted
## Stub. No squad commands in milestone 1 (OQ-33); bots follow the zone (battle royale; commands are undecided, see DESIGN.md).
## Data hook: data/bots.json "commands.enabled" lists enabled commands (empty for now).

enum Command { NONE, FOLLOW, ATTACK, HOLD }

static func enabled_from(cfg: Dictionary) -> Array:
	return cfg.get("commands", {}).get("enabled", [])
