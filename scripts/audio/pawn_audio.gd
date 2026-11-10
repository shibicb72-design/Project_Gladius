class_name PawnAudio
extends Node3D
## S5: one pawn's sounds. A child of the pawn scene that only listens to the pawn's own signals and reads its
## public state; it never writes to the pawn. Which sound answers what: data/audio.json "hooks" and
## "footsteps" (placeholders, OQ-AUDIO-MIX). The footstep surface comes from the visual side: the ground's
## paint map under the feet, or the kind of piece stood on.

var pawn: Pawn
var hooks: Dictionary = {}
var steps: Dictionary = {}
var _stride_left := 0.0
var _last_at := Vector3.ZERO
var _was_downed := false
var _fall_loop: AudioStreamPlayer
var _revive_loop: AudioStreamPlayer3D
var _step_index := 0
var last_surface := ""


func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _ready() -> void:
	pawn = get_parent() as Pawn
	var sfx := _sfx()
	if pawn == null or sfx == null:
		set_physics_process(false)
		return
	hooks = sfx.cfg["hooks"]
	steps = sfx.cfg["footsteps"]
	_stride_left = float(steps["stride_m"])
	_last_at = pawn.global_position
	pawn.shot.connect(_on_shot)
	pawn.shot_resolved.connect(_on_shot_resolved)
	pawn.damaged.connect(_on_damaged)
	pawn.melee_landed.connect(_on_melee_landed)
	pawn.reload_started.connect(_on_reload_started)
	pawn.weapon_switched.connect(_on_weapon_switched)
	pawn.fire_empty.connect(_on_fire_empty)
	pawn.landed.connect(_on_landed)
	_bind_shot_fx.call_deferred()


## Shots replicated from other peers never emit the pawn's own signals; the shot visual does, so listen there
## too (ShotFx.shot_shown fires for local and replicated shots alike).
func _bind_shot_fx() -> void:
	if pawn != null and pawn.shot_fx != null and not pawn.shot_fx.shot_shown.is_connected(_on_shot_shown):
		pawn.shot_fx.shot_shown.connect(_on_shot_shown)


func _is_listener() -> bool:
	return pawn.get_node_or_null("CameraRig") != null


func _play(hook: String, at: Vector3, offset_db: float = 0.0) -> void:
	var sfx := _sfx()
	if sfx != null and hooks.has(hook):
		sfx.play_at(String(hooks[hook]), at, offset_db)


func _on_shot(_origin: Vector3, _direction: Vector3, weapon_id: String) -> void:
	# The ranged report is played from the shot visual (see _bind_shot_fx); a swing has no visual signal.
	var weapon := pawn.loadout.get_active() if pawn.loadout != null else null
	if weapon != null and weapon.def.id == weapon_id and weapon.def.is_melee():
		_play("melee_swing", pawn.global_position + Vector3.UP * 1.2)


func _on_shot_shown(origin: Vector3, end: Vector3) -> void:
	var sfx := _sfx()
	if sfx == null:
		return
	var weapon := pawn.loadout.get_active() if pawn.loadout != null else null
	var weapon_id := weapon.def.id if weapon != null else ""
	var id := String((hooks["shot_by_weapon"] as Dictionary).get(weapon_id, hooks["shot_default"]))
	var listener: Vector3 = sfx._listener_position()
	if origin.distance_to(listener) > float(hooks["shot_far_from_m"]):
		id = String(hooks["shot_far"])
	sfx.play_at(id, origin)
	# A round that passes close to the listener without being its own.
	if not _is_listener():
		var nearest := Geometry3D.get_closest_point_to_segment(listener, origin, end)
		if nearest.distance_to(listener) < float(hooks["near_miss_within_m"]) and nearest.distance_to(origin) > 4.0:
			sfx.play_at(String(hooks["near_miss"]), nearest)


