class_name ViewMotion
extends RefCounted
## M2 AN1 commit 3: the layered first-person view-model motion, view only (nothing here feeds a shot, the aim point,
## the recoil or the camera). Numbers: data/anim.json first_person (OQ-FP-ANIM placeholders); the switch, swing and kick
## timers are camera.json first_person.view_model swap_s, swing_s and recoil_s; a reload lasts the weapon's own
## WeaponDef.reload_s, its stages are fractions of it. ViewModel feeds tick() with read-only pawn state and triggers the
## one-shot motions from the pawn's signals; it reads three results each frame:
##   pivot_xf()  about the eye: breathing, walk bob on the step phase, landing dip, blade swing;
##   weapon_xf() about the grip: sprint pose, ADS settle, kick spring, reload tilt, switch and pickup lower and raise;
##   hand / cell / charge: the left hand's target and finger pose during reload and pickup, the cell and charging handle.

const RELOAD_STAGES: Array[String] = ["tilt", "hand_to_cell", "cell_out", "cell_in", "charge", "return"]

var cfg: Dictionary = {}
var _rng := RandomNumberGenerator.new()

# Continuous layers.
var _time := 0.0
var _step_phase := 0.0  # radians; one cycle = two steps
var _walk := 0.0  # 0..1 smoothed speed / run speed
var _sprint := 0.0  # 0..1 smoothed
var _ads_prev := 0.0
var _settle := Spring.new()
var _kick_pos := [Spring.new(), Spring.new(), Spring.new()]
var _kick_rot := [Spring.new(), Spring.new(), Spring.new()]
var _land_t := -1.0
var _land_amount := 0.0
var _air_t := 0.0
var _air_min_vy := 0.0
var _was_on_floor := true

# One-shot motions: elapsed and total (total 0 = idle).
var reload_t := 0.0
var reload_total := 0.0
var switch_t := 0.0
var switch_total := 0.0
var pickup_t := 0.0
var pickup_total := 0.0
var swing_t := 0.0
var swing_total := 0.0


## A critically damped-ish spring (x'' = -w^2 x - 2 z w x'), kicked by impulses on its velocity.
class Spring:
	var x := 0.0
	var v := 0.0

	func step(delta: float, hz: float, damping: float, target: float = 0.0) -> void:
		var w := TAU * hz
		var steps := maxi(1, ceili(delta / 0.004))
		var h := delta / steps
		for i in steps:
			v += (-(w * w) * (x - target) - 2.0 * damping * w * v) * h
			x += v * h


func _init(config: Dictionary) -> void:
	cfg = config
	_rng.randomize()


func _f(path: String, key: String) -> float:
	return float((cfg[path] as Dictionary)[key])


func _v(path: String, key: String) -> Vector3:
	return ViewMesh.vec((cfg[path] as Dictionary)[key])


static func _deg(v: Vector3) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z)))


# --- triggers -----------------------------------------------------------------------------------------------------

func start_reload(total: float) -> void:
	reload_t = 0.0
	reload_total = maxf(total, 0.0)


func start_switch(total: float) -> void:
	reload_total = 0.0
	swing_total = 0.0
	pickup_total = 0.0
	switch_t = 0.0
	switch_total = maxf(total, 0.0)


func start_pickup() -> void:
	reload_total = 0.0
	swing_total = 0.0
	switch_total = 0.0
	pickup_t = 0.0
	pickup_total = maxf(_f("pickup", "s"), 0.0)


func start_swing(total: float) -> void:
	swing_t = 0.0
	swing_total = maxf(total, 0.0)


## A shot: an impulse on the kick springs (back, up, a random yaw and roll), scaled by `mult` (ADS).
func kick(mult: float) -> void:
	var k: Dictionary = cfg["kick"]
	var w := TAU * float(k["spring_hz"])
	var pos := ViewMesh.vec(k["pos_m"]) * mult
	for i in 3:
		(_kick_pos[i] as Spring).v += pos[i] * w * 2.2
	(_kick_rot[0] as Spring).v += float(k["pitch_deg"]) * mult * w * 2.2
	(_kick_rot[1] as Spring).v += _rng.randf_range(-1.0, 1.0) * float(k["yaw_deg"]) * mult * w * 2.2
	(_kick_rot[2] as Spring).v += _rng.randf_range(-1.0, 1.0) * float(k["roll_deg"]) * mult * w * 2.2


