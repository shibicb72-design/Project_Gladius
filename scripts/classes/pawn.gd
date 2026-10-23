class_name Pawn
extends CharacterBody3D
## Driven only by an InputFrame, so humans, bots and network peers share it.

signal fired
## Every shot of the active weapon, for the network layer: a client forwards it to the host.
signal shot(origin: Vector3, direction: Vector3, weapon_id: String)
## A local reload started / the active slot changed, for the network layer (reliable host sync).
signal reload_started
signal weapon_switched(slot: int)
## Presentation signals (HUD, shot visuals). `hit` is the Hitscan result ({} on a miss).
signal shot_resolved(origin: Vector3, end: Vector3, hit: Dictionary)
## Reload tapped but not started: reason "full" or "no_reserve".
signal reload_rejected(reason: String)
## Fire pressed with an empty magazine.
signal fire_empty

## LOCAL: full simulation (offline, host, own pawn on a client).
## HOST_REMOTE: remote human on the host; moved only by accepted net input, never fires by itself.
## REPLICA: client copy of a pawn simulated elsewhere; state comes from snapshots.
enum NetMode { LOCAL, HOST_REMOTE, REPLICA }

## stats.json "melee" keys receive_melee needs, checked in this order (first missing one is reported).
const MELEE_REQUIRED_KEYS: Array[String] = ["melee_back_angle_deg", "melee_front_shield_fraction",
		"front_breaks_full_shield_classes"]

@export var class_id: String = "hastati"
@export var squad_id: int = 0

var registry: DataRegistry = DataRegistry.new()
var bridge: PawnRulesBridge
## Test seam, unused at runtime: a non-empty dictionary replaces registry.get_melee_cfg(); a valid
## melee_error_sink receives the error text instead of push_error (so tests stay free of ERROR: lines).
var melee_cfg_override: Dictionary = {}
var melee_error_sink: Callable = Callable()
var loadout: Loadout
var class_def: ClassDef
## Called as authority.call(attacker, target, weapon_def, is_headshot). Defaults to local resolution.
var hit_authority: Callable = Callable(self, "_local_authority")
var pitch: float = 0.0
var net_mode: NetMode = NetMode.LOCAL
## True while the Aim button is held (InputFrame.aim_pressed); read by the shot code and the zoom.
var aiming: bool = false
## 0..1 aim zoom blend, eased by stats.json aim.aim_zoom_s.
var aim_blend: float = 0.0
var shot_fx: ShotFx
## 1.0 at run speed, up to stats.json movement.sprint_speed_multiplier at full sprint.
var sprint_factor: float = 1.0

var _frame: InputFrame = InputFrame.new()
var _aim: Dictionary = {}
var _movement: Dictionary = {}
var _camera: Dictionary = {}
var _clock: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("pawns")
	shot_fx = ShotFx.new()
	shot_fx.name = "ShotFx"
	add_child(shot_fx)
	setup(class_id, squad_id)


func setup(new_class_id: String, new_squad_id: int) -> void:
	class_id = new_class_id
	squad_id = new_squad_id
	class_def = registry.get_class_def(class_id)
	_movement = registry.get_movement_cfg()
	_camera = registry.get_camera_cfg()
	_aim = registry.get_aim_cfg()
	bridge = PawnRulesBridge.new(class_def, squad_id, registry.get_combat_cfg())
	loadout = Loadout.from_class(class_id, registry)
	_rng.randomize()


func set_frame(frame: InputFrame) -> void:
	_frame = frame


## Pawn simulation clock (s); the time base of Weapon reload progress.
func get_clock() -> float:
	return _clock


func is_alive() -> bool:
	return bridge != null and not bridge.state.is_dead()


## Enables or disables the pawn (dead pawns are hidden and not hittable).
func set_active(active: bool) -> void:
	visible = active
	collision_layer = 2 if active else 0
	var head := get_node_or_null("Head")
	if head != null:
		head.collision_layer = 4 if active else 0
	set_physics_process(active)


## Fresh health and loadout at a new position; the caller sets protection.
func respawn_at(xform: Transform3D) -> void:
	bridge = PawnRulesBridge.new(class_def, squad_id, registry.get_combat_cfg())
	loadout = Loadout.from_class(class_id, registry)
	global_transform = xform
	velocity = Vector3.ZERO
	pitch = 0.0
	set_active(true)


## Class speed_pct applied to the base speed (m/s).
func get_move_speed() -> float:
	var pct: float = class_def.speed_pct if class_def != null else 100.0
	return float(_movement.get("base_speed_mps", 5.0)) * pct / 100.0


