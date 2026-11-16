extends "res://tests/test_case.gd"
## M2 Z2 (OQ-BR-LENGTH): the match length presets of data/br.json "match_length". MatchDirector.load_config(map,
## id) stretches the merged zone schedule so the last circle finishes closing at minutes x 60 (every wait_s and
## shrink_s times one factor); radii, damage, phase order, the start circle, the drop and loot are untouched.
## Without an id nothing is touched; an unknown id, a malformed option or a factor below 1 is rejected (one
## push_warning, the map's own schedule). The rejections log WARNING lines only, never a script error.

const _Tool := preload("res://tools/gen_zone.gd")
const MAP := "res://data/maps/alesia_1km.json"
const BR := "res://data/br.json"
const TICK := 1.0 / 60.0


func _cfg(map_json: String = "", length_id: String = "") -> MatchDirector:
	var d := MatchDirector.new()
	d.load_config(map_json, length_id)
	return d


## Today's mode_cfg / loot_cfg, built the way load_config built them before M2 Z2.
func _today_mode(map_json: String) -> Dictionary:
	var cfg := ModeRegistry.merged_config(MatchDirector.MODE_ID, DataRegistry.new().load_file("res://data/modes.json"))
	if map_json != "":
		cfg = MatchDirector.merge_overrides(cfg, MatchDirector.map_overrides(map_json).get("br", {}))
	return cfg


func _today_loot(map_json: String) -> Dictionary:
	var cfg: Dictionary = DataRegistry.new().load_file(MatchDirector.LOOT_PATH).duplicate(true)
	if map_json != "":
		cfg = MatchDirector.merge_overrides(cfg, MatchDirector.map_overrides(map_json).get("loot", {}))
	return cfg


func _sum(phases: Array) -> float:
	var t := 0.0
	for ph: Dictionary in phases:
		t += float(ph["wait_s"]) + float(ph["shrink_s"])
	return t


## Rule time (s) at which a BrRules built from `cfg` reaches the "final" zone state, ticked at 1/60 s; -1 if never.
func _rules_last_close(cfg: Dictionary) -> float:
	var rules := ModeRegistry.create(MatchDirector.MODE_ID, {MatchDirector.MODE_ID: cfg}) as BrRules
	if rules == null or not rules.config_problems().is_empty():
		return -1.0
	rules.register_player(1, 1)
	rules.register_player(2, 2)
	var limit := int(_sum(cfg["zone"]["phases"]) * 60.0) + 120
	for n in limit:
		rules.tick(TICK, {})
		if rules.zone_state() == "final":
			return (n + 1) * TICK
	return -1.0


func _release(d: MatchDirector) -> void:
	d.free()


func test_presets_stretch_the_1km_schedule() -> void:
	var plain := _cfg(MAP)
	var def := DataRegistry.parse_quiet(MAP)
	var gen: Array = _Tool.generate(def, _Tool.merged_drop(MAP))["phases"]
	var nominal := _sum(plain.mode_cfg["zone"]["phases"])
	assert_true(absf(nominal - 570.0) < 1e-6, "alesia_1km's own schedule is 570 s (got %.3f)" % nominal)
	for spec: Array in [["12", 12.0], ["15", 15.0], ["20", 20.0]]:
		var id: String = spec[0]
		var minutes: float = spec[1]
		var d := _cfg(MAP, id)
		var info := d.match_length_info
		var factor := minutes * 60.0 / 570.0
		assert_true(bool(info["applied"]), id + ": applied")
		assert_true(absf(float(info["factor"]) - factor) < 1e-9, id + ": factor is minutes x 60 / 570")
		assert_eq(float(info["minutes"]), minutes, id + ": minutes")
		assert_true(absf(float(info["nominal_s"]) - 570.0) < 1e-6, id + ": nominal_s")
		var phases: Array = d.mode_cfg["zone"]["phases"]
		var total := _sum(phases)
		assert_true(absf(total - minutes * 60.0) <= TICK, id + ": the last circle closes at minutes x 60 (%.4f s)" % total)
		assert_true(absf(float(info["last_close_s"]) - minutes * 60.0) <= TICK, id + ": info last_close_s")
		var base: Array = plain.mode_cfg["zone"]["phases"]
		assert_eq(phases.size(), base.size(), id + ": phase count")
		assert_eq(phases.size(), gen.size(), id + ": phase count is the generator's")
		for i in phases.size():
			var ph: Dictionary = phases[i]
			var g: Dictionary = gen[i]
			assert_true(absf(float(ph["wait_s"]) - float(g["wait_s"]) * factor) < 1e-9, "%s phase %d: wait = generated x factor" % [id, i])
			assert_true(absf(float(ph["shrink_s"]) - float(g["shrink_s"]) * factor) < 1e-9, "%s phase %d: shrink = generated x factor" % [id, i])
			assert_eq(typeof(ph["wait_s"]), TYPE_FLOAT, "%s phase %d: wait is a float" % [id, i])
			assert_eq(ph["radius_m"], base[i]["radius_m"], "%s phase %d: radius unchanged" % [id, i])
			assert_eq(ph["damage_per_s"], base[i]["damage_per_s"], "%s phase %d: damage unchanged" % [id, i])
			assert_eq(ph.keys(), (base[i] as Dictionary).keys(), "%s phase %d: same keys in the same order" % [id, i])
		for key: String in ["start_radius_m", "start_center", "damage_skips_shield"]:
			assert_eq(d.mode_cfg["zone"][key], plain.mode_cfg["zone"][key], id + ": zone " + key + " unchanged")
		assert_eq(d.mode_cfg["drop"], plain.mode_cfg["drop"], id + ": the drop is not scaled")
		assert_eq(d.loot_cfg, plain.loot_cfg, id + ": loot is not scaled")
		assert_eq(d.match_cfg, plain.match_cfg, id + ": match.json unchanged")
		for key: String in ["downed", "end", "teams", "default_seed", "match_length"]:
			assert_eq(d.mode_cfg[key], plain.mode_cfg[key], id + ": " + key + " unchanged")
		_release(d)
	_release(plain)


