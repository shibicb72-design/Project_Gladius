class_name Loadout
extends RefCounted
## Primary, secondary and sidearm slots plus swap. The sidearm slot exists but is empty (OQ-09).

const SLOT_NAMES: Array[String] = ["primary", "secondary", "sidearm"]

var slots: Array[Weapon] = [null, null, null]
var active: int = 0


static func from_class(class_id: String, registry: DataRegistry) -> Loadout:
	var l := Loadout.new()
	var ids: Dictionary = registry.get_loadout_ids(class_id)
	for i in SLOT_NAMES.size():
		var wid := str(ids.get(SLOT_NAMES[i], ""))
		if wid == "":
			continue
		var wd := registry.get_weapon_def(wid)
		if wd != null:
			l.slots[i] = Weapon.new(wd)
	return l


func get_active() -> Weapon:
	return slots[active]


## Switches to the next filled slot; returns true if the active slot changed.
func swap() -> bool:
	for step in range(1, slots.size()):
		var i := (active + step) % slots.size()
		if slots[i] != null:
			var old := slots[active]
			if old != null:
				old.cancel_reload()
			active = i
			return true
	return false