func receive_hit(weapon_def: WeaponDef, is_headshot: bool, attacker_squad: int) -> DamageRules.HitResult:
	return bridge.take_hit(weapon_def, is_headshot, attacker_squad)


## Melee hit from `attacker` (DESIGN.md:15): front/back from this pawn's facing, rule numbers from
## stats.json "melee". Called by the hit authority instead of receive_hit for melee weapons.
## A missing melee key is a data error: the first one missing (in MELEE_REQUIRED_KEYS order) is
## reported, and the hit is invalid (no damage, blocked_reason "invalid_melee_cfg"); there are no defaults.
func receive_melee(attacker: Pawn) -> DamageRules.HitResult:
	var cfg: Dictionary = melee_cfg_override if not melee_cfg_override.is_empty() else registry.get_melee_cfg()
	for key in MELEE_REQUIRED_KEYS:
		if not cfg.has(key):
			return _invalid_melee(key)
	var behind := Melee.is_from_behind(global_position, -global_transform.basis.z, attacker.global_position,
			float(cfg["melee_back_angle_deg"]))
	var breaks: bool = attacker.class_id in cfg["front_breaks_full_shield_classes"]
	return bridge.take_melee(attacker.squad_id, behind, breaks, cfg)


func _invalid_melee(key: String) -> DamageRules.HitResult:
	var bad := DamageRules.HitResult.new()
	bad.blocked_reason = "invalid_melee_cfg"
	var msg := "stats.json melee.%s is missing; melee hit ignored" % key
	if melee_error_sink.is_valid():
		melee_error_sink.call(msg)
	else:
		push_error(msg)
	return bad


## Single source of the shot direction: muzzle -> the frame's camera-centre aim point when the frame has one
## (right-shoulder camera, GBTN4); otherwise pitch/yaw forward (bots, tests, frames without a camera).
func get_aim_direction() -> Vector3:
	if _frame.has_aim_point:
		var to := _frame.aim_point - get_muzzle_position()
		if to.length_squared() > 0.0001:
			return to.normalized()
	return (global_transform.basis * Vector3(0.0, sin(pitch), -cos(pitch))).normalized()


func get_muzzle_position() -> Vector3:
	return global_position + Vector3(0.0, float(_movement.get("muzzle_height_m", 1.3)), 0.0)


## Fires the active weapon once (one hitscan ray, or one melee swing). Returns the Hitscan result,
## or {"melee": true, "targets": [...]} for a swing.
func fire_shot() -> Dictionary:
	var w := loadout.get_active()
	if w == null:
		return {}
	fired.emit()
	shot.emit(get_muzzle_position(), get_aim_direction(), w.def.id)
	if w.def.is_melee():
		return melee_swing(w.def, get_muzzle_position(), get_aim_direction(), hit_authority)
	var origin := get_muzzle_position()
	var dir := get_aim_direction()
	var res := Hitscan.fire(get_world_3d().direct_space_state, self, origin, dir, w.def, hitscan_exclude(),
			hit_authority, _rng, get_spread_mult())
	var end: Vector3 = res["position"] if res.has("position") else origin + dir * w.def.range_m
	show_shot_fx(origin, end)
	shot_resolved.emit(origin, end, res)
	return res


## Spread multiplier for the next shot: stats.json aim.aim_spread_mult while aiming, else 1.
func get_spread_mult() -> float:
	return float(_aim["aim_spread_mult"]) if aiming else 1.0


## Muzzle flash and tracer; also called for shots replicated from other peers.
func show_shot_fx(origin: Vector3, end: Vector3) -> void:
	if shot_fx != null:
		shot_fx.show_shot(origin, end)


## One melee swing from `origin` along `direction`; shows the placeholder swing visual.
func melee_swing(def: WeaponDef, origin: Vector3, direction: Vector3, authority: Callable) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state if is_inside_tree() else null
	var candidates: Array = get_tree().get_nodes_in_group("pawns") if is_inside_tree() else []
	var hit := Melee.swing(space, self, origin, direction, def, candidates, authority)
	if is_inside_tree():
		SwingVisual.spawn(self, def, direction)
	return {"melee": true, "targets": hit}


## Own body and head hitbox, so steep upward shots cannot hit the shooter.
func hitscan_exclude() -> Array[RID]:
	var out: Array[RID] = [get_rid()]
	var head := get_node_or_null("Head") as Area3D
	if head != null:
		out.append(head.get_rid())
	return out