func test_rules_close_the_last_circle_at_the_preset() -> void:
	# Drives BrRules itself through the scaled 1 km config at 1/60 s ticks (rule time, no scene).
	for spec: Array in [["12", 12.0], ["15", 15.0], ["20", 20.0]]:
		var d := _cfg(MAP, spec[0])
		var t := _rules_last_close(d.mode_cfg)
		assert_true(t > 0.0, "%s: the zone reaches its final state" % spec[0])
		assert_true(absf(t - float(spec[1]) * 60.0) <= TICK + 1e-6, "%s: the last circle finishes closing at %.0f s of rule time within one tick (got %.4f s)" % [spec[0], float(spec[1]) * 60.0, t])
		_release(d)


func test_no_preset_touches_nothing() -> void:
	for map_json: String in ["", MAP]:
		var d := _cfg(map_json)
		assert_eq(d.mode_cfg, _today_mode(map_json), "'%s': mode_cfg is today's" % map_json)
		assert_eq(d.loot_cfg, _today_loot(map_json), "'%s': loot_cfg is today's" % map_json)
		assert_true(not bool(d.match_length_info["applied"]), "'%s': not applied" % map_json)
		assert_eq(float(d.match_length_info["factor"]), 1.0, "'%s': factor 1" % map_json)
		var want: Array = _today_mode(map_json)["zone"]["phases"]
		assert_eq(var_to_str(d.mode_cfg["zone"]["phases"]), var_to_str(want), "'%s': the phases keep their values and types" % map_json)
		assert_eq(JSON.stringify(d.mode_cfg["zone"]["phases"]), JSON.stringify(want), "'%s': the phases stringify the same" % map_json)
		_release(d)
	# The plain file: br.json's phases exactly as parsed, and the default-argument call is the same.
	var plain := _cfg()
	var file_phases: Array = DataRegistry.parse_quiet(BR)["zone"]["phases"]
	assert_eq(var_to_str(plain.mode_cfg["zone"]["phases"]), var_to_str(file_phases), "load_config() keeps br.json's phases as the file has them")
	# apply with "" is a no-op on any config.
	var cfg := plain.mode_cfg.duplicate(true)
	var info := MatchDirector.apply_match_length(cfg, "")
	assert_eq(var_to_str(cfg), var_to_str(plain.mode_cfg), "apply_match_length(cfg, \"\") changes nothing")
	assert_true(not bool(info["applied"]), "\"\": applied false")
	assert_true(absf(float(info["last_close_s"]) - 295.0) < 1e-6, "\"\": last_close_s is br.json's 295 s")
	_release(plain)


func test_plain_br_json_scales_its_own_phases() -> void:
	var plain := _cfg()
	var d := _cfg("", "12")
	var factor := 720.0 / 295.0
	assert_true(bool(d.match_length_info["applied"]), "applied on br.json")
	assert_true(absf(float(d.match_length_info["factor"]) - factor) < 1e-9, "factor 720 / 295")
	var phases: Array = d.mode_cfg["zone"]["phases"]
	var base: Array = plain.mode_cfg["zone"]["phases"]
	assert_eq(phases.size(), base.size(), "phase count")
	for i in phases.size():
		assert_true(absf(float(phases[i]["wait_s"]) - float(base[i]["wait_s"]) * factor) < 1e-9, "phase %d wait" % i)
		assert_true(absf(float(phases[i]["shrink_s"]) - float(base[i]["shrink_s"]) * factor) < 1e-9, "phase %d shrink" % i)
		assert_eq(phases[i]["radius_m"], base[i]["radius_m"], "phase %d radius" % i)
		assert_eq(phases[i]["damage_per_s"], base[i]["damage_per_s"], "phase %d damage" % i)
	assert_true(absf(_sum(phases) - 720.0) <= TICK, "br.json's schedule closes at 720 s")
	assert_eq(d.mode_cfg["drop"], plain.mode_cfg["drop"], "the drop is not scaled")
	_release(d)
	_release(plain)


