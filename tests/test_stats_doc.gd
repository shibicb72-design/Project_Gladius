extends "res://tests/test_case.gd"
## Derives Pilum BR bullets-to-kill (vs Hastati) from data/stats.json so docs/STATS.md cannot drift.

const STATS_DOC := "res://docs/STATS.md"


func _derive() -> Dictionary:
	var reg := DataRegistry.new()
	var pilum := reg.get_weapon_def("pilum_br")
	var c := reg.get_class_def("hastati")
	var total: float = c.shield + c.health
	var body := int(ceili(total / pilum.damage))
	var head := int(ceili(total / (pilum.damage * pilum.headshot_multiplier)))
	var bursts := int(ceili(float(body) / pilum.burst_count))
	return {"total": total, "body": body, "head": head, "bursts": bursts,
			"ttk_s": float(bursts - 1) * pilum.fire_interval_s}


func test_pilum_vs_hastati_derived_values() -> void:
	var d := _derive()
	assert_eq(d["total"], 200.0, "Hastati shield + health")
	assert_eq(d["body"], 10, "body hits to kill")
	assert_eq(d["head"], 7, "headshots to kill (200 / 30 = 6.7)")
	assert_eq(d["bursts"], 4, "3-round bursts on body hits")
	assert_eq(d["ttk_s"], 1.5, "time to the last burst at 0.5 s per burst")


## Melee figures per enabled class from stats.json "melee": {display_name: front, display_name: full shield}.
func _derive_melee() -> Dictionary:
	var reg := DataRegistry.new()
	var frac := float(reg.get_melee_cfg().get("melee_front_shield_fraction", 0.0))
	var classes: Dictionary = reg.load_file(DataRegistry.STATS_PATH).get("classes", {})
	var front := {}
	var full := {}
	for id: String in classes:
		var c := reg.get_class_def(id)
		if bool(classes[id].get("enabled", false)):
			front[c.display_name] = roundi(c.shield * frac)
			full[c.display_name] = roundi(c.shield)
	return {"front": front, "full": full}


func test_melee_figures_are_derived_from_data() -> void:
	var m := _derive_melee()
	assert_eq(m["front"], {"Hastati": 70, "Sagittarii": 56}, "front hits: 0.7 x max shield, enabled classes")
	assert_eq(m["full"], {"Hastati": 100, "Sagittarii": 80}, "Gladiator attacker front hit = full shield")


func test_stats_doc_states_the_melee_figures() -> void:
	var f := FileAccess.open(STATS_DOC, FileAccess.READ)
	if f == null:
		failures.append("cannot open " + STATS_DOC)
		return
	var text := f.get_as_text()
	var m := _derive_melee()
	for name: String in m["front"]:
		assert_true(text.contains("front %d (%s)" % [m["front"][name], name]),
				"STATS.md states front %d (%s)" % [m["front"][name], name])
		assert_true(text.contains("Gladiator attacker front %d (%s)" % [m["full"][name], name]),
				"STATS.md states the Gladiator front %d (%s)" % [m["full"][name], name])
	assert_true(text.contains("back instant kill"), "STATS.md states the back hit is an instant kill")
	assert_true(not text.contains("60 per swing"), "STATS.md no longer states a typed-in 60 per swing")


func test_stats_doc_states_the_derived_values() -> void:
	var f := FileAccess.open(STATS_DOC, FileAccess.READ)
	if f == null:
		failures.append("cannot open " + STATS_DOC)
		return
	var text := f.get_as_text()
	var d := _derive()
	assert_true(text.contains("%d body hits" % d["body"]), "STATS.md states %d body hits" % d["body"])
	assert_true(text.contains("about %d with headshots" % d["head"]), "STATS.md states about %d with headshots" % d["head"])
	assert_true(text.contains("%d bursts = about %.1f s" % [d["bursts"], d["ttk_s"]]),
			"STATS.md states %d bursts = about %.1f s" % [d["bursts"], d["ttk_s"]])
