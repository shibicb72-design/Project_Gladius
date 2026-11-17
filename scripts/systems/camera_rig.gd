class_name CameraRig
extends Node3D
## Third-person SpringArm3D + Camera3D. FOV comes from data/camera.json by viewport aspect ratio.
## M2 C1a: a first-person mode for the local player walking (spring length 0, rig at eye height), blended from and to
## the third-person view (cover, carrier, falling, downed); see is_first_person and data/camera.json first_person.
## Stage 4: the local pawn's own body sits on first_person.body_layer (LocalBodyLayer), which this camera leaves out
## while the view model shows (is_body_hidden) and draws again in third person.
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
## M2 C1b stage 2: the close cover view (data/camera.json cover and cover_blend_s, OQ-COVER). _cover_w 1 = the third-
## person end of the first-person blend is the cover pose (cover.distance_m, side and height) instead of today's
## arm_length_m / shoulder offset / height_m. It is set to 1 or 0 only while the first-person weight is 1 (invisible),
## held while an exit blends back to first person, and eased over cover_blend_s for any other change.
var _cover_cfg: Dictionary = {}
var _cover_w: float = 0.0
## 0 = the idle cover pose, 1 = the tighter leaned-out pose (PEEK_LEFT / PEEK_RIGHT or the draw out); eased.
var _cover_out: float = 0.0
## The cover side (-1 left, +1 right, CoverController.side), eased with a smoothstep over cover.side_ease_s.
var _cover_side: float = 1.0
var _cover_side_from: float = 1.0
var _cover_side_to: float = 1.0
var _cover_side_t: float = 0.0
## The soldier's crouch as last seen in cover (lowers the cover pivot); held after the controller resets.
var _cover_crouch: float = 0.0
## The cover follow's lag at the moment it stops (world metres), eased out over cover_blend_s: the exit never snaps.
var _exit_residual := Vector3.ZERO
var _exit_t: float = 0.0
var _exit_s: float = 0.0


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
	_cover_cfg = _cfg.get("cover", {})
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
	_ensure_body_layer()


## Recovers the knockback. The pawn (this rig's parent) runs first in a physics frame and may kick during it, so a
## kick from the current frame is left whole for one frame.
func _physics_process(delta: float) -> void:
	_tick_cover_pose(delta)  # before the blend: an entry from full first person sets the cover pose invisibly
	_tick_first_person(delta)
	_ensure_view_model()
	_ensure_body_layer()
	_tick_cover_follow(delta)
	_tick_shoulder(delta)
	if knockback.offset == Vector2.ZERO or Engine.get_physics_frames() == _kick_frame:
		return
	knockback.tick(delta)
	_apply_rotation()


## First person is wanted iff the parent is the local player's pawn (a Pawn with no Brain, the pawn.gd cover-gate
## check), ALIVE, on the ground (not aboard the carrier or falling) and with cover FREE, EXITING or absent. Everything
## else, including a rig with no Pawn parent, is today's third person.
## M2 C1b stage 2 (fix 32): the exit blend starts when EXITING begins, not at FREE, so leaving cover is one move.
func is_first_person() -> bool:
	var pawn := get_parent() as Pawn
	if pawn == null or pawn.has_node("Brain"):
		return false
	if pawn.life != Pawn.Life.ALIVE or pawn.drop_state != Pawn.Drop.NONE:
		return false
	return not _holds_cover(pawn)


## M2 C1b stage 2: the parent pawn is in cover and not leaving it (ENTERING, IN_COVER, PEEK_LEFT, PEEK_RIGHT).
func _holds_cover(pawn: Pawn) -> bool:
	if pawn == null or pawn.cover == null:
		return false
	return pawn.cover.state != CoverController.State.FREE and pawn.cover.state != CoverController.State.EXITING


## M2 C1b stage 2: true while the rig shows (or blends to) the close cover view.
func in_cover_view() -> bool:
	return _holds_cover(get_parent() as Pawn)


func get_cover_weight() -> float:
	return _cover_w


func get_cover_side() -> float:
	return _cover_side


func _cover_value(key: String, fallback: float) -> float:
	var entry: Variant = _cover_cfg.get(key, {})
	if entry is Dictionary:
		return float((entry as Dictionary).get("value", fallback))
	return float(entry) if entry != null else fallback


## camera.json cover_blend_s: the FREE <-> cover blend (both ways), falling back to first_person.blend_s.
func cover_blend_s() -> float:
	var entry: Variant = _cfg.get("cover_blend_s", {})
	if entry is Dictionary and (entry as Dictionary).has("value"):
		return maxf(0.0, float((entry as Dictionary)["value"]))
	return maxf(0.0, _fp_value("blend_s", 0.0))


