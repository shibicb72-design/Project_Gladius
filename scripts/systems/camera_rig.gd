class_name CameraRig
extends Node3D
## Third-person SpringArm3D + Camera3D. FOV comes from data/camera.json by viewport aspect ratio.
## M2 C1a: a first-person mode for the local player walking (spring length 0, rig at eye height), blended from and to
## the third-person view (cover, carrier, falling, downed); see is_first_person and data/camera.json first_person.
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
var _cover_follow_active := false
var _cover_follow_position := Vector3.ZERO
## Shoulder pose x (lateral arm offset) before the first-person weight scales it away.
var _shoulder_x: float = 0.0
## M2 C1a first-person mode (data/camera.json first_person, OQ-FIRST-PERSON). Weight 0 = third person (today's
## numbers), 1 = first person (spring 0, no side offset, rig at eye height). Decided per physics frame, never cached.
var _fp_cfg: Dictionary = {}
var _fp_weight: float = 0.0
var _fp_from: float = 0.0
var _fp_target: float = 0.0
var _fp_elapsed_s: float = 0.0
var _fp_duration_s: float = 0.0
var _fp_evaluated := false
## M2 C1a stage 2: the local player's first-person view model under the camera (scripts/visual/view_model.gd).
var _view_model: ViewModel


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
	_fp_cfg = _cfg.get("first_person", {})
	shoulder_side = str(_cfg.get("shoulder_side", "right"))
	position.y = float(_cfg.get("height_m", 1.6))
	knockback.configure(_cfg)
	_apply_shoulder()
	_ensure_aim_ray()
	get_viewport().size_changed.connect(apply_fov)
	apply_fov()
	# The first evaluation snaps, so a rig attached to a walking local pawn starts in first person (no blend).
	_tick_first_person(0.0)
	_ensure_view_model()


## Recovers the knockback. The pawn (this rig's parent) runs first in a physics frame and may kick during it, so a
## kick from the current frame is left whole for one frame.
func _physics_process(delta: float) -> void:
	_tick_first_person(delta)
	_ensure_view_model()
	_tick_cover_follow(delta)
	_tick_shoulder(delta)
	if knockback.offset == Vector2.ZERO or Engine.get_physics_frames() == _kick_frame:
		return
	knockback.tick(delta)
	_apply_rotation()


## First person is wanted iff the parent is the local player's pawn (a Pawn with no Brain, the pawn.gd cover-gate
## check), ALIVE, on the ground (not aboard the carrier or falling) and with cover FREE or absent. Everything else,
## including a rig with no Pawn parent, is today's third person.
func is_first_person() -> bool:
	var pawn := get_parent() as Pawn
	if pawn == null or pawn.has_node("Brain"):
		return false
	if pawn.life != Pawn.Life.ALIVE or pawn.drop_state != Pawn.Drop.NONE:
		return false
	return pawn.cover == null or pawn.cover.state == CoverController.State.FREE


## Lazily gives the local player's pawn its view model (the rig is added after Pawn._ready, and a Brain may be removed
## later); ViewModel.attach returns null for every other parent, so the check repeats until it applies.
func _ensure_view_model() -> void:
	if _view_model == null or not is_instance_valid(_view_model):
		_view_model = ViewModel.attach(self)


func get_view_model() -> ViewModel:
	return _view_model if _view_model != null and is_instance_valid(_view_model) else null


## 0 = third person, 1 = first person; between them while the mode blend runs.
func get_first_person_weight() -> float:
	return _fp_weight


func _fp_value(key: String, fallback: float) -> float:
	var entry: Variant = _fp_cfg.get(key, {})
	if entry is Dictionary:
		return float((entry as Dictionary).get("value", fallback))
	return float(entry) if entry != null else fallback