## A landing: a dip whose depth follows the impact speed (m/s, positive).
func land(impact_mps: float) -> void:
	var l: Dictionary = cfg["land"]
	_land_amount = minf(float(l["dip_m"]) + float(l["per_mps"]) * maxf(impact_mps, 0.0), float(l["max_m"]))
	_land_t = 0.0


func is_landing() -> bool:
	return _land_t >= 0.0


# --- per frame ----------------------------------------------------------------------------------------------------

## in: speed (horizontal m/s), run_speed, sprint (0..1 raw), ads (0..1), on_floor, vy (m/s).
func tick(delta: float, speed: float, run_speed: float, sprint: float, ads: float, on_floor: bool, vy: float) -> void:
	_time += delta
	var walk_cfg: Dictionary = cfg["walk"]
	var smooth := float(walk_cfg["smooth_s"])
	var k := 1.0 - exp(-delta / smooth) if smooth > 0.0 else 1.0
	_walk = lerpf(_walk, clampf(speed / maxf(run_speed, 0.01), 0.0, 1.0), k)
	var sb := float(cfg["sprint"]["blend_s"])
	_sprint = move_toward(_sprint, clampf(sprint, 0.0, 1.0) * (1.0 - ads), delta / sb if sb > 0.0 else 1.0)
	# The step phase advances with the real distance walked: one cycle per stride (two steps).
	var stride := lerpf(float(walk_cfg["stride_m"]), float(cfg["sprint"]["stride_m"]), _sprint)
	_step_phase = fmod(_step_phase + speed * delta / maxf(stride, 0.01) * TAU, TAU * 4.0)
	# ADS settle: while the ADS weight changes the spring is pulled by its rate (a lag), and rings out after the raise
	# and the lower.
	var a: Dictionary = cfg["ads"]
	var rate := (ads - _ads_prev) / delta if delta > 0.0 else 0.0
	_ads_prev = ads
	_settle.step(delta, float(a["settle_hz"]), float(a["settle_damping"]), rate * float(a["settle_lag_s"]))
	var kc: Dictionary = cfg["kick"]
	for s in _kick_pos + _kick_rot:
		(s as Spring).step(delta, float(kc["spring_hz"]), float(kc["damping"]))
	# Landing: a fall of at least min_air_s ending on the floor dips by its impact speed.
	if not on_floor:
		_air_t += delta
		_air_min_vy = minf(_air_min_vy, vy)
	elif not _was_on_floor:
		if _air_t >= float(cfg["land"]["min_air_s"]):
			land(-_air_min_vy)
		_air_t = 0.0
		_air_min_vy = 0.0
	_was_on_floor = on_floor
	if _land_t >= 0.0:
		_land_t += delta
		if _land_t >= float(cfg["land"]["s"]):
			_land_t = -1.0
	for m in ["reload", "switch", "pickup", "swing"]:
		var total: float = get(m + "_total")
		if total > 0.0:
			var t: float = get(m + "_t") + delta
			set(m + "_t", t)
			if t >= total:
				set(m + "_total", 0.0)


# --- results ------------------------------------------------------------------------------------------------------

