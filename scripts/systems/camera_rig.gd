class_name CameraRig
extends Node3D
## Third-person SpringArm3D + Camera3D. FOV comes from data/camera.json by viewport aspect ratio.
## Path A: AMSG shoulder swap + GDQuest-style ADS over-shoulder pivot (code only; no NC art).
## Path A phase 2: Kenney-style camera knockback on fire (CameraKnockback). It is view only: it turns the rig, but
## get_aim_point casts from the un-kicked camera, so shots, Hitscan and the host's aim check never see it.

@onready var _arm: SpringArm3D = $SpringArm3D
@onready var _camera: Camera3D = $SpringArm3D/Camera3D

var _cfg: Dictionary = {}
## FOV from the aspect table, before any aim zoom.
var base_fov: float = 75.0
var _aim_blend: float = 0.0
var _aim_fov_mult: float = 1.0
## "right" | "left" - AMSG view_angle pattern via data/camera.json (no addon vendored).
var shoulder_side: String = "right"
## GDQuest camera_controller pattern: RayCast3D on the camera for ADS aim target.
var _aim_ray: RayCast3D
## View kick per shot and its recovery (data/camera.json camera_knockback_*).
var knockback: CameraKnockback = CameraKnockback.new()
## Look pitch from the pawn (radians, clamped), before the knockback offset is added.
var _look_pitch: float = 0.0
## Physics frame of the latest kick: that frame shows the kick whole, recovery starts on the next one.
var _kick_frame: int = -1
## Presentation blend: x is the lateral offset, y the hip arm length before ADS.
var _shoulder_from: Vector2 = Vector2.ZERO
var _shoulder_target: Vector2 = Vector2.ZERO
var _shoulder_hip_length: float = 0.0
var _shoulder_elapsed_s: float = 0.0
var _shoulder_duration_s: float = 0.0


## Picks the first table row (sorted by min_aspect descending) the aspect satisfies.
static func fov_for_aspect(cfg: Dictionary, aspect: float) -> float:
	var rows: Array = cfg.get("fov_table", []).duplicate()
	rows.sort_custom(func(a, b): return float(a["min_aspect"]) > float(b["min_aspect"]))
	for row in rows:
		if aspect >= float(row["min_aspect"]):
			return float(row["fov_deg"])
	return 75.0


func _ready() -> void:
	_cfg = DataRegistry.new().get_camera_cfg()
	shoulder_side = str(_cfg.get("shoulder_side", "right"))
	position.y = float(_cfg.get("height_m", 1.6))
	knockback.configure(_cfg)
	_apply_shoulder()
	_ensure_aim_ray()
	get_viewport().size_changed.connect(apply_fov)
	apply_fov()


## Recovers the knockback. The pawn (this rig's parent) runs first in a physics frame and may kick during it, so a
## kick from the current frame is left whole for one frame.
func _physics_process(delta: float) -> void:
	_tick_shoulder(delta)
	if knockback.offset == Vector2.ZERO or Engine.get_physics_frames() == _kick_frame:
		return
	knockback.tick(delta)
	_apply_rotation()


## Creates a camera-forward RayCast3D (GDQuest CameraRayCast pattern). Code only ? no demo scenes.
func _ensure_aim_ray() -> void:
	if _aim_ray != null or _camera == null:
		return
	_aim_ray = RayCast3D.new()
	_aim_ray.name = "AimRayCast"
	_aim_ray.enabled = true
	_aim_ray.collide_with_areas = true
	_aim_ray.collision_mask = Hitscan.MASK_WORLD | Hitscan.MASK_BODY | Hitscan.MASK_HEAD
	var far_m := float(_cfg["aim_ray_length_m"]["value"])
	_aim_ray.target_position = Vector3(0.0, 0.0, -far_m)
	_camera.add_child(_aim_ray)


## Applies spring_length + lateral arm offset for the current shoulder_side from camera.json.
func _apply_shoulder(ease_motion: bool = false) -> void:
	var right_x := float(_cfg["shoulder_offset_m"]["value"])
	var left_entry: Dictionary = _cfg.get("shoulder_offset_left_m", {"value": -right_x})
	var left_x := float(left_entry.get("value", -right_x))
	var use_left := shoulder_side == "left"
	# SpringArm3D rewrites its child camera's transform every physics frame (measured: tools/measure_shoulder.gd),
	# so the shoulder offset goes on the arm itself.
	_shoulder_from = Vector2(_arm.position.x, _shoulder_hip_length)
	_shoulder_target = Vector2(left_x if use_left else right_x, _hip_arm_length())
	_shoulder_elapsed_s = 0.0
	var entry: Dictionary = _cfg.get("shoulder_ease_s", {})
	_shoulder_duration_s = maxf(0.0, float(entry.get("value", 0.0))) if ease_motion else 0.0
	if _shoulder_duration_s <= 0.0:
		_arm.position.x = _shoulder_target.x
		_shoulder_hip_length = _shoulder_target.y
	_apply_arm_length()


## Smoothstep between the current pose and the new side; rapid swaps restart from that pose.
## No aim undo: the existing AimRayCast follows the camera throughout the move.
func _tick_shoulder(delta: float) -> void:
	if _shoulder_duration_s <= 0.0:
		return
	_shoulder_elapsed_s = minf(_shoulder_elapsed_s + maxf(delta, 0.0), _shoulder_duration_s)
	var weight := smoothstep(0.0, 1.0, _shoulder_elapsed_s / _shoulder_duration_s)
	var pose := _shoulder_from.lerp(_shoulder_target, weight)
	if _shoulder_elapsed_s >= _shoulder_duration_s:
		pose = _shoulder_target
		_shoulder_duration_s = 0.0
	_arm.position.x = pose.x
	_shoulder_hip_length = pose.y
	_apply_arm_length()