func test_a_new_option_in_data_needs_no_code() -> void:
	var plain := _cfg(MAP)
	var cfg := plain.mode_cfg.duplicate(true)
	(cfg["match_length"]["options"] as Array).append({"id": "25", "minutes": 25})
	var info := MatchDirector.apply_match_length(cfg, "25")
	assert_true(bool(info["applied"]), "25: applied")
	assert_true(absf(_sum(cfg["zone"]["phases"]) - 1500.0) <= TICK, "25: closes at 1500 s")
	assert_eq(MatchDirector.match_length_label(cfg, "25"), "25 min", "25: label")
	assert_eq(MatchDirector.validated_match_length_id(cfg, "25"), "25", "25: a valid id")
	var ids: Array = []
	for opt: Dictionary in MatchDirector.match_length_options(cfg):
		ids.append(str(opt["id"]))
	assert_eq(ids, ["12", "15", "20", "25"], "the option list in data order")
	_release(plain)


func test_helpers_read_the_data() -> void:
	var plain := _cfg()
	var cfg := plain.mode_cfg
	var block: Dictionary = DataRegistry.parse_quiet(BR)["match_length"]
	assert_true(bool(block["_placeholder"]) and String(block["_todo"]).contains("OQ-BR-LENGTH"), "the block is a placeholder (OQ-BR-LENGTH)")
	assert_eq(MatchDirector.match_length_default_id(cfg), "15", "data default 15")
	assert_eq(MatchDirector.match_length_label(cfg, "12"), "12 min", "label 12")
	assert_eq(MatchDirector.match_length_label(cfg, "15"), "15 min", "label 15")
	assert_eq(MatchDirector.match_length_label(cfg, "20"), "20 min", "label 20")
	assert_eq(MatchDirector.match_length_label(cfg, "nope"), "", "no label for an unknown id")
	assert_eq(MatchDirector.validated_match_length_id(cfg, "20"), "20", "a known id stays")
	assert_eq(MatchDirector.validated_match_length_id(cfg, "nope"), "15", "an unknown id becomes the default")
	assert_eq(MatchDirector.validated_match_length_id(cfg, ""), "15", "an empty id becomes the default")
	assert_eq(MatchDirector.match_length_options(cfg).size(), 3, "three options")
	assert_true(BrRules.validate_config(cfg).is_empty(), "BrRules accepts br.json with the match_length block")
	assert_true(BrRules.validate_config(_cfg(MAP, "20").mode_cfg).is_empty(), "BrRules accepts the stretched 1 km config")
	_release(plain)


func test_rejected_ids_keep_the_maps_schedule() -> void:
	var plain := _cfg(MAP)
	var want := var_to_str(plain.mode_cfg)
	# Unknown id through load_config: the map's own schedule, untouched.
	var d := _cfg(MAP, "nope")
	assert_true(not bool(d.match_length_info["applied"]), "unknown id: applied false")
	assert_eq(var_to_str(d.mode_cfg), want, "unknown id: mode_cfg is the map's own")
	_release(d)
	# A factor below 1 on the 1 km phases (5 min < 570 s), and a malformed option.
	for opt: Dictionary in [{"id": "5", "minutes": 5}, {"id": "bad", "minutes": "x"}, {"id": "zero", "minutes": 0}]:
		var cfg := plain.mode_cfg.duplicate(true)
		(cfg["match_length"]["options"] as Array).append(opt)
		var before := var_to_str(cfg)
		var info := MatchDirector.apply_match_length(cfg, str(opt["id"]))
		assert_true(not bool(info["applied"]), "%s: applied false" % opt["id"])
		assert_eq(float(info["factor"]), 1.0, "%s: factor 1" % opt["id"])
		assert_eq(var_to_str(cfg), before, "%s: phases untouched" % opt["id"])
	# No match_length block at all.
	var bare := plain.mode_cfg.duplicate(true)
	bare.erase("match_length")
	var bare_before := var_to_str(bare)
	assert_true(not bool(MatchDirector.apply_match_length(bare, "15")["applied"]), "no block: applied false")
	assert_eq(var_to_str(bare), bare_before, "no block: untouched")
	_release(plain)


func test_last_drop_lands_before_the_first_wait_ends_at_12() -> void:
	# The last forced drop leaves at drop.carrier_s and lands at about carrier_s + altitude_m / max_fall_mps
	# (alesia_1km.json drop _todo; tools/gen_zone.gd's reach rule). The presets only stretch waits, so the
	# shortest preset is the tightest.
	for map_json: String in [MAP, ""]:
		var d := _cfg(map_json, "12")
		assert_true(bool(d.match_length_info["applied"]), "'%s': 12 applied" % map_json)
		var drop: Dictionary = d.mode_cfg["drop"]
		var t_land := float(drop["carrier_s"]) + float(drop["altitude_m"]) / float(drop["max_fall_mps"])
		var first_wait := float(d.mode_cfg["zone"]["phases"][0]["wait_s"])
		assert_true(t_land < first_wait, "'%s': the last drop lands (%.1f s) before the first wait ends (%.1f s)" % [map_json, t_land, first_wait])
		_release(d)
