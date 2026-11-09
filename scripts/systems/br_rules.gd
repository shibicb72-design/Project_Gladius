class_name BrRules
extends GameModeRules
## Battle royale rules core. Pure RefCounted: no nodes, scenes, input or rendering; time only via tick(delta);
## randomness only from its own seeded RandomNumberGenerator. Problems are returned, never printed.
##
## tick(delta, facts): facts["positions"] = {player_id: Vector2(x, z)} (ALIVE and DOWNED players),
## facts["reviving"] = {reviver_id: target_id}. Events are Dictionaries with a "type" key.
## Order inside one tick: queued downed/dead (by player id), zone_phase, zone_damage, zone deaths of downed
## players, revive_progress (all), revived (all), bleed-outs (bled_out then its dead, per player),
## squad-wipe dead, squad_eliminated, match_over. Per-player/per-squad events go in ascending id order.
##   zone_phase      {phase:int, state:"waiting"|"shrinking"|"final"}   start of every wait/shrink, "final" once
##   zone_damage     {player_id, amount, skips_shield}                  ALIVE players outside the circle
##   downed          {player_id, killer_id}                             killer_id: credited downer or -1
##   revive_progress {reviver_id, target_id, progress 0..1}             every tick a revive advances
##   revived         {player_id, health_pct}
##   bled_out        {player_id}
##   dead            {player_id, killer_id, cause:"hit"|"finished"|"zone"|"bled_out"|"squad_wipe"}
##   squad_eliminated {squad_id, placement}
##   match_over      {winner:int (-1 on draw), draw:bool}
## Kill credit: finishing hitter, or the downer when kill_credit_to_downer and the victim was downed by a hit
## (then no downer = no kill). No credit for self, same squad, unknown or -1 killers, or the zone.

enum State { ALIVE, DOWNED, DEAD }

var _problems: Array[String] = []
var _rng := RandomNumberGenerator.new()
var _default_seed: int = 0
var _team_mode: String = "solo"
var _squad_max: int = 3

# zone data
var _start_center := Vector2.ZERO
var _start_radius: float = 0.0
var _skips_shield: bool = false
var _phases: Array[Dictionary] = []  # {wait, shrink, radius, damage}
var _circles: Array[Dictionary] = []  # {center: Vector2, radius: float} per phase target
# downed data
var _bleed_s: float = 0.0
var _revive_s: float = 0.0
var _revive_range: float = 0.0
var _revive_hp: float = 0.0
var _can_finish: bool = false
var _zone_finishes: bool = false
var _wipe_kills: bool = false
var _credit_downer: bool = false
var _bleed_pauses: bool = false
var _bleed_restarts: bool = false

# zone state
var _center := Vector2.ZERO
var _radius: float = 0.0
var _phase: int = 0
var _zstate: String = "waiting"
var _zleft: float = 0.0
var _stage_len: float = 0.0
var _from_center := Vector2.ZERO
var _from_radius: float = 0.0

# match state
var _players: Dictionary = {}  # id -> {squad, state, by_hit, downer, bleed, prog}
var _squads: Dictionary = {}  # squad id -> Array[int]
var _eliminated: Dictionary = {}
var _placements: Dictionary = {}
var _kills: Dictionary = {}
var _queue: Array[Dictionary] = []
var _seq: int = 0
var _started: bool = false
var _over: bool = false
var _winner: int = -1
var _draw: bool = false


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _need_dict(c: Dictionary, key: String, out: Array[String]) -> Dictionary:
	var v: Variant = c.get(key)
	if typeof(v) != TYPE_DICTIONARY:
		out.append("%s: missing or not an object" % key)
		return {}
	return v


static func _need_num(d: Dictionary, key: String, where: String, out: Array[String], min_v: float, max_v: float = INF) -> void:
	if not d.has(key) or not _is_num(d[key]):
		out.append("%s.%s: missing or not a number" % [where, key])
	elif float(d[key]) < min_v or float(d[key]) > max_v:
		out.append("%s.%s: out of range" % [where, key])


## JSON numbers arrive as floats, so a float equal to its int() counts as an integer. Bools and strings do not.
static func _need_int(d: Dictionary, key: String, where: String, out: Array[String], min_v: float = -INF) -> void:
	if not d.has(key) or not _is_num(d[key]):
		out.append("%s.%s: missing or not a number" % [where, key])
	elif float(d[key]) != float(int(d[key])):
		out.append("%s.%s: must be a whole number" % [where, key])
	elif float(d[key]) < min_v:
		out.append("%s.%s: out of range" % [where, key])


