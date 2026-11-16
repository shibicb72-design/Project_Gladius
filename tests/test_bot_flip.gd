extends "res://tests/test_case.gd"
## M2B3 (OQ-BOT-FLIP): the goal flip at the zone edge. A bot whose loot / gear / hunt target lies just outside
## 0.85 x the next circle's radius turned round every step: inside the edge the outside goal won, outside it the
## zone goal came back. The brains under test are driven by hand (as in tests/test_bot_route.gd); every bot's own
## Brain is switched off. The flip runs: one think per physics tick for 10 s (600 thinks), and after each think the
## pawn is moved toward the returned goal by its class move speed / 60 (flat; a "hold" does not move), with no
## physics step in between (director ticks do not advance, so the zone timer and the hunt memory age stand still).

const _MatchScene := preload("res://scenes/match/match.tscn")
const THINKS := 600  # 10 s at 60 thinks per second
const NEXT_R := 40.0  # next circle radius: the 0.85 edge lies 34 m from its centre

var m: MatchRoot


func tree() -> SceneTree:
	return Engine.get_main_loop()


func frames(n: int) -> void:
	for i in n:
		await tree().physics_frame


## A big zone (start radius 400 > big_map_radius_m) whose first wait is `wait_s` and whose next circle is 40 m.
## A 5 s wait makes the zone "call" on a big map: the walk to the spot (at least rotate_margin_s) outlasts it.
static func edge_zone(start_r: float = 400.0, wait_s: float = 5.0) -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": start_r, "damage_skips_shield": false,
			"phases": [{"wait_s": wait_s, "shrink_s": 200.0, "radius_m": NEXT_R, "damage_per_s": 0.0}]}


## A match on the test map with every bot brain off and every bot parked out of sight; the human far away.
## The next circle's centre is pinned to `center` (the seeded one may lie off the test ground). All loot is taken.
func start(zone: Dictionary, center: Vector2) -> void:
	m = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.ground_loot = true
	tree().root.add_child(m)
	await tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = "solo"
	assert_true(m.begin(), "begin")
	var i := 0
	for b in m.bots:
		b.get_node("Brain").set_physics_process(false)
		b.set_frame(InputFrame.new())
		b.global_position = Vector3(-70.0 + float(i % 6) * 4.0, 0.2, 60.0 + float(i / 6) * 4.0)
		b.visible = false
		i += 1
	m.local_player.global_position = Vector3(70.0, 0.2, -70.0)
	m.local_player.visible = false
	await frames(2)
	m.director.rules._circles[0]["center"] = center
	for id in m.loot.items.keys():
		m.loot.take(id)


func base_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).duplicate(true)


func add_brain(pawn: Pawn, cfg: Dictionary = {}, tag: String = "") -> BotBrain:
	var profile: Dictionary = DataRegistry.new().load_file("res://data/bots.json").get("profiles", {}).get("tiro", {})
	var b := BotBrain.new()
	b.name = "Test" + tag
	b.setup(pawn, m.director, profile, cfg if not cfg.is_empty() else base_cfg())
	pawn.add_child(b)
	b.set_physics_process(false)
	b._ensure_seeded()
	return b


func gear_up(p: Pawn) -> void:
	p.armor_tier = 1
	var gun := p.loadout.get_active()
	gun.reserve = int(ceil(gun.def.magazine * m.director.bot_ammo_low_magazines())) + 5


## A point `d` metres from the next circle's centre along +x.
func at_r(d: float, y: float = 0.0) -> Vector3:
	var c := m.director.zone_target_center()
	return Vector3(c.x + d, y, c.z)