## Eases the cover pose: its weight, the leaned-out tightening, the side and the crouch height. Runs before the
## first-person blend each physics frame.
func _tick_cover_pose(delta: float) -> void:
	var pawn := get_parent() as Pawn
	var holding := _holds_cover(pawn)
	var hidden := _fp_weight >= 1.0  # the third-person end is invisible at full first person
	var blend := cover_blend_s()
	if holding:
		_cover_w = 1.0 if hidden or blend <= 0.0 else move_toward(_cover_w, 1.0, delta / blend)
	elif hidden or blend <= 0.0:
		_cover_w = 0.0
	elif not is_first_person():
		_cover_w = move_toward(_cover_w, 0.0, delta / blend)  # cover -> another third-person mode (downed)
	# else: an exit blending back to first person holds the cover pose, so only the first-person weight moves.
	var out_target := 0.0
	var side_target := _cover_side_to
	if pawn != null and pawn.cover != null and pawn.cover.state != CoverController.State.FREE:
		var c := pawn.cover
		if holding and (c.state == CoverController.State.PEEK_LEFT or c.state == CoverController.State.PEEK_RIGHT or c.aim_out_amount > 0.0):
			out_target = 1.0
		side_target = -1.0 if c.side < 0 else 1.0
		_cover_crouch = c.crouch_amount
	var out_s := _cover_value("out_ease_s", 0.0)
	_cover_out = out_target if out_s <= 0.0 else move_toward(_cover_out, out_target, delta / out_s)
	if hidden:
		_cover_side = side_target
		_cover_side_from = side_target
		_cover_side_to = side_target
		_cover_side_t = 0.0
	else:
		if side_target != _cover_side_to:
			_cover_side_from = _cover_side
			_cover_side_to = side_target
			_cover_side_t = 0.0
		var side_s := _cover_value("side_ease_s", 0.0)
		_cover_side_t = minf(_cover_side_t + maxf(delta, 0.0), side_s)
		_cover_side = _cover_side_to if side_s <= 0.0 else lerpf(_cover_side_from, _cover_side_to, smoothstep(0.0, 1.0, _cover_side_t / side_s))
	_apply_third_pose()


## Side offset, spring length and (outside the cover follow) pivot height for the current weights.
func _apply_third_pose() -> void:
	if _arm != null:
		_arm.position.x = _third_x() * (1.0 - _fp_weight)
	_apply_arm_length()


## The cover pose's lateral offset: away from the wall toward the open side. Looking along the wall toward side s, the
## view's right is the wall normal times s, so +offset * s is always on the open side.
func _cover_x() -> float:
	var o := smoothstep(0.0, 1.0, _cover_out)
	return lerpf(_cover_value("side_offset_m", 0.0), _cover_value("out_side_offset_m", 0.0), o) * _cover_side


func _cover_length() -> float:
	var o := smoothstep(0.0, 1.0, _cover_out)
	return lerpf(_cover_value("distance_m", _shoulder_hip_length), _cover_value("out_distance_m", _shoulder_hip_length), o)


func _cover_height() -> float:
	var stand := _cover_value("height_m", float(_cfg.get("height_m", 1.6)))
	return lerpf(stand, _cover_value("crouch_height_m", stand), clampf(_cover_crouch, 0.0, 1.0))


func _third_x() -> float:
	return lerpf(_shoulder_x, _cover_x(), _cover_w)


## Lazily gives the local player's pawn its view model (the rig is added after Pawn._ready, and a Brain may be removed
## later); ViewModel.attach returns null for every other parent, so the check repeats until it applies.
func _ensure_view_model() -> void:
	if _view_model == null or not is_instance_valid(_view_model):
		_view_model = ViewModel.attach(self)


func get_view_model() -> ViewModel:
	return _view_model if _view_model != null and is_instance_valid(_view_model) else null


## Stage 4: the render layer of the local player's own body (camera.json first_person.body_layer; 0 = no hide).
func get_body_layer() -> int:
	return int(_fp_value("body_layer", 0.0))


## Lazily puts the local player's pawn body on the body layer (the rig is added after Pawn._ready, and a Brain may be
## removed later); the pawn ignores the call unless it is the local player. Independent of net_mode.
func _ensure_body_layer() -> void:
	var pawn := get_parent() as Pawn
	if pawn != null:
		pawn.ensure_local_body_layer(get_body_layer())


