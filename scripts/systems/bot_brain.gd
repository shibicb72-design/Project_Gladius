class_name BotBrain
extends Node
## Child of a bot Pawn. Builds an InputFrame each physics tick from perception; never reads player input.
## Battle royale brain (M1 S5; every tuning number is a placeholder in data/bots.json "brain", OQ-31):
##   fight: shoot the nearest visible standing enemy; with only the blade, charge it when close; with no
##     standing enemy in sight, finish a visible DOWNED enemy (finish_downed, OQ-BR-DOWNED).
##   move, first goal that applies: revive a DOWNED squad mate within revive_seek_range_m (no enemy in
##     sight); get inside the next circle when outside it and the zone is shrinking, has under zone_margin_s
##     left, or the bot is outside the current circle; go for the nearest usable loot within
##     loot_seek_range_m (guns first when it has none); otherwise its own spot inside the next circle.
##   unstick: barely moved over stuck_window_s while walking -> jump and sidestep for unstick_s.
## Pickups happen in MatchDirector when a bot stands on an item; revives through director.begin_revive.
## A DOWNED, dropping or dead bot does nothing.
## Think rate (M2P1C stop 7): far from every human a bot decides only every few ticks (see next_frame).

var pawn: Pawn
var director: MatchDirector
var profile: Dictionary = {}
var cfg: Dictionary = {}
var target_id: int = -1
## Last goal kind, for tests and debugging: "revive", "zone", "loot", "hold", "chase" or ""; on a big map also
## "gear" (M2B1).
var goal_kind: String = ""

var _agent: NavigationAgent3D
var _rng := RandomNumberGenerator.new()
var _seen_for_s: float = 0.0
var _error: Vector2 = Vector2.ZERO
var _error_age_s: float = 0.0
var _spot_dir := Vector2.ZERO  # this bot's own direction inside the next circle
var _stuck_from := Vector3.ZERO
var _stuck_t: float = 0.0
var _unstick_left: float = 0.0
var _unstick_side: float = 1.0
var _seeded: bool = false
var _swap_cooldown: float = 0.0

## ---- Think rate (M2P1C stop 7, data/bots.json brain.think_rate, placeholder OQ-BOT-THINK) ----
## A bot farther than far_distance_m from every human runs a full think (build_frame) only on its cadence
## ticks: (director.tick_count + player_id) % far_interval_ticks == 0. On the ticks between it "coasts"
## (_coast_frame): movement, look, timers and path following still run every tick on the last decision.
## Cadence source: MatchDirector.tick_count, the director's own count of rule ticks; it is 0 when the
## director is made (one director per match), advances by exactly one per physics tick while the match
## runs, and is shared by every brain of the match, so the player_id stagger holds even for a brain made
## later. No engine-global or static counter: two matches in one process see the same sequence.
## While the match is not running (before start, after match_over, a network client) every tick thinks.
## Feature off (far_interval_ticks <= 1, far_distance_m <= 0 or no block): every tick thinks, as before.
## Report and test counters: ticks on which this bot was alive and grounded, and how many were full thinks.
var brain_ticks: int = 0
var think_ticks: int = 0
## Sim CPU proxy (M2B1, report only): microseconds spent in build_frame / _coast_frame on grounded ticks (the
## brain_ticks condition). Wall clock, so it never enters a deterministic comparison; it changes no decision.
var brain_usec: int = 0
var _near: bool = true  # a human within far_distance_m at the last check
var _has_decision: bool = false  # build_frame ran its full grounded branch since the last early return
var _last_goal := Vector3.ZERO  # the walk goal chosen at the last think
var _last_goal_active: bool = false  # false: the last think held still ("hold")
var _last_enemy: bool = false  # an enemy was in sight at the last think (the aim timers run)
var _last_look: bool = false  # the last think turned toward something
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0