func _local_authority(attacker: Node, target: Node, weapon_def: WeaponDef, is_headshot: bool) -> void:
	if weapon_def.is_melee() and attacker is Pawn and target.has_method("receive_melee"):
		target.receive_melee(attacker)
	elif target.has_method("receive_hit"):
		target.receive_hit(weapon_def, is_headshot, attacker.squad_id)


func _physics_process(delta: float) -> void:
	if net_mode == NetMode.REPLICA:
		return
	_clock += delta
	bridge.tick(delta)
	if net_mode == NetMode.HOST_REMOTE:
		return
	_apply_look()
	_apply_aim(delta)
	_apply_movement(delta)
	_apply_weapon()


func _apply_look() -> void:
	rotate_y(-_frame.look.x)
	pitch = clampf(pitch - _frame.look.y, deg_to_rad(float(_camera.get("pitch_min_deg", -70.0))),
			deg_to_rad(float(_camera.get("pitch_max_deg", 70.0))))
	var rig := get_node_or_null("CameraRig")
	if rig != null:
		rig.set_pitch(pitch)


## Aim button held (InputFrame.aim_pressed): zooms the camera FOV and tightens spread; release eases back.
func _apply_aim(delta: float) -> void:
	aiming = _frame.aim_pressed
	var zoom_s: float = _aim["aim_zoom_s"]
	var target := 1.0 if aiming else 0.0
	aim_blend = target if zoom_s <= 0.0 else move_toward(aim_blend, target, delta / zoom_s)
	var rig := get_node_or_null("CameraRig")
	if rig != null:
		rig.set_aim_blend(aim_blend, float(_aim["aim_fov_mult"]))


## Highest speed the pawn can reach (sprint included); the host's movement validator uses it.
func get_max_move_speed() -> float:
	return get_move_speed() * float(_movement["sprint_speed_multiplier"]["value"])


## Eases sprint_factor between 1 (run) and sprint_speed_multiplier over sprint_ramp_s, both directions.
## The sprint request comes from InputFrame.sprint (hold timer / lock live in the input layer).
func _update_sprint_factor(delta: float) -> void:
	var mult: float = _movement["sprint_speed_multiplier"]["value"]
	var target := mult if _frame.sprint and _frame.move.y < 0.0 else 1.0
	var ramp_s: float = _movement["sprint_ramp_s"]["value"]
	sprint_factor = target if ramp_s <= 0.0 else move_toward(sprint_factor, target, (mult - 1.0) / ramp_s * delta)


func _apply_movement(delta: float) -> void:
	# Full analog speed: the wish speed scales continuously with the stick length (no walk/run step).
	# Sideways and backward are a ratio of forward speed (stats.json movement.strafe_back_ratio).
	_update_sprint_factor(delta)
	var ratio: float = _movement["strafe_back_ratio"]["value"]
	var local := Vector3(_frame.move.x * ratio, 0.0, _frame.move.y * (ratio if _frame.move.y > 0.0 else 1.0))
	var wish := global_transform.basis * local * get_move_speed() * sprint_factor
	velocity.x = _ramp_axis(velocity.x, wish.x, delta)
	velocity.z = _ramp_axis(velocity.z, wish.z, delta)
	if is_on_floor():
		if _frame.jump_just_pressed and bool(_movement.get("jump_enabled", false)):
			velocity.y = float(_movement.get("jump_velocity", 0.0))
	else:
		velocity.y -= float(_movement.get("gravity", 20.0)) * delta
	move_and_slide()


## One horizontal axis toward its wish value. The rate is base_speed_mps / ramp time, the same for every
## class (5.0 / 0.125 = 40 m/s^2 with the shipped data). Decel when the axis slows down or flips sign.
func _ramp_axis(cur: float, target: float, delta: float) -> float:
	var decelerating := absf(target) < absf(cur) or cur * target < 0.0
	var ramp_s: float = _movement["ground_decel" if decelerating else "ground_accel"]["time_s"]
	if ramp_s <= 0.0:
		return target
	return move_toward(cur, target, float(_movement["base_speed_mps"]) / ramp_s * delta)


func _apply_weapon() -> void:
	if _frame.swap_weapon_just_pressed and loadout.swap():
		weapon_switched.emit(loadout.active)
	var w := loadout.get_active()
	if w == null:
		return
	if _frame.reload_just_pressed:
		if w.start_reload(_clock):
			reload_started.emit()
		elif not w.def.is_melee() and not w.reloading:
			reload_rejected.emit("full" if w.ammo_in_mag >= w.def.magazine else "no_reserve")
	if _frame.fire_just_pressed and not w.has_ammo() and not w.reloading:
		fire_empty.emit()
	var shots := w.update(_clock, _frame.fire_pressed)
	for i in shots:
		fire_shot()
