extends "res://tests/test_case.gd"
## Shibi's Oct 22 2026 decisions: starter stats, energy blade, headshots, scoring, plain digits.

const _TMP := "user://test_profile_oct22.json"
const _MatchScene := preload("res://scenes/match/match.tscn")
const MODES_PATH := "res://data/modes.json"
const MELEE_KEYS := ["damage", "headshot_multiplier", "fire_interval_s", "melee_range_m", "melee_arc_deg",
	"swing_duration_s"]
const GUN_KEYS := ["damage", "headshot_multiplier", "fire_interval_s", "burst_count", "burst_interval_s",
	"magazine", "reserve_ammo", "reload_s", "range_m", "spread_deg"]


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _weapon(id: String) -> WeaponDef:
	return DataRegistry.new().get_weapon_def(id)


# ---- OQ-06: stats.json loads every weapon ----------------------------------------------------

func test_stats_json_loads_every_weapon() -> void:
	var reg := DataRegistry.new()
	var weapons: Dictionary = reg.load_file(DataRegistry.STATS_PATH).get("weapons", {})
	for id in ["pilum_br", "gladius_lux", "sagittarii_rifle"]:
		assert_true(weapons.has(id), "stats.json has " + id)
	for id in weapons:
		var def := reg.get_weapon_def(id)
		assert_true(def != null, "WeaponDef for " + id)
		if def == null:
			continue
		assert_true(def.is_placeholder, id + " is marked placeholder (Shibi tunes on the phone)")
		for k in (MELEE_KEYS if def.is_melee() else GUN_KEYS):
			assert_true(weapons[id].has(k) and float(weapons[id][k]) > 0.0, "%s.%s present and > 0" % [id, k])
		assert_true(def.headshot_multiplier >= 1.0, id + " headshot_multiplier >= 1")
	assert_eq(reg.validate(), PackedStringArray(), "registry validates clean")


func test_sagittarii_rifle_is_long_range_single_shot_placeholder() -> void:
	var rifle := _weapon("sagittarii_rifle")
	var pilum := _weapon("pilum_br")
	assert_eq(rifle.burst_count, 1, "single shot")
	assert_eq(rifle.kind, "hitscan", "hitscan")
	assert_true(rifle.range_m > pilum.range_m, "longer range than Pilum BR")
	assert_true(rifle.is_placeholder, "placeholder, not a Shibi decision")
	var raw: Dictionary = DataRegistry.new().load_file(DataRegistry.STATS_PATH)["weapons"]["sagittarii_rifle"]
	assert_true(str(raw.get("_todo", "")).contains("NOT a Shibi decision"), "data says it is not a decision")


# ---- OQ-07: Gladius Lux is an energy blade ---------------------------------------------------

func test_gladius_lux_is_melee_and_pilum_stays_hitscan_burst() -> void:
	var lux := _weapon("gladius_lux")
	assert_eq(lux.kind, "melee", "Gladius Lux kind")
	assert_true(lux.is_melee(), "is_melee")
	assert_true(lux.melee_range_m > 0.0 and lux.melee_range_m < 5.0, "short range")
	var pilum := _weapon("pilum_br")
	assert_eq(pilum.kind, "hitscan", "Pilum BR kind")
	assert_true(pilum.burst_count > 1, "Pilum BR is a burst weapon")


func test_melee_weapon_has_no_ammo_use_and_no_reload() -> void:
	var w := Weapon.new(_weapon("gladius_lux"))
	assert_true(w.has_ammo(), "melee never dry")
	assert_eq(w.update(0.0, true), 1, "swing")
	assert_eq(w.ammo_in_mag, 0, "no ammo spent")
	assert_true(not w.start_reload(1.0), "no reload for a blade")
	assert_eq(w.update(w.def.fire_interval_s * 0.5, true), 0, "swing rate respected")
	assert_eq(w.update(w.def.fire_interval_s, true), 1, "second swing at interval")


func test_melee_hit_test_range_and_arc() -> void:
	var def := _weapon("gladius_lux")
	var o := Vector3.ZERO
	var fwd := Vector3(0, 0, -1)
	var r := def.melee_range_m
	assert_true(Melee.in_swing(o, fwd, Vector3(0, 0, -r * 0.5), def), "dead ahead inside range")
	assert_true(not Melee.in_swing(o, fwd, Vector3(0, 0, -(r + 0.5)), def), "beyond range")
	assert_true(not Melee.in_swing(o, fwd, Vector3(0, 0, r * 0.5), def), "directly behind")
	var half := deg_to_rad(def.melee_arc_deg) * 0.5
	var inside := Vector3(-sin(half - 0.05), 0, -cos(half - 0.05)) * (r * 0.5)
	var outside := Vector3(-sin(half + 0.05), 0, -cos(half + 0.05)) * (r * 0.5)
	assert_true(Melee.in_swing(o, fwd, inside, def), "just inside the arc")
	assert_true(not Melee.in_swing(o, fwd, outside, def), "just outside the arc")