## Eye-space offset: breathing, the walk bob on the step phase (stronger in sprint), the landing dip, the swing.
## `calm` (1 hip .. ads_motion_mult at full ADS) damps breathing and bob.
func pivot_xf(calm: float) -> Transform3D:
	var b: Dictionary = cfg["breath"]
	# Breathing fades out with ADS (1 - ads) so the red dot rests on the centre at full ADS.
	var breath_w := lerpf(1.0, float(b["moving_mult"]), _walk) * calm * (1.0 - _ads_prev)
	var bp := sin(_time * TAU * float(b["hz"]))
	var pos := ViewMesh.vec(b["pos_m"]) * Vector3(sin(_time * TAU * float(b["hz"]) * 0.5), bp, 0.0) * breath_w
	var rot := ViewMesh.vec(b["rot_deg"]) * Vector3(bp, sin(_time * TAU * float(b["hz"]) * 0.5), cos(_time * TAU * float(b["hz"]) * 0.7)) * breath_w
	var bob_w := _walk * lerpf(1.0, float(cfg["sprint"]["bob_mult"]), _sprint) * calm
	var w: Dictionary = cfg["walk"]
	var bob := ViewMesh.vec(w["pos_m"]) * bob_w
	var bob_rot := ViewMesh.vec(w["rot_deg"]) * bob_w
	# Sideways once per stride, down twice (each footfall), a little forward push and roll with each step.
	pos += Vector3(sin(_step_phase) * bob.x, -absf(sin(_step_phase)) * bob.y + bob.y * 0.5, cos(_step_phase * 2.0) * bob.z)
	rot += Vector3(-absf(cos(_step_phase)) * bob_rot.x, sin(_step_phase) * bob_rot.y, sin(_step_phase) * bob_rot.z)
	if _land_t >= 0.0:
		var l: Dictionary = cfg["land"]
		var p := _land_t / float(l["s"])
		var dip := smoothstep(0.0, 0.25, p) * (1.0 - smoothstep(0.25, 1.0, p))  # quick drop, slow recovery
		pos.y -= _land_amount * dip
		rot.x -= float(l["pitch_deg"]) * dip * (_land_amount / maxf(float(l["max_m"]), 0.0001))
	var swing := _swing_pose()
	var lower := Transform3D(_deg(Vector3(-lower_deg(), 0.0, 0.0)), Vector3.ZERO)
	return lower * Transform3D(_deg(rot + swing[1]), pos + swing[0])


## Grip-space offset: sprint pose, ADS settle, kick spring, reload tilt, switch and pickup lower / raise. `melee`: the
## blade (pointing up) lowers with its own tilt (melee_rot_deg) so its long tip stays inside the reach.
func weapon_xf(kick_mult: float, melee: bool = false) -> Transform3D:
	var tilt_key := "melee_rot_deg" if melee else "rot_deg"
	var s: Dictionary = cfg["sprint"]
	var sw := smoothstep(0.0, 1.0, _sprint)
	var pos := ViewMesh.vec(s["pos_m"]) * sw
	var rot := ViewMesh.vec(s["rot_deg"]) * sw
	# The settle pushes along the sight line (grip z, away from the eye while raising), so a red dot on the centre ray
	# stays on it.
	pos.z -= _settle.x * float(cfg["ads"]["settle_m"])
	for i in 3:
		pos[i] += (_kick_pos[i] as Spring).x * kick_mult
		rot[i] += (_kick_rot[i] as Spring).x * kick_mult
	if reload_total > 0.0:
		var r: Dictionary = cfg["reload"]
		var tilt := _reload_tilt()
		pos += ViewMesh.vec(r["tilt_pos_m"]) * tilt
		rot += ViewMesh.vec(r["tilt_rot_deg"]) * tilt
		if reload_stage() == "charge":
			var c := sin(PI * reload_stage_progress())
			rot += ViewMesh.vec(r["charge_rot_deg"]) * c
	if switch_total > 0.0:
		var p := clampf(switch_t / switch_total, 0.0, 1.0)
		var sc: Dictionary = cfg["switch"]
		rot += ViewMesh.vec(sc.get(tilt_key, sc["rot_deg"])) * switch_lower()
		if p > 0.5:  # a small overshoot as the new weapon arrives
			rot.x += float(sc["overshoot_deg"]) * sin(PI * (p - 0.5) * 2.0)
	if pickup_total > 0.0:
		var pc: Dictionary = cfg["pickup"]
		rot += ViewMesh.vec(pc.get(tilt_key, pc["rot_deg"])) * pickup_lower()
	return Transform3D(_deg(rot), pos)


