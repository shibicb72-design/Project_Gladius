class_name SoldierHitSide
extends RefCounted
## A3 item 3: which side a soldier's flinch comes from (front, back, left, right), visuals only. One small central
## relay shared by every SoldierModel on this peer: each model records the shots its own pawn shows and the melee
## swings its own pawn simulates; a victim's model takes the matching event when it sees its shield + health drop.
## Tunables: data/anim_third_person.json gait.hit_dir (OQ-A3-HITDIR placeholders).
##
## Rifle: ShotFx.shot_shown(origin, end) fires on the SHOOTER's ShotFx on every peer (local shots, host-validated
## remote shots, replicas through MatchRoot._on_remote_shot), so recording it on the shooter's side reaches every
## victim. The victim is matched by `end` within match_m of its body axis, within window_s. On a replica the damage
## usually arrives in a later snapshot: the event waits for the drop. A drop seen BEFORE its event arrives takes what
## is there (no event: front); a later event is not applied to a flinch already shown.
## Melee: Pawn.shot fires only for pawns this peer simulates (the local player, bots on the host); the side comes
## from the attacker's origin. LAN limit (accepted): a remote human's melee seen on the host and every melee hit on a
## replica (melee is never announced to replicas) has no event and plays the front flinch.

const SIDES: Array[String] = ["front", "back", "left", "right"]
const MAX_EVENTS := 64

## {origin: Vector3, end: Vector3, melee: bool, shooter: int (instance id), ms: int}
static var _events: Array[Dictionary] = []


static func cfg() -> Dictionary:
	return SoldierRig.config()["gait"].get("hit_dir", {})


## Tests: forget every recorded event.
static func clear() -> void:
	_events.clear()


static func record_shot(shooter: Node3D, origin: Vector3, end: Vector3) -> void:
	_push({"origin": origin, "end": end, "melee": false, "shooter": shooter.get_instance_id() if shooter != null else 0})


static func record_melee(attacker: Node3D, origin: Vector3) -> void:
	_push({"origin": origin, "end": origin, "melee": true, "shooter": attacker.get_instance_id() if attacker != null else 0})


static func _push(event: Dictionary) -> void:
	event["ms"] = Time.get_ticks_msec()
	_prune()
	_events.append(event)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()


static func _prune() -> void:
	var window_ms := int(float(cfg().get("window_s", 0.5)) * 1000.0)
	var now := Time.get_ticks_msec()
	while not _events.is_empty() and now - int(_events[0]["ms"]) > window_ms:
		_events.pop_front()


## The side of the newest event that matches `victim` (consumed), or "front" when none does.
static func take(victim: Pawn) -> String:
	_prune()
	var c := cfg()
	var head := victim.get_node_or_null("Head") as Node3D
	var feet := victim.global_position
	var top := head.global_position if head != null else feet + Vector3.UP * 1.75
	for i in range(_events.size() - 1, -1, -1):
		var ev: Dictionary = _events[i]
		if int(ev["shooter"]) == victim.get_instance_id():
			continue
		var origin: Vector3 = ev["origin"]
		var near: bool
		if bool(ev["melee"]):
			near = Vector2(origin.x - feet.x, origin.z - feet.z).length() <= float(c.get("melee_match_m", 3.0))
		else:
			near = _to_segment(ev["end"], feet, top) <= float(c.get("match_m", 1.0))
		if near:
			_events.remove_at(i)
			return side_of(victim, origin)
	return "front"


## Where `from` lies around the victim, in its own frame (forward -Z, left -X): quadrants.
static func side_of(victim: Node3D, from: Vector3) -> String:
	var local := victim.global_transform.basis.inverse() * (from - victim.global_position)
	if Vector2(local.x, local.z).length_squared() < 0.000001:
		return "front"
	if absf(local.z) >= absf(local.x):
		return "front" if local.z < 0.0 else "back"
	return "left" if local.x < 0.0 else "right"


static func _to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
	return p.distance_to(a + ab * t)
