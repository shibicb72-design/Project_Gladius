class_name Pawn
extends CharacterBody3D
## Driven only by an InputFrame, so humans, bots and network peers share it.

signal fired
## Every shot of the active weapon, for the network layer: a client forwards it to the host.
signal shot(origin: Vector3, direction: Vector3, weapon_id: String)
## A local reload started / the active slot changed, for the network layer (reliable host sync).
signal reload_started
signal weapon_switched(slot: int)

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

var _frame: InputFrame = InputFrame.new()
var _movement: Dictionary = {}
var _camera: Dictionary = {}
var _clock: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("pawns")
	setup(class_id, squad_id)


func setup(new_class_id: String, new_squad_id: int) -> void:
	class_id = new_class_id
	squad_id = new_squad_id
	class_def = registry.get_class_def(class_id)
	_movement = registry.get_movement_cfg()
	_camera = registry.get_camera_cfg()
	bridge = PawnRulesBridge.new(class_def, squad_id, registry.get_combat_cfg())
	loadout = Loadout.from_class(class_id, registry)
	_rng.randomize()


func set_frame(frame: InputFrame) -> void:
	_frame = frame


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


func get_aim_direction() -> Vector3:
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
	return Hitscan.fire(get_world_3d().direct_space_state, self, get_muzzle_position(),
			get_aim_direction(), w.def, hitscan_exclude(), hit_authority, _rng)


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
	_apply_movement(delta)
	_apply_weapon()


func _apply_look() -> void:
	rotate_y(-_frame.look.x)
	pitch = clampf(pitch - _frame.look.y, deg_to_rad(float(_camera.get("pitch_min_deg", -70.0))),
			deg_to_rad(float(_camera.get("pitch_max_deg", 70.0))))
	var rig := get_node_or_null("CameraRig")
	if rig != null:
		rig.set_pitch(pitch)


func _apply_movement(delta: float) -> void:
	var wish := global_transform.basis * Vector3(_frame.move.x, 0.0, _frame.move.y) * get_move_speed()
	var accel: float = float(_movement.get("accel", 40.0))
	velocity.x = move_toward(velocity.x, wish.x, accel * delta)
	velocity.z = move_toward(velocity.z, wish.z, accel * delta)
	if is_on_floor():
		if _frame.jump_just_pressed and bool(_movement.get("jump_enabled", false)):
			velocity.y = float(_movement.get("jump_velocity", 0.0))
	else:
		velocity.y -= float(_movement.get("gravity", 20.0)) * delta
	move_and_slide()


func _apply_weapon() -> void:
	if _frame.swap_weapon_just_pressed and loadout.swap():
		weapon_switched.emit(loadout.active)
	var w := loadout.get_active()
	if w == null:
		return
	if _frame.reload_just_pressed and w.start_reload(_clock):
		reload_started.emit()
	var shots := w.update(_clock, _frame.fire_pressed)
	for i in shots:
		fire_shot()
