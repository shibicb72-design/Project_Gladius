class_name BotSpawner
extends RefCounted
## Fills empty squad slots with bot pawns up to match.json max_players. Host-only.

const BOTS_PATH := "res://data/bots.json"
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _BrainScript := preload("res://scripts/systems/bot_brain.gd")


## humans_per_squad: squad id -> human count. squad_size: slots per squad (solo 1, squads squad_size_max).
## Returns [{squad, class_id}] for each bot to add. Classes rotate through class_rotation across the whole fill.
static func plan_fill(humans_per_squad: Dictionary, cfg: Dictionary, squad_count: int, squad_size: int) -> Array:
	var rotation: Array = cfg.get("class_rotation", ["hastati"])
	var plan: Array = []
	for squad in squad_count:
		var missing := squad_size - int(humans_per_squad.get(squad, 0))
		for i in maxi(missing, 0):
			plan.append({"squad": squad, "class_id": str(rotation[plan.size() % rotation.size()])})
	return plan


## Gives `pawn` a BotBrain configured from data/bots.json (match_fill profile).
static func attach_brain(pawn: Pawn, director: MatchDirector) -> void:
	var cfg := DataRegistry.new().load_file(BOTS_PATH)
	var profile: Dictionary = cfg.get("profiles", {}).get(cfg.get("match_fill", {}).get("profile", "tiro"), {})
	var brain: Node = _BrainScript.new()
	brain.name = "Brain"
	brain.setup(pawn, director, profile, cfg.get("brain", {}))
	pawn.add_child(brain)


## Adds bot pawns (and brains) under `parent`, registers them with the director. The director's mode
## config sets the layout (18 players: solo 18 squads of 1, squads 6 of 3). Player ids start at first_id
## (or above the highest id already registered). Returns the pawns.
static func spawn_bots(parent: Node, director: MatchDirector, humans_per_squad: Dictionary,
		first_id: int = 100, with_brains: bool = true) -> Array[Pawn]:
	var cfg := DataRegistry.new().load_file(BOTS_PATH)
	var layout := MatchDirector.team_layout(director.mode_cfg, director.match_cfg)
	var pawns: Array[Pawn] = []
	for entry in plan_fill(humans_per_squad, cfg, int(layout["squad_count"]), int(layout["squad_size"])):
		var pawn: Pawn = _PawnScene.instantiate()
		pawn.class_id = entry["class_id"]
		pawn.squad_id = entry["squad"]
		pawn.name = "Bot%d" % (first_id + pawns.size())
		parent.add_child(pawn)
		if with_brains:
			attach_brain(pawn, director)
		director.add_player(first_id + pawns.size(), pawn)
		pawns.append(pawn)
	return pawns