## 0..1..0 over a switch: how far the old weapon is lowered (out at the half), then the new one rises.
func switch_lower() -> float:
	if switch_total <= 0.0:
		return 0.0
	return sin(PI * clampf(switch_t / switch_total, 0.0, 1.0))


## The lowering of a switch or pickup as a pitch about the EYE (degrees, downward): a rotation about the camera keeps
## every vertex at its distance, so the model leaves the view without leaving max_reach_m.
func lower_deg() -> float:
	return float(cfg["switch"]["drop_deg"]) * switch_lower() + float(cfg["pickup"]["drop_deg"]) * pickup_lower()


## 0..1: how far a pickup has lowered the weapon (out by swap_at, then the new one rises).
func pickup_lower() -> float:
	if pickup_total <= 0.0:
		return 0.0
	var p := clampf(pickup_t / pickup_total, 0.0, 1.0)
	var at := float(cfg["pickup"]["swap_at"])
	return smoothstep(0.0, at, p) if p < at else 1.0 - smoothstep(at, 1.0, p)


## True from the pickup's swap point on (the new weapon is shown).
func pickup_swapped() -> bool:
	return pickup_total > 0.0 and pickup_t >= pickup_total * float(cfg["pickup"]["swap_at"])


func _reload_tilt() -> float:
	var stage := reload_stage()
	var p := reload_stage_progress()
	match stage:
		"tilt":
			return smoothstep(0.0, 1.0, p)
		"return":
			return 1.0 - smoothstep(0.0, 1.0, p)
	return 1.0


## The reload's current stage name ("" when not reloading) and its 0..1 progress.
func reload_stage() -> String:
	if reload_total <= 0.0:
		return ""
	var p := reload_t / reload_total
	var acc := 0.0
	var stages: Array = cfg["reload"]["stages"]
	var sum := 0.0
	for st: Array in stages:
		sum += float(st[1])
	for st: Array in stages:
		acc += float(st[1]) / sum
		if p < acc:
			return String(st[0])
	return String((stages[stages.size() - 1] as Array)[0])


func reload_stage_progress() -> float:
	if reload_total <= 0.0:
		return 0.0
	var p := reload_t / reload_total
	var stages: Array = cfg["reload"]["stages"]
	var sum := 0.0
	for st: Array in stages:
		sum += float(st[1])
	var start := 0.0
	for st: Array in stages:
		var span := float(st[1]) / sum
		if p < start + span:
			return clampf((p - start) / span, 0.0, 1.0)
		start += span
	return 1.0


## The cell's offset from its rest (weapon frame): out and down in cell_out, back up in cell_in.
func cell_offset() -> Transform3D:
	var r: Dictionary = cfg["reload"]
	var out := 0.0
	match reload_stage():
		"cell_out":
			out = smoothstep(0.0, 1.0, reload_stage_progress())
		"cell_in":
			out = 1.0 - smoothstep(0.0, 1.0, reload_stage_progress())
	return Transform3D(_deg(ViewMesh.vec(r["cell_out_rot_deg"]) * out), ViewMesh.vec(r["cell_out_m"]) * out)


## The charging handle's pull back (+z) during the charge stage: a quick pull and a snap forward.
func charge_offset() -> Vector3:
	if reload_stage() != "charge":
		return Vector3.ZERO
	var p := reload_stage_progress()
	var pull := smoothstep(0.15, 0.55, p) * (1.0 - smoothstep(0.6, 0.75, p))
	return Vector3(0.0, 0.0, float(cfg["reload"]["charge_pull_m"]) * pull)