## ---- Route (M2B1, data/bots.json brain.route, placeholders OQ-BOT-ROUTE) ----
## Big map: the zone's start radius (rules.zone_radius() while phase 0 is "waiting", cached at seeding) is above
## route.big_map_radius_m. Only then do the gear / hunt / fight goals and the landmark glide run; on a small map
## (or with no rules, or a brain seeded after the first shrink began) every goal and result is the pre-M2B1 one.
## Every new seeded draw comes from _route_rng (hash([match_seed, player_id, "route"])), never from _rng (aim).
var _route_rng := RandomNumberGenerator.new()
var _big_map: bool = false
var _landmarks_cache: Array = []  # director.loot_landmarks(), copied once
var _landmarks_loaded: bool = false
var _landmark: Dictionary = {}  # the chosen landmark ({} = none): {"id", "at" Vector3, "radius" float}
var _landmark_picked: bool = false  # a pick was made (it may have found none)
var _jump_seen: bool = false  # this bot was FALLING at some think (dropped from the carrier)
var _jump_from := Vector3.ZERO  # its position at the first FALLING think
var _gear_check_tick: int = 0  # director.tick_count at or after which the chosen landmark is re-checked
## Report only (the sims read them; no decision depends on them).
var route_landed_at := Vector3.INF  # position at the first grounded think after the drop
var route_geared_ever: bool = false
var route_landed_in_pick: bool = false  # route_landed_at lies inside the landmark held at that moment


func setup(new_pawn: Pawn, new_director: MatchDirector, new_profile: Dictionary, new_cfg: Dictionary) -> void:
	pawn = new_pawn
	director = new_director
	profile = new_profile
	cfg = new_cfg


## Seeds this bot from the match seed and its player id (G0: the same match seed replays the same bots).
## Called lazily on the first frame, once MatchDirector.start has set match_seed and player_id.
func _ensure_seeded() -> void:
	if _seeded:
		return
	_seeded = true
	_rng.seed = hash([director.match_seed if director != null else 0, pawn.player_id, "brain"])  # own stream, apart from the pawn's spread
	var a := _rng.randf() * TAU
	_spot_dir = Vector2(cos(a), sin(a)) * sqrt(_rng.randf())
	_route_rng.seed = hash([director.match_seed if director != null else 0, pawn.player_id, "route"])
	var rules: BrRules = director.rules if director != null else null
	_big_map = rules != null and rules.zone_phase() == 0 and rules.zone_state() == "waiting" \
			and rules.zone_radius() > _route_f("big_map_radius_m", 250.0)


## A number from bots.json brain.route (placeholder block, OQ-BOT-ROUTE).
func _route_f(key: String, default: float) -> float:
	return float(cfg.get("route", {}).get(key, default))


## True on a big map (see the Route block); read by tests and the sims.
func is_big_map() -> bool:
	return _big_map


func _ready() -> void:
	_agent = NavigationAgent3D.new()
	_agent.path_desired_distance = float(cfg.get("path_desired_distance_m", 1.0))
	_agent.target_desired_distance = float(cfg.get("target_desired_distance_m", 1.0))
	pawn.add_child(_agent)


func _physics_process(delta: float) -> void:
	pawn.set_frame(next_frame(delta))


## This tick's frame: a full think (build_frame) on think ticks, else a coast on the last decision.
func next_frame(delta: float) -> InputFrame:
	var grounded := pawn != null and pawn.is_alive() and pawn.is_inside_tree() and not pawn.is_dropping()
	if grounded:
		brain_ticks += 1
	var frame: InputFrame
	var t0 := 0
	if should_think():
		if grounded:
			think_ticks += 1
		t0 = Time.get_ticks_usec()
		frame = build_frame(delta)
	else:
		t0 = Time.get_ticks_usec()
		frame = _coast_frame(delta)
	if grounded:
		brain_usec += Time.get_ticks_usec() - t0
	return frame


func _far_interval() -> int:
	return int(cfg.get("think_rate", {}).get("far_interval_ticks", 1))


func _far_distance() -> float:
	return float(cfg.get("think_rate", {}).get("far_distance_m", 0.0))


