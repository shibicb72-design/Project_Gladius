class_name HapticsEvents
extends RefCounted
## Maps the local pawn's gameplay signals to haptic events. Only the local player's pawn is bound, and every
## call goes through Haptics.play (never Input). Sound-cue events are not wired: the project has no audio or
## sound-visualisation events yet (OQ-HAPTICS-SOUND-CUES).


static func bind_pawn(pawn: Pawn) -> void:
	pawn.shot_resolved.connect(func(_o: Vector3, _e: Vector3, _h: Dictionary) -> void: Haptics.play("weapon_fire"))
	pawn.reload_started.connect(func() -> void: Haptics.play("weapon_reload"))
	pawn.melee_landed.connect(func() -> void: Haptics.play("melee_hit"))
	pawn.damaged.connect(func(r: DamageRules.HitResult) -> void: Haptics.play(status_event(r)))


## Which single status event a damaging hit plays (placeholder precedence, OQ-HAPTICS-VALUES): death, else
## shield break, else plain damage.
static func status_event(result: DamageRules.HitResult) -> String:
	if result.killed:
		return "death"
	if result.shield_broken:
		return "shield_break"
	return "damage_taken"