## Smoothstep from the current weight to the wanted mode; a change mid-blend restarts from the current pose (like
## _tick_shoulder). The first evaluation snaps.
func _tick_first_person(delta: float) -> void:
	var target := 1.0 if is_first_person() else 0.0
	if not _fp_evaluated:
		_fp_evaluated = true
		_fp_target = target
		_fp_duration_s = 0.0
		_set_fp_weight(target)
		return
	if target != _fp_target:
		_fp_from = _fp_weight
		_fp_target = target
		_fp_elapsed_s = 0.0
		_fp_duration_s = maxf(0.0, _fp_value("blend_s", 0.0))
		if _fp_duration_s <= 0.0:
			_set_fp_weight(target)
			return
	if _fp_duration_s <= 0.0:
		return
	_fp_elapsed_s = minf(_fp_elapsed_s + maxf(delta, 0.0), _fp_duration_s)
	var weight := lerpf(_fp_from, _fp_target, smoothstep(0.0, 1.0, _fp_elapsed_s / _fp_duration_s))
	if _fp_elapsed_s >= _fp_duration_s:
		weight = _fp_target
		_fp_duration_s = 0.0
	_set_fp_weight(weight)


## Applies the weight to the spring length, the side offset, the FOV and (outside the cover follow) the rig height.
func _set_fp_weight(weight: float) -> void:
	var changed := weight != _fp_weight
	_fp_weight = weight
	if _arm != null:
		_arm.position.x = _shoulder_x * (1.0 - _fp_weight)
	_apply_arm_length()
	if _camera != null:
		_apply_zoom()
	if changed and not _cover_follow_active:
		position.y = _rig_height()


## Rig pivot height: today's height_m in third person, the eye in first person.
func _rig_height() -> float:
	var third := float(_cfg.get("height_m", 1.6))
	return lerpf(third, _fp_value("eye_height_m", third), _fp_weight)

## Presentation-only translation damping. FREE follows the original parent exactly.
func _tick_cover_follow(delta: float) -> void:
	var pawn := get_parent() as Pawn
	if pawn == null or pawn.cover == null or pawn.cover.state == CoverController.State.FREE:
		if _cover_follow_active:
			position.x = 0.0
			position.z = 0.0
			position.y = _rig_height()
		_cover_follow_active = false
		return
	var desired := pawn.global_transform * Vector3(0, _rig_height(), 0)
	if not _cover_follow_active:
		_cover_follow_position = desired
		_cover_follow_active = true
	var duration := float(pawn.cover.config["camera_follow_damping_s"])
	_cover_follow_position = _cover_follow_position.lerp(desired, 1.0 - exp(-delta / duration) if duration > 0.0 else 1.0)
	global_position = _cover_follow_position


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
	_shoulder_from = Vector2(_shoulder_x, _shoulder_hip_length)
	_shoulder_target = Vector2(left_x if use_left else right_x, _hip_arm_length())
	_shoulder_elapsed_s = 0.0
	var entry: Dictionary = _cfg.get("shoulder_ease_s", {})
	_shoulder_duration_s = maxf(0.0, float(entry.get("value", 0.0))) if ease_motion else 0.0
	if _shoulder_duration_s <= 0.0:
		_set_shoulder_x(_shoulder_target.x)
		_shoulder_hip_length = _shoulder_target.y
	_apply_arm_length()


## The side offset does not apply in first person: the first-person weight scales it to 0.
func _set_shoulder_x(x: float) -> void:
	_shoulder_x = x
	_arm.position.x = _shoulder_x * (1.0 - _fp_weight)


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
	_set_shoulder_x(pose.x)
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


## GDQuest OVER_SHOULDER vs THIRD_PERSON: blend spring_length between hip and ADS lengths. The first-person weight
## then pulls it to 0, so ADS in first person never moves the camera off the eye.
func _apply_arm_length() -> void:
	if _arm == null:
		return
	_arm.spring_length = lerpf(lerpf(_shoulder_hip_length, _aim_arm_length(), _aim_blend), 0.0, _fp_weight)


## AMSG-style right/left shoulder swap. Unknown sides fall back to right. Ignored in first person (M2 C1a: the
## shoulder has no meaning there); the third-person cover view keeps it.
func set_shoulder_side(side: String) -> void:
	if is_first_person():
		return
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
	var vm := get_view_model()
	if vm != null:
		vm.set_aim_blend(_aim_blend)  # M2 C1a stage 3: the view model raises the gun to the sight


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
	_camera.fov = base_fov * lerpf(1.0, _fp_value("fov_mult", 1.0), _fp_weight) * lerpf(1.0, _aim_fov_mult, _aim_blend)


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