## True when this tick is a full think. Dead, dropping and falling bots always "think" (build_frame's
## early returns are cheap and unchanged), as does the first grounded tick (no decision to keep yet).
## The near check runs on the cadence ticks only (and on that first tick): a far bot that a human
## approaches notices on its next cadence tick, at most far_interval_ticks - 1 ticks late, and then thinks
## every tick; a near bot that the human leaves keeps thinking every tick until its next cadence tick.
func should_think() -> bool:
	var interval := _far_interval()
	var dist := _far_distance()
	if interval <= 1 or dist <= 0.0 or director == null or not director.running:
		return true
	if pawn == null or not pawn.is_alive() or not pawn.is_inside_tree() or pawn.is_dropping():
		return true
	if not _has_decision:
		_near = _human_within(dist)
		return true
	if posmod(director.tick_count + pawn.player_id, interval) == 0:
		_near = _human_within(dist)
		return true
	return _near


## An ALIVE human pawn (no Brain child, the director's own bot test) lies within dist_m.
## Only ALIVE humans count (the slice's binding rule); a DOWNED, DEAD or spectating human does not, although a
## downed human still watches the fight around it (open for Shibi, OQ-BOT-THINK).
## The local idle human of the sim counts, also while aboard the carrier. No human at all:
## every bot is far. Squared 3D distances over a handful of pawns.
func _human_within(dist_m: float) -> bool:
	var d2 := dist_m * dist_m
	var here := pawn.global_position
	var players := director.all_players()
	for id in players:
		var p: Pawn = players[id]
		if p == pawn or p.life != Pawn.Life.ALIVE or not p.is_inside_tree() or p.has_node("Brain"):
			continue
		if p.global_position.distance_squared_to(here) <= d2:
			return true
	return false


## A far bot's tick between thinks. Field by field against build_frame:
##   move: follows the NavigationAgent3D path toward the last decided goal (re-asked every tick, so the
##     world-space direction is re-expressed in the pawn's current local frame); hold -> no move; the
##     unstick sidestep and its timer run as in build_frame.
##   look: BotTargeting.look_toward the last decided yaw and pitch with this tick's turn budget (frame.look
##     is a per-tick delta, never reused).
##   one-shots (jump_just_pressed, swap_weapon_just_pressed, reload_just_pressed, fire_just_pressed): false.
##   held: jump_pressed stays true while the unstick runs (it follows the timer, not a stale decision);
##     reload_pressed false (the pawn acts only on reload_just_pressed); fire_pressed FALSE: a far bot never
##     fires on a coast tick, so it never shoots at a stale aim. A burst already started still finishes
##     (Weapon.update ends running bursts without the trigger); the cost is that a new burst starts on the
##     first think tick after the gun's cooldown, at most far_interval_ticks - 1 ticks late.
##   timers: _seen_for_s and _error_age_s (while the last think saw an enemy; the aim error is redrawn on
##     the tick its age runs out, as build_frame would, and the kept yaw/pitch shift by the change),
##     _swap_cooldown, _unstick_left and the stuck window _stuck_t all advance by delta. Whether the bot is
##     stuck is judged at the next think (_track_stuck), so the unstick, and its jump, start on a think tick.
func _coast_frame(delta: float) -> InputFrame:
	var frame := InputFrame.new()
	if _last_enemy:
		_seen_for_s += delta
		_error_age_s -= delta
		if _error_age_s <= 0.0:
			var old := _error
			_error = BotTargeting.aim_error(float(profile.get("accuracy", 0.3)),
					float(cfg.get("max_aim_error_deg", 12.0)), _rng)
			_error_age_s = float(cfg.get("aim_error_refresh_s", 0.5))
			_last_yaw += _error.x - old.x
			_last_pitch += _error.y - old.y
	_swap_cooldown = maxf(_swap_cooldown - delta, 0.0)
	var move_dir := _follow_path(delta)
	if _unstick_left > 0.0:
		_unstick_left -= delta
		var side := pawn.global_transform.basis.x * _unstick_side
		move_dir = (move_dir + side).normalized() if move_dir != Vector3.ZERO else side
		frame.jump_pressed = true
	if move_dir != Vector3.ZERO:
		var local := pawn.global_transform.basis.inverse() * move_dir
		frame.move = Vector2(local.x, local.z).limit_length(1.0)
	if _last_look:
		var turn: float = float(cfg.get("turn_rate_rad_s", 6.0)) * delta
		frame.look = BotTargeting.look_toward(pawn.rotation.y, pawn.pitch, _last_yaw, _last_pitch, turn)
	return frame