static func _need_bool(d: Dictionary, key: String, where: String, out: Array[String]) -> void:
	if not d.has(key) or typeof(d[key]) != TYPE_BOOL:
		out.append("%s.%s: missing or not a bool" % [where, key])


## Returns a list of problems (empty when the config is usable). Keys starting with "_" are ignored.
static func validate_config(c: Dictionary) -> Array[String]:
	var out: Array[String] = []
	_need_int(c, "default_seed", "config", out)
	var zone := _need_dict(c, "zone", out)
	if true:  # always run the key checks, also for {} or a missing object, so every missing key is named
		var sc: Variant = zone.get("start_center")
		if typeof(sc) != TYPE_ARRAY or (sc as Array).size() != 2 or not _is_num(sc[0]) or not _is_num(sc[1]):
			out.append("zone.start_center: must be exactly 2 numbers")
		_need_num(zone, "start_radius_m", "zone", out, 1e-9)
		_need_bool(zone, "damage_skips_shield", "zone", out)
		var ph: Variant = zone.get("phases")
		if typeof(ph) != TYPE_ARRAY or (ph as Array).is_empty():
			out.append("zone.phases: missing, not a list or empty")
		else:
			var prev: float = float(zone["start_radius_m"]) if _is_num(zone.get("start_radius_m")) else INF
			for i in (ph as Array).size():
				var p: Variant = ph[i]
				if typeof(p) != TYPE_DICTIONARY:
					out.append("zone.phases[%d]: not an object" % i)
					continue
				var w := "zone.phases[%d]" % i
				_need_num(p, "wait_s", w, out, 0.0)
				_need_num(p, "shrink_s", w, out, 0.0)
				_need_num(p, "radius_m", w, out, 0.0)
				_need_num(p, "damage_per_s", w, out, 0.0)
				if _is_num(p.get("radius_m")):
					if float(p["radius_m"]) >= prev:
						out.append("%s.radius_m: must be smaller than the previous radius" % w)
					prev = float(p["radius_m"])
	var d := _need_dict(c, "downed", out)
	if true:
		for k in ["bleed_out_s", "revive_s", "revive_range_m"]:
			_need_num(d, k, "downed", out, 0.0)
		for k in ["downed_move_speed_pct", "revive_health_pct"]:
			_need_num(d, k, "downed", out, 0.0, 100.0)
		for k in ["can_be_finished", "zone_finishes_downed", "squad_wipe_kills_downed", "kill_credit_to_downer",
				"bleed_pauses_while_reviving", "bleed_restarts_on_new_down"]:
			_need_bool(d, k, "downed", out)
	var e := _need_dict(c, "end", out)
	if e.get("tie_result") != "draw":
		out.append("end.tie_result: only \"draw\" is implemented")
	var t := _need_dict(c, "teams", out)
	if true:
		var m: Variant = t.get("mode")
		if typeof(m) != TYPE_DICTIONARY or not ["solo", "squads"].has(m.get("value")):
			out.append("teams.mode.value: must be \"solo\" or \"squads\"")
		_need_int(t, "squad_size_max", "teams", out, 1.0)
	return out


