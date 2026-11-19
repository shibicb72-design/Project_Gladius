extends "res://tests/test_case.gd"
## M2 B4 (OQ-BOT-DIFFICULTY): the bot difficulty table of data/bots.json "difficulty" and MatchRoot's helpers. A level
## overrides every bot brain's profile accuracy / reaction_time_s and cfg fight.settle_s / settle_floor_frac (on deep
## copies: the data a brain was handed is never written). normal = profile tiro + today's brain.fight values. A match
## begun without a lobby (tests, sims, offline) is not touched and keeps match_fill.profile. The lobby wiring (a
## lobby set to hard) is phase 2.

const _MatchScene := preload("res://scenes/match/match.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const BOTS_PATH := "res://data/bots.json"
const LEVEL_KEYS := ["accuracy", "reaction_time_s", "settle_s", "settle_floor_frac"]


func tree() -> SceneTree:
	return Engine.get_main_loop()


func all_cfg() -> Dictionary:
	return DataRegistry.new().load_file(BOTS_PATH)


## The profile and brain.fight values every bot plays with today (match_fill.profile, brain.fight).
func today() -> Dictionary:
	var cfg := all_cfg()
	var p: Dictionary = cfg["profiles"][cfg["match_fill"]["profile"]]
	var f: Dictionary = cfg["brain"]["fight"]
	return {"accuracy": float(p["accuracy"]), "reaction_time_s": float(p["reaction_time_s"]),
			"settle_s": float(f["settle_s"]), "settle_floor_frac": float(f["settle_floor_frac"])}


## The four values a brain plays with now.
static func effective(brain: BotBrain) -> Dictionary:
	return {"accuracy": float(brain.profile["accuracy"]), "reaction_time_s": float(brain.profile["reaction_time_s"]),
			"settle_s": float(brain.cfg["fight"]["settle_s"]), "settle_floor_frac": float(brain.cfg["fight"]["settle_floor_frac"])}


static func level_values(id: String) -> Dictionary:
	var lv := MatchRoot.bot_difficulty_level(id)
	var out := {}
	for k in LEVEL_KEYS:
		out[k] = float(lv[k])
	return out


## Bare bot pawns (not in the tree, no director) with brains from BotSpawner.attach_brain, as a match gives them.
func bare_bots(n: int) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for i in n:
		var p: Pawn = _PawnScene.instantiate()
		BotSpawner.attach_brain(p, null)
		out.append(p)
	return out


static func free_all(pawns: Array) -> void:
	for p in pawns:
		if is_instance_valid(p):
			(p as Node).free()


func test_table_order_default_and_labels() -> void:
	var cfg := MatchRoot.bot_difficulty_cfg()
	assert_true(bool(cfg.get("_placeholder", false)) and str(cfg.get("_todo", "")).contains("OQ-BOT-DIFFICULTY"),
			"the table is a placeholder with its OQ id")
	assert_eq(MatchRoot.bot_difficulty_ids(), ["easy", "normal", "hard", "very_hard"] as Array[String], "the cycle order")
	assert_eq((cfg["levels"] as Dictionary).size(), 4, "exactly four levels")
	assert_eq(MatchRoot.bot_difficulty_default(), "normal", "the default level")
	var labels := {"easy": "Easy", "normal": "Normal", "hard": "Hard", "very_hard": "Very hard"}
	for id in labels:
		assert_eq(MatchRoot.bot_difficulty_label(id), labels[id], "label of " + id)
	assert_eq(MatchRoot.bot_difficulty_label("nightmare"), "", "an unknown level has no label")
	assert_true(MatchRoot.bot_difficulty_level("nightmare").is_empty(), "an unknown level is {}")


func test_normal_is_today_exactly() -> void:
	assert_eq(level_values("normal"), today(), "normal = profile tiro + today's brain.fight settle values")
	assert_eq(String(all_cfg()["match_fill"]["profile"]), "tiro", "match_fill still plays tiro")


func test_levels_are_strictly_ordered() -> void:
	var ids := MatchRoot.bot_difficulty_ids()
	for i in range(1, ids.size()):
		var a := level_values(ids[i - 1])
		var b := level_values(ids[i])
		var pair := "%s -> %s" % [ids[i - 1], ids[i]]
		assert_true(b["accuracy"] > a["accuracy"], "accuracy rises " + pair)
		assert_true(b["reaction_time_s"] < a["reaction_time_s"], "reaction time falls " + pair)
		assert_true(b["settle_floor_frac"] < a["settle_floor_frac"], "settle floor falls " + pair)
		assert_true(b["settle_s"] <= a["settle_s"], "settle time does not rise " + pair)


func test_validated_bot_difficulty() -> void:
	for id in ["easy", "normal", "hard", "very_hard"]:
		assert_eq(MatchRoot.validated_bot_difficulty(id), id, "a valid id is kept: " + id)
	for bad: Variant in ["nightmare", "", "Hard", null, 2, true, ["hard"], {"hard": 1}, 0.5]:
		assert_eq(MatchRoot.validated_bot_difficulty(bad), "normal", "falls back to normal: %s" % str(bad))


func test_apply_hard_on_brains_and_shared_data_untouched() -> void:
	var pawns := bare_bots(3)
	var bare: Pawn = _PawnScene.instantiate()  # a client-side pawn: no Brain
	var before: BotBrain = pawns[0].get_node("Brain")
	var profile_before := before.profile.duplicate(true)
	var cfg_before := before.cfg.duplicate(true)
	var handed_profile := before.profile  # the dictionaries attach_brain handed it
	var handed_cfg := before.cfg
	var targets: Array = []  # untyped, so it can hold a non-node
	targets.append_array(pawns)
	targets.append(bare)
	targets.append(42)  # not a node: skipped
	assert_eq(MatchRoot.apply_bot_difficulty(targets, "hard"), 3, "three brains changed, the brainless pawn skipped")
	var hard := level_values("hard")
	for p in pawns:
		var brain: BotBrain = p.get_node("Brain")
		assert_eq(effective(brain), hard, "the brain plays hard")
		for k in profile_before:
			if not k in ["accuracy", "reaction_time_s"]:
				assert_eq(brain.profile[k], profile_before[k], "profile key unchanged: " + str(k))
		for k in cfg_before:
			if k != "fight":
				assert_eq(brain.cfg[k], cfg_before[k], "cfg key unchanged: " + str(k))
		for k in cfg_before["fight"]:
			if not k in ["settle_s", "settle_floor_frac"]:
				assert_eq(brain.cfg["fight"][k], cfg_before["fight"][k], "fight key unchanged: " + str(k))
	assert_eq(handed_profile, profile_before, "the profile dictionary attach_brain handed over is not written")
	assert_eq(handed_cfg, cfg_before, "the cfg dictionary attach_brain handed over is not written")
	var b0: BotBrain = pawns[0].get_node("Brain")
	var b1: BotBrain = pawns[1].get_node("Brain")
	b0.profile["accuracy"] = 0.99
	b0.cfg["fight"]["settle_s"] = 9.9
	assert_eq(float(b1.profile["accuracy"]), hard["accuracy"], "two bots do not share a profile")
	assert_eq(float(b1.cfg["fight"]["settle_s"]), hard["settle_s"], "two bots do not share a fight block")
	assert_eq(today(), level_values("normal"), "a fresh load of bots.json still shows tiro 0.35 / 0.8 and settle 1.5 / 0.15")
	assert_eq(float(all_cfg()["profiles"]["tiro"]["accuracy"]), 0.35, "tiro accuracy in a fresh load")
	assert_eq(float(all_cfg()["brain"]["fight"]["settle_s"]), 1.5, "settle_s in a fresh load")
	var later := bare_bots(1)
	assert_eq(effective(later[0].get_node("Brain")), today(), "a brain attached afterwards still gets tiro and today's settle")
	free_all(pawns)
	free_all(later)
	bare.free()


func test_apply_normal_keeps_today_and_unknown_changes_nothing() -> void:
	var pawns := bare_bots(2)
	assert_eq(MatchRoot.apply_bot_difficulty(pawns, "normal"), 2, "normal changes both brains (to the same values)")
	for p in pawns:
		assert_eq(effective(p.get_node("Brain")), today(), "normal plays exactly as today")
	var brain: BotBrain = pawns[0].get_node("Brain")
	var prof := brain.profile
	var cfg := brain.cfg
	for bad in ["nightmare", "", "Normal"]:
		assert_eq(MatchRoot.apply_bot_difficulty(pawns, bad), 0, "unknown level %s changes no brain" % bad)
	assert_true(is_same(brain.profile, prof) and is_same(brain.cfg, cfg), "an unknown level does not even replace the dictionaries")
	assert_eq(MatchRoot.apply_bot_difficulty([], "hard"), 0, "no pawns, nothing changed")
	free_all(pawns)


## The one full match: begun without a lobby, its bots play tiro and today's settle; a level applied to its real
## bots reaches every brain.
func test_match_without_lobby_keeps_tiro() -> void:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	tree().root.add_child(m)
	await tree().physics_frame
	assert_true(m.begin(), "begin")
	assert_true(m.roster == null, "no lobby (the offline branch: no roster)")
	assert_true(m.bots.size() > 0, "the match filled bots")
	for b in m.bots:
		b.get_node("Brain").set_physics_process(false)
	var expect := {"accuracy": 0.35, "reaction_time_s": 0.8, "settle_s": 1.5, "settle_floor_frac": 0.15}
	var ok := true
	for b in m.bots:
		ok = ok and effective(b.get_node("Brain")) == expect
	assert_true(ok, "every bot of a match without a lobby plays tiro 0.35 / 0.8, settle 1.5 / 0.15")
	assert_eq(MatchRoot.apply_bot_difficulty(m.bots, "very_hard"), m.bots.size(), "every real bot brain changed")
	var vh := level_values("very_hard")
	ok = true
	for b in m.bots:
		ok = ok and effective(b.get_node("Brain")) == vh
	assert_true(ok, "every real bot brain plays very_hard")
	m.queue_free()
	await tree().process_frame