## The path-following half of _move_direction, toward the last decided goal (the goal itself is chosen
## only on think ticks).
func _follow_path(delta: float) -> Vector3:
	if not _last_goal_active:
		_stuck_t = 0.0
		return Vector3.ZERO
	var to_goal := _last_goal - pawn.global_position
	to_goal.y = 0.0
	if to_goal.length() < 0.3:
		_stuck_t = 0.0
		return Vector3.ZERO
	if _unstick_left <= 0.0:
		if _stuck_t == 0.0:
			_stuck_from = pawn.global_position  # a stuck window starts here (M2B1: not at the world origin)
		_stuck_t += delta
	if _agent.target_position != _last_goal:
		_agent.target_position = _last_goal
	var next := _agent.get_next_path_position()
	var dir := next - pawn.global_position
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = to_goal
	return dir.normalized()


func build_frame(delta: float) -> InputFrame:
	var frame := InputFrame.new()
	if pawn == null or not pawn.is_alive() or not pawn.is_inside_tree():
		_has_decision = false
		return frame
	_ensure_seeded()
	if pawn.drop_state == Pawn.Drop.FALLING:
		_has_decision = false
		# Steer the glide toward this bot's own spot inside the next circle; on a big map toward its landmark.
		var to := _glide_goal() - pawn.global_position
		to.y = 0.0
		if to.length() > 1.0:
			var local := pawn.global_transform.basis.inverse() * to.normalized()
			frame.move = Vector2(local.x, local.z).limit_length(1.0)
		return frame
	if pawn.is_dropping():
		_has_decision = false
		return frame
	if _big_map:
		_route_think()
	var turn: float = float(cfg.get("turn_rate_rad_s", 6.0)) * delta
	var enemy := _find_target()
	var melee_only := _melee_only()
	var want_dir := Vector3.ZERO
	if enemy != null:
		_seen_for_s += delta
		_error_age_s -= delta
		if _error_age_s <= 0.0:
			_error = BotTargeting.aim_error(float(profile.get("accuracy", 0.3)),
					float(cfg.get("max_aim_error_deg", 12.0)), _rng)
			_error_age_s = float(cfg.get("aim_error_refresh_s", 0.5))
		var aim_pt: Vector3 = enemy.global_position + Vector3(0.0, _target_height(), 0.0)
		want_dir = (aim_pt - (pawn.global_position + Vector3(0.0, _eye_height(), 0.0))).normalized()
	else:
		_seen_for_s = 0.0
		_error_age_s = 0.0
		_error = Vector2.ZERO

	_manage_weapon(frame, delta)
	var move_dir := _move_direction(enemy, melee_only, delta)
	if _unstick_left > 0.0:
		_unstick_left -= delta
		var side := pawn.global_transform.basis.x * _unstick_side
		move_dir = (move_dir + side).normalized() if move_dir != Vector3.ZERO else side
		frame.jump_pressed = true
		frame.jump_just_pressed = _unstick_left > float(cfg.get("unstick_s", 1.0)) - delta * 1.5
	if move_dir != Vector3.ZERO:
		var local := pawn.global_transform.basis.inverse() * move_dir
		frame.move = Vector2(local.x, local.z).limit_length(1.0)
		if enemy == null:
			want_dir = move_dir

	# The decision a far bot keeps until its next think (_coast_frame); the goal is kept in _move_direction.
	_has_decision = true
	_last_enemy = enemy != null
	_last_look = want_dir != Vector3.ZERO
	if want_dir != Vector3.ZERO:
		var yaw := BotTargeting.yaw_of(want_dir) + (_error.x if enemy != null else 0.0)
		var pitch := BotTargeting.pitch_of(want_dir) + (_error.y if enemy != null else 0.0)
		_last_yaw = yaw
		_last_pitch = pitch
		frame.look = BotTargeting.look_toward(pawn.rotation.y, pawn.pitch, yaw, pitch, turn)
		if enemy != null and _seen_for_s >= float(profile.get("reaction_time_s", 0.5)):
			var aimed := absf(wrapf(yaw - pawn.rotation.y, -PI, PI)) < deg_to_rad(float(cfg.get("fire_cone_deg", 6.0)))
			var in_reach := not melee_only or _flat_dist(enemy) <= _melee_reach()
			frame.fire_pressed = aimed and in_reach
			frame.fire_just_pressed = frame.fire_pressed
	return frame