## True while this camera leaves the body layer out: from the first-person weight at which the view model shows
## (view_model.show_weight, the same rule as ViewModel._update), so body and view model swap in one physics frame.
func is_body_hidden() -> bool:
	var vm_cfg: Dictionary = _fp_cfg.get("view_model", {})
	var entry: Variant = vm_cfg.get("show_weight", {})
	var show_from := float((entry as Dictionary).get("value", 1.0)) if entry is Dictionary else 1.0
	return get_body_layer() > 0 and _fp_weight > 0.0 and _fp_weight >= show_from


func _apply_body_cull() -> void:
	var layer := get_body_layer()
	if _camera == null or layer <= 0:
		return
	var body_bit := 1 << (layer - 1)
	_camera.cull_mask = (_camera.cull_mask & ~body_bit) if is_body_hidden() else (_camera.cull_mask | body_bit)


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
		# M2 C1b stage 2 (fix 12): into cover and every exit from cover use cover_blend_s; carrier, falling and downed
		# keep first_person.blend_s.
		var cover_change := (target == 0.0 and in_cover_view()) or (target == 1.0 and _cover_w > 0.0)
		_fp_duration_s = cover_blend_s() if cover_change else maxf(0.0, _fp_value("blend_s", 0.0))
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
	_apply_third_pose()
	if _camera != null:
		_apply_zoom()
		_apply_body_cull()
	if changed and not _cover_follow_active:
		position.y = _rig_height()


## Rig pivot height: today's height_m in third person (the cover pose's height in cover), the eye in first person.
func _rig_height() -> float:
	var third := lerpf(float(_cfg.get("height_m", 1.6)), _cover_height(), _cover_w)
	return lerpf(third, _fp_value("eye_height_m", third) * _crouch_eye_scale(), _fp_weight)

# M2 H1c item 4 (OQ-CROUCH): the first-person eye lowers with Pawn.crouch_amount() by the same scale as the head hitbox
# (Pawn.crouch_height_scale), so eye, head and muzzle move together. The third-person end keeps its own numbers (the
# cover pose's crouch height above); outside cover the free crouch only happens in first person (is_first_person).
# _tick_cover_follow re-places the pivot every physics frame outside cover, so the eye follows the ease.
func _crouch_eye_scale() -> float:
	var pawn := get_parent() as Pawn
	return pawn.crouch_height_scale() if pawn != null else 1.0
# M2 H1c item 4 end

## Presentation-only translation damping while in cover. Outside cover the rig follows the parent exactly.
## M2 C1b stage 2 (fixes 19, 25): when the follow stops (EXITING, or FREE for an exit that skipped EXITING, such as a
## lost wall, a reset or a death) its lag is not cut: it eases out over cover_blend_s (smoothstep) to the
## parent-exact pivot, for every exit, so the camera never snaps.
func _tick_cover_follow(delta: float) -> void:
	var pawn := get_parent() as Pawn
	if not _holds_cover(pawn):
		if pawn == null:
			_cover_follow_active = false
			return
		if _cover_follow_active:
			_cover_follow_active = false
			var exact := global_transform * transform.affine_inverse() * Vector3(0, _rig_height(), 0)
			_exit_residual = global_position - exact
			_exit_t = 0.0
			_exit_s = cover_blend_s()
		var pivot := Vector3(0, _rig_height(), 0)
		if _exit_s > 0.0:
			_exit_t = minf(_exit_t + maxf(delta, 0.0), _exit_s)
			var k := 1.0 - smoothstep(0.0, 1.0, _exit_t / _exit_s)
			var parent_basis := (global_transform * transform.affine_inverse()).basis
			pivot += parent_basis.inverse() * (_exit_residual * k)
			if _exit_t >= _exit_s:
				_exit_s = 0.0
		position = pivot
		return
	_exit_s = 0.0
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
	_arm.position.x = _third_x() * (1.0 - _fp_weight)


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
	var third := lerpf(lerpf(_shoulder_hip_length, _aim_arm_length(), _aim_blend), _cover_length(), _cover_w)
	_arm.spring_length = lerpf(third, 0.0, _fp_weight)


## AMSG-style right/left shoulder swap. Unknown sides fall back to right. Ignored in first person (M2 C1a: the
## shoulder has no meaning there) and in cover (M2 C1b stage 2: the cover view's side follows CoverController.side).
func set_shoulder_side(side: String) -> void:
	if is_first_person() or in_cover_view():
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
