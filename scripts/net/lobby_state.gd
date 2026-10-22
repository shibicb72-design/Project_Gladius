class_name LobbyState
extends RefCounted
## Pure pre-match lobby: humans and bots, auto squad assignment (humans first, bots fill; OQ-28).

var squad_count: int = 2
var squad_size: int = 3
var default_class: String = "hastati"
var class_rotation: Array = ["hastati", "sagittarii"]
var started: bool = false
## Humans in join order: {peer_id, name, class_id}.
var humans: Array = []
## Result of assign(): {player_id, peer_id, name, class_id, squad_id, slot, is_bot}.
var slots: Array = []


func setup(squads: int, size: int, rotation: Array = [], human_default_class: String = "hastati") -> void:
	squad_count = squads
	squad_size = size
	default_class = human_default_class
	if not rotation.is_empty():
		class_rotation = rotation.duplicate()


func add_human(peer_id: int, player_name: String) -> bool:
	if started or find_human(peer_id) >= 0 or humans.size() >= squad_count * squad_size:
		return false
	humans.append({"peer_id": peer_id, "name": player_name, "class_id": default_class})
	return true


func remove_human(peer_id: int) -> void:
	var i := find_human(peer_id)
	if i >= 0 and not started:
		humans.remove_at(i)


func set_class(peer_id: int, class_id: String) -> bool:
	var i := find_human(peer_id)
	if i < 0 or started:
		return false
	humans[i]["class_id"] = class_id
	return true


func find_human(peer_id: int) -> int:
	for i in humans.size():
		if int(humans[i]["peer_id"]) == peer_id:
			return i
	return -1


## Humans take the first slots in squad order, bots fill the rest. Player ids are slot indices.
func assign() -> Array:
	slots = []
	var total := squad_count * squad_size
	var bot_n := 0
	for i in total:
		var s := {"player_id": i, "peer_id": 0, "name": "", "class_id": "", "squad_id": floori(float(i) / float(squad_size)),
				"slot": i % squad_size, "is_bot": true}
		if i < humans.size():
			var h: Dictionary = humans[i]
			s["peer_id"] = int(h["peer_id"])
			s["name"] = str(h["name"])
			s["class_id"] = str(h["class_id"])
			s["is_bot"] = false
		else:
			s["name"] = "Bot %d" % (bot_n + 1)
			s["class_id"] = str(class_rotation[bot_n % class_rotation.size()])
			bot_n += 1
		slots.append(s)
	return slots


func start() -> bool:
	if humans.is_empty() or started:
		return false
	assign()
	started = true
	return true


func to_dict() -> Dictionary:
	return {"squad_count": squad_count, "squad_size": squad_size, "default_class": default_class,
			"class_rotation": class_rotation.duplicate(), "started": started,
			"humans": humans.duplicate(true), "slots": slots.duplicate(true)}


static func from_dict(d: Dictionary) -> LobbyState:
	var l := LobbyState.new()
	l.squad_count = int(d.get("squad_count", 2))
	l.squad_size = int(d.get("squad_size", 3))
	l.default_class = str(d.get("default_class", "hastati"))
	l.class_rotation = Array(d.get("class_rotation", [])).duplicate()
	l.started = bool(d.get("started", false))
	for h in d.get("humans", []):
		l.humans.append({"peer_id": int(h["peer_id"]), "name": str(h["name"]), "class_id": str(h["class_id"])})
	for s in d.get("slots", []):
		l.slots.append({"player_id": int(s["player_id"]), "peer_id": int(s["peer_id"]), "name": str(s["name"]),
				"class_id": str(s["class_id"]), "squad_id": int(s["squad_id"]), "slot": int(s["slot"]),
				"is_bot": bool(s["is_bot"])})
	return l