func test_melee_swing_damages_enemy_in_front_only() -> void:
	var root := _tree().root
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	var front := Pawn.new()
	front.setup("hastati", 1)
	var behind := Pawn.new()
	behind.setup("hastati", 1)
	var mate := Pawn.new()
	mate.setup("hastati", 0)
	for p in [attacker, front, behind, mate]:
		root.add_child(p)
		p.add_to_group("pawns")
	attacker.global_position = Vector3(0, 50, 0)
	var def := _weapon("gladius_lux")
	front.global_position = attacker.global_position + Vector3(0, 0, -def.melee_range_m * 0.5)
	behind.global_position = attacker.global_position + Vector3(0, 0, def.melee_range_m * 0.5)
	mate.global_position = front.global_position
	var shield_before: float = front.bridge.state.shield
	var dir := Vector3(0, 0, -1)
	var hit := attacker.melee_swing(def, attacker.get_muzzle_position(), dir, attacker.hit_authority)
	assert_eq(hit["targets"].size(), 2, "enemy in front and teammate are reached by the arc")
	assert_eq(front.bridge.state.shield, shield_before - def.damage, "front enemy lost the blade damage")
	assert_eq(behind.bridge.state.shield, behind.bridge.state.max_shield, "enemy behind untouched")
	assert_eq(mate.bridge.state.shield, mate.bridge.state.max_shield, "no friendly fire")
	for p in [attacker, front, behind, mate]:
		p.free()


func test_fire_shot_with_blade_does_a_melee_swing() -> void:
	var root := _tree().root
	var attacker := Pawn.new()
	attacker.setup("hastati", 0)
	var victim := Pawn.new()
	victim.setup("hastati", 1)
	root.add_child(attacker)
	root.add_child(victim)
	attacker.global_position = Vector3(0, 60, 0)
	victim.global_position = attacker.global_position + Vector3(0, 0, -1.0)
	attacker.loadout.swap()
	assert_eq(attacker.loadout.get_active().def.id, "gladius_lux", "blade active")
	var res := attacker.fire_shot()
	assert_true(bool(res.get("melee", false)), "swing result")
	assert_true(victim.bridge.state.shield < victim.bridge.state.max_shield, "victim hit by the swing")
	attacker.free()
	victim.free()


# ---- OQ-13: headshot multiplier per weapon, same on shield and health -----------------------

func test_headshot_multiplier_applies_equally_to_shield_and_health() -> void:
	for id in ["pilum_br", "sagittarii_rifle"]:
		var def := _weapon(id)
		var body := HealthState.create(1000.0, 1000.0)
		var head := HealthState.create(1000.0, 1000.0)
		var rb := DamageRules.apply_hit(body, def, false, 0, 1, false)
		var rh := DamageRules.apply_hit(head, def, true, 0, 1, false)
		assert_eq(rb.shield_damage, def.damage, id + " body hit on shield")
		assert_eq(rh.shield_damage, def.damage * def.headshot_multiplier, id + " headshot on shield")
		# Health: no shield, same multiplier.
		var hp := HealthState.create(0.0, 1000.0)
		var rhp := DamageRules.apply_hit(hp, def, true, 0, 1, false)
		assert_eq(rhp.health_damage, def.damage * def.headshot_multiplier, id + " headshot on health")
	var a := _weapon("pilum_br")
	var b := _weapon("sagittarii_rifle")
	assert_true(a.headshot_multiplier != b.headshot_multiplier, "weapons carry their own multiplier")


# ---- OQ-20/21/22: independent squads, contested hill, draw -----------------------------------

func _koth(squads: int) -> KothRules:
	var k := KothRules.new()
	k.setup(DataRegistry.new().load_file(MODES_PATH)["koth"])
	k.register_squads(range(squads))
	return k


func test_six_squads_score_independently() -> void:
	var k := _koth(6)
	for s in 6:
		k.tick(float(s + 1), {s: 3})
	for s in 6:
		assert_eq(k.scores[s], s + 1, "squad %d scored only its own time" % s)
	assert_eq(k.scores.size(), 6, "six squads")


func test_contested_zone_nobody_scores_even_with_three_squads() -> void:
	var k := _koth(6)
	k.tick(10.0, {0: 1, 2: 2, 5: 1})
	for s in 6:
		assert_eq(k.scores[s], 0, "squad %d scored nothing while contested" % s)
	k.tick(4.0, {2: 1, 5: 0})
	assert_eq(k.scores[2], 4, "scores again once only one squad is inside")


