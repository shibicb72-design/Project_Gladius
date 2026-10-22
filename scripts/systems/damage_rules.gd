class_name DamageRules
extends RefCounted
## Pure Halo-style damage rules: shield first, then health. No scene dependencies.

const _HealthStateScript := preload("res://scripts/systems/health_state.gd")
const _WeaponDefScript := preload("res://scripts/weapons/weapon_def.gd")


class HitResult extends RefCounted:
	var damage_dealt: float = 0.0
	var shield_damage: float = 0.0
	var health_damage: float = 0.0
	var shield_broken: bool = false
	var killed: bool = false
	## "", "friendly", "protected" or "dead" when no damage was applied.
	var blocked_reason: String = ""


## combat_cfg: data/stats.json "combat" (overflow_to_health). Placeholder semantics, see OQ-13/OQ-14.
static func apply_hit(target_state: HealthState, weapon_def: WeaponDef, is_headshot: bool,
		attacker_squad: int, target_squad: int, target_protected: bool,
		combat_cfg: Dictionary = {}) -> HitResult:
	var r := HitResult.new()
	if target_state.is_dead():
		r.blocked_reason = "dead"
		return r
	if attacker_squad == target_squad:
		r.blocked_reason = "friendly"
		return r
	if target_protected:
		r.blocked_reason = "protected"
		return r

	var dmg: float = weapon_def.damage
	if is_headshot:
		dmg *= weapon_def.headshot_multiplier
	r.damage_dealt = dmg
	target_state.time_since_damage = 0.0

	var had_shield: bool = target_state.shield > 0.0
	var to_shield: float = minf(dmg, target_state.shield)
	target_state.shield -= to_shield
	r.shield_damage = to_shield
	var overflow: float = dmg - to_shield
	r.shield_broken = had_shield and target_state.shield <= 0.0
	if overflow > 0.0 and (not r.shield_broken or bool(combat_cfg.get("overflow_to_health", true))):
		var to_health: float = minf(overflow, target_state.health)
		target_state.health -= to_health
		r.health_damage = to_health
	r.killed = target_state.health <= 0.0
	return r


## Advances the regen timer; shield (not health) refills after the delay.
static func tick_regen(state: HealthState, delta: float, combat_cfg: Dictionary) -> void:
	if state.is_dead():
		return
	var delay: float = float(combat_cfg.get("shield_regen_delay_s", 5.0))
	var rate: float = float(combat_cfg.get("shield_regen_rate_per_s", 25.0))
	var before: float = state.time_since_damage
	state.time_since_damage += delta
	if state.shield >= state.max_shield:
		return
	var regen_time: float = state.time_since_damage - maxf(before, delay)
	if regen_time > 0.0:
		state.shield = minf(state.max_shield, state.shield + regen_time * rate)
