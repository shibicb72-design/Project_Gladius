class_name SpectatorCamera
extends Camera3D
## After the local player is eliminated: follows another living pawn from behind its shoulder.
## Presentation only. Offsets come from data/ui.json "spectate" (placeholders, OQ-BR-SPECTATE wording in S6).

var target: Pawn
var offset := Vector3(0.6, 2.0, 4.0)  # right, up, back (metres, in the target's frame)
var look_height_m: float = 1.4


func configure(cfg: Dictionary) -> void:
	var o: Array = cfg.get("offset_m", [offset.x, offset.y, offset.z])
	offset = Vector3(float(o[0]), float(o[1]), float(o[2]))
	look_height_m = float(cfg.get("look_height_m", look_height_m))


func follow(new_target: Pawn) -> void:
	target = new_target
	if target != null:
		_snap()
		make_current()


func _process(_delta: float) -> void:
	if target != null and is_instance_valid(target):
		_snap()


func _snap() -> void:
	var b := target.global_transform.basis
	var eye := target.global_position + b.x * offset.x + Vector3.UP * offset.y + b.z * offset.z
	var focus := target.global_position + Vector3.UP * look_height_m
	if eye.distance_to(focus) > 0.01:
		look_at_from_position(eye, focus, Vector3.UP)


## Who to watch after `local_id` is out: a living (ALIVE or DOWNED) squad mate first, then the killer if
## still in, then the lowest-id player still in. -1 when nobody is left. `squad_of` and `in_match` are
## callables (id -> int, id -> bool) so the choice is testable without a scene.
static func pick_target(local_id: int, killer_id: int, ids: Array, squad_of: Callable, in_match: Callable) -> int:
	var sorted := ids.duplicate()
	sorted.sort()
	var mine := int(squad_of.call(local_id))
	for id in sorted:
		if int(id) != local_id and int(squad_of.call(id)) == mine and bool(in_match.call(id)):
			return int(id)
	if killer_id >= 0 and killer_id != local_id and bool(in_match.call(killer_id)):
		return killer_id
	for id in sorted:
		if int(id) != local_id and bool(in_match.call(id)):
			return int(id)
	return -1