## G1: reload an empty gun that has reserve; swap away from a gun with no ammo at all, and from the blade
## to a gun that has ammo. swap_cooldown_s (bots.json brain, placeholder) stops swap thrashing.
func _manage_weapon(frame: InputFrame, delta: float) -> void:
	_swap_cooldown = maxf(_swap_cooldown - delta, 0.0)
	var lo := pawn.loadout
	if lo == null:
		return
	var w := lo.get_active()
	var gun_with_ammo := false
	for s in lo.slots:
		if s != null and not s.def.is_melee() and s.ammo_in_mag + s.reserve > 0:
			gun_with_ammo = true
	if w != null and not w.def.is_melee():
		if w.ammo_in_mag == 0 and w.reserve > 0:
			if not w.reloading:
				frame.reload_pressed = true
				frame.reload_just_pressed = true
			return
		if w.ammo_in_mag + w.reserve == 0 and _swap_cooldown <= 0.0:
			frame.swap_weapon_just_pressed = true
			_swap_cooldown = _swap_cooldown_s()
		return
	if (w == null or w.def.is_melee()) and gun_with_ammo and _swap_cooldown <= 0.0:
		frame.swap_weapon_just_pressed = true
		_swap_cooldown = _swap_cooldown_s()


func _swap_cooldown_s() -> float:
	return float(cfg.get("swap_cooldown_s", 0.5))


func _eye_height() -> float:
	return float(cfg.get("eye_height_m", 1.3))


func _target_height() -> float:
	return float(cfg.get("target_height_m", 1.0))


func _melee_only() -> bool:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	return w == null or w.def.is_melee()


func _melee_reach() -> float:
	var w := pawn.loadout.get_active() if pawn.loadout != null else null
	return (w.def.melee_range_m if w != null and w.def.is_melee() else 2.0) * 1.1


func _flat_dist(other: Node3D) -> float:
	return Vector2(other.global_position.x - pawn.global_position.x, other.global_position.z - pawn.global_position.z).length()


## Nearest visible standing enemy; else (finish_downed) the nearest visible DOWNED enemy.
func _find_target() -> Pawn:
	var origin := pawn.global_position + Vector3(0.0, _eye_height(), 0.0)
	var standing: Array = []
	var downed: Array = []
	var space := pawn.get_world_3d().direct_space_state
	var players := director.all_players()
	for id in players:
		var other: Pawn = players[id]
		if other == pawn or not other.is_inside_tree() or not other.visible or other.is_dropping():
			continue
		if not other.is_alive() and not other.is_downed():
			continue
		var pos := other.global_position
		var q := PhysicsRayQueryParameters3D.create(origin, pos + Vector3(0.0, _target_height(), 0.0), Hitscan.MASK_WORLD)
		var seen := space.intersect_ray(q).is_empty()
		var c := {"id": id, "pos": pos, "squad": other.squad_id, "alive": true, "visible": seen}
		(standing if other.is_alive() else downed).append(c)
	var sight := float(cfg.get("sight_range_m", 60.0))
	target_id = BotTargeting.pick_target(pawn.global_position, pawn.squad_id, standing, sight)
	if target_id < 0 and bool(cfg.get("finish_downed", true)):
		target_id = BotTargeting.pick_target(pawn.global_position, pawn.squad_id, downed, sight)
	return players.get(target_id) if target_id >= 0 else null


## World-space direction to walk this tick (ZERO = stay).
func _move_direction(enemy: Pawn, melee_only: bool, delta: float) -> Vector3:
	var goal := _goal(enemy, melee_only)
	_last_goal = goal
	_last_goal_active = goal_kind != "hold"
	if goal_kind == "hold":
		_stuck_t = 0.0
		return Vector3.ZERO
	var to_goal := goal - pawn.global_position
	to_goal.y = 0.0
	if to_goal.length() < 0.3:
		_stuck_t = 0.0
		return Vector3.ZERO
	_track_stuck(delta)
	_agent.target_position = goal
	var next := _agent.get_next_path_position()
	var dir := next - pawn.global_position
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = to_goal  # no navmesh path: head straight for it
	return dir.normalized()


