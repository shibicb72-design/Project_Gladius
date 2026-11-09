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

var pawn: Pawn
var director: MatchDirector
var profile: Dictionary = {}
var cfg: Dictionary = {}
var target_id: int = -1
## Last goal kind, for tests and debugging: "revive", "zone", "loot", "hold", "chase" or "".
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


func _ready() -> void:
	_agent = NavigationAgent3D.new()
	_agent.path_desired_distance = float(cfg.get("path_desired_distance_m", 1.0))
	_agent.target_desired_distance = float(cfg.get("target_desired_distance_m", 1.0))
	pawn.add_child(_agent)


func _physics_process(delta: float) -> void:
	pawn.set_frame(build_frame(delta))


func build_frame(delta: float) -> InputFrame:
	var frame := InputFrame.new()
	if pawn == null or not pawn.is_alive() or not pawn.is_inside_tree():
		return frame
	_ensure_seeded()
	if pawn.drop_state == Pawn.Drop.FALLING:
		# Steer the glide toward this bot's own spot inside the next circle.
		var to := _zone_spot() - pawn.global_position
		to.y = 0.0
		if to.length() > 1.0:
			var local := pawn.global_transform.basis.inverse() * to.normalized()
			frame.move = Vector2(local.x, local.z).limit_length(1.0)
		return frame
	if pawn.is_dropping():
		return frame
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

	if want_dir != Vector3.ZERO:
		var yaw := BotTargeting.yaw_of(want_dir) + (_error.x if enemy != null else 0.0)
		var pitch := BotTargeting.pitch_of(want_dir) + (_error.y if enemy != null else 0.0)
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
	return rules.zone_state() != "waiting" or rules.zone_seconds_left() < float(cfg.get("zone_margin_s", 25.0)) \
			or rules.is_outside(here)


## Nearest usable loot item within loot_seek_range_m (a gun first when the bot has none); INF if none.
func _loot_goal(guns_only: bool = false) -> Vector3:
	var loot := director.loot
	if loot == null:
		return Vector3.INF
	var range_m := float(cfg.get("loot_seek_range_m", 45.0))
	var best := Vector3.INF
	var best_score := INF
	var want_gun := _melee_only()
	for id in loot.items:
		var entry: Dictionary = loot.items[id]
		var item_def := loot.def(str(entry["item_id"]))
		if not pawn.wants_item(item_def, director.bot_ammo_low_magazines()) or (guns_only and str(item_def.get("kind", "")) != "weapon"):
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


func _track_stuck(delta: float) -> void:
	if _unstick_left > 0.0:
		return
	_stuck_t += delta
	if _stuck_t < float(cfg.get("stuck_window_s", 2.0)):
		return
	var moved := Vector2(pawn.global_position.x - _stuck_from.x, pawn.global_position.z - _stuck_from.z).length()
	if moved < float(cfg.get("stuck_min_move_m", 0.6)):
		_unstick_left = float(cfg.get("unstick_s", 1.0))
		_unstick_side = -_unstick_side
	_stuck_t = 0.0
	_stuck_from = pawn.global_position
