class_name ClassDef
extends RefCounted
## Typed wrapper around one entry of data/stats.json "classes".

var id: String = ""
var display_name: String = ""
var shield: float = 0.0
var health: float = 0.0
var speed_pct: float = 100.0
var enabled: bool = false


static func from_dict(class_id: String, d: Dictionary) -> ClassDef:
	var c := ClassDef.new()
	c.id = class_id
	c.display_name = str(d.get("display_name", class_id))
	c.shield = float(d.get("shield", 0))
	c.health = float(d.get("health", 0))
	c.speed_pct = float(d.get("speed_pct", 100))
	c.enabled = bool(d.get("enabled", false))
	return c
