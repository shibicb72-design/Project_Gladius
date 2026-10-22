class_name PawnRulesBridge
extends RefCounted
## Wraps HealthState + DamageRules for one pawn.

var state: HealthState
var squad_id: int = 0
var spawn_protected: bool = false
var combat_cfg: Dictionary = {}


func _init(class_def: ClassDef = null, squad: int = 0, cfg: Dictionary = {}) -> void:
	squad_id = squad
	combat_cfg = cfg
	if class_def != null:
		state = HealthState.create(class_def.shield, class_def.health)
	else:
		state = HealthState.create(1.0, 1.0)


func take_hit(weapon_def: WeaponDef, is_headshot: bool, attacker_squad: int) -> DamageRules.HitResult:
	return DamageRules.apply_hit(state, weapon_def, is_headshot, attacker_squad, squad_id,
			spawn_protected, combat_cfg)


func tick(delta: float) -> void:
	DamageRules.tick_regen(state, delta, combat_cfg)
