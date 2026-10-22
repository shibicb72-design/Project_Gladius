class_name BotBrain
extends Node
## Child of a bot Pawn. Builds an InputFrame each physics tick from perception; never reads
## player input. Moves to the hill via NavigationAgent3D and shoots the nearest visible enemy.

const EYE_HEIGHT_M := 1.3
const TARGET_HEIGHT_M := 1.0

var pawn: Pawn
var director: MatchDirector
var profile: Dictionary = {}
var cfg: Dictionary = {}
var hill_center: Vector3 = Vector3.ZERO
var hill_radius: float = 8.0
var target_id: int = -1

var _agent: NavigationAgent3D
var _rng := RandomNumberGenerator.new()
var _seen_for_s: float = 0.0
var _error: Vector2 = Vector2.ZERO
var _error_age_s: float = 0.0


func setup(new_pawn: Pawn, new_director: MatchDirector, new_profile: Dictionary, new_cfg: Dictionary,
		center: Vector3, radius: float) -> void:
	pawn = new_pawn
	director = new_director
	profile = new_profile
	cfg = new_cfg
	hill_center = center
	hill_radius = radius
	_rng.randomize()


func _ready() -> void:
	_agent = NavigationAgent3D.new()
	_agent.path_desired_distance = 1.0
	_agent.target_desired_distance = 1.0
	pawn.add_child(_agent)


func _physics_process(delta: float) -> void:
	pawn.set_frame(build_frame(delta))


func build_frame(delta: float) -> InputFrame:
	var frame := InputFrame.new()
	if pawn == null or not pawn.is_alive() or not pawn.is_inside_tree():
		return frame
	var turn: float = float(cfg.get("turn_rate_rad_s", 6.0)) * delta
	var enemy := _find_target()
	var want_dir := Vector3.ZERO
	if enemy != null:
		_seen_for_s += delta
		_error_age_s -= delta
		if _error_age_s <= 0.0:
			_error = BotTargeting.aim_error(float(profile.get("accuracy", 0.3)),
					float(cfg.get("max_aim_error_deg", 12.0)), _rng)
			_error_age_s = float(cfg.get("aim_error_refresh_s", 0.5))
		var aim_pt: Vector3 = enemy.global_position + Vector3(0.0, TARGET_HEIGHT_M, 0.0)
		want_dir = (aim_pt - (pawn.global_position + Vector3(0.0, EYE_HEIGHT_M, 0.0))).normalized()
	else:
		_seen_for_s = 0.0
		_error_age_s = 0.0
		_error = Vector2.ZERO

	var move_dir := _move_direction()
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
			frame.fire_pressed = aimed
	return frame


func _find_target() -> Pawn:
	var origin := pawn.global_position + Vector3(0.0, EYE_HEIGHT_M, 0.0)
	var cands: Array = []
	var space := pawn.get_world_3d().direct_space_state
	var players := director.all_players()
	for id in players:
		var other: Pawn = players[id]
		if other == pawn or not other.is_inside_tree():
			continue
		var pos := other.global_position
		var visible := false
		if other.is_alive() and other.visible:
			var q := PhysicsRayQueryParameters3D.create(origin, pos + Vector3(0.0, TARGET_HEIGHT_M, 0.0), Hitscan.MASK_WORLD)
			visible = space.intersect_ray(q).is_empty()
		cands.append({"id": id, "pos": pos, "squad": other.squad_id, "alive": other.is_alive(), "visible": visible})
	target_id = BotTargeting.pick_target(pawn.global_position, pawn.squad_id, cands,
			float(cfg.get("sight_range_m", 60.0)))
	return players.get(target_id) if target_id >= 0 else null


## World-space direction to walk, or ZERO when holding the hill.
func _move_direction() -> Vector3:
	var to_hill := hill_center - pawn.global_position
	to_hill.y = 0.0
	if to_hill.length() <= hill_radius * float(cfg.get("hill_hold_fraction", 0.5)):
		return Vector3.ZERO
	_agent.target_position = hill_center
	var next := _agent.get_next_path_position()
	var dir := next - pawn.global_position
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = to_hill  # no navmesh path yet: head straight for the hill
	return dir.normalized()
