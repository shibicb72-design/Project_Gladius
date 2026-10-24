class_name HealthState
extends RefCounted
## Shield + health of one combatant. Pure data; rules live in DamageRules.

var max_shield: float = 0.0
var max_health: float = 0.0
var shield: float = 0.0
var health: float = 0.0
## Seconds since the last damage was taken; drives shield regen.
var time_since_damage: float = 0.0


static func create(max_shield_value: float, max_health_value: float) -> HealthState:
	var s := HealthState.new()
	s.max_shield = max_shield_value
	s.max_health = max_health_value
	s.shield = max_shield_value
	s.health = max_health_value
	return s


func is_dead() -> bool:
	return health <= 0.0