func test_tie_at_top_is_a_draw_with_six_squads() -> void:
	var k := _koth(6)
	k.tick(30.0, {1: 1})
	k.tick(30.0, {4: 1})
	k.tick(10.0, {3: 1})
	k.tick(600.0, {})
	assert_true(k.is_over(), "timer ended")
	var res := k.result()
	assert_true(res["draw"], "tie at the top is a draw")
	assert_eq(res["winner"], -1, "no winner")


func test_clear_leader_wins_on_timer() -> void:
	var k := _koth(6)
	k.tick(31.0, {1: 1})
	k.tick(30.0, {4: 1})
	k.tick(600.0, {})
	assert_true(not k.result()["draw"], "no draw")
	assert_eq(k.result()["winner"], 1, "highest score wins")


# ---- OQ-38: plain digits, Roman code kept behind a data switch --------------------------------

func test_roman_numerals_off_in_data_and_hud_uses_digits() -> void:
	assert_true(not HudNumbers.roman_enabled(), "data/ui.json hud.roman_numerals is false")
	assert_eq(HudNumbers.number(0), "0", "zero is 0")
	assert_eq(HudNumbers.number(12), "12", "plain digits")
	assert_eq(HudNumbers.squad_name(0), "Squad 1", "first squad")
	assert_eq(HudNumbers.squad_name(5), "Squad 6", "sixth squad")
	assert_eq(HudNumbers.number(4, true), "IV", "Roman code still works when enabled")
	assert_eq(RomanNumerals.to_roman(0), RomanNumerals.ZERO_TEXT, "RomanNumerals kept")
	var hud := GameHud.new()
	assert_true(not hud.roman_numerals, "HUD follows the data setting")
	var director := MatchDirector.new()
	var pawn := Pawn.new()
	pawn.setup("hastati", 0)
	hud.bind(director, pawn)
	director.score_changed.emit({0: 0, 1: 0, 2: 7})
	assert_eq(hud.scores_label.text, "Squad 1: 0   Squad 2: 0   Squad 3: 7", "score 0 renders as 0")
	for ch in ["I", "V", "X", "N"]:
		assert_true(not hud.scores_label.text.replace("Squad", "").contains(ch), "no Roman letter " + ch)
	hud.free()
	pawn.free()
	director.free()


# ---- OQ-41 / OQ-27: manual IP, host IPs, host drop ---------------------------------------------

func test_manual_ip_field_is_prefilled_with_last_address() -> void:
	var svc := SaveService.new(_TMP)
	svc.save_profile({"gamertag": "Marcus", "last_ip": "192.168.43.1"})
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	menu.save = svc
	_tree().root.add_child(menu)
	assert_eq(menu.ip_edit.text, "192.168.43.1", "IP field pre-filled")
	menu.free()
	if FileAccess.file_exists(_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_TMP))
	AppFlow.lobby = null


func test_lobby_start_blocks_late_joins_and_host_drop_goes_to_menu_handler() -> void:
	var st := LobbyState.new()
	st.setup(2, 3)
	assert_true(st.add_human(1, "Host"), "join before start")
	assert_true(st.start(), "start")
	assert_true(not st.add_human(2, "Late"), "joining works only from the lobby")
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	m.lobby_override = LobbyState.new()  # keeps the test from leaving the scene
	_tree().root.add_child(m)
	await _tree().physics_frame
	m._on_host_lost()
	assert_true(m.host_lost_handled, "match reacts to a host drop")
	m.queue_free()


# ---- carried-over low: offline class from data, then the profile -------------------------------

func test_offline_class_comes_from_data_then_profile() -> void:
	var reg := DataRegistry.new()
	var from_data := MatchRoot.offline_class_id(reg, {"last_class": "sagittarii"})
	assert_eq(from_data, str(reg.load_file(DataRegistry.MATCH_PATH).get("default_class")), "data default wins")
	# Fallback: with the data default removed, the profile's last class is used.
	var fake := DataRegistry.new()
	fake._cache[DataRegistry.MATCH_PATH] = {"squads": 2}
	assert_eq(MatchRoot.offline_class_id(fake, {"last_class": "sagittarii"}), "sagittarii", "profile fallback")
	# A disabled or unknown class is ignored, the first enabled class in stats.json is used.
	assert_eq(MatchRoot.offline_class_id(fake, {"last_class": "gladiator"}), "hastati", "disabled class ignored")
	assert_eq(MatchRoot.offline_class_id(fake, {}), "hastati", "first enabled class")
