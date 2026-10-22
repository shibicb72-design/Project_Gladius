class_name Pawn
extends CharacterBody3D
## Driven only by an InputFrame, so humans, bots and network peers share it.

signal fired
## Every shot of the active weapon, for the network layer: a client forwards it to the host.
signal shot(origin: Vector3, direction: Vector3, weapon_id: String)

## LOCAL: full simulation (offline, host, own pawn on a client).
## HOST_REMOTE: remote human on the host; moved only by accepted net input, never fires by itself.
## REPLICA: client copy of a pawn simulated elsewhere; state comes from snapshots.
enum NetMode { LOCAL, HOST_REMOTE, REPLICA }

const MUZZLE_HEIGHT_M := 1.3

@export var class_id: String = "hastati"
@export var squad_id: int = 0

var registry: DataRegistry = DataRegistry.new()
var bridge: PawnRulesBridge
var loadout: Loadout
var class_def: ClassDef
## Called as authority.call(attacker, target, weapon_def, is_headshot). Defaults to local resolution.
var hit_authority: Callable = Callable(self, "_local_authority")
var pitch: float = 0.0
var net_mode: NetMode = NetMode.LOCAL

var _frame: InputFrame = InputFrame.new()
var _movement: Dictionary = {}
var _clock: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	setup(class_id, squad_id)


func setup(new_class_id: String, new_squad_id: int) -> void:
	class_id = new_class_id
	squad_id = new_squad_id
	class_def = registry.get_class_def(class_id)
	_movement = registry.get_movement_cfg()
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


func get_aim_direction() -> Vector3:
	return (global_transform.basis * Vector3(0.0, sin(pitch), -cos(pitch))).normalized()


func get_muzzle_position() -> Vector3:
	return global_position + Vector3(0.0, MUZZLE_HEIGHT_M, 0.0)


## Fires the active weapon once (one hitscan ray). Returns the Hitscan result.
func fire_shot() -> Dictionary:
	var w := loadout.get_active()
	if w == null:
		return {}
	fired.emit()
	shot.emit(get_muzzle_position(), get_aim_direction(), w.def.id)
	return Hitscan.fire(get_world_3d().direct_space_state, self, get_muzzle_position(),
			get_aim_direction(), w.def, hitscan_exclude(), hit_authority, _rng)


## Own body and head hitbox, so steep upward shots cannot hit the shooter.
func hitscan_exclude() -> Array[RID]:
	var out: Array[RID] = [get_rid()]
	var head := get_node_or_null("Head") as Area3D
	if head != null:
		out.append(head.get_rid())
	return out


func _local_authority(attacker: Node, target: Node, weapon_def: WeaponDef, is_headshot: bool) -> void:
	if target.has_method("receive_hit"):
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
	pitch = clampf(pitch - _frame.look.y, deg_to_rad(-80.0), deg_to_rad(80.0))
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
	if _frame.swap_weapon_just_pressed:
		loadout.swap()
	var w := loadout.get_active()
	if w == null:
		return
	if _frame.reload_just_pressed:
		w.start_reload(_clock)
	var shots := w.update(_clock, _frame.fire_pressed)
	for i in shots:
		fire_shot()
