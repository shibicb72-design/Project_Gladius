class_name WeaponDef
extends RefCounted
## Typed wrapper around one entry of data/stats.json "weapons".

var id: String = ""
var display_name: String = ""
var kind: String = "hitscan"
var tier: String = "standard"
var damage: float = 0.0
var headshot_multiplier: float = 1.0
var fire_interval_s: float = 0.5
var burst_count: int = 1
var burst_interval_s: float = 0.05
var magazine: int = 0
var reserve_ammo: int = 0
var reload_s: float = 1.0
var range_m: float = 50.0
var spread_deg: float = 0.0
var is_placeholder: bool = false
## Melee only (kind "melee"): swing reach, full arc in degrees and the visual swing time.
var melee_range_m: float = 0.0
var melee_arc_deg: float = 0.0
var swing_duration_s: float = 0.2


func is_melee() -> bool:
	return kind == "melee"


static func from_dict(weapon_id: String, d: Dictionary) -> WeaponDef:
	var w := WeaponDef.new()
	w.id = weapon_id
	w.display_name = str(d.get("display_name", weapon_id))
	w.kind = str(d.get("kind", "hitscan"))
	w.tier = str(d.get("tier", "standard"))
	w.damage = float(d.get("damage", 0))
	w.headshot_multiplier = float(d.get("headshot_multiplier", 1.0))
	w.fire_interval_s = float(d.get("fire_interval_s", 0.5))
	w.burst_count = int(d.get("burst_count", 1))
	w.burst_interval_s = float(d.get("burst_interval_s", 0.05))
	w.magazine = int(d.get("magazine", 0))
	w.reserve_ammo = int(d.get("reserve_ammo", 0))
	w.reload_s = float(d.get("reload_s", 1.0))
	w.range_m = float(d.get("range_m", 50))
	w.spread_deg = float(d.get("spread_deg", 0))
	w.is_placeholder = bool(d.get("_placeholder", false))
	w.melee_range_m = float(d.get("melee_range_m", 0))
	w.melee_arc_deg = float(d.get("melee_arc_deg", 0))
	w.swing_duration_s = float(d.get("swing_duration_s", 0.2))
	return w
