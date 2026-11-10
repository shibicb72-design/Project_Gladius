extends "res://tests/test_case.gd"
## Step 3 D6 (Shibi, Nov 9 2026): "a healing item, slow health regeneration". The Bandage loot item heals at pickup;
## health climbs slowly after a quiet spell, never while DOWNED. Numbers are placeholders in data.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const CFG := {"shield_regen_delay_s": 5.0, "shield_regen_rate_per_s": 25.0, "health_regen_delay_s": 8.0, "health_regen_rate_per_s": 1.0}


func _hurt_state() -> HealthState:
	var s := HealthState.create(100.0, 100.0)
	s.health = 50.0
	return s


func test_health_waits_for_the_delay_then_climbs_at_the_rate() -> void:
	var s := _hurt_state()
	DamageRules.tick_regen(s, 7.0, CFG)
	assert_true(absf(s.health - 50.0) < 1e-4, "no health regen before health_regen_delay_s (%s)" % s.health)
	DamageRules.tick_regen(s, 3.0, CFG)
	assert_true(absf(s.health - 52.0) < 1e-4, "2 s past the delay at 1/s: +2 (%s)" % s.health)
	DamageRules.tick_regen(s, 1000.0, CFG)
	assert_true(absf(s.health - 100.0) < 1e-4, "capped at max health")


func test_damage_restarts_the_wait_and_no_rate_means_no_regen() -> void:
	var s := _hurt_state()
	DamageRules.tick_regen(s, 9.0, CFG)
	var after := s.health
	s.time_since_damage = 0.0  # what a hit does
	DamageRules.tick_regen(s, 7.0, CFG)
	assert_true(absf(s.health - after) < 1e-4, "a hit restarts the wait")
	var old := _hurt_state()
	DamageRules.tick_regen(old, 100.0, {"shield_regen_delay_s": 5.0, "shield_regen_rate_per_s": 25.0})
	assert_true(absf(old.health - 50.0) < 1e-4, "no health_regen_rate_per_s: health stays (shield-only regen as before)")


func test_shield_still_refills_first_as_before() -> void:
	var s := HealthState.create(100.0, 100.0)
	s.shield = 0.0
	DamageRules.tick_regen(s, 6.0, CFG)
	assert_true(absf(s.shield - 25.0) < 1e-4, "shield: 1 s past its 5 s delay at 25/s (%s)" % s.shield)


func test_no_health_regen_while_downed() -> void:
	var b := PawnRulesBridge.new(null, 0, CFG)
	b.state = _hurt_state()
	b.downed = true
	b.tick(100.0)
	assert_true(absf(b.state.health - 50.0) < 1e-4, "DOWNED: no regen")


## Review follow-up: the regen wait does not run while DOWNED, so a revived pawn (hit just before going down) still
## waits the full health_regen_delay_s after the revive.
func test_after_a_revive_health_waits_the_full_delay() -> void:
	var b := PawnRulesBridge.new(null, 0, CFG)
	b.state = _hurt_state()
	b.state.time_since_damage = 0.0  # the downing hit
	b.downed = true
	b.tick(30.0)
	assert_true(absf(b.state.time_since_damage) < 1e-6, "the wait does not run while DOWNED")
	b.downed = false  # revived
	b.tick(7.0)
	assert_true(absf(b.state.health - 50.0) < 1e-4, "7 s after the revive: still waiting")
	b.tick(2.0)
	assert_true(absf(b.state.health - 51.0) < 1e-4, "1 s past the delay: +1 (%s)" % b.state.health)


func test_shipped_data_has_slow_regen_and_a_bandage() -> void:
	var reg := DataRegistry.new()
	var combat := reg.get_combat_cfg()
	assert_true(float(combat.get("health_regen_rate_per_s", 0.0)) > 0.0, "stats.json combat ships health regen")
	assert_true(float(combat.get("health_regen_rate_per_s", 0.0)) < float(combat["shield_regen_rate_per_s"]), "health regen is slower than shield regen")
	var item: Dictionary = reg.load_file("res://data/loot.json")["items"].get("bandage", {})
	assert_eq(str(item.get("kind", "")), "heal", "loot.json has the Bandage heal item")
	assert_true(float(item.get("health_pct", 0.0)) > 0.0, "it heals")


func test_bandage_heals_at_pickup_only_when_hurt() -> void:
	var p: Pawn = _PawnScene.instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(p)
	p.set_physics_process(false)
	var item: Dictionary = DataRegistry.new().load_file("res://data/loot.json")["items"]["bandage"]
	var st := p.bridge.state
	assert_true(not p.can_take(item), "full health: the Bandage stays on the ground")
	st.health = st.max_health * 0.3
	assert_true(p.can_take(item) and p.wants_item(item), "hurt: humans and bots take it")
	var below := float(DataRegistry.new().load_file("res://data/bots.json")["brain"]["heal_below_health_pct"])
	st.health = st.max_health * (below + 5.0) / 100.0
	assert_true(p.can_take(item) and not p.wants_item(item, 2.0, below), "barely hurt: a human may take it, a bot does not detour")
	st.health = st.max_health * 0.3
	p.take_item({}, item)
	var want := minf(st.max_health, st.max_health * (0.3 + float(item["health_pct"]) / 100.0))
	assert_true(absf(st.health - want) < 1e-3, "healed by health_pct of max (%s vs %s)" % [st.health, want])
	st.health = st.max_health - 1.0
	p.take_item({}, item)
	assert_true(absf(st.health - st.max_health) < 1e-4, "never above max health")
	p.queue_free()