static func flat_d(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func flat_r(p: Vector3) -> float:
	var c := m.director.zone_target_center()
	return Vector2(p.x - c.x, p.z - c.z).length()


## Runs the hand-driven flip loop; returns [goal_kind changes, the kinds seen in order (deduplicated runs)].
func run_flip(bot: Pawn, b: BotBrain) -> Array:
	var step := bot.get_move_speed() / 60.0
	var changes := 0
	var prev := ""
	var seen: Array = []
	for t in THINKS:
		var g := b._goal(null, b._melee_only())
		if b.goal_kind != prev:
			if prev != "":
				changes += 1
			prev = b.goal_kind
			if seen.size() < 12:
				seen.append(b.goal_kind)
		if b.goal_kind == "hold":
			continue
		var to := Vector3(g.x - bot.global_position.x, 0.0, g.z - bot.global_position.z)
		if to.length() <= step:
			bot.global_position = Vector3(g.x, bot.global_position.y, g.z)
		else:
			bot.global_position += to.normalized() * step
	return [changes, seen]


# ---- The three flip cases: the wanted thing just outside the edge, the zone calling ----

## A wanted armour 37 m from the next circle's centre; the ungeared bot starts 35 m out (just outside the edge).
func test_loot_outside_the_edge_does_not_flip() -> void:
	await start(edge_zone(), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	bot.armor_tier = 0
	bot.global_position = at_r(35.0, 0.2)
	m.loot.drop({"item_id": "armor_1"}, at_r(37.0))
	var b := add_brain(bot)
	assert_true(b.is_big_map(), "big map")
	var r := run_flip(bot, b)
	print("FLIP loot changes=%d kinds=%s" % [r[0], r[1]])
	assert_true(int(r[0]) <= 1, "loot outside the edge: at most 1 goal change in 10 s (%d, %s)" % [r[0], r[1]])
	m.queue_free()


## A gear landmark (aqua_alta, anchor 42.5, -29) whose anchor lies 37 m from the next circle's centre; loot out of
## reach (loot_seek_range_m 5) so only the gear goal wants out.
func test_gear_outside_the_edge_does_not_flip() -> void:
	await start(edge_zone(), Vector2(5.5, -29.0))
	m.loot.drop({"item_id": "armor_1"}, Vector3(44.0, 0.0, -38.0))  # inside aqua_alta
	var bot: Pawn = m.bots[0]
	bot.armor_tier = 0
	bot.global_position = at_r(35.0, 0.2)
	var cfg := base_cfg()
	cfg["loot_seek_range_m"] = 5.0
	cfg["route"]["landmark_pick_k"] = 1
	var b := add_brain(bot, cfg)
	assert_true(absf(flat_r(Vector3(42.5, 0.0, -29.0)) - 37.0) < 0.01, "the anchor lies 37 m from the centre")
	var r := run_flip(bot, b)
	print("FLIP gear changes=%d kinds=%s landmark=%s" % [r[0], r[1], b.landmark_id()])
	assert_eq(b.landmark_id(), "aqua_alta", "the landmark with loot")
	assert_true(int(r[0]) <= 1, "gear outside the edge: at most 1 goal change in 10 s (%d, %s)" % [r[0], r[1]])
	m.queue_free()


## A fresh hunt memory 38 m from the next circle's centre; the geared bot starts 35 m out. hunt_arrive_m is cut to
## 2 m so the memory, 3 m beyond the bot on the same ray, is not "reached" at the start (with the shipped 15 m a
## memory just outside the edge is forgotten before the bot gets near the edge from inside).
func test_hunt_outside_the_edge_does_not_flip() -> void:
	await start(edge_zone(), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	gear_up(bot)
	bot.global_position = at_r(35.0, 0.2)
	var cfg := base_cfg()
	cfg["route"]["hunt_arrive_m"] = 2.0
	var b := add_brain(bot, cfg)
	assert_true(b.is_geared(), "geared")
	b._remember_enemy(at_r(38.0))
	var r := run_flip(bot, b)
	print("FLIP hunt changes=%d kinds=%s" % [r[0], r[1]])
	assert_true(int(r[0]) <= 1, "hunt outside the edge: at most 1 goal change in 10 s (%d, %s)" % [r[0], r[1]])
	m.queue_free()


# ---- Goals inside the edge, the exemption, small maps ----

## Inside the edge a goal is still taken: an armour 30 m out; with one item outside (36 m, nearer to the bot) and
## one inside (20 m, farther), the inside one is chosen; a hunt memory inside the edge is followed.
func test_goals_inside_the_edge_are_still_taken() -> void:
	await start(edge_zone(), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	bot.armor_tier = 0
	bot.global_position = at_r(25.0, 0.2)
	var inner := at_r(30.0)
	var id := m.loot.drop({"item_id": "armor_1"}, inner)
	var b := add_brain(bot)
	assert_true(b._zone_calls(), "the zone calls (a 5 s wait is shorter than any walk)")
	var g := b._goal(null, false)
	assert_eq(b.goal_kind, "loot", "an item inside the edge is taken")
	assert_true(flat_d(g, inner) < 0.01, "that item")
	m.loot.take(id)
	bot.global_position = at_r(30.0, 0.2)
	m.loot.drop({"item_id": "armor_1"}, at_r(36.0))
	var far_in := at_r(20.0)
	m.loot.drop({"item_id": "armor_1"}, far_in)
	g = b._goal(null, false)
	assert_true(b.goal_kind == "loot" and flat_d(g, far_in) < 0.01, "the farther item inside the edge, not the nearer one outside (%s %s)" % [b.goal_kind, g])
	m.queue_free()
	# Hunt: a geared bot, a fresh memory 30 m out, 20 m from the bot.
	await start(edge_zone(), Vector2.ZERO)
	bot = m.bots[0]
	gear_up(bot)
	bot.global_position = at_r(10.0, 0.2)
	b = add_brain(bot)
	var mem := at_r(30.0)
	b._remember_enemy(mem)
	g = b._goal(null, false)
	assert_true(b.goal_kind == "hunt" and flat_d(g, mem) < 0.01, "a memory inside the edge is hunted (%s %s)" % [b.goal_kind, g])
	m.queue_free()


## gun_first is exempt: an unarmed bot inside the edge still walks to a gun outside it.
func test_gun_first_is_exempt() -> void:
	await start(edge_zone(), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	bot.apply_start_kit({"secondary": "gladius_lux"})
	bot.global_position = at_r(30.0, 0.2)
	var gun := at_r(37.0)
	m.loot.drop({"item_id": "pilum_br"}, gun)
	var b := add_brain(bot)
	assert_true(b._melee_only(), "blade only")
	assert_true(b._zone_calls() and b._inside_target(), "the zone calls and the bot is inside")
	var g := b._goal(null, b._melee_only())
	assert_true(b.goal_kind == "loot" and flat_d(g, gun) < 0.01, "the gun outside the edge (%s %s)" % [b.goal_kind, g])
	m.queue_free()


## Hysteresis: 0.82 x r is outside for a bot coming from outside and inside for one coming from inside; a new
## next circle and a skipped (dead) think reset the state, which is then judged at the enter edge.
func test_hysteresis_and_resets() -> void:
	await start(edge_zone(), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	assert_eq(float(b._route_f("inside_enter_frac", 0.0)), 0.80, "shipped enter 0.80")
	assert_eq(float(b._route_f("inside_leave_frac", 0.0)), 0.85, "shipped leave 0.85")
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "unknown, 0.82: judged at the enter edge, outside")
	assert_true(not b._inside_target(), "idempotent")
	bot.global_position = at_r(0.79 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "0.79: inside")
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "0.82 coming from inside: inside")
	assert_true(b._inside_target(), "idempotent")
	bot.global_position = at_r(0.86 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "0.86: outside")
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "0.82 coming from outside: outside")
	# A new next circle: reset.
	bot.global_position = at_r(0.5 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "inside")
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "0.82 from inside: inside")
	m.director.rules._circles[0]["center"] = Vector2(0.0, 0.01)
	assert_true(not b._inside_target(), "the next circle changed: judged afresh at the enter edge, outside")
	bot.global_position = at_r(0.5 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "inside again")
	m.director.rules._circles[0]["radius"] = NEXT_R + 0.001
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "the radius changed: judged afresh, outside")
	m.director.rules._circles[0]["radius"] = NEXT_R
	# A dead think (build_frame's early return): reset.
	bot.global_position = at_r(0.5 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "inside")
	bot.global_position = at_r(0.82 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "0.82 from inside: inside")
	bot.life = Pawn.Life.DEAD
	b.build_frame(1.0 / 60.0)
	bot.life = Pawn.Life.ALIVE
	assert_true(not b._inside_target(), "after a dead think: judged afresh, outside")
	m.queue_free()


## A small map and missing keys use 0.85 for both edges (stateless); enter above leave is cut to leave.
func test_small_map_missing_keys_and_guard_use_one_edge() -> void:
	await start(edge_zone(80.0, 1000.0), Vector2.ZERO)
	var bot: Pawn = m.bots[0]
	var b := add_brain(bot)
	assert_true(not b.is_big_map(), "start radius 80: small map")
	bot.global_position = at_r(0.84 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "small: 0.84 inside")
	bot.global_position = at_r(0.86 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "small: 0.86 outside")
	bot.global_position = at_r(0.84 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "small: 0.84 from outside, inside")
	m.queue_free()
	await start(edge_zone(), Vector2.ZERO)
	bot = m.bots[0]
	var bare := base_cfg()
	bare["route"].erase("inside_enter_frac")
	bare["route"].erase("inside_leave_frac")
	b = add_brain(bot, bare, "Bare")
	assert_true(b.is_big_map(), "big map")
	bot.global_position = at_r(0.84 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "no keys: 0.84 from unknown, inside")
	bot.global_position = at_r(0.86 * NEXT_R, 0.2)
	assert_true(not b._inside_target(), "no keys: 0.86 outside")
	bot.global_position = at_r(0.84 * NEXT_R, 0.2)
	assert_true(b._inside_target(), "no keys: 0.84 from outside, inside")
	var swapped := base_cfg()
	swapped["route"]["inside_enter_frac"] = 0.9
	swapped["route"]["inside_leave_frac"] = 0.85
	var s := add_brain(bot, swapped, "Swapped")
	bot.global_position = at_r(0.87 * NEXT_R, 0.2)
	assert_true(not s._inside_target(), "enter 0.9 > leave 0.85: enter cut to 0.85, 0.87 outside")
	bot.global_position = at_r(0.84 * NEXT_R, 0.2)
	assert_true(s._inside_target(), "guarded: 0.84 inside")
	m.queue_free()


## A small map keeps today's goals: inside the edge with the zone calling, an item outside the edge is still taken.
func test_small_map_takes_loot_outside_the_edge() -> void:
	await start(edge_zone(80.0, 20.0), Vector2.ZERO)  # 20 s left < zone_margin_s 25: the zone calls
	var bot: Pawn = m.bots[0]
	bot.armor_tier = 0
	bot.global_position = at_r(30.0, 0.2)
	var item := at_r(37.0)
	m.loot.drop({"item_id": "armor_1"}, item)
	var b := add_brain(bot)
	assert_true(not b.is_big_map() and b._zone_calls(), "small map, the zone calls")
	var g := b._goal(null, false)
	assert_true(b.goal_kind == "loot" and flat_d(g, item) < 0.01, "small map: the item outside the edge, as before (%s %s)" % [b.goal_kind, g])
	m.queue_free()