func _goal(enemy: Pawn, melee_only: bool) -> Vector3:
	var me := pawn.player_id
	# Blade only and an enemy close by: charge it.
	if enemy != null and melee_only and _flat_dist(enemy) <= float(cfg.get("melee_chase_m", 14.0)):
		goal_kind = "chase"
		return enemy.global_position
	# Revive a DOWNED squad mate (no enemy in sight).
	if enemy == null:
		var mate := _downed_mate()
		if mate != null:
			goal_kind = "revive"
			if director.revive_target_for(me) >= 0:
				director.begin_revive(me)
				goal_kind = "hold"
			return mate.global_position
	elif director.is_reviving(me):
		director.end_revive(me)
	# Unarmed: a gun comes first unless the bot is already outside the current circle (taking damage).
	var spot := _zone_spot()
	var here := Vector2(pawn.global_position.x, pawn.global_position.z)
	var hurting := director.rules != null and director.rules.is_outside(here)
	if melee_only and not hurting:
		var gun := _loot_goal(true)
		if gun != Vector3.INF:
			goal_kind = "loot"
			return gun
	# Zone pressure.
	if _zone_pressure():
		goal_kind = "zone"
		return spot
	# Loot.
	var item := _loot_goal()
	if item != Vector3.INF:
		goal_kind = "loot"
		return item
	# Big map: gear up at a landmark (M2B1).
	if _big_map:
		var gear := _gear_goal()
		if gear != Vector3.INF:
			goal_kind = "gear"
			return gear
	goal_kind = "zone"
	if _inside_target():
		goal_kind = "hold"
	return spot


func _downed_mate() -> Pawn:
	var best: Pawn = null
	var best_d := float(cfg.get("revive_seek_range_m", 18.0))
	for id in director.all_players():
		var p: Pawn = director.player(id)
		if p != pawn and p.squad_id == pawn.squad_id and p.is_downed():
			var d := _flat_dist(p)
			if d <= best_d:
				best = p
				best_d = d
	return best


## This bot's own point inside the next circle (zone_spot_fraction of its radius, seeded per bot).
func _zone_spot() -> Vector3:
	var c := director.zone_target_center()
	var r := director.zone_target_radius() * float(cfg.get("zone_spot_fraction", 0.6))
	return c + Vector3(_spot_dir.x, 0.0, _spot_dir.y) * r


func _inside_target() -> bool:
	var c := director.zone_target_center()
	return Vector2(pawn.global_position.x - c.x, pawn.global_position.z - c.z).length() <= director.zone_target_radius() * 0.85


func _zone_pressure() -> bool:
	if director.rules == null or _inside_target():
		return false
	var rules := director.rules
	var here := Vector2(pawn.global_position.x, pawn.global_position.z)
	# M2B1 stage 4: on a big map, while waiting, leave when the walk to the spot would outlast the wait
	# (_time_to_reach); a small map keeps the fixed zone_margin_s.
	var late := (_time_to_reach() > rules.zone_seconds_left()) if _big_map and rules.zone_state() == "waiting" \
			else rules.zone_seconds_left() < float(cfg.get("zone_margin_s", 25.0))
	return rules.zone_state() != "waiting" or late or rules.is_outside(here)


## Big map rotation (M2B1, brain.route, placeholders OQ-BOT-ROUTE): seconds this bot needs to walk to its zone
## spot = flat distance / its class move speed (Pawn.get_move_speed: stats.json movement.base_speed_mps x
## class speed_pct / 100; bots never sprint) x route.rotate_detour + route.rotate_margin_s.
func _time_to_reach() -> float:
	var spot := _zone_spot()
	var d := Vector2(spot.x - pawn.global_position.x, spot.z - pawn.global_position.z).length()
	var speed := maxf(pawn.get_move_speed(), 0.1)
	return d / speed * _route_f("rotate_detour", 1.3) + _route_f("rotate_margin_s", 10.0)


