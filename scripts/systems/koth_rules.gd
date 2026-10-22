class_name KothRules
extends GameModeRules
## Fixed-hill King of the Hill. Scoring unit, contest rule and tie result are
## placeholders read from data/modes.json (OQ-20, OQ-21, OQ-22).

## Float error tolerance when moving whole points out of the carry (not a tunable).
const CARRY_EPSILON := 1e-6

var scores: Dictionary = {}  # squad id -> int score
var elapsed_s: float = 0.0
var _over: bool = false
var _winner: int = -1
var _draw: bool = false
var _fraction: Dictionary = {}


func setup(p_cfg: Dictionary) -> void:
	super.setup(p_cfg)
	scores = {}
	_fraction = {}
	elapsed_s = 0.0
	_over = false
	_winner = -1
	_draw = false


func register_squads(squad_ids: Array) -> void:
	for id in squad_ids:
		if not scores.has(id):
			scores[id] = 0
			_fraction[id] = 0.0


func tick(delta: float, occupancy: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if _over:
		return events
	elapsed_s += delta
	var holder := _scoring_squad(occupancy)
	if holder != -1:
		# Integer score plus a float carry, so reaching score_to_win is exact, never a tick late.
		var carry: float = float(_fraction.get(holder, 0.0)) + float(cfg.get("points_per_second", 1)) * delta
		var whole := int(floor(carry + CARRY_EPSILON))
		carry -= float(whole)
		_fraction[holder] = maxf(carry, 0.0)
		scores[holder] = int(scores.get(holder, 0)) + whole
		events.append({"type": "score", "squad": holder, "score": scores[holder]})
		if scores[holder] >= int(cfg.get("score_to_win", 100)):
			_finish(holder, false, events)
			return events
	if elapsed_s >= float(cfg.get("time_limit_s", 600)):
		_finish_on_timer(events)
	return events


func is_over() -> bool:
	return _over


func result() -> Dictionary:
	return {"winner": _winner, "draw": _draw, "scores": scores.duplicate()}


## Squad id that scores this tick, or -1 when the hill is empty or contested.
func _scoring_squad(occupancy: Dictionary) -> int:
	var present: Array[int] = []
	for squad in occupancy:
		if int(occupancy[squad]) > 0:
			present.append(int(squad))
	if present.size() == 1:
		return present[0]
	# TODO(OQ-21): only "any_other_squad" is implemented; more than one squad means contested.
	return -1


func _finish_on_timer(events: Array[Dictionary]) -> void:
	var best := -1
	var leaders: Array[int] = []
	for squad in scores:
		var s: int = scores[squad]
		if s > best:
			best = s
			leaders = [int(squad)]
		elif s == best:
			leaders.append(int(squad))
	if leaders.size() == 1:
		_finish(leaders[0], false, events)
	else:
		# TODO(OQ-22): tie_result "draw" is the only option implemented.
		_finish(-1, true, events)


func _finish(winner: int, draw: bool, events: Array[Dictionary]) -> void:
	_over = true
	_winner = winner
	_draw = draw
	events.append({"type": "match_over", "winner": winner, "draw": draw})
