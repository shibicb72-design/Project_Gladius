extends "res://tests/test_case.gd"

const PATH := "res://data/stats.json"
const CLASS_IDS := ["hastati", "principes", "triarii", "velites", "sagittarii", "equites", "gladiator"]
const WEAPON_KEYS := ["damage", "headshot_multiplier", "fire_interval_s", "burst_count", "burst_interval_s",
	"magazine", "reserve_ammo", "reload_s", "range_m", "spread_deg"]


func _load() -> Dictionary:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		failures.append("cannot open " + PATH)
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		failures.append("stats.json did not parse to a dictionary")
		return {}
	return data


func test_classes() -> void:
	var data := _load()
	if data.is_empty():
		return
	var classes: Dictionary = data["classes"]
	var enabled: Array[String] = []
	for id in CLASS_IDS:
		assert_true(classes.has(id), "missing class " + id)
		if not classes.has(id):
			continue
		for k in ["shield", "health", "speed_pct"]:
			assert_true(classes[id][k] > 0, "%s.%s must be > 0" % [id, k])
		if classes[id]["enabled"]:
			enabled.append(id)
	enabled.sort()
	assert_eq(enabled, ["hastati", "sagittarii"], "enabled classes")


func test_weapons() -> void:
	var data := _load()
	if data.is_empty():
		return
	# gladius_lux is melee (OQ-07): its keys are checked in test_decisions_oct22.gd.
	for id in ["pilum_br", "sagittarii_rifle"]:
		assert_true(data["weapons"].has(id), "missing weapon " + id)
		if not data["weapons"].has(id):
			continue
		var w: Dictionary = data["weapons"][id]
		assert_eq(w.get("_placeholder"), true, id + " _placeholder")
		for k in WEAPON_KEYS:
			assert_true(w.has(k) and w[k] > 0, "%s.%s must be > 0" % [id, k])