func setup(p_cfg: Dictionary) -> void:
	super.setup(p_cfg)
	_problems = validate_config(p_cfg)
	_players = {}
	_squads = {}
	_eliminated = {}
	_placements = {}
	_kills = {}
	_queue = []
	_seq = 0
	_started = false
	_over = false
	_winner = -1
	_draw = false
	_phases = []
	_circles = []
	_phase = 0
	_zstate = "waiting"
	if not _problems.is_empty():
		return
	var zone: Dictionary = p_cfg["zone"]
	_start_center = Vector2(float(zone["start_center"][0]), float(zone["start_center"][1]))
	_start_radius = float(zone["start_radius_m"])
	_skips_shield = bool(zone["damage_skips_shield"])
	for p in zone["phases"]:
		_phases.append({"wait": float(p["wait_s"]), "shrink": float(p["shrink_s"]),
				"radius": float(p["radius_m"]), "damage": float(p["damage_per_s"])})
	var d: Dictionary = p_cfg["downed"]
	_bleed_s = float(d["bleed_out_s"])
	_revive_s = float(d["revive_s"])
	_revive_range = float(d["revive_range_m"])
	_revive_hp = float(d["revive_health_pct"])
	_can_finish = bool(d["can_be_finished"])
	_zone_finishes = bool(d["zone_finishes_downed"])
	_wipe_kills = bool(d["squad_wipe_kills_downed"])
	_credit_downer = bool(d["kill_credit_to_downer"])
	_bleed_pauses = bool(d["bleed_pauses_while_reviving"])
	_bleed_restarts = bool(d["bleed_restarts_on_new_down"])
	var teams: Dictionary = p_cfg["teams"]
	_team_mode = str(teams["mode"]["value"])
	_squad_max = int(teams["squad_size_max"])
	_default_seed = int(p_cfg["default_seed"])
	_center = _start_center
	_radius = _start_radius
	_zleft = float(_phases[0]["wait"])
	_generate_circles(_default_seed)


func config_problems() -> Array[String]:
	return _problems.duplicate()


## Fixed draws per phase (angle, distance fraction), so the same seed always gives the same circles.
func _generate_circles(seed_value: int) -> void:
	_rng.seed = seed_value
	_circles = []
	var c := _start_center
	var r := _start_radius
	for p in _phases:
		var tr: float = p["radius"]
		var ang := _rng.randf() * TAU
		var frac := sqrt(_rng.randf())
		var slack := maxf(r - tr, 0.0)
		c = c + Vector2(cos(ang), sin(ang)) * (slack * frac)
		_circles.append({"center": c, "radius": tr})
		r = tr


func set_seed(seed_value: int) -> bool:
	if _started or not _problems.is_empty():
		return false
	_generate_circles(seed_value)
	return true


func set_team_mode(mode: String) -> bool:
	if not ["solo", "squads"].has(mode) or not _players.is_empty():
		return false
	_team_mode = mode
	return true


func register_player(player_id: int, squad_id: int) -> bool:
	if _started or not _problems.is_empty() or _players.has(player_id):
		return false
	var sid := player_id if _team_mode == "solo" else squad_id
	var members: Array = _squads.get(sid, [])
	if members.size() >= _squad_max:
		return false
	members.append(player_id)
	_squads[sid] = members
	_players[player_id] = {"squad": sid, "state": State.ALIVE, "by_hit": false, "downer": -1, "bleed": _bleed_s, "prog": 0.0}
	_kills[player_id] = 0
	return true


func player_state(id: int) -> int:
	return int(_players[id]["state"]) if _players.has(id) else -1


func squad_of(id: int) -> int:
	return int(_players[id]["squad"]) if _players.has(id) else -1


# ---- zone read API ----
func phase_count() -> int:
	return _circles.size()


func phase_circle(i: int) -> Dictionary:
	if i < 0 or i >= _circles.size():
		return {}
	return _circles[i].duplicate()


func zone_center() -> Vector2:
	return _center


func zone_radius() -> float:
	return _radius


func zone_target_center() -> Vector2:
	return _circles[_phase]["center"] if _phase < _circles.size() else _center


func zone_target_radius() -> float:
	return float(_circles[_phase]["radius"]) if _phase < _circles.size() else _radius


func zone_phase() -> int:
	return _phase


func zone_state() -> String:
	return _zstate


func zone_seconds_left() -> float:
	return 0.0 if _zstate == "final" else _zleft


func is_outside(p: Vector2) -> bool:
	return p.distance_to(_center) > _radius


func zone_damage_per_s() -> float:
	return float(_phases[_phase]["damage"]) if _phase < _phases.size() else 0.0


# ---- health reports ----
func _valid_killer(k: int, victim: int) -> bool:
	return k >= 0 and k != victim and _players.has(k) and _players[k]["squad"] != _players[victim]["squad"]


## Credited killer for a victim's death. finisher is the finishing hitter or -1.
func _credit(victim: int, finisher: int) -> int:
	var p: Dictionary = _players[victim]
	if _credit_downer and p["by_hit"]:
		return int(p["downer"])
	return finisher if _valid_killer(finisher, victim) else -1


func _enqueue(id: int, type: String, killer: int, cause: String) -> void:
	_seq += 1
	_queue.append({"id": id, "seq": _seq, "type": type, "killer": killer, "cause": cause})