func _on_shot_resolved(_origin: Vector3, end: Vector3, hit: Dictionary) -> void:
	var sfx := _sfx()
	if sfx == null:
		return
	var target: Variant = hit.get("target")
	if target == null:
		if not hit.is_empty():
			_play("impact_world", end)
		return
	if _is_listener():
		sfx.play_ui(String(hooks["local_headshot"] if bool(hit.get("is_headshot", false)) else hooks["local_hit"]))


func _on_damaged(result: DamageRules.HitResult) -> void:
	var at := pawn.global_position + Vector3.UP * 1.2
	if result.shield_broken:
		_play("shield_broken", at)
	elif result.shield_damage > 0.0:
		_play("damaged_shield", at)
	else:
		_play("damaged_health", at)


func _on_melee_landed() -> void:
	_play("melee_landed", pawn.global_position + Vector3.UP * 1.2 - pawn.global_transform.basis.z)


func _on_reload_started() -> void:
	_play("reload_started", pawn.global_position + Vector3.UP * 1.2)


func _on_weapon_switched(_slot: int) -> void:
	_play("weapon_switched", pawn.global_position + Vector3.UP * 1.2)


func _on_fire_empty() -> void:
	_play("fire_empty", pawn.global_position + Vector3.UP * 1.2)


func _on_landed() -> void:
	_play("landed", pawn.global_position)
	_stride_left = float(steps["stride_m"])


## What the visual side shows under the pawn's feet: "earth", "grass", "paving", "stone" or "wood".
func surface_under() -> String:
	var floor_body: Object = null
	for i in pawn.get_slide_collision_count():
		var hit := pawn.get_slide_collision(i)
		if hit.get_normal().y > 0.6:
			floor_body = hit.get_collider()
			break
	if floor_body is Node:
		var node := floor_body as Node
		if node.is_in_group(&"structure"):
			var by_piece: Dictionary = steps["piece_surface"]
			return String(by_piece.get(String(node.get_meta(&"structure_type", "")), by_piece["default"]))
		if node.name != &"Ground":
			return String(steps["cover_surface"])
	var builder := get_tree().get_first_node_in_group(&"ground_paint") if is_inside_tree() else null
	if builder != null and builder.get("ground_paint") != null:
		return GroundPaint.surface_at(builder.ground_paint, float(builder.ground_size_m), pawn.global_position)
	return "earth"


func _physics_process(_delta: float) -> void:
	var sfx := _sfx()
	if sfx == null or pawn == null:
		return
	var at := pawn.global_position
	var moved := Vector3(at.x - _last_at.x, 0.0, at.z - _last_at.z).length()
	_last_at = at
	# Footsteps: ground covered on foot, alive, not in the air and not teleported.
	if pawn.is_alive() and pawn.drop_state == Pawn.Drop.NONE and pawn.is_on_floor() and moved < 2.0 \
			and pawn.velocity.length() >= float(steps["min_speed_mps"]):
		_stride_left -= moved
		if _stride_left <= 0.0:
			_stride_left += float(steps["stride_m"])
			last_surface = surface_under()
			var list: Array = (steps["surfaces"] as Dictionary).get(last_surface, [])
			if not list.is_empty():
				_step_index = (_step_index + 1 + (randi() % maxi(list.size() - 1, 1))) % list.size()
				sfx.play_at(String(list[_step_index]), at, 0.0 if _is_listener() else float(steps["others_volume_db"]))
	# Downed: read-only state, no signal on the pawn for it.
	var downed := pawn.is_downed()
	if downed and not _was_downed:
		_play("downed", at + Vector3.UP * 0.5)
	_was_downed = downed
	# The listener's own fall from the carrier: wind in the ears (non-positional, local pawn only).
	var falling := pawn.drop_state == Pawn.Drop.FALLING and _is_listener()
	if falling and _fall_loop == null:
		_fall_loop = sfx.make_loop(String(hooks["falling_loop"]), self, false) as AudioStreamPlayer
	elif not falling and _fall_loop != null:
		_fall_loop.queue_free()
		_fall_loop = null