## Nearest usable loot item within loot_seek_range_m (a gun first when the bot has none); INF if none.
func _loot_goal(guns_only: bool = false) -> Vector3:
	var loot := director.loot
	if loot == null:
		return Vector3.INF
	var range_m := float(cfg.get("loot_seek_range_m", 45.0))
	var best := Vector3.INF
	var best_score := INF
	var want_gun := _melee_only()
	# M2P1C stop 6: only the items the loot grid finds in range, in the same order as `items` (same result).
	for id in loot.items_near(pawn.global_position, range_m):
		var entry: Dictionary = loot.items[id]
		var item_def := loot.def(str(entry["item_id"]))
		if not pawn.wants_item(item_def, director.bot_ammo_low_magazines(), director.bot_heal_below_pct()) or (guns_only and str(item_def.get("kind", "")) != "weapon"):
			continue
		var pos: Vector3 = entry["pos"]
		var d := Vector2(pos.x - pawn.global_position.x, pos.z - pawn.global_position.z).length()
		if d > range_m:
			continue
		var score := d * (0.5 if want_gun and str(item_def.get("kind", "")) == "weapon" else 1.0)
		if score < best_score:
			best_score = score
			best = pos
	return best


## A stuck window measures from where it started: _stuck_from is set whenever _stuck_t starts from 0 (here and
## in _follow_path, the coast path); hold and arrival reset _stuck_t, so the next walk opens a fresh window.
func _track_stuck(delta: float) -> void:
	if _unstick_left > 0.0:
		return
	if _stuck_t == 0.0:
		_stuck_from = pawn.global_position
	_stuck_t += delta
	if _stuck_t < float(cfg.get("stuck_window_s", 2.0)):
		return
	var moved := Vector2(pawn.global_position.x - _stuck_from.x, pawn.global_position.z - _stuck_from.z).length()
	if moved < float(cfg.get("stuck_min_move_m", 0.6)):
		_unstick_left = float(cfg.get("unstick_s", 1.0))
		_unstick_side = -_unstick_side
	_stuck_t = 0.0
	_stuck_from = pawn.global_position


## ---- Gearing up at a landmark (M2B1 stage 3, big maps only; placeholders in brain.route, OQ-BOT-ROUTE) ----
## Geared: armour tier >= route.geared_armor_tier_min and the gun wants_item would refill (the active gun, else
## the first gun: Pawn._ranged_slot's rule) holds reserve >= magazine x director.bot_ammo_low_magazines().
## The landmark pick: a seeded choice (_route_rng) among the route.landmark_pick_k nearest landmarks "with loot",
## measured from the bot's position on the carrier at its jump (or from where it stands at its first think when it
## never dropped). While FALLING, Pawn.wants_item is false (can_take refuses a dropping pawn), so the jump pick
## counts a landmark with ANY item inside its radius; every ground pick and re-check counts only items this pawn
## wants, and skips landmarks whose centre lies outside the current circle. No loot placed yet at the jump: glide
## to the zone spot and pick (from the stored jump position) on the first think once it is placed.
## The gear goal walks to the chosen landmark's anchor; every route.gear_recheck_ticks director ticks (not every
## think) it checks the landmark still has wanted loot inside the circle and otherwise re-picks from here.

func _geared() -> bool:
	if pawn.armor_tier < int(_route_f("geared_armor_tier_min", 1.0)):
		return false
	var lo := pawn.loadout
	if lo == null:
		return false
	var gun: Weapon = lo.get_active()
	if gun == null or gun.def.is_melee():
		gun = null
		for s in lo.slots:
			if s != null and not s.def.is_melee():
				gun = s
				break
	return gun != null and float(gun.reserve) >= float(gun.def.magazine) * director.bot_ammo_low_magazines()


## True once this bot is geared (report / tests).
func is_geared() -> bool:
	return _geared()


func _route_landmarks() -> Array:
	if not _landmarks_loaded:
		_landmarks_loaded = true
		_landmarks_cache = director.loot_landmarks()
	return _landmarks_cache


static func _lm_center(lm: Dictionary) -> Vector3:
	var at: Array = lm.get("at", [0.0, 0.0])
	return Vector3(float(at[0]), 0.0, float(at[1]))


## The walk / glide goal of a landmark: its anchor (open ground inside it) when the data has one, else its centre.
static func _lm_goal(lm: Dictionary) -> Vector3:
	var an: Variant = lm.get("anchor")
	if an is Array and (an as Array).size() == 3:
		return Vector3(float(an[0]), float(an[1]), float(an[2]))
	return _lm_center(lm)