func report_zero_health(player_id: int, killer_id: int, cause: String) -> void:
	if not _problems.is_empty() or not _started or _over or not _players.has(player_id):
		return
	if cause != "hit" and cause != "zone":
		return
	var p: Dictionary = _players[player_id]
	var st: int = p["state"]
	if st == State.DEAD:
		return
	var hitter := killer_id if (cause == "hit" and _valid_killer(killer_id, player_id)) else -1
	if _team_mode == "solo":
		var credit := hitter
		p["state"] = State.DEAD
		_enqueue(player_id, "dead", credit, cause)
	elif st == State.ALIVE:
		p["state"] = State.DOWNED
		p["by_hit"] = cause == "hit"
		p["downer"] = hitter
		p["prog"] = 0.0
		if _bleed_restarts:
			p["bleed"] = _bleed_s
		_enqueue(player_id, "downed", hitter, cause)
	elif cause == "hit" and _can_finish:
		var credit2 := _credit(player_id, hitter)
		p["state"] = State.DEAD
		_enqueue(player_id, "dead", credit2, "finished")


func _emit_dead(id: int, killer: int, cause: String, events: Array[Dictionary]) -> void:
	if killer >= 0:
		_kills[killer] = int(_kills.get(killer, 0)) + 1
	events.append({"type": "dead", "player_id": id, "killer_id": killer, "cause": cause})


func _kill(id: int, killer: int, cause: String, events: Array[Dictionary]) -> void:
	_players[id]["state"] = State.DEAD
	_emit_dead(id, killer, cause, events)


func _flush_queue(events: Array[Dictionary]) -> void:
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["id"] < b["id"] or (a["id"] == b["id"] and a["seq"] < b["seq"]))
	for q in _queue:
		if q["type"] == "downed":
			events.append({"type": "downed", "player_id": q["id"], "killer_id": q["killer"]})
		else:
			_emit_dead(q["id"], q["killer"], q["cause"], events)
	_queue = []


# ---- zone advance ----
func _enter_next(events: Array[Dictionary]) -> void:
	if _zstate == "waiting":
		_zstate = "shrinking"
		_zleft = float(_phases[_phase]["shrink"])
		_stage_len = _zleft
		_from_center = _center
		_from_radius = _radius
	elif _phase + 1 < _phases.size():
		_phase += 1
		_zstate = "waiting"
		_zleft = float(_phases[_phase]["wait"])
	else:
		_zstate = "final"
		_zleft = 0.0
	events.append({"type": "zone_phase", "phase": _phase, "state": _zstate})


func _update_shrink() -> void:
	var target: Dictionary = _circles[_phase]
	if _zleft <= 0.0 or _stage_len <= 0.0:
		_center = target["center"]
		_radius = float(target["radius"])
		return
	var t := 1.0 - _zleft / _stage_len
	_center = _from_center.lerp(target["center"], t)
	_radius = lerpf(_from_radius, float(target["radius"]), t)


## Advances the zone by dt, emitting every boundary crossed. Returns the total damage per second * time.
func _advance_zone(dt: float, events: Array[Dictionary]) -> float:
	var remaining := dt
	var dmg := 0.0
	while true:
		var rate: float = _phases[_phase]["damage"]
		if _zstate == "final":
			dmg += rate * remaining
			break
		var step := minf(remaining, _zleft)
		dmg += rate * step
		remaining -= step
		_zleft -= step
		if _zstate == "shrinking":
			_update_shrink()
		if _zleft > 0.0:
			break
		_enter_next(events)
	return dmg


# ---- tick ----
static func _int_map(src: Variant) -> Dictionary:
	var out := {}
	if typeof(src) == TYPE_DICTIONARY:
		for k in src:
			out[int(k)] = src[k]
	return out


func _sorted_ids(d: Dictionary) -> Array:
	var ids: Array = d.keys()
	ids.sort()
	return ids


