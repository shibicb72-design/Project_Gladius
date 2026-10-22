class_name BotCommands
extends RefCounted
## Stub. No squad commands in milestone 1 (OQ-33); bots always play the hill.
## Data hook: data/bots.json "commands.enabled" lists enabled commands (empty for now).

enum Command { NONE, FOLLOW, ATTACK, HOLD, RUSH_HILL }

static func enabled_from(cfg: Dictionary) -> Array:
	return cfg.get("commands", {}).get("enabled", [])