func _hip_arm_length() -> float:
	var use_left := shoulder_side == "left"
	if use_left and _cfg.has("arm_length_left_m"):
		return float(_cfg["arm_length_left_m"]["value"])
	return float(_cfg.get("arm_length_m", 3.5))


func _aim_arm_length() -> float:
	if _cfg.has("arm_length_aim_m"):
		return float(_cfg["arm_length_aim_m"]["value"])
	return _shoulder_hip_length


## GDQuest OVER_SHOULDER vs THIRD_PERSON: blend spring_length between hip and ADS lengths.
func _apply_arm_length() -> void:
	if _arm == null:
		return
	_arm.spring_length = lerpf(_shoulder_hip_length, _aim_arm_length(), _aim_blend)


## AMSG-style right/left shoulder swap. Unknown sides fall back to right.
func set_shoulder_side(side: String) -> void:
	var next_side := "left" if side == "left" else "right"
	if next_side == shoulder_side:
		return
	shoulder_side = next_side
	if _arm != null:
		_apply_shoulder(true)


func swap_shoulder() -> void:
	set_shoulder_side("left" if shoulder_side == "right" else "right")


func apply_fov() -> void:
	var size := get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		return
	base_fov = fov_for_aspect(_cfg, size.x / size.y)
	_apply_zoom()


## Aim zoom + over-shoulder pivot: blend FOV and spring_length toward ADS values.
func set_aim_blend(blend: float, fov_mult: float) -> void:
	_aim_blend = clampf(blend, 0.0, 1.0)
	_aim_fov_mult = fov_mult
	_apply_zoom()
	_apply_arm_length()


## Sync SpringArm + AimRayCast exclusions (GDQuest add_excluded_object / add_exception_rid pattern).
func set_aim_excludes(exclude: Array[RID]) -> void:
	if _arm != null:
		_arm.clear_excluded_objects()
		for rid in exclude:
			_arm.add_excluded_object(rid)
	if _aim_ray != null:
		_aim_ray.clear_exceptions()
		for rid in exclude:
			_aim_ray.add_exception_rid(rid)


## World aim point: prefer AimRayCast hit (GDQuest), else AimMath camera-centre ray. The ray is cast from the
## un-kicked camera, so a knockback in progress never moves the aim.
func get_aim_point(exclude: Array[RID]) -> Vector3:
	set_aim_excludes(exclude)
	var far_m := float(_cfg["aim_ray_length_m"]["value"])
	if _aim_ray != null and _aim_ray.is_inside_tree():
		_aim_ray.transform = _knockback_undo()
		_aim_ray.target_position = Vector3(0.0, 0.0, -far_m)
		_aim_ray.force_raycast_update()
		if _aim_ray.is_colliding():
			return _aim_ray.get_collision_point()
		return _aim_ray.global_transform * _aim_ray.target_position
	# Unreachable in a match: _ready always adds the AimRayCast under the scene's Camera3D. This fallback casts from
	# the camera as it is, so it would include a knockback in progress.
	return AimMath.camera_aim_point(_camera, exclude, far_m)


func get_camera() -> Camera3D:
	return _camera


## Path A / P0c: force this rig camera current (tps-demo authority make_current pattern). True iff the viewport presents it.
func ensure_current() -> bool:
	if _camera == null or not _camera.is_inside_tree():
		return false
	_camera.make_current()
	return get_viewport().get_camera_3d() == _camera


func get_fov() -> float:
	return _camera.fov


func get_aim_blend() -> float:
	return _aim_blend


func get_spring_length() -> float:
	return _arm.spring_length if _arm != null else 0.0


func _apply_zoom() -> void:
	_camera.fov = base_fov * lerpf(1.0, _aim_fov_mult, _aim_blend)


## Orients the rig; pitch in radians, clamped by data. Any knockback in progress is added on top.
func set_pitch(pitch: float) -> void:
	_look_pitch = _clamp_pitch(pitch)
	_apply_rotation()


## Kenney-style kick for one ranged shot (the pawn calls it). Returns the kick added (x pitch, y yaw, radians).
func apply_knockback() -> Vector2:
	var add := knockback.kick()
	_kick_frame = Engine.get_physics_frames()
	_apply_rotation()
	return add


## Current knockback offset in radians (x pitch, + up; y yaw); zero at rest.
func get_knockback() -> Vector2:
	return knockback.offset


func _clamp_pitch(pitch: float) -> float:
	var lo := deg_to_rad(float(_cfg.get("pitch_min_deg", -70.0)))
	var hi := deg_to_rad(float(_cfg.get("pitch_max_deg", 70.0)))
	return clampf(pitch, lo, hi)


## Look pitch plus the knockback offset. The kicked pitch stays inside the data limits; the yaw kick turns the rig
## about the pawn's vertical axis (the pawn's own yaw is the look yaw).
func _apply_rotation() -> void:
	rotation.x = _clamp_pitch(_look_pitch + knockback.offset.x)
	rotation.y = knockback.offset.y


## AimRayCast pose on the camera that undoes the knockback: identity at rest, else the un-kicked camera seen from the
## kicked one. Un-kicked camera = the parent's frame * the rig at the look pitch only * the camera's pose in the rig.
func _knockback_undo() -> Transform3D:
	if knockback.offset == Vector2.ZERO:
		return Transform3D.IDENTITY
	var cam := _camera.global_transform
	var parent_xf := global_transform * transform.affine_inverse()
	var look_xf := Transform3D(Basis.from_euler(Vector3(_look_pitch, 0.0, 0.0)), position)
	return cam.affine_inverse() * parent_xf * look_xf * global_transform.affine_inverse() * cam
