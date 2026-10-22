class_name BotSpawner
extends RefCounted
## Fills empty squad slots with bot pawns up to data/bots.json match_fill. Host-only.

const BOTS_PATH := "res://data/bots.json"
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _BrainScript := preload("res://scripts/systems/bot_brain.gd")


## humans_per_squad: squad id -> human count. Returns [{squad, class_id}] for each bot to add.
## Classes rotate through class_rotation across the whole fill.
static func plan_fill(humans_per_squad: Dictionary, cfg: Dictionary) -> Array:
	var fill: Dictionary = cfg.get("match_fill", {})
	var rotation: Array = cfg.get("class_rotation", ["hastati"])
	var plan: Array = []
	var squads := int(DataRegistry.new().load_file("res://data/match.json").get("squads", 0))
	for squad in squads:
		var missing := int(fill.get("squad_size", 0)) - int(humans_per_squad.get(squad, 0))
		for i in maxi(missing, 0):
			plan.append({"squad": squad, "class_id": str(rotation[plan.size() % rotation.size()])})
	return plan


## Gives `pawn` a BotBrain configured from data/bots.json (match_fill profile).
static func attach_brain(pawn: Pawn, director: MatchDirector, hill_center: Vector3, hill_radius: float) -> void:
	var cfg := DataRegistry.new().load_file(BOTS_PATH)
	var profile: Dictionary = cfg.get("profiles", {}).get(cfg.get("match_fill", {}).get("profile", "tiro"), {})
	var brain: Node = _BrainScript.new()
	brain.name = "Brain"
	brain.setup(pawn, director, profile, cfg.get("brain", {}), hill_center, hill_radius)
	pawn.add_child(brain)


## Adds bot pawns (and brains) under `parent`, registers them with the director.
## Player ids start at first_id. Returns the pawns.
static func spawn_bots(parent: Node, director: MatchDirector, humans_per_squad: Dictionary,
		hill_center: Vector3, hill_radius: float, first_id: int = 100) -> Array[Pawn]:
	var cfg := DataRegistry.new().load_file(BOTS_PATH)
	var profile: Dictionary = cfg.get("profiles", {}).get(cfg.get("match_fill", {}).get("profile", "tiro"), {})
	var pawns: Array[Pawn] = []
	for entry in plan_fill(humans_per_squad, cfg):
		var pawn: Pawn = _PawnScene.instantiate()
		pawn.class_id = entry["class_id"]
		pawn.squad_id = entry["squad"]
		pawn.name = "Bot%d" % (first_id + pawns.size())
		parent.add_child(pawn)
		var brain: Node = _BrainScript.new()
		brain.name = "Brain"
		brain.setup(pawn, director, profile, cfg.get("brain", {}), hill_center, hill_radius)
		pawn.add_child(brain)
		director.add_player(first_id + pawns.size(), pawn)
		pawns.append(pawn)
	return pawns
