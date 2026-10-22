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