## The left hand: {"target": "rest" | "cell" | "charge" | "reach", "weight": 0..1, "pose": name, "pose_from": name,
## "pose_t": 0..1}. "cell" follows the cell node; "reach" is a camera-frame point (pickup).
func left_hand() -> Dictionary:
	if pickup_total > 0.0:
		var p := clampf(pickup_t / pickup_total, 0.0, 1.0)
		var w := smoothstep(0.0, 0.35, p) * (1.0 - smoothstep(0.7, 1.0, p))
		return {"target": "reach", "weight": w, "pose": "open" if p < 0.4 else "reach", "pose_from": "foregrip", "pose_t": w}
	if reload_total > 0.0:
		var stage := reload_stage()
		var p := reload_stage_progress()
		match stage:
			"tilt":
				return {"target": "cell", "weight": smoothstep(0.5, 1.0, p) * 0.3, "pose": "reach", "pose_from": "foregrip", "pose_t": p}
			"hand_to_cell":
				return {"target": "cell", "weight": lerpf(0.3, 1.0, smoothstep(0.0, 1.0, p)), "pose": "grip", "pose_from": "reach", "pose_t": p}
			"cell_out", "cell_in":
				return {"target": "cell", "weight": 1.0, "pose": "grip", "pose_from": "grip", "pose_t": 1.0}
			"charge":
				var w := smoothstep(0.0, 0.25, p) * (1.0 - smoothstep(0.8, 1.0, p))
				return {"target": "charge", "weight": w, "pose": "grip", "pose_from": "reach", "pose_t": smoothstep(0.0, 0.3, p)}
			"return":
				return {"target": "charge", "weight": 0.0, "pose": "foregrip", "pose_from": "reach", "pose_t": p}
	return {"target": "rest", "weight": 0.0, "pose": "", "pose_from": "", "pose_t": 0.0}


## The swing alone as an eye-space transform (part of pivot_xf): the blade's free left hand undoes it so it keeps its
## guard while the sword arm cuts.
func swing_xf() -> Transform3D:
	var s := _swing_pose()
	return Transform3D(_deg(s[1]), s[0])


## The swing keys (anim.json swing.keys over swing_s): [pos, rot_deg] at the current time.
func _swing_pose() -> Array:
	if swing_total <= 0.0:
		return [Vector3.ZERO, Vector3.ZERO]
	var p := clampf(swing_t / swing_total, 0.0, 1.0)
	var keys: Array = cfg["swing"]["keys"]
	for i in range(1, keys.size()):
		var a: Dictionary = keys[i - 1]
		var b: Dictionary = keys[i]
		if p <= float(b["t"]) or i == keys.size() - 1:
			var u := clampf((p - float(a["t"])) / maxf(float(b["t"]) - float(a["t"]), 0.0001), 0.0, 1.0)
			match String(b.get("ease", "inout")):
				"in":
					u = u * u * u
				"out":
					u = 1.0 - pow(1.0 - u, 3.0)
				_:
					u = smoothstep(0.0, 1.0, u)
			return [ViewMesh.vec(a["pos_m"]).lerp(ViewMesh.vec(b["pos_m"]), u), ViewMesh.vec(a["rot_deg"]).lerp(ViewMesh.vec(b["rot_deg"]), u)]
	return [Vector3.ZERO, Vector3.ZERO]


## Names of the motions running now (tests and the capture tool): idle, walk, sprint, ads, fire, reload:<stage>,
## switch, pickup, swing, land.
func active() -> Array[String]:
	var out: Array[String] = []
	if _walk > 0.05:
		out.append("walk")
	if _sprint > 0.05:
		out.append("sprint")
	if _ads_prev > 0.05:
		out.append("ads")
	if absf((_kick_rot[0] as Spring).x) > 0.01 or absf((_kick_pos[2] as Spring).x) > 0.0001:
		out.append("fire")
	if reload_total > 0.0:
		out.append("reload:" + reload_stage())
	if switch_total > 0.0:
		out.append("switch")
	if pickup_total > 0.0:
		out.append("pickup")
	if swing_total > 0.0:
		out.append("swing")
	if _land_t >= 0.0:
		out.append("land")
	if out.is_empty():
		out.append("idle")
	return out