## Whether a landmark holds loot: any item inside its radius (any_item, the jump pick) or one this pawn wants.
func _landmark_has_loot(lm: Dictionary, any_item: bool) -> bool:
	var loot := director.loot
	if loot == null:
		return false
	var c := _lm_center(lm)
	var r := float(lm.get("radius_m", 0.0))
	for id in loot.items_near(c, r):
		var entry: Dictionary = loot.items[id]
		var pos: Vector3 = entry["pos"]
		if Vector2(pos.x - c.x, pos.z - c.z).length() > r:
			continue
		if any_item or pawn.wants_item(loot.def(str(entry["item_id"])), director.bot_ammo_low_magazines(), director.bot_heal_below_pct()):
			return true
	return false


## A seeded pick among the K nearest landmarks with loot from `from` ({} when none).
func _pick_landmark(from: Vector3, any_item: bool) -> Dictionary:
	var lms := _route_landmarks()
	var order: Array = []
	for i in lms.size():
		var c := _lm_center(lms[i])
		order.append([Vector2(c.x - from.x, c.z - from.z).length(), i])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	# Nearest first, so the loot check runs only until k landmarks with loot are found.
	var k := maxi(int(_route_f("landmark_pick_k", 3.0)), 1)
	var cands: Array = []
	for o in order:
		var lm: Dictionary = lms[int(o[1])]
		var c := _lm_center(lm)
		if not any_item and director.rules != null and director.rules.is_outside(Vector2(c.x, c.z)):
			continue
		if _landmark_has_loot(lm, any_item):
			cands.append(lm)
			if cands.size() >= k:
				break
	if cands.is_empty():
		return {}
	return cands[_route_rng.randi_range(0, cands.size() - 1)]


## The FALLING glide target: the zone spot on a small map; on a big map the landmark picked at the jump.
func _glide_goal() -> Vector3:
	if not _big_map:
		return _zone_spot()
	if not _jump_seen:
		_jump_seen = true
		_jump_from = pawn.global_position
	if not _landmark_picked and director.loot != null and director.loot.placed:
		_landmark_picked = true
		_landmark = _pick_landmark(_jump_from, true)
		_gear_check_tick = director.tick_count  # the first ground think re-checks with the wants rule
	return _lm_goal(_landmark) if not _landmark.is_empty() else _zone_spot()


## Every grounded think on a big map, before the goals: the first pick for a bot that has none yet, and reports.
func _route_think() -> void:
	if not _landmark_picked:
		_landmark_picked = true
		_landmark = _pick_landmark(_jump_from if _jump_seen else pawn.global_position, false)
		_gear_check_tick = director.tick_count + _gear_recheck_ticks()
	if _jump_seen and route_landed_at == Vector3.INF:
		route_landed_at = pawn.global_position
		if not _landmark.is_empty():
			var c := _lm_center(_landmark)
			route_landed_in_pick = Vector2(c.x - route_landed_at.x, c.z - route_landed_at.z).length() <= float(_landmark.get("radius_m", 0.0))
	if not route_geared_ever and _geared():
		route_geared_ever = true


func _gear_recheck_ticks() -> int:
	return maxi(int(_route_f("gear_recheck_ticks", 60.0)), 1)


## The gear goal: the chosen landmark while this bot is not geared; INF when geared or no landmark has loot.
func _gear_goal() -> Vector3:
	if _geared():
		return Vector3.INF
	if director.tick_count >= _gear_check_tick:
		_gear_check_tick = director.tick_count + _gear_recheck_ticks()
		var keep := not _landmark.is_empty()
		if keep:
			var c := _lm_center(_landmark)
			keep = not (director.rules != null and director.rules.is_outside(Vector2(c.x, c.z))) \
					and _landmark_has_loot(_landmark, false)
		if not keep:
			_landmark = _pick_landmark(pawn.global_position, false)
	if _landmark.is_empty():
		return Vector3.INF
	return _lm_goal(_landmark)


## The chosen landmark's id ("" when none), for tests and the sims.
func landmark_id() -> String:
	return str(_landmark.get("id", ""))