func tick(delta: float, facts: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if not _problems.is_empty() or _over:
		return events
	var begin := false
	if not _started:
		if _squads.size() < 2:
			return events
		_started = true
		begin = true
	var dt := maxf(delta, 0.0)
	var pos := _int_map(facts.get("positions", {}))
	var reviving := _int_map(facts.get("reviving", {}))
	_flush_queue(events)
	if begin:
		events.append({"type": "zone_phase", "phase": 0, "state": "waiting"})
	var dmg := _advance_zone(dt, events)
	var ids := _sorted_ids(_players)
	for id in ids:
		if _players[id]["state"] == State.ALIVE and pos.has(id) and is_outside(pos[id]):
			events.append({"type": "zone_damage", "player_id": id, "amount": dmg, "skips_shield": _skips_shield})
	if _zone_finishes:
		for id in ids:
			if _players[id]["state"] == State.DOWNED and pos.has(id) and is_outside(pos[id]):
				_kill(id, _credit(id, -1), "zone", events)
	var advancing := _revive_step(dt, pos, reviving, ids, events)
	for id in ids:
		var p: Dictionary = _players[id]
		if p["state"] != State.DOWNED:
			continue
		if not (_bleed_pauses and advancing.has(id)):
			p["bleed"] = float(p["bleed"]) - dt
		if float(p["bleed"]) <= 0.0:
			events.append({"type": "bled_out", "player_id": id})
			_kill(id, _credit(id, -1), "bled_out", events)
	_resolve_squads(events)
	return events


## Returns {target_id: true} for revives that advanced this tick.
func _revive_step(dt: float, pos: Dictionary, reviving: Dictionary, ids: Array, events: Array[Dictionary]) -> Dictionary:
	var best := {}  # target -> lowest reviver id
	for r in _sorted_ids(reviving):
		var t := int(reviving[r])
		if not best.has(t):
			best[t] = r
	var advancing := {}
	var done: Array[Dictionary] = []
	for t in ids:
		var tp: Dictionary = _players[t]
		var ok := false
		if best.has(t) and tp["state"] == State.DOWNED:
			var r: int = best[t]
			if _players.has(r) and _players[r]["state"] == State.ALIVE and _players[r]["squad"] == tp["squad"] \
					and pos.has(r) and pos.has(t) and (pos[r] as Vector2).distance_to(pos[t]) <= _revive_range:
				ok = true
				tp["prog"] = float(tp["prog"]) + dt
				var ratio := 1.0 if _revive_s <= 0.0 else minf(float(tp["prog"]) / _revive_s, 1.0)
				advancing[t] = true
				events.append({"type": "revive_progress", "reviver_id": r, "target_id": t, "progress": ratio})
				if ratio >= 1.0:
					done.append({"type": "revived", "player_id": t, "health_pct": _revive_hp})
		if not ok:
			tp["prog"] = 0.0
	for ev in done:
		var tp2: Dictionary = _players[ev["player_id"]]
		tp2["state"] = State.ALIVE
		tp2["prog"] = 0.0
		advancing.erase(ev["player_id"])
		events.append(ev)
	return advancing


func _resolve_squads(events: Array[Dictionary]) -> void:
	var newly: Array[int] = []
	for sid in _sorted_ids(_squads):
		if _eliminated.has(sid):
			continue
		var members: Array = _squads[sid].duplicate()
		members.sort()
		var any_alive := false
		var any_down := false
		for pid in members:
			var st: int = _players[pid]["state"]
			any_alive = any_alive or st == State.ALIVE
			any_down = any_down or st == State.DOWNED
		if any_alive or (any_down and not _wipe_kills):
			continue
		if any_down:
			for pid in members:
				if _players[pid]["state"] == State.DOWNED:
					_kill(pid, _credit(pid, -1), "squad_wipe", events)
		newly.append(sid)
	if newly.is_empty():
		return
	var before := _squads.size() - _eliminated.size()
	for sid in newly:
		_eliminated[sid] = true
		_placements[sid] = before
		events.append({"type": "squad_eliminated", "squad_id": sid, "placement": before})
	var left := _squads.size() - _eliminated.size()
	if left > 1:
		return
	_over = true
	if left == 1:
		for sid in _sorted_ids(_squads):
			if not _eliminated.has(sid):
				_winner = sid
				_placements[sid] = 1
	else:
		_draw = true
	events.append({"type": "match_over", "winner": _winner, "draw": _draw})


func is_over() -> bool:
	return _over


func result() -> Dictionary:
	return {"winner": _winner, "draw": _draw, "placements": _placements.duplicate(),
			"kills": _kills.duplicate(), "scores": {}}
